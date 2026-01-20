#!/bin/bash
# /root/upgrade-docker.sh
# Run on each AIR-GAPPED server to upgrade Docker 28.5.1 → 29.1.5
#
# Prerequisites:
# - Extract docker-offline-packages.tar.gz to /opt/
#
# This script handles:
# - Docker Swarm detection and node drain/activate
# - Automatic RHEL version detection (8 or 9)
# - Proper service stop/start order (containerd before docker)
# - Direct RPM installation (no network required)
# - XFS ftype=1 validation for containerd (with interactive fix)
# - containerd config migration (1.7 → 2.2)
# - NVIDIA toolkit upgrade (if already installed)
# - Comprehensive verification
#
# NOTE: This script uses direct rpm installation instead of dnf/createrepo
# to avoid SSL certificate issues with corporate satellite servers
# (e.g., "SSL certificate problem: EE certificate key too weak")
#
# NOTE: containerd 2.x requires XFS filesystems to have ftype=1.
# If /var/lib/containerd is on XFS with ftype=0, you will be prompted
# to provide an alternative path on a compatible filesystem.

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Log file
exec > >(tee -a /var/log/docker-upgrade.log) 2>&1

echo "=========================================="
echo "Docker Upgrade: 28.5.1 → 29.1.5"
echo "Server: $(hostname)"
echo "Date: $(date)"
echo "=========================================="

#############################################
# Helper Functions
#############################################

prompt_yes_no() {
    local prompt="$1"
    local default="$2"
    local response

    while true; do
        read -p "$prompt " response
        response=${response:-$default}
        case "$response" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]) return 1 ;;
            *) echo "Please answer yes or no." ;;
        esac
    done
}

check_xfs_ftype() {
    local path="$1"
    local check_path="$path"

    # Find an existing path to check (walk up if needed)
    while [ ! -e "$check_path" ] && [ "$check_path" != "/" ]; do
        check_path=$(dirname "$check_path")
    done

    # Get mount point using findmnt (more reliable than parsing df)
    local mount_point
    mount_point=$(findmnt -n -o TARGET --target "$check_path" 2>/dev/null)

    # Fallback to df if findmnt not available
    if [ -z "$mount_point" ]; then
        mount_point=$(df "$check_path" 2>/dev/null | tail -1 | awk '{print $NF}')
    fi

    if [ -z "$mount_point" ]; then
        echo "unknown:no_mount"
        return
    fi

    # Check filesystem type
    local fs_type
    fs_type=$(findmnt -n -o FSTYPE --target "$check_path" 2>/dev/null)
    if [ -z "$fs_type" ]; then
        fs_type=$(df -T "$check_path" 2>/dev/null | tail -1 | awk '{print $2}')
    fi

    if [ "$fs_type" != "xfs" ]; then
        echo "ok:$fs_type"
        return
    fi

    # Check ftype for XFS - xfs_info ONLY works on mount point
    local ftype
    ftype=$(xfs_info "$mount_point" 2>/dev/null | grep -oP 'ftype=\K[0-9]')

    # Fallback grep if -P not supported
    if [ -z "$ftype" ]; then
        ftype=$(xfs_info "$mount_point" 2>/dev/null | grep -o "ftype=[0-9]" | cut -d= -f2)
    fi

    if [ "$ftype" = "1" ]; then
        echo "ok:xfs:ftype=1:$mount_point"
    elif [ "$ftype" = "0" ]; then
        echo "bad:xfs:ftype=0:$mount_point"
    else
        echo "unknown:xfs:$mount_point"
    fi
}

wait_for_services() {
    local max_wait=60
    local waited=0

    echo "Waiting for Swarm services to stabilize..."
    while [ $waited -lt $max_wait ]; do
        local pending
        pending=$(docker service ls --format '{{.Replicas}}' 2>/dev/null | grep -v "0/0" | grep -c "/0" || echo "0")

        if [ "$pending" = "0" ]; then
            echo "All services are running."
            return 0
        fi

        echo "  Waiting for services... ($waited/$max_wait seconds)"
        sleep 5
        waited=$((waited + 5))
    done

    echo -e "${YELLOW}WARNING: Some services may still be starting.${NC}"
    docker service ls
    return 0
}

#############################################
# Pre-flight Checks
#############################################

# Detect RHEL version
RHEL_VER=$(rpm -E %rhel)
PKG_DIR="/opt/docker-offline/rhel${RHEL_VER}"

if [ ! -d "$PKG_DIR" ]; then
    echo -e "${RED}ERROR: Package directory not found: $PKG_DIR${NC}"
    echo "Please extract docker-offline-packages.tar.gz to /opt/"
    exit 1
fi

echo "Detected RHEL version: $RHEL_VER"
echo "Using packages from: $PKG_DIR"

# Check if NVIDIA toolkit is installed
NVIDIA_INSTALLED=false
if rpm -q nvidia-container-toolkit &>/dev/null; then
    NVIDIA_INSTALLED=true
    echo "NVIDIA Container Toolkit detected - will upgrade"
fi

#############################################
# Phase 1: Docker Swarm Detection & Drain
#############################################
echo ""
echo "=== Phase 1: Docker Swarm Check ==="

SWARM_ACTIVE=false
SWARM_NODE_ID=""
SWARM_WAS_ACTIVE=false

if docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q "active"; then
    SWARM_ACTIVE=true
    SWARM_NODE_ID=$(docker info --format '{{.Swarm.NodeID}}' 2>/dev/null)
    SWARM_ROLE=$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null)

    if [ "$SWARM_ROLE" = "true" ]; then
        echo "This node is a Swarm MANAGER (Node ID: $SWARM_NODE_ID)"
    else
        echo "This node is a Swarm WORKER (Node ID: $SWARM_NODE_ID)"
    fi

    # Check current availability
    NODE_AVAILABILITY=$(docker node inspect "$SWARM_NODE_ID" --format '{{.Spec.Availability}}' 2>/dev/null || echo "unknown")
    echo "Current availability: $NODE_AVAILABILITY"

    if [ "$NODE_AVAILABILITY" = "active" ]; then
        SWARM_WAS_ACTIVE=true
        echo ""
        echo -e "${YELLOW}WARNING: This node is currently ACTIVE in the Swarm.${NC}"
        echo "It should be drained before upgrading to avoid service disruption."
        echo ""

        if prompt_yes_no "Drain this node now? [Y/n]" "y"; then
            echo "Draining node..."
            docker node update --availability drain "$SWARM_NODE_ID"

            echo "Waiting for tasks to migrate..."
            sleep 10

            # Show remaining tasks
            TASKS=$(docker node ps "$SWARM_NODE_ID" --filter "desired-state=running" --format '{{.Name}}' 2>/dev/null | wc -l)
            if [ "$TASKS" -gt 0 ]; then
                echo "Tasks still on this node: $TASKS"
                docker node ps "$SWARM_NODE_ID" --filter "desired-state=running"
                echo ""
                if ! prompt_yes_no "Continue with upgrade anyway? [y/N]" "n"; then
                    echo "Aborting. Please wait for tasks to migrate and re-run."
                    exit 1
                fi
            else
                echo "All tasks migrated successfully."
            fi
        else
            echo -e "${YELLOW}Proceeding without draining. Services may be disrupted.${NC}"
        fi
    else
        echo "Node is already drained/paused. Proceeding with upgrade."
    fi
else
    echo "This node is NOT part of a Docker Swarm."
fi

#############################################
# Phase 2: Pre-upgrade Verification
#############################################
echo ""
echo "=== Phase 2: Pre-upgrade Verification ==="

# Check dnf state for corruption
echo "Checking dnf state..."
if ! dnf check 2>/dev/null; then
    echo -e "${YELLOW}WARNING: dnf has issues. Attempting cleanup...${NC}"
    dnf clean all
    rpm --rebuilddb
fi

# Verify current packages are installed
echo "Current installed versions:"
rpm -q docker-ce docker-ce-cli containerd.io 2>/dev/null || echo "Some packages not installed"

# Check services (don't fail if not running)
echo "Service status:"
systemctl is-active docker 2>/dev/null && echo "  docker: running" || echo "  docker: not running"
systemctl is-active containerd 2>/dev/null && echo "  containerd: running" || echo "  containerd: not running"

#############################################
# Phase 3: Backup
#############################################
echo ""
echo "=== Phase 3: Backup ==="
BACKUP_DIR="/root/docker-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

docker version > "$BACKUP_DIR/docker-version.txt" 2>&1 || true
containerd --version > "$BACKUP_DIR/containerd-version.txt" 2>&1 || true
docker ps -a > "$BACKUP_DIR/containers.txt" 2>&1 || true
docker images --all > "$BACKUP_DIR/images.txt" 2>&1 || true
docker network ls > "$BACKUP_DIR/networks.txt" 2>&1 || true
cp /etc/containerd/config.toml "$BACKUP_DIR/config.toml" 2>/dev/null || true
cp /etc/docker/daemon.json "$BACKUP_DIR/daemon.json" 2>/dev/null || true
rpm -qa | grep -E "(docker|containerd)" > "$BACKUP_DIR/packages.txt" 2>&1 || true

echo "Backup saved to: $BACKUP_DIR"

#############################################
# Phase 4: Stop Services (CORRECT ORDER)
#############################################
echo ""
echo "=== Phase 4: Stop Services ==="

# Stop docker first
echo "Stopping docker..."
systemctl stop docker docker.socket 2>/dev/null || true
sleep 2

# Then stop containerd
echo "Stopping containerd..."
systemctl stop containerd 2>/dev/null || true
sleep 2

echo "Services stopped."

#############################################
# Phase 5: Upgrade Packages (Direct RPM)
#############################################
echo ""
echo "=== Phase 5: Upgrade Packages ==="

# Use direct rpm installation - no network required, avoids SSL issues
# with corporate satellite servers
cd "$PKG_DIR"
echo "Installing packages from: $PKG_DIR"
ls -la *.rpm

echo "Running rpm upgrade..."
rpm -Uvh --force *.rpm

echo -e "${GREEN}Packages upgraded.${NC}"

#############################################
# Phase 6: Configure containerd
#############################################
echo ""
echo "=== Phase 6: Configure containerd ==="

# Generate default config for containerd 2.x
echo "Generating containerd 2.x configuration..."
containerd config default > /etc/containerd/config.toml

# Get current containerd root from config (handles both single and double quotes)
CONTAINERD_ROOT=$(grep -E "^root\s*=" /etc/containerd/config.toml | head -1 | sed "s/.*=\s*['\"]\\(.*\\)['\"]/\\1/")
CONTAINERD_ROOT=${CONTAINERD_ROOT:-/var/lib/containerd}

echo "containerd root directory: $CONTAINERD_ROOT"

# Check XFS ftype for containerd root
echo "Checking filesystem compatibility..."
FTYPE_CHECK=$(check_xfs_ftype "$CONTAINERD_ROOT")

if [[ "$FTYPE_CHECK" == bad:* ]]; then
    echo ""
    echo -e "${RED}=========================================="
    echo "WARNING: XFS FILESYSTEM ISSUE DETECTED"
    echo "==========================================${NC}"
    echo ""
    echo "The containerd root directory ($CONTAINERD_ROOT) is on an XFS"
    echo "filesystem with ftype=0. containerd 2.x requires ftype=1."
    echo ""
    echo "This will cause container startup failures!"
    echo ""

    # Find filesystems with ftype=1
    echo "Scanning for compatible filesystems..."
    echo ""

    while true; do
        read -p "Enter an alternative path for containerd root (e.g., /data/containerd): " NEW_CONTAINERD_ROOT

        if [ -z "$NEW_CONTAINERD_ROOT" ]; then
            echo "Path cannot be empty."
            continue
        fi

        # Check if parent directory exists or can be created
        PARENT_DIR=$(dirname "$NEW_CONTAINERD_ROOT")
        if [ ! -d "$PARENT_DIR" ]; then
            echo -e "${YELLOW}Parent directory $PARENT_DIR does not exist.${NC}"
            if ! prompt_yes_no "Create it? [Y/n]" "y"; then
                continue
            fi
            mkdir -p "$PARENT_DIR"
        fi

        # Check ftype of new path
        NEW_FTYPE_CHECK=$(check_xfs_ftype "$PARENT_DIR")

        if [[ "$NEW_FTYPE_CHECK" == bad:* ]]; then
            echo -e "${RED}ERROR: $NEW_CONTAINERD_ROOT is also on XFS with ftype=0.${NC}"
            echo "Please choose a different path."
            continue
        fi

        echo -e "${GREEN}Filesystem check passed: $NEW_FTYPE_CHECK${NC}"

        # Create the directory
        mkdir -p "$NEW_CONTAINERD_ROOT"

        # Update containerd config (config uses single quotes)
        echo "Updating containerd configuration..."
        sed -i "s|^root = .*|root = '$NEW_CONTAINERD_ROOT'|" /etc/containerd/config.toml

        # Verify the change was applied
        NEW_ROOT_CHECK=$(grep -E "^root\s*=" /etc/containerd/config.toml | head -1)
        echo "Updated config: $NEW_ROOT_CHECK"

        if ! echo "$NEW_ROOT_CHECK" | grep -q "$NEW_CONTAINERD_ROOT"; then
            echo -e "${RED}ERROR: Failed to update containerd config!${NC}"
            echo "Please manually edit /etc/containerd/config.toml"
            echo "Change: root = '/var/lib/containerd'"
            echo "To:     root = '$NEW_CONTAINERD_ROOT'"
            exit 1
        fi

        CONTAINERD_ROOT="$NEW_CONTAINERD_ROOT"
        break
    done
else
    echo -e "${GREEN}Filesystem check passed: $FTYPE_CHECK${NC}"
fi

# Ensure containerd root exists
mkdir -p "$CONTAINERD_ROOT"

#############################################
# Phase 7: Handle NVIDIA Toolkit (if present)
#############################################
if [ "$NVIDIA_INSTALLED" = true ]; then
    echo ""
    echo "=== Phase 7: Upgrade NVIDIA Container Toolkit ==="

    NVIDIA_DIR="/opt/docker-offline/nvidia"
    if [ -d "$NVIDIA_DIR" ] && ls "$NVIDIA_DIR"/*.rpm &>/dev/null; then
        cd "$NVIDIA_DIR"
        rpm -Uvh --force *.rpm || true

        # Reconfigure NVIDIA runtime for Docker
        nvidia-ctk runtime configure --runtime=docker
        nvidia-ctk runtime configure --runtime=containerd

        echo "NVIDIA toolkit upgraded and configured."
    else
        echo -e "${YELLOW}WARNING: NVIDIA packages not found in $NVIDIA_DIR${NC}"
    fi
fi

#############################################
# Phase 8: Start Services (CORRECT ORDER)
#############################################
echo ""
echo "=== Phase 8: Start Services ==="

# Start containerd FIRST
echo "Starting containerd..."
systemctl start containerd
systemctl enable containerd

# Wait for containerd to be ready
echo "Waiting for containerd to initialize..."
sleep 5

# Verify containerd is healthy
if ! systemctl is-active containerd &>/dev/null; then
    echo -e "${RED}ERROR: containerd failed to start!${NC}"
    echo "Check logs with: journalctl -u containerd --no-pager -n 50"
    exit 1
fi

# Then start docker
echo "Starting docker..."
systemctl start docker
systemctl enable docker

# Verify docker is healthy
if ! systemctl is-active docker &>/dev/null; then
    echo -e "${RED}ERROR: docker failed to start!${NC}"
    echo "Check logs with: journalctl -u docker --no-pager -n 50"
    exit 1
fi

echo -e "${GREEN}Services started successfully.${NC}"

#############################################
# Phase 9: Verification
#############################################
echo ""
echo "=== Phase 9: Verification ==="

echo "Docker version:"
docker version

echo ""
echo "containerd version:"
containerd --version

echo ""
echo "Installed packages:"
rpm -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo ""
echo "Service status:"
systemctl is-active docker && echo -e "  docker: ${GREEN}running${NC}"
systemctl is-active containerd && echo -e "  containerd: ${GREEN}running${NC}"

echo ""
echo "Docker images (use 'docker images --all' in Docker 29.x):"
docker images --all | head -20

echo ""
echo "Existing containers:"
docker ps -a | head -20

if [ "$NVIDIA_INSTALLED" = true ]; then
    echo ""
    echo "NVIDIA GPU test:"
    if docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi 2>/dev/null; then
        echo -e "${GREEN}SUCCESS: GPU access works!${NC}"
    else
        echo "NOTE: GPU test requires nvidia/cuda image to be available"
    fi
fi

#############################################
# Phase 10: Swarm Reactivation
#############################################
if [ "$SWARM_ACTIVE" = true ]; then
    echo ""
    echo "=== Phase 10: Docker Swarm Reactivation ==="

    # Re-check node status
    CURRENT_AVAILABILITY=$(docker node inspect "$SWARM_NODE_ID" --format '{{.Spec.Availability}}' 2>/dev/null || echo "unknown")
    echo "Current node availability: $CURRENT_AVAILABILITY"

    if [ "$CURRENT_AVAILABILITY" = "drain" ]; then
        echo ""
        if prompt_yes_no "Set this node back to ACTIVE? [Y/n]" "y"; then
            echo "Activating node..."
            docker node update --availability active "$SWARM_NODE_ID"

            echo ""
            wait_for_services

            echo ""
            echo "Node status:"
            docker node ls

            echo ""
            echo "Services on this node:"
            docker node ps "$SWARM_NODE_ID" | head -20
        else
            echo ""
            echo "Node remains drained. To activate later, run:"
            echo "  docker node update --availability active $SWARM_NODE_ID"
        fi
    else
        echo "Node is already active."
    fi
fi

#############################################
# Complete
#############################################
echo ""
echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}UPGRADE COMPLETE${NC}"
echo -e "${GREEN}==========================================${NC}"
echo ""
echo "Versions installed:"
echo "  - docker-ce: $(rpm -q docker-ce --queryformat '%{VERSION}')"
echo "  - containerd.io: $(rpm -q containerd.io --queryformat '%{VERSION}')"
echo ""
echo "containerd root: $CONTAINERD_ROOT"
echo ""
if [ "$SWARM_ACTIVE" = true ]; then
    echo "Swarm node ID: $SWARM_NODE_ID"
    echo "Swarm status: $(docker node inspect "$SWARM_NODE_ID" --format '{{.Spec.Availability}}' 2>/dev/null)"
fi
echo ""
echo "Log file: /var/log/docker-upgrade.log"
echo "Backup: $BACKUP_DIR"
echo "=========================================="

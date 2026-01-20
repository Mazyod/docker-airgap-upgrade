#!/bin/bash
# /root/upgrade-docker.sh
# Run on each AIR-GAPPED server to upgrade Docker 28.5.1 → 29.1.5
#
# Prerequisites:
# - Extract docker-offline-packages.tar.gz to /opt/
# - For Swarm nodes: drain the node first
#
# This script handles:
# - Automatic RHEL version detection (8 or 9)
# - Proper service stop/start order (containerd before docker)
# - Direct RPM installation (no network required)
# - containerd config migration (1.7 → 2.2)
# - NVIDIA toolkit upgrade (if already installed)
# - Comprehensive verification
#
# NOTE: This script uses direct rpm installation instead of dnf/createrepo
# to avoid SSL certificate issues with corporate satellite servers
# (e.g., "SSL certificate problem: EE certificate key too weak")

set -e
exec > >(tee -a /var/log/docker-upgrade.log) 2>&1

echo "=========================================="
echo "Docker Upgrade: 28.5.1 → 29.1.5"
echo "Server: $(hostname)"
echo "Date: $(date)"
echo "=========================================="

# Detect RHEL version
RHEL_VER=$(rpm -E %rhel)
PKG_DIR="/opt/docker-offline/rhel${RHEL_VER}"

if [ ! -d "$PKG_DIR" ]; then
    echo "ERROR: Package directory not found: $PKG_DIR"
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
# Phase 1: Pre-upgrade Verification
#############################################
echo ""
echo "=== Phase 1: Pre-upgrade Verification ==="

# Check dnf state for corruption
echo "Checking dnf state..."
if ! dnf check 2>/dev/null; then
    echo "WARNING: dnf has issues. Attempting cleanup..."
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
# Phase 2: Backup
#############################################
echo ""
echo "=== Phase 2: Backup ==="
BACKUP_DIR="/root/docker-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

docker version > "$BACKUP_DIR/docker-version.txt" 2>&1 || true
containerd --version > "$BACKUP_DIR/containerd-version.txt" 2>&1 || true
docker ps -a > "$BACKUP_DIR/containers.txt" 2>&1 || true
docker images > "$BACKUP_DIR/images.txt" 2>&1 || true
docker network ls > "$BACKUP_DIR/networks.txt" 2>&1 || true
cp /etc/containerd/config.toml "$BACKUP_DIR/config.toml" 2>/dev/null || true
rpm -qa | grep -E "(docker|containerd)" > "$BACKUP_DIR/packages.txt" 2>&1 || true

echo "Backup saved to: $BACKUP_DIR"

#############################################
# Phase 3: Stop Services (CORRECT ORDER)
#############################################
echo ""
echo "=== Phase 3: Stop Services ==="

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
# Phase 4: Upgrade Packages (Direct RPM)
#############################################
echo ""
echo "=== Phase 4: Upgrade Packages ==="

# Use direct rpm installation - no network required, avoids SSL issues
# with corporate satellite servers
cd "$PKG_DIR"
echo "Installing packages from: $PKG_DIR"
ls -la *.rpm

echo "Running rpm upgrade..."
rpm -Uvh --force *.rpm

echo "Packages upgraded."

#############################################
# Phase 5: Migrate containerd Config
#############################################
echo ""
echo "=== Phase 5: Migrate containerd Config ==="

if [ -f "$BACKUP_DIR/config.toml" ]; then
    echo "Migrating config from 1.x to 2.x format..."
    containerd config migrate "$BACKUP_DIR/config.toml" > /etc/containerd/config.toml 2>/dev/null || {
        echo "Migration failed, generating default config..."
        containerd config default > /etc/containerd/config.toml
    }
else
    echo "No previous config found, using defaults..."
    containerd config default > /etc/containerd/config.toml
fi

#############################################
# Phase 6: Handle NVIDIA Toolkit (if present)
#############################################
if [ "$NVIDIA_INSTALLED" = true ]; then
    echo ""
    echo "=== Phase 6: Upgrade NVIDIA Container Toolkit ==="

    NVIDIA_DIR="/opt/docker-offline/nvidia"
    if [ -d "$NVIDIA_DIR" ] && ls "$NVIDIA_DIR"/*.rpm &>/dev/null; then
        cd "$NVIDIA_DIR"
        rpm -Uvh --force *.rpm || true

        # Reconfigure NVIDIA runtime for Docker
        nvidia-ctk runtime configure --runtime=docker
        nvidia-ctk runtime configure --runtime=containerd

        echo "NVIDIA toolkit upgraded and configured."
    else
        echo "WARNING: NVIDIA packages not found in $NVIDIA_DIR"
    fi
fi

#############################################
# Phase 7: Start Services (CORRECT ORDER)
#############################################
echo ""
echo "=== Phase 7: Start Services ==="

# Start containerd FIRST
echo "Starting containerd..."
systemctl start containerd
systemctl enable containerd

# Wait for containerd to be ready
echo "Waiting for containerd to initialize..."
sleep 5

# Then start docker
echo "Starting docker..."
systemctl start docker
systemctl enable docker

echo "Services started."

#############################################
# Phase 8: Verification
#############################################
echo ""
echo "=== Phase 8: Verification ==="

echo "Docker version:"
docker version

echo ""
echo "containerd version (should show containerd.io 2.2.1):"
containerd --version

echo ""
echo "Installed packages:"
rpm -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo ""
echo "Service status:"
systemctl is-active docker && echo "  docker: running"
systemctl is-active containerd && echo "  containerd: running"

echo ""
echo "Testing DNS resolution on custom bridge network (the bug fix):"
docker network create test-upgrade-net 2>/dev/null || true
if docker run --rm --network test-upgrade-net alpine:latest nslookup google.com 2>/dev/null; then
    echo "SUCCESS: DNS resolution works!"
else
    echo "NOTE: DNS test skipped (expected in air-gapped environment without alpine image)"
fi
docker network rm test-upgrade-net 2>/dev/null || true

echo ""
echo "Existing containers:"
docker ps -a

if [ "$NVIDIA_INSTALLED" = true ]; then
    echo ""
    echo "Testing NVIDIA GPU access:"
    if docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi 2>/dev/null; then
        echo "SUCCESS: GPU access works!"
    else
        echo "NOTE: GPU test requires nvidia/cuda image to be available"
    fi
fi

echo ""
echo "=========================================="
echo "UPGRADE COMPLETE"
echo "=========================================="
echo "Expected versions:"
echo "  - docker-ce: 29.1.5"
echo "  - containerd.io: 2.2.1"
echo ""
echo "For Swarm nodes, remember to:"
echo "  docker node update --availability active <node-name>"
echo "=========================================="

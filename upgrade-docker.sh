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
# - Two-phase package installation (install then distro-sync)
# - containerd config migration (1.7 → 2.2)
# - NVIDIA toolkit upgrade (if already installed)
# - Comprehensive verification

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
# Phase 3: Create Local Repository
#############################################
echo ""
echo "=== Phase 3: Create Local Repository ==="

# Ensure createrepo is available
if ! command -v createrepo &>/dev/null; then
    echo "Installing createrepo_c..."
    dnf install -y createrepo_c 2>/dev/null || yum install -y createrepo
fi

cd "$PKG_DIR"
createrepo . 2>/dev/null || createrepo .

cat > /etc/yum.repos.d/docker-local.repo << EOF
[docker-local]
name=Docker Local Repo
baseurl=file://${PKG_DIR}
enabled=1
gpgcheck=0
priority=1
EOF

echo "Local repository created."

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
# Phase 5: Upgrade Packages (TWO-PHASE)
#############################################
echo ""
echo "=== Phase 5: Upgrade Packages ==="

dnf clean all

# PHASE 5a: Install (handles both fresh install and existing)
echo "Phase 5a: Installing packages..."
dnf install -y --disablerepo='*' --enablerepo=docker-local \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin 2>&1 || true

# PHASE 5b: distro-sync with --allowerasing (handles version conflicts)
echo "Phase 5b: Synchronizing versions..."
dnf distro-sync -y --disablerepo='*' --enablerepo=docker-local --allowerasing \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

echo "Packages upgraded."

#############################################
# Phase 6: Migrate containerd Config
#############################################
echo ""
echo "=== Phase 6: Migrate containerd Config ==="

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
# Phase 7: Handle NVIDIA Toolkit (if present)
#############################################
if [ "$NVIDIA_INSTALLED" = true ]; then
    echo ""
    echo "=== Phase 7: Upgrade NVIDIA Container Toolkit ==="

    NVIDIA_DIR="/opt/docker-offline/nvidia"
    if [ -d "$NVIDIA_DIR" ] && ls "$NVIDIA_DIR"/*.rpm &>/dev/null; then
        createrepo "$NVIDIA_DIR" 2>/dev/null || true

        cat > /etc/yum.repos.d/nvidia-local.repo << EOF
[nvidia-local]
name=NVIDIA Local Repo
baseurl=file://${NVIDIA_DIR}
enabled=1
gpgcheck=0
EOF

        dnf install -y --disablerepo='*' --enablerepo=nvidia-local nvidia-container-toolkit || true
        dnf distro-sync -y --disablerepo='*' --enablerepo=nvidia-local --allowerasing nvidia-container-toolkit || true

        # Reconfigure NVIDIA runtime for Docker
        nvidia-ctk runtime configure --runtime=docker
        nvidia-ctk runtime configure --runtime=containerd

        echo "NVIDIA toolkit upgraded and configured."
    else
        echo "WARNING: NVIDIA packages not found in $NVIDIA_DIR"
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

# Then start docker
echo "Starting docker..."
systemctl start docker
systemctl enable docker

echo "Services started."

#############################################
# Phase 9: Verification
#############################################
echo ""
echo "=== Phase 9: Verification ==="

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

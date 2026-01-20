#!/bin/bash
# /root/rollback-docker.sh
# Emergency rollback: Docker 29.1.5 → 28.5.1
#
# Use this script if:
# - Services fail to start after upgrade
# - Applications break due to API changes
# - Cluster nodes have version mismatch issues
# - Any other critical issues requiring immediate rollback
#
# Prerequisites:
# - Rollback packages in /opt/docker-offline/rollback-rhel{8,9}/

set -e
exec > >(tee -a /var/log/docker-rollback.log) 2>&1

echo "=========================================="
echo "Docker Rollback: 29.1.5 → 28.5.1"
echo "Server: $(hostname)"
echo "Date: $(date)"
echo "=========================================="

# Detect RHEL version
RHEL_VER=$(rpm -E %rhel)
ROLLBACK_DIR="/opt/docker-offline/rollback-rhel${RHEL_VER}"

if [ ! -d "$ROLLBACK_DIR" ]; then
    echo "ERROR: Rollback directory not found: $ROLLBACK_DIR"
    exit 1
fi

echo "Detected RHEL version: $RHEL_VER"
echo "Using rollback packages from: $ROLLBACK_DIR"

# Verify rollback packages exist
echo ""
echo "Verifying rollback packages..."
ls -la "$ROLLBACK_DIR"/*.rpm || {
    echo "ERROR: No RPM packages found in $ROLLBACK_DIR"
    exit 1
}

#############################################
# Phase 1: Stop Services
#############################################
echo ""
echo "=== Phase 1: Stop Services ==="

echo "Stopping docker..."
systemctl stop docker docker.socket 2>/dev/null || true
sleep 2

echo "Stopping containerd..."
systemctl stop containerd 2>/dev/null || true
sleep 2

echo "Services stopped."

#############################################
# Phase 2: Downgrade Packages
#############################################
echo ""
echo "=== Phase 2: Downgrade Packages ==="

cd "$ROLLBACK_DIR"

# Use rpm with --oldpackage to force downgrade
echo "Downgrading containerd.io to 1.7.29..."
rpm -Uvh --oldpackage containerd.io-1.7.29-*.rpm

echo "Downgrading docker-ce and docker-ce-cli to 28.5.1..."
rpm -Uvh --oldpackage docker-ce-28.5.1-*.rpm docker-ce-cli-28.5.1-*.rpm

echo "Packages downgraded."

#############################################
# Phase 3: Restore containerd Config
#############################################
echo ""
echo "=== Phase 3: Restore containerd Config ==="

# Find most recent backup
BACKUP_DIR=$(ls -td /root/docker-backup-* 2>/dev/null | head -1)

if [ -n "$BACKUP_DIR" ] && [ -f "$BACKUP_DIR/config.toml" ]; then
    echo "Restoring containerd config from $BACKUP_DIR..."
    cp "$BACKUP_DIR/config.toml" /etc/containerd/config.toml
    echo "Config restored."
else
    echo "No backup config found, generating default for 1.7.x..."
    containerd config default > /etc/containerd/config.toml
fi

#############################################
# Phase 4: Restart Services (CORRECT ORDER)
#############################################
echo ""
echo "=== Phase 4: Restart Services ==="

echo "Starting containerd..."
systemctl start containerd
sleep 3

echo "Starting docker..."
systemctl start docker

echo "Services started."

#############################################
# Phase 5: Verification
#############################################
echo ""
echo "=== Phase 5: Verification ==="

echo "Docker version (should be 28.5.1):"
docker version

echo ""
echo "containerd version (should be 1.7.29):"
containerd --version

echo ""
echo "Installed packages:"
rpm -q docker-ce docker-ce-cli containerd.io

echo ""
echo "Service status:"
systemctl is-active docker && echo "  docker: running"
systemctl is-active containerd && echo "  containerd: running"

echo ""
echo "Existing containers:"
docker ps -a

echo ""
echo "=========================================="
echo "ROLLBACK COMPLETE"
echo "=========================================="
echo ""
echo "Rolled back to:"
echo "  - docker-ce: 28.5.1"
echo "  - containerd.io: 1.7.29"
echo ""
echo "NOTE: The DNS fix for custom bridge networks will NOT be"
echo "available in this version. Consider troubleshooting the"
echo "29.1.5 upgrade or waiting for a newer release."
echo ""
echo "For Swarm nodes, remember to:"
echo "  docker node update --availability active <node-name>"
echo "=========================================="

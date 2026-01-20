#!/bin/bash
# /root/download-docker-packages.sh
# Run on the ONLINE RHEL 8 server to collect all packages needed for air-gapped upgrade
#
# This script downloads:
# - Docker 29.1.5 packages for RHEL 8 and RHEL 9
# - Rollback packages (28.5.1) for emergency recovery
# - NVIDIA Container Toolkit packages (for GPU servers)

set -e

DEST_BASE="/opt/docker-offline"
mkdir -p "$DEST_BASE"/{rhel8,rhel9,nvidia,rollback-rhel8,rollback-rhel9}

echo "=========================================="
echo "Docker Offline Package Downloader"
echo "Date: $(date)"
echo "=========================================="

echo ""
echo "=== Downloading Docker 29.1.5 packages ==="

# RHEL 8
echo ""
echo "Downloading RHEL 8 packages..."
cd "$DEST_BASE/rhel8"
for pkg in \
    docker-ce-29.1.5-1.el8.x86_64.rpm \
    docker-ce-cli-29.1.5-1.el8.x86_64.rpm \
    containerd.io-2.2.1-1.el8.x86_64.rpm \
    docker-buildx-plugin-0.30.1-1.el8.x86_64.rpm \
    docker-compose-plugin-5.0.1-1.el8.x86_64.rpm
do
    echo "  Downloading: $pkg"
    curl -LO "https://download.docker.com/linux/rhel/8/x86_64/stable/Packages/$pkg"
    echo "    ✓ $pkg"
done

# RHEL 9
echo ""
echo "Downloading RHEL 9 packages..."
cd "$DEST_BASE/rhel9"
for pkg in \
    docker-ce-29.1.5-1.el9.x86_64.rpm \
    docker-ce-cli-29.1.5-1.el9.x86_64.rpm \
    containerd.io-2.2.1-1.el9.x86_64.rpm \
    docker-buildx-plugin-0.30.1-1.el9.x86_64.rpm \
    docker-compose-plugin-5.0.1-1.el9.x86_64.rpm
do
    echo "  Downloading: $pkg"
    curl -LO "https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/$pkg"
    echo "    ✓ $pkg"
done

# Rollback packages (IMPORTANT!)
echo ""
echo "=== Downloading rollback packages ==="

echo "Downloading RHEL 8 rollback packages..."
cd "$DEST_BASE/rollback-rhel8"
for pkg in \
    docker-ce-28.5.1-1.el8.x86_64.rpm \
    docker-ce-cli-28.5.1-1.el8.x86_64.rpm \
    containerd.io-1.7.29-1.el8.x86_64.rpm
do
    echo "  Downloading: $pkg"
    curl -LO "https://download.docker.com/linux/rhel/8/x86_64/stable/Packages/$pkg"
    echo "    ✓ $pkg (rollback)"
done

echo ""
echo "Downloading RHEL 9 rollback packages..."
cd "$DEST_BASE/rollback-rhel9"
for pkg in \
    docker-ce-28.5.1-1.el9.x86_64.rpm \
    docker-ce-cli-28.5.1-1.el9.x86_64.rpm \
    containerd.io-1.7.29-1.el9.x86_64.rpm
do
    echo "  Downloading: $pkg"
    curl -LO "https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/$pkg"
    echo "    ✓ $pkg (rollback)"
done

# NVIDIA Container Toolkit (for GPU servers)
echo ""
echo "=== Downloading NVIDIA Container Toolkit ==="
cd "$DEST_BASE/nvidia"

# Add NVIDIA repo temporarily
echo "Adding NVIDIA repository..."
curl -s -L https://nvidia.github.io/libnvidia-container/rhel8.10/libnvidia-container.repo | \
    tee /etc/yum.repos.d/nvidia-container-toolkit.repo

# Download with ALL dependencies
echo "Downloading NVIDIA packages with dependencies..."
dnf download --resolve --alldeps --destdir=. nvidia-container-toolkit || {
    echo "WARNING: Failed to download NVIDIA packages (may not be needed if no GPU servers)"
}

# Also get RHEL 9 nvidia packages
echo ""
echo "Attempting RHEL 9 NVIDIA packages..."
curl -s -L https://nvidia.github.io/libnvidia-container/rhel9.5/libnvidia-container.repo | \
    tee /etc/yum.repos.d/nvidia-container-toolkit-el9.repo
dnf download --resolve --alldeps --destdir=. nvidia-container-toolkit --releasever=9 2>/dev/null || {
    echo "WARNING: Failed to download RHEL 9 NVIDIA packages"
}

echo ""
echo "=== Verifying downloads ==="
echo ""
echo "RHEL 8 packages:"
ls -lh "$DEST_BASE/rhel8/"
echo ""
echo "RHEL 9 packages:"
ls -lh "$DEST_BASE/rhel9/"
echo ""
echo "Rollback RHEL 8:"
ls -lh "$DEST_BASE/rollback-rhel8/"
echo ""
echo "Rollback RHEL 9:"
ls -lh "$DEST_BASE/rollback-rhel9/"
echo ""
echo "NVIDIA packages:"
ls -lh "$DEST_BASE/nvidia/" 2>/dev/null || echo "  (none)"

# Verify checksums by checking RPM integrity
echo ""
echo "=== Verifying RPM integrity ==="
for dir in rhel8 rhel9 rollback-rhel8 rollback-rhel9; do
    echo "Checking $dir..."
    for rpm in "$DEST_BASE/$dir"/*.rpm; do
        if [ -f "$rpm" ]; then
            rpm -K "$rpm" >/dev/null 2>&1 || echo "  WARNING: $rpm may be corrupted"
        fi
    done
done

# Create tarball
echo ""
echo "=== Creating tarball ==="
cd /opt
tar czvf docker-offline-packages.tar.gz docker-offline/

echo ""
echo "=========================================="
echo "DOWNLOAD COMPLETE"
echo "=========================================="
echo ""
echo "Package ready: /opt/docker-offline-packages.tar.gz"
echo "Size: $(du -h /opt/docker-offline-packages.tar.gz | cut -f1)"
echo ""
echo "Transfer this file to your air-gapped servers."
echo "=========================================="

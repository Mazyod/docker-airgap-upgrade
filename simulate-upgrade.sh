#!/bin/bash
# /root/simulate-upgrade.sh
# Run on a fresh RHEL 8 VM to test the full upgrade process
#
# This script simulates the complete Docker 28.5.1 → 29.1.5 upgrade path
# in a controlled environment before deploying to production.

set -e
exec > >(tee -a /var/log/docker-upgrade-sim.log) 2>&1

echo "=========================================="
echo "Docker Upgrade Simulation: 28.5.1 → 29.1.5"
echo "Date: $(date)"
echo "=========================================="

# Phase A: Install Docker 28.5.1 (simulate current state)
echo ""
echo "=== Installing Docker 28.5.1 (simulating current state) ==="

dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo

# Note: buildx and compose have INDEPENDENT versions - don't pin them!
dnf install -y \
    docker-ce-28.5.1 \
    docker-ce-cli-28.5.1 \
    containerd.io-1.7.29 \
    docker-buildx-plugin \
    docker-compose-plugin

# Start containerd FIRST, then docker
systemctl enable --now containerd
sleep 2
systemctl enable --now docker

echo "Installed versions:"
docker version
containerd --version

# Create test containers
docker run -d --name test-nginx --network bridge nginx:alpine
docker network create custom-bridge
docker run -d --name test-dns --network custom-bridge alpine sleep 3600

# Phase B: Download upgrade packages (simulating online server)
echo ""
echo "=== Downloading upgrade packages ==="

mkdir -p /opt/docker-offline/rhel8
cd /opt/docker-offline/rhel8

# Download with explicit versions
for pkg in \
    docker-ce-29.1.5-1.el8.x86_64.rpm \
    docker-ce-cli-29.1.5-1.el8.x86_64.rpm \
    containerd.io-2.2.1-1.el8.x86_64.rpm \
    docker-buildx-plugin-0.30.1-1.el8.x86_64.rpm \
    docker-compose-plugin-5.0.1-1.el8.x86_64.rpm
do
    echo "Downloading: $pkg"
    curl -sLO "https://download.docker.com/linux/rhel/8/x86_64/stable/Packages/$pkg"
done

ls -lh *.rpm

# Phase C: Create local repository
echo ""
echo "=== Creating local repository ==="

dnf install -y createrepo_c
createrepo .

cat > /etc/yum.repos.d/docker-local.repo << 'EOF'
[docker-local]
name=Docker Local Repo
baseurl=file:///opt/docker-offline/rhel8
enabled=1
gpgcheck=0
priority=1
EOF

# Phase D: Backup
echo ""
echo "=== Creating backups ==="

mkdir -p /root/docker-backup
docker version > /root/docker-backup/docker-version.txt
docker ps -a > /root/docker-backup/containers.txt
cp /etc/containerd/config.toml /root/docker-backup/config.toml.bak 2>/dev/null || true

# Phase E: Pre-upgrade verification
echo ""
echo "=== Pre-upgrade verification ==="

echo "Checking dnf state..."
dnf check || { echo "ERROR: dnf has broken dependencies. Fix before proceeding."; exit 1; }

echo "Verifying services are running..."
systemctl is-active docker || { echo "ERROR: docker not running"; exit 1; }
systemctl is-active containerd || { echo "ERROR: containerd not running"; exit 1; }

echo "Current package versions:"
rpm -q docker-ce docker-ce-cli containerd.io

# Phase F: Perform upgrade
echo ""
echo "=== Performing upgrade ==="

# Stop services in correct order
systemctl stop docker docker.socket
sleep 2
systemctl stop containerd
sleep 2

# CRITICAL: Two-phase install approach (learned from past failures)
# Phase 1: Install (handles both fresh and existing)
dnf clean all
dnf install -y --disablerepo='*' --enablerepo=docker-local \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin || true

# Phase 2: distro-sync with --allowerasing (handles version conflicts)
dnf distro-sync -y --disablerepo='*' --enablerepo=docker-local --allowerasing \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

# Migrate containerd config (REQUIRED for 1.7→2.2)
echo ""
echo "=== Migrating containerd config ==="
if [ -f /root/docker-backup/config.toml.bak ]; then
    containerd config migrate /root/docker-backup/config.toml.bak > /etc/containerd/config.toml 2>/dev/null || \
        echo "Config migration skipped (using defaults)"
fi

# Start services in correct order: containerd FIRST
echo ""
echo "=== Starting services ==="
systemctl start containerd
sleep 3  # Wait for containerd to fully initialize
systemctl start docker
systemctl enable docker containerd

# Phase G: Verification
echo ""
echo "=== Verification ==="

echo "New versions:"
docker version
containerd --version

echo ""
echo "Package verification:"
rpm -q docker-ce docker-ce-cli containerd.io

echo ""
echo "Testing DNS resolution on custom bridge (the fix we need):"
docker start test-dns 2>/dev/null || true
docker exec test-dns nslookup google.com && echo "SUCCESS: DNS resolution works!" || echo "FAILED: DNS issue"

echo ""
echo "Testing existing containers:"
docker ps -a
docker start test-nginx 2>/dev/null || true
sleep 2
curl -s localhost:$(docker port test-nginx 80/tcp | cut -d: -f2) | head -5 && echo "SUCCESS: nginx works!"

# Cleanup
docker rm -f test-nginx test-dns 2>/dev/null || true
docker network rm custom-bridge 2>/dev/null || true

echo ""
echo "=========================================="
echo "SIMULATION COMPLETE"
echo "=========================================="

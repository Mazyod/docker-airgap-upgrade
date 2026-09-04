#!/bin/bash
# /root/simulate-upgrade.sh
# Run on a fresh RHEL 8 VM to test the full upgrade process
#
# This script simulates the complete Docker 29.1.5 → 29.8.0 upgrade path
# in a controlled environment before deploying to production.
#
# WHAT THIS DOES AND DOES NOT PROVE
#
# This uses createrepo + dnf, which is NOT the code path upgrade-docker.sh
# takes. That script uses `rpm -Uvh --force` directly, because corporate
# satellite servers break dnf with "SSL certificate problem: EE certificate key
# too weak". Passing this simulation therefore does NOT prove the air-gapped
# path works -- it proves the PACKAGES upgrade cleanly and the services come
# back.
#
# To exercise the real air-gapped path, run upgrade-docker.sh itself against a
# populated /opt/docker-offline in the same VM. See the test plan.

set -e
exec > >(tee -a /var/log/docker-upgrade-sim.log) 2>&1

# Detect the RHEL major rather than hard-coding el8. Testing a hand-edited copy
# of this script on RHEL 9 would not be testing the checked-in artifact.
RHEL_VER=$(rpm -E %rhel)
PKG_DIR="/opt/docker-offline/rhel${RHEL_VER}"

echo "=========================================="
echo "Docker Upgrade Simulation: 29.1.5 → 29.8.0"
echo "RHEL major: $RHEL_VER"
echo "Date: $(date)"
echo "=========================================="

# Phase A: Install Docker 29.1.5 (simulate current state)
echo ""
echo "=== Installing Docker 29.1.5 (simulating current cluster state) ==="

dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo

# buildx and compose have INDEPENDENT versions - never derive them from the
# docker-ce version. They ARE pinned here, to the versions the cluster actually
# runs today: leaving them unpinned installs the latest, so the "29.1.5
# baseline" would already contain the plugins the upgrade is supposed to
# deliver, and the plugin transition would go untested.
dnf install -y \
    docker-ce-29.1.5 \
    docker-ce-cli-29.1.5 \
    containerd.io-2.2.1 \
    docker-buildx-plugin-0.30.1 \
    docker-compose-plugin-5.0.1

# Start containerd FIRST, then docker
systemctl enable --now containerd
sleep 2
systemctl enable --now docker

echo "Installed versions:"
docker version
containerd --version

# Create test containers. nginx PUBLISHES a port -- without -p, `docker port`
# returns nothing later and the connectivity check tests an empty URL.
docker run -d --name test-nginx -p 18080:80 --network bridge nginx:alpine
docker network create custom-bridge
docker run -d --name test-dns --network custom-bridge alpine sleep 3600

# Capture the containerd config so the upgrade can be checked against it.
# Preserving this file across the upgrade is the single most important
# behavioural change in upgrade-docker.sh v2.0.0.
cp /etc/containerd/config.toml /root/config.toml.before 2>/dev/null || true

# Phase B: Download upgrade packages (simulating online server)
echo ""
echo "=== Downloading upgrade packages ==="

mkdir -p "$PKG_DIR"
cd "$PKG_DIR"

# Download with explicit versions. -f so a bad version fails here rather than
# writing a 404 page into a .rpm.
#
# containerd.io is "-2" while everything else is "-1". containerd.io 2.3.4 was
# published twice, same version and same file list, differing only in the runc
# it carries (1.4.3 in -1, 1.5.1 in -2). Both download fine, so leaving the
# suffix at "-1" during a retarget produces a simulation of the wrong runtime.
for pkg in \
    "docker-ce-29.8.0-1.el${RHEL_VER}.x86_64.rpm" \
    "docker-ce-cli-29.8.0-1.el${RHEL_VER}.x86_64.rpm" \
    "containerd.io-2.3.4-2.el${RHEL_VER}.x86_64.rpm" \
    "docker-buildx-plugin-0.37.0-1.el${RHEL_VER}.x86_64.rpm" \
    "docker-compose-plugin-5.5.1-1.el${RHEL_VER}.x86_64.rpm"
do
    echo "Downloading: $pkg"
    curl -fsLO "https://download.docker.com/linux/rhel/${RHEL_VER}/x86_64/stable/Packages/$pkg"
done

ls -lh ./*.rpm

# Phase C: Create local repository
echo ""
echo "=== Creating local repository ==="

dnf install -y createrepo_c
createrepo .

cat > /etc/yum.repos.d/docker-local.repo << EOF
[docker-local]
name=Docker Local Repo
baseurl=file://${PKG_DIR}
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

# NOTE: `containerd config migrate` used to run here. It was required for the
# 1.7 -> 2.x config format change. 2.3.4 raises the config version from 3 to 4
# but READS a v3 file unchanged -- it migrates in memory at load and never
# writes back -- so the existing config is carried across untouched.
#
# Running migrate here would also be pointless: it writes to stdout, not to the
# file. Writing its v4 output over the config would block a later rollback to
# containerd 2.2.1, which loads at most version 3.

# Start services in correct order: containerd FIRST
echo ""
echo "=== Starting services ==="
systemctl start containerd

# Poll rather than sleeping blindly: systemd reports containerd active before
# its snapshotter is usable.
for i in {1..30}; do
    if ctr version &>/dev/null; then
        echo "containerd API responsive (attempt $i)"
        break
    fi
    echo "  Waiting for containerd API... (attempt $i/30)"
    sleep 2
done
ctr snapshots --snapshotter overlayfs ls >/dev/null || echo "WARNING: snapshotter not ready"

systemctl start docker
systemctl enable docker containerd

# Phase G: Verification
echo ""
echo "=== Verification ==="

FAILURES=0

echo "New versions:"
docker version
containerd --version

echo ""
echo "Package verification:"
rpm -q docker-ce docker-ce-cli containerd.io

echo ""
echo "Asserting expected versions:"
assert_pkg() {
    local pkg="$1" want="$2" got
    got=$(rpm -q "$pkg" --queryformat '%{VERSION}' 2>/dev/null || echo absent)
    if [ "$got" = "$want" ]; then
        echo "  OK   $pkg $got"
    else
        echo "  FAIL $pkg is $got, expected $want"
        FAILURES=$((FAILURES + 1))
    fi
}

assert_pkg docker-ce             29.8.0
assert_pkg docker-ce-cli         29.8.0
assert_pkg containerd.io         2.3.4
assert_pkg docker-buildx-plugin  0.37.0
assert_pkg docker-compose-plugin 5.5.1

# Config preservation is the single most important behavioural change in
# upgrade-docker.sh v2.0.0, so it is a FAILURE here, not a note. (The dnf path
# this script exercises does not rewrite the config either, so a diff means
# something genuinely unexpected happened.)
echo ""
echo "containerd config preserved across upgrade:"
if [ -f /root/config.toml.before ]; then
    if cmp -s /root/config.toml.before /etc/containerd/config.toml; then
        echo "  OK   config.toml is byte-identical to pre-upgrade"
    else
        echo "  FAIL config.toml changed - diff follows"
        diff -u /root/config.toml.before /etc/containerd/config.toml || true
        FAILURES=$((FAILURES + 1))
    fi
else
    echo "  FAIL no pre-upgrade config was captured - cannot verify preservation"
    FAILURES=$((FAILURES + 1))
fi

echo ""
echo "Testing DNS resolution on custom bridge:"
docker start test-dns 2>/dev/null || true
if docker exec test-dns nslookup google.com; then
    echo "  OK   DNS resolution works"
else
    echo "  FAIL DNS issue on custom bridge"
    FAILURES=$((FAILURES + 1))
fi

echo ""
echo "Testing existing containers survived the upgrade:"
docker ps -a
docker start test-nginx 2>/dev/null || true
sleep 3
# -f so an HTTP error is a failure, and no pipe: piping into `head` would make
# this report head's exit status, so a completely failed request printed "OK".
if curl -fsS -o /dev/null --max-time 10 http://localhost:18080/; then
    echo "  OK   nginx responds on the published port"
else
    echo "  FAIL nginx did not respond"
    FAILURES=$((FAILURES + 1))
fi

# Cleanup
docker rm -f test-nginx test-dns 2>/dev/null || true
docker network rm custom-bridge 2>/dev/null || true

echo ""
echo "=========================================="
if [ "$FAILURES" -eq 0 ]; then
    echo "SIMULATION PASSED"
else
    echo "SIMULATION FAILED: $FAILURES check(s) failed"
fi
echo "=========================================="
echo ""
echo "REMINDER: this exercised the dnf path, not upgrade-docker.sh's"
echo "rpm -Uvh path. Run upgrade-docker.sh separately to test that."
echo "=========================================="

exit "$FAILURES"

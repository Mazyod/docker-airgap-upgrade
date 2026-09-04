#!/bin/bash
# shellcheck disable=SC2016,SC1091  # single-quoted VM commands must expand INSIDE the VM
# tests/vm/bootstrap-vm.sh
# Build the "S1" test baseline: a RHEL-like node running exactly what the
# production cluster runs today, with a relocated containerd root and real data
# on it, ready for upgrade-docker.sh to be run against for real.
#
# Idempotent-ish: pass --recreate to destroy and rebuild from scratch.
#
# What this produces (S1 in docs/TEST-PLAN.md):
#   - Rocky Linux (RHEL rebuild), x86_64, systemd as PID 1
#   - docker-ce 29.1.5 / containerd.io 2.2.1 / buildx 0.30.1 / compose 5.0.1
#   - containerd root relocated to /data/containerd on a SEPARATE XFS
#     filesystem with ftype=1, backed by a loopback image mounted through an
#     ordered systemd mount unit
#   - a representative /etc/docker/daemon.json (registry mirror, log opts)
#   - a pulled image, a named container, and a volume holding a canary file
#   - a manifest of all of the above, for the assertions in tier2-run.sh
#
# The relocated root is the point. It is the exact configuration that the
# previous script version would have destroyed, and it cannot be tested any
# other way than by building it and running the real upgrade over it.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source ./lib.sh

RECREATE=false
[ "${1:-}" = "--recreate" ] && RECREATE=true

need_backend

REPO_DIR="$HARNESS_REPO_DIR"

echo "backend: $HARNESS_BACKEND"

if vm_exists && [ "$RECREATE" = true ]; then
    echo "Deleting existing VM '$VM_NAME'..."
    vm_delete
fi

if ! vm_exists; then
    vm_create
else
    echo "Reusing existing VM '$VM_NAME'."
    vm_wake
fi

echo ""
echo "=== Environment ==="
vm 'cat /etc/os-release | grep -E "^(NAME|VERSION)=" | tr "\n" " "; echo
echo "rpm %rhel : $(rpm -E %rhel)"
echo "arch      : $(uname -m)"
echo "init      : $(ps -p 1 -o comm=)"
echo "systemd   : $(systemctl --version | head -1)"'

echo ""
echo "=== Installing the $BASELINE_DOCKER baseline ==="
vm "set -e
dnf install -y -q dnf-plugins-core xfsprogs >/dev/null 2>&1 || true
if [ ! -f /etc/yum.repos.d/docker-ce.repo ]; then
    dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo >/dev/null 2>&1
fi
dnf install -y -q \
    docker-ce-$BASELINE_DOCKER docker-ce-cli-$BASELINE_DOCKER \
    containerd.io-$BASELINE_CONTAINERD \
    docker-buildx-plugin-$BASELINE_BUILDX docker-compose-plugin-$BASELINE_COMPOSE \
    >/dev/null 2>&1
rpm -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

echo ""
echo "=== Relocated containerd root on a separate XFS (ftype=1) ==="
vm "systemctl stop docker docker.socket >/dev/null 2>&1 || true
systemctl stop containerd >/dev/null 2>&1 || true
sleep 2"

ensure_relocated_mount

vm "set -e
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i \"s|^root = .*|root = '$RELOCATED_ROOT'|\" /etc/containerd/config.toml

mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  \"registry-mirrors\": [\"https://mirror.internal.example.com\"],
  \"log-driver\": \"json-file\",
  \"log-opts\": {\"max-size\": \"10m\"}
}
EOF

findmnt --target /data | tail -1
xfs_info /data | grep -o 'ftype=[0-9]'
grep '^root' /etc/containerd/config.toml"

# Refuse to build a baseline on a filesystem that is not the separate XFS.
# Without this the canary data lands on a shadow directory in the guest's own
# root filesystem and every relocated-root assertion downstream is theatre.
require_relocated_xfs

echo ""
echo "=== Starting services on the relocated root ==="
vm 'set -e
systemctl enable --now containerd >/dev/null 2>&1
for i in $(seq 1 30); do ctr version >/dev/null 2>&1 && break; sleep 2; done
ctr snapshots --snapshotter overlayfs ls >/dev/null 2>&1 || { echo "snapshotter unusable"; exit 1; }
systemctl enable --now docker >/dev/null 2>&1
sleep 4
echo "containerd: $(systemctl is-active containerd)  docker: $(systemctl is-active docker)"
docker version --format "server {{.Server.Version}}"'

echo ""
echo "=== Creating canary data ON the relocated root ==="
vm "set -e
docker pull -q alpine:3.19 >/dev/null 2>&1
docker volume inspect testvol >/dev/null 2>&1 || docker volume create testvol >/dev/null
if ! docker inspect survivor >/dev/null 2>&1; then
    docker run -d --name survivor -v testvol:/data alpine:3.19 sleep 100000 >/dev/null
    docker exec survivor sh -c 'echo VOLUME-CANARY-DATA > /data/canary.txt'
fi
docker network inspect custom-bridge >/dev/null 2>&1 || docker network create custom-bridge >/dev/null"

echo ""
echo "=== Restart regression check (hard precondition) ==="
./preflight-host.sh

echo ""
echo "=== Writing baseline manifest to $MANIFEST ==="
vm "mkdir -p /root/vmtests"
stage_manifest_writer
vm "/tmp/vm-write-manifest.sh $MANIFEST"

echo ""
echo "=== Staging repo scripts into the VM ==="
# vm_cp_verified, not a bare `cp`: it compares each staged file's digest against
# this checkout's, so a guest reading some other tree at the same absolute path
# stops the run here instead of producing product failures about code nobody
# wrote. It exits non-zero, and this script runs under set -e.
vm "rm -rf /root/scripts"
vm_cp_verified /root/scripts "$REPO_DIR"/*.sh
vm "chmod +x /root/scripts/*.sh
ls /root/scripts"

echo ""
echo "=========================================="
echo "BASELINE (S1) READY on VM '$VM_NAME' (backend: $HARNESS_BACKEND)"
echo "=========================================="
echo "Next:"
echo "  tests/vm/build-bundle.sh    # run the real download script inside the VM"
echo "  tests/vm/tier2-run.sh       # execute the Tier 2 cases"
echo "  tests/vm/reset-baseline.sh  # return to S1 between destructive tests"
echo "  tests/vm/teardown-vm.sh     # delete the machine"

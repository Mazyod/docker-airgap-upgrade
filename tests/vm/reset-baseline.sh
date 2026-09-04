#!/bin/bash
# shellcheck disable=SC2016,SC1091  # single-quoted VM commands must expand INSIDE the VM
# tests/vm/reset-baseline.sh
# Return the VM to the S1 baseline between destructive tests.
#
# Neither backend has snapshots, so this reconstructs S1 rather than restoring
# it: packages back to the baseline versions, containerd config regenerated
# with the relocated root, daemon.json restored, services healthy, canary data
# recreated if missing. Nothing here touches a hypervisor primitive, so it is
# identical on both backends.
#
# Cheaper than recreating the machine (seconds vs minutes). If you suspect the
# VM has drifted in a way this does not cover, use:
#   tests/vm/bootstrap-vm.sh --recreate

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source ./lib.sh

require_vm

echo "=== Resetting VM '$VM_NAME' to the S1 baseline ==="

vm "set -e
systemctl stop docker docker.socket >/dev/null 2>&1 || true
systemctl stop containerd >/dev/null 2>&1 || true
sleep 2

# Packages back to baseline. --allowerasing/downgrade handles either direction.
dnf install -y -q --allowerasing \
    docker-ce-$BASELINE_DOCKER docker-ce-cli-$BASELINE_DOCKER \
    containerd.io-$BASELINE_CONTAINERD \
    docker-buildx-plugin-$BASELINE_BUILDX docker-compose-plugin-$BASELINE_COMPOSE \
    >/dev/null 2>&1 || \
dnf downgrade -y -q --allowerasing \
    docker-ce-$BASELINE_DOCKER docker-ce-cli-$BASELINE_DOCKER \
    containerd.io-$BASELINE_CONTAINERD \
    docker-buildx-plugin-$BASELINE_BUILDX docker-compose-plugin-$BASELINE_COMPOSE \
    >/dev/null 2>&1
"

# The relocated root must be mounted, through the ordered systemd mount unit,
# before containerd starts. A bare `mount -o loop` here would not survive a
# guest restart -- see lib.sh's ensure_relocated_mount().
ensure_relocated_mount

vm "set -e
containerd config default > /etc/containerd/config.toml
sed -i \"s|^root = .*|root = '$RELOCATED_ROOT'|\" /etc/containerd/config.toml

cat > /etc/docker/daemon.json <<'EOF'
{
  \"registry-mirrors\": [\"https://mirror.internal.example.com\"],
  \"log-driver\": \"json-file\",
  \"log-opts\": {\"max-size\": \"10m\"}
}
EOF

systemctl start containerd
for i in \$(seq 1 30); do ctr version >/dev/null 2>&1 && break; sleep 2; done
systemctl start docker
sleep 3

# Recreate canary data if a test destroyed it.
docker volume inspect testvol >/dev/null 2>&1 || docker volume create testvol >/dev/null
if ! docker inspect survivor >/dev/null 2>&1; then
    docker pull -q alpine:3.19 >/dev/null 2>&1
    docker run -d --name survivor -v testvol:/data alpine:3.19 sleep 100000 >/dev/null
    docker exec survivor sh -c 'echo VOLUME-CANARY-DATA > /data/canary.txt'
fi
docker start survivor >/dev/null 2>&1 || true

# Restore a pristine package directory from the bundle.
rm -rf /opt/docker-offline
tar xzf /opt/docker-upgrade-bundle.tar.gz -C /opt/


echo 'reset complete:'
rpm -q docker-ce containerd.io | sed 's/^/  /'
grep '^root' /etc/containerd/config.toml | sed 's/^/  /'
echo \"  docker: \$(systemctl is-active docker)  containerd: \$(systemctl is-active containerd)\""

# Refuse to declare S1 restored on anything but the separate XFS -- a reset
# onto a shadow directory would rebuild the canary data in the wrong place and
# hand back a green run built on a lie.
require_relocated_xfs

echo ""
echo "=== Refreshing baseline manifest ==="
stage_manifest_writer
vm "/tmp/vm-write-manifest.sh $MANIFEST"

echo ""
echo "VM is back at S1."

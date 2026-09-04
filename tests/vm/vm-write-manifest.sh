#!/bin/bash
# tests/vm/vm-write-manifest.sh
# Runs INSIDE the test VM. Records the pre-upgrade truth that tier2-run.sh
# asserts against afterwards.
#
# This lives in its own file rather than inline in bootstrap-vm.sh /
# reset-baseline.sh because those pass their body through `bash -c` from macOS,
# which meant three levels of quote escaping around the config parser -- and
# that is exactly where it broke (a sed expression that silently produced an
# empty CONTAINERD_ROOT, which then made every 2.4 assertion compare against
# the empty string and look like a product failure).
#
# Usage (inside the VM): ./vm-write-manifest.sh /root/baseline-manifest.txt

set -euo pipefail

OUT="${1:-/root/baseline-manifest.txt}"
CONF="/etc/containerd/config.toml"

# Same top-level-only parse the upgrade script uses: stop at the first
# [section] header, tolerate indentation and either quoting style.
containerd_root() {
    awk '/^[[:space:]]*\[/ { exit } { print }' "$CONF" 2>/dev/null \
        | sed -n "s/^[[:space:]]*root[[:space:]]*=[[:space:]]*['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}.*/\1/p" \
        | head -1
}

# Count snapshots under a containerd root, to prove which root is LIVE.
count_snapshots() {
    find "$1/io.containerd.snapshotter.v1.overlayfs/snapshots" \
        -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '
}

ROOT=$(containerd_root)
ROOT=${ROOT:-/var/lib/containerd}

{
    echo "IMAGE_ID=$(docker image inspect alpine:3.19 --format '{{.Id}}')"
    echo "CONTAINER_ID=$(docker inspect survivor --format '{{.Id}}')"
    echo "CANARY=$(docker exec survivor cat /data/canary.txt 2>/dev/null || echo MISSING)"
    echo "CONTAINERD_CONF_SHA=$(sha256sum "$CONF" | cut -d' ' -f1)"
    echo "DAEMON_JSON_SHA=$(sha256sum /etc/docker/daemon.json | cut -d' ' -f1)"
    echo "CONTAINERD_ROOT=$ROOT"
    echo "ROOT_MOUNT=$(findmnt -n -o SOURCE --target "$ROOT" 2>/dev/null || echo unknown)"
    echo "ROOT_FSTYPE=$(findmnt -n -o FSTYPE --target "$ROOT" 2>/dev/null || echo unknown)"
    echo "ROOT_SNAPSHOTS=$(count_snapshots "$ROOT")"
    echo "VARLIB_SNAPSHOTS=$(count_snapshots /var/lib/containerd)"
    echo "DOCKER_VERSION=$(rpm -q docker-ce --queryformat '%{VERSION}')"
    echo "CONTAINERD_VERSION=$(rpm -q containerd.io --queryformat '%{VERSION}')"
} > "$OUT"

# Refuse to write a manifest with an empty key -- an empty value downstream
# turns every assertion into a comparison against "" and hides the real result.
if grep -qE '^[A-Z_]+=$' "$OUT"; then
    echo "ERROR: manifest has empty keys:" >&2
    grep -nE '^[A-Z_]+=$' "$OUT" >&2
    exit 1
fi

# MISSING is the CANARY line's own failure marker, and it is NOT empty, so the
# check above waves it through. A manifest recording MISSING would describe a
# baseline whose volume data is already gone, which is not a baseline.
if grep -qx 'CANARY=MISSING' "$OUT"; then
    echo "ERROR: the canary container did not yield /data/canary.txt." >&2
    echo "       docker inspect survivor:" >&2
    docker inspect survivor --format '  state={{.State.Status}} started={{.State.StartedAt}}' >&2 2>&1 || true
    exit 1
fi

cat "$OUT"

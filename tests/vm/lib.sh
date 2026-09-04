#!/bin/bash
# shellcheck disable=SC2034  # version constants are consumed by scripts that source this
# tests/vm/lib.sh
# Shared helpers for the VM test harness. Source this; do not run it.
#
# The harness drives a Rocky Linux 9 guest, which is a RHEL rebuild: `rpm -E
# %rhel` returns the right major, the packages are the same el9 builds, and
# systemd is PID 1. It is NOT RHEL, and it is not bare metal -- see
# tests/vm/README.md for exactly what that does and does not prove.
#
# TWO BACKENDS provide that guest:
#
#   orb     an OrbStack Linux machine on macOS (the original)
#   docker  a privileged Rocky 9 systemd container on a Linux host
#
# Everything above the backend is identical, because the backend contract is
# small. The CORE is six operations:
#
#   need_backend   the backend's tooling is present and usable, or exit 1
#   vm_exists      does a guest named $VM_NAME exist (running or not)
#   vm             run a command in the guest as root; status is preserved
#   vm_try         same, but never fails the caller
#   vm_create      create and start the guest
#   vm_delete      destroy the guest and everything it allocated
#
# Two further operations exist for the harness's own lifecycle code and are NOT
# part of that core: vm_wake (make an existing guest usable) and vm_restart
# (used only by preflight-host.sh). Both backends implement all eight.
#
# NOTE for future edits: CLAUDE.md and tests/vm/README.md used to claim the port
# surface was FOUR helpers. It never was -- create and delete were raw hypervisor
# calls sitting in bootstrap-vm.sh and teardown-vm.sh, outside any helper.

HARNESS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_REPO_DIR="$(cd "$HARNESS_LIB_DIR/../.." && pwd)"

VM_NAME="${VM_NAME:-rhel9test}"
VM_DISTRO="${VM_DISTRO:-rocky}"
VM_RELEASE="${VM_RELEASE:-9}"
VM_ARCH="${VM_ARCH:-amd64}"

# The versions under test. Keep in sync with the scripts -- see CLAUDE.md.
BASELINE_DOCKER="29.1.5"
BASELINE_CONTAINERD="2.2.1"
BASELINE_BUILDX="0.30.1"
BASELINE_COMPOSE="5.0.1"
TARGET_DOCKER="29.7.2"
TARGET_CONTAINERD="2.3.3"
TARGET_BUILDX="0.36.1"
TARGET_COMPOSE="5.5.0"

# Where the relocated containerd root lives, and the loopback image backing it.
# A backend may override LOOP_IMG -- the container backend keeps the 3 GB image
# on a named volume rather than in the container's writable layer.
RELOCATED_ROOT="/data/containerd"
LOOP_IMG="/var/data.img"
MANIFEST="/root/baseline-manifest.txt"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'

PASS=0; FAIL=0; SKIP=0
ok()   { printf '  %sPASS%s %s\n' "$GREEN" "$NC" "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  %sFAIL%s %s\n' "$RED" "$NC" "$1";   FAIL=$((FAIL + 1)); }
skip() { printf '  %sSKIP%s %s\n' "$YELLOW" "$NC" "$1"; SKIP=$((SKIP + 1)); }
head_(){ printf '\n== %s ==\n' "$1"; }

#############################################
# Backend selection
#############################################
# HARNESS_BACKEND=auto|orb|docker. Auto prefers OrbStack when it is installed,
# because on a Mac that is the only thing that works; otherwise it falls back
# to a reachable Docker daemon. Set the variable explicitly to override.
HARNESS_BACKEND="${HARNESS_BACKEND:-auto}"

if [ "$HARNESS_BACKEND" = "auto" ]; then
    if command -v orbctl >/dev/null 2>&1; then
        HARNESS_BACKEND="orb"
    elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        HARNESS_BACKEND="docker"
    elif command -v docker >/dev/null 2>&1; then
        echo "ERROR: found the docker CLI but the daemon is not reachable, and" >&2
        echo "       orbctl is not installed. The Tier 2 harness needs one of:" >&2
        echo "         - macOS + OrbStack   (brew install orbstack)" >&2
        echo "         - Linux + a running Docker daemon you can reach" >&2
        echo "       Set HARNESS_BACKEND=orb|docker to override auto-detection." >&2
        exit 1
    else
        echo "ERROR: no Tier 2 backend available. The harness needs one of:" >&2
        echo "         - macOS + OrbStack   (brew install orbstack)" >&2
        echo "         - Linux + a running Docker daemon you can reach" >&2
        echo "       Set HARNESS_BACKEND=orb|docker to override auto-detection." >&2
        exit 1
    fi
fi

case "$HARNESS_BACKEND" in
    orb|docker) ;;
    *) echo "ERROR: HARNESS_BACKEND='$HARNESS_BACKEND' is not 'orb' or 'docker'." >&2; exit 1 ;;
esac

# shellcheck source=backend-orb.sh
# shellcheck source=backend-docker.sh
source "$HARNESS_LIB_DIR/backend-$HARNESS_BACKEND.sh"

# Backwards-compatible name. The old harness called this need_orbctl; it is
# kept so an out-of-tree caller does not break, but new code uses need_backend.
need_orbctl() { need_backend; }

require_vm() {
    need_backend
    if ! vm_exists; then
        echo "ERROR: VM '$VM_NAME' does not exist. Run tests/vm/bootstrap-vm.sh first." >&2
        exit 1
    fi
    vm_wake >/dev/null 2>&1 || true
}

#############################################
# The relocated root
#############################################
# Establish /data as a real, separate, loop-backed XFS filesystem -- and do it
# through a systemd MOUNT UNIT rather than a bare `mount -o loop`.
#
# The unit is what makes the mount survive a guest restart. A bare mount does
# not: the mount namespace goes away, the 3 GB backing file does not, and
# systemd then starts containerd on an EMPTY shadow /data/containerd directory
# while reporting it active. Zero snapshots, no images, canary container dead --
# and every Tier 2 assertion failing for a reason that has nothing to do with
# the scripts under test.
#
# Installed on BOTH backends, from one code path, for three reasons: the hazard
# is not specific to containers (an OrbStack machine that reboots loses a bare
# mount too), a production node with a relocated containerd root would carry an
# fstab entry anyway so this makes the baseline more faithful, and one code path
# cannot drift against itself.
ensure_relocated_mount() {
    local loop_dir
    loop_dir="$(dirname "$LOOP_IMG")"

    vm "set -e
mkdir -p $loop_dir /data $RELOCATED_ROOT
[ -f $LOOP_IMG ] || dd if=/dev/zero of=$LOOP_IMG bs=1M count=3072 status=none
blkid $LOOP_IMG >/dev/null 2>&1 || mkfs.xfs -q -n ftype=1 $LOOP_IMG

mkdir -p /etc/systemd/system/containerd.service.d
cat > /etc/systemd/system/data.mount <<'UNIT_EOF'
[Unit]
Description=Harness XFS filesystem for the relocated containerd root
Before=containerd.service

[Mount]
What=$LOOP_IMG
Where=/data
Type=xfs
Options=loop

[Install]
WantedBy=local-fs.target
UNIT_EOF

cat > /etc/systemd/system/containerd.service.d/10-harness-mount.conf <<'DROPIN_EOF'
[Unit]
RequiresMountsFor=$RELOCATED_ROOT
DROPIN_EOF

systemctl daemon-reload
systemctl enable data.mount >/dev/null 2>&1 || true
findmnt -n -o TARGET /data >/dev/null 2>&1 || systemctl start data.mount
mkdir -p $RELOCATED_ROOT"
}

# Hard precondition: the relocated root must actually be on the separate XFS.
#
# If it is not, everything downstream is theatre -- the canary data gets written
# to a shadow directory on the guest's own root filesystem and the whole S1
# premise is a lie. Refuse rather than produce a green run built on it.
require_relocated_xfs() {
    local fs src
    fs=$(vm_try "findmnt -n -o FSTYPE --target $RELOCATED_ROOT 2>/dev/null" | tr -d '\r' | tail -1)
    src=$(vm_try "findmnt -n -o SOURCE --target $RELOCATED_ROOT 2>/dev/null" | tr -d '\r' | tail -1)
    if [ "$fs" != "xfs" ]; then
        echo "" >&2
        echo "${RED}ERROR${NC}: $RELOCATED_ROOT is on '${fs:-<unknown>}' (source '${src:-<unknown>}'), not xfs." >&2
        echo "       The S1 baseline REQUIRES a separate XFS filesystem there. Without it," >&2
        echo "       containerd is running on a shadow directory and every relocated-root" >&2
        echo "       assertion is meaningless." >&2
        echo "       Fix:  tests/vm/reset-baseline.sh   (or bootstrap-vm.sh --recreate)" >&2
        exit 1
    fi
    echo "  relocated root: $RELOCATED_ROOT on $src ($fs)"
}

# Stage the in-guest manifest writer, and VERIFY it landed.
#
# Both backends expose the repo inside the guest at its identical absolute
# path, so this is a plain `cp` rather than a push. OrbStack's `orbctl push` is
# unusable here: its destination resolves relative to the Linux user's HOME, so
# an absolute /tmp/... destination is silently discarded while it still exits 0.
# That is why the landed-file check below exists rather than a status check.
stage_manifest_writer() {
    vm "cp \"$HARNESS_LIB_DIR/vm-write-manifest.sh\" /tmp/vm-write-manifest.sh" >/dev/null 2>&1 || true
    if ! vm "test -f /tmp/vm-write-manifest.sh" >/dev/null 2>&1; then
        echo "ERROR: could not stage vm-write-manifest.sh into the VM." >&2
        exit 1
    fi
    vm "chmod +x /tmp/vm-write-manifest.sh" >/dev/null 2>&1
}

# Assert a command in the VM prints exactly the expected string.
assert_vm_eq() {
    local label="$1" cmd="$2" want="$3" got
    got=$(vm_try "$cmd" | tr -d '\r' | tail -1)
    if [ "$got" = "$want" ]; then
        ok "$label"
    else
        bad "$label (got '$got', want '$want')"
    fi
}

# Assert a command in the VM succeeds.
assert_vm_ok() {
    local label="$1" cmd="$2"
    if vm_try "$cmd >/dev/null 2>&1; echo \$?" | tail -1 | grep -qx 0; then
        ok "$label"
    else
        bad "$label"
    fi
}

# Assert a command in the VM FAILS (for rejection tests).
assert_vm_fails() {
    local label="$1" cmd="$2" rc
    rc=$(vm_try "$cmd >/dev/null 2>&1; echo \$?" | tail -1)
    if [ "$rc" != "0" ]; then
        ok "$label (exit $rc)"
    else
        bad "$label (expected non-zero, got 0)"
    fi
}

summary() {
    printf '\n==========================================\n'
    printf 'passed %d, failed %d, skipped %d\n' "$PASS" "$FAIL" "$SKIP"
    printf '==========================================\n'
    [ "$FAIL" -gt 0 ] && return 1
    return 0
}

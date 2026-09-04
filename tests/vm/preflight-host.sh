#!/bin/bash
# shellcheck disable=SC2016,SC1091  # single-quoted VM commands must expand INSIDE the VM
# tests/vm/preflight-host.sh
# Prove that the relocated containerd root survives a guest RESTART.
#
# WHY THIS EXISTS
#
# The S1 baseline's whole point is that containerd's root lives on a separate
# XFS filesystem. A guest restart tears down the mount namespace; the 3 GB
# backing image does not go away with it. If nothing orders the mount before
# containerd, systemd starts containerd on an EMPTY shadow /data/containerd
# directory in the guest's own root filesystem -- and containerd reports itself
# `active` while doing it. Zero snapshots, no images, the canary container dead.
#
# That is the same "silently repointing a node at an empty root" hazard that
# upgrade-docker.sh phase 6 and negative-control.sh exist to detect, except
# manufactured by the test harness rather than by the product. A Tier 2 run in
# that state produces a screenful of confident-looking failures that say nothing
# about the scripts, and reset-baseline.sh would happily rebuild the canary data
# ON the shadow root and hand back a green run built on a lie.
#
# lib.sh's ensure_relocated_mount() installs a systemd mount unit and a
# containerd.service drop-in (RequiresMountsFor) to prevent exactly this.
# This script is the test of that guard, and bootstrap-vm.sh runs it, so the
# baseline is never declared ready without it having passed.
#
# It restarts the guest, so it is mildly disruptive but not destructive.
#
# Usage:
#   tests/vm/preflight-host.sh

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source ./lib.sh

require_vm

head_ "Restart regression: the relocated root must come back on XFS"

before_src=$(vm_try "findmnt -n -o SOURCE --target $RELOCATED_ROOT" | tr -d '\r' | tail -1)
echo "  before restart: $RELOCATED_ROOT on ${before_src:-<unmounted>}"

echo "  restarting guest '$VM_NAME' (backend: $HARNESS_BACKEND)..."
if ! vm_restart; then
    bad "guest did not come back from a restart"
    summary
    exit 1
fi

fs=$(vm_try "findmnt -n -o FSTYPE --target $RELOCATED_ROOT" | tr -d '\r' | tail -1)
src=$(vm_try "findmnt -n -o SOURCE --target $RELOCATED_ROOT" | tr -d '\r' | tail -1)

if [ "$fs" = "xfs" ]; then
    ok "relocated root is back on xfs after restart ($src)"
else
    bad "relocated root came back on '${fs:-<none>}' (source '${src:-<none>}'), not xfs"
    echo "       This is the shadow-root hazard. Check that data.mount is enabled" >&2
    echo "       and that containerd.service has the RequiresMountsFor drop-in." >&2
fi

assert_vm_eq "data.mount is active" "systemctl is-active data.mount" "active"

# The ordering, not just the end state: containerd must depend on the mount.
# Distinguish "containerd is not installed yet", which is a legitimate skip,
# from "containerd is installed and has no such dependency", which is the
# defect -- both look the same if you only grep the property.
if vm_try "systemctl cat containerd >/dev/null 2>&1; echo \$?" | tr -d '\r' | tail -1 | grep -qx 0; then
    if vm_try "systemctl show containerd -p RequiresMountsFor" | tr -d '\r' | grep -q "$RELOCATED_ROOT"; then
        ok "containerd.service requires the $RELOCATED_ROOT mount"
    else
        bad "containerd.service has NO RequiresMountsFor=$RELOCATED_ROOT -- nothing orders the mount before it"
    fi
else
    skip "containerd.service is not installed yet (no RequiresMountsFor to check)"
fi

# containerd must be usable, and it must be usable ON the relocated root.
if vm_try "systemctl is-active containerd" | tr -d '\r' | tail -1 | grep -qx active; then
    ok "containerd is active after restart"
    snaps=$(vm_try "ls -A $RELOCATED_ROOT/io.containerd.snapshotter.v1.overlayfs/snapshots 2>/dev/null | wc -l" | tr -d '\r' | tail -1)
    shadow=$(vm_try "ls -A /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots 2>/dev/null | wc -l" | tr -d '\r' | tail -1)
    if [ "${snaps:-0}" -gt 0 ]; then
        ok "snapshots are on the relocated root (${snaps}), not a shadow copy (/var/lib/containerd: ${shadow:-0})"
    else
        bad "relocated root has NO snapshots after restart -- containerd is on another root"
    fi
else
    skip "containerd is not running yet (nothing to check on the relocated root)"
fi

# Bring the canary container back up: nothing inside the guest restarts it, and
# vm-write-manifest.sh needs to exec into it.
vm_try "docker start survivor >/dev/null 2>&1" >/dev/null 2>&1

summary

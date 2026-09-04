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

# The FULL S1 precondition, not a weaker re-probe of two of its five facts.
#
# This used to check FSTYPE and `is-active data.mount` by hand, which accepts a
# hand-made `mount -o loop` of some other image: systemd ADOPTS any mount at
# /data into data.mount and reports it active. require_relocated_xfs is the one
# definition of the precondition -- mount point, filesystem, a /dev/loop*
# source, that the source is backed by THIS harness image, is-active AND
# is-enabled -- and is-enabled is the half that says the mount would survive the
# NEXT restart too, which is exactly what this script is about. It names every
# fact that failed and exits; nothing below it is meaningful without it.
require_relocated_xfs
ok "relocated root is back on the separate XFS after restart"

# From here on, containerd being absent or down is a DEFECT, not a skip.
# bootstrap-vm.sh installs it, enables it and starts it before this script
# runs, and this script's whole purpose is to prove the restart did not break
# that. A skip here would silently pass on the exact regression being hunted.

# The ordering, not just the end state: containerd must depend on the mount.
if ! vm_try "systemctl cat containerd >/dev/null 2>&1; echo \$?" | tr -d '\r' | tail -1 | grep -qx 0; then
    bad "containerd.service is not installed -- the baseline is incomplete"
elif vm_try "systemctl show containerd -p RequiresMountsFor" | tr -d '\r' | grep -q "$RELOCATED_ROOT"; then
    ok "containerd.service requires the $RELOCATED_ROOT mount"
else
    bad "containerd.service has NO RequiresMountsFor=$RELOCATED_ROOT -- nothing orders the mount before it"
fi

# containerd must be usable, and it must be usable ON the relocated root.
if vm_try "systemctl is-active containerd" | tr -d '\r' | tail -1 | grep -qx active; then
    ok "containerd is active after restart"
else
    bad "containerd is not active after restart"
fi

# containerd's own view of the effective root, as its parser resolves it --
# including the in-memory v3 -> v4 migration -- rather than a grep of the TOML.
# This is the same assertion config-version-check.sh's B7 makes. A snapshot
# count alone would not catch a root that parsed to the wrong path.
assert_vm_eq "containerd's LIVE root is still $RELOCATED_ROOT" \
    "containerd config dump 2>/dev/null | awk '/^[[:space:]]*\\[/ { exit } { print }' | sed -n \"s/^[[:space:]]*root[[:space:]]*=[[:space:]]*['\\\"]\\{0,1\\}\\([^'\\\"]*\\)['\\\"]\\{0,1\\}.*/\\1/p\" | head -1" \
    "$RELOCATED_ROOT"

# systemd reports containerd active before its snapshotter is usable, so
# exercise the snapshotter rather than trusting the unit state.
assert_vm_ok "ctr responds and the overlayfs snapshotter is usable after restart" \
    "ctr version && ctr snapshots --snapshotter overlayfs ls"

snaps=$(vm_try "ls -A $RELOCATED_ROOT/io.containerd.snapshotter.v1.overlayfs/snapshots 2>/dev/null | wc -l" | tr -d '\r' | tail -1)
shadow=$(vm_try "ls -A /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots 2>/dev/null | wc -l" | tr -d '\r' | tail -1)
if [ "${snaps:-0}" -gt 0 ]; then
    ok "snapshots are on the relocated root (${snaps}), not a shadow copy (/var/lib/containerd: ${shadow:-0})"
else
    bad "relocated root has NO snapshots after restart -- containerd is on another root"
fi

# dockerd, not just containerd. Nothing else here would notice if the restart
# left the engine down.
assert_vm_eq "docker is active after restart" "systemctl is-active docker" "active"

# And the canary, which is the only assertion that proves the data on the
# relocated root is still REACHABLE rather than merely present as a directory
# count. Starting `survivor` is part of the assertion, not a side effect quietly
# swallowed: nothing inside the guest restarts it after a reboot, and
# vm-write-manifest.sh execs into it immediately afterwards.
assert_vm_eq "canary container restarts and its volume data is intact" \
    "docker start survivor >/dev/null 2>&1; docker exec survivor cat /data/canary.txt" \
    "VOLUME-CANARY-DATA"

summary

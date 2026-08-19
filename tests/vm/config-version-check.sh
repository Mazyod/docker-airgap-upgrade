#!/bin/bash
# shellcheck disable=SC2016,SC1091  # single-quoted VM commands must expand INSIDE the VM
# tests/vm/config-version-check.sh
# The containerd config-version boundary introduced by containerd.io 2.2.1 -> 2.3.3.
#
# WHY THIS EXISTS
#
# Every previous round of this upgrade stayed inside one containerd config
# version, so "phase 6 verifies, it does not rewrite" only had to protect a
# relocated `root`. Moving to 2.3.3 raises the current config version from 3 to
# 4, which adds a second, sharper hazard in the ROLLBACK direction:
#
#   containerd 2.3.3 reads a version = 3 config happily.
#   containerd 2.2.1 refuses a version = 4 config outright, and does not start.
#
# So a node that ends up with a v4 config on disk is one emergency rollback away
# from a dead runtime. Nothing in the upgrade writes a v4 file -- this script
# proves that, rather than assuming it -- and rollback-docker.sh phase 0c
# refuses to act when a v4 file is present without a usable backup.
#
# WHAT THIS ASSERTS -- all of it measured, none of it inferred from release
# notes. Section B was written only after observing the real behaviour.
#
# Requires the S1 baseline and a built bundle:
#   tests/vm/bootstrap-vm.sh
#   tests/vm/build-bundle.sh
#
# This script is DESTRUCTIVE. Run tests/vm/reset-baseline.sh afterwards.
#
# Usage:
#   tests/vm/config-version-check.sh

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source ./lib.sh

require_vm

CONF="/etc/containerd/config.toml"
WORK="/root/configver"
NEW_CTRD="/opt/docker-offline/rhel9/containerd.io-$TARGET_CONTAINERD-1.el9.x86_64.rpm"
OLD_CTRD="/opt/docker-offline/rollback-rhel9/containerd.io-$BASELINE_CONTAINERD-1.el9.x86_64.rpm"

# The highest config version the BASELINE containerd can load. This is the
# number rollback-docker.sh guards on.
MAX_OLD_CONFIG_VERSION=3

if ! vm "test -f $NEW_CTRD && test -f $OLD_CTRD" >/dev/null 2>&1; then
    echo "ERROR: bundle RPMs not found in the VM. Run tests/vm/build-bundle.sh first." >&2
    exit 1
fi

vm "mkdir -p $WORK" >/dev/null 2>&1

# Read the top-level `version` key out of a TOML file in the VM. Mirrors the
# parser the scripts use: stop at the first [section] so only top-level counts.
conf_version() {
    vm_try "awk '/^[[:space:]]*\\[/ { exit } { print }' '$1' 2>/dev/null \
        | sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p' \
        | head -1" | tr -d '\r' | tail -1
}

#############################################
head_ "A  Baseline facts (containerd $BASELINE_CONTAINERD)"
#############################################

assert_vm_eq "A1 baseline containerd.io is $BASELINE_CONTAINERD" \
    "rpm -q containerd.io --queryformat '%{VERSION}'" "$BASELINE_CONTAINERD"

got=$(conf_version "$CONF")
if [ "$got" = "$MAX_OLD_CONFIG_VERSION" ]; then
    ok "A2 on-disk config is version $MAX_OLD_CONFIG_VERSION"
else
    bad "A2 on-disk config is version '$got', want $MAX_OLD_CONFIG_VERSION"
fi

assert_vm_eq "A3 relocated root is $RELOCATED_ROOT" \
    "awk '/^[[:space:]]*\\[/ { exit } { print }' $CONF | sed -n \"s/^[[:space:]]*root[[:space:]]*=[[:space:]]*['\\\"]\\{0,1\\}\\([^'\\\"]*\\)['\\\"]\\{0,1\\}.*/\\1/p\" | head -1" \
    "$RELOCATED_ROOT"

# `containerd config default` on the OLD binary emits the old version. This is
# the control for C2 below: the same command on the new binary emits v4.
v=$(vm_try "containerd config default 2>/dev/null | sed -n 's/^version[[:space:]]*=[[:space:]]*\\([0-9]*\\).*/\\1/p' | head -1" | tr -d '\r' | tail -1)
if [ "$v" = "$MAX_OLD_CONFIG_VERSION" ]; then
    ok "A4 'containerd config default' on $BASELINE_CONTAINERD emits version $MAX_OLD_CONFIG_VERSION"
else
    bad "A4 'containerd config default' on $BASELINE_CONTAINERD emitted '$v', want $MAX_OLD_CONFIG_VERSION"
fi

vm "cp $CONF $WORK/config.v3.orig && sha256sum $CONF | cut -d' ' -f1 > $WORK/sha.before" >/dev/null 2>&1

#############################################
head_ "B  containerd $TARGET_CONTAINERD reads the v$MAX_OLD_CONFIG_VERSION config without rewriting it"
#############################################

vm "systemctl stop docker docker.socket containerd" >/dev/null 2>&1
vm "rpm -Uvh --force $NEW_CTRD" >/dev/null 2>&1

assert_vm_eq "B1 containerd.io upgraded to $TARGET_CONTAINERD" \
    "rpm -q containerd.io --queryformat '%{VERSION}'" "$TARGET_CONTAINERD"

# The RPM ships config.toml as %config(noreplace). The operator's file must
# survive the transaction byte for byte -- this is the whole basis for "phase 6
# verifies, it does not rewrite".
if vm_try "cmp -s $WORK/config.v3.orig $CONF && echo SAME" | tail -1 | grep -qx SAME; then
    ok "B2 config.toml is byte-identical after the rpm transaction"
else
    bad "B2 config.toml CHANGED during the rpm transaction"
fi

got=$(conf_version "$CONF")
if [ "$got" = "$MAX_OLD_CONFIG_VERSION" ]; then
    ok "B3 on-disk config is still version $MAX_OLD_CONFIG_VERSION"
else
    bad "B3 on-disk config became version '$got'"
fi

vm "systemctl start containerd" >/dev/null 2>&1
vm_try "for i in \$(seq 1 30); do ctr version >/dev/null 2>&1 && break; sleep 2; done" >/dev/null 2>&1

assert_vm_eq "B4 containerd $TARGET_CONTAINERD starts on the v$MAX_OLD_CONFIG_VERSION config" \
    "systemctl is-active containerd" "active"

assert_vm_ok "B5 ctr responds and the overlayfs snapshotter is usable" \
    "ctr version && ctr snapshots --snapshotter overlayfs ls"

# The migration is in-memory and containerd says so. If this message ever stops
# appearing, the assumption behind "nothing is written back" needs re-checking.
if vm_try "journalctl -u containerd --no-pager | grep -c 'Configuration migrated from version $MAX_OLD_CONFIG_VERSION'" | tail -1 | grep -qvx 0; then
    ok "B6 containerd logs the in-memory migration from version $MAX_OLD_CONFIG_VERSION"
else
    bad "B6 no 'Configuration migrated from version $MAX_OLD_CONFIG_VERSION' message in the journal"
fi

# The point of the whole exercise: the relocated root survives the in-memory
# migration. If this regressed, every image and snapshot on the node would
# appear to vanish.
assert_vm_eq "B7 'containerd config dump' still reports the relocated root" \
    "containerd config dump 2>/dev/null | awk '/^[[:space:]]*\\[/ { exit } { print }' | sed -n \"s/^[[:space:]]*root[[:space:]]*=[[:space:]]*['\\\"]\\{0,1\\}\\([^'\\\"]*\\)['\\\"]\\{0,1\\}.*/\\1/p\" | head -1" \
    "$RELOCATED_ROOT"

#############################################
head_ "C  The v4 trap: what must NOT be written to disk"
#############################################

# `containerd config default` on the NEW binary emits v4. This is the command an
# operator is most likely to reach for, and its output is exactly what the
# rollback containerd cannot read.
v=$(vm_try "containerd config default 2>/dev/null | sed -n 's/^version[[:space:]]*=[[:space:]]*\\([0-9]*\\).*/\\1/p' | head -1" | tr -d '\r' | tail -1)
if [ "$v" -gt "$MAX_OLD_CONFIG_VERSION" ] 2>/dev/null; then
    ok "C1 'containerd config default' on $TARGET_CONTAINERD emits version $v (> $MAX_OLD_CONFIG_VERSION)"
else
    bad "C1 expected a version above $MAX_OLD_CONFIG_VERSION from 'containerd config default', got '$v'"
fi

# `containerd config migrate` writes to stdout, not to the file. If it ever
# started writing in place, running it would silently arm the trap.
vm_try "containerd config migrate >/dev/null 2>&1" >/dev/null 2>&1
if vm_try "cmp -s $WORK/config.v3.orig $CONF && echo SAME" | tail -1 | grep -qx SAME; then
    ok "C2 'containerd config migrate' leaves the on-disk config untouched"
else
    bad "C2 'containerd config migrate' MODIFIED the on-disk config"
fi

#############################################
head_ "D  rollback-docker.sh phase 0c refuses a config the rollback containerd cannot load"
#############################################

# Arm the trap the way an operator would, and confirm the guard catches it while
# the node is still healthy. There must be no backup for the guard to fall back
# on, so this is the genuinely unrecoverable case.
vm "rm -rf /root/docker-backup-*" >/dev/null 2>&1
vm "containerd config default > $CONF" >/dev/null 2>&1
vm "systemctl start docker" >/dev/null 2>&1
vm_try "for i in \$(seq 1 15); do systemctl is-active docker | grep -qx active && break; sleep 1; done" >/dev/null 2>&1

armed=$(conf_version "$CONF")
if [ "$armed" -gt "$MAX_OLD_CONFIG_VERSION" ] 2>/dev/null; then
    ok "D1 test setup: on-disk config is now version $armed"
else
    bad "D1 test setup FAILED: config is version '$armed', expected > $MAX_OLD_CONFIG_VERSION"
fi

# ONE invocation, with the exit code carried out in the same stream. Running it
# twice -- output from the first, status from the second -- would measure two
# different executions, and the second would start from whatever state the first
# left behind. That silently breaks the mutation test: with the guard disabled,
# run 1 completes the downgrade and run 2 executes against an already-downgraded
# node, so the exit code and the state assertions would describe different runs.
out=$(vm_try "cd /opt/docker-offline && ./rollback-docker.sh </dev/null 2>&1; echo \"__RC=\$?\"")
rc=$(printf '%s' "$out" | tr -d '\r' | sed -n 's/^__RC=//p' | tail -1)
rc=${rc:-<none>}

if [ "$rc" != "0" ]; then
    ok "D2 rollback-docker.sh exits non-zero (exit $rc)"
else
    bad "D2 rollback-docker.sh exited 0 -- the guard did NOT fire"
fi

if printf '%s' "$out" | grep -q "CONFIG VERSION BLOCKS THIS ROLLBACK"; then
    ok "D3 it names the config version as the reason"
else
    bad "D3 aborted without naming the config version"
    printf '%s\n' "$out" | tail -8 | sed 's/^/       /'
fi

# Fail-closed: refusing must cost nothing. The node has to be exactly as it was.
assert_vm_eq "D4 containerd.io was NOT downgraded" \
    "rpm -q containerd.io --queryformat '%{VERSION}'" "$TARGET_CONTAINERD"
assert_vm_eq "D5 containerd is still running" "systemctl is-active containerd" "active"
assert_vm_eq "D6 docker is still running" "systemctl is-active docker" "active"

# D7-D8 cover a hole found in review: phase 3 restores the selected BACKUP when
# one exists, so the file containerd is asked to load is not always the file
# currently on disk. A guard that only inspected /etc/containerd/config.toml
# would wave through an absent config paired with a v4 backup, and phase 3 would
# then restore exactly the file that cannot be loaded.
vm "rm -rf /root/docker-backup-* && mkdir -p /root/docker-backup-20260101-000000" >/dev/null 2>&1
vm "cp $CONF /root/docker-backup-20260101-000000/config.toml && rm -f $CONF" >/dev/null 2>&1

out=$(vm_try "cd /opt/docker-offline && ./rollback-docker.sh </dev/null 2>&1; echo \"__RC=\$?\"")
rc=$(printf '%s' "$out" | tr -d '\r' | sed -n 's/^__RC=//p' | tail -1)

if [ "${rc:-0}" != "0" ]; then
    ok "D7 config absent + v$armed BACKUP: rollback exited non-zero (exit $rc)"
else
    bad "D7 config absent + v$armed BACKUP: rollback exited 0 -- phase 3 restored an unloadable config"
fi

# The exit code alone does NOT distinguish "refused safely in phase 0c" from
# "ran the whole rollback and then failed to start containerd" -- both exit
# non-zero, and the second is the outage this guard exists to prevent. Assert
# the node state, which is the only thing that tells them apart. (Verified: a
# mutant that skips the backup in the effective-config choice passes D7 and
# fails these.)
assert_vm_eq "D7a containerd.io was NOT downgraded" \
    "rpm -q containerd.io --queryformat '%{VERSION}'" "$TARGET_CONTAINERD"
assert_vm_eq "D7b containerd still running" "systemctl is-active containerd" "active"

if printf '%s' "$out" | grep -q "backup phase 3 will restore"; then
    ok "D8 the refusal names the BACKUP, not the on-disk file"
else
    bad "D8 refusal did not identify the backup as the offending config"
    printf '%s\n' "$out" | tail -8 | sed 's/^/       /'
fi

# D9-D10: phase 0b only ever selects the NEWEST backup. When an OLDER one holds
# a loadable config, saying "no usable config exists" would send an operator
# hunting for a file they already have.
vm "mkdir -p /root/docker-backup-20250101-000000 && cp $WORK/config.v3.orig /root/docker-backup-20250101-000000/config.toml" >/dev/null 2>&1
vm "cp /root/docker-backup-20260101-000000/config.toml $CONF" >/dev/null 2>&1

# Two backups now exist, so phase 0b prompts; answer it rather than tripping the
# deliberate EOF refusal in prompt_yes_no.
out=$(vm_try "cd /opt/docker-offline && printf 'y\\n' | ./rollback-docker.sh 2>&1; echo \"__RC=\$?\"")
rc=$(printf '%s' "$out" | tr -d '\r' | sed -n 's/^__RC=//p' | tail -1)

if [ "${rc:-0}" != "0" ]; then
    ok "D9 newest backup unusable: rollback exited non-zero (exit $rc)"
else
    bad "D9 newest backup unusable: rollback exited 0"
fi
# Same reasoning as D7a/D7b: prove it refused rather than broke the node.
assert_vm_eq "D9a containerd.io was NOT downgraded" \
    "rpm -q containerd.io --queryformat '%{VERSION}'" "$TARGET_CONTAINERD"
assert_vm_eq "D9b containerd still running" "systemctl is-active containerd" "active"
if printf '%s' "$out" | grep -q "20250101-000000/config.toml"; then
    ok "D10 the refusal names the older, usable backup"
else
    bad "D10 refusal did not point at the older usable backup"
    printf '%s\n' "$out" | tail -10 | sed 's/^/       /'
fi

# Restore the D-section state for section E.
vm "rm -rf /root/docker-backup-*" >/dev/null 2>&1

#############################################
head_ "E  Negative control: the hazard is real"
#############################################

# Everything above is only worth having if the thing it prevents actually
# happens. Force the downgrade past the guard, with the v4 config in place, and
# confirm containerd genuinely refuses to start. If this test ever passes
# trivially -- containerd starting anyway -- then phase 0c is guarding nothing
# and should be reconsidered rather than kept for decoration.
vm "systemctl stop docker docker.socket containerd" >/dev/null 2>&1
vm "rpm -Uvh --oldpackage --replacepkgs $OLD_CTRD" >/dev/null 2>&1
vm_try "systemctl start containerd" >/dev/null 2>&1

# containerd.service restarts on failure, so a rejected config shows up as a
# crash-restart loop -- `activating` -- before it settles. Checking the state
# once would pass for a containerd that was merely slow to come up, which is the
# opposite of what this test is for. Poll instead, and pass only if it never
# reaches `active`.
state=$(vm_try "
    final=unknown
    for i in \$(seq 1 20); do
        final=\$(systemctl is-active containerd 2>/dev/null)
        [ \"\$final\" = active ] && break
        sleep 1
    done
    echo \"\$final\"" | tr -d '\r' | tail -1)

if [ "$state" != "active" ]; then
    ok "E1 containerd $BASELINE_CONTAINERD never reaches active on a v$armed config (settled: $state)"
else
    bad "E1 containerd $BASELINE_CONTAINERD STARTED on a v$armed config -- the guard protects nothing"
fi

if vm_try "journalctl -u containerd --no-pager | grep -c 'expected containerd config version equal to or less than'" | tail -1 | grep -qvx 0; then
    ok "E2 the journal names the config version as the cause"
else
    bad "E2 containerd failed for some other reason -- check the journal"
fi

# And the documented recovery works.
vm "cp $WORK/config.v3.orig $CONF" >/dev/null 2>&1
vm_try "systemctl start containerd" >/dev/null 2>&1
vm_try "for i in \$(seq 1 30); do ctr version >/dev/null 2>&1 && break; sleep 2; done" >/dev/null 2>&1

assert_vm_eq "E3 restoring the v$MAX_OLD_CONFIG_VERSION config lets containerd $BASELINE_CONTAINERD start" \
    "systemctl is-active containerd" "active"

echo ""
echo "This VM is now in a modified state. Run tests/vm/reset-baseline.sh."

summary

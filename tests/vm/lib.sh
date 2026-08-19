#!/bin/bash
# shellcheck disable=SC2034  # version constants are consumed by scripts that source this
# tests/vm/lib.sh
# Shared helpers for the VM test harness. Source this; do not run it.
#
# The harness drives an OrbStack Linux machine running Rocky Linux, which is a
# RHEL rebuild: `rpm -E %rhel` returns the right major, the packages are the
# same el8/el9 builds, and systemd is PID 1. It is NOT RHEL, and it is not bare
# metal -- see tests/vm/README.md for exactly what that does and does not prove.

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
RELOCATED_ROOT="/data/containerd"
LOOP_IMG="/var/data.img"
MANIFEST="/root/baseline-manifest.txt"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'

PASS=0; FAIL=0; SKIP=0
ok()   { printf '  %sPASS%s %s\n' "$GREEN" "$NC" "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  %sFAIL%s %s\n' "$RED" "$NC" "$1";   FAIL=$((FAIL + 1)); }
skip() { printf '  %sSKIP%s %s\n' "$YELLOW" "$NC" "$1"; SKIP=$((SKIP + 1)); }
head_(){ printf '\n== %s ==\n' "$1"; }

need_orbctl() {
    if ! command -v orbctl >/dev/null 2>&1; then
        echo "ERROR: orbctl not found. Install OrbStack: https://orbstack.dev" >&2
        exit 1
    fi
}

vm_exists() { orbctl list 2>/dev/null | awk '{print $1}' | grep -qx "$VM_NAME"; }

# Run a command in the VM as root. Output is returned; status is preserved.
vm() { orbctl run -m "$VM_NAME" sudo bash -c "$1"; }

# Same, but never fails the caller -- for probes whose failure is information.
vm_try() { orbctl run -m "$VM_NAME" sudo bash -c "$1" 2>&1 || true; }

require_vm() {
    need_orbctl
    if ! vm_exists; then
        echo "ERROR: VM '$VM_NAME' does not exist. Run tests/vm/bootstrap-vm.sh first." >&2
        exit 1
    fi
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

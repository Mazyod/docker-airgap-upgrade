#!/bin/bash
# shellcheck shell=bash
# tests/vm/backend-orb.sh
# OrbStack backend for the VM test harness. Sourced by lib.sh; do not run it.
#
# This is the original harness backend, moved here verbatim so that adding a
# second backend could not change it. It drives an OrbStack Linux machine on
# macOS: `orbctl run -m <machine> sudo bash -c '<cmd>'` is the whole transport,
# and OrbStack mounts the Mac's filesystem into the machine at the SAME
# absolute path, which is why every file-transfer site in the harness is a
# plain `cp` rather than a push.
#
# Requires: macOS + OrbStack (brew install orbstack).

need_backend() {
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

vm_create() {
    echo "Creating $VM_DISTRO:$VM_RELEASE ($VM_ARCH) machine '$VM_NAME'..."
    orbctl create -a "$VM_ARCH" "$VM_DISTRO:$VM_RELEASE" "$VM_NAME"
}

# Idempotent, and it does not claim success it has not verified. The loopback
# image lives inside the machine, so deleting the machine takes it along; there
# is no separate volume or image to clean up on this backend.
vm_delete() {
    orbctl delete -f "$VM_NAME" >/dev/null 2>&1 || true
    if vm_exists; then
        echo "ERROR: machine '$VM_NAME' still exists after orbctl delete." >&2
        return 1
    fi
    return 0
}

# --- Beyond the six-function core (see lib.sh) --------------------------------

# Make sure an already-existing guest is running and usable.
vm_wake() {
    orbctl start "$VM_NAME" >/dev/null 2>&1 || true
    vm "true" >/dev/null 2>&1
}

# Restart the guest. Used only by preflight-host.sh, to prove that the
# relocated-root mount survives a restart rather than assuming it.
vm_restart() {
    orbctl restart "$VM_NAME" >/dev/null 2>&1 || return 1
    # Only a SETTLED systemd counts. /run/systemd/system exists from very early
    # in the boot, so testing for it would return while units are still
    # starting -- including data.mount, which is the whole point of the check
    # this waiter serves. `is-system-running` exits non-zero for `degraded`,
    # which is normal for a guest with pruned units, so read the word.
    local waited=0 state
    while [ "$waited" -lt 120 ]; do
        state=$(vm_try "systemctl is-system-running" | tr -d '\r' | tail -1)
        case "$state" in
            running|degraded) return 0 ;;
        esac
        sleep 2
        waited=$((waited + 2))
    done
    echo "ERROR: systemd in '$VM_NAME' did not settle (last state: '${state:-none}')." >&2
    return 1
}

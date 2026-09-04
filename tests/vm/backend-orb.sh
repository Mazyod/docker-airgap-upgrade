#!/bin/bash
# shellcheck shell=bash
# tests/vm/backend-orb.sh
# OrbStack backend for the VM test harness. Sourced by lib.sh; do not run it.
#
# It drives an OrbStack Linux machine on macOS: `orbctl run -m <machine> sudo
# bash -c '<cmd>'` is the whole transport, and OrbStack mounts the Mac's
# filesystem into the machine at the SAME absolute path, which is why every
# file-transfer site in the harness is a plain `cp` rather than a push.
#
# WHAT IS AND IS NOT ORIGINAL CODE. The TRANSPORT -- need_backend, vm_exists,
# vm, vm_try and the `orbctl create` in vm_create -- was moved here verbatim
# from the pre-backend harness. The LIFECYCLE operations were not: vm_delete's
# absence verification, vm_wake and vm_restart are all new. Before the split,
# `orbctl delete -f` was a bare unverified call in bootstrap-vm.sh and
# teardown-vm.sh, and neither wake nor restart existed at all.
#
# That distinction matters because docs/TEST-PLAN.md records Tier 2 as executed
# on the DOCKER backend only. Everything new in this file is therefore
# unexecuted code, reviewed but never run. Treat a change here as untested
# until someone runs the harness on a Mac.
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

    # Prove absence from a SUCCESSFUL listing. vm_exists returning false covers
    # both "the machine is gone" and "orbctl could not be reached", and reading
    # the second as confirmed deletion is fail-open. `$(cmd || true)` cannot see
    # the status at all, so the listing is taken in a CONDITION.
    #
    # It has to be a condition rather than `listing=$(...)` followed by reading
    # `$?`: bootstrap-vm.sh calls vm_delete as a bare statement under
    # `set -euo pipefail`, so errexit fires on the failing assignment and the
    # script dies right there -- silently, after "Deleting existing VM", with
    # the diagnostic below never reaching anyone. Fail-closed but mute is not
    # good enough when the operator has to decide whether a 3 GB loop image
    # survived.
    local listing
    if ! listing=$(orbctl list 2>/dev/null); then
        echo "ERROR: 'orbctl list' failed; cannot verify that '$VM_NAME' was" >&2
        echo "       deleted. Refusing to report success." >&2
        return 1
    fi
    if printf '%s\n' "$listing" | awk '{print $1}' | grep -qx "$VM_NAME"; then
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

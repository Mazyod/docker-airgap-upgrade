#!/bin/bash
# shellcheck shell=bash
# tests/vm/backend-docker.sh
# Privileged-systemd-container backend for the VM test harness. Sourced by
# lib.sh; do not run it.
#
# The guest is a Rocky Linux 9 container running systemd as PID 1 under
# --privileged, built from tests/vm/Dockerfile.rocky9-systemd. That is enough
# for everything Tier 2 needs: real rpm transactions with real scriptlets, real
# systemd unit ordering and socket activation, a real loop-backed XFS
# filesystem for the relocated containerd root, and a nested dockerd.
#
# It is NOT a virtual machine. --privileged is genuine host access: the loop
# device comes out of the HOST's global loop table and mounting XFS autoloads
# the host kernel's xfs module. tests/vm/README.md spells out what that costs.
#
# Requires: Linux + a reachable Docker daemon. No sudo, no KVM.

HARNESS_IMAGE="${HARNESS_IMAGE:-${VM_NAME}-rocky9-systemd:latest}"
HARNESS_DATA_VOLUME="${HARNESS_DATA_VOLUME:-${VM_NAME}-data}"

# The loop-backed image lives on a named volume, NOT in the container's
# writable layer: it is 3 GB, and keeping it out of the layer keeps container
# recreation cheap. Dockerfile.rocky9-systemd's data.mount unit hardcodes this
# same path -- change both together.
LOOP_IMG="/var/harness/data.img"

need_backend() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "ERROR: docker not found. The container backend needs a Docker CLI." >&2
        exit 1
    fi
    if ! docker info >/dev/null 2>&1; then
        echo "ERROR: the Docker daemon is not reachable (docker info failed)." >&2
        echo "       Start it, or add yourself to the 'docker' group." >&2
        exit 1
    fi
}

vm_exists() { docker container inspect "$VM_NAME" >/dev/null 2>&1; }

_vm_running() {
    [ "$(docker container inspect -f '{{.State.Running}}' "$VM_NAME" 2>/dev/null)" = "true" ]
}

# Wait for systemd inside the guest to finish coming up. `is-system-running`
# exits non-zero for `degraded`, which is a normal state for a container with
# pruned units, so accept any settled answer rather than only `running`.
_vm_wait_systemd() {
    local waited=0 state
    while [ "$waited" -lt 120 ]; do
        state=$(docker exec "$VM_NAME" systemctl is-system-running 2>/dev/null || true)
        case "$state" in
            running|degraded) return 0 ;;
        esac
        sleep 2
        waited=$((waited + 2))
    done
    echo "ERROR: systemd in '$VM_NAME' did not settle (last state: '${state:-none}')." >&2
    return 1
}

# Run a command in the guest as root. Output is returned; status is preserved.
#
# No -t (avoids \r in captured output) and deliberately no -i: every harness
# command that needs stdin supplies it INSIDE the command string. Attaching the
# host's stdin would defeat prompt_yes_no's EOF refusal, which is the mechanism
# that turns an unexpected prompt into a hard failure.
vm() { docker exec "$VM_NAME" bash -c "$1"; }

# Same, but never fails the caller -- for probes whose failure is information.
vm_try() { docker exec "$VM_NAME" bash -c "$1" 2>&1 || true; }

vm_create() {
    echo "Building the harness image '$HARNESS_IMAGE'..."
    docker build -t "$HARNESS_IMAGE" \
        -f "$HARNESS_LIB_DIR/Dockerfile.rocky9-systemd" "$HARNESS_LIB_DIR" \
        || { echo "ERROR: docker build failed." >&2; return 1; }

    echo "Starting privileged systemd container '$VM_NAME'..."
    docker run -d --name "$VM_NAME" \
        --privileged \
        --cgroupns=private \
        --tmpfs /run --tmpfs /run/lock \
        -v "$HARNESS_REPO_DIR:$HARNESS_REPO_DIR:ro" \
        -v "$HARNESS_DATA_VOLUME:/var/harness" \
        "$HARNESS_IMAGE" >/dev/null \
        || { echo "ERROR: docker run failed." >&2; return 1; }

    _vm_wait_systemd
}

# Detach any host loop device still backed by this harness's data image.
#
# `mount -o loop` and systemd's Options=loop both set autoclear, so the loop is
# normally released with the container's mount namespace. This is the safety
# net, and it is deliberately narrow: it matches the exact backing path and
# refuses to touch a device the HOST has mounted.
harness_sweep_loops() {
    local line dev
    command -v losetup >/dev/null 2>&1 || return 0
    while IFS= read -r line; do
        dev=${line%%:*}
        [ -b "$dev" ] || continue
        if findmnt -n -S "$dev" >/dev/null 2>&1; then
            echo "  WARNING: $dev is mounted on this host; leaving it alone." >&2
            continue
        fi
        echo "  sweeping stray loop device $dev ($LOOP_IMG)"
        losetup -d "$dev" 2>/dev/null || true
    done < <(losetup -a 2>/dev/null | grep -F "($LOOP_IMG" || true)
}

vm_delete() {
    docker rm -f "$VM_NAME" >/dev/null 2>&1 || true
    docker volume rm -f "$HARNESS_DATA_VOLUME" >/dev/null 2>&1 || true
    harness_sweep_loops
}

# --- Beyond the six-function core (see lib.sh) --------------------------------

vm_wake() {
    _vm_running || docker start "$VM_NAME" >/dev/null 2>&1 || true
    _vm_wait_systemd
}

# Restart the guest. Used only by preflight-host.sh, to prove that the
# relocated-root mount survives a restart rather than assuming it. This is the
# exact failure mode the data.mount unit exists for: a container restart tears
# down the mount namespace, the 3 GB backing file survives on the volume, and
# without an ordered mount unit containerd would come up on an EMPTY shadow
# directory and report itself healthy.
vm_restart() {
    docker restart "$VM_NAME" >/dev/null || return 1
    _vm_wait_systemd
}

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

# The guest is not a VM, so three properties of the DAEMON are load-bearing and
# are checked rather than assumed:
#
#   local      the repo is handed to the guest as a bind mount of a host path.
#              A remote daemon would resolve that path on the remote machine and
#              silently mount the wrong tree, or nothing.
#   rootful    the baseline needs real loop devices, mount(2), and a nested
#              dockerd. Rootless Docker gives none of those under --privileged.
#   x86_64     the bundle is built from el9 x86_64 RPMs. On another architecture
#              the RPM transaction is the thing under test and it would fail for
#              a reason that has nothing to do with the scripts.
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

    case "${DOCKER_HOST:-}" in
        ""|unix://*) ;;
        *)
            echo "ERROR: DOCKER_HOST='$DOCKER_HOST' points at a non-local daemon." >&2
            echo "       The harness bind-mounts the repo at $HARNESS_REPO_DIR, which only" >&2
            echo "       works when the daemon can see that path. Use a local unix socket." >&2
            exit 1
            ;;
    esac

    local arch sec
    arch=$(docker info --format '{{.Architecture}}' 2>/dev/null)
    case "$arch" in
        x86_64|amd64) ;;
        *)
            echo "ERROR: the Docker daemon reports architecture '${arch:-<unknown>}'." >&2
            echo "       The Tier 2 bundle is el9 x86_64; another architecture would fail" >&2
            echo "       the rpm transaction for reasons unrelated to the scripts." >&2
            exit 1
            ;;
    esac

    sec=$(docker info --format '{{.SecurityOptions}}' 2>/dev/null)
    case "$sec" in
        *rootless*)
            echo "ERROR: this is a ROOTLESS Docker daemon." >&2
            echo "       The S1 baseline needs a real loop device, an XFS mount and a nested" >&2
            echo "       dockerd, none of which rootless Docker provides. Use a rootful daemon" >&2
            echo "       or run the harness on macOS with OrbStack." >&2
            exit 1
            ;;
    esac
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
    docker build --platform linux/amd64 -t "$HARNESS_IMAGE" \
        -f "$HARNESS_LIB_DIR/Dockerfile.rocky9-systemd" "$HARNESS_LIB_DIR" \
        || { echo "ERROR: docker build failed." >&2; return 1; }

    echo "Starting privileged systemd container '$VM_NAME'..."
    docker run -d --name "$VM_NAME" \
        --platform linux/amd64 \
        --privileged \
        --cgroupns=private \
        --tmpfs /run --tmpfs /run/lock \
        -v "$HARNESS_REPO_DIR:$HARNESS_REPO_DIR:ro" \
        -v "$HARNESS_DATA_VOLUME:/var/harness" \
        "$HARNESS_IMAGE" >/dev/null \
        || { echo "ERROR: docker run failed." >&2; return 1; }

    _vm_wait_systemd
}

# REPORT any host loop device still backed by this harness's data image.
#
# This deliberately does NOT detach anything. Loop devices are host-global but
# their MOUNTS are not: a device attached inside another container's mount
# namespace looks idle from here, and `findmnt` on the host cannot see it. Two
# guests configured with the same LOOP_IMG path would each select the other's
# device. Detaching on that evidence would pull a filesystem out from under a
# live process on the host or in an unrelated container.
#
# Detaching is also unnecessary. Both `mount -o loop` and systemd's
# Options=loop set autoclear, so the device is released with the mount
# namespace -- measured on this host: after removing the container and its
# volume, `losetup -a` came back clean with no intervention. So this is a
# diagnostic for the case where that did not happen, and the operator decides.
harness_report_loops() {
    local line dev found=0
    command -v losetup >/dev/null 2>&1 || return 0
    while IFS= read -r line; do
        # `losetup -a` prints:  /dev/loopN: [ID]: (BACKING PATH)
        # Match the backing path as a whole parenthesised token, so that
        # /var/harness/data.img.bak or .../data.img2 cannot match. A deleted
        # backing file is printed as "(PATH (deleted))", so accept that suffix.
        case "$line" in
            *"($LOOP_IMG)"|*"($LOOP_IMG (deleted))") ;;
            *) continue ;;
        esac
        dev=${line%%:*}
        [ -n "$dev" ] || continue
        found=1
        echo "  NOTE: host loop device $dev is still backed by $LOOP_IMG" >&2
        echo "        Nothing here detaches it -- a loop attached inside another mount" >&2
        echo "        namespace looks idle from the host, so detaching on that evidence" >&2
        echo "        is unsafe. If it really is stray:  sudo losetup -d $dev" >&2
    done < <(losetup -a 2>/dev/null || true)
    return "$found"
}

# Idempotent, but it does not claim success it has not verified.
vm_delete() {
    docker rm -f "$VM_NAME" >/dev/null 2>&1 || true
    docker volume rm -f "$HARNESS_DATA_VOLUME" >/dev/null 2>&1 || true
    docker image rm -f "$HARNESS_IMAGE" >/dev/null 2>&1 || true

    local rc=0
    if docker container inspect "$VM_NAME" >/dev/null 2>&1; then
        echo "ERROR: container '$VM_NAME' still exists after removal." >&2
        rc=1
    fi
    if docker volume inspect "$HARNESS_DATA_VOLUME" >/dev/null 2>&1; then
        echo "ERROR: volume '$HARNESS_DATA_VOLUME' still exists after removal." >&2
        echo "       Something else may still be using it: docker ps -a --filter volume=$HARNESS_DATA_VOLUME" >&2
        rc=1
    fi
    if docker image inspect "$HARNESS_IMAGE" >/dev/null 2>&1; then
        echo "ERROR: image '$HARNESS_IMAGE' still exists after removal." >&2
        rc=1
    fi

    harness_report_loops || true
    return "$rc"
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

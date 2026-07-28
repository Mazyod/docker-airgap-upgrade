#!/bin/bash
# clean-swarm-networks.sh
# Reset orphaned Swarm overlay network state on a single node
VERSION="1.0.0"
#
# WHEN TO RUN THIS
#
# Run this only when a Swarm node has come back from an upgrade or a crash and
# cannot attach to overlay networks. The signature symptom is dockerd logging:
#
#     failed adding service binding
#
# ...or services scheduled onto the node never reaching a running state while
# the same services run fine on other nodes.
#
# WHEN NOT TO RUN THIS
#
# This is NOT a routine upgrade step. It was formerly phase 4.5 of
# upgrade-docker.sh, where it ran unconditionally on every Swarm node, because
# swapping containerd 1.7 -> 2.x out from under a running dockerd left orphaned
# VXLAN interfaces and a stale libnetwork key-value store behind.
#
# Upgrades inside the containerd 2.2.x line stop the daemon cleanly, so there is
# nothing orphaned to collect and running this anyway just forces an unnecessary
# overlay reconvergence. See upgrade-docker.sh v1.2.3 (commit 974683a) in git
# history for the original in-line phase.
#
# WHAT IT DESTROYS
#
# - every VXLAN interface on the host
# - /var/run/docker/netns/*
# - <docker-data-root>/network/files/local-kv.db  (libnetwork local state)
# - the docker_gwbridge interface
#
# Swarm recreates all of it on reconnect. Containers, images, volumes and the
# Swarm membership itself are NOT touched.
#
# PREREQUISITE: drain this node from a manager first if it is carrying tasks.
#   docker node update --availability drain <node>

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

exec > >(tee -a /var/log/docker-network-cleanup.log) 2>&1

echo "=========================================="
echo "Swarm Network State Cleanup"
echo "Script Version: $VERSION"
echo "Server: $(hostname)"
echo "Date: $(date)"
echo "=========================================="

#############################################
# Helper Functions
#############################################

prompt_yes_no() {
    local prompt="$1"
    local default="$2"
    local response

    while true; do
        read -r -p "$prompt " response
        response=${response:-$default}
        case "$response" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]) return 1 ;;
            *) echo "Please answer yes or no." ;;
        esac
    done
}

# Confirm a unit is CONCLUSIVELY stopped.
#
# `systemctl is-active` is not sufficient: it returns nonzero for `activating`,
# `deactivating`, and for a failure to reach systemd at all. Treating any
# nonzero as "safely stopped" fails open -- a stop that timed out and left the
# unit `deactivating` would sail through and network state would be deleted
# under a live daemon.
verify_unit_stopped() {
    local unit="$1" out state mainpid

    if ! out=$(systemctl show "$unit" --property=ActiveState --property=MainPID 2>/dev/null); then
        echo "    $unit: cannot query systemd"
        return 1
    fi

    state=$(printf '%s\n' "$out" | sed -n 's/^ActiveState=//p')
    mainpid=$(printf '%s\n' "$out" | sed -n 's/^MainPID=//p')

    if [ -z "$state" ]; then
        echo "    $unit: systemd reported no ActiveState"
        return 1
    fi

    case "$state" in
        inactive|failed) ;;
        *)
            echo "    $unit: ActiveState=$state (not conclusively stopped)"
            return 1
            ;;
    esac

    if [ -n "$mainpid" ] && [ "$mainpid" != "0" ]; then
        echo "    $unit: still running as PID $mainpid"
        return 1
    fi

    return 0
}

stop_services() {
    echo "Stopping docker..."
    systemctl stop docker docker.socket 2>/dev/null || true
    sleep 2

    echo "Stopping containerd..."
    systemctl stop containerd 2>/dev/null || true
    sleep 2

    # Do not take `systemctl stop` at its word. Cleaning network state out from
    # under a daemon that is still running is worse than not cleaning at all.
    #
    # docker.socket is checked too, and that is not pedantry: if the socket unit
    # survives while dockerd is down, anything that connects to it -- a
    # monitoring agent, an operator's `docker ps` -- socket-activates dockerd
    # again, mid-deletion.
    echo "Confirming services are stopped..."
    local failed=0 unit
    for unit in docker docker.socket containerd; do
        if verify_unit_stopped "$unit"; then
            echo "    $unit: stopped"
        else
            failed=$((failed + 1))
        fi
    done

    if [ "$failed" -gt 0 ]; then
        echo -e "${RED}ERROR: $failed unit(s) not conclusively stopped.${NC}" >&2
        echo "Refusing to modify network state while a daemon can be reached." >&2
        echo "Investigate with: systemctl status docker docker.socket containerd" >&2
        return 1
    fi

    echo "Services confirmed stopped."
    return 0
}

# Start containerd, wait for it to be genuinely usable, then start docker.
# systemd reports containerd active before its snapshotter is ready, so both
# the API and the snapshotter are polled -- see CLAUDE.md.
start_services() {
    local i

    echo "Starting containerd..."
    if ! systemctl start containerd; then
        echo -e "${RED}ERROR: systemctl start containerd failed${NC}" >&2
        return 1
    fi

    local ready=false
    for i in {1..30}; do
        if ctr version &>/dev/null; then
            echo "  containerd API responsive (attempt $i)"
            ready=true
            break
        fi
        echo "  Waiting for containerd API... (attempt $i/30)"
        sleep 2
    done

    if [ "$ready" = false ]; then
        echo -e "${YELLOW}  containerd API not responding, forcing restart...${NC}"
        systemctl restart containerd || true
        sleep 5
        if ! ctr version &>/dev/null; then
            echo -e "${RED}ERROR: containerd API never became responsive${NC}" >&2
            echo "Check: journalctl -u containerd --no-pager -n 50" >&2
            return 1
        fi
    fi

    echo "  Verifying overlayfs snapshotter..."
    if ! ctr snapshots --snapshotter overlayfs ls &>/dev/null; then
        echo -e "${YELLOW}  Snapshotter not ready, restarting containerd...${NC}"
        systemctl restart containerd || true
        sleep 5
        if ! ctr snapshots --snapshotter overlayfs ls &>/dev/null; then
            echo -e "${RED}ERROR: overlayfs snapshotter is not usable${NC}" >&2
            echo "Check: journalctl -u containerd --no-pager -n 50" >&2
            return 1
        fi
    fi
    echo "  containerd is fully ready."

    echo "Starting docker..."
    if ! systemctl start docker; then
        echo -e "${RED}ERROR: systemctl start docker failed${NC}" >&2
        echo "Check: journalctl -u docker --no-pager -n 50" >&2
        return 1
    fi

    if ! systemctl is-active docker &>/dev/null; then
        echo -e "${RED}ERROR: docker is not active after start${NC}" >&2
        return 1
    fi

    echo "  docker is running."
    return 0
}

# SERVICES_STOPPED is armed BEFORE the first stop and cleared only after both
# services are verified back up. Any exit in between -- error, Ctrl-C, SIGTERM
# -- must not leave the node down.
SERVICES_STOPPED=false
# shellcheck disable=SC2329  # invoked indirectly by `trap on_exit EXIT` below
on_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ] && [ "$SERVICES_STOPPED" = true ]; then
        echo ""
        echo -e "${RED}Script failed (exit $rc) with services stopped.${NC}"
        echo "Attempting to bring docker and containerd back up..."
        if start_services; then
            echo -e "${GREEN}Services restored.${NC}"
        else
            echo -e "${RED}AUTOMATIC RECOVERY FAILED. This node is DOWN.${NC}"
            echo ""
            echo "Recover manually:"
            echo "  systemctl start containerd"
            echo "  ctr version                     # wait until this responds"
            echo "  systemctl start docker"
            echo "  journalctl -u containerd -u docker --no-pager -n 100"
        fi
    fi
    exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

#############################################
# Phase 1: Detect State & Confirm Intent
#############################################
echo ""
echo "=== Phase 1: Detect State ==="

SWARM_STATE=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "unknown")
echo "Swarm state: $SWARM_STATE"

if [ "$SWARM_STATE" != "active" ]; then
    echo ""
    echo -e "${YELLOW}WARNING: This node does not report an active Swarm membership.${NC}"
    echo "This script only makes sense on a Swarm node. On a standalone Docker"
    echo "host it deletes bridge network state for no benefit."
    echo ""
    if ! prompt_yes_no "Continue anyway? [y/N]" "n"; then
        echo "Aborted. No changes made."
        exit 0
    fi
fi

# The drain guardrail that Phase 1 of upgrade-docker.sh used to provide. A
# worker cannot drain or inspect itself, so this can only be an attestation.
echo ""
echo -e "${YELLOW}This node must be DRAINED before its network state is reset.${NC}"
echo "From a manager node:"
echo ""
echo -e "  ${YELLOW}docker node update --availability drain $(hostname)${NC}"
echo ""
if ! prompt_yes_no "Has this node been drained? [y/N]" "n"; then
    echo "Aborted. Drain the node from a manager, then re-run."
    exit 0
fi

# Detect Docker data root from daemon.json
DOCKER_DATA_ROOT="/var/lib/docker"
if [ -f /etc/docker/daemon.json ]; then
    CUSTOM_ROOT=$(grep -oP '"data-root"\s*:\s*"\K[^"]+' /etc/docker/daemon.json 2>/dev/null || true)
    if [ -n "$CUSTOM_ROOT" ]; then
        DOCKER_DATA_ROOT="$CUSTOM_ROOT"
        echo "Detected custom Docker data root: $DOCKER_DATA_ROOT"
    fi
fi
KV_DB="$DOCKER_DATA_ROOT/network/files/local-kv.db"
echo "libnetwork KV store: $KV_DB"

echo ""
echo "Services will now be stopped so the exact set of state to delete can be"
echo "enumerated. You get a final confirmation before anything is deleted."
echo ""
if ! prompt_yes_no "Stop docker and containerd now? [y/N]" "n"; then
    echo "Aborted. No changes made."
    exit 0
fi

#############################################
# Phase 2: Stop Services (CORRECT ORDER)
#############################################
echo ""
echo "=== Phase 2: Stop Services ==="

# Armed BEFORE the stop, so an interrupt anywhere inside stop_services still
# triggers recovery on the way out.
SERVICES_STOPPED=true
stop_services

#############################################
# Phase 3: Enumerate & Confirm Deletions
#############################################
echo ""
echo "=== Phase 3: Planned Deletions ==="

# Enumerated AFTER shutdown and deleted from these exact lists, so what is
# printed below is precisely what gets removed. Enumerating before the stop
# would let daemon shutdown add or remove interfaces in between.
#
# `mapfile < <(cmd || true)` cannot observe cmd's exit status -- mapfile only
# sees EOF -- and an unpipefailed `ip | awk` hides ip's failure behind awk's
# success. Either way a failed enumeration would arrive as an empty array and
# be reported as "nothing to clean". For a destructive inventory, "I could not
# look" must never read as "there is none". Capture output and status apart.

if ! VXLAN_RAW=$(ip -o link show type vxlan 2>&1); then
    echo -e "${RED}ERROR: could not enumerate VXLAN interfaces${NC}" >&2
    echo "$VXLAN_RAW" >&2
    echo "Refusing to delete an inventory that could not be read." >&2
    exit 1
fi
mapfile -t VXLAN_IFACES < <(printf '%s' "$VXLAN_RAW" | awk -F': ' 'NF > 1 { print $2 }')

NETNS_DIR="/var/run/docker/netns"
if [ ! -d "$NETNS_DIR" ]; then
    # Genuinely absent: docker never created it. Not an error.
    NETNS_FILES=()
elif ! NETNS_RAW=$(find "$NETNS_DIR" -mindepth 1 -maxdepth 1 2>&1); then
    echo -e "${RED}ERROR: could not enumerate $NETNS_DIR${NC}" >&2
    echo "$NETNS_RAW" >&2
    echo "Refusing to delete an inventory that could not be read." >&2
    exit 1
else
    mapfile -t NETNS_FILES < <(printf '%s' "$NETNS_RAW")
fi

GWBRIDGE_PRESENT=false
ip link show docker_gwbridge &>/dev/null && GWBRIDGE_PRESENT=true

KV_DB_PRESENT=false
[ -f "$KV_DB" ] && KV_DB_PRESENT=true

echo ""
echo "VXLAN interfaces (${#VXLAN_IFACES[@]}):"
if [ "${#VXLAN_IFACES[@]}" -eq 0 ]; then
    echo "  (none)"
else
    printf '  %s\n' "${VXLAN_IFACES[@]}"
fi

echo ""
echo "Network namespaces (${#NETNS_FILES[@]}):"
if [ "${#NETNS_FILES[@]}" -eq 0 ]; then
    echo "  (none)"
else
    printf '  %s\n' "${NETNS_FILES[@]}"
fi

echo ""
echo "libnetwork local key-value store:"
if [ "$KV_DB_PRESENT" = true ]; then
    echo "  $KV_DB  ($(du -h "$KV_DB" | cut -f1))"
else
    echo "  $KV_DB  (not present)"
fi

echo ""
echo "docker_gwbridge:"
if [ "$GWBRIDGE_PRESENT" = true ]; then
    echo "  present - will be deleted"
else
    echo "  (not present)"
fi

TOTAL=$(( ${#VXLAN_IFACES[@]} + ${#NETNS_FILES[@]} ))
[ "$KV_DB_PRESENT" = true ] && TOTAL=$((TOTAL + 1))
[ "$GWBRIDGE_PRESENT" = true ] && TOTAL=$((TOTAL + 1))

if [ "$TOTAL" -eq 0 ]; then
    echo ""
    echo -e "${GREEN}Nothing to clean. Restarting services and exiting.${NC}"
    start_services
    SERVICES_STOPPED=false
    echo ""
    echo "No orphaned network state was found on this node. If it still cannot"
    echo "attach to overlay networks, the cause is elsewhere -- check:"
    echo "  journalctl -u docker --no-pager -n 100"
    exit 0
fi

echo ""
echo -e "${YELLOW}$TOTAL item(s) listed above will be DELETED.${NC}"
echo -e "${YELLOW}Swarm recreates them on reconnect. Containers, images and${NC}"
echo -e "${YELLOW}volumes are not affected.${NC}"
echo ""
if ! prompt_yes_no "Delete the state listed above? [y/N]" "n"; then
    echo "Aborted. Nothing deleted - restarting services."
    start_services
    SERVICES_STOPPED=false
    echo "Services restored. No changes were made to network state."
    exit 0
fi

#############################################
# Phase 4: Delete Network State
#############################################
echo ""
echo "=== Phase 4: Delete Network State ==="

FAILED=0

echo "Removing VXLAN interfaces..."
for iface in "${VXLAN_IFACES[@]}"; do
    if ip link del "$iface" 2>/dev/null; then
        echo "  ✓ $iface"
    elif ! ip link show "$iface" &>/dev/null; then
        echo "  ✓ $iface (already gone)"
    else
        echo -e "  ${RED}✗ $iface - could not delete${NC}"
        FAILED=$((FAILED + 1))
    fi
done

echo "Removing network namespaces..."
for ns in "${NETNS_FILES[@]}"; do
    if rm -rf "$ns" 2>/dev/null && [ ! -e "$ns" ]; then
        echo "  ✓ ${ns##*/}"
    else
        echo -e "  ${RED}✗ ${ns##*/} - could not delete${NC}"
        FAILED=$((FAILED + 1))
    fi
done

if [ "$KV_DB_PRESENT" = true ]; then
    echo "Removing libnetwork key-value store..."
    if rm -f "$KV_DB" 2>/dev/null && [ ! -f "$KV_DB" ]; then
        echo "  ✓ $KV_DB"
    else
        echo -e "  ${RED}✗ $KV_DB - could not delete${NC}"
        FAILED=$((FAILED + 1))
    fi
fi

if [ "$GWBRIDGE_PRESENT" = true ]; then
    echo "Removing docker_gwbridge..."
    if ip link del docker_gwbridge 2>/dev/null || ! ip link show docker_gwbridge &>/dev/null; then
        echo "  ✓ docker_gwbridge"
    else
        echo -e "  ${RED}✗ docker_gwbridge - could not delete${NC}"
        FAILED=$((FAILED + 1))
    fi
fi

if [ "$FAILED" -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}WARNING: $FAILED item(s) could not be deleted.${NC}"
    echo "Services will still be restarted, but the cleanup was INCOMPLETE."
    echo "The node may still fail to attach to overlay networks."
else
    echo ""
    echo -e "${GREEN}All listed network state removed.${NC}"
fi

#############################################
# Phase 5: Start Services (CORRECT ORDER)
#############################################
echo ""
echo "=== Phase 5: Start Services ==="

start_services
# Cleared only now: containerd API, the overlayfs snapshotter, and docker have
# all been verified inside start_services.
SERVICES_STOPPED=false

echo -e "${GREEN}Services started.${NC}"

#############################################
# Phase 6: Verification
#############################################
echo ""
echo "=== Phase 6: Verification ==="

echo "Swarm state:"
docker info --format '  LocalNodeState: {{.Swarm.LocalNodeState}}' 2>/dev/null || \
    echo "  (unable to query)"

echo ""
echo "Networks:"
docker network ls 2>/dev/null || echo "  (unable to query)"

echo ""
echo "=========================================="
if [ "$FAILED" -gt 0 ]; then
    echo -e "${YELLOW}NETWORK CLEANUP COMPLETED WITH $FAILED FAILURE(S)${NC}"
else
    echo -e "${GREEN}NETWORK CLEANUP COMPLETE${NC}"
fi
echo "=========================================="
echo ""
echo "Next steps:"
echo "  - Overlay networks reattach as Swarm reconverges; allow a minute."
echo "  - Reactivate this node from a manager:"
echo "      docker node update --availability active $(hostname)"
echo "  - Confirm services schedule here again:"
echo "      docker node ps $(hostname)"
echo ""
echo "Log file: /var/log/docker-network-cleanup.log"
echo "=========================================="

# Services are back up and SERVICES_STOPPED is already false, so the EXIT trap
# will not try to recover. Exit nonzero anyway when the cleanup was incomplete:
# an operator sees the warning above, but a runbook or wrapper checking $?
# would otherwise record an incomplete remedy as a success.
if [ "$FAILED" -gt 0 ]; then
    exit 2
fi
exit 0

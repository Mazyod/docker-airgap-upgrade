#!/bin/bash
# clean-swarm-networks.sh
# Reset orphaned Swarm overlay network state on a single node
VERSION="1.1.0"
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

#############################################
# Agent-mode identity
#############################################
SCRIPT_NAME="clean-swarm-networks.sh"
LOG_FILE="/var/log/docker-network-cleanup.log"

#############################################
# Agent-mode run record
#############################################
# --status-file=PATH writes a flat key=value record of this run. Nothing else
# about the script changes: with no arguments the behaviour is exactly what it
# was, and there is still no way to answer a prompt from a flag. That arrives
# in a later change.
#
# Everything here runs BEFORE `exec > >(tee ...)` further down, and the order
# is load-bearing:
#
#   globals -> parser -> traps -> startup record -> root check -> tee -> banner
#
#   - The parser precedes the tee because --help must not need write access to
#     /var/log.
#   - The traps precede the root check so a non-root refusal is still reported.
#   - The root check precedes the tee because a non-root run cannot open the
#     log, and the process substitution then swallows every line the script
#     prints: measured, a non-root run produced NO output at all. An
#     unexplained silent exit is the worst possible failure for an operator
#     with no internet.
STATUS_FILE=""
STATUS_WRITTEN=false
STATUS_OK=true
LOG_STARTED=false
MODE="interactive"
RESULT="running"
REFUSAL_REASON=""
REFUSAL_DETAIL=""
NEXT_ACTION="none"
OPERATION_COMPLETED=false
ENDED="unknown"
STARTED="unknown"
RUN_ID="unknown"

# Slice 4 populates these; declared here because the parser will own them, and
# assigning GATE_ANSWERS[x] before `declare -A` would create an indexed array
# that cannot be converted afterwards.
# shellcheck disable=SC2034  # reserved for the gate flags; see the agent-mode plan
NON_INTERACTIVE=false
# shellcheck disable=SC2034  # reserved for the gate flags; see the agent-mode plan
declare -A GATE_ANSWERS=()

usage() {
    cat <<USAGE
$SCRIPT_NAME $VERSION

Usage: $SCRIPT_NAME [OPTIONS]

Options:
  --status-file=PATH   Write a key=value record of this run to PATH. Written
                       once at startup with result=running and again on every
                       exit path, including success and interrupts.
  --help               Show this help and exit.
  --version            Print the script version and exit.

With no options the behaviour is unchanged: the script is interactive and
every prompt refuses a closed stdin. See docs/AGENT-RUNBOOK.md.
USAGE
}

# Inert with zero arguments: the loop body never runs, so nothing is assigned
# and nothing is touched. The timestamp and correlation id below are computed
# only when a record will actually be written, so a run with no status file
# does no extra work beyond this loop and the root check.
while [ "$#" -gt 0 ]; do
    case "$1" in
        --status-file=*)
            STATUS_FILE="${1#*=}"
            if [ -z "$STATUS_FILE" ]; then
                echo "ERROR: --status-file needs a path" >&2
                exit 1
            fi
            ;;
        --status-file)
            # An empty value must be rejected here too. Accepted, it would
            # leave STATUS_FILE empty and the run would silently behave as if
            # no status file had been asked for at all.
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                echo "ERROR: --status-file needs a path" >&2
                exit 1
            fi
            STATUS_FILE="$2"; shift
            ;;
        --help|-h) usage; exit 0 ;;
        --version) echo "$SCRIPT_NAME $VERSION"; exit 0 ;;
        *)
            echo "ERROR: unrecognised argument: $1" >&2
            echo "Try --help." >&2
            exit 1
            ;;
    esac
    shift
done

if [ -n "$STATUS_FILE" ]; then
    if [ "${STATUS_FILE#/}" = "$STATUS_FILE" ]; then
        echo "ERROR: --status-file must be an absolute path: $STATUS_FILE" >&2
        exit 1
    fi
    # A directory would otherwise "succeed": mktemp makes a sibling and `mv`
    # drops it INSIDE the directory, so the startup write returns 0 and no
    # record exists at the path the caller asked for. `mv -fT` refuses that,
    # but say so here rather than at the rename.
    if [ -d "$STATUS_FILE" ]; then
        echo "ERROR: --status-file is a directory: $STATUS_FILE" >&2
        exit 1
    fi
    STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
    # A correlation id, not a guaranteed-unique key: epoch plus pid collides
    # under pid reuse, hence the random suffix. Lets a caller that reuses one
    # status-file path tell this run's record from the previous run's.
    RUN_ID="$(date -u +%s 2>/dev/null || echo 0)-$$-$(od -An -N2 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || echo 0000)"
fi

# Quiet, bounded probes of unit state, for the run record and for
# derive_next_action. `systemctl is-active` is NOT used: it returns nonzero for
# `activating`, for `deactivating`, and for failing to reach systemd at all, so
# treating nonzero as "stopped" fails open -- the exact trap verify_unit_stopped
# exists to avoid, and one CLAUDE.md calls out by name. These fail CLOSED: an
# unreachable systemd reads as unknown, never as stopped.
#
# `timeout` bounds them because they run inside the EXIT trap, and a trap that
# hangs on a sick systemd is worse than a missing key.
unit_state() {
    local out
    out=$(timeout --kill-after=2 5 systemctl show "$1" \
              --property=ActiveState --value 2>/dev/null) || return 1
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
}

# The same rule verify_unit_stopped applies: a SUCCESSFUL show, an ActiveState
# of inactive or failed, and MainPID 0. Anything else is not "stopped".
# shellcheck disable=SC2329  # invoked from derive_next_action, which on_exit runs
unit_is_stopped() {
    local out st pid
    # ONE call for both properties. Two calls can straddle a state change: the
    # first sees docker.socket inactive, the socket activates, the second still
    # reads MainPID=0, and a live socket is classified as stopped. That is the
    # unit whose survival socket-activates dockerd mid-transaction.
    out=$(timeout --kill-after=2 5 systemctl show "$1" \
              --property=ActiveState --property=MainPID 2>/dev/null) || return 1
    st=$(printf '%s\n' "$out" | sed -n 's/^ActiveState=//p' | head -1)
    pid=$(printf '%s\n' "$out" | sed -n 's/^MainPID=//p' | head -1)
    case "$st" in
        inactive|failed) : ;;
        *) return 1 ;;
    esac
    [ "$pid" = "0" ]
}

# Values are single-line and unquoted; a consumer splits on the FIRST '='.
# A failed write flips STATUS_OK, which is what stops a truncated file being
# published -- see write_status_file.
status_kv() {
    printf '%s=%s\n' "$1" "${2//[$'\n\r']/ }" || STATUS_OK=false
}

status_common() {
    status_kv schema 1
    status_kv run_id "$RUN_ID"
    status_kv script "$SCRIPT_NAME"
    status_kv script_version "$VERSION"
    status_kv started "$STARTED"
    status_kv ended "$ENDED"
    status_kv host "$(hostname 2>/dev/null || echo unknown)"
    status_kv rhel "$(rpm -E %rhel 2>/dev/null || echo unknown)"
    status_kv mode "$MODE"
    status_kv result "$RESULT"
    status_kv exit_code "$EXIT_CODE"
    status_kv phase "$CURRENT_PHASE"
    status_kv refusal_reason "$REFUSAL_REASON"
    status_kv refusal_detail "$REFUSAL_DETAIL"
    status_kv next_action "$NEXT_ACTION"
    status_kv log "$LOG_FILE"
    status_kv log_started "$LOG_STARTED"
    # Observed at write time. SERVICES_STOPPED records that the script BEGAN
    # stopping services, which is what the recovery logic needs; it is not a
    # claim that the units actually reached inactive. A failed or partial stop
    # leaves it true while docker is still up, so report both.
    status_kv docker_active "$(unit_state docker || echo unknown)"
    status_kv docker_socket_active "$(unit_state docker.socket || echo unknown)"
    status_kv containerd_active "$(unit_state containerd || echo unknown)"
}

# Writes to a temp file beside the destination and renames, so a reader never
# sees a half-written record, and NEVER through the tee'd stdout -- the process
# substitution's flush ordering at exit is not guaranteed.
#
# Publishing requires BOTH the STATUS_OK accumulator and the status_complete
# terminator. Either alone can be satisfied by a truncated file: the call site
# guards this with `|| true`, which suspends `set -e` for the whole function,
# so a status_kv that fails mid-file is followed by later ones that succeed --
# terminator included.
write_status_file() {
    [ -n "$STATUS_FILE" ] || return 0
    local tmp last
    # mktemp, not ".tmp.$$": exclusive creation, so a stale temp left by a
    # killed run whose pid was later reused cannot be inspected and published.
    tmp=$(mktemp "${STATUS_FILE}.tmp.XXXXXX" 2>/dev/null) || return 1
    STATUS_OK=true
    {
        status_common
        status_keys
        [ "$STATUS_OK" = true ] && status_kv status_complete 1
    } > "$tmp" 2>/dev/null || STATUS_OK=false
    if [ "$STATUS_OK" = true ] && last=$(tail -n 1 "$tmp" 2>/dev/null) &&
       [ "$last" = "status_complete=1" ]; then
        # -T: treat the destination as a file, never as a directory to move
        # into. GNU userland is assumed throughout these scripts.
        mv -fT "$tmp" "$STATUS_FILE" 2>/dev/null && return 0
    fi
    rm -f "$tmp"
    return 1
}

# TOTAL: always returns 0. A nonzero return would abort the EXIT trap under
# `set -e`, replacing 130 or 143 with this function's status and writing no
# final record -- on exactly the interrupted run someone needs to read.
# shellcheck disable=SC2329  # invoked from on_exit, which the EXIT trap runs
derive_result() {
    local rc="$1"
    if [ "$rc" -eq 130 ] || [ "$rc" -eq 143 ]; then
        RESULT="interrupted"
    elif [ -n "$REFUSAL_REASON" ]; then
        RESULT="refused"
    elif [ "$rc" -eq 3 ]; then
        RESULT="nothing-to-do"
    elif [ "$rc" -eq 2 ] && [ "$OPERATION_COMPLETED" = true ]; then
        RESULT="completed"
    elif [ "$rc" -eq 0 ]; then
        case "$RESULT" in
            ready|nothing-to-do) : ;;
            *) RESULT="completed" ;;
        esac
    else
        RESULT="failed"
    fi
    [ -n "$STATUS_FILE" ] && ENDED=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
    EXIT_CODE="$rc"
    return 0
}

# Script-specific half of the run record. status_kv, status_common,
# write_status_file and derive_result above are byte-identical across the three
# stateful scripts and are drift-checked by tests/static-checks.sh.
#
# Read-only: this runs inside the EXIT trap.
status_keys() {
    status_kv services_stopped "$SERVICES_STOPPED"
    status_kv docker_data_root "$DOCKER_DATA_ROOT"
    status_kv inventory_total "$INVENTORY_TOTAL"
    status_kv vxlan_count "$VXLAN_COUNT"
    status_kv netns_count "$NETNS_COUNT"
    status_kv kv_db_present "$KV_DB_PRESENT"
    status_kv gwbridge_present "$GWBRIDGE_PRESENT"
    status_kv deleted "$DELETED"
    status_kv failed_items "$FAILED_ITEMS"
    status_kv recovery_attempted "$RECOVERY_ATTEMPTED"
    status_kv recovery_succeeded "$RECOVERY_SUCCEEDED"
}

# shellcheck disable=SC2329  # invoked from on_exit, which the EXIT trap runs
derive_next_action() {
    case "$RESULT" in
        completed|nothing-to-do)
            if [ "$FAILED_ITEMS" != "0" ] && [ "$FAILED_ITEMS" != "unknown" ]; then
                NEXT_ACTION="investigate"
            else
                NEXT_ACTION="none"
            fi
            return 0
            ;;
    esac
    case "$REFUSAL_REASON" in
        not-root)  NEXT_ACTION="rerun-as-root"; return 0 ;;
        bad-usage) NEXT_ACTION="none";          return 0 ;;
    esac
    # As in the other two: only when the units are observed down.
    if [ "$SERVICES_STOPPED" = true ] &&
       unit_is_stopped docker && unit_is_stopped docker.socket &&
       unit_is_stopped containerd; then
        NEXT_ACTION="start-services"
    else
        NEXT_ACTION="investigate"
    fi
    return 0
}

# Initialised before the trap is armed and before the startup record is
# written, so no key is emitted without a value in its documented domain.
EXIT_CODE="unknown"
# Read by status_keys, so it must exist before the startup record is written.
# Its own comment further down explains why it is armed before the first stop.
SERVICES_STOPPED=false
DOCKER_DATA_ROOT="unknown"
INVENTORY_TOTAL="unknown"
VXLAN_COUNT="unknown"
NETNS_COUNT="unknown"
KV_DB_PRESENT="unknown"
GWBRIDGE_PRESENT="unknown"
DELETED=false
FAILED_ITEMS="unknown"
RECOVERY_ATTEMPTED=false
RECOVERY_SUCCEEDED="n/a"
CURRENT_PHASE="startup"

# SERVICES_STOPPED is armed BEFORE the first stop and cleared only after both
# services are verified back up. Any exit in between -- error, Ctrl-C, SIGTERM
# -- must not leave the node down.
# shellcheck disable=SC2329  # invoked indirectly by `trap on_exit EXIT` below
# Unlike upgrade-docker.sh and rollback-docker.sh, this trap RECOVERS: it
# restarts the services it stopped. So the run record is written AFTER the
# recovery attempt, not before the report. Writing first would publish
# services_stopped=true and next_action=start-services for a node whose
# services this trap had just successfully brought back.
on_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ] && [ "$SERVICES_STOPPED" = true ]; then
        RECOVERY_ATTEMPTED=true
        echo ""
        echo -e "${RED}Script failed (exit $rc) with services stopped.${NC}"
        echo "Attempting to bring docker and containerd back up..."
        if start_services; then
            RECOVERY_SUCCEEDED=true
            SERVICES_STOPPED=false
            echo -e "${GREEN}Services restored.${NC}"
        else
            RECOVERY_SUCCEEDED=false
            echo -e "${RED}AUTOMATIC RECOVERY FAILED. This node is DOWN.${NC}"
            echo ""
            echo "Recover manually:"
            echo "  systemctl start containerd"
            echo "  ctr version                     # wait until this responds"
            echo "  systemctl start docker"
            echo "  journalctl -u containerd -u docker --no-pager -n 100"
        fi
    fi

    # After the recovery attempt, so SERVICES_STOPPED and the two recovery
    # keys describe where the node actually ended up.
    if [ "$STATUS_WRITTEN" != true ]; then
        STATUS_WRITTEN=true
        derive_result "$rc" || true
        # A failed automatic recovery outranks an ordinary refusal. Several
        # refusals here fire with services already stopped -- a declined
        # deletion, an unreadable inventory -- and derive_result would report
        # `refused` for a node this trap then failed to bring back up. The node
        # being DOWN is the fact that matters; the refusal is why it got there,
        # and it stays in refusal_reason.
        # ...but NOT over `interrupted`. exit_code stays 130 or 143, and a
        # record saying result=failed beside exit_code=130 contradicts itself.
        # The recovery keys already report that recovery failed.
        if [ "$RESULT" != "interrupted" ] &&
           [ "$RECOVERY_ATTEMPTED" = true ] && [ "$RECOVERY_SUCCEEDED" != true ]; then
            RESULT="failed"
            REFUSAL_DETAIL="automatic recovery failed after: ${REFUSAL_DETAIL:-$CURRENT_PHASE}"
        fi
        derive_next_action || true
        write_status_file || true
    fi

    exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Written once here with result=running, and again from the EXIT trap on every
# path. See upgrade-docker.sh for why the ordering around it matters.
#
# NOTE: `trap on_exit EXIT` above is installed BEFORE start_services is
# defined. That is safe, and deliberately so: on_exit only calls it when
# SERVICES_STOPPED is true, which cannot happen until phase 2, long after every
# helper exists. Arming the traps here instead of after the helpers is what
# lets an interrupt during the root check still produce a 130 record.
if [ -n "$STATUS_FILE" ]; then
    EXIT_CODE="unknown"
    if ! write_status_file; then
        REFUSAL_REASON="bad-usage"
        REFUSAL_DETAIL="cannot write status file: $STATUS_FILE"
        echo "ERROR: cannot write status file: $STATUS_FILE" >&2
        exit 1
    fi
fi

if [ "$(id -u 2>/dev/null || echo 1)" != "0" ]; then
    REFUSAL_REASON="not-root"
    REFUSAL_DETAIL="must run as root"
    echo "ERROR: $SCRIPT_NAME must be run as root." >&2
    echo "It stops services and deletes network state." >&2
    exit 1
fi

exec > >(tee -a /var/log/docker-network-cleanup.log) 2>&1
LOG_STARTED=true

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
        # EOF is not an answer. Without this, a non-interactive run (ssh
        # without -t, a wrapper, cron) makes `read` fail, leaves response
        # empty, and silently applies the default to EVERY prompt -- including
        # ones that default to yes.
        if ! read -r -p "$prompt " response; then
            echo "" >&2
            echo "ERROR: stdin closed - cannot read an answer." >&2
            echo "These scripts are interactive; run them on a terminal." >&2
            exit 1
        fi
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


#############################################
# Phase 1: Detect State & Confirm Intent
#############################################
echo ""
echo "=== Phase 1: Detect State ==="
CURRENT_PHASE="phase 1 (detect state)"

SWARM_STATE=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "unknown")
echo "Swarm state: $SWARM_STATE"

if [ "$SWARM_STATE" != "active" ]; then
    echo ""
    echo -e "${YELLOW}WARNING: This node does not report an active Swarm membership.${NC}"
    echo "This script only makes sense on a Swarm node. On a standalone Docker"
    echo "host it deletes bridge network state for no benefit."
    echo ""
    if ! prompt_yes_no "Continue anyway? [y/N]" "n"; then
        REFUSAL_REASON="non-swarm-declined"
        REFUSAL_DETAIL="declined to clean a host that is not in a Swarm"
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
    REFUSAL_REASON="drain-unconfirmed"
    REFUSAL_DETAIL="drain was not attested"
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
    REFUSAL_REASON="stop-declined"
    REFUSAL_DETAIL="declined to stop docker and containerd"
    echo "Aborted. No changes made."
    exit 0
fi

#############################################
# Phase 2: Stop Services (CORRECT ORDER)
#############################################
echo ""
echo "=== Phase 2: Stop Services ==="
CURRENT_PHASE="phase 2 (stop services)"

# Armed BEFORE the stop, so an interrupt anywhere inside stop_services still
# triggers recovery on the way out.
SERVICES_STOPPED=true
if ! stop_services; then
    REFUSAL_REASON="stop-failed"
    REFUSAL_DETAIL="units were not conclusively stopped"
    exit 1
fi

#############################################
# Phase 3: Enumerate & Confirm Deletions
#############################################
echo ""
echo "=== Phase 3: Planned Deletions ==="
CURRENT_PHASE="phase 3 (enumerate)"

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
    REFUSAL_REASON="enumeration-failed"
    REFUSAL_DETAIL="could not enumerate VXLAN interfaces"
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
    REFUSAL_REASON="enumeration-failed"
    REFUSAL_DETAIL="could not enumerate $NETNS_DIR"
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

VXLAN_COUNT="${#VXLAN_IFACES[@]}"
NETNS_COUNT="${#NETNS_FILES[@]}"
INVENTORY_TOTAL="$TOTAL"

if [ "$TOTAL" -eq 0 ]; then
    echo ""
    RESULT="nothing-to-do"
    echo -e "${GREEN}Nothing to clean. Restarting services and exiting.${NC}"
    FAILED_ITEMS=0
    OPERATION_COMPLETED=true
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
    REFUSAL_REASON="delete-declined"
    REFUSAL_DETAIL="declined to delete the enumerated inventory"
    echo "Aborted. Nothing deleted - restarting services."
    FAILED_ITEMS=0
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
CURRENT_PHASE="phase 4 (delete network state)"
DELETED=true

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
CURRENT_PHASE="phase 5 (start services)"

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
CURRENT_PHASE="phase 6 (verification)"

echo "Swarm state:"
docker info --format '  LocalNodeState: {{.Swarm.LocalNodeState}}' 2>/dev/null || \
    echo "  (unable to query)"

echo ""
echo "Networks:"
docker network ls 2>/dev/null || echo "  (unable to query)"

echo ""
echo "=========================================="
FAILED_ITEMS="$FAILED"
OPERATION_COMPLETED=true
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

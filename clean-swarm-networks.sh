#!/bin/bash
# clean-swarm-networks.sh
# Reset orphaned Swarm overlay network state on a single node
VERSION="1.3.0"
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
# --status-file=PATH writes a flat key=value record of this run, and the gate
# flags below pre-declare an answer to each question the run can ask. With NO
# arguments the behaviour is exactly what it was: interactive, and every prompt
# still refuses a closed stdin.
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

# Gate state, owned by the parser. `declare -A` MUST precede any assignment to
# GATE_ANSWERS[x]: assigning first creates an INDEXED array that cannot be
# converted to an associative one afterwards.
#
# NON_INTERACTIVE is a STRICTNESS switch, not a consent switch. It grants
# nothing. It decides only what happens to a gate nobody answered: prompt, or
# refuse.
NON_INTERACTIVE=false
declare -A GATE_ANSWERS=()
# Every gate this run reached, comma-separated, appended by gate().
GATES_SEEN=""

# Record one gate answer from the command line.
#
# CONTRADICTIONS ARE REFUSED, not resolved by order. Each flag states one fact
# the caller is accountable for, so `--drain-self --no-drain-self` is not a
# preference to reconcile -- it is two incompatible claims, and letting the
# last one silently win is how a wrapper that appends a default ends up
# overriding a deliberate answer.
#
# Byte-identical across the scripts that have gate(); tests/static-checks.sh
# enforces it.
set_gate() {
    local name="$1" val="$2"
    # Two `local`s, not one: an assignment in the same `local` has not taken
    # effect yet, so $name would be empty and every contradiction would slip
    # through as "no previous answer".
    local prev="${GATE_ANSWERS[$name]:-}"
    if [ -n "$prev" ] && [ "$prev" != "$val" ]; then
        echo "ERROR: --$name and --no-$name were both given." >&2
        echo "Each flag states one fact; they cannot both be true." >&2
        exit 1
    fi
    GATE_ANSWERS[$name]="$val"
}

# The inventory hash a caller expects the enumeration to produce, from
# --expect-inventory-sha. Empty means the caller stated no expectation, which
# is the only state --confirm-delete is refused in.
EXPECT_INVENTORY_SHA=""

# --dry-run: stop, enumerate, print the inventory and its hash, restart, exit 0.
# It reaches the delete gate's "no" branch by flag instead of by prompt, so it
# is the existing decline path with a different trigger -- not a second, parallel
# way through the script.
DRY_RUN=false

usage() {
    cat <<USAGE
$SCRIPT_NAME $VERSION

Usage: $SCRIPT_NAME [OPTIONS]

Options:
  --status-file=PATH   Write a key=value record of this run to PATH. Written
                       once at startup with result=running and again on every
                       exit path, including success and interrupts.
  --non-interactive    Refuse, rather than prompt, when one of the questions
                       below has no answer. Never reads stdin.
                       Requires --status-file.
  --dry-run            Stop services, enumerate exactly what a real run would
                       delete, print it with its inventory hash, restart
                       services and exit 0. Deletes nothing. Cannot be
                       combined with a --confirm-delete answer or with
                       --expect-inventory-sha.
  --expect-inventory-sha=SHA
                       Refuse unless the inventory THIS run enumerates hashes
                       to SHA, 64 lowercase hex characters. Take the value
                       from the immediately preceding --dry-run. Required
                       whenever --confirm-delete is given.
  --help, -h           Show this help and exit.
  --version            Print the script version and exit.

Gate flags. Each states ONE fact you are accountable for, and an answer given
here is used in BOTH modes. --no-NAME states the opposite of --NAME.

  --allow-non-swarm, --no-allow-non-swarm
                       Run this on a host that is not in a Swarm anyway.
  --assume-drained, --no-assume-drained
                       A manager has already drained this node. An
                       attestation, not an instruction: it drains nothing.
  --confirm-stop, --no-confirm-stop
                       Stop docker and containerd now.
  --confirm-delete, --no-confirm-delete
                       Delete the enumerated inventory. --confirm-delete is
                       NOT accepted on its own in any mode: the inventory is
                       enumerated only after the stop, so a pre-declared yes
                       would authorise deleting a list nothing has seen.

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
        --non-interactive) NON_INTERACTIVE=true ;;
        --dry-run) DRY_RUN=true ;;
        --expect-inventory-sha=*)
            EXPECT_INVENTORY_SHA="${1#*=}"
            ;;
        --expect-inventory-sha)
            # An empty value must be rejected here too: accepted, it would
            # leave the variable empty and --confirm-delete would then be
            # refused for "no hash given", naming the flag the caller just
            # passed.
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                echo "ERROR: --expect-inventory-sha needs a 64-character hash" >&2
                exit 1
            fi
            EXPECT_INVENTORY_SHA="$2"; shift
            ;;
        # One arm per gate, spelled out rather than generated from a list. A
        # generated arm would accept --no-anything and silently record an
        # answer for a gate that does not exist; static check 1.14.1 compares
        # these literals against the `gate` call sites in both directions.
        --allow-non-swarm)              set_gate allow-non-swarm y ;;
        --no-allow-non-swarm)           set_gate allow-non-swarm n ;;
        --assume-drained)               set_gate assume-drained y ;;
        --no-assume-drained)            set_gate assume-drained n ;;
        --confirm-stop)                 set_gate confirm-stop y ;;
        --no-confirm-stop)              set_gate confirm-stop n ;;
        --confirm-delete)               set_gate confirm-delete y ;;
        --no-confirm-delete)            set_gate confirm-delete n ;;
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

# `mode` is one token. --dry-run wins over --non-interactive because the run
# deletes nothing either way, and the dry-run branch keys off this value.
# Resolved AFTER the loop so flag order on the command line cannot matter.
if [ "$DRY_RUN" = true ]; then
    MODE="dry-run"
elif [ "$NON_INTERACTIVE" = true ]; then
    MODE="non-interactive"
fi

# A dry run's whole definition is that it reaches the delete gate's "no"
# branch. A pre-declared delete answer on the same command line is two
# contradictory instructions, and guessing which one wins is how a "dry run"
# deletes something. An expected hash is equally contradictory: a dry run
# publishes a hash, it does not check one.
#
# Rejected here, at parse time, with no status file written -- the same
# treatment every other usage error gets, and the reason the runbook says a
# caller reusing one status path must compare run_id before believing a file.
if [ "$DRY_RUN" = true ]; then
    dr_conflict=""
    if [ -n "${GATE_ANSWERS[confirm-delete]:-}" ]; then
        dr_conflict="--confirm-delete/--no-confirm-delete"
    fi
    if [ -n "$EXPECT_INVENTORY_SHA" ]; then
        dr_conflict="${dr_conflict:+$dr_conflict and }--expect-inventory-sha"
    fi
    if [ -n "$dr_conflict" ]; then
        echo "ERROR: --dry-run cannot be combined with $dr_conflict." >&2
        echo "A dry run deletes nothing and checks no hash; it publishes one." >&2
        exit 1
    fi
fi

# Validated for SHAPE at parse time, so a typo is a usage error rather than a
# mismatch. Reporting "the inventory changed" for a hash that could never have
# been produced would send a caller looking at the node instead of at its own
# command line.
if [ -n "$EXPECT_INVENTORY_SHA" ] &&
   ! printf '%s' "$EXPECT_INVENTORY_SHA" | grep -qE '^[0-9a-f]{64}$'; then
    echo "ERROR: --expect-inventory-sha must be 64 lowercase hex characters." >&2
    echo "Got: $EXPECT_INVENTORY_SHA" >&2
    echo "Take the value from the immediately preceding --dry-run." >&2
    exit 1
fi

# Exit 1 conflates refusal with failure, and 130 and 143 say nothing about
# phase or service state. This interface calls the status file authoritative
# and then tells an exit-1 caller to read refusal_reason and next_action;
# without the file those fields do not exist. Refuse the combination here
# rather than shipping an interface that can be used uselessly.
if [ "$NON_INTERACTIVE" = true ] && [ -z "$STATUS_FILE" ]; then
    echo "ERROR: --non-interactive requires --status-file=PATH." >&2
    echo "Without it a refusal is indistinguishable from a failure." >&2
    exit 1
fi

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

# Which gates a run of this shape reaches, split into two lists.
#
# PURE and TOTAL. It assigns reporting globals, reads only what phase 1
# detection already established, and always returns 0. It is called from
# status_keys, which runs inside the EXIT trap, so it must not touch the node
# and must not be able to abort a trap.
predict_gates() {
    local req="" cond="" unans="" answered="" g
    local ALL="allow-non-swarm assume-drained confirm-stop confirm-delete"

    for g in $ALL; do
        if [ -n "${GATE_ANSWERS[$g]:-}" ]; then
            answered="${answered:+$answered,}$g:${GATE_ANSWERS[$g]}"
        fi
    done
    GATES_ANSWERED="$answered"

    if [ "${SWARM_STATE:-unknown}" = "unknown" ]; then
        # Phase 1 has not looked yet. `unknown` beats an empty list, which
        # would read as the definite claim that this run reaches no gates.
        GATES_REQUIRED="unknown"
        GATES_CONDITIONAL="unknown"
        GATES_UNANSWERED="unknown"
        return 0
    fi

    # Fires only on a host that does not report an active Swarm membership.
    if [ "$SWARM_STATE" != "active" ]; then
        req="allow-non-swarm"
    fi
    # These two are unconditional, which is why this script cannot be run
    # without either a terminal or both flags.
    req="${req:+$req,}assume-drained,confirm-stop"
    # Reached only when the enumeration finds something. An empty inventory
    # takes the "nothing to clean" exit and never asks.
    cond="confirm-delete"

    GATES_REQUIRED="$req"
    GATES_CONDITIONAL="$cond"

    for g in $ALL; do
        case ",$req,$cond," in
            *",$g,"*) ;;
            *) continue ;;
        esac
        if [ -n "${GATE_ANSWERS[$g]:-}" ]; then
            continue
        fi
        unans="${unans:+$unans,}$g"
    done
    GATES_UNANSWERED="$unans"
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
    # The hash of the list THIS run enumerated, and the one the caller said to
    # expect. Both are reported so an audit can see which pair was compared,
    # not merely that they agreed.
    status_kv inventory_sha "$INVENTORY_SHA"
    status_kv inventory_sha_expected "$EXPECT_INVENTORY_SHA"
    status_kv vxlan_count "$VXLAN_COUNT"
    status_kv netns_count "$NETNS_COUNT"
    status_kv kv_db_present "$KV_DB_PRESENT"
    status_kv gwbridge_present "$GWBRIDGE_PRESENT"
    status_kv deleted "$DELETED"
    status_kv failed_items "$FAILED_ITEMS"
    status_kv recovery_attempted "$RECOVERY_ATTEMPTED"
    status_kv recovery_succeeded "$RECOVERY_SUCCEEDED"
    # Recomputed here rather than cached, so a record written at any exit path
    # describes the run that actually happened. predict_gates only assigns
    # reporting globals; it touches nothing on the node.
    predict_gates
    status_kv gates_required "$GATES_REQUIRED"
    status_kv gates_conditional "$GATES_CONDITIONAL"
    status_kv gates_answered "$GATES_ANSWERED"
    status_kv gates_unanswered "$GATES_UNANSWERED"
    status_kv gates_seen "$GATES_SEEN"
}

# shellcheck disable=SC2329  # invoked from on_exit, which the EXIT trap runs
derive_next_action() {
    case "$RESULT" in
        completed|nothing-to-do)
            if [ "$FAILED_ITEMS" != "0" ] && [ "$FAILED_ITEMS" != "unknown" ]; then
                NEXT_ACTION="investigate"
            elif [ "$MODE" = "dry-run" ] && [ "$DELETED" != true ] &&
                 [ "$INVENTORY_TOTAL" != "0" ] && [ "$INVENTORY_TOTAL" != "unknown" ]; then
                # A dry run that found something: the next step is the real
                # pass, carrying the hash this one published. A dry run on a
                # node with nothing to clean takes the nothing-to-do exit and
                # gets `none`, because there is no second pass to make.
                NEXT_ACTION="proceed"
            else
                NEXT_ACTION="none"
            fi
            return 0
            ;;
    esac
    case "$REFUSAL_REASON" in
        not-root)  NEXT_ACTION="rerun-as-root"; return 0 ;;
        bad-usage) NEXT_ACTION="none";          return 0 ;;
        # Verify the fact, THEN supply the flag. Never supply it to clear the
        # error -- that is the one way this interface can be used to lie.
        gate-unanswered:*)      NEXT_ACTION="supply-flag";   return 0 ;;
        # The only sha-free path to deletion is answering the live prompt AFTER
        # enumeration, which means running the dry run first.
        inventory-sha-required) NEXT_ACTION="rerun-dry-run"; return 0 ;;
        # The node changed between the two passes, so the authorisation the
        # caller holds describes a different inventory. Only a fresh dry run
        # can produce one that describes this node.
        inventory-changed)      NEXT_ACTION="rerun-dry-run"; return 0 ;;
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
# Empty, not "unknown": it is a hash or it is nothing, and the run record's
# documented domain for it is "sha256 of the canonical inventory, or empty".
INVENTORY_SHA=""
VXLAN_COUNT="unknown"
NETNS_COUNT="unknown"
KV_DB_PRESENT="unknown"
GWBRIDGE_PRESENT="unknown"
DELETED=false
FAILED_ITEMS="unknown"
RECOVERY_ATTEMPTED=false
RECOVERY_SUCCEEDED="n/a"
CURRENT_PHASE="startup"
# Read by predict_gates from inside the EXIT trap, so it must exist before the
# startup record is written. Phase 1 replaces it with what docker reports.
SWARM_STATE="unknown"
# Assigned by predict_gates on every status write. Initialised here because the
# startup record is written before phase 1 has looked at anything.
GATES_REQUIRED="unknown"
GATES_CONDITIONAL="unknown"
GATES_UNANSWERED="unknown"
GATES_ANSWERED=""

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
# Ask one gate: a yes/no question whose answer may have been pre-declared on
# the command line. Returns 0 for yes and 1 for no, exactly like
# prompt_yes_no -- and, exactly like prompt_yes_no, EVERY call site must sit in
# an `if` or `if !` condition. Under `set -e` a bare `gate ...` that returns 1
# kills the script. The same errexit suspension is what makes the nested
# prompt_yes_no call safe here.
#
# A pre-declared answer wins in BOTH modes: --drain-self skips that prompt on
# an interactive run too. The flag states a fact; the mode only decides what
# happens to facts nobody stated.
#
# Under --non-interactive, prompt_yes_no is NEVER REACHED. Not reached and
# auto-answered -- never reached. A wrapper piping /dev/null or `yes y` still
# cannot answer anything, because there is nothing to answer.
#
# Byte-identical across upgrade-docker.sh and clean-swarm-networks.sh
# (tests/static-checks.sh enforces it), so it may not reference anything
# script-specific: the only globals it touches are GATE_ANSWERS,
# NON_INTERACTIVE, GATES_SEEN and REFUSAL_REASON.
gate() {
    local name="$1" prompt="$2" default="$3"
    local ans="${GATE_ANSWERS[$name]:-}"
    # Every gate this run actually REACHED, in order. The predicted lists say
    # what a run of this shape would reach; this says what it did.
    GATES_SEEN="${GATES_SEEN:+$GATES_SEEN,}$name"
    case "$ans" in
        y) echo "gate $name: yes (--$name)"; return 0 ;;
        n) echo "gate $name: no (--no-$name)"; return 1 ;;
    esac
    if [ "$NON_INTERACTIVE" != true ]; then
        # Explicit branches rather than a bare call plus `return`. Both forms
        # work, because `set -e` is suspended for the dynamic extent of a
        # function called in a condition -- but relying on that is relying on
        # a subtlety a later refactor can silently break.
        if prompt_yes_no "$prompt" "$default"; then return 0; else return 1; fi
    fi
    # An unstated fact fails closed. Never resolved by a default, and never by
    # reading stdin.
    REFUSAL_REASON="gate-unanswered:$name"
    echo "" >&2
    echo "ERROR: --non-interactive was given and gate '$name' was not answered." >&2
    echo "  question: $prompt" >&2
    echo "  pass --$name or --no-$name" >&2
    exit 1
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

# The canonical inventory string, hashed.
#
# NAMES AND PATHS ONLY -- never a file's contents. The libnetwork KV database's
# bytes change on every dockerd run, so hashing them would guarantee a mismatch
# between a dry run and the real one and make --expect-inventory-sha useless.
# tests/static-checks.sh enforces that this block reads no file's bytes.
#
# One line per object:
#     vxlan<TAB><interface name>
#     netns<TAB><absolute path>
#     kv<TAB><absolute path>        only when present
#     gwbridge                      only when present
#
# `ip` and `find` guarantee no ordering, so the sort is what makes the hash
# reproducible at all; LC_ALL=C so a locale cannot change it either. The four
# prefixes are distinct, so a single sort of the whole list also keeps the
# categories grouped.
#
# FAIL CLOSED. This script runs `set -e` without `pipefail`, so a failing
# `sort` upstream of a succeeding `sha256sum` would yield a confident hash of
# nothing -- and a confident hash of nothing is exactly what an attacker of
# this protocol, or a bad day, would need. The pipeline therefore runs in a
# subshell with pipefail set, and the caller treats a nonzero return as
# enumeration-failed, never as an empty inventory. Same rule the enumeration
# above already follows.
compute_inventory_sha() {
    local item
    (
        set -o pipefail
        {
            if [ "${#VXLAN_IFACES[@]}" -gt 0 ]; then
                for item in "${VXLAN_IFACES[@]}"; do printf 'vxlan\t%s\n' "$item"; done
            fi
            if [ "${#NETNS_FILES[@]}" -gt 0 ]; then
                for item in "${NETNS_FILES[@]}"; do printf 'netns\t%s\n' "$item"; done
            fi
            if [ "$KV_DB_PRESENT" = true ]; then
                printf 'kv\t%s\n' "$KV_DB"
            fi
            if [ "$GWBRIDGE_PRESENT" = true ]; then
                printf 'gwbridge\n'
            fi
        } | LC_ALL=C sort | sha256sum | awk '{print $1}'
    )
}


#############################################
# Flag consistency
#############################################
# --confirm-delete on its own is refused in EVERY mode, not only under
# --non-interactive.
#
# A pre-declared answer wins in both modes, so the flag alone on an otherwise
# interactive run would skip the post-enumeration confirmation with nobody and
# nothing ever having seen the inventory -- and the inventory is enumerated
# AFTER the stop precisely so the confirmation describes what gets deleted.
# That is the bypass this whole interface exists to prevent.
#
# The only sha-free path to deletion is answering the live prompt after
# enumeration, which is what a human does today. The hash comes from the
# immediately preceding --dry-run, which stops, enumerates and restarts without
# deleting -- so something HAS seen a list, and this run refuses unless its own
# enumeration produces the same one.
#
# What that buys is bounded, and the runbook says so: services restart between
# the two passes, so a matching hash proves the set of NAMES is unchanged, not
# that the objects behind them are the same objects.
#
# It sits HERE, before phase 1 and long before phase 2 stops anything, so a
# refusal costs a node nothing.
if [ "${GATE_ANSWERS[confirm-delete]:-}" = "y" ] && [ -z "$EXPECT_INVENTORY_SHA" ]; then
    REFUSAL_REASON="inventory-sha-required"
    REFUSAL_DETAIL="--confirm-delete requires --expect-inventory-sha from a preceding dry run"
    echo ""
    echo -e "${RED}ERROR: --confirm-delete was given without --expect-inventory-sha.${NC}"
    echo "The inventory is enumerated only after docker and containerd stop, so a"
    echo "pre-declared yes would authorise deleting a list nothing has seen."
    echo "Nothing has been changed."
    exit 1
fi

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
    if ! gate allow-non-swarm "Continue anyway? [y/N]" "n"; then
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
if ! gate assume-drained "Has this node been drained? [y/N]" "n"; then
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
if ! gate confirm-stop "Stop docker and containerd now? [y/N]" "n"; then
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
# The PARSE is status-checked as well as the command. `mapfile < <(cmd)`
# returns 0 the moment it sees EOF, whatever the producer did, so a failing awk
# would arrive as an empty array and be reported as "nothing to clean" -- the
# same fail-open the capture above exists to avoid, one step further down.
# pipefail is set inside the substitution because this script does not set it
# globally.
if ! VXLAN_PARSED=$(set -o pipefail; printf '%s' "$VXLAN_RAW" | awk -F': ' 'NF > 1 { print $2 }'); then
    REFUSAL_REASON="enumeration-failed"
    REFUSAL_DETAIL="could not parse the VXLAN interface list"
    echo -e "${RED}ERROR: could not parse the VXLAN interface list${NC}" >&2
    echo "Refusing to delete an inventory that could not be read." >&2
    exit 1
fi
# A here-string on an empty value yields ONE empty element, which would be
# reported as an interface and handed to `ip link del`. An empty parse means an
# empty array.
VXLAN_IFACES=()
if [ -n "$VXLAN_PARSED" ] && ! mapfile -t VXLAN_IFACES <<< "$VXLAN_PARSED"; then
    REFUSAL_REASON="enumeration-failed"
    REFUSAL_DETAIL="could not read the VXLAN interface list into an array"
    echo -e "${RED}ERROR: could not read the VXLAN interface list.${NC}" >&2
    exit 1
fi

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
    # Same rule as above: an empty result is an empty array, never one empty
    # element, and there is no parse step here whose status could be lost.
    NETNS_FILES=()
    if [ -n "$NETNS_RAW" ] && ! mapfile -t NETNS_FILES <<< "$NETNS_RAW"; then
        REFUSAL_REASON="enumeration-failed"
        REFUSAL_DETAIL="could not read the namespace list into an array"
        echo -e "${RED}ERROR: could not read the namespace list.${NC}" >&2
        exit 1
    fi
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

# Hashed from the arrays enumerated moments ago, AFTER the stop -- the very
# arrays phase 4 deletes from. The hash therefore describes this run's
# inventory and nothing else.
#
# ONLY when the new interface needs it: a dry run publishes it, and a run
# carrying --expect-inventory-sha compares against it. With no new flag the
# transcript is exactly what it was and the hashing adds no way for the run to
# fail -- which is the rule the whole interface is built under. (The
# fail-closed parse checks above DO add refusals a previous version would have
# sailed through; those are the deliberate fix for a fail-open enumeration, not
# a side effect of these flags.) A record from a run that computed no hash
# carries `inventory_sha=` empty, a documented value for that key.
#
# Computed before the nothing-to-clean exit below, so a dry run on a node with
# nothing to clean still reports the hash of what it found.
if [ "$DRY_RUN" = true ] || [ -n "$EXPECT_INVENTORY_SHA" ]; then
    if ! INVENTORY_SHA=$(compute_inventory_sha); then
        INVENTORY_SHA=""
        REFUSAL_REASON="enumeration-failed"
        REFUSAL_DETAIL="could not canonicalise or hash the enumerated inventory"
        echo -e "${RED}ERROR: could not hash the enumerated inventory.${NC}" >&2
        echo "Refusing to delete an inventory that could not be canonicalised." >&2
        exit 1
    fi
    # Shape-checked as well as status-checked. A pipeline that succeeded but
    # produced something that is not a digest is still a failure to enumerate,
    # and publishing it would let a later run "match" it.
    if ! printf '%s' "$INVENTORY_SHA" | grep -qE '^[0-9a-f]{64}$'; then
        REFUSAL_REASON="enumeration-failed"
        REFUSAL_DETAIL="inventory hash is not a sha256 digest: $INVENTORY_SHA"
        echo -e "${RED}ERROR: the inventory hash is not a sha256 digest.${NC}" >&2
        echo "Got: $INVENTORY_SHA" >&2
        INVENTORY_SHA=""
        exit 1
    fi

    echo ""
    echo "Inventory hash: $INVENTORY_SHA"
    echo "  covers the names and paths listed above, never their contents"
fi

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

# --dry-run reaches the delete gate's "no" branch by FLAG instead of by prompt.
# It is the existing decline path -- restart the services this run stopped and
# exit having deleted nothing -- reached a different way, not a second route
# through the script. Its purpose is to publish the hash above.
if [ "$DRY_RUN" = true ]; then
    echo ""
    echo -e "${GREEN}DRY RUN: nothing will be deleted.${NC}"
    FAILED_ITEMS=0
    OPERATION_COMPLETED=true
    start_services
    SERVICES_STOPPED=false
    echo ""
    echo "To delete exactly this inventory, re-run IMMEDIATELY with:"
    echo "  --confirm-delete --expect-inventory-sha=$INVENTORY_SHA"
    echo ""
    echo "The services this run restarted recreate namespaces and interfaces,"
    echo "so a matching hash proves the LIST of names is unchanged -- not that"
    echo "the objects behind those names are the same objects. Run the second"
    echo "pass immediately, and treat a mismatch as the node having moved."
    exit 0
fi

# The real run hashes ITS OWN enumeration and compares. A mismatch means the
# node changed between the two passes, so the authorisation the caller holds
# describes a different inventory: restart and refuse rather than delete a list
# nobody approved.
#
# This sits before the delete gate, so a mismatch cannot be answered past by a
# pre-declared --confirm-delete.
if [ -n "$EXPECT_INVENTORY_SHA" ] && [ "$EXPECT_INVENTORY_SHA" != "$INVENTORY_SHA" ]; then
    REFUSAL_REASON="inventory-changed"
    REFUSAL_DETAIL="expected $EXPECT_INVENTORY_SHA, enumerated $INVENTORY_SHA"
    echo ""
    echo -e "${RED}ERROR: this node's inventory does not match --expect-inventory-sha.${NC}"
    echo "  expected:   $EXPECT_INVENTORY_SHA"
    echo "  enumerated: $INVENTORY_SHA"
    echo ""
    echo "Nothing has been deleted. Restarting services."
    FAILED_ITEMS=0
    start_services
    SERVICES_STOPPED=false
    echo "Services restored. Run --dry-run again and pass the hash it prints."
    exit 1
fi

echo ""
if ! gate confirm-delete "Delete the state listed above? [y/N]" "n"; then
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

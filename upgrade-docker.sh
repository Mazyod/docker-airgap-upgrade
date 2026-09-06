#!/bin/bash
# upgrade-docker.sh
# Run on each AIR-GAPPED server to upgrade Docker 29.1.5 → 29.8.0
VERSION="2.6.0"
#
# Prerequisites:
# - Extract docker-upgrade-bundle.tar.gz to /opt/
#
# This script handles:
# - Docker Swarm detection and node drain/activate
# - Automatic RHEL version detection (8 or 9)
# - Proper service stop/start order (containerd before docker)
# - Direct RPM installation (no network required)
# - NVIDIA toolkit upgrade (if already installed)
# - Comprehensive verification
#
# NOTE: This script uses direct rpm installation instead of dnf/createrepo
# to avoid SSL certificate issues with corporate satellite servers
# (e.g., "SSL certificate problem: EE certificate key too weak")
#
# SCOPE OF THIS VERSION (2.5.0)
#
# This upgrade crosses containerd 2.2.1 -> 2.3.4: a MINOR containerd bump, not
# the 1.7 -> 2.x MAJOR boundary the 28.5.1 -> 29.1.5 migration crossed. 2.3 is
# containerd's first annual LTS.
#
# The minor bump does raise the containerd config version from 3 to 4, but it
# is read-compatible in the direction that matters: 2.3.4 loads an existing
# version = 3 file, migrates it in memory, and never writes it back. So no
# config migration is performed here either -- see phase 6, which explains what
# was measured and why writing a v4 config would be actively harmful.
#
# What is NOT read-compatible is the reverse direction, and that is new in this
# version: containerd 2.2.1 refuses a version = 4 config outright. Phase 0c of
# rollback-docker.sh guards it, before anything stops.
#
# Three things the 1.7 -> 2.x boundary required remain removed, because at a
# minor bump they range from inert to actively harmful:
#
#   - Phase 4.5, orphaned VXLAN/network cleanup. Extracted to the standalone
#     clean-swarm-networks.sh. The daemon now stops cleanly, so there is no
#     orphaned state to collect; running the wipe anyway just forces an
#     unnecessary overlay reconvergence. Run that script on demand if a node
#     comes back unable to attach to overlay networks.
#
#   - XFS ftype=1 validation and the interactive containerd-root relocation
#     prompt. Any node already running containerd 2.x has satisfied the ftype
#     requirement; the check cannot fire usefully here.
#
#   - containerd config regeneration. 2.3.4 reads the existing v3 config and
#     migrates it in memory, so there is nothing to migrate on disk -- and
#     regenerating would DISCARD a relocated root path, registry mirrors, and
#     runtime config, as well as writing a v4 file that blocks rollback.
#     Phase 6 verifies instead.
#
# All three are preserved in git history at upgrade-docker.sh v1.2.3 (commit
# 974683a) should a future containerd MAJOR upgrade need them back.

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

#############################################
# Agent-mode identity
#############################################
SCRIPT_NAME="upgrade-docker.sh"
LOG_FILE="/var/log/docker-upgrade.log"

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

usage() {
    cat <<USAGE
$SCRIPT_NAME $VERSION

Usage: $SCRIPT_NAME [OPTIONS]

Options:
  --preflight          Run every check that can be made with the node
                       untouched, report, and exit. Changes nothing: no
                       service is stopped, no package is installed, no
                       directory is created. Exits 0 when the real run would
                       proceed, 1 when it would refuse, 3 when there is
                       nothing to do.
  --status-file=PATH   Write a key=value record of this run to PATH. Written
                       once at startup with result=running and again on every
                       exit path, including success and interrupts.
  --non-interactive    Refuse, rather than prompt, when one of the questions
                       below has no answer. Never reads stdin.
                       Requires --status-file.
  --help, -h           Show this help and exit.
  --version            Print the script version and exit.

Gate flags. Each states ONE fact you are accountable for, and an answer given
here is used in BOTH modes. --no-NAME states the opposite of --NAME.

  --rerun-at-target, --no-rerun-at-target
                       Re-run even though all five packages already match.
  --allow-unverified-baseline, --no-allow-unverified-baseline
                       Accept this untested starting version.
  --drain-self, --no-drain-self
                       Drain this manager now.
  --proceed-with-tasks, --no-proceed-with-tasks
                       Continue with tasks possibly still on this node.
  --assume-drained, --no-assume-drained
                       A manager has already drained this node. An
                       attestation, not an instruction: it drains nothing.
  --reactivate, --no-reactivate
                       Return this manager to active at the end.

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
        --preflight) MODE="preflight" ;;
        --non-interactive) NON_INTERACTIVE=true ;;
        # One arm per gate, spelled out rather than generated from a list. A
        # generated arm would accept --no-anything and silently record an
        # answer for a gate that does not exist; static check 1.14.1 compares
        # these literals against the `gate` call sites in both directions.
        --rerun-at-target)              set_gate rerun-at-target y ;;
        --no-rerun-at-target)           set_gate rerun-at-target n ;;
        --allow-unverified-baseline)    set_gate allow-unverified-baseline y ;;
        --no-allow-unverified-baseline) set_gate allow-unverified-baseline n ;;
        --drain-self)                   set_gate drain-self y ;;
        --no-drain-self)                set_gate drain-self n ;;
        --proceed-with-tasks)           set_gate proceed-with-tasks y ;;
        --no-proceed-with-tasks)        set_gate proceed-with-tasks n ;;
        --assume-drained)               set_gate assume-drained y ;;
        --no-assume-drained)            set_gate assume-drained n ;;
        --reactivate)                   set_gate reactivate y ;;
        --no-reactivate)                set_gate reactivate n ;;
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

# `mode` is one token. --preflight wins over --non-interactive because the run
# is read-only either way, and the preflight branches key off this value.
# Resolved AFTER the loop so flag order on the command line cannot matter.
if [ "$MODE" != "preflight" ] && [ "$NON_INTERACTIVE" = true ]; then
    MODE="non-interactive"
fi

# Exit 1 conflates refusal with failure, and 130 and 143 say nothing about
# phase, service state or package state. This interface calls the status file
# authoritative and then tells an exit-1 caller to read refusal_reason and
# next_action; without the file those fields do not exist and the caller is
# back to grepping coloured prose. Refuse the combination here rather than
# shipping an interface that can be used uselessly.
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

# Which gates a run of this shape reaches, split into two lists because two of
# the six cannot be predicted from a node at rest.
#
# PURE and TOTAL. It assigns reporting globals, reads only what phase 0 and the
# phase 1 detection already established, and always returns 0. It is called
# from preflight_report AND from status_keys, which runs inside the EXIT trap,
# so it must not touch the node and must not be able to abort a trap.
#
# It consumes NODE_CLASS, SWARM_ACTIVE, IS_MANAGER and NODE_AVAILABILITY -- the
# same variables the real branches switch on, never a re-derivation of their
# conditions. That is what keeps the predictor and the branches from
# disagreeing when one of them changes.
predict_gates() {
    local req="" cond="" unans="" blocking="" answered="" g
    local avail="${NODE_AVAILABILITY:-unknown}"
    local drain_ans="${GATE_ANSWERS[drain-self]:-}"

    # A stable order, so a consumer can compare two records.
    local ALL="rerun-at-target allow-unverified-baseline drain-self proceed-with-tasks assume-drained reactivate"
    for g in $ALL; do
        if [ -n "${GATE_ANSWERS[$g]:-}" ]; then
            answered="${answered:+$answered,}$g:${GATE_ANSWERS[$g]}"
        fi
    done
    GATES_ANSWERED="$answered"

    if [ "$NODE_CLASS" = "unknown" ]; then
        # Phase 0 has not classified this node, so nothing below is knowable.
        # `unknown` beats an empty list, which would read as the definite claim
        # that this run reaches no gates at all.
        GATES_REQUIRED="unknown"
        GATES_CONDITIONAL="unknown"
        GATES_UNANSWERED="unknown"
        GATES_BLOCKING=""
        return 0
    fi

    # Does the run get PAST phase 0 at all? Everything below is in phase 1 and
    # phase 10, so a run that exits in phase 0 reaches none of it. Listing
    # those gates as "certainly reached" would be simply false.
    local proceeds=true
    if [ "$NODE_CLASS" = "at-target" ]; then
        req="${req:+$req,}rerun-at-target"
        # Unanswered resolves to "nothing to do", so only an explicit yes gets
        # this node into phase 1.
        if [ "${GATE_ANSWERS[rerun-at-target]:-}" != "y" ]; then
            proceeds=false
        fi
    fi
    if [ "$NODE_CLASS" = "unverified" ]; then
        req="${req:+$req,}allow-unverified-baseline"
        # Only an explicit NO definitively stops it. Unanswered still reports
        # the later gates, because the caller may well answer yes and then
        # needs to know what else to supply.
        if [ "${GATE_ANSWERS[allow-unverified-baseline]:-}" = "n" ]; then
            proceeds=false
        fi
    fi

    if [ "$proceeds" = true ] && [ "${SWARM_ACTIVE:-false}" = true ]; then
        if [ "${IS_MANAGER:-false}" = true ]; then
            # Phase 1 consults drain-self ONLY when availability is active or
            # unknown. On a manager already `drain` or `pause` it takes the
            # "already drained/paused" branch and never asks -- which is why
            # --no-drain-self must not suppress anything on such a node.
            # The SAME test the branch uses, in the same direction: anything
            # that is not conclusively drain or pause reaches the drain gate.
            local drain_reachable=false
            if [ "$avail" != "drain" ] && [ "$avail" != "pause" ]; then
                drain_reachable=true
            fi
            if [ "$drain_reachable" = true ]; then
                req="${req:+$req,}drain-self"
                # Fires only AFTER a drain that leaves tasks behind or cannot
                # count them, so it is never certain -- and is not reached at
                # all when the drain was declined up front.
                if [ "$drain_ans" != "n" ]; then
                    cond="${cond:+$cond,}proceed-with-tasks"
                fi
            fi
            # Phase 10 offers reactivation only to a manager, and only when it
            # observes `drain` at that point. It deliberately does not
            # reactivate a node whose availability is `pause`.
            if [ "$avail" = "drain" ]; then
                # Already drained: phase 10 certainly reaches it, whatever the
                # drain flag says, because phase 1 never consulted that flag.
                req="${req:+$req,}reactivate"
            elif [ "$drain_reachable" = true ]; then
                if [ "$drain_ans" = "y" ]; then
                    req="${req:+$req,}reactivate"
                elif [ "$drain_ans" != "n" ]; then
                    cond="${cond:+$cond,}reactivate"
                fi
            fi
        else
            # A worker cannot inspect itself, so its availability always reads
            # `unknown` and this gate always fires on a worker.
            req="${req:+$req,}assume-drained"
        fi
    fi

    GATES_REQUIRED="$req"
    GATES_CONDITIONAL="$cond"

    # Unanswered is over BOTH lists: a conditional gate with no answer is
    # reported, not refused, but a caller still needs to see it.
    #
    # BLOCKING is the subset preflight refuses over: required, unanswered, and
    # not rerun-at-target -- whose "no" branch does nothing at all, so leaving
    # it unanswered resolves safely by implication to "nothing to do".
    for g in $ALL; do
        case ",$req,$cond," in
            *",$g,"*) ;;
            *) continue ;;
        esac
        if [ -n "${GATE_ANSWERS[$g]:-}" ]; then
            continue
        fi
        unans="${unans:+$unans,}$g"
        case ",$req," in
            *",$g,"*)
                if [ "$g" != "rerun-at-target" ]; then
                    blocking="${blocking:+$blocking,}$g"
                fi
                ;;
        esac
    done
    GATES_UNANSWERED="$unans"
    GATES_BLOCKING="$blocking"
    return 0
}

# Script-specific half of the run record. status_kv, status_common,
# write_status_file and derive_result above are byte-identical across the three
# stateful scripts and are drift-checked by tests/static-checks.sh; only this
# function differs.
#
# Everything here is READ from variables the phases already maintain. Nothing
# in this function may change state -- it runs inside the EXIT trap.
status_keys() {
    local root="${CONTAINERD_ROOT:-unknown}" relocated="unknown" present="unknown"
    if [ "$root" != "unknown" ]; then
        if [ "$root" = "/var/lib/containerd" ]; then relocated=false; else relocated=true; fi
        if [ -d "$root" ]; then present=true; else present=false; fi
    fi
    local rbsafe="unknown"
    if [ -n "${CONFIG_VERSION+x}" ]; then
        if [ -z "$CONFIG_VERSION" ]; then
            rbsafe=true
        elif [ "${#CONFIG_VERSION}" -le 4 ] &&
             [ "$CONFIG_VERSION" -le "${ROLLBACK_SAFE_CONFIG_VERSION:-3}" ]; then
            rbsafe=true
        else
            rbsafe=false
        fi
    fi
    status_kv services_stopped "$SERVICES_STOPPED"
    status_kv pkg_state "$PKG_STATE"
    status_kv backup_dir "${BACKUP_DIR:-}"
    status_kv swarm_active "${SWARM_ACTIVE:-unknown}"
    status_kv swarm_role "$SWARM_ROLE_TOKEN"
    status_kv swarm_node_id "${SWARM_NODE_ID:-}"
    status_kv node_availability_before "${NODE_AVAILABILITY:-unknown}"
    status_kv node_availability_after "$NODE_AVAILABILITY_AFTER"
    status_kv drain_performed "$DRAIN_PERFORMED"
    status_kv workload_state "$WORKLOAD_STATE"
    status_kv tasks_remaining "${TASKS:-n/a}"
    status_kv containerd_config "${CONTAINERD_CONF:-/etc/containerd/config.toml}"
    status_kv containerd_config_version "${CONFIG_VERSION:-unknown}"
    status_kv containerd_config_rollback_safe "$rbsafe"
    status_kv containerd_root "$root"
    status_kv containerd_root_relocated "$relocated"
    status_kv containerd_root_present "$present"
    status_kv rpmnew_present "$(if [ -f "${CONTAINERD_CONF:-/etc/containerd/config.toml}.rpmnew" ]; then echo true; else echo false; fi)"
    status_kv nvidia "$NVIDIA_RESULT"
    status_kv node_class "$NODE_CLASS"
    # Recomputed here rather than cached, so a record written at any exit path
    # describes the run that actually happened. predict_gates only assigns
    # reporting globals; it touches nothing on the node.
    predict_gates
    status_kv gates_required "$GATES_REQUIRED"
    status_kv gates_conditional "$GATES_CONDITIONAL"
    status_kv gates_answered "$GATES_ANSWERED"
    status_kv gates_unanswered "$GATES_UNANSWERED"
    status_kv gates_seen "$GATES_SEEN"
    status_kv drain_attested_by "$DRAIN_ATTESTED_BY"
    status_kv docker_ce_before "${CURRENT_DOCKER:-unknown}"
    status_kv docker_ce_after "$AFTER_DOCKER"
    status_kv docker_ce_expected "${EXPECTED_DOCKER_VERSION:-unknown}"
    status_kv docker_ce_cli_before "${CURRENT_DOCKER_CLI:-unknown}"
    status_kv docker_ce_cli_after "$AFTER_DOCKER_CLI"
    status_kv containerd_io_before "${CURRENT_CONTAINERD:-unknown}"
    status_kv containerd_io_after "$AFTER_CONTAINERD"
    status_kv containerd_io_expected "${EXPECTED_CONTAINERD_VERSION:-unknown}"
    status_kv containerd_io_release_before "${CURRENT_CONTAINERD_REL:-unknown}"
    status_kv containerd_io_release_after "$AFTER_CONTAINERD_REL"
    status_kv containerd_io_release_expected "${EXPECTED_CT_REL_FULL:-unknown}"
    status_kv buildx_before "${CURRENT_BUILDX:-unknown}"
    status_kv buildx_after "$AFTER_BUILDX"
    status_kv buildx_expected "${EXPECTED_BUILDX_VERSION:-unknown}"
    status_kv compose_before "${CURRENT_COMPOSE:-unknown}"
    status_kv compose_after "$AFTER_COMPOSE"
    status_kv compose_expected "${EXPECTED_COMPOSE_VERSION:-unknown}"
}

# The token form of the decision on_exit already prints in English. It never
# says "rollback": CLAUDE.md is explicit that retry-versus-rollback is an
# operator judgement that depends on why the run failed, and a token that made
# that call would contradict the invariant the trap exists to honour.
derive_next_action() {
    case "$RESULT" in
        ready)
            NEXT_ACTION="proceed"
            return 0
            ;;
        completed|nothing-to-do)
            NEXT_ACTION="none"
            return 0
            ;;
    esac
    # Reason-specific first: these name a repair, and "investigate" would send
    # an agent to read a log that already says exactly what to do.
    case "$REFUSAL_REASON" in
        not-root)               NEXT_ACTION="rerun-as-root";  return 0 ;;
        bad-usage)              NEXT_ACTION="none";           return 0 ;;
        payload-invalid)        NEXT_ACTION="rebuild-bundle"; return 0 ;;
        relocated-root-missing) NEXT_ACTION="fix-mount";      return 0 ;;
        drain-unconfirmed)      NEXT_ACTION="drain-from-manager"; return 0 ;;
        # Verify the fact, THEN supply the flag. Never supply it to clear the
        # error -- that is the one way this interface can be used to lie.
        gate-unanswered:*)      NEXT_ACTION="supply-flag";    return 0 ;;
        # dry-run-failed is NOT rebuild-bundle: rpm refuses for disk space and
        # host dependency reasons too, and neither is fixed by a new bundle.
        # tasks-present is NOT drain-from-manager: on the manager path the
        # drain has already run, and what is needed is to wait and look.
        dry-run-failed|tasks-present)
                                NEXT_ACTION="investigate";    return 0 ;;
    esac
    # start-services only when the units are OBSERVED down. SERVICES_STOPPED
    # is set before the first stop command, so a stop that failed partway
    # leaves it true with docker still running -- telling an agent to start an
    # already-running daemon, and hiding a genuinely stuck unit behind a
    # confident instruction.
    if [ "$SERVICES_STOPPED" = true ] &&
       [ "$PKG_STATE" = "untouched" ] &&
       unit_is_stopped docker && unit_is_stopped docker.socket &&
       unit_is_stopped containerd; then
        NEXT_ACTION="start-services"
    else
        NEXT_ACTION="investigate"
    fi
    return 0
}

# Everything --preflight adds, in one place so the read-only claim can be read
# in one place. It reports what phase 0 and the phase 1 detection already
# established, plus the two phase-6 reads hoisted here, and exits.
#
# READ-ONLY. Nothing in this function or on the path that reaches it may stop a
# service, install a package, create a directory, repair dnf, or drain a node.
# tests/static-checks.sh check 1.14.12 greps the block for exactly that.
#
# It DOES report which gates the run would reach, in two lists. Two of the six
# depend on what the run does rather than on what a node at rest looks like, so
# advertising a single list that silently omitted them would be worse than
# advertising nothing. `gates_required` is what preflight refuses over under
# --non-interactive; `gates_conditional` is reported and never refused over,
# because the run may never reach it.
preflight_report() {
    local rc=0 pf_root_missing=false

    echo ""
    echo -e "${GREEN}==========================================${NC}"
    echo -e "${GREEN}PREFLIGHT${NC}"
    echo -e "${GREEN}==========================================${NC}"
    echo ""
    echo "  docker-ce:             ${CURRENT_DOCKER:-absent} -> $EXPECTED_DOCKER_VERSION"
    echo "  containerd.io:         ${CURRENT_CONTAINERD:-absent} -> $EXPECTED_CONTAINERD_VERSION"
    echo "  containerd.io release: ${CURRENT_CONTAINERD_REL:-absent} -> $EXPECTED_CT_REL_FULL"
    echo "  buildx:                ${CURRENT_BUILDX:-absent} -> $EXPECTED_BUILDX_VERSION"
    echo "  compose:               ${CURRENT_COMPOSE:-absent} -> $EXPECTED_COMPOSE_VERSION"
    echo "  classification:        $NODE_CLASS"
    echo "  swarm:                 ${SWARM_STATE:-unknown} ($SWARM_ROLE_TOKEN, availability ${NODE_AVAILABILITY:-n/a})"
    # The check phase 2 runs, without the `dnf clean all` and `rpm --rebuilddb`
    # repair it follows the check with. A broken dnf is worth knowing about
    # here; repairing it is a mutation and belongs to the real run.
    if dnf check >/dev/null 2>&1; then
        echo "  dnf state:             ok"
    else
        echo -e "  dnf state:             ${YELLOW}has issues (the real run would attempt a repair)${NC}"
    fi
    echo "  nvidia toolkit:        $(if [ "$NVIDIA_INSTALLED" = true ]; then echo present; else echo absent; fi)"
    predict_gates
    echo "  gates required:        ${GATES_REQUIRED:-<none>}"
    echo "  gates conditional:     ${GATES_CONDITIONAL:-<none>}"
    echo "  gates answered:        ${GATES_ANSWERED:-<none>}"
    echo "  gates unanswered:      ${GATES_UNANSWERED:-<none>}"
    echo ""

    # Hoisted from phase 6. Both are pure reads, and both matter here for the
    # same reason: phase 6 runs AFTER the rpm transaction with services
    # stopped, so a problem it finds costs a node that is already down.
    echo "containerd config: $CONTAINERD_CONF"
    if [ ! -f "$CONTAINERD_CONF" ]; then
        echo -e "${YELLOW}  NOTE: absent. Phase 6 would generate a default, and under this${NC}"
        echo -e "${YELLOW}  containerd that default is a version the rollback containerd${NC}"
        echo -e "${YELLOW}  cannot load. Put a config in place first if you may roll back.${NC}"
        # Deliberately left UNSET, so the record reports rollback safety as
        # `unknown`. Setting it to "" would mean "a file with no version key",
        # which reads as legacy and therefore rollback-SAFE -- the opposite of
        # what the warning above just said, and the opposite of what the real
        # run produces, since phase 6 generates a v4 default here. Preflight
        # cannot read that default itself: `containerd config default` would be
        # answered by the 2.2.1 binary still installed, not by the one that
        # will write the file.
    else
        CONFIG_VERSION=$(read_config_version "$CONTAINERD_CONF")
        if [ -z "$CONFIG_VERSION" ]; then
            echo "  version: unset (treated as legacy; rollback-safe)"
        elif [ "${#CONFIG_VERSION}" -gt 4 ]; then
            echo -e "${YELLOW}  version reads as '$CONFIG_VERSION' -- not a valid config version.${NC}"
            echo "  The file may be corrupt. Services would fail to start in phase 8."
        elif [ "$CONFIG_VERSION" -le "$ROLLBACK_SAFE_CONFIG_VERSION" ]; then
            echo "  version: $CONFIG_VERSION (rollback-safe)"
        else
            echo -e "${YELLOW}  version: $CONFIG_VERSION -- the rollback containerd loads at most${NC}"
            echo -e "${YELLOW}  $ROLLBACK_SAFE_CONFIG_VERSION. A rollback would leave containerd unable to start${NC}"
            echo -e "${YELLOW}  until this file is reverted. Not a refusal: the upgrade itself${NC}"
            echo -e "${YELLOW}  is unaffected.${NC}"
        fi
    fi

    CONTAINERD_ROOT=$(read_containerd_root "$CONTAINERD_CONF")
    echo "containerd root: $CONTAINERD_ROOT"
    if relocated_root_is_missing "$CONTAINERD_ROOT"; then
        echo ""
        echo -e "${RED}  ERROR: the relocated containerd root does not exist.${NC}"
        echo "  Its filesystem is almost certainly not mounted. The real run would"
        echo "  discover this in PHASE 6 -- after the rpm transaction, with docker"
        echo "  and containerd stopped. Mount it first:"
        echo "    findmnt --target $(dirname "$CONTAINERD_ROOT")"
        echo "    lsblk; cat /etc/fstab"
        # Recorded, not claimed. Which finding becomes THE refusal is decided
        # below, in the order the real run would meet them -- and this one
        # lives in phase 6, so almost everything outranks it.
        pf_root_missing=true
    elif [ "$CONTAINERD_ROOT" != "/var/lib/containerd" ]; then
        echo "  relocated and present:"
        findmnt --target "$CONTAINERD_ROOT" 2>/dev/null | sed 's/^/    /' || true
    fi

    # THE ORDER BELOW IS THE ORDER THE REAL RUN MEETS THESE, and that is the
    # whole point of the block. Reporting whichever finding this function
    # happened to evaluate first would name a phase-6 mount problem on a node
    # the real run refuses in phase 0, and send an agent to fix the wrong
    # thing. Each arm claims the refusal only if nothing earlier did.
    #
    #   phase 0   allow-unverified-baseline, declined in advance
    #   phase 0/1 a required gate with no answer, first in canonical order --
    #             which IS phase order
    #   phase 1   assume-drained, declined in advance (worker only)
    #   phase 6   the relocated root
    #
    # An explicit NO on a gate whose "no" branch ABORTS means the real run
    # would not proceed, and `ready` says it would. Those two arms apply in
    # BOTH modes, because a pre-declared answer wins in both. Only two gates
    # qualify: `drain-self` no proceeds without draining and `reactivate` no
    # leaves the node drained, neither of which stops the run, and
    # `proceed-with-tasks` is conditional so a no there cannot be predicted.
    if [ "$rc" -eq 0 ] && [ "$NODE_CLASS" = "unverified" ] &&
       [ "${GATE_ANSWERS[allow-unverified-baseline]:-}" = "n" ]; then
        echo ""
        echo -e "${YELLOW}  --no-allow-unverified-baseline was given and this node is on an${NC}"
        echo -e "${YELLOW}  unverified starting version, so the real run would stop in phase 0.${NC}"
        REFUSAL_REASON="unverified-baseline"
        REFUSAL_DETAIL="declined in advance to upgrade from ${CURRENT_DOCKER:-absent} / containerd.io ${CURRENT_CONTAINERD:-absent}"
        rc=1
    fi

    # An unanswered gate is only a refusal when the caller asked for the strict
    # mode. Without --non-interactive both lists are informational: the real
    # run would simply ask.
    #
    # A conditional gate is never refused over. The run may never reach it, and
    # refusing would force a caller to pre-answer a question that may not be
    # asked. The bounded claim this leaves is stated in docs/AGENT-RUNBOOK.md:
    # preflight validates every gate that is certain and NAMES the ones that
    # are not.
    if [ "$rc" -eq 0 ] && [ "$NON_INTERACTIVE" = true ] && [ -n "$GATES_BLOCKING" ]; then
        echo ""
        echo -e "${RED}  ERROR: required gate(s) with no answer: $GATES_BLOCKING${NC}"
        echo "  The real run would refuse when it reached the first of them."
        echo "  Verify each fact, then pass the matching --NAME or --no-NAME flag."
        REFUSAL_REASON="gate-unanswered:${GATES_BLOCKING%%,*}"
        REFUSAL_DETAIL="required gate(s) unanswered: $GATES_BLOCKING"
        rc=1
    fi

    if [ "$rc" -eq 0 ] && [ "${SWARM_ACTIVE:-false}" = true ] && [ "$IS_MANAGER" != true ] &&
       [ "${GATE_ANSWERS[assume-drained]:-}" = "n" ]; then
        echo ""
        echo -e "${YELLOW}  --no-assume-drained was given and this is a worker, so the real${NC}"
        echo -e "${YELLOW}  run would stop in phase 1, before touching anything.${NC}"
        REFUSAL_REASON="drain-unconfirmed"
        REFUSAL_DETAIL="worker drain declined in advance"
        rc=1
    fi

    # Last, because phase 6 is where the real run meets it -- after every gate
    # above. The finding was printed further up either way; this only decides
    # whether it is the one the caller is told to act on.
    if [ "$rc" -eq 0 ] && [ "$pf_root_missing" = true ]; then
        REFUSAL_REASON="relocated-root-missing"
        REFUSAL_DETAIL="$CONTAINERD_ROOT does not exist; its filesystem is probably not mounted"
        rc=1
    fi

    echo ""
    # Already-at-target WINS over anything found above, and the ordering is the
    # whole point. The real run's default answer to "re-run anyway?" is no, and
    # that branch exits before phase 6 -- so a finding that only a re-run would
    # hit must not be reported as a refusal the default path would produce.
    # It is still printed above; it is just not what the caller is told to act on.
    if [ "$PREFLIGHT_NOTHING_TO_DO" = true ]; then
        RESULT="nothing-to-do"
        REFUSAL_REASON=""
        REFUSAL_DETAIL=""
        echo -e "${GREEN}Nothing to do: this node is already fully at the target.${NC}"
        if [ "$rc" -ne 0 ]; then
            echo -e "${YELLOW}A finding above would block a re-run, but the default answer${NC}"
            echo -e "${YELLOW}to the re-run prompt is no, so the real run would exit first.${NC}"
        fi
        rc=3
    elif [ "$rc" -eq 0 ]; then
        RESULT="ready"
        echo -e "${GREEN}Ready: the real run would proceed from here.${NC}"
        echo "Nothing on this node was changed."
    else
        echo -e "${RED}Not ready. Nothing on this node was changed.${NC}"
    fi
    echo "=========================================="
    return "$rc"
}

# Captured at a point where rpm is known to have exited. Doing this inside the
# EXIT trap instead would risk `rpm -q` blocking on the rpmdb lock if the run
# was killed mid-transaction, and a trap that hangs is worse than a missing key.
capture_after_versions() {
    AFTER_DOCKER=$(rpm -q docker-ce --queryformat '%{VERSION}' 2>/dev/null || echo "absent")
    AFTER_DOCKER_CLI=$(rpm -q docker-ce-cli --queryformat '%{VERSION}' 2>/dev/null || echo "absent")
    AFTER_CONTAINERD=$(rpm -q containerd.io --queryformat '%{VERSION}' 2>/dev/null || echo "absent")
    AFTER_CONTAINERD_REL=$(rpm -q containerd.io --queryformat '%{RELEASE}' 2>/dev/null || echo "absent")
    AFTER_BUILDX=$(rpm -q docker-buildx-plugin --queryformat '%{VERSION}' 2>/dev/null || echo "absent")
    AFTER_COMPOSE=$(rpm -q docker-compose-plugin --queryformat '%{VERSION}' 2>/dev/null || echo "absent")
}

#############################################
# Failure Handling
#############################################
# `set -e` means any unhandled failure exits immediately. From phase 4 onward
# that leaves docker and containerd stopped, and the operator -- on a box with
# no internet -- gets a bare shell prompt and no idea what state the node is in.
#
# This does NOT auto-restart services. Once the RPM transaction has run, whether
# to retry or roll back is a judgement call that depends on why it failed, and
# guessing wrong is worse than stopping. It tells the operator exactly where it
# broke and what their options are.
CURRENT_PHASE="startup"
SERVICES_STOPPED=false

# Service state and package state are tracked SEPARATELY. Conflating them
# produces the two worst possible messages: telling an operator the node is
# unchanged when packages were in fact replaced, or telling them the original
# packages are intact when an rpm transaction died halfway through one.
#
#   untouched  - rpm has not been invoked
#   attempted  - rpm was invoked; outcome unknown, host state may be partial
#   installed  - rpm returned success
PKG_STATE="untouched"

# Every variable status_keys reads is initialised HERE, before the trap is
# armed. The startup record is written moments later, and a key with no value
# would violate its own documented domain. "unknown" means "not observed at the
# time this record was written", which is the normal state of most keys in a
# startup record.
EXIT_CODE="unknown"
SWARM_ROLE_TOKEN="unknown"
NODE_AVAILABILITY_AFTER="unknown"
DRAIN_PERFORMED=false
WORKLOAD_STATE="not-checked"
NVIDIA_RESULT="not-attempted"
PREFLIGHT_NOTHING_TO_DO=false
# How the drain fact reached this run. An audit afterwards can then tell a
# flag that was TRUSTED from a question a human ANSWERED. Neither makes the
# fact true; the record only says which one was relied on.
DRAIN_ATTESTED_BY="not-required"
# Assigned by predict_gates on every status write. Initialised here because the
# startup record is written before phase 0 has classified anything.
GATES_REQUIRED="unknown"
GATES_CONDITIONAL="unknown"
GATES_UNANSWERED="unknown"
GATES_ANSWERED=""
GATES_BLOCKING=""
# The installed-version classification, computed ONCE in phase 0 and switched
# on by the branches below. Slice 4's gate predictor consumes the same variable
# rather than re-deriving the conditions, which is how the predictor and the
# branches are kept from disagreeing.
#   at-target  all five packages, and the containerd release, already match
#   partial    some match and some do not
#   baseline   on the tested starting versions
#   unverified anything else
NODE_CLASS="unknown"
AFTER_DOCKER="unknown"
AFTER_DOCKER_CLI="unknown"
AFTER_CONTAINERD="unknown"
AFTER_CONTAINERD_REL="unknown"
# The full expected %{RELEASE}. The constant further down is only its numeric
# half, and a record carrying "2" would be as ambiguous as the version-only
# check the release assertion exists to replace. Declared HERE, with the other
# globals the writer reads, because the startup record is written long before
# RHEL_VER is known; the real value is assigned the moment it is.
EXPECTED_CT_REL_FULL="unknown"
AFTER_BUILDX="unknown"
AFTER_COMPOSE="unknown"

# shellcheck disable=SC2329  # invoked indirectly by `trap on_exit EXIT` below
on_exit() {
    local rc=$?

    # BEFORE the rc==0 short-circuit below. Placed after it, a successful
    # upgrade -- the single most common outcome anyone needs to confirm --
    # would leave the startup record saying result=running for ever.
    # `|| true` so a failing write cannot replace the real exit code with its
    # own, and STATUS_WRITTEN so gate-style exits cannot re-enter the trap.
    if [ "$STATUS_WRITTEN" != true ]; then
        STATUS_WRITTEN=true
        derive_result "$rc" || true
        derive_next_action || true
        write_status_file || true
    fi

    [ "$rc" -eq 0 ] && exit 0

    # A usage error or a non-root invocation already printed the one line that
    # explains it, and nothing has happened yet. The full state report below
    # would bury that line under twenty lines about packages and services that
    # were never touched.
    case "$REFUSAL_REASON" in
        not-root|bad-usage) exit "$rc" ;;
    esac

    # --preflight touches nothing, so the state report below -- services,
    # packages, backup directory, rollback advice -- describes a node this run
    # never went near, and every phase-0 refusal has already printed the one
    # line that explains itself. On exit 3 the report is worse than redundant:
    # it prints "UPGRADE FAILED" directly underneath preflight's own green
    # "Nothing to do", so the same output says both.
    if [ "$MODE" = "preflight" ]; then
        exit "$rc"
    fi

    echo ""
    echo -e "${RED}==========================================${NC}"
    echo -e "${RED}UPGRADE FAILED during: $CURRENT_PHASE (exit $rc)${NC}"
    echo -e "${RED}==========================================${NC}"
    echo ""

    if [ "$SERVICES_STOPPED" = true ]; then
        echo "Services:  STOPPED - this node is DOWN"
    else
        echo "Services:  running (or never stopped by this script)"
    fi

    case "$PKG_STATE" in
        untouched)
            echo "Packages:  UNCHANGED - rpm was never run"
            ;;
        attempted)
            echo -e "Packages:  ${RED}UNKNOWN - the rpm transaction did not complete cleanly${NC}"
            ;;
        installed)
            echo "Packages:  NEW packages installed successfully"
            ;;
    esac

    echo ""
    echo "Check what is actually installed before doing anything:"
    echo "  rpm -q docker-ce docker-ce-cli containerd.io"
    echo "  journalctl -u containerd --no-pager -n 100"
    echo "  journalctl -u docker --no-pager -n 100"
    echo ""

    if [ "$SERVICES_STOPPED" = true ]; then
        case "$PKG_STATE" in
            untouched)
                echo "The node still has its original packages. Bring it back with:"
                echo "  systemctl start containerd"
                echo "  sleep 5"
                echo "  systemctl start docker"
                ;;
            attempted)
                echo -e "${YELLOW}Do NOT assume either version is fully installed.${NC}"
                echo "Confirm the installed versions first, then choose:"
                echo "  a) Re-run this script (it is safe to re-run from the top)"
                echo "  b) Roll back:  /opt/docker-offline/rollback-docker.sh"
                ;;
            installed)
                echo "Choose one:"
                echo "  a) Start services:  systemctl start containerd && sleep 5 && systemctl start docker"
                echo "  b) Roll back:       /opt/docker-offline/rollback-docker.sh"
                ;;
        esac
    elif [ "$PKG_STATE" != "untouched" ]; then
        echo "Services are up but the upgrade did not finish cleanly."
        echo "Verify the versions above match what you expect before returning"
        echo "this node to service."
    fi

    echo ""
    echo "Backup: ${BACKUP_DIR:-<none created yet>}"
    echo "Log:    /var/log/docker-upgrade.log"

    if [ "$SWARM_ACTIVE" = true ] && [ -n "$SWARM_NODE_ID" ]; then
        echo ""
        echo -e "${YELLOW}This node may still be DRAINED in the Swarm.${NC}"
        echo "Once it is healthy, reactivate it from a manager:"
        echo "  docker node update --availability active $SWARM_NODE_ID"
    fi
    echo "=========================================="
    exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Written once here with result=running, and again from the EXIT trap on every
# path. Without the startup record, a run killed hard enough that the trap
# never fires leaves a caller reading the PREVIOUS run's file and believing it.
#
# This write is also the writability check, and it must succeed. A create-and-
# remove probe beside the file proves less: it never exercises the rename,
# which is what a sticky directory or a root-owned existing target blocks.
if [ -n "$STATUS_FILE" ]; then
    EXIT_CODE="unknown"
    if ! write_status_file; then
        REFUSAL_REASON="bad-usage"
        REFUSAL_DETAIL="cannot write status file: $STATUS_FILE"
        echo "ERROR: cannot write status file: $STATUS_FILE" >&2
        exit 1
    fi
fi

# Before the tee, deliberately -- see the ordering note above.
if [ "$(id -u 2>/dev/null || echo 1)" != "0" ]; then
    REFUSAL_REASON="not-root"
    REFUSAL_DETAIL="must run as root"
    echo "ERROR: $SCRIPT_NAME must be run as root." >&2
    echo "It stops services, replaces packages and writes to /var/log." >&2
    exit 1
fi

# Log file
exec > >(tee -a /var/log/docker-upgrade.log) 2>&1
LOG_STARTED=true

echo "=========================================="
echo "Docker Upgrade: 29.1.5 → 29.8.0"
echo "Script Version: $VERSION"
echo "Server: $(hostname)"
echo "Date: $(date)"
echo "=========================================="


#############################################
# Expected package versions
#############################################
# Asserted against RPM metadata in phase 0, not against filenames. Renaming a
# file, or extracting the PREVIOUS bundle (which has an identical directory
# layout), must not be able to reach "UPGRADE COMPLETE" without these versions
# actually being installed.
#
# Keep in sync with download-docker-packages.sh, rollback-docker.sh,
# simulate-upgrade.sh and README.md -- see CLAUDE.md.
EXPECTED_DOCKER_VERSION="29.8.0"
EXPECTED_CONTAINERD_VERSION="2.3.4"

# The containerd.io RPM RELEASE, asserted separately because VERSION alone is
# no longer enough to identify the build. containerd.io 2.3.4 was published
# twice: -1 and -2 have the same %{VERSION}, the same file list and the same
# Requires, and differ only in /usr/bin/runc (1.4.3 in -1, 1.5.1 in -2).
#
# A version-only check therefore accepts either. An operator whose bundle was
# built from the -1 window would pass phase 0 cleanly and get a container
# runtime nobody chose. Assert the release too, and fail closed.
#
# This is the RELEASE's numeric part only. The full %{RELEASE} string is
# "2.el9" on RHEL 9 and "2.el8" on RHEL 8, so the constant is the same for both
# majors; containerd_release_matches() builds the full expected string from
# this value and the host's own RHEL major and compares it exactly.
EXPECTED_CONTAINERD_RELEASE="2"

# buildx and compose version INDEPENDENTLY of docker-ce -- these are their own
# versions, not derived from the engine version, and must never be set to it.
# They are still asserted: the bundle ships specific builds, and a bundle that
# quietly carries last round's plugins should not report success.
EXPECTED_BUILDX_VERSION="0.37.0"
EXPECTED_COMPOSE_VERSION="5.5.1"

# The baseline this upgrade was designed and tested against. Starting anywhere
# else is a warning, except containerd 1.x which is a hard stop -- that crosses
# the major boundary whose handling was removed in v2.0.0.
SUPPORTED_FROM_DOCKER="29.1.5"
SUPPORTED_FROM_CONTAINERD="2.2.1"

# Packages permitted in the upgrade directory.
ALLOWED_PKGS="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

#############################################
# Helper Functions
#############################################

# Does an RPM %{RELEASE} name the containerd.io build this upgrade wants?
#
# Shared by phase 0 (which checks the PAYLOAD), the already-at-target gate and
# phase 9 (which checks what rpm actually INSTALLED), so the three cannot drift
# apart.
#
# The comparison is EXACT, not a prefix match. %{RELEASE} for these packages is
# exactly "<n>.el<major>" -- "2.el9" -- because the architecture lives in
# %{ARCH} and nothing else is appended. There is therefore nothing legitimate
# to tolerate on either side, and every tolerance is a hole: splitting on the
# first ".el" and ignoring the remainder accepted "2.el9.el8" and "2.el9.foo",
# and comparing only the part before ".el" accepted a bare "2".
#
# Both halves of the string carry weight. The <n> is what separates
# containerd.io 2.3.4-2 (runc 1.5.1) from 2.3.4-1 (runc 1.4.3), which are
# indistinguishable by %{VERSION}. The el<major> catches an el8 RPM on an el9
# host, which matters most in phase 9 and in the already-at-target gate, where
# phase 0's own el check has no say.
containerd_release_matches() {
    local rel="$1" want="$2" major="$3"

    # All three must be present. An empty `want` would make the expected string
    # ".el9", which a release of ".el9" satisfies -- so a guard whose
    # expectation had been blanked would still report a match. Refuse instead.
    [ -n "$rel" ] && [ -n "$want" ] && [ -n "$major" ] || return 1

    [ "$rel" = "${want}.el${major}" ]
}

CONTAINERD_CONF="/etc/containerd/config.toml"

# The highest config version the ROLLBACK containerd (2.2.1) can load. A config
# at or below this is safe to leave in place for an emergency rollback.
ROLLBACK_SAFE_CONFIG_VERSION=3

# Read the top-level `version` key. The awk stops at the first [section] header
# so only top-level keys count, matching the `root` parser below.
read_config_version() {
    # Tolerate an optionally quoted value. containerd wants an integer here, so
    # `version = "4"` is not a config it would accept anyway -- but reading it
    # as 4 makes this guard FIRE, whereas failing to match would silently read
    # as "no version key" and wave the file through. Err toward firing.
    awk '/^[[:space:]]*\[/ { exit } { print }' "$1" 2>/dev/null \
        | sed -n "s/^[[:space:]]*version[[:space:]]*=[[:space:]]*['\"]\{0,1\}\([0-9][0-9]*\)['\"]\{0,1\}.*/\1/p" \
        | head -1
}

# Read the configured containerd root. TOP-LEVEL keys only -- the awk stops at
# the first [section] header -- and the sed tolerates leading whitespace and
# any of the three quoting styles. Both halves matter, and both were bugs once:
# without the awk a `root` inside a [plugins."..."] section is returned as if
# it were containerd's own, and without the leading-whitespace tolerance an
# INDENTED top-level root parses as empty and silently falls back to the
# default, which defeats the relocated-root check below.
#
# Extracted from phase 6 so preflight and phase 6 cannot disagree about what
# the configured root is. Read-only.
read_containerd_root() {
    local root
    root=$(awk '/^[[:space:]]*\[/ { exit } { print }' "$1" 2>/dev/null \
        | sed -n "s/^[[:space:]]*root[[:space:]]*=[[:space:]]*['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}.*/\1/p" \
        | head -1)
    printf '%s\n' "${root:-/var/lib/containerd}"
}

# Is the configured root a RELOCATED one that has gone missing? A pure
# filesystem read: it creates nothing and repairs nothing.
#
# The default root simply not existing yet is unremarkable -- phase 6 creates
# it. A relocated root that is absent almost always means its filesystem is not
# mounted, and creating it would start containerd against an empty root and
# make every image and snapshot look lost.
relocated_root_is_missing() {
    local root="$1"
    [ "$root" != "/var/lib/containerd" ] && [ ! -d "$root" ]
}

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
# unit `deactivating` would sail through and rpm would run against a live
# daemon. Require a successful query, a conclusively stopped ActiveState, and
# no live MainPID.
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

# NOTE: check_xfs_ftype() lived here. It validated that containerd's root was
# on a filesystem with XFS ftype=1 and offered an interactive relocation when
# it was not. That requirement arrives with containerd 2.x, so it mattered when
# this script crossed 1.7 -> 2.x. Any node running 2.2.1 today has already
# satisfied it. Recover it from upgrade-docker.sh v1.2.3 (commit 974683a) if a
# future containerd major upgrade needs it again.

wait_for_services() {
    local deadline=$((SECONDS + 60)) remaining budget replicas pending

    echo "Waiting up to 60 seconds for Swarm replica counts to converge..."
    WORKLOAD_STATE="unknown"
    while [ "$SECONDS" -lt "$deadline" ]; do
        remaining=$((deadline - SECONDS))
        # Recheck after scheduling delays: timeout 0 would disable its deadline.
        if [ "$remaining" -le 0 ]; then break; fi
        budget=5
        if [ "$remaining" -lt "$budget" ]; then budget=$remaining; fi
        # Bound the query too: a hung manager must not turn this advisory wait
        # into an indefinite outage. Query failure is unknown, never zero tasks.
        if replicas=$(timeout "$budget" docker service ls --format '{{.Replicas}}' 2>/dev/null); then
            # Validate every row before claiming convergence. Empty output means
            # no services; malformed output cannot prove healthy workloads.
            pending=$(printf '%s\n' "$replicas" | awk '
                NF == 0 { next }
                $1 !~ /^[0-9]+\/[0-9]+$/ { invalid=1; next }
                { split($1, r, "/"); if (r[1] != r[2]) n++ }
                END { if (invalid) print "unknown"; else print n+0 }')
            if [ "$pending" = "0" ]; then
                WORKLOAD_STATE="converged"
                echo "Swarm replica counts converged; application checks are still required."
                return 0
            elif [ "$pending" = "unknown" ]; then
                WORKLOAD_STATE="unknown"
                echo "  Waiting: unrecognized Swarm replica counts."
            else
                WORKLOAD_STATE="timeout"
                echo "  Waiting: $pending service(s) have differing running/desired counts."
            fi
        else
            WORKLOAD_STATE="unknown"
            echo "  Waiting: 'docker service ls' not answering yet."
        fi

        remaining=$((deadline - SECONDS))
        if [ "$remaining" -le 0 ]; then break; fi
        budget=5
        if [ "$remaining" -lt "$budget" ]; then budget=$remaining; fi
        sleep "$budget"
    done

    echo -e "${YELLOW}WARNING: Workload recovery is $WORKLOAD_STATE; packages were upgraded.${NC}"
    echo "Inspect from a manager: docker service ls; docker service ps --no-trunc <service>"
    # Advisory: timeout/unknown does not turn a completed package upgrade into
    # a failed transaction. The run record carries the separate workload state.
    return 0
}

#############################################
# Pre-flight Checks
#############################################

# Detect RHEL version
RHEL_VER=$(rpm -E %rhel)
# Assigned the moment RHEL_VER exists, not after the payload checks: a release
# rejection would otherwise report the expected release as "unknown" when it
# was already knowable.
EXPECTED_CT_REL_FULL="${EXPECTED_CONTAINERD_RELEASE}.el${RHEL_VER}"
PKG_DIR="/opt/docker-offline/rhel${RHEL_VER}"

if [ ! -d "$PKG_DIR" ]; then
    REFUSAL_REASON="payload-invalid"
    REFUSAL_DETAIL="package directory not found: $PKG_DIR"
    echo -e "${RED}ERROR: Package directory not found: $PKG_DIR${NC}"
    echo "Please extract docker-upgrade-bundle.tar.gz to /opt/"
    exit 1
fi

echo "Detected RHEL version: $RHEL_VER"
echo "Using packages from: $PKG_DIR"

# Check if NVIDIA toolkit is installed
NVIDIA_INSTALLED=false
if rpm -q nvidia-container-toolkit &>/dev/null; then
    NVIDIA_INSTALLED=true
    echo "NVIDIA Container Toolkit detected - will upgrade"
fi

#############################################
# Phase 0: Validate Package Payload
#############################################
# Runs BEFORE the Swarm drain in phase 1 and before services stop in phase 4.
# Everything that can be checked without touching the node is checked here, so
# a bad bundle fails while the node is still serving traffic AND still active
# in the Swarm. A failure below leaves the node genuinely untouched.
echo ""
echo "=== Phase 0: Validate Package Payload ==="
CURRENT_PHASE="phase 0 (validate packages)"

echo "Validating packages in $PKG_DIR..."

shopt -s nullglob
PKG_FILES=("$PKG_DIR"/*.rpm)
shopt -u nullglob

if [ "${#PKG_FILES[@]}" -eq 0 ]; then
    REFUSAL_REASON="payload-invalid"
    REFUSAL_DETAIL="no .rpm files in $PKG_DIR"
    echo -e "${RED}ERROR: No .rpm files found in $PKG_DIR${NC}"
    echo "The bundle is empty or was extracted to the wrong location."
    exit 1
fi
echo "  Found ${#PKG_FILES[@]} package(s)"

# Digest check (--nosignature): a NOKEY signature result on a host that never
# imported Docker's GPG key is not corruption, but a bad digest is.
PKG_ERRORS=0
for rpmfile in "${PKG_FILES[@]}"; do
    if ! rpm -K --nosignature "$rpmfile" >/dev/null 2>&1; then
        echo -e "${RED}  ERROR: ${rpmfile##*/} failed digest verification${NC}"
        PKG_ERRORS=$((PKG_ERRORS + 1))
    fi
done

# Assert on RPM METADATA, never on filenames. The previous bundle has the same
# directory layout and the same filename shapes, so a filename check would let
# an operator "upgrade" 29.1.5 -> 29.1.5 and be told it succeeded.
echo ""
echo "  Package inventory:"
FOUND_DOCKER_CE=""
FOUND_DOCKER_CLI=""
FOUND_CONTAINERD=""
FOUND_CONTAINERD_REL=""
FOUND_BUILDX=""
FOUND_COMPOSE=""
HOST_ARCH=$(uname -m)
SEEN_NAMES=""

for rpmfile in "${PKG_FILES[@]}"; do
    meta=$(rpm -qp --queryformat '%{NAME} %{VERSION} %{RELEASE} %{ARCH}' "$rpmfile" 2>/dev/null || true)
    if [ -z "$meta" ]; then
        echo -e "${RED}    ERROR: ${rpmfile##*/} is not a readable RPM${NC}"
        PKG_ERRORS=$((PKG_ERRORS + 1))
        continue
    fi

    read -r p_name p_ver p_rel p_arch <<< "$meta"
    echo "    $p_name $p_ver-$p_rel.$p_arch"

    case " $ALLOWED_PKGS " in
        *" $p_name "*) ;;
        *)
            echo -e "${RED}    ERROR: unexpected package '$p_name' in upgrade dir${NC}"
            PKG_ERRORS=$((PKG_ERRORS + 1))
            continue
            ;;
    esac

    # Two copies of the same package is the failure mode you get by extracting
    # a new bundle OVER an old /opt/docker-offline. Both would be handed to
    # rpm, and the version assertion below -- being a scalar -- would only
    # remember whichever was seen last. Reject it outright.
    case " $SEEN_NAMES " in
        *" $p_name "*)
            echo -e "${RED}    ERROR: duplicate $p_name in $PKG_DIR${NC}"
            echo "           Remove the directory and re-extract the bundle cleanly."
            PKG_ERRORS=$((PKG_ERRORS + 1))
            continue
            ;;
    esac
    SEEN_NAMES="$SEEN_NAMES $p_name"

    if [ "$p_arch" != "$HOST_ARCH" ] && [ "$p_arch" != "noarch" ]; then
        echo -e "${RED}    ERROR: $p_name is $p_arch, host is $HOST_ARCH${NC}"
        PKG_ERRORS=$((PKG_ERRORS + 1))
        continue
    fi

    # RELEASE carries the RHEL major (e.g. "1.el9"). Without this, an el8 RPM
    # sitting in the rhel9 directory passes name/version/arch checks cleanly.
    case "$p_rel" in
        *".el${RHEL_VER}"*) ;;
        *)
            echo -e "${RED}    ERROR: $p_name release '$p_rel' is not el${RHEL_VER}${NC}"
            PKG_ERRORS=$((PKG_ERRORS + 1))
            continue
            ;;
    esac

    case "$p_name" in
        docker-ce)             FOUND_DOCKER_CE="$p_ver" ;;
        docker-ce-cli)         FOUND_DOCKER_CLI="$p_ver" ;;
        containerd.io)         FOUND_CONTAINERD="$p_ver"
                               FOUND_CONTAINERD_REL="$p_rel" ;;
        docker-buildx-plugin)  FOUND_BUILDX="$p_ver" ;;
        docker-compose-plugin) FOUND_COMPOSE="$p_ver" ;;
    esac
done

check_version() {
    local label="$1" found="$2" want="$3"
    if [ -z "$found" ]; then
        echo -e "${RED}  ERROR: no $label package found in $PKG_DIR${NC}"
        PKG_ERRORS=$((PKG_ERRORS + 1))
    elif [ "$found" != "$want" ]; then
        echo -e "${RED}  ERROR: $label is $found, expected $want${NC}"
        echo "         This looks like the wrong bundle for this upgrade."
        PKG_ERRORS=$((PKG_ERRORS + 1))
    else
        echo -e "  ${GREEN}✓ $label $found${NC}"
    fi
}

echo ""
check_version "docker-ce"             "$FOUND_DOCKER_CE"  "$EXPECTED_DOCKER_VERSION"
check_version "docker-ce-cli"         "$FOUND_DOCKER_CLI" "$EXPECTED_DOCKER_VERSION"
check_version "containerd.io"         "$FOUND_CONTAINERD" "$EXPECTED_CONTAINERD_VERSION"
check_version "docker-buildx-plugin"  "$FOUND_BUILDX"     "$EXPECTED_BUILDX_VERSION"
check_version "docker-compose-plugin" "$FOUND_COMPOSE"    "$EXPECTED_COMPOSE_VERSION"

# containerd.io needs its RELEASE asserted as well, because its VERSION stopped
# being a unique identifier at 2.3.4: upstream published -1 and -2 with the same
# version, the same file list and the same Requires, differing only in which
# runc they carry (1.4.3 vs 1.5.1). check_version above passes for either, so
# without this a bundle built during the -1 window installs a runtime nobody
# chose and still reports success.
#
# Every branch below either passes or increments PKG_ERRORS. There is no path
# that reads as a match by default -- an empty, malformed, or unexpected
# release is an error, not a shrug.
check_containerd_release() {
    local found="$1" want="$2"

    if containerd_release_matches "$found" "$want" "$RHEL_VER"; then
        echo -e "  ${GREEN}✓ containerd.io release $found${NC}"
        return
    fi

    # ONE refusal, for every shape that is not the wanted one -- including an
    # empty release. containerd_release_matches already refuses an empty string,
    # so a separate branch for it duplicated the predicate rather than adding
    # anything, and the two messages had drifted apart.
    echo -e "${RED}  ERROR: containerd.io release is ${found:-<none>}, expected ${want}.el${RHEL_VER}${NC}"
    if [ -z "$found" ]; then
        # No containerd.io in the payload at all, or one an earlier check
        # rejected (arch, el-major, duplicate) and `continue`d past before the
        # release was recorded. check_version has already said which.
        echo "         containerd.io is missing from the payload, or an earlier check"
        echo "         rejected it before its release could be read."
    fi
    echo "         containerd.io $EXPECTED_CONTAINERD_VERSION was published more than once."
    echo "         Release -1 carries runc 1.4.3; -2 carries runc 1.5.1."
    echo "         This bundle has the wrong build. Re-download it."
    PKG_ERRORS=$((PKG_ERRORS + 1))
}

check_containerd_release "$FOUND_CONTAINERD_REL" "$EXPECTED_CONTAINERD_RELEASE"

if [ "$PKG_ERRORS" -gt 0 ]; then
    echo ""
    REFUSAL_REASON="payload-invalid"
    REFUSAL_DETAIL="$PKG_ERRORS problem(s) with the package payload"
    echo -e "${RED}ERROR: $PKG_ERRORS problem(s) with the package payload.${NC}"
    echo "Nothing on this node has been changed. Re-transfer the correct bundle:"
    echo "  expected docker-ce $EXPECTED_DOCKER_VERSION, containerd.io $EXPECTED_CONTAINERD_VERSION-$EXPECTED_CONTAINERD_RELEASE"
    exit 1
fi

# Dry-run the exact transaction phase 5 will perform, while services are still
# running and the node is still in the Swarm. rpm refusing the set -- for an
# unsatisfiable dependency, a conflict, a disk-space shortfall -- is something
# to discover now, not after phase 4 has taken the node down.
echo ""
echo "Dry-running the upgrade transaction..."
if ! rpm -Uvh --test --force "${PKG_FILES[@]}" 2>&1; then
    echo ""
    echo -e "${RED}ERROR: rpm rejected the upgrade transaction (dry run).${NC}"
    echo "Nothing on this node has been changed. The output above says why."
    echo ""
    REFUSAL_REASON="dry-run-failed"
    REFUSAL_DETAIL="rpm --test refused the transaction"
    echo "Common causes: unsatisfied dependency, or insufficient space in /var."
    echo "  df -h /var /usr"
    exit 1
fi
echo -e "${GREEN}Transaction dry run passed.${NC}"

echo -e "${GREEN}Package payload validated.${NC}"

CURRENT_DOCKER=$(rpm -q docker-ce --queryformat '%{VERSION}' 2>/dev/null || echo "")
CURRENT_DOCKER_CLI=$(rpm -q docker-ce-cli --queryformat '%{VERSION}' 2>/dev/null || echo "")
CURRENT_CONTAINERD=$(rpm -q containerd.io --queryformat '%{VERSION}' 2>/dev/null || echo "")
# The installed RELEASE too. Without it, "already fully at the target" is a
# claim about %{VERSION} alone, and %{VERSION} stopped identifying the build at
# containerd.io 2.3.4 -- see EXPECTED_CONTAINERD_RELEASE.
CURRENT_CONTAINERD_REL=$(rpm -q containerd.io --queryformat '%{RELEASE}' 2>/dev/null || echo "")
CURRENT_BUILDX=$(rpm -q docker-buildx-plugin --queryformat '%{VERSION}' 2>/dev/null || echo "")
CURRENT_COMPOSE=$(rpm -q docker-compose-plugin --queryformat '%{VERSION}' 2>/dev/null || echo "")

# UNCONDITIONAL hard stop, evaluated before any of the branches below.
#
# This was previously nested inside the "unexpected starting version" branch,
# which made it bypassable: a node with docker-ce already at 29.8.0 but
# containerd still on 1.x took the partial-upgrade branch instead and never
# reached this check -- letting the script attempt exactly the major migration
# it no longer supports.
case "$CURRENT_CONTAINERD" in
    1.*)
        echo ""
        echo -e "${RED}=========================================="
        echo "ERROR: containerd 1.x DETECTED"
        echo -e "==========================================${NC}"
        echo ""
        echo "  this node has containerd.io $CURRENT_CONTAINERD"
        echo ""
        echo "This script version does NOT handle the containerd 1.7 -> 2.x"
        echo "major migration. The config migration, XFS ftype check and"
        echo "orphaned-network cleanup that migration requires were removed in"
        echo "v2.0.0."
        echo ""
        REFUSAL_REASON="containerd-1x"
        REFUSAL_DETAIL="containerd.io $CURRENT_CONTAINERD predates the supported range"
        echo "Use upgrade-docker.sh v1.2.3 (commit 974683a) for that path."
        echo ""
        echo "Aborting. Nothing has been changed."
        exit 1
        ;;
esac

# If the node is ALREADY fully at the target, offer to skip. ALL FIVE packages
# must match, not just the core three: a partially applied transaction can leave
# correct core packages beside stale plugins, and that node still needs this run.
#
# The containerd.io RPM RELEASE is part of "at the target", not a detail. This
# branch ends in `exit 0` on the default answer, so anything it treats as
# already-done never reaches phase 9's assertions. A node holding
# containerd.io 2.3.4-1 matches every %{VERSION} here while running runc 1.4.3;
# without the release test it would be told there was nothing to do and keep a
# runtime nobody chose. A release mismatch falls through to the partial-upgrade
# branch below, which is correct -- that node does need this run.
# Classify ONCE. The branches below switch on NODE_CLASS rather than
# re-evaluating these expressions, so a future gate predictor reading the same
# variable cannot disagree with the branch that actually runs.
if [ "$CURRENT_DOCKER" = "$EXPECTED_DOCKER_VERSION" ] &&
   [ "$CURRENT_DOCKER_CLI" = "$EXPECTED_DOCKER_VERSION" ] &&
   [ "$CURRENT_CONTAINERD" = "$EXPECTED_CONTAINERD_VERSION" ] &&
   containerd_release_matches "$CURRENT_CONTAINERD_REL" "$EXPECTED_CONTAINERD_RELEASE" "$RHEL_VER" &&
   [ "$CURRENT_BUILDX" = "$EXPECTED_BUILDX_VERSION" ] &&
   [ "$CURRENT_COMPOSE" = "$EXPECTED_COMPOSE_VERSION" ]; then
    NODE_CLASS="at-target"
elif [ "$CURRENT_DOCKER" = "$EXPECTED_DOCKER_VERSION" ] ||
     [ "$CURRENT_CONTAINERD" = "$EXPECTED_CONTAINERD_VERSION" ]; then
    NODE_CLASS="partial"
elif [ "$CURRENT_DOCKER" != "$SUPPORTED_FROM_DOCKER" ] ||
     [ "$CURRENT_CONTAINERD" != "$SUPPORTED_FROM_CONTAINERD" ]; then
    NODE_CLASS="unverified"
else
    NODE_CLASS="baseline"
fi

if [ "$NODE_CLASS" = "at-target" ]; then
    echo ""
    echo -e "${YELLOW}NOTE: this node is already fully at the target versions:${NC}"
    echo "  docker-ce $CURRENT_DOCKER, docker-ce-cli $CURRENT_DOCKER_CLI,"
    echo "  containerd.io $CURRENT_CONTAINERD-$CURRENT_CONTAINERD_REL, buildx $CURRENT_BUILDX,"
    echo "  compose $CURRENT_COMPOSE"
    PREFLIGHT_NOTHING_TO_DO=true
    if [ "$MODE" = "preflight" ]; then
        # A pre-declared answer wins in both modes, so a preflight carrying
        # --rerun-at-target must report what the REAL run would do -- proceed
        # -- not the default the prompt would have applied.
        if [ "${GATE_ANSWERS[rerun-at-target]:-}" = "y" ]; then
            PREFLIGHT_NOTHING_TO_DO=false
            echo "Preflight: --rerun-at-target was given, so the real run would proceed."
        else
            echo "Preflight: the real run would offer to re-run and default to no."
        fi
    elif [ "$NON_INTERACTIVE" = true ] && [ -z "${GATE_ANSWERS[rerun-at-target]:-}" ]; then
        # The ONE gate whose unanswered state resolves safely by implication.
        # gate() refuses generically -- it has to, it is byte-identical across
        # scripts and cannot special-case a name -- so the exception is handled
        # HERE, before the call, rather than inside it.
        #
        # Its "no" branch does nothing at all, so a distinct exit code beats an
        # abort: the caller learns the node is already done instead of being
        # told to go and answer a question whose answer changes nothing.
        RESULT="nothing-to-do"
        # The run REACHED this gate and resolved it, just not through gate().
        # Leaving it out would make gates_seen omit the one decision that
        # determined the outcome.
        GATES_SEEN="${GATES_SEEN:+$GATES_SEEN,}rerun-at-target"
        echo "Nothing to do, and --rerun-at-target was not given. Exiting without changes."
        exit 3
    elif ! gate rerun-at-target "Re-run the upgrade anyway? [y/N]" "n"; then
        # Exit 0 here has always meant "nothing done", which is indistinguishable
        # from "upgrade completed" by status alone. The record separates them.
        RESULT="nothing-to-do"
        echo "Nothing to do. Exiting without changes."
        # Exit 3 ONLY when the caller asked for the richer taxonomy. An
        # interactive decline still exits 0, exactly as it always has, so no
        # existing wrapper sees a new code.
        #
        # This is also the one gate whose unanswered state resolves safely by
        # implication: its "no" branch does nothing at all, so under
        # --non-interactive it reports "nothing to do" rather than refusing.
        if [ "$NON_INTERACTIVE" = true ]; then
            exit 3
        fi
        exit 0
    fi
elif [ "$NODE_CLASS" = "partial" ]; then
    echo ""
    echo -e "${YELLOW}NOTE: some packages are already at the target and some are${NC}"
    echo -e "${YELLOW}not - this looks like a partial upgrade.${NC}"
    echo "  docker-ce:             ${CURRENT_DOCKER:-absent} (want $EXPECTED_DOCKER_VERSION)"
    echo "  docker-ce-cli:         ${CURRENT_DOCKER_CLI:-absent} (want $EXPECTED_DOCKER_VERSION)"
    echo "  containerd.io:         ${CURRENT_CONTAINERD:-absent}-${CURRENT_CONTAINERD_REL:-?} (want $EXPECTED_CONTAINERD_VERSION-$EXPECTED_CONTAINERD_RELEASE.el$RHEL_VER)"
    echo "  docker-buildx-plugin:  ${CURRENT_BUILDX:-absent} (want $EXPECTED_BUILDX_VERSION)"
    echo "  docker-compose-plugin: ${CURRENT_COMPOSE:-absent} (want $EXPECTED_COMPOSE_VERSION)"
    echo "Proceeding to complete it."
else
    # Confirm the node is on the baseline this upgrade was designed and tested
    # against. Not a hard failure -- an intermediate 29.x is probably fine --
    # but it must not pass silently.
    if [ "$NODE_CLASS" = "unverified" ]; then
        echo ""
        echo -e "${YELLOW}=========================================="
        echo "WARNING: UNEXPECTED STARTING VERSION"
        echo -e "==========================================${NC}"
        echo ""
        echo "  tested upgrade path: $SUPPORTED_FROM_DOCKER / containerd.io $SUPPORTED_FROM_CONTAINERD"
        echo "  this node has:       ${CURRENT_DOCKER:-absent} / containerd.io ${CURRENT_CONTAINERD:-absent}"
        echo ""
        if [ "$MODE" = "preflight" ]; then
            echo "Preflight: the real run would ask whether to continue from here."
        elif ! gate allow-unverified-baseline "Continue from this unverified starting version? [y/N]" "n"; then
            REFUSAL_REASON="unverified-baseline"
            REFUSAL_DETAIL="declined to upgrade from ${CURRENT_DOCKER:-absent} / containerd.io ${CURRENT_CONTAINERD:-absent}"
            echo "Aborting. Nothing has been changed."
            exit 0
        fi
    fi
fi

#############################################
# Phase 1: Docker Swarm Detection & Drain
#############################################
echo ""
echo "=== Phase 1: Docker Swarm Check ==="
CURRENT_PHASE="phase 1 (swarm drain)"

SWARM_ACTIVE=false
SWARM_NODE_ID=""
IS_MANAGER=false

# Exact compare, not `grep -q "active"`. A non-Swarm host reports "inactive",
# which CONTAINS "active" -- the unanchored grep matched it and classified every
# standalone Docker host as a Swarm worker. That node then got a drain
# instruction with an empty node ID and a "has this been drained?" prompt
# defaulting to No, so the upgrade could not proceed on a host that was never
# in a Swarm. clean-swarm-networks.sh already compared exactly; this brings the
# two into line.
SWARM_STATE=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "unknown")
echo "Swarm state: $SWARM_STATE"

if [ "$SWARM_STATE" = "active" ]; then
    SWARM_ACTIVE=true
    SWARM_NODE_ID=$(docker info --format '{{.Swarm.NodeID}}' 2>/dev/null)
    SWARM_ROLE=$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null)

    if [ "$SWARM_ROLE" = "true" ]; then
        IS_MANAGER=true
        SWARM_ROLE_TOKEN="manager"
        echo "This node is a Swarm MANAGER (Node ID: $SWARM_NODE_ID)"
    else
        SWARM_ROLE_TOKEN="worker"
        echo "This node is a Swarm WORKER (Node ID: $SWARM_NODE_ID)"
    fi

    # Check current availability (only managers can inspect nodes)
    if [ "$IS_MANAGER" = true ]; then
        NODE_AVAILABILITY=$(docker node inspect "$SWARM_NODE_ID" --format '{{.Spec.Availability}}' 2>/dev/null || echo "unknown")
        # `|| echo unknown` only covers a FAILING inspect. An inspect that
        # succeeds and prints nothing -- a renamed field, a future format --
        # leaves this empty, and an empty value is not a member of this key's
        # domain. Normalise, so both the branch below and the record see a
        # value they can reason about.
        NODE_AVAILABILITY="${NODE_AVAILABILITY:-unknown}"
        echo "Current availability: $NODE_AVAILABILITY"
    else
        # Workers cannot check their own status, assume active
        NODE_AVAILABILITY="unknown"
        echo "Current availability: unknown (worker nodes cannot self-inspect)"
    fi

    if [ "$MODE" = "preflight" ]; then
        # Preflight stops before this branch: everything below it either
        # prompts or drains, and preflight does neither. Which gates the real
        # run would reach IS reported, from predict_gates -- see
        # preflight_report.
        echo "Preflight: this node would be asked about draining."
    # FAIL CLOSED. This used to test for `active` or `unknown`, which meant any
    # other value -- an empty string from an inspect that succeeded and printed
    # nothing, a future availability, a malformed line -- fell through to the
    # "already drained/paused" branch and SKIPPED the drain on a node nobody
    # had drained. Only a conclusive `drain` or `pause` may skip it. Same rule
    # as verify_unit_stopped: an unrecognised answer is not a safe answer.
    elif [ "$NODE_AVAILABILITY" != "drain" ] && [ "$NODE_AVAILABILITY" != "pause" ]; then
        if [ "$IS_MANAGER" = true ]; then
            # Manager can drain itself
            echo ""
            echo -e "${YELLOW}WARNING: This node is currently ACTIVE in the Swarm.${NC}"
            echo "It should be drained before upgrading to avoid service disruption."
            echo ""

            if gate drain-self "Drain this node now? [Y/n]" "y"; then
                # Recorded BEFORE the drain, so an audit can tell a flag that
                # was trusted from a question a human answered. The flag does
                # not make the fact true; the record says which it was.
                if [ -n "${GATE_ANSWERS[drain-self]:-}" ]; then
                    DRAIN_ATTESTED_BY="flag"
                else
                    DRAIN_ATTESTED_BY="prompt"
                fi
                echo "Draining node..."
                docker node update --availability drain "$SWARM_NODE_ID"
                DRAIN_PERFORMED=true

                echo "Waiting for tasks to migrate..."
                sleep 10

                # Show remaining tasks
                # Run the query separately so its failure is distinguishable
                # from "no tasks left". Piping straight into `wc -l` reports 0
                # when docker errors, which reads as "all tasks migrated" and
                # would wave the operator past a drain that never happened.
                if TASK_LIST=$(docker node ps "$SWARM_NODE_ID" --filter "desired-state=running" --format '{{.Name}}' 2>/dev/null); then
                    TASKS=$(printf '%s' "$TASK_LIST" | grep -c . || true)
                else
                    echo -e "${YELLOW}WARNING: could not query tasks on this node.${NC}"
                    echo "Cannot confirm the drain completed. Check from a manager:"
                    echo "  docker node ps $SWARM_NODE_ID"
                    TASKS="unknown"
                fi
                # "unknown" must be handled before the numeric test: `[ unknown
                # -gt 0 ]` errors with status 2, and inside an `if` that falls
                # through to the success branch -- reporting "all tasks
                # migrated" precisely when we could not tell.
                if [ "$TASKS" = "unknown" ]; then
                    if ! gate proceed-with-tasks "Continue with upgrade anyway? [y/N]" "n"; then
                        REFUSAL_REASON="tasks-present"
                        REFUSAL_DETAIL="task count could not be confirmed after the drain"
                        echo "Aborting. Confirm the drain from a manager and re-run."
                        exit 1
                    fi
                elif [ "$TASKS" -gt 0 ]; then
                    echo "Tasks still on this node: $TASKS"
                    docker node ps "$SWARM_NODE_ID" --filter "desired-state=running" || true
                    echo ""
                    # The SAME gate as the unknown-count branch above, on
                    # purpose: one flag covers both. The distinction is not
                    # lost -- it survives in the record as tasks_remaining=3
                    # versus tasks_remaining=unknown.
                    if ! gate proceed-with-tasks "Continue with upgrade anyway? [y/N]" "n"; then
                        REFUSAL_REASON="tasks-present"
                        REFUSAL_DETAIL="$TASKS task(s) still on this node after the drain"
                        echo "Aborting. Please wait for tasks to migrate and re-run."
                        exit 1
                    fi
                else
                    echo "No tasks remain assigned here with desired state running."
                fi
            else
                echo -e "${YELLOW}Proceeding without draining. Services may be disrupted.${NC}"
            fi
        else
            # Worker cannot drain itself
            echo ""
            echo -e "${RED}=========================================="
            echo "WARNING: WORKER NODE CANNOT DRAIN ITSELF"
            echo -e "==========================================${NC}"
            echo ""
            echo "This is a Swarm WORKER node. Workers cannot drain themselves."
            echo "Please drain this node from a MANAGER node first:"
            echo ""
            echo -e "  ${YELLOW}docker node update --availability drain $SWARM_NODE_ID${NC}"
            echo ""
            echo "Or by hostname:"
            echo ""
            echo -e "  ${YELLOW}docker node update --availability drain $(hostname)${NC}"
            echo ""

            if ! gate assume-drained "Has this node been drained from a manager? [y/N]" "n"; then
                REFUSAL_REASON="drain-unconfirmed"
                REFUSAL_DETAIL="worker drain was not attested"
                echo "Aborting. Please drain this node from a manager and re-run."
                exit 1
            fi
            # Accepted. An attestation, not a drain: nothing on this node
            # verified it, and the record says whether a flag or a human said so.
            if [ -n "${GATE_ANSWERS[assume-drained]:-}" ]; then
                DRAIN_ATTESTED_BY="flag"
            else
                DRAIN_ATTESTED_BY="prompt"
            fi
        fi
    else
        echo "Node is already $NODE_AVAILABILITY. Proceeding with upgrade."
    fi
else
    SWARM_ROLE_TOKEN="none"
    echo "This node is NOT part of a Docker Swarm."
fi

#############################################
# Preflight exit
#############################################
# Everything above this line is read-only: phase 0 validates the payload and
# dry-runs the transaction with `rpm -Uvh --test`, and phase 1 only queries
# Swarm state. Everything BELOW it mutates -- phase 2 repairs dnf, phase 3
# writes a backup, phase 4 stops services.
#
# The exit sits here rather than earlier so preflight covers the whole of
# phase 0, which is where almost everything checkable lives.
if [ "$MODE" = "preflight" ]; then
    CURRENT_PHASE="preflight"
    if preflight_report; then
        PREFLIGHT_RC=0
    else
        PREFLIGHT_RC=$?
    fi
    exit "$PREFLIGHT_RC"
fi

#############################################
# Phase 2: Pre-upgrade Verification
#############################################
echo ""
echo "=== Phase 2: Pre-upgrade Verification ==="
CURRENT_PHASE="phase 2 (pre-upgrade checks)"

# Check dnf state for corruption
echo "Checking dnf state..."
if ! dnf check 2>/dev/null; then
    echo -e "${YELLOW}WARNING: dnf has issues. Attempting cleanup...${NC}"
    dnf clean all
    rpm --rebuilddb
fi

# Verify current packages are installed
echo "Current installed versions:"
rpm -q docker-ce docker-ce-cli containerd.io 2>/dev/null || echo "Some packages not installed"

# Check services (don't fail if not running)
echo "Service status:"
systemctl is-active docker 2>/dev/null && echo "  docker: running" || echo "  docker: not running"
systemctl is-active containerd 2>/dev/null && echo "  containerd: running" || echo "  containerd: not running"


#############################################
# Phase 3: Backup
#############################################
echo ""
echo "=== Phase 3: Backup ==="
CURRENT_PHASE="phase 3 (backup)"
BACKUP_DIR="/root/docker-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

docker version > "$BACKUP_DIR/docker-version.txt" 2>&1 || true
containerd --version > "$BACKUP_DIR/containerd-version.txt" 2>&1 || true
docker ps -a > "$BACKUP_DIR/containers.txt" 2>&1 || true
docker images --all > "$BACKUP_DIR/images.txt" 2>&1 || true
docker network ls > "$BACKUP_DIR/networks.txt" 2>&1 || true
cp /etc/containerd/config.toml "$BACKUP_DIR/config.toml" 2>/dev/null || true
cp /etc/docker/daemon.json "$BACKUP_DIR/daemon.json" 2>/dev/null || true
rpm -qa | grep -E "(docker|containerd)" > "$BACKUP_DIR/packages.txt" 2>&1 || true

echo "Backup saved to: $BACKUP_DIR"

#############################################
# Phase 4: Stop Services (CORRECT ORDER)
#############################################
echo ""
echo "=== Phase 4: Stop Services ==="
CURRENT_PHASE="phase 4 (stop services)"

# Armed before the first stop so the EXIT trap reports accurate state if
# anything below fails.
SERVICES_STOPPED=true

# Stop docker first
echo "Stopping docker..."
systemctl stop docker docker.socket 2>/dev/null || true
sleep 2

# Then stop containerd
echo "Stopping containerd..."
systemctl stop containerd 2>/dev/null || true
sleep 2

# Verify rather than assume. Replacing packages under a live daemon turns a
# routine upgrade into an unrecoverable one. docker.socket is checked too: if
# it survives while dockerd is down, anything that touches the socket
# socket-activates dockerd again, mid-transaction.
echo "Confirming services are stopped..."
STOP_FAILED=0
for unit in docker docker.socket containerd; do
    if verify_unit_stopped "$unit"; then
        echo "    $unit: stopped"
    else
        STOP_FAILED=$((STOP_FAILED + 1))
    fi
done

if [ "$STOP_FAILED" -gt 0 ]; then
    echo ""
    REFUSAL_REASON="stop-failed"
    REFUSAL_DETAIL="$STOP_FAILED unit(s) not conclusively stopped"
    echo -e "${RED}ERROR: $STOP_FAILED unit(s) not conclusively stopped.${NC}"
    echo "Refusing to replace packages under a running daemon."
    echo "Investigate with: systemctl status docker docker.socket containerd"
    exit 1
fi

echo "Services confirmed stopped."

# NOTE: Phase 4.5, orphaned VXLAN/network cleanup, lived here and ran on every
# Swarm node. It is now the standalone clean-swarm-networks.sh, run on demand.
# The phase number is intentionally left vacant so phases 5-10 keep the
# identities they have in the runbook and in the logs of prior upgrades.

#############################################
# Phase 5: Upgrade Packages (Direct RPM)
#############################################
echo ""
echo "=== Phase 5: Upgrade Packages ==="
CURRENT_PHASE="phase 5 (rpm upgrade)"

# Use direct rpm installation - no network required, avoids SSL issues
# with corporate satellite servers.
#
# PKG_FILES was populated and digest-verified in phase 2. Using the array
# rather than re-globbing means this cannot silently install a different set
# than the one that was validated, and cannot pass a literal "*.rpm" to rpm if
# the directory turns up empty.
echo "Installing packages from: $PKG_DIR"
printf '  %s\n' "${PKG_FILES[@]##*/}"

echo "Running rpm upgrade..."

# Marked BEFORE the call, not after. An rpm transaction that fails partway --
# a scriptlet error, or a SIGINT mid-transaction -- can leave the host changed
# while still returning nonzero. Setting this afterwards would have the trap
# confidently report "original packages intact" over a half-migrated node.
PKG_STATE="attempted"
rpm -Uvh --force "${PKG_FILES[@]}"
PKG_STATE="installed"
capture_after_versions

echo -e "${GREEN}Packages upgraded.${NC}"

#############################################
# Phase 6: Verify containerd Config
#############################################
echo ""
echo "=== Phase 6: Verify containerd Config ==="
CURRENT_PHASE="phase 6 (containerd config)"

# containerd 2.2.1 speaks config v3; 2.3.4 raises the current version to v4.
# Unlike the 2.2.1 -> 2.2.6 move this replaces, that IS a config-format
# boundary -- but it is a read-compatible one, and the correct response is
# still to leave the file alone. Verified against containerd.io 2.3.x on a node
# with a relocated root (tests/vm/config-version-check.sh):
#
#   - 2.3.4 loads a version = 3 config unchanged. It migrates it IN MEMORY at
#     load time and logs "Configuration migrated from version 3, use
#     `containerd config migrate` to avoid migration". Nothing is written back.
#   - The RPM ships /etc/containerd/config.toml as %config(noreplace), so an
#     operator's file survives the transaction byte for byte.
#   - A relocated top-level `root` survives the in-memory migration:
#     `containerd config dump` still reports the relocated path.
#
# So this phase still VERIFIES rather than rewrites -- and that now matters
# MORE, not less. `containerd config default` under 2.3.4 emits version = 4,
# and containerd 2.2.1 refuses to load a v4 file at all:
#
#   containerd: failed to load TOML from /etc/containerd/config.toml:
#   expected containerd config version equal to or less than `3`, got `4`
#
# Writing a v4 config here would arm a trap that springs only during an
# emergency rollback, on a node that is already in trouble. Leave v3 alone.
#
# Config validity is proven downstream rather than here: phase 8 polls
# `ctr version` and the overlayfs snapshotter, and neither responds if the
# config is malformed.

if [ ! -f "$CONTAINERD_CONF" ]; then
    # containerd.io ships this file, so reaching here means it was deliberately
    # removed. Generating a default is the only option, but under 2.3.4 that
    # default is v4 -- which the rollback containerd cannot read. Say so plainly
    # rather than letting the operator discover it mid-emergency.
    echo -e "${YELLOW}No $CONTAINERD_CONF found - generating a default.${NC}"
    mkdir -p /etc/containerd
    containerd config default > "$CONTAINERD_CONF"
    echo "Default configuration written."
    GENERATED_VERSION=$(read_config_version "$CONTAINERD_CONF")
    if [ -n "$GENERATED_VERSION" ] && \
       [ "$GENERATED_VERSION" -gt "$ROLLBACK_SAFE_CONFIG_VERSION" ]; then
        echo ""
        echo -e "${YELLOW}WARNING: the generated config is version $GENERATED_VERSION.${NC}"
        echo "containerd 2.2.1 cannot load it. If this node is ever"
        echo "rolled back, containerd will refuse to start until the config is"
        echo "replaced with a version <= $ROLLBACK_SAFE_CONFIG_VERSION file."
        echo "rollback-docker.sh checks for this and will tell you before it acts."
    fi
else
    echo "Existing configuration preserved (backed up in $BACKUP_DIR)."
fi

# Report the config version, and flag the rollback implication if it is one the
# rollback containerd cannot read.
CONFIG_VERSION=$(read_config_version "$CONTAINERD_CONF")
if [ -z "$CONFIG_VERSION" ]; then
    echo "containerd config version: unset (treated as legacy; rollback-safe)"
elif [ "${#CONFIG_VERSION}" -gt 4 ]; then
    # Not a real config version -- a corrupt file. Comparing it would print a
    # raw "integer expression expected" from bash, since `[` is 64-bit only.
    # Report it instead; phase 8 is what actually proves the config loads.
    echo ""
    echo -e "${YELLOW}NOTE: containerd config version reads as '$CONFIG_VERSION'.${NC}"
    echo "That is not a valid config version -- $CONTAINERD_CONF may be corrupt."
    echo "Services start next; if containerd fails to come up, this is why."
elif [ "$CONFIG_VERSION" -le "$ROLLBACK_SAFE_CONFIG_VERSION" ]; then
    # Deliberately bounded from ABOVE only. A lower bound ("is this too old for
    # 2.3.4?") is not asserted: every node in this fleet came from containerd
    # 2.2.1, which writes v3, so a v2 config would have to be hand-made. Adding
    # an untested lower bound risks refusing a node that is actually fine, and
    # phase 8's readiness gate already catches a config containerd cannot load.
    echo "containerd config version: $CONFIG_VERSION (rollback-safe)"
else
    echo ""
    echo -e "${YELLOW}NOTE: containerd config version is $CONFIG_VERSION.${NC}"
    echo "containerd 2.2.1 -- the rollback target -- loads at most version"
    echo "$ROLLBACK_SAFE_CONFIG_VERSION. A rollback would leave containerd unable to start until"
    echo "this file is reverted."
    # Only name the backup if one actually exists. Phase 3 copies the config
    # with `|| true`, so when there was no config to back up there is no file
    # here either -- and sending an operator to a path that does not exist,
    # mid-rollback, is worse than saying nothing.
    if [ -f "$BACKUP_DIR/config.toml" ]; then
        echo "The pre-upgrade copy is in:"
        echo "  $BACKUP_DIR/config.toml"
    else
        echo -e "${YELLOW}No pre-upgrade copy exists in $BACKUP_DIR -- there was no${NC}"
        echo -e "${YELLOW}config to back up. Keep a copy of this file somewhere off${NC}"
        echo -e "${YELLOW}the node if you may need to roll back.${NC}"
    fi
fi

# rpm keeps %config(noreplace) files in place and drops the package's version
# alongside as .rpmnew. Surface it -- an operator with no internet needs to be
# told the new default exists rather than discovering it months later.
if [ -f "${CONTAINERD_CONF}.rpmnew" ]; then
    echo ""
    echo -e "${YELLOW}NOTE: ${CONTAINERD_CONF}.rpmnew exists.${NC}"
    echo "The package shipped a new default config; yours was kept. Compare later with:"
    echo "  diff -u $CONTAINERD_CONF ${CONTAINERD_CONF}.rpmnew"
fi

# Read the configured root, for reporting, for the missing-mount check below,
# and to ensure the directory exists. The extraction and the missing-relocated
# predicate both live in helpers now, so --preflight predicts EXACTLY what this
# phase enforces. Preflight predicts; this phase still enforces.
CONTAINERD_ROOT=$(read_containerd_root "$CONTAINERD_CONF")

echo "containerd root directory: $CONTAINERD_ROOT"

if [ ! -d "$CONTAINERD_ROOT" ]; then
    if ! relocated_root_is_missing "$CONTAINERD_ROOT"; then
        # The default root simply not existing yet is unremarkable.
        echo -e "${YELLOW}NOTE: $CONTAINERD_ROOT does not exist - creating it.${NC}"
        mkdir -p "$CONTAINERD_ROOT"
    else
        # A RELOCATED root that has gone missing is a different matter. The
        # overwhelmingly likely cause is that its filesystem is not mounted.
        # Blindly mkdir'ing it would create an empty directory on the root
        # filesystem, containerd would start against it, and every existing
        # image and snapshot would appear to have vanished -- while the script
        # reported success.
        echo ""
        echo -e "${RED}=========================================="
        echo "ERROR: RELOCATED containerd ROOT IS MISSING"
        echo -e "==========================================${NC}"
        echo ""
        echo "  /etc/containerd/config.toml points at: $CONTAINERD_ROOT"
        echo "  ...but that directory does not exist."
        echo ""
        echo "This usually means its filesystem is not mounted. Creating the"
        echo "directory would hide that: containerd would start against an empty"
        echo "root and this node's images and snapshots would look lost."
        echo ""
        echo "Check the mount first:"
        echo "  findmnt --target $(dirname "$CONTAINERD_ROOT")"
        echo "  lsblk; cat /etc/fstab"
        echo ""
        echo "Once the filesystem is mounted, re-run this script."
        echo ""
        REFUSAL_REASON="relocated-root-missing"
        REFUSAL_DETAIL="$CONTAINERD_ROOT does not exist; its filesystem is probably not mounted"
        echo -e "${YELLOW}NOTE: this is phase 6 -- packages have ALREADY been${NC}"
        echo -e "${YELLOW}installed and services are stopped. See the state report${NC}"
        echo -e "${YELLOW}below for exactly where this node stands.${NC}"
        exit 1
    fi
elif [ "$CONTAINERD_ROOT" != "/var/lib/containerd" ]; then
    # Relocated and present -- report the mount so an operator can eyeball that
    # it is the real filesystem and not an empty stand-in on /.
    echo "Relocated containerd root is present."
    findmnt --target "$CONTAINERD_ROOT" 2>/dev/null | sed 's/^/  /' || true
fi

#############################################
# Phase 7: Handle NVIDIA Toolkit (if present)
#############################################
if [ "$NVIDIA_INSTALLED" != true ]; then
    # No toolkit on this node, so phase 7 does not run at all. Distinct from
    # "phase 7 never reached", which the initial not-attempted still means.
    NVIDIA_RESULT="toolkit-absent"
fi
if [ "$NVIDIA_INSTALLED" = true ]; then
    echo ""
    echo "=== Phase 7: Upgrade NVIDIA Container Toolkit ==="
CURRENT_PHASE="phase 7 (nvidia toolkit)"

    NVIDIA_DIR="/opt/docker-offline/nvidia"

    shopt -s nullglob
    NVIDIA_FILES=("$NVIDIA_DIR"/*.rpm)
    shopt -u nullglob

    if [ "${#NVIDIA_FILES[@]}" -gt 0 ]; then
        # These were not covered by phase 0 (that validates the engine payload
        # only). Check digests here so a truncated NVIDIA RPM is named rather
        # than surfacing as an opaque rpm failure. NVIDIA is best-effort, so a
        # corrupt package skips the toolkit upgrade instead of aborting the run.
        NVIDIA_CORRUPT=0
        for nv in "${NVIDIA_FILES[@]}"; do
            if ! rpm -K --nosignature "$nv" >/dev/null 2>&1; then
                echo -e "${YELLOW}  WARNING: ${nv##*/} failed digest verification${NC}"
                NVIDIA_CORRUPT=$((NVIDIA_CORRUPT + 1))
            fi
        done
        if [ "$NVIDIA_CORRUPT" -gt 0 ]; then
            NVIDIA_RESULT="skipped-corrupt"
            echo -e "${YELLOW}Skipping NVIDIA upgrade: $NVIDIA_CORRUPT corrupt package(s).${NC}"
            echo "GPU workloads will keep using the currently installed toolkit."
            NVIDIA_FILES=()
        fi
    fi

    if [ "${#NVIDIA_FILES[@]}" -gt 0 ]; then
        # Remove conflicting packages that block NVIDIA upgrade
        # (devel and debuginfo packages may depend on old versions)
        echo "Removing conflicting NVIDIA packages..."
        rpm -e --nodeps libnvidia-container-devel 2>/dev/null || true
        rpm -e --nodeps libnvidia-container1-debuginfo 2>/dev/null || true

        # Install NVIDIA packages
        echo "Installing ${#NVIDIA_FILES[@]} NVIDIA package(s)..."
        if rpm -Uvh --force "${NVIDIA_FILES[@]}"; then
            NVIDIA_RESULT="installed"
            echo -e "${GREEN}NVIDIA packages installed.${NC}"
        else
            NVIDIA_RESULT="install-failed"
            echo -e "${YELLOW}WARNING: Some NVIDIA packages failed to install.${NC}"
            echo "You may need to manually resolve dependencies."
        fi

        # Reconfigure NVIDIA runtime for Docker
        # Note: nvidia-ctk doesn't understand containerd config v3, let alone the
        # v4 that containerd 2.3.4 introduces, so the containerd runtime is skipped.
        echo "Configuring NVIDIA runtime for Docker..."
        if nvidia-ctk runtime configure --runtime=docker 2>/dev/null; then
            echo -e "${GREEN}NVIDIA Docker runtime configured.${NC}"
        else
            echo -e "${YELLOW}WARNING: nvidia-ctk docker config failed. Manual config may be needed.${NC}"
        fi

        # Skip the containerd runtime deliberately. Beyond nvidia-ctk not
        # understanding config v3/v4, having it rewrite /etc/containerd/config.toml
        # is exactly what phase 6 exists to prevent: it would discard a relocated
        # root and could emit a version the rollback containerd cannot load.
        echo "Skipping containerd NVIDIA config (nvidia-ctk does not understand config v3/v4)"

        echo "NVIDIA toolkit upgrade complete."
    else
        # NVIDIA_FILES is also emptied above when every package failed its
        # digest check, so this branch is reached for both "none shipped" and
        # "all corrupt". The message is unchanged for both -- only the recorded
        # token distinguishes them.
        if [ "$NVIDIA_RESULT" != "skipped-corrupt" ]; then
            NVIDIA_RESULT="payload-missing"
        fi
        echo -e "${YELLOW}WARNING: NVIDIA packages not found in $NVIDIA_DIR${NC}"
        echo "GPU functionality may not work. Continuing anyway..."
    fi
fi

#############################################
# Phase 8: Start Services (CORRECT ORDER)
#############################################
echo ""
echo "=== Phase 8: Start Services ==="
CURRENT_PHASE="phase 8 (start services)"

# Start containerd FIRST
echo "Starting containerd..."
systemctl start containerd
systemctl enable containerd

# Wait for containerd to be fully ready (not just systemd "active")
# This avoids race conditions where docker starts before containerd's snapshotter is ready
echo "Waiting for containerd to be fully ready..."
CONTAINERD_READY=false
for i in {1..30}; do
    if ctr version &>/dev/null; then
        CONTAINERD_READY=true
        echo "containerd API is responsive (attempt $i)"
        break
    fi
    echo "  Waiting for containerd API... (attempt $i/30)"
    sleep 2
done

# A restart is an escalation, not a resolution. Re-check after it: previously
# this printed "containerd is fully ready" unconditionally and started docker
# even when the API had never responded across all 30 attempts AND the restart
# had not helped, which is exactly the race the polling exists to prevent.
if [ "$CONTAINERD_READY" = false ]; then
    echo -e "${YELLOW}WARNING: containerd API not responding, forcing restart...${NC}"
    systemctl restart containerd
    sleep 5
    if ! ctr version &>/dev/null; then
        echo -e "${RED}ERROR: containerd API never became responsive.${NC}"
        echo "Not starting docker against an unusable containerd."
        echo "Check logs with: journalctl -u containerd --no-pager -n 100"
        exit 1
    fi
    echo "containerd API responsive after restart."
fi

# Verify containerd is healthy
if ! systemctl is-active containerd &>/dev/null; then
    echo -e "${RED}ERROR: containerd failed to start!${NC}"
    echo "Check logs with: journalctl -u containerd --no-pager -n 50"
    exit 1
fi

# Verify snapshotter is working (this catches root path issues)
echo "Verifying containerd snapshotter..."
if ! ctr snapshots --snapshotter overlayfs ls &>/dev/null; then
    echo -e "${YELLOW}WARNING: Snapshotter not ready, restarting containerd...${NC}"
    systemctl restart containerd
    sleep 5
    if ! ctr snapshots --snapshotter overlayfs ls &>/dev/null; then
        echo -e "${RED}ERROR: the overlayfs snapshotter is not usable.${NC}"
        echo "Containers will not start. Not proceeding to docker."
        echo ""
        echo "This most often means containerd's root is wrong or unwritable."
        echo "  configured root: $CONTAINERD_ROOT"
        echo "  check:           journalctl -u containerd --no-pager -n 100"
        exit 1
    fi
    echo "Snapshotter usable after restart."
fi

echo -e "${GREEN}containerd is fully ready.${NC}"

# Then start docker
echo "Starting docker..."
systemctl start docker
systemctl enable docker

# Verify docker is healthy
if ! systemctl is-active docker &>/dev/null; then
    echo -e "${RED}ERROR: docker failed to start!${NC}"
    echo "Check logs with: journalctl -u docker --no-pager -n 50"
    exit 1
fi

# Both services verified up; a later failure no longer means "node is down".
SERVICES_STOPPED=false

echo -e "${GREEN}Services started successfully.${NC}"

#############################################
# Phase 9: Verification
#############################################
echo ""
echo "=== Phase 9: Verification ==="
CURRENT_PHASE="phase 9 (verification)"

echo "Docker version:"
docker version

echo ""
echo "containerd version:"
containerd --version

echo ""
echo "Installed packages:"
rpm -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Assert the upgrade actually landed. Without this, a node can reach
# "UPGRADE COMPLETE" while still running the old engine -- rpm can decline a
# transaction, or a scriptlet can fail, without the run aborting.
echo ""
echo "Asserting installed versions..."
VERIFY_FAILED=0

assert_installed() {
    local pkg="$1" want="$2" got
    got=$(rpm -q "$pkg" --queryformat '%{VERSION}' 2>/dev/null || echo "absent")
    if [ "$got" != "$want" ]; then
        echo -e "${RED}  ✗ $pkg is $got, expected $want${NC}"
        VERIFY_FAILED=1
    else
        echo -e "  ${GREEN}✓ $pkg $got${NC}"
    fi
}

assert_installed docker-ce             "$EXPECTED_DOCKER_VERSION"
assert_installed docker-ce-cli         "$EXPECTED_DOCKER_VERSION"
assert_installed containerd.io         "$EXPECTED_CONTAINERD_VERSION"
assert_installed docker-buildx-plugin  "$EXPECTED_BUILDX_VERSION"
assert_installed docker-compose-plugin "$EXPECTED_COMPOSE_VERSION"

# The installed containerd.io RELEASE, for the same reason phase 0 checks the
# payload's: 2.3.4-1 and 2.3.4-2 report an identical %{VERSION}. Phase 0 proves
# the BUNDLE was right; this proves what rpm actually left on the node, which
# is not the same claim -- a node that already had -1 installed and whose
# transaction partially failed would satisfy the version check above.
INSTALLED_CT_REL=$(rpm -q containerd.io --queryformat '%{RELEASE}' 2>/dev/null || echo "")
if containerd_release_matches "$INSTALLED_CT_REL" "$EXPECTED_CONTAINERD_RELEASE" "$RHEL_VER"; then
    echo -e "  ${GREEN}✓ containerd.io release $INSTALLED_CT_REL${NC}"
else
    echo -e "${RED}  ✗ containerd.io release is ${INSTALLED_CT_REL:-unreadable}, expected ${EXPECTED_CONTAINERD_RELEASE}.el${RHEL_VER}${NC}"
    VERIFY_FAILED=1
fi

if [ "$VERIFY_FAILED" -ne 0 ]; then
    echo ""
    REFUSAL_REASON="verification-failed"
    REFUSAL_DETAIL="installed versions do not match the upgrade target"
    echo -e "${RED}ERROR: installed versions do not match the upgrade target.${NC}"
    echo "Services are running, but this node was NOT upgraded as intended."
    echo "Inspect: rpm -qa | grep -E '(docker|containerd)'"
    exit 1
fi

echo ""
echo "Service status:"
systemctl is-active docker && echo -e "  docker: ${GREEN}running${NC}"
systemctl is-active containerd && echo -e "  containerd: ${GREEN}running${NC}"

echo ""
echo "Docker images (use 'docker images --all' in Docker 29.x):"
docker images --all | head -20

echo ""
echo "Existing containers:"
docker ps -a | head -20

if [ "$NVIDIA_INSTALLED" = true ]; then
    echo ""
    echo "NVIDIA GPU test:"
    if docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi 2>/dev/null; then
        echo -e "${GREEN}SUCCESS: GPU access works!${NC}"
    else
        echo "NOTE: GPU test requires nvidia/cuda image to be available"
    fi
fi

#############################################
# Phase 10: Swarm Reactivation
#############################################
if [ "$SWARM_ACTIVE" = true ]; then
    echo ""
    echo "=== Phase 10: Docker Swarm Reactivation ==="
CURRENT_PHASE="phase 10 (swarm reactivation)"

    if [ "$IS_MANAGER" = true ]; then
        # Manager can reactivate itself
        CURRENT_AVAILABILITY=$(docker node inspect "$SWARM_NODE_ID" --format '{{.Spec.Availability}}' 2>/dev/null || echo "unknown")
        case "$CURRENT_AVAILABILITY" in
            active|drain|pause) ;;
            *) CURRENT_AVAILABILITY="unknown" ;;
        esac
        # Recorded as soon as it is known, then overwritten if the node is
        # actually reactivated below. Assigning it only after the prompt means
        # an EOF there reports "unknown" for a value just observed.
        NODE_AVAILABILITY_AFTER="$CURRENT_AVAILABILITY"
        echo "Current node availability: $CURRENT_AVAILABILITY"

        if [ "$CURRENT_AVAILABILITY" = "drain" ]; then
            echo ""
            if gate reactivate "Set this node back to ACTIVE? [Y/n]" "y"; then
                echo "Activating node..."
                docker node update --availability active "$SWARM_NODE_ID"
                NODE_AVAILABILITY_AFTER="active"

                echo ""
                echo "Node status:"
                docker node ls

                echo ""
                echo "Services on this node:"
                docker node ps "$SWARM_NODE_ID" | head -20
            else
                NODE_AVAILABILITY_AFTER="drain"
                echo ""
                echo "Node remains drained. To activate later, run:"
                echo "  docker node update --availability active $SWARM_NODE_ID"
            fi
        else
            echo "Node availability: $CURRENT_AVAILABILITY"
        fi

        # Both reactivated and no-drain managers reach this check. Leave an
        # intentional drain/pause alone; unknown availability proves nothing.
        case "$NODE_AVAILABILITY_AFTER" in
            active) wait_for_services ;;
            drain|pause) echo "Workload recovery not checked while node remains $NODE_AVAILABILITY_AFTER." ;;
            *)
                WORKLOAD_STATE="unknown"
                echo -e "${YELLOW}WARNING: Node availability is unknown; inspect from a manager.${NC}"
                ;;
        esac
    else
        # Worker cannot reactivate itself
        echo ""
        echo "This is a WORKER node. To reactivate, run from a MANAGER:"
        echo ""
        echo -e "  ${YELLOW}docker node update --availability active $SWARM_NODE_ID${NC}"
        echo ""
        echo "Or by hostname:"
        echo ""
        echo -e "  ${YELLOW}docker node update --availability active $(hostname)${NC}"
    fi
fi

#############################################
# Complete
#############################################
echo ""
echo -e "${GREEN}==========================================${NC}"
OPERATION_COMPLETED=true
echo -e "${GREEN}UPGRADE COMPLETE${NC}"
echo "Package versions verified. Workload recovery: $WORKLOAD_STATE"
echo -e "${GREEN}==========================================${NC}"
echo ""
echo "Versions installed:"
echo "  - docker-ce: $(rpm -q docker-ce --queryformat '%{VERSION}')"
echo "  - containerd.io: $(rpm -q containerd.io --queryformat '%{VERSION}')"
echo ""
echo "containerd root: $CONTAINERD_ROOT"
echo ""
if [ "$SWARM_ACTIVE" = true ]; then
    echo "Swarm node ID: $SWARM_NODE_ID"
    echo "Swarm status: $(docker node inspect "$SWARM_NODE_ID" --format '{{.Spec.Availability}}' 2>/dev/null)"
fi
echo ""
echo "Log file: /var/log/docker-upgrade.log"
echo "Backup: $BACKUP_DIR"
echo "=========================================="

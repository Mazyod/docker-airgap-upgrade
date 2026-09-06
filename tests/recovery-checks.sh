#!/bin/bash
# Execute the real recovery and packaging sections with isolated command fixtures.
# No upgrade transaction, host service change, download or real sleep occurs.
VERSION="1.0.0"
set -euo pipefail
REPO_DIR="${RECOVERY_TEST_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
echo "Recovery checks $VERSION"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
PASS=0

extract_function() {
    sed -n "/^$1() {/,/^}/p" "$REPO_DIR/upgrade-docker.sh"
}
WAIT_FUNCTION=$(extract_function wait_for_services)
PHASE10=$(sed -n '/^# Phase 10: Swarm Reactivation/,/^# Complete/p' "$REPO_DIR/upgrade-docker.sh")
[ -n "$WAIT_FUNCTION" ] && [ -n "$PHASE10" ]

run_case() (
    local availability="$1" response="$2" reactivate="$3" manager="$4"
    local WORKLOAD_STATE=not-checked NODE_AVAILABILITY_AFTER=unknown
    # shellcheck disable=SC2034 # consumed by the extracted source below
    local SWARM_ACTIVE=true IS_MANAGER="$manager" SWARM_NODE_ID=test-node
    # shellcheck disable=SC2034 # consumed by the extracted source below
    local CURRENT_PHASE=initial YELLOW='' NC='' SECONDS=0
    # shellcheck disable=SC2034 # phase 10 records the current phase for the trap
    CURRENT_PHASE=initial
    : > "$TEST_DIR/calls"
    echo 0 > "$TEST_DIR/polls"
    # shellcheck disable=SC2329 # invoked by the extracted source below
    docker() {
        printf '%s\n' "$*" >> "$TEST_DIR/calls"
        case "$1 $2" in
            'node inspect') printf '%s\n' "$availability" ;;
            'node update') availability=active ;;
            'node ls'|'node ps') : ;;
            'service ls')
                local polls
                polls=$(cat "$TEST_DIR/polls")
                echo $((polls + 1)) > "$TEST_DIR/polls"
                case "$response" in
                    delayed) if [ "$polls" -lt 2 ]; then echo 0/1; else echo 1/1; fi ;;
                    failed) return 1 ;;
                    malformed) echo nonsense ;;
                    empty) : ;;
                    *) printf '%s\n' "$response" ;;
                esac
                ;;
            *) echo "Unexpected docker call: $*" >&2; exit 90 ;;
        esac
    }
    # shellcheck disable=SC2329 # invoked by the extracted source below
    gate() { [ "$reactivate" = yes ]; }
    # shellcheck disable=SC2329 # invoked by the extracted source below
    timeout() {
        [ "$1" -gt 0 ] && [ "$1" -le 5 ] || exit 91
        shift
        "$@"
    }
    # shellcheck disable=SC2329 # invoked by the extracted source below
    sleep() { SECONDS=$((SECONDS + $1)); }
    # These are extracted source sections, not copies of their implementation.
    eval "$WAIT_FUNCTION"
    eval "$PHASE10"
    printf 'OBSERVED=%s/%s\n' "$WORKLOAD_STATE" "$NODE_AVAILABILITY_AFTER"
)

check_case() {
    local label="$1" expected="$2" expected_polls="$3" output polls
    shift 3
    if ! output=$(run_case "$@"); then
        echo "FAIL: $label exited nonzero: $output" >&2; exit 1
    fi
    polls=$(cat "$TEST_DIR/polls")
    if ! [[ "$output" == *"OBSERVED=$expected"* ]] || [ "$polls" -ne "$expected_polls" ]; then
        echo "FAIL: $label expected $expected/$expected_polls polls, got $output/$polls" >&2; exit 1
    fi
    if [[ "$output" == *'Node is already active.'* ]]; then
        echo "FAIL: unconditional active claim" >&2; exit 1
    fi
    if [ "$1" != drain ] || [ "$3" != yes ]; then
        if grep -q 'node update' "$TEST_DIR/calls"; then
            echo "FAIL: $label changed availability" >&2; exit 1
        fi
    fi
    PASS=$((PASS + 1))
    echo "PASS: $label"
}

check_case 'active/no-drain delayed recovery' converged/active 3 active delayed no true
check_case 'reactivated delayed recovery' converged/active 3 drain delayed yes true
check_case 'replica timeout remains nonfatal' timeout/active 12 active 0/1 no true
check_case 'failed queries remain unknown' unknown/active 12 active failed no true
check_case 'malformed replicas remain unknown' unknown/active 12 active malformed no true
check_case 'empty Swarm converges' converged/active 1 active empty no true
check_case 'scaled-to-zero service converges' converged/active 1 active 0/0 no true
check_case 'pause preserved' not-checked/pause 0 pause 1/1 no true
check_case 'drain preserved' not-checked/drain 0 drain 1/1 no true
check_case 'empty availability is unknown' unknown/unknown 0 '' 1/1 no true
check_case 'invalid availability is unknown' unknown/unknown 0 invalid 1/1 no true
check_case 'worker needs manager verification' not-checked/unknown 0 active 1/1 no false

# Run the actual documentation copy block with real cp and isolated directories.
# The tar sentinel proves a missing doc exits before artifact creation.
DOC_BLOCK=$(sed -n '/^# Operator documentation travels/,/^# Create final bundle/p' "$REPO_DIR/download-docker-packages.sh")
[ -n "$DOC_BLOCK" ]
for missing in none README.md RUNBOOK.md docs/AGENT-RUNBOOK.md; do
    mkdir -p "$TEST_DIR/source/docs" "$TEST_DIR/bundle"
    for doc in README.md RUNBOOK.md docs/AGENT-RUNBOOK.md; do
        printf 'fixture %s\n' "$doc" > "$TEST_DIR/source/$doc"
    done
    if [ "$missing" != none ]; then rm "$TEST_DIR/source/$missing"; fi
    rm -f "$TEST_DIR/artifact"
    if (
        # shellcheck disable=SC2034 # consumed by the extracted source below
        SCRIPT_DIR="$TEST_DIR/source"
        # shellcheck disable=SC2034 # consumed by the extracted source below
        DEST_BASE="$TEST_DIR/bundle"
        eval "$DOC_BLOCK"
        touch "$TEST_DIR/artifact"
    ) > "$TEST_DIR/docs.log" 2>&1; then rc=0; else rc=$?; fi
    if [ "$missing" = none ]; then
        [ "$rc" -eq 0 ] && [ -f "$TEST_DIR/artifact" ]
        for doc in README.md RUNBOOK.md docs/AGENT-RUNBOOK.md; do
            cmp "$TEST_DIR/source/$doc" "$TEST_DIR/bundle/${doc##*/}"
        done
    elif [ "$rc" -eq 0 ] || [ -f "$TEST_DIR/artifact" ]; then
        echo "FAIL: missing $missing did not prevent packaging" >&2; exit 1
    fi
    PASS=$((PASS + 1))
    echo "PASS: bundle documentation ($missing missing)"
done

# Execute the harness staging section with a local equivalent of verified copy.
STAGE_BLOCK=$(sed -n '/^echo "=== Bundle builder/,/^echo "=== Running download/p' "$REPO_DIR/tests/vm/build-bundle.sh")
(
    # shellcheck disable=SC2329 # invoked by the extracted source below
    vm() { :; }
    # shellcheck disable=SC2329 # invoked by the extracted source below
    vm_cp_verified() {
        local destination="$TEST_DIR/staged${1#/root/scripts}"
        shift
        mkdir -p "$destination"
        cp "$@" "$destination/"
    }
    eval "$STAGE_BLOCK"
) > "$TEST_DIR/stage.log"
for doc in README.md RUNBOOK.md docs/AGENT-RUNBOOK.md; do
    cmp "$REPO_DIR/$doc" "$TEST_DIR/staged/$doc"
done
PASS=$((PASS + 1))
echo "PASS: harness stages matching operator documents"
# Startup must reject incomplete checkouts before downloads and remove stale output.
START_BLOCK=$(sed -n '/^DEST_BASE=/,/^# NOTE ON THE RELEASE SUFFIX/p' "$REPO_DIR/download-docker-packages.sh")
START_BLOCK=${START_BLOCK//\/opt/$TEST_DIR/opt}
for missing in none README.md RUNBOOK.md docs/AGENT-RUNBOOK.md upgrade-docker.sh; do
    mkdir -p "$TEST_DIR/start/docs" "$TEST_DIR/opt"
    for required in upgrade-docker.sh rollback-docker.sh recover-dnf.sh clean-swarm-networks.sh \
        README.md RUNBOOK.md docs/AGENT-RUNBOOK.md; do
        echo fixture > "$TEST_DIR/start/$required"
    done
    if [ "$missing" != none ]; then rm "$TEST_DIR/start/$missing"; fi
    touch "$TEST_DIR/opt/docker-upgrade-bundle.tar.gz"
    if (
        # shellcheck disable=SC2034 # consumed by the extracted startup
        SCRIPT_DIR="$TEST_DIR/start"
        eval "$START_BLOCK"
    ) > "$TEST_DIR/start.log" 2>&1; then rc=0; else rc=$?; fi
    if [ -f "$TEST_DIR/opt/docker-upgrade-bundle.tar.gz" ]; then
        echo "FAIL: stale bundle survives startup" >&2; exit 1
    fi
    if { [ "$missing" = none ] && [ "$rc" -ne 0 ]; } ||
       { [ "$missing" != none ] && [ "$rc" -eq 0 ]; }; then
        echo "FAIL: startup required-file check ($missing)" >&2; exit 1
    fi
    PASS=$((PASS + 1))
    echo "PASS: startup required-file check ($missing missing)"
done

echo "Recovery checks: $PASS passed"

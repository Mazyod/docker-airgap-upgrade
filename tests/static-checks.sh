#!/bin/bash
# tests/static-checks.sh
# Tier 1 of docs/TEST-PLAN.md -- everything checkable without a RHEL box.
#
# Runs on the macOS dev machine. Proves syntax, lint, internal consistency, and
# (with --online) that every pinned package exists upstream.
#
# This does NOT execute any upgrade logic. Passing this does not authorize a
# production rollout; Tier 2 in a RHEL VM is the minimum bar for that.
#
# Usage:
#   ./tests/static-checks.sh            # offline checks only
#   ./tests/static-checks.sh --online   # also verify all 16 RPM URLs resolve

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR" || exit 1

ONLINE=false
[ "${1:-}" = "--online" ] && ONLINE=true

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'

PASS=0
FAIL=0
SKIP=0

ok()   { printf '  %sPASS%s %s\n' "$GREEN" "$NC" "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  %sFAIL%s %s\n' "$RED" "$NC" "$1"; FAIL=$((FAIL + 1)); }
skip() { printf '  %sSKIP%s %s\n' "$YELLOW" "$NC" "$1"; SKIP=$((SKIP + 1)); }
head_() { printf '\n== %s ==\n' "$1"; }

SCRIPTS=(
    upgrade-docker.sh
    rollback-docker.sh
    clean-swarm-networks.sh
    download-docker-packages.sh
    simulate-upgrade.sh
    recover-dnf.sh
)

# Target versions, kept here so a retarget that forgets a file gets caught.
WANT_DOCKER="29.6.2"
WANT_CONTAINERD="2.2.6"
WANT_BUILDX="0.35.0"
WANT_COMPOSE="5.3.1"
WANT_ROLLBACK_DOCKER="29.1.5"
WANT_ROLLBACK_CONTAINERD="2.2.1"

#############################################
head_ "1.1 / 1.2  Syntax and lint"
#############################################
for s in "${SCRIPTS[@]}"; do
    if [ ! -f "$s" ]; then bad "$s missing"; continue; fi
    if bash -n "$s" 2>/dev/null; then ok "bash -n $s"; else bad "bash -n $s"; fi
done

if command -v shellcheck >/dev/null 2>&1; then
    for s in "${SCRIPTS[@]}"; do
        [ -f "$s" ] || continue
        if shellcheck "$s" >/dev/null 2>&1; then
            ok "shellcheck $s"
        else
            bad "shellcheck $s"
            shellcheck "$s" 2>&1 | sed 's/^/       /'
        fi
    done
else
    skip "shellcheck not installed"
fi

#############################################
head_ "1.4  Version constants agree across files"
#############################################
check_contains() {
    local file="$1" pattern="$2" label="$3"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        ok "$label"
    else
        bad "$label (pattern '$pattern' not in $file)"
    fi
}

check_contains upgrade-docker.sh  "EXPECTED_DOCKER_VERSION=\"$WANT_DOCKER\""       "upgrade-docker.sh pins docker $WANT_DOCKER"
check_contains upgrade-docker.sh  "EXPECTED_CONTAINERD_VERSION=\"$WANT_CONTAINERD\"" "upgrade-docker.sh pins containerd $WANT_CONTAINERD"
check_contains rollback-docker.sh "ROLLBACK_DOCKER_VERSION=\"$WANT_ROLLBACK_DOCKER\"" "rollback-docker.sh pins docker $WANT_ROLLBACK_DOCKER"
check_contains rollback-docker.sh "ROLLBACK_CONTAINERD_VERSION=\"$WANT_ROLLBACK_CONTAINERD\"" "rollback-docker.sh pins containerd $WANT_ROLLBACK_CONTAINERD"

for v in "$WANT_DOCKER" "$WANT_CONTAINERD" "$WANT_BUILDX" "$WANT_COMPOSE"; do
    check_contains download-docker-packages.sh "$v" "download script references $v"
done
for v in "$WANT_ROLLBACK_DOCKER" "$WANT_ROLLBACK_CONTAINERD"; do
    check_contains download-docker-packages.sh "$v" "download script references rollback $v"
done
check_contains simulate-upgrade.sh "$WANT_DOCKER"     "simulate-upgrade.sh targets $WANT_DOCKER"
check_contains simulate-upgrade.sh "$WANT_CONTAINERD" "simulate-upgrade.sh targets $WANT_CONTAINERD"
check_contains README.md           "$WANT_DOCKER"     "README references $WANT_DOCKER"

# Both el8 and el9 must be covered for every upgrade package.
for pkg in "docker-ce-$WANT_DOCKER" "docker-ce-cli-$WANT_DOCKER" \
           "containerd.io-$WANT_CONTAINERD" "docker-buildx-plugin-$WANT_BUILDX" \
           "docker-compose-plugin-$WANT_COMPOSE"; do
    for el in el8 el9; do
        if grep -q "$pkg-1\.$el\.x86_64\.rpm" download-docker-packages.sh; then
            ok "download loop has $pkg ($el)"
        else
            bad "download loop MISSING $pkg ($el)"
        fi
    done
done

#############################################
head_ "1.5  No stale version literals"
#############################################
# Historical references are legitimate in comments and in "from" columns; only
# flag them in live code. Strip comment lines before searching.
#
# simulate-upgrade.sh is a special case: it deliberately INSTALLS the previous
# versions as its simulated starting state, so 29.1.5 / 2.2.1 / 0.30.1 / 5.0.1
# are correct there. Only the pre-previous round (28.5.1 / 1.7.29) would be
# wrong, since this script no longer covers the containerd major migration.
STALE_FOUND=0
for s in "${SCRIPTS[@]}"; do
    [ -f "$s" ] || continue
    if [ "$s" = "simulate-upgrade.sh" ]; then
        pattern='28\.5\.1|1\.7\.29'
        what="pre-baseline literal"
    else
        pattern='28\.5\.1|1\.7\.29|0\.30\.1|5\.0\.1'
        what="stale literal"
    fi
    # grep -n on a FILTERED stream reports the filtered line numbers, which do
    # not correspond to anything in the file. Number the file first, then
    # filter, so the reported numbers are real.
    hits=$(grep -nE "$pattern" "$s" | grep -vE '^[0-9]+:\s*#' || true)
    if [ -n "$hits" ]; then
        bad "$what in live code of $s"
        printf '       %s\n' "$hits"
        STALE_FOUND=1
    fi
done
[ "$STALE_FOUND" -eq 0 ] && ok "no stale version literals in live code"

# The simulation's baseline must match the cluster's actual current state,
# otherwise it is not simulating this upgrade.
for spec in "docker-buildx-plugin-0.30.1" "docker-compose-plugin-5.0.1" \
            "docker-ce-29.1.5" "containerd.io-2.2.1"; do
    if grep -q "$spec" simulate-upgrade.sh; then
        ok "simulation baseline pins $spec"
    else
        bad "simulation baseline does NOT pin $spec"
    fi
done

#############################################
head_ "1.6  Phase structure of upgrade-docker.sh"
#############################################
for p in 0 1 2 3 4 5 6 7 8 9 10; do
    if grep -qE "^# Phase $p:" upgrade-docker.sh; then
        ok "phase $p present"
    else
        bad "phase $p MISSING"
    fi
done

if grep -qE "^# Phase 4\.5:" upgrade-docker.sh; then
    bad "phase 4.5 still present (should be extracted)"
else
    ok "phase 4.5 absent (extracted to clean-swarm-networks.sh)"
fi

#############################################
head_ "1.7  Removed logic really is removed"
#############################################
if grep -vE '^\s*#' upgrade-docker.sh | grep -q "check_xfs_ftype"; then
    bad "check_xfs_ftype still live in upgrade-docker.sh"
else
    ok "check_xfs_ftype removed from live code"
fi

# `containerd config default` is allowed ONLY in the file-absent branch. There
# must be exactly one occurrence in live code, and phase 6 must not rewrite an
# existing config.
CFG_DEFAULT_COUNT=$(grep -vE '^\s*#' upgrade-docker.sh | grep -c "containerd config default" || true)
if [ "$CFG_DEFAULT_COUNT" -eq 1 ]; then
    ok "containerd config default appears once (file-absent branch only)"
else
    bad "containerd config default appears $CFG_DEFAULT_COUNT times in live code (want 1)"
fi

if grep -vE '^\s*#' simulate-upgrade.sh | grep -q "containerd config migrate"; then
    bad "containerd config migrate still live in simulate-upgrade.sh"
else
    ok "containerd config migrate removed from simulate-upgrade.sh"
fi

#############################################
head_ "1.8  Executable bits"
#############################################
for s in "${SCRIPTS[@]}"; do
    [ -f "$s" ] || continue
    if [ -x "$s" ]; then ok "$s executable"; else bad "$s NOT executable"; fi
done

#############################################
head_ "1.9  Bundle ships every operator script"
#############################################
BUNDLED=$(grep -oE 'for script in [^;]+' download-docker-packages.sh | sed 's/for script in //')
for s in upgrade-docker.sh rollback-docker.sh recover-dnf.sh clean-swarm-networks.sh; do
    case " $BUNDLED " in
        *" $s "*)
            if [ -f "$s" ]; then ok "bundle includes $s and it exists"
            else bad "bundle lists $s but the file is missing"; fi
            ;;
        *) bad "bundle does NOT include $s" ;;
    esac
done

#############################################
head_ "1.10  Failure-handling wiring"
#############################################
for s in upgrade-docker.sh rollback-docker.sh clean-swarm-networks.sh; do
    for t in "trap on_exit EXIT" "trap 'exit 130' INT" "trap 'exit 143' TERM"; do
        if grep -qF "$t" "$s"; then ok "$s has: $t"; else bad "$s MISSING: $t"; fi
    done
    if grep -q "verify_unit_stopped" "$s"; then
        ok "$s uses verify_unit_stopped (fail-closed)"
    else
        bad "$s does not use verify_unit_stopped"
    fi
    # `systemctl is-active` must not be used to decide a unit is STOPPED (it
    # fails open). It is still legitimate for confirming a unit is RUNNING.
    # Flag it only inside a stop-verification context: a `STILL_UP`/`still_up`
    # accumulator, which is the shape the old fail-open code had.
    if grep -nE 'systemctl is-active' "$s" | grep -vE '^[0-9]+:\s*#' \
        | grep -qiE 'still_up'; then
        bad "$s uses is-active to decide a unit is stopped (fails open)"
    else
        ok "$s does not use is-active as a stop check"
    fi
done

#############################################
head_ "1.11  Duplicated helpers have not drifted"
#############################################
# The three stateful scripts are standalone by design -- they get hand-carried
# to air-gapped hosts individually -- so shared helpers are duplicated rather
# than sourced. That makes silent divergence between the copies the standing
# risk, and it has already happened once (rollback's start_services lost the
# error handling its sibling had). Compare them ignoring blank lines.
extract_fn() {
    awk -v fn="$2" '$0 ~ "^"fn"\\(\\) \\{", /^\}/ { print }' "$1" | grep -v '^[[:space:]]*$'
}

cmp_fn() {
    local fn="$1"; shift
    local first="$1"; shift
    local ref out ok=1
    ref=$(extract_fn "$first" "$fn")
    if [ -z "$ref" ]; then bad "$fn not found in $first"; return; fi
    for other in "$@"; do
        out=$(extract_fn "$other" "$fn")
        if [ -z "$out" ]; then bad "$fn not found in $other"; ok=0; continue; fi
        if [ "$ref" != "$out" ]; then
            bad "$fn DRIFTED between $first and $other"
            diff <(printf '%s\n' "$ref") <(printf '%s\n' "$out") | sed 's/^/       /'
            ok=0
        fi
    done
    [ "$ok" -eq 1 ] && ok "$fn identical across $(( $# + 1 )) scripts"
}

cmp_fn verify_unit_stopped upgrade-docker.sh rollback-docker.sh clean-swarm-networks.sh
cmp_fn start_services      rollback-docker.sh clean-swarm-networks.sh
cmp_fn prompt_yes_no       upgrade-docker.sh clean-swarm-networks.sh

#############################################
head_ "1.12  Every helper called is also defined"
#############################################
# A call to an undefined function is a RUNTIME failure that `bash -n` cannot
# see and shellcheck does not flag. It already happened: rollback-docker.sh
# called prompt_yes_no without defining it, and because the call sat in an
# `if !` condition the missing command (127) inverted to "abort", exiting 0 --
# a silent no-op rollback that reported success.
#
# Grepping for a helper NAME is not enough either: the call site itself
# supplies the string, so a check like that passes even with the definition
# deleted. Require the definition.
for s in "${SCRIPTS[@]}"; do
    [ -f "$s" ] || continue
    for fn in prompt_yes_no verify_unit_stopped start_services stop_services; do
        # Does the script reference it anywhere other than its own definition?
        refs=$(grep -vE '^\s*#' "$s" | grep -cE "(^|[^[:alnum:]_])${fn}( |$|\")" || true)
        defs=$(grep -cE "^${fn}\(\) \{" "$s" || true)
        if [ "$refs" -gt 0 ] && [ "$defs" -eq 0 ]; then
            bad "$s calls $fn but never defines it"
        elif [ "$refs" -gt 0 ]; then
            ok "$s defines the $fn it calls"
        fi
    done
done

#############################################
head_ "1.13  Load-bearing invariants"
#############################################
# CLAUDE.md calls these non-negotiable, so assert them rather than trusting
# that nobody reorders them.

# Stop order: docker (with docker.socket) must precede containerd.
for s in upgrade-docker.sh rollback-docker.sh clean-swarm-networks.sh; do
    d=$(grep -n 'systemctl stop docker docker.socket' "$s" | head -1 | cut -d: -f1)
    c=$(grep -n 'systemctl stop containerd' "$s" | head -1 | cut -d: -f1)
    if [ -n "$d" ] && [ -n "$c" ] && [ "$d" -lt "$c" ]; then
        ok "$s stops docker before containerd"
    else
        bad "$s stop order WRONG (docker@${d:-?}, containerd@${c:-?})"
    fi
done

# Start order: containerd must precede docker, in every start path.
for s in upgrade-docker.sh rollback-docker.sh clean-swarm-networks.sh; do
    c=$(grep -n 'systemctl start containerd' "$s" | head -1 | cut -d: -f1)
    d=$(grep -n 'systemctl start docker' "$s" | head -1 | cut -d: -f1)
    if [ -n "$c" ] && [ -n "$d" ] && [ "$c" -lt "$d" ]; then
        ok "$s starts containerd before docker"
    else
        bad "$s start order WRONG (containerd@${c:-?}, docker@${d:-?})"
    fi
done

# Readiness gating: both the API poll and the snapshotter check must exist.
for s in upgrade-docker.sh rollback-docker.sh clean-swarm-networks.sh; do
    if grep -q 'ctr version' "$s" && grep -q 'ctr snapshots --snapshotter overlayfs ls' "$s"; then
        ok "$s gates on both ctr version and the overlayfs snapshotter"
    else
        bad "$s is missing a containerd readiness gate"
    fi
done

# Rollback resumability: --replacepkgs on both the dry run and the real call.
rp=$(grep -vE '^\s*#' rollback-docker.sh | grep -c -- '--replacepkgs' || true)
if [ "$rp" -eq 2 ]; then
    ok "rollback-docker.sh uses --replacepkgs on dry run and real transaction"
else
    bad "rollback-docker.sh has $rp --replacepkgs occurrences in live code (want 2)"
fi

# One rpm transaction, not several: exactly one real `rpm -Uvh` that is not a
# --test dry run, in each of upgrade (engine) and rollback.
for s in upgrade-docker.sh rollback-docker.sh; do
    real=$(grep -vE '^\s*#' "$s" | grep -E 'rpm -Uvh' | grep -vc -- '--test' || true)
    want=1
    [ "$s" = "upgrade-docker.sh" ] && want=2   # engine set + NVIDIA set
    if [ "$real" -eq "$want" ]; then
        ok "$s has $real real rpm -Uvh transaction(s)"
    else
        bad "$s has $real real rpm -Uvh transactions (want $want)"
    fi
done

# Swarm state must be compared exactly -- `grep -q "active"` matches "inactive".
for s in upgrade-docker.sh clean-swarm-networks.sh; do
    if grep -vE '^\s*#' "$s" | grep -q 'grep -q "active"'; then
        bad "$s uses grep -q \"active\" which also matches \"inactive\""
    else
        ok "$s compares Swarm state exactly"
    fi
done

#############################################
head_ "1.3  Upstream package availability"
#############################################
if [ "$ONLINE" = false ]; then
    skip "URL checks (pass --online to run)"
else
    BASE="https://download.docker.com/linux/rhel"
    for rel in 8 9; do
        for pkg in \
            "docker-ce-$WANT_DOCKER-1.el$rel.x86_64.rpm" \
            "docker-ce-cli-$WANT_DOCKER-1.el$rel.x86_64.rpm" \
            "containerd.io-$WANT_CONTAINERD-1.el$rel.x86_64.rpm" \
            "docker-buildx-plugin-$WANT_BUILDX-1.el$rel.x86_64.rpm" \
            "docker-compose-plugin-$WANT_COMPOSE-1.el$rel.x86_64.rpm" \
            "docker-ce-$WANT_ROLLBACK_DOCKER-1.el$rel.x86_64.rpm" \
            "docker-ce-cli-$WANT_ROLLBACK_DOCKER-1.el$rel.x86_64.rpm" \
            "containerd.io-$WANT_ROLLBACK_CONTAINERD-1.el$rel.x86_64.rpm"
        do
            code=$(curl -sIL -o /dev/null -w '%{http_code}' --max-time 25 \
                "$BASE/$rel/x86_64/stable/Packages/$pkg" || echo "000")
            if [ "$code" = "200" ]; then ok "el$rel $pkg"; else bad "el$rel $pkg (HTTP $code)"; fi
        done
    done
fi

#############################################
printf '\n==========================================\n'
printf 'passed %d, failed %d, skipped %d\n' "$PASS" "$FAIL" "$SKIP"
printf '==========================================\n'

if [ "$FAIL" -gt 0 ]; then
    printf '%sTIER 1 FAILED%s\n' "$RED" "$NC"
    exit 1
fi
printf '%sTIER 1 PASSED%s\n' "$GREEN" "$NC"
printf 'Reminder: this executes no upgrade logic. Tier 2 in a RHEL VM is\n'
printf 'still required before any production rollout.\n'
exit 0

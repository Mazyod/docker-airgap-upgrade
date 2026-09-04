#!/bin/bash
# tests/static-checks.sh
# Tier 1 of docs/TEST-PLAN.md -- everything checkable without a RHEL box.
#
# Runs anywhere bash and shellcheck do. Proves syntax, lint, internal consistency, and
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
WANT_DOCKER="29.8.0"
WANT_CONTAINERD="2.3.4"
WANT_BUILDX="0.37.0"
WANT_COMPOSE="5.5.1"
WANT_ROLLBACK_DOCKER="29.1.5"
WANT_ROLLBACK_CONTAINERD="2.2.1"

# The containerd.io RPM RELEASE suffix, which is load-bearing for the first
# time. containerd.io 2.3.4 ships as both -1 and -2: identical file lists,
# identical Requires, identical %{VERSION}, and a DIFFERENT /usr/bin/runc
# (1.4.3 in -1, 1.5.1 in -2). A version-only assertion cannot tell them apart,
# so upgrade-docker.sh asserts %{RELEASE} too and this value must agree with
# the constant there and with the download loops. Every other package is -1.
WANT_CONTAINERD_RELEASE="2"

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

# The package set, as name:version:release, in ONE place.
#
# Both el8 and el9 must be covered for every upgrade package, and the same five
# have to resolve upstream in check 1.3. Those were two hand-maintained lists
# that had to be kept in agreement by eye; 1.3's hard-coded "-1" per package was
# exactly the mistake the release suffix below exists to prevent.
#
# The RELEASE suffix is carried per package rather than hard-coded to 1. It used
# to be 1 for everything, which made "-1" invisible boilerplate; containerd.io
# 2.3.4 ships as -1 and -2 and only -2 is wanted, so a mechanical version bump
# that left the suffix alone would name an RPM that is real but WRONG.
WANT_PKGS=(
    "docker-ce:$WANT_DOCKER:1"
    "docker-ce-cli:$WANT_DOCKER:1"
    "containerd.io:$WANT_CONTAINERD:$WANT_CONTAINERD_RELEASE"
    "docker-buildx-plugin:$WANT_BUILDX:1"
    "docker-compose-plugin:$WANT_COMPOSE:1"
)
# The rollback set, checked upstream by 1.3 only -- the download loops for it are
# covered by the plain version greps above. Published once, so every release is 1.
WANT_ROLLBACK_PKGS=(
    "docker-ce:$WANT_ROLLBACK_DOCKER:1"
    "docker-ce-cli:$WANT_ROLLBACK_DOCKER:1"
    "containerd.io:$WANT_ROLLBACK_CONTAINERD:1"
)
# name:version:release -> the exact RPM filename for one RHEL major.
pkg_rpm_name() {
    local spec="$1" major="$2" rest
    rest="${spec#*:}"
    printf '%s-%s-%s.el%s.x86_64.rpm' \
        "${spec%%:*}" "${rest%%:*}" "${rest##*:}" "$major"
}

for spec in "${WANT_PKGS[@]}"; do
    for major in 8 9; do
        rpm_name=$(pkg_rpm_name "$spec" "$major")
        # Escape the dots: an unescaped version string is a regex matching more
        # than it should, and a check that over-matches fails open.
        #
        # Strip comments -- whole-line AND trailing -- and require the filename to
        # END where a filename ends. An unanchored search of the whole file is
        # satisfied by a mention in a comment, or by a longer token like
        # `...x86_64.rpm.disabled`, while the live download loop names something
        # else entirely. The boundary class covers every delimiter a filename can
        # legitimately sit against in shell: whitespace, quotes, a line
        # continuation, `;`, `)`, `,` and end of line.
        rpm_re=$(printf '%s' "$rpm_name" | sed 's/\./\\./g')
        if sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#.*$//' download-docker-packages.sh \
            | grep -qE "$rpm_re([[:space:];,)]|\"|'|\\\\|$)"; then
            ok "download loop has $rpm_name"
        else
            bad "download loop MISSING $rpm_name"
        fi
    done
done

#############################################
head_ "1.4b  containerd.io RELEASE suffix agrees everywhere"
#############################################
# containerd.io 2.3.4-1 and 2.3.4-2 are indistinguishable by %{VERSION}: same
# file list, same Requires, same version string. The only difference is
# /usr/bin/runc -- 1.4.3 in -1, 1.5.1 in -2. So the version assertions in
# upgrade-docker.sh phase 0 cannot tell a bundle built from -1 apart from one
# built from -2, and an operator with a stale bundle would pass validation and
# get a runtime nobody chose.
#
# upgrade-docker.sh therefore asserts %{RELEASE} as well. That constant, the
# filenames the download script fetches, and the filenames simulate-upgrade.sh
# fetches must all name the same build, or the bundle carries packages phase 0
# will refuse -- discovered on the air-gapped server, which is the worst place.
#
# Escape the dots: an unescaped version string is a regex that matches more
# than it should, and a check that over-matches is a check that fails open.
CT_RE=$(printf '%s' "$WANT_CONTAINERD" | sed 's/\./\\./g')

UD_CT_REL=$(grep -m1 '^EXPECTED_CONTAINERD_RELEASE="' upgrade-docker.sh \
    | sed 's/^EXPECTED_CONTAINERD_RELEASE="\(.*\)".*/\1/')
if [ -z "$UD_CT_REL" ]; then
    bad "upgrade-docker.sh has no EXPECTED_CONTAINERD_RELEASE constant"
elif [ "$UD_CT_REL" != "$WANT_CONTAINERD_RELEASE" ]; then
    bad "upgrade-docker.sh EXPECTED_CONTAINERD_RELEASE is '$UD_CT_REL', want '$WANT_CONTAINERD_RELEASE'"
else
    ok "upgrade-docker.sh asserts containerd.io release $UD_CT_REL"
fi

# The RELEASE assertion has to actually RUN, not merely be declared. Grepping
# for the name is not enough: the declaration line is itself live code, so a
# naive grep passes for a constant nothing reads. Exclude the declaration and
# require a remaining reference -- and require one in each of the two places
# that matter, the payload check and the post-install check.
ct_uses=$(grep -vE '^\s*#' upgrade-docker.sh \
    | grep -c 'EXPECTED_CONTAINERD_RELEASE' || true)
ct_decl=$(grep -c '^EXPECTED_CONTAINERD_RELEASE=' upgrade-docker.sh || true)
if [ "$(( ct_uses - ct_decl ))" -gt 0 ]; then
    ok "upgrade-docker.sh reads EXPECTED_CONTAINERD_RELEASE $(( ct_uses - ct_decl )) time(s) beyond its declaration"
else
    bad "upgrade-docker.sh declares EXPECTED_CONTAINERD_RELEASE but never reads it"
fi

# The payload gate. Phase 0 must call the release check, or a wrong bundle is
# only caught in phase 9 -- after the node has been drained, stopped and
# upgraded, which is the whole failure this guard exists to avoid.
# Pin the arguments, not just the call. A literal "1" here expects the wrong
# build while leaving the function name -- and every name-based check -- intact,
# and the behavioural section below cannot see it: that harness supplies its own
# arguments, so it tests the function, never this call site.
# shellcheck disable=SC2016  # the literal "$..." text IS the pattern
if grep -vE '^\s*#' upgrade-docker.sh \
    | grep -qF 'check_containerd_release "$FOUND_CONTAINERD_REL" "$EXPECTED_CONTAINERD_RELEASE"'; then
    ok "upgrade-docker.sh phase 0 calls check_containerd_release with the payload and the constant"
else
    bad "upgrade-docker.sh phase 0 does not call check_containerd_release with FOUND_CONTAINERD_REL / EXPECTED_CONTAINERD_RELEASE"
fi
if grep -qE '^check_containerd_release\(\) \{' upgrade-docker.sh; then
    ok "upgrade-docker.sh defines check_containerd_release"
else
    bad "upgrade-docker.sh calls check_containerd_release but never defines it"
fi

# The post-install gate: phase 9 must read the INSTALLED release, not just the
# payload's. rpm can decline or partially apply a transaction.
#
# Name the variable, not just the query. Two different sites query
# %{RELEASE} -- the already-at-target gate and phase 9 -- so a check that
# matched the query alone stayed green when phase 9's was deleted, satisfied by
# the other one.
# Pin the WHOLE assignment, not a prefix of it. A prefix match is satisfied by
# `VAR=$(rpm -q ... | sed s/1/2/)`, which keeps every required substring while
# rewriting the value the guard is about to trust.
CT_QUERY_TAIL="=\$(rpm -q containerd.io --queryformat '%{RELEASE}' 2>/dev/null || echo \"\")"
if grep -vE '^\s*#' upgrade-docker.sh | grep -qF "INSTALLED_CT_REL$CT_QUERY_TAIL"; then
    ok "upgrade-docker.sh phase 9 reads the installed containerd.io release, untransformed"
else
    bad "upgrade-docker.sh does not query the installed containerd.io %{RELEASE} verbatim"
fi

# ...and must VALIDATE what it read. Querying the release and then not comparing
# it is the failure this pair exists to separate.
# shellcheck disable=SC2016  # the literal text "$INSTALLED_CT_REL" IS the pattern; expanding it would search for this harness's own unset variable
if grep -vE '^\s*#' upgrade-docker.sh \
    | grep -qF 'containerd_release_matches "$INSTALLED_CT_REL"'; then
    ok "upgrade-docker.sh phase 9 validates the installed containerd.io release"
else
    bad "upgrade-docker.sh reads the installed containerd.io release but never checks it"
fi

# ...and the phase 9 branch must set VERIFY_FAILED. Everything above proves the
# release is read and compared; none of it proves the comparison has any
# consequence. Deleting `VERIFY_FAILED=1` from the else-branch leaves phase 9
# printing a red line and exiting 0 with "UPGRADE COMPLETE" -- and no Tier 2
# case can catch that, because every reachable scenario in the harness installs
# the RIGHT release from a valid bundle, so the else-branch never runs there.
# This text pin is the only thing standing between that mutation and a green
# suite. Search a WINDOW after the call rather than the whole file: a
# VERIFY_FAILED=1 belonging to assert_installed would otherwise satisfy it.
# shellcheck disable=SC2016  # the literal text "$INSTALLED_CT_REL" IS the pattern
ct9_line=$(grep -n 'containerd_release_matches "$INSTALLED_CT_REL"' upgrade-docker.sh \
    | head -1 | cut -d: -f1)
# Anchored to a whole-line ASSIGNMENT, not the bare text: `echo VERIFY_FAILED=1`
# contains the string and sets nothing. A trailing comment is fine.
if [ -n "$ct9_line" ] && sed -n "${ct9_line},$((ct9_line + 8))p" upgrade-docker.sh \
    | grep -qE '^[[:space:]]*VERIFY_FAILED=1[[:space:]]*(#.*)?$'; then
    ok "upgrade-docker.sh phase 9 fails the run when the installed containerd.io release is wrong"
else
    bad "upgrade-docker.sh phase 9 checks the installed containerd.io release but does not set VERIFY_FAILED (searched the 8 lines from ${ct9_line:-?}; widen the window if the branch legitimately grew)"
fi

# Both call sites must pass the CONSTANT as the expected release. A literal
# argument would satisfy a check that only looked for the function name, while
# quietly expecting the wrong build.
for site in INSTALLED_CT_REL CURRENT_CONTAINERD_REL; do
    # shellcheck disable=SC2016  # the literal "$..." text IS the pattern
    if grep -vE '^\s*#' upgrade-docker.sh \
        | grep -qF "containerd_release_matches \"\$$site\" \"\$EXPECTED_CONTAINERD_RELEASE\" \"\$RHEL_VER\""; then
        ok "containerd_release_matches($site) uses EXPECTED_CONTAINERD_RELEASE and RHEL_VER"
    else
        bad "containerd_release_matches($site) does not pass EXPECTED_CONTAINERD_RELEASE / RHEL_VER"
    fi
done

# ...and neither may be negated. `if ! containerd_release_matches ...` keeps
# every substring above intact while inverting the guard.
if grep -vE '^\s*#' upgrade-docker.sh | grep -qE '!\s*containerd_release_matches'; then
    bad "upgrade-docker.sh negates containerd_release_matches (guard inverted)"
else
    ok "upgrade-docker.sh never negates containerd_release_matches"
fi

# ...nor may its exit status be discarded. `containerd_release_matches ... || true`
# keeps every substring the checks above look for while making the guard
# unconditional. Same for the wrapper.
if grep -vE '^\s*#' upgrade-docker.sh \
    | grep -qE '(containerd_release_matches|check_containerd_release)[^#]*\|\|[[:space:]]*(true|:)'; then
    bad "upgrade-docker.sh discards the containerd release check's status with || true"
else
    ok "upgrade-docker.sh does not discard the containerd release check's status"
fi

# The predicate must be DEFINED before it is CALLED. bash reads top to bottom;
# a definition moved below its first call is a runtime "command not found" that
# neither bash -n nor shellcheck reports.
crm_def=$(grep -n '^containerd_release_matches() {' upgrade-docker.sh | head -1 | cut -d: -f1)
crm_use_real=$(grep -n 'containerd_release_matches ' upgrade-docker.sh | grep -vE '^[0-9]+:\s*#' | head -1 | cut -d: -f1)
if [ -n "$crm_def" ] && [ -n "$crm_use_real" ] && [ "$crm_def" -lt "$crm_use_real" ]; then
    ok "containerd_release_matches is defined (line $crm_def) before first use (line $crm_use_real)"
else
    bad "containerd_release_matches defined@${crm_def:-?} is not before first use@${crm_use_real:-?}"
fi

# The already-at-target gate must test the release too. That branch ends in
# `exit 0`, so whatever it accepts as "nothing to do" never reaches phase 9 --
# a node on containerd.io <version>-1 matches every %{VERSION} and would be
# sent away still running the wrong runc. A guard downstream of an early exit
# is not a guard for anything that takes the exit.
# shellcheck disable=SC2016  # the literal text "$CURRENT_CONTAINERD_REL" IS the pattern; expanding it would search for this harness's own unset variable
if grep -vE '^\s*#' upgrade-docker.sh \
    | grep -qF 'containerd_release_matches "$CURRENT_CONTAINERD_REL"'; then
    ok "upgrade-docker.sh already-at-target gate tests the containerd.io release"
else
    bad "upgrade-docker.sh already-at-target gate ignores the containerd.io release (exits 0 on a -1 node)"
fi

# The gate can only test what it read.
if grep -vE '^\s*#' upgrade-docker.sh | grep -qF "CURRENT_CONTAINERD_REL$CT_QUERY_TAIL"; then
    ok "upgrade-docker.sh reads the installed containerd.io release before the gate, untransformed"
else
    bad "upgrade-docker.sh does not populate CURRENT_CONTAINERD_REL verbatim"
fi

# Exactly one assignment. Querying it correctly and then overwriting it with
# "${EXPECTED_CONTAINERD_RELEASE}.el${RHEL_VER}" would satisfy every check above
# while handing the gate fabricated state.
ct_assigns=$(grep -vE '^\s*#' upgrade-docker.sh | grep -cE '(^|[^[:alnum:]_])CURRENT_CONTAINERD_REL=' || true)
if [ "$ct_assigns" -eq 1 ]; then
    ok "CURRENT_CONTAINERD_REL is assigned exactly once"
else
    bad "CURRENT_CONTAINERD_REL is assigned $ct_assigns times in live code (want 1)"
fi

# Every containerd.io filename in the two download paths must name exactly the
# wanted release. Collecting the distinct suffixes (rather than grepping for
# the wanted one) catches a file that fetches BOTH -- which would pass a
# "contains the right string" test while still shipping the wrong RPM.
for f in download-docker-packages.sh simulate-upgrade.sh; do
    rels=$(grep -oE "containerd\.io-$CT_RE-[0-9]+\." "$f" \
        | sed -E "s/^containerd\.io-$CT_RE-([0-9]+)\.$/\1/" | sort -u | tr '\n' ' ')
    rels="${rels% }"
    if [ -z "$rels" ]; then
        bad "$f fetches no containerd.io-$WANT_CONTAINERD-<release> RPM"
    elif [ "$rels" != "$WANT_CONTAINERD_RELEASE" ]; then
        bad "$f fetches containerd.io release(s) '$rels', want exactly '$WANT_CONTAINERD_RELEASE'"
    else
        ok "$f fetches containerd.io-$WANT_CONTAINERD-$WANT_CONTAINERD_RELEASE only"
    fi
done

# The VM harness builds containerd RPM paths by hand. A hard-coded -1 there
# would make Tier 2 truncate/copy a file that no longer exists, and the case
# would fail for a reason unrelated to what it tests.
#
# All FIVE target constants, not just the release. tests/vm/lib.sh is not in
# SCRIPTS[] -- it legitimately carries the BASELINE versions, which 1.5's
# stale-literal sweep would flag -- so nothing else in Tier 1 looks at it. A
# retarget that updated WANT_* and all six deliverable scripts but forgot this
# file passed 133/133, and tools/make-release.sh sources it: the release title
# followed automatically into being wrong.
for spec in "TARGET_DOCKER:$WANT_DOCKER" \
            "TARGET_CONTAINERD:$WANT_CONTAINERD" \
            "TARGET_BUILDX:$WANT_BUILDX" \
            "TARGET_COMPOSE:$WANT_COMPOSE" \
            "TARGET_CONTAINERD_RELEASE:$WANT_CONTAINERD_RELEASE"; do
    const="${spec%%:*}"
    want="${spec#*:}"
    # Count first, and count ANY assignment to the name -- indented, unquoted,
    # exported, readonly. grep -m1 reads the FIRST declaration while bash uses
    # the LAST, so a second assignment in any spelling would hand the harness a
    # value Tier 1 never looked at, consistently, across the release title and
    # every case.
    #
    # `|| true` would hide grep's status 2 (an unreadable file) behind its
    # status 1 (no matches), and a check that cannot read its input must say so
    # rather than report a count. Read the status.
    decls=$(grep -cE "^[[:space:]]*(export[[:space:]]+|readonly[[:space:]]+)?$const=" tests/vm/lib.sh)
    grep_rc=$?
    # Read the value in the SAME forms the count accepts. An extraction narrower
    # than the count reports "no constant" for a declaration that is present and
    # legal -- `export TARGET_DOCKER="29.8.0"`, or an indented one.
    got=$(grep -m1 -E "^[[:space:]]*(export[[:space:]]+|readonly[[:space:]]+)?$const=" tests/vm/lib.sh \
        | sed -E -e "s/^[[:space:]]*(export[[:space:]]+|readonly[[:space:]]+)?$const=//" \
                 -e 's/^"([^"]*)".*$/\1/' \
                 -e "s/^'([^']*)'.*\$/\1/" \
                 -e 's/[[:space:]].*$//')
    if [ "$grep_rc" -gt 1 ]; then
        bad "could not read tests/vm/lib.sh while checking $const (grep exited $grep_rc)"
    elif [ "$decls" -ne 1 ]; then
        bad "tests/vm/lib.sh declares $const $decls times (want exactly 1)"
    elif [ -z "$got" ]; then
        bad "tests/vm/lib.sh has no $const constant"
    elif [ "$got" != "$want" ]; then
        bad "tests/vm/lib.sh $const is '$got', want '$want'"
    else
        ok "tests/vm/lib.sh pins $const $got"
    fi
done

# Three spellings, not one. The old pattern required the unbraced
# `$TARGET_CONTAINERD` form, so `${TARGET_CONTAINERD}-1.el9` and a fully
# spelled-out `2.3.4-1.el9` both reported PASS -- the exact drift the check
# exists to catch. $BASELINE_CONTAINERD is deliberately not covered: it names a
# version upstream published once, where the release really is a constant.
# shellcheck disable=SC2016  # the literal string "$TARGET_CONTAINERD" is the pattern; expanding it would search for the version instead
vm_hardcoded=$(grep -nE 'containerd\.io-(\$\{?TARGET_CONTAINERD\}?|[0-9]+(\.[0-9]+)+)-[0-9]+\.' tests/vm/*.sh || true)
if [ -n "$vm_hardcoded" ]; then
    bad "VM harness hard-codes a containerd.io release suffix instead of \$TARGET_CONTAINERD_RELEASE"
    printf '       %s\n' "$vm_hardcoded"
else
    ok "VM harness builds containerd.io paths from \$TARGET_CONTAINERD_RELEASE"
fi

#############################################
head_ "1.4c  containerd_release_matches BEHAVES, not just exists"
#############################################
# Every check in 1.4b is a text check, and text checks share one blind spot:
# they prove a call site is present, never that the thing it calls does
# anything. Replacing the predicate's body with `return 0` passes all of them
# and makes the guard accept every bundle.
#
# So run it. This is a pure string comparison -- no root, no rpm, no RHEL, no
# side effects -- which makes it the one piece of upgrade logic Tier 1 can
# legitimately execute. It is extracted from the real script rather than
# reimplemented here, because a copy would be the next thing to drift.
ct_fn=$(awk '/^containerd_release_matches\(\) \{/,/^\}/' upgrade-docker.sh)
if [ -z "$ct_fn" ]; then
    bad "containerd_release_matches not found in upgrade-docker.sh"
else
    CT_BAD=0
    CT_CASES=0
    ct_case() {
        local want_result="$1" rel="$2" want="$3" major="$4" got
        CT_CASES=$((CT_CASES + 1))
        if ( eval "$ct_fn"; containerd_release_matches "$rel" "$want" "$major" ) 2>/dev/null; then
            got=accept
        else
            got=reject
        fi
        if [ "$got" != "$want_result" ]; then
            bad "containerd_release_matches '$rel' (want $want, el$major) -> $got, expected $want_result"
            CT_BAD=1
        fi
    }

    # The only two shapes that may be accepted.
    ct_case accept "2.el9"          2  9
    ct_case accept "2.el8"          2  8

    # The build this whole guard exists for: same %{VERSION}, runc 1.4.3.
    ct_case reject "1.el9"          2  9

    # Absent, unreadable, or rejected by an earlier phase-0 check.
    ct_case reject ""               2  9
    ct_case reject "(none)"         2  9

    # Shapes a prefix comparison used to wave through.
    ct_case reject "2"              2  9
    ct_case reject "2.1.el9"        2  9
    ct_case reject "20.el9"         2  9
    ct_case reject "x2.el9"         2  9
    ct_case reject "2mycustom.el9"  2  9
    ct_case reject ".el9"           2  9
    ct_case reject " 2.el9"         2  9
    ct_case reject "2.el9 "         2  9
    ct_case reject "2.el9.el8"      2  9
    ct_case reject "2.el9.foo"      2  9

    # The same wrong build on RHEL 8. Testing only the el9 form would let a
    # special case for "1.el8" survive -- and containerd.io-2.3.4-1.el8 is a
    # real RPM an operator can really be handed.
    ct_case reject "1.el8"          2  8

    # Wrong RHEL major, in both directions, and a major that only starts right.
    ct_case reject "2.el8"          2  9
    ct_case reject "2.el9"          2  8
    ct_case reject "1.el8"          2  9
    ct_case reject "1.el9"          2  8
    ct_case reject "2.el10"         2  9
    ct_case reject "2.el9x"         2  9

    # A blanked expectation must refuse everything rather than match ".el9".
    ct_case reject ".el9"           "" 9
    ct_case reject "2.el9"          "" 9
    ct_case reject "2.el9"          2  ""

    if [ "$CT_BAD" -eq 0 ]; then
        ok "containerd_release_matches accepts only <want>.el<major> ($CT_CASES cases)"
    fi

    # The predicate is only half the phase-0 guard. check_containerd_release is
    # the wrapper that decides whether a payload problem becomes a PKG_ERRORS
    # increment -- and phase 0 aborts on PKG_ERRORS, not on the predicate. A
    # wrapper whose body is `return 0`, or that passes a literal "1" as the
    # expected release, disables the payload gate while every text check above
    # stays green. So run the wrapper and watch the counter it is supposed to
    # move.
    ct_wrapper=$(awk '/^check_containerd_release\(\) \{/,/^\}/' upgrade-docker.sh)
    if [ -z "$ct_wrapper" ]; then
        bad "check_containerd_release not found in upgrade-docker.sh"
    else
        WRAP_BAD=0
        wrap_case() {
            local want_result="$1" rel="$2" major="$3" errs
            # Run the wrapper with the REAL constant, in a subshell carrying
            # just enough of phase 0's environment, and report the counter.
            # These four look unused to shellcheck; the eval'd function body
            # reads all of them. Its colour vars come from this script's own,
            # and its output is discarded, so only these need setting.
            # shellcheck disable=SC2034
            errs=$(
                RHEL_VER="$major"
                EXPECTED_CONTAINERD_VERSION="$WANT_CONTAINERD"
                # $UD_CT_REL, read once above from the script's own constant.
                # Re-running the extraction here meant a changed declaration
                # shape failed loudly up there and SILENTLY yielded an empty
                # expectation down here -- every wrapper case then flipping to
                # REJECT for a reason that has nothing to do with the wrapper.
                EXPECTED_CONTAINERD_RELEASE="$UD_CT_REL"
                PKG_ERRORS=0
                eval "$ct_fn"
                eval "$ct_wrapper"
                check_containerd_release "$rel" "$EXPECTED_CONTAINERD_RELEASE" >/dev/null 2>&1
                echo "$PKG_ERRORS"
            )
            local got="accept"
            [ "${errs:-0}" -gt 0 ] && got="REJECT"
            if [ "$got" != "$want_result" ]; then
                bad "check_containerd_release '$rel' on el$major -> $got, expected $want_result"
                WRAP_BAD=1
            fi
        }
        wrap_case accept "2.el9" 9
        wrap_case accept "2.el8" 8
        wrap_case REJECT "1.el9" 9   # the wrong build, el9
        wrap_case REJECT "1.el8" 8   # the wrong build, el8
        wrap_case REJECT ""      9   # containerd.io absent from the payload
        wrap_case REJECT "2.el8" 9   # el8 RPM in the rhel9 directory
        wrap_case REJECT "2"     9   # malformed
        [ "$WRAP_BAD" -eq 0 ] && ok "check_containerd_release increments PKG_ERRORS on every wrong payload (7 cases)"
    fi
fi

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
#
# MAINTENANCE: the LAST target belongs in this list too. Check 1.4 only proves
# the new versions are PRESENT; it says nothing about the old ones still being
# there. Reverting a single constant -- EXPECTED_BUILDX_VERSION back to 0.36.1,
# say -- left both checks green until 29.7.2 / 2.3.3 / 0.36.1 / 5.5.0 were
# added here. When the next retarget lands, roll this list forward: the target
# being replaced becomes stale the moment it is replaced.
#
# The fleet baseline (29.1.5 / 2.2.1) is deliberately absent from every pattern
# -- it is the version being upgraded FROM and is legitimate in all six
# scripts.
STALE_FOUND=0
for s in "${SCRIPTS[@]}"; do
    [ -f "$s" ] || continue
    if [ "$s" = "simulate-upgrade.sh" ]; then
        pattern='28\.5\.1|1\.7\.29|29\.7\.2|2\.3\.3|0\.36\.1|5\.5\.0'
        what="pre-baseline literal"
    else
        pattern='28\.5\.1|1\.7\.29|0\.30\.1|5\.0\.1|29\.7\.2|2\.3\.3|0\.36\.1|5\.5\.0'
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
cmp_fn read_config_version upgrade-docker.sh rollback-docker.sh
# The run-record machinery is duplicated across the three stateful scripts and
# MUST NOT drift. A copy that loses the STATUS_OK accumulator or the terminator
# check silently publishes truncated status files -- from one script only, which
# is exactly the kind of divergence nobody notices.
cmp_fn status_kv          upgrade-docker.sh rollback-docker.sh clean-swarm-networks.sh
cmp_fn status_common      upgrade-docker.sh rollback-docker.sh clean-swarm-networks.sh
cmp_fn write_status_file  upgrade-docker.sh rollback-docker.sh clean-swarm-networks.sh
cmp_fn derive_result      upgrade-docker.sh rollback-docker.sh clean-swarm-networks.sh
cmp_fn unit_state         upgrade-docker.sh rollback-docker.sh clean-swarm-networks.sh
cmp_fn unit_is_stopped    upgrade-docker.sh rollback-docker.sh clean-swarm-networks.sh

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
    for fn in prompt_yes_no verify_unit_stopped start_services stop_services \
              read_config_version config_is_loadable \
              containerd_release_matches check_containerd_release \
              status_kv status_common status_keys write_status_file \
              derive_result derive_next_action capture_after_versions usage \
              unit_state unit_is_stopped; do
        # Does the script reference it anywhere other than its own definition?
        refs=$(grep -vE '^\s*#' "$s" | grep -cE "(^|[^[:alnum:]_])${fn}( |$|\")" || true)
        defs=$(grep -cE "^${fn}\(\) \{" "$s" || true)
        if [ "$refs" -gt 0 ] && [ "$defs" -eq 0 ]; then
            bad "$s calls $fn but never defines it"
        elif [ "$refs" -gt 0 ] && [ "$defs" -gt 1 ]; then
            # EXACTLY one, not at least one. Two definitions mean the last one
            # wins at runtime while the first is dead -- and 1.4c, which
            # extracts by pattern, would eval BOTH and test the survivor. A
            # broken definition placed before the call sites with a correct
            # duplicate after them would run broken and test clean.
            bad "$s defines $fn $defs times (want exactly 1; the later one silently wins)"
        elif [ "$refs" -gt 0 ]; then
            ok "$s defines the $fn it calls exactly once"
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

# The containerd config-version guard must run BEFORE anything stops.
# containerd 2.2.1 refuses a version 4 config outright, so a rollback started
# with one on disk downgrades successfully and then cannot start the runtime.
# Detecting that after services are down is too late to be useful -- the whole
# value of the check is that it costs nothing while the node is still healthy.
cfg_guard_line=$(grep -n 'ROLLBACK_MAX_CONFIG_VERSION=' rollback-docker.sh | head -1 | cut -d: -f1)
cfg_stop_line=$(grep -n 'systemctl stop docker docker.socket' rollback-docker.sh | head -1 | cut -d: -f1)
if [ -n "$cfg_guard_line" ] && [ -n "$cfg_stop_line" ] && [ "$cfg_guard_line" -lt "$cfg_stop_line" ]; then
    ok "rollback-docker.sh checks the config version before stopping services"
else
    bad "rollback-docker.sh config-version guard missing or too late (guard@${cfg_guard_line:-?}, stop@${cfg_stop_line:-?})"
fi

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
head_ "1.14  Agent-mode contract"
#############################################
# docs/AGENT-RUNBOOK.md is the entry point for an agent operating a node.
# It must carry NO package version literals: the moment it names one, it joins
# the eight-file version-sync list in CLAUDE.md, and a retarget that forgets it
# ships an agent a version that is quietly wrong. It refers to versions as
# "what this run reported" instead.
#
# The pattern also matches three-part section numbers, so the runbook does not
# use them. That is deliberate -- a blanket ban is easier to reason about than
# a heuristic that tries to tell a version from a heading, and it cannot be
# defeated by a version sitting somewhere the heuristic did not expect.
if [ ! -f docs/AGENT-RUNBOOK.md ]; then
    bad "docs/AGENT-RUNBOOK.md is missing"
else
    # grep exits 0 for a match, 1 for none, and >1 for a real error. A blanket
    # `|| true` would turn an unreadable file into "no matches" -- a false PASS
    # on exactly the check whose job is to fail. Separate the three.
    vlits=$(grep -nE '[0-9]+\.[0-9]+\.[0-9]+' docs/AGENT-RUNBOOK.md)
    vrc=$?
    if [ "$vrc" -gt 1 ]; then
        bad "could not read docs/AGENT-RUNBOOK.md (grep exit $vrc)"
    elif [ "$vrc" -eq 1 ]; then
        ok "docs/AGENT-RUNBOOK.md has no version literals"
    else
        bad "docs/AGENT-RUNBOOK.md contains version literals"
        printf '%s\n' "$vlits" | sed 's/^/       /'
    fi
fi

# AGENTS.md must fork by audience. Sending an operator to CLAUDE.md costs it
# 21 KB about editing scripts it is not editing.
#
# Requiring the operator row itself, not merely the filename: a mention in a
# comment, or a sentence saying operators should NOT read it, would satisfy a
# bare filename grep while the fork was gone.
# Requiring the role label and its link on the SAME row. Searching for the
# three fragments separately would pass on an AGENTS.md whose operator row had
# been deleted, because a CLAUDE.md link appears further down the file anyway.
fork_missing=""
grep -qF '| **Changing these scripts** | **[CLAUDE.md](CLAUDE.md)**' AGENTS.md \
    || fork_missing="$fork_missing editor-row"
grep -qF '| **Operating a node**' AGENTS.md \
    || fork_missing="$fork_missing operator-row"
grep -F '| **Operating a node**' AGENTS.md \
    | grep -qF '**[docs/AGENT-RUNBOOK.md](docs/AGENT-RUNBOOK.md)**' \
    || fork_missing="$fork_missing operator-row-link"
if [ -z "$fork_missing" ]; then
    ok "AGENTS.md forks by audience; both rows link their document"
else
    bad "AGENTS.md audience fork is incomplete:$fork_missing"
fi

# Every status key a script EMITS must be documented in AGENT-RUNBOOK.md, and
# every documented key must be emitted. An agent branches on these; a key that
# is written but undocumented is a contract nobody agreed to, and a key that is
# documented but never written is one an agent will wait for for ever.
#
# Keys are extracted from the literal `status_kv <name>` call sites, which is
# why the writers use one call per key rather than a loop.
doc_keys_for() {
    awk -v want="$1" '
        $0 ~ "<!-- status-keys: " want " -->" { on = 1; next }
        /<!-- \/status-keys -->/              { on = 0 }
        # FIRST backticked token of the row only. Taking every one would pull
        # in the value domains from the second column -- true, false, unknown
        # -- and report them as undocumented keys. Each row names exactly one
        # key for this reason; do not collapse rows with "/ `_after` /".
        on && /^\| `[a-z0-9_]+` \|/ {
            if (match($0, /`[a-z0-9_]+`/))
                print substr($0, RSTART + 1, RLENGTH - 2)
        }
    ' docs/AGENT-RUNBOOK.md | LC_ALL=C sort -u
}

emitted_keys_for() {
    # Comments are stripped first: prose like "a status_kv that fails" would
    # otherwise be read as a key named "that".
    grep -vE '^[[:space:]]*#' "$1" \
        | grep -oE '(^|[^a-z_])status_kv [a-z0-9_]+' \
        | grep -oE 'status_kv [a-z0-9_]+' | awk '{print $2}' | LC_ALL=C sort -u
}

if [ ! -f docs/AGENT-RUNBOOK.md ]; then
    bad "docs/AGENT-RUNBOOK.md is missing; cannot check status keys"
else
    common_doc=$(doc_keys_for common)
    if [ -z "$common_doc" ]; then
        bad "AGENT-RUNBOOK.md has no 'common' status-key block"
    fi
    for s in upgrade-docker.sh rollback-docker.sh clean-swarm-networks.sh; do
        emitted=$(emitted_keys_for "$s")
        documented=$(printf '%s\n%s\n' "$common_doc" "$(doc_keys_for "$s")" | LC_ALL=C sort -u | grep . || true)
        undoc=$(comm -23 <(printf '%s\n' "$emitted") <(printf '%s\n' "$documented") | grep . || true)
        unemit=$(comm -13 <(printf '%s\n' "$emitted") <(printf '%s\n' "$documented") | grep . || true)
        if [ -z "$undoc" ] && [ -z "$unemit" ]; then
            ok "$s status keys match AGENT-RUNBOOK.md ($(printf '%s\n' "$emitted" | grep -c .) keys)"
        else
            [ -n "$undoc" ] && bad "$s emits undocumented status keys: $(printf '%s' "$undoc" | tr '\n' ' ')"
            [ -n "$unemit" ] && bad "$s documented but never emitted: $(printf '%s' "$unemit" | tr '\n' ' ')"
        fi
    done
fi

# The parser must be inert with zero arguments: it is the only new code on the
# default path. A `while [ "$#" -gt 0 ]` loop over an empty "$@" runs zero
# times -- but the loop existing proves nothing if a bare `$1` is read before
# it. Require the loop AND require that nothing reads a positional parameter
# outside a function before it.
for s in upgrade-docker.sh rollback-docker.sh clean-swarm-networks.sh; do
    loop=$(grep -n 'while \[ "\$#" -gt 0 \]; do' "$s" | head -1 | cut -d: -f1)
    if [ -z "$loop" ]; then
        bad "$s does not guard its argument parser on \$#"
        continue
    fi
    # Positional reads before the loop, ignoring comments and function bodies
    # (a function's $1 is its own argument, not the script's).
    early=$(awk -v stop="$loop" '
        NR >= stop { exit }
        /^[a-z_]+\(\) \{/ { infn = 1 }
        infn && /^\}/       { infn = 0; next }
        infn                { next }
        /^[[:space:]]*#/    { next }
        /\$[1-9]|\$\{[1-9]|\$@|\$\*/ { print NR ": " $0 }
    ' "$s")
    if [ -z "$early" ]; then
        ok "$s reads no positional parameter before its argument loop"
    else
        bad "$s reads a positional parameter before its argument loop"
        printf '%s\n' "$early" | sed 's/^/       /'
    fi
done

# The top-of-script ordering is load-bearing and easy to undo by accident:
#   parser -> traps -> startup record -> root check -> tee
# Each step is where it is for a reason; see CLAUDE.md.
for s in upgrade-docker.sh rollback-docker.sh clean-swarm-networks.sh; do
    l_parse=$(grep -n 'while \[ "\$#" -gt 0 \]; do' "$s" | head -1 | cut -d: -f1)
    l_trap=$(grep -n "^trap on_exit EXIT" "$s" | head -1 | cut -d: -f1)
    l_start=$(grep -n '^    if ! write_status_file; then' "$s" | head -1 | cut -d: -f1)
    l_root=$(grep -n 'id -u 2>/dev/null' "$s" | head -1 | cut -d: -f1)
    l_tee=$(grep -n '^exec > >(tee -a' "$s" | head -1 | cut -d: -f1)
    if [ -n "$l_parse" ] && [ -n "$l_trap" ] && [ -n "$l_start" ] &&
       [ -n "$l_root" ] && [ -n "$l_tee" ] &&
       [ "$l_parse" -lt "$l_trap" ] && [ "$l_trap" -lt "$l_start" ] &&
       [ "$l_start" -lt "$l_root" ] && [ "$l_root" -lt "$l_tee" ]; then
        ok "$s orders parser, traps, startup record, root check and tee correctly"
    else
        bad "$s prologue order wrong (parse@${l_parse:-?} trap@${l_trap:-?} start@${l_start:-?} root@${l_root:-?} tee@${l_tee:-?})"
    fi
done

# The status write must sit BEFORE on_exit's rc==0 short-circuit. After it, a
# successful run never updates the startup record and reports result=running
# for ever -- the single most common outcome an agent needs to confirm.
for s in upgrade-docker.sh rollback-docker.sh clean-swarm-networks.sh; do
    w=$(grep -n 'write_status_file || true' "$s" | tail -1 | cut -d: -f1)
    # shellcheck disable=SC2016  # a literal grep pattern, not an expansion
    c=$(grep -n '\[ "\$rc" -eq 0 \] && exit 0' "$s" | head -1 | cut -d: -f1)
    if [ -z "$c" ]; then
        # clean-swarm-networks.sh has no short-circuit: its trap always writes.
        # It has the opposite requirement -- the write must come AFTER the
        # trap's start_services recovery, or the record claims the node is down
        # when the trap just brought it back up.
        r=$(grep -n 'if start_services; then' "$s" | tail -1 | cut -d: -f1)
        # Not merely after the recovery CALL: after the assignments that record
        # what the recovery achieved. Writing between the two would publish
        # services_stopped=true for a node the trap had just brought back.
        f=$(grep -n 'SERVICES_STOPPED=false' "$s" | awk -F: -v r="${r:-0}" '$1 > r {print $1; exit}')
        if [ -n "$w" ] && [ -n "$r" ] && [ -n "$f" ] && [ "$w" -gt "$f" ]; then
            ok "$s writes its run record after the trap's recovery bookkeeping"
        else
            bad "$s status write at ${w:-?} is not after its recovery at ${r:-?}/${f:-?}"
        fi
    elif [ -n "$w" ] && [ "$w" -lt "$c" ]; then
        ok "$s writes its run record before the rc==0 short-circuit"
    else
        bad "$s status write is at ${w:-?}, after the rc==0 short-circuit at ${c:-?}"
    fi
done

# The root check must precede the log redirection. After it, a non-root run
# cannot open the log and the process substitution swallows every line the
# script prints -- measured, that produced no output at all.
for s in upgrade-docker.sh rollback-docker.sh clean-swarm-networks.sh; do
    r=$(grep -n 'id -u 2>/dev/null' "$s" | head -1 | cut -d: -f1)
    t=$(grep -n '^exec > >(tee -a' "$s" | head -1 | cut -d: -f1)
    if [ -n "$r" ] && [ -n "$t" ] && [ "$r" -lt "$t" ]; then
        ok "$s checks for root before installing the log redirection"
    else
        bad "$s root check missing or after the tee (root@${r:-?}, tee@${t:-?})"
    fi
done

# Every flag a parser accepts must appear in that script's own usage text, and
# every flag the usage text advertises must be accepted. `usage` used to be
# drift-checked for byte-identity across the three scripts, which stopped being
# meaningful the moment their interfaces diverged -- and byte-identity never
# proved the text matched the parser anyway.
for s in upgrade-docker.sh rollback-docker.sh clean-swarm-networks.sh; do
    parsed=$(awk '/^while \[ "\$#" -gt 0 \]; do/,/^done$/' "$s" \
        | grep -oE '^[[:space:]]*-[a-z|=*-]+\)' | tr -d ' )' | tr '|' '\n' \
        | sed 's/=\*$//' | grep -E '^-' | LC_ALL=C sort -u)
    documented=$(awk '/^usage\(\) \{/,/^\}/' "$s" \
        | grep -oE '^  -[a-z, -]*[a-z]' | tr ',' '\n' | tr -d ' ' \
        | grep -E '^-' | LC_ALL=C sort -u)
    undoc=$(comm -23 <(printf '%s\n' "$parsed") <(printf '%s\n' "$documented") | grep . || true)
    unparsed=$(comm -13 <(printf '%s\n' "$parsed") <(printf '%s\n' "$documented") | grep . || true)
    if [ -z "$undoc" ] && [ -z "$unparsed" ]; then
        ok "$s usage text matches its parser ($(printf '%s\n' "$parsed" | grep -c .) flags)"
    else
        [ -n "$undoc" ] && bad "$s accepts undocumented flags: $(printf '%s' "$undoc" | tr '\n' ' ')"
        [ -n "$unparsed" ] && bad "$s documents flags it does not accept: $(printf '%s' "$unparsed" | tr '\n' ' ')"
    fi
done

# --preflight must be READ-ONLY. Its whole value is that it converts an abort
# past the point of no return into a refusal on a healthy node, and a preflight
# that mutates anything destroys that.
#
# Comments are stripped first: the block explains which mutations it avoids, and
# a grep that reads its own prose as code reports the explanation as the crime.
if ! grep -q '^preflight_report() {' upgrade-docker.sh; then
    bad "upgrade-docker.sh has no preflight_report to check"
else
    # Scope: preflight_report, plus PHASE 0 -- the two regions every preflight
    # run executes unconditionally. Phase 1 is deliberately NOT scanned. It
    # contains a real `docker node update --availability drain`, in a branch
    # preflight never enters, and no text check can decide that reachability.
    # A scan that included it would report the drain as a violation for ever,
    # and a check that always fails gets disabled, which is worse than a check
    # with a stated limit. The phase-1 guard is asserted separately below.
    pf_from=$(grep -n '^CURRENT_PHASE="phase 0 (validate packages)"' upgrade-docker.sh | head -1 | cut -d: -f1)
    pf_to=$(grep -n '^CURRENT_PHASE="phase 1 (swarm drain)"' upgrade-docker.sh | head -1 | cut -d: -f1)
    pf=$( { awk '/^preflight_report\(\) \{/,/^\}/' upgrade-docker.sh
            if [ -n "$pf_from" ] && [ -n "$pf_to" ]; then
                sed -n "${pf_from},${pf_to}p" upgrade-docker.sh
            fi; } | grep -vE '^[[:space:]]*#' \
        | grep -vE '^[[:space:]]*echo ([^>]|$)*$')
    # Widened past the obvious few: touch, cp, mv, sed -i, tee and a systemctl
    # restart all mutate, and a blacklist that omits them invites them.
    # shellcheck disable=SC2016  # a literal grep pattern, not an expansion
    muts=$(printf '%s\n' "$pf" | grep -nE 'mkdir|touch[[:space:]]|(^|[^a-z_-])cp[[:space:]]|(^|[^a-z_-])mv[[:space:]]|sed[[:space:]]+-i|(^|[^a-z_-])tee[[:space:]]|systemctl[[:space:]]+(start|stop|restart|enable|disable)|dnf[[:space:]]+(clean|install|remove|upgrade)|rpm[[:space:]]+--rebuilddb|(^|[^-])rpm[[:space:]]+-e|docker[[:space:]]+node[[:space:]]+update|(^|[^-])rm[[:space:]]+-|truncate[[:space:]]|chmod[[:space:]]|chown[[:space:]]|(^|[^a-z_-])ln[[:space:]]|(^|[^a-z_-])mount[[:space:]]|umount[[:space:]]|systemctl[[:space:]]+mask|>[[:space:]]*"?\$CONTAINERD_CONF' || true)
    # rpm -Uvh is only allowed with --test, which changes nothing.
    rpmm=$(printf '%s\n' "$pf" | grep -E 'rpm -Uvh' | grep -v -- '--test' || true)
    # Any redirect that lands in a FILE. A command blacklist cannot catch
    # `echo x > /somewhere`, and that writes just as surely as touch does.
    # /dev/null and fd duplications are the only permitted targets.
    # `-` before `>` is an ASCII arrow in report text, not a redirect. Every
    # other non-fd, non-dup `>` that lands on a name is one.
    #
    # Parameter expansions are blanked first. A `>` inside `${...}` is part of a
    # default value, never a redirect -- `${found:-<none>}` in phase 0 is the
    # live example. Only the body is removed, so a genuine `> "${FILE}"` still
    # shows its `>` followed by a quote and is still caught.
    redir=$(printf '%s\n' "$pf" | sed 's/\${[^{}]*}/${}/g' \
        | grep -nE '(^|[^0-9&<>-])>>?[[:space:]]*[^&[:space:]]' \
        | grep -v '/dev/null' || true)
    if [ -z "$muts" ] && [ -z "$rpmm" ] && [ -z "$redir" ]; then
        ok "upgrade-docker.sh preflight path contains none of the known mutators"
    else
        bad "upgrade-docker.sh preflight_report contains a mutating command"
        printf '%s\n%s\n%s\n' "$muts" "$rpmm" "$redir" | grep . | sed 's/^/       /'
    fi
fi

# preflight_report must CALL the hoisted checks. Without this, deleting the
# call leaves every other static check green -- the phase-6 enforcement check
# still finds phase 6's own call, and the read-only scan is happier with less
# code, not less happy. Tier 2 mutant M2 proves the behavioural hazard; this
# catches the deletion at Tier 1, where it is cheap.
pf_body=$(awk '/^preflight_report\(\) \{/,/^\}/' upgrade-docker.sh | grep -vE '^[[:space:]]*#')
pf_missing=""
for fn in read_config_version read_containerd_root relocated_root_is_missing; do
    printf '%s\n' "$pf_body" | grep -q "$fn" || pf_missing="$pf_missing $fn"
done
if [ -z "$pf_missing" ]; then
    ok "upgrade-docker.sh preflight_report calls all three hoisted readers"
else
    bad "upgrade-docker.sh preflight_report does not call:$pf_missing"
fi

# The --preflight arm must not assign STATUS_FILE. Case 2.30b2 checks one
# sentinel path, which cannot catch a regression that picks a different default.
pf_arm_body=$(grep -E '^[[:space:]]*--preflight\)' upgrade-docker.sh || true)
if printf '%s\n' "$pf_arm_body" | grep -q 'STATUS_FILE'; then
    bad "upgrade-docker.sh --preflight assigns STATUS_FILE"
else
    ok "upgrade-docker.sh --preflight writes no status file of its own"
fi

# tests/vm/negative-control.sh locates phase 6 by a marker before searching for
# its anchor. It used to take the first match, which silently moved into
# preflight_report when that grew the same `-f` test -- the mutant then patched
# code a normal run never executes, changed nothing, and the control reported
# that the hazard it exists to prove was not real.
if grep -q 'phase 6 (containerd config)' tests/vm/negative-control.sh; then
    ok "negative-control.sh scopes its mutation to phase 6"
else
    bad "negative-control.sh does not scope its mutation to phase 6"
fi

# Preflight must not advertise gate keys it cannot compute. Two of the six
# gates depend on what the run DOES, not on what a node at rest looks like, and
# a list that silently omits them is worse than no list.
if grep -qE '^[[:space:]]*status_kv gates_' upgrade-docker.sh; then
    bad "upgrade-docker.sh emits gate keys; preflight cannot predict them yet"
else
    ok "upgrade-docker.sh emits no gate keys"
fi

# The preflight exit must sit AFTER phase 0 and BEFORE phase 2. Earlier and it
# skips the payload validation that is the bulk of what it exists to run;
# later and it has already repaired dnf and written a backup.
# shellcheck disable=SC2016  # a literal grep pattern, not an expansion
pf_exit=$(grep -n 'exit "\$PREFLIGHT_RC"' upgrade-docker.sh | head -1 | cut -d: -f1)
p0=$(grep -n '^CURRENT_PHASE="phase 0 (validate packages)"' upgrade-docker.sh | head -1 | cut -d: -f1)
p2=$(grep -n '^CURRENT_PHASE="phase 2 (pre-upgrade checks)"' upgrade-docker.sh | head -1 | cut -d: -f1)
# Phase 1's preflight arm must come FIRST, so the drain and the attestation sit
# in elif branches behind it and preflight cannot reach either. This is what
# the read-only scan above deliberately does not try to prove textually.
# The CONDITION, not the message it prints: a mutant that swapped the guard for
# `if false` kept the message and sailed through a message-based check. Grepping
# for a string the call site supplies proves nothing about the call site.
p1_start=$(grep -n '^CURRENT_PHASE="phase 1 (swarm drain)"' upgrade-docker.sh | head -1 | cut -d: -f1)
# shellcheck disable=SC2016  # a literal grep pattern, not an expansion
pf_arm=$(grep -n 'if \[ "\$MODE" = "preflight" \]; then' upgrade-docker.sh \
    | awk -F: -v p="${p1_start:-0}" '$1 > p {print $1; exit}')
# shellcheck disable=SC2016  # a literal grep pattern, not an expansion
drain_line=$(grep -n 'docker node update --availability drain "\$SWARM_NODE_ID"' upgrade-docker.sh | head -1 | cut -d: -f1)
# "Before" is not enough: turning the following `elif` into a separate `if`
# would leave the arm first AND let preflight fall through into the drain.
# Require the availability branch between them to be an elif, and require no
# sibling `if` on the same variable.
# shellcheck disable=SC2016  # literal grep patterns, not expansions
avail_elif=$(sed -n "${pf_arm:-1},${drain_line:-1}p" upgrade-docker.sh \
    | grep -cE '^    elif \[ "\$NODE_AVAILABILITY"' || true)
# shellcheck disable=SC2016  # literal grep pattern, not an expansion
avail_if=$(sed -n "${pf_arm:-1},${drain_line:-1}p" upgrade-docker.sh \
    | grep -cE '^    if \[ "\$NODE_AVAILABILITY"' || true)
if [ -n "$pf_arm" ] && [ -n "$drain_line" ] && [ "$pf_arm" -lt "$drain_line" ] &&
   [ "$avail_elif" -ge 1 ] && [ "$avail_if" -eq 0 ]; then
    ok "upgrade-docker.sh phase 1 gates the drain behind its preflight arm"
else
    bad "upgrade-docker.sh phase 1 drain is not behind the preflight arm (arm@${pf_arm:-?} drain@${drain_line:-?} elif=$avail_elif if=$avail_if)"
fi

p1=$(grep -n '^CURRENT_PHASE="phase 1 (swarm drain)"' upgrade-docker.sh | head -1 | cut -d: -f1)
if [ -n "$pf_exit" ] && [ -n "$p0" ] && [ -n "$p1" ] && [ -n "$p2" ] &&
   [ "$p0" -lt "$p1" ] && [ "$p1" -lt "$pf_exit" ] && [ "$pf_exit" -lt "$p2" ]; then
    ok "upgrade-docker.sh preflight exits after phases 0 and 1, before phase 2"
else
    bad "upgrade-docker.sh preflight exit misplaced (p0@${p0:-?} p1@${p1:-?} exit@${pf_exit:-?} p2@${p2:-?})"
fi

# Phase 6 must still ENFORCE what preflight predicts, through the same helpers,
# so the two cannot answer differently. Preflight predicts; phase 6 enforces.
p6=$(grep -n '^CURRENT_PHASE="phase 6 (containerd config)"' upgrade-docker.sh | head -1 | cut -d: -f1)
enf=$(grep -n 'relocated_root_is_missing' upgrade-docker.sh | awk -F: -v p="${p6:-0}" '$1 > p {print $1; exit}')
if [ -n "$enf" ]; then
    ok "upgrade-docker.sh phase 6 still enforces the relocated-root check"
else
    bad "upgrade-docker.sh phase 6 no longer calls relocated_root_is_missing"
fi

#############################################
head_ "1.3  Upstream package availability"
#############################################
if [ "$ONLINE" = false ]; then
    skip "URL checks (pass --online to run)"
else
    # Built from the same WANT_PKGS table as the download-loop check above, so
    # the URL probed and the filename the bundle fetches cannot disagree. This
    # loop used to hard-code "-1" per package, which meant it would have happily
    # confirmed the existence of the WRONG containerd build.
    BASE="https://download.docker.com/linux/rhel"
    for major in 8 9; do
        for spec in "${WANT_PKGS[@]}" "${WANT_ROLLBACK_PKGS[@]}"; do
            pkg=$(pkg_rpm_name "$spec" "$major")
            code=$(curl -sIL -o /dev/null -w '%{http_code}' --max-time 25 \
                "$BASE/$major/x86_64/stable/Packages/$pkg" || echo "000")
            if [ "$code" = "200" ]; then ok "el$major $pkg"; else bad "el$major $pkg (HTTP $code)"; fi
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

#!/bin/bash
# shellcheck disable=SC2016,SC1091  # single-quoted VM commands must expand INSIDE the VM
# tests/vm/tier2-run.sh
# Execute the Tier 2 cases from docs/TEST-PLAN.md against the VM baseline.
#
# Order matters and is deliberate:
#   1. REJECTION tests first. Each corrupts the package directory in a specific
#      way and asserts the upgrade refuses in phase 0 with the node untouched.
#      They are safe to run consecutively because none of them changes the node.
#   2. The real upgrade, which is also the relocated-root regression test.
#   3. Post-upgrade assertions: versions, config preservation, data integrity.
#   4. Idempotent re-run.
#   5. Rollback, and its own assertions.
#
# Every rejection test restores a pristine package dir from the bundle before
# the next one, so a failure in one cannot cascade.
#
# Usage:
#   tests/vm/tier2-run.sh            # everything
#   tests/vm/tier2-run.sh reject     # rejection tests only
#   tests/vm/tier2-run.sh upgrade    # upgrade + assertions only
#   tests/vm/tier2-run.sh rollback   # rollback only
#   tests/vm/tier2-run.sh agent      # agent-mode cases only (2.29-2.38)
#
# The `agent` phase is separate on purpose. The reject/upgrade/rollback phases
# are the interactive-path regression gate and their assertion count must not
# move; agent-mode cases are added beside them, never inside them.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source ./lib.sh

require_vm
# Hard precondition: the relocated containerd root must actually be on the
# separate XFS. If it is not, the 2.4 assertions below are comparing shadow
# state and would fail for a reason that has nothing to do with the scripts.
require_relocated_xfs

PHASE_ARG="${1:-all}"
PKG_DIR="/opt/docker-offline/rhel9"

# A pristine, already-extracted copy of the bundle, kept beside it in the guest.
#
# restore_pkgs runs before every rejection case -- eleven times in a full run --
# and used to re-extract the whole 350 MB tarball each time. `gzip -t` alone on
# that file measures 1.56 s in the guest, so a run spent ~17 s decompressing
# before any tar write, to reset a directory of five RPMs.
#
# Keyed on the bundle's digest, so a rebuilt bundle is re-extracted rather than
# silently reset from a stale copy -- the one way a cache like this could make
# the whole suite test yesterday's artifact.
PRISTINE="/root/pristine-docker-offline"
ensure_pristine() {
    if ! vm "set -e
want=\$(sha256sum /opt/docker-upgrade-bundle.tar.gz | cut -d' ' -f1)
# The guest has errexit but not pipefail, so a failed sha256sum still leaves cut
# exiting 0 and want empty. An empty key would be WRITTEN as the cache key and
# then match the next empty one, so a rebuilt bundle would never invalidate it.
[ -n \"\$want\" ] || { echo 'could not checksum the bundle' >&2; exit 1; }
have=\$(cat $PRISTINE.sha256 2>/dev/null || echo none)
if [ \"\$want\" != \"\$have\" ] || [ ! -d $PRISTINE ]; then
    rm -rf $PRISTINE $PRISTINE.tmp $PRISTINE.sha256
    mkdir -p $PRISTINE.tmp
    tar xzf /opt/docker-upgrade-bundle.tar.gz -C $PRISTINE.tmp
    mv $PRISTINE.tmp/docker-offline $PRISTINE
    rm -rf $PRISTINE.tmp
    printf '%s\n' \"\$want\" > $PRISTINE.sha256
fi" >/dev/null 2>&1; then
        echo "  ${RED}ERROR${NC}: could not extract a pristine copy of the bundle in the VM." >&2
        echo "  Every rejection case restores from it; without it they would run" >&2
        echo "  against whatever the previous case left behind." >&2
        exit 1
    fi
}

# Restore a pristine package directory from that copy.
#
# Fails the RUN, not silently. A restore that did not happen leaves the previous
# case's sabotage in place and the next case passes or fails for that reason
# instead of its own.
restore_pkgs() {
    if ! vm "set -e
rm -rf /opt/docker-offline
cp -a $PRISTINE /opt/docker-offline" >/dev/null 2>&1; then
        echo "  ${RED}ERROR${NC}: could not restore /opt/docker-offline from $PRISTINE." >&2
        exit 1
    fi
}

# Run the upgrade with stdin closed. Any prompt is a hard failure by design
# (prompt_yes_no refuses EOF), which makes an unexpected prompt loud rather
# than silently auto-answered.
run_upgrade() { vm_try "cd /opt/docker-offline && ./upgrade-docker.sh </dev/null 2>&1"; }

# One extraction, before any case needs it.
ensure_pristine

# --- helper: assert the node was NOT touched by a rejected run ---------------
assert_untouched() {
    local label="$1"
    local v
    v=$(vm_try "rpm -q docker-ce --queryformat '%{VERSION}'" | tail -1)
    if [ "$v" = "$BASELINE_DOCKER" ]; then
        ok "$label: docker-ce still $BASELINE_DOCKER"
    else
        bad "$label: docker-ce is now $v -- the node WAS modified"
    fi
    local d
    d=$(vm_try "systemctl is-active docker" | tail -1)
    if [ "$d" = "active" ]; then
        ok "$label: docker still running"
    else
        bad "$label: docker is '$d' -- services were stopped by a rejected run"
    fi
}

#############################################
if [ "$PHASE_ARG" = "all" ] || [ "$PHASE_ARG" = "reject" ]; then
head_ "Phase 0 rejection tests (node must remain untouched)"
#############################################

# 2.6 -- wrong bundle: the PREVIOUS round's RPMs, same layout, same filenames
restore_pkgs
vm "rm -f $PKG_DIR/*.rpm && cp /opt/docker-offline/rollback-rhel9/*.rpm $PKG_DIR/" >/dev/null 2>&1
out=$(run_upgrade)
if printf '%s' "$out" | grep -q "expected $TARGET_DOCKER"; then
    ok "2.6 wrong bundle ($BASELINE_DOCKER RPMs) rejected on version"
else
    bad "2.6 wrong bundle NOT rejected on version"
    printf '%s\n' "$out" | tail -5 | sed 's/^/       /'
fi
assert_untouched "2.6"

# 2.7 -- duplicates: new bundle extracted over the old one
restore_pkgs
vm "cp /opt/docker-offline/rollback-rhel9/docker-ce-*.rpm $PKG_DIR/" >/dev/null 2>&1
out=$(run_upgrade)
if printf '%s' "$out" | grep -qi "duplicate"; then
    ok "2.7 duplicate RPMs rejected"
else
    bad "2.7 duplicate RPMs NOT rejected"
    printf '%s\n' "$out" | tail -5 | sed 's/^/       /'
fi
assert_untouched "2.7"

# 2.8 -- corrupt RPM
restore_pkgs
vm "truncate -s -1M $PKG_DIR/containerd.io-$TARGET_CONTAINERD-$TARGET_CONTAINERD_RELEASE.el9.x86_64.rpm" >/dev/null 2>&1
out=$(run_upgrade)
if printf '%s' "$out" | grep -qi "digest verification"; then
    ok "2.8 corrupt RPM rejected on digest"
else
    bad "2.8 corrupt RPM NOT rejected"
    printf '%s\n' "$out" | tail -5 | sed 's/^/       /'
fi
assert_untouched "2.8"

# 2.9 -- wrong release: REPLACE the el9 build with its el8 counterpart
#        (adding it would trip the duplicate check first)
restore_pkgs
vm "rm -f $PKG_DIR/containerd.io-$TARGET_CONTAINERD-$TARGET_CONTAINERD_RELEASE.el9.x86_64.rpm
    cp /opt/docker-offline/rhel8/containerd.io-$TARGET_CONTAINERD-$TARGET_CONTAINERD_RELEASE.el8.x86_64.rpm $PKG_DIR/" >/dev/null 2>&1
out=$(run_upgrade)
if printf '%s' "$out" | grep -qi "is not el9"; then
    ok "2.9 wrong-release (el8 in rhel9 dir) rejected"
else
    bad "2.9 wrong-release NOT rejected"
    printf '%s\n' "$out" | tail -5 | sed 's/^/       /'
fi
assert_untouched "2.9"

# 2.6a -- the RIGHT version, the WRONG build.
#
# containerd.io 2.3.4 was published upstream twice. -1 and -2 carry the same
# %{VERSION}, the same file list and the same Requires; the only difference is
# /usr/bin/runc, 1.4.3 in -1 and 1.5.1 in -2. So every version assertion in
# phase 0 passes for either, and only EXPECTED_CONTAINERD_RELEASE separates
# them.
#
# This uses the real upstream -1 RPM rather than a hand-edited file, because a
# doctored package would be caught by the digest check instead and this case
# would pass for the wrong reason.
#
# The assertions below are STATE assertions, not an exit code. A node that is
# refused and a node that is upgraded with the wrong runc and then fails both
# exit non-zero; only the package versions, the services and the data tell
# them apart.
# If upstream ever publishes the target containerd version only once, there is
# no other build to stage and this case has nothing to say. Fail loudly instead
# of passing vacuously.
if [ "$WRONG_CONTAINERD_RELEASE" = "$TARGET_CONTAINERD_RELEASE" ]; then
    bad "2.6a WRONG_CONTAINERD_RELEASE equals the target release -- no wrong build exists to test"
fi
restore_pkgs
vm "rm -f $PKG_DIR/containerd.io-*.rpm
    dnf download -q --destdir=$PKG_DIR containerd.io-$TARGET_CONTAINERD-$WRONG_CONTAINERD_RELEASE.el9 >/dev/null 2>&1" >/dev/null 2>&1
# Read the RPM HEADER, not the filename. "Assert on RPM metadata, never on
# filenames" is the rule the product scripts follow, and it applies to the guard
# that decides whether this case is vacuous: a file renamed to look right would
# satisfy a basename comparison.
staged=$(vm_try "rpm -qp --queryformat '%{NAME} %{VERSION}-%{RELEASE}' $PKG_DIR/containerd.io-*.rpm 2>/dev/null" | tr -d '\r' | tail -1)
want_staged="containerd.io $TARGET_CONTAINERD-$WRONG_CONTAINERD_RELEASE.el9"
if [ "$staged" = "$want_staged" ]; then
    ok "2.6a staged the real upstream $want_staged"
else
    bad "2.6a could not stage $want_staged (got '$staged') -- case is vacuous"
fi
out=$(run_upgrade)
# The refusal must name the RELEASE, not just say "wrong version" -- an
# operator whose bundle differs only in the release needs to be told that.
if printf '%s' "$out" | grep -q "containerd.io release is $WRONG_CONTAINERD_RELEASE.el9"; then
    ok "2.6a wrong containerd RELEASE rejected, and the refusal names it"
else
    bad "2.6a wrong containerd RELEASE NOT rejected on the release"
    printf '%s\n' "$out" | tail -8 | sed 's/^/       /'
fi
# It must also say WHY the release matters, or the operator has no way to know
# the two builds differ at all.
if printf '%s' "$out" | grep -q "runc $WRONG_RUNC"; then
    ok "2.6a the refusal explains the runc difference"
else
    bad "2.6a the refusal does not mention the runc difference"
fi
# And it must refuse in PHASE 0 -- before the drain, before services stop.
if printf '%s' "$out" | grep -q "Phase 1"; then
    bad "2.6a reached phase 1 -- the refusal came too late to be free"
else
    ok "2.6a refused in phase 0, before the Swarm drain"
fi
assert_untouched "2.6a"
# assert_untouched covers docker-ce and docker. The containerd half is the
# whole point of this case, so assert it explicitly rather than by implication.
#
# VERSION-RELEASE together, and ONLY that. The baseline containerd.io 2.2.1 has
# release "1.el9" and so does the WRONG build 2.3.4-1, so asserting the release
# by itself passes whether the node was refused or upgraded to the wrong
# runtime -- mutation testing caught that. A separate %{VERSION}-only assertion
# used to sit here too; it is strictly implied by this one, cannot fail
# independently, and only inflated the case count.
assert_vm_eq "2.6a: containerd.io is still $BASELINE_CONTAINERD-1.el9 exactly" \
    "rpm -q containerd.io --queryformat '%{VERSION}-%{RELEASE}'" "$BASELINE_CONTAINERD-1.el9"
assert_vm_eq "2.6a: containerd still active" "systemctl is-active containerd" "active"
assert_vm_eq "2.6a: docker.socket still active" "systemctl is-active docker.socket" "active"
# The data the guard is protecting. A refusal that cost the node its images
# would not be a refusal worth having.
assert_vm_eq "2.6a: canary data on the relocated root intact" \
    "docker start survivor >/dev/null 2>&1; docker exec survivor cat /data/canary.txt" \
    "VOLUME-CANARY-DATA"

# 2.10 -- empty package directory
restore_pkgs
vm "rm -f $PKG_DIR/*.rpm" >/dev/null 2>&1
out=$(run_upgrade)
if printf '%s' "$out" | grep -qi "No .rpm files found"; then
    ok "2.10 empty package dir rejected"
else
    bad "2.10 empty package dir NOT rejected"
    printf '%s\n' "$out" | tail -5 | sed 's/^/       /'
fi
assert_untouched "2.10"

# 2.11 -- stale plugins: correct core packages, previous round's plugins
restore_pkgs
vm "rm -f $PKG_DIR/docker-buildx-plugin-*.rpm $PKG_DIR/docker-compose-plugin-*.rpm
    dnf download -q --destdir=$PKG_DIR docker-buildx-plugin-$BASELINE_BUILDX docker-compose-plugin-$BASELINE_COMPOSE >/dev/null 2>&1" >/dev/null 2>&1
out=$(run_upgrade)
if printf '%s' "$out" | grep -q "docker-buildx-plugin is $BASELINE_BUILDX"; then
    ok "2.11 stale plugins rejected"
else
    bad "2.11 stale plugins NOT rejected"
    printf '%s\n' "$out" | tail -6 | sed 's/^/       /'
fi
assert_untouched "2.11"

# 2.12 -- missing plugins entirely
restore_pkgs
vm "rm -f $PKG_DIR/docker-buildx-plugin-*.rpm $PKG_DIR/docker-compose-plugin-*.rpm" >/dev/null 2>&1
out=$(run_upgrade)
if printf '%s' "$out" | grep -q "no docker-buildx-plugin package found"; then
    ok "2.12 missing plugins rejected"
else
    bad "2.12 missing plugins NOT rejected"
    printf '%s\n' "$out" | tail -6 | sed 's/^/       /'
fi
assert_untouched "2.12"

restore_pkgs
fi

#############################################
if [ "$PHASE_ARG" = "all" ] || [ "$PHASE_ARG" = "upgrade" ]; then
head_ "2.3 / 2.4 / 2.5  Real upgrade over a RELOCATED containerd root"
#############################################
restore_pkgs

# Capture the pre-upgrade truth.
#
# A MISSING manifest must abort, not silently compare everything against the
# empty string -- that produces a screen of confident-looking FAILs whose
# "want" is '' and hides whether the product actually worked. Fail closed, the
# same rule the scripts themselves follow.
BEFORE=$(vm_try "cat $MANIFEST 2>/dev/null")
if [ -z "$BEFORE" ]; then
    echo "  ${RED}ERROR${NC}: baseline manifest $MANIFEST is missing or empty in the VM." >&2
    echo "  Run tests/vm/bootstrap-vm.sh (or reset-baseline.sh) first -- the" >&2
    echo "  2.4/2.5 assertions have nothing to compare against without it." >&2
    exit 1
fi

b_conf_sha=$(printf '%s' "$BEFORE" | sed -n 's/^CONTAINERD_CONF_SHA=//p')
b_daemon_sha=$(printf '%s' "$BEFORE" | sed -n 's/^DAEMON_JSON_SHA=//p')
b_image=$(printf '%s' "$BEFORE" | sed -n 's/^IMAGE_ID=//p')
b_container=$(printf '%s' "$BEFORE" | sed -n 's/^CONTAINER_ID=//p')
b_root=$(printf '%s' "$BEFORE" | sed -n 's/^CONTAINERD_ROOT=//p')

for pair in "CONTAINERD_CONF_SHA:$b_conf_sha" "DAEMON_JSON_SHA:$b_daemon_sha" \
            "IMAGE_ID:$b_image" "CONTAINER_ID:$b_container" "CONTAINERD_ROOT:$b_root"; do
    if [ -z "${pair#*:}" ]; then
        echo "  ${RED}ERROR${NC}: manifest key ${pair%%:*} is empty. Re-run bootstrap." >&2
        exit 1
    fi
done

echo "  pre-upgrade containerd root: $b_root"
echo "  pre-upgrade config sha:      ${b_conf_sha:0:16}..."

out=$(run_upgrade)
if printf '%s' "$out" | grep -q "UPGRADE COMPLETE"; then
    ok "2.3 upgrade-docker.sh completed"
else
    bad "2.3 upgrade did NOT complete"
    printf '%s\n' "$out" | tail -25 | sed 's/^/       /'
fi

assert_vm_eq "2.3 docker-ce is $TARGET_DOCKER" \
    "rpm -q docker-ce --queryformat '%{VERSION}'" "$TARGET_DOCKER"
# %{VERSION}-%{RELEASE}, not %{VERSION}. containerd.io 2.3.4 shipped twice, so
# the version alone is not a build identity -- and this is the only place either
# tier asserts what rpm actually LEFT ON THE NODE as one. Phase 9's own release
# check had nothing behind it on either tier: deleting its VERIFY_FAILED left
# Tier 1 at 133/133 and Tier 2 green.
assert_vm_eq "2.3 containerd.io is $TARGET_CONTAINERD-$TARGET_CONTAINERD_RELEASE.el9 exactly" \
    "rpm -q containerd.io --queryformat '%{VERSION}-%{RELEASE}'" \
    "$TARGET_CONTAINERD-$TARGET_CONTAINERD_RELEASE.el9"
# The consequence the release guard exists for, asserted directly: the two
# builds differ in nothing but this binary.
assert_vm_eq "2.3 runc is $TARGET_RUNC (the build the release guard selects)" \
    "runc --version 2>/dev/null | head -1 | awk '{print \$3}'" "$TARGET_RUNC"
assert_vm_eq "2.3 buildx is $TARGET_BUILDX" \
    "rpm -q docker-buildx-plugin --queryformat '%{VERSION}'" "$TARGET_BUILDX"
assert_vm_eq "2.3 compose is $TARGET_COMPOSE" \
    "rpm -q docker-compose-plugin --queryformat '%{VERSION}'" "$TARGET_COMPOSE"
assert_vm_eq "2.3 docker service active" "systemctl is-active docker" "active"
assert_vm_eq "2.3 containerd service active" "systemctl is-active containerd" "active"

# --- 2.4: the regression this whole change exists to prevent ---
assert_vm_eq "2.4 containerd config is BYTE-IDENTICAL" \
    "sha256sum /etc/containerd/config.toml | cut -d' ' -f1" "$b_conf_sha"
assert_vm_eq "2.4 containerd root still $b_root" \
    "sed -n \"s/^root[[:space:]]*=[[:space:]]*'\\(.*\\)'.*/\\1/p\" /etc/containerd/config.toml" "$b_root"
assert_vm_eq "2.4 root is still on the separate filesystem" \
    "findmnt -n -o TARGET --target $RELOCATED_ROOT" "/data"
assert_vm_eq "2.4 image survived (same ID)" \
    "docker image inspect alpine:3.19 --format '{{.Id}}'" "$b_image"
assert_vm_eq "2.4 container survived (same ID)" \
    "docker inspect survivor --format '{{.Id}}'" "$b_container"
assert_vm_ok  "2.4 container starts after upgrade" "docker start survivor"
assert_vm_eq "2.4 volume data intact" \
    "docker exec survivor cat /data/canary.txt" "VOLUME-CANARY-DATA"
assert_vm_ok  "2.4 overlayfs snapshotter usable" \
    "ctr snapshots --snapshotter overlayfs ls"

# /var/lib/containerd must not have become a second, live root
vl=$(vm_try "ls -A /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots 2>/dev/null | wc -l" | tail -1)
dl=$(vm_try "ls -A $RELOCATED_ROOT/io.containerd.snapshotter.v1.overlayfs/snapshots 2>/dev/null | wc -l" | tail -1)
if [ "${dl:-0}" -gt 0 ]; then
    ok "2.4 snapshots live on the relocated root ($dl)"
else
    bad "2.4 relocated root has NO snapshots -- containerd is using another root"
fi
echo "       (/var/lib/containerd snapshots: ${vl:-0}, $RELOCATED_ROOT: ${dl:-0})"

# --- 2.5: daemon.json untouched ---
assert_vm_eq "2.5 daemon.json is byte-identical" \
    "sha256sum /etc/docker/daemon.json | cut -d' ' -f1" "$b_daemon_sha"
assert_vm_ok "2.5 docker loaded the configured registry mirror" \
    "docker info 2>/dev/null | grep -q mirror.internal.example.com"

# --- 2.14: idempotent re-run ---
head_ "2.14  Idempotent re-run (already at target)"
out=$(run_upgrade)
if printf '%s' "$out" | grep -q "already fully at the target versions"; then
    ok "2.14 re-run detects already-at-target"
else
    bad "2.14 re-run did NOT detect already-at-target"
    printf '%s\n' "$out" | tail -8 | sed 's/^/       /'
fi

#############################################
head_ "2.6b  Already-at-target gate: every target version, the WRONG containerd build"
#############################################
# The other side of the release guard. 2.6a covers phase 0 refusing a wrong
# PAYLOAD; this covers the gate that decides there is nothing to do at all.
#
# That gate ends in `exit 0`, so anything it waves through never reaches phase
# 9. A node holding containerd.io 2.3.4-1 matches every %{VERSION} in it while
# running runc 1.4.3, and a version-only gate would tell the operator the node
# was done and leave a runtime nobody chose.
#
# The node is put on the wrong build by DOWNGRADING containerd.io alone with the
# real upstream -1 RPM -- no mutation of the script under test, and no doctored
# package. docs/TEST-PLAN.md describes reaching this state by running a -1
# bundle with the guard disabled; downgrading in place reaches the same state
# without ever running a mutant.
SETUP_2_6B=ok
if ! vm "set -e
rm -rf /root/wrongct && mkdir -p /root/wrongct
dnf download -q --destdir=/root/wrongct containerd.io-$TARGET_CONTAINERD-$WRONG_CONTAINERD_RELEASE.el9 >/dev/null 2>&1
systemctl stop docker docker.socket >/dev/null 2>&1 || true
systemctl stop containerd >/dev/null 2>&1 || true
rpm -Uvh --oldpackage --replacepkgs /root/wrongct/containerd.io-*.rpm >/dev/null 2>&1
systemctl start containerd
for i in \$(seq 1 30); do ctr version >/dev/null 2>&1 && break; sleep 2; done
systemctl start docker
sleep 3" >/dev/null 2>&1; then
    bad "2.6b could not stage the wrong containerd build -- case is vacuous"
    SETUP_2_6B=failed
fi

# The precondition, asserted rather than assumed, and it GATES the case.
#
# assert_vm_eq cannot do this job: it increments FAIL and returns, so a setup
# that half-applied -- the downgrade done, containerd not restarted -- would be
# reported and then the case would carry on describing a scenario that never
# existed. This variant flips the gate as well.
setup_assert_2_6b() {
    local label="$1" cmd="$2" want="$3" got
    got=$(vm_try "$cmd" | tr -d '\r' | tail -1)
    if [ "$got" = "$want" ]; then
        ok "$label"
    else
        bad "$label (got '$got', want '$want')"
        SETUP_2_6B=failed
    fi
}

if [ "$SETUP_2_6B" = ok ]; then
    setup_assert_2_6b "2.6b setup: node is on the wrong build $TARGET_CONTAINERD-$WRONG_CONTAINERD_RELEASE.el9" \
        "rpm -q containerd.io --queryformat '%{VERSION}-%{RELEASE}'" \
        "$TARGET_CONTAINERD-$WRONG_CONTAINERD_RELEASE.el9"
    setup_assert_2_6b "2.6b setup: docker-ce is still at the target $TARGET_DOCKER" \
        "rpm -q docker-ce --queryformat '%{VERSION}'" "$TARGET_DOCKER"
    setup_assert_2_6b "2.6b setup: runc is the wrong build's $WRONG_RUNC" \
        "runc --version 2>/dev/null | head -1 | awk '{print \$3}'" "$WRONG_RUNC"
else
    skip "2.6b setup assertions (staging failed -- see above)"
fi

# The corrective run happens either way: it is what returns the node to the
# target build, and the rollback section below starts from there.
restore_pkgs
out=$(run_upgrade)

# What the run SAID is only meaningful if the node really was on the wrong build,
# so those checks are gated on the setup.
if [ "$SETUP_2_6B" != ok ]; then
    skip "2.6b output assertions (the node was never on the wrong build)"
else
    if printf '%s' "$out" | grep -q "already fully at the target versions"; then
        bad "2.6b the gate called a node on $TARGET_CONTAINERD-$WRONG_CONTAINERD_RELEASE.el9 already-at-target"
        printf '%s\n' "$out" | tail -8 | sed 's/^/       /'
    else
        ok "2.6b the already-at-target gate does not accept the wrong containerd build"
    fi
    if printf '%s' "$out" | grep -q "UPGRADE COMPLETE"; then
        ok "2.6b the run completed rather than exiting with nothing to do"
    else
        bad "2.6b the run did not complete"
        printf '%s\n' "$out" | tail -20 | sed 's/^/       /'
    fi
    # Scan ONLY from the phase 9 banner onward. Phase 0 prints a byte-identical
    # "containerd.io release 2.el9" line about the PAYLOAD, so a whole-output
    # grep passes even when the run exits at the already-at-target gate and
    # never reaches phase 9 -- which is precisely what the 2.6b mutant does.
    # Measured: under that mutant this line was green while every assertion
    # around it went red. A green line that survives the mutation proves
    # nothing, so it is anchored to the phase it claims to be about.
    phase9=$(printf '%s\n' "$out" | sed -n '/=== Phase 9: Verification ===/,$p')
    if printf '%s' "$phase9" | grep -q "containerd.io release $TARGET_CONTAINERD_RELEASE.el9"; then
        ok "2.6b phase 9 reported the installed containerd.io release"
    else
        bad "2.6b phase 9 did not report the installed containerd.io release"
    fi
fi

# The STATE assertions are NOT gated. They are the ones that tell a node the
# gate waved through from a node that was upgraded -- both exit 0 -- and they
# are also what the rollback section below depends on. Skipping them after a
# failed setup would hand 2.16 a node in an unknown state and let its failures
# read as rollback defects.
assert_vm_eq "2.6b: containerd.io is now $TARGET_CONTAINERD-$TARGET_CONTAINERD_RELEASE.el9" \
    "rpm -q containerd.io --queryformat '%{VERSION}-%{RELEASE}'" \
    "$TARGET_CONTAINERD-$TARGET_CONTAINERD_RELEASE.el9"
assert_vm_eq "2.6b: runc is now $TARGET_RUNC, not $WRONG_RUNC" \
    "runc --version 2>/dev/null | head -1 | awk '{print \$3}'" "$TARGET_RUNC"
assert_vm_eq "2.6b: docker active after the corrective run" "systemctl is-active docker" "active"
assert_vm_eq "2.6b: containerd active after the corrective run" "systemctl is-active containerd" "active"
assert_vm_eq "2.6b: canary data on the relocated root intact" \
    "docker start survivor >/dev/null 2>&1; docker exec survivor cat /data/canary.txt" \
    "VOLUME-CANARY-DATA"
fi

#############################################
if [ "$PHASE_ARG" = "all" ] || [ "$PHASE_ARG" = "rollback" ]; then
head_ "2.16  Rollback to $BASELINE_DOCKER"
#############################################
# Rollback prompts in phase 0b when more than one backup exists (which is the
# normal state after any upgrade). Answer "y" -- accepting the newest backup.
# Note stdin is a real stream here, NOT /dev/null: with stdin closed the script
# correctly refuses rather than silently defaulting, which is the behaviour the
# prompt_yes_no EOF guard exists to provide.
out=$(vm_try "cd /opt/docker-offline && yes y | ./rollback-docker.sh 2>&1")
if printf '%s' "$out" | grep -q "ROLLBACK COMPLETE"; then
    ok "2.16 rollback-docker.sh completed"
else
    bad "2.16 rollback did NOT complete"
    printf '%s\n' "$out" | tail -25 | sed 's/^/       /'
fi
assert_vm_eq "2.16 docker-ce back to $BASELINE_DOCKER" \
    "rpm -q docker-ce --queryformat '%{VERSION}'" "$BASELINE_DOCKER"
assert_vm_eq "2.16 containerd.io back to $BASELINE_CONTAINERD" \
    "rpm -q containerd.io --queryformat '%{VERSION}'" "$BASELINE_CONTAINERD"
assert_vm_eq "2.16 docker running after rollback" "systemctl is-active docker" "active"
assert_vm_eq "2.16 canary data survived rollback" \
    "docker start survivor >/dev/null 2>&1; docker exec survivor cat /data/canary.txt" \
    "VOLUME-CANARY-DATA"
fi

#############################################
if [ "$PHASE_ARG" = "agent" ]; then
head_ "2.29  Agent mode: the run record"
#############################################
# Slice 2 of the agent-mode plan: the argument parser, the root check and
# --status-file. NO prompt behaviour changes in this slice, so every case here
# still runs on a terminal or with stdin closed exactly as before.
#
# Runs from a reset S1 baseline and leaves one.
./reset-baseline.sh >/dev/null 2>&1
restore_pkgs
SF=/tmp/agent-status.kv
vm "rm -f $SF" >/dev/null 2>&1

# --- 2.29a: zero arguments behave exactly as before ---
capture_strict_state a29a
out=$(run_upgrade)
if printf '%s' "$out" | grep -q "UPGRADE COMPLETE"; then
    ok "2.29a zero-argument run still completes"
else
    bad "2.29a zero-argument run did NOT complete"
    printf '%s\n' "$out" | tail -20 | sed 's/^/       /'
fi
assert_pkg_profile "2.29a" target
assert_vm_eq "2.29a containerd config unchanged by the upgrade" \
    "sha256sum /etc/containerd/config.toml | cut -d' ' -f1" "${STRICT_CONF_SHA[a29a]}"
assert_vm_eq "2.29a canary data intact" \
    "docker start survivor >/dev/null 2>&1; docker exec survivor cat /data/canary.txt" \
    "VOLUME-CANARY-DATA"

# --- 2.29b: the record of a successful run ---
./reset-baseline.sh >/dev/null 2>&1
restore_pkgs
vm "rm -f $SF" >/dev/null 2>&1
out=$(vm_try "cd /opt/docker-offline && ./upgrade-docker.sh --status-file=$SF </dev/null 2>&1")
if printf '%s' "$out" | grep -q "UPGRADE COMPLETE"; then
    ok "2.29b run with --status-file completed"
else
    bad "2.29b run with --status-file did NOT complete"
    printf '%s\n' "$out" | tail -20 | sed 's/^/       /'
fi
assert_status_complete "2.29b" "$SF"
assert_status_key "2.29b" "$SF" result completed
assert_status_key "2.29b" "$SF" exit_code 0
assert_status_key "2.29b" "$SF" pkg_state installed
assert_status_key "2.29b" "$SF" services_stopped false
assert_status_key "2.29b" "$SF" next_action none
assert_status_key "2.29b" "$SF" mode interactive
assert_status_key "2.29b" "$SF" log_started true
assert_status_key "2.29b" "$SF" containerd_root "$RELOCATED_ROOT"
assert_status_key "2.29b" "$SF" containerd_root_relocated true
assert_status_key "2.29b" "$SF" containerd_root_present true
assert_status_key "2.29b" "$SF" docker_ce_after "$TARGET_DOCKER"
assert_status_key "2.29b" "$SF" docker_ce_expected "$TARGET_DOCKER"
assert_status_key "2.29b" "$SF" containerd_io_after "$TARGET_CONTAINERD"
# The release, not only the version: the same containerd version has shipped
# with two different runc builds, so a record carrying the version alone cannot
# say which one is installed.
assert_status_key "2.29b" "$SF" containerd_io_release_after "${TARGET_CONTAINERD_RELEASE}.el${VM_RELEASE}"
assert_status_key "2.29b" "$SF" containerd_io_release_expected "${TARGET_CONTAINERD_RELEASE}.el${VM_RELEASE}"
assert_status_key "2.29b" "$SF" containerd_io_release_before "${BASELINE_CONTAINERD_RELEASE}.el${VM_RELEASE}"
assert_status_key "2.29b" "$SF" docker_ce_before "$BASELINE_DOCKER"
# result=running would mean the trap never updated the startup record. That is
# the exact failure the write-before-short-circuit ordering exists to prevent,
# and mutant M1a in agent-mode-negative-control.sh reproduces it.
r=$(status_key "$SF" result)
if [ "$r" != "running" ]; then
    ok "2.29b startup record was superseded by the final one"
else
    bad "2.29b record still says result=running after a successful upgrade"
fi

# --- 2.29c: the record of a phase 0 refusal, and the node is untouched ---
./reset-baseline.sh >/dev/null 2>&1
restore_pkgs
capture_strict_state a29c
vm "rm -f $SF && rm -f $PKG_DIR/*.rpm && cp /opt/docker-offline/rollback-rhel9/*.rpm $PKG_DIR/" >/dev/null 2>&1
vm_try "cd /opt/docker-offline && ./upgrade-docker.sh --status-file=$SF </dev/null 2>&1" >/dev/null
assert_status_complete "2.29c" "$SF"
assert_status_key "2.29c" "$SF" result refused
assert_status_key "2.29c" "$SF" pkg_state untouched
assert_status_key "2.29c" "$SF" services_stopped false
assert_untouched_strict "2.29c" baseline a29c
restore_pkgs

# --- 2.29d: a non-root refusal still writes a record ---
vm "rm -f $SF" >/dev/null 2>&1
capture_strict_state a29d
rc=$(vm_try "runuser -u nobody -- /opt/docker-offline/upgrade-docker.sh --status-file=$SF; echo \$?" | tail -1)
if [ "$rc" = "1" ]; then
    ok "2.29d non-root run exits 1"
else
    bad "2.29d non-root run exited '$rc', want 1"
fi
assert_status_complete "2.29d" "$SF"
assert_status_key "2.29d" "$SF" result refused
assert_status_key "2.29d" "$SF" refusal_reason not-root
assert_status_key "2.29d" "$SF" next_action rerun-as-root
assert_status_key "2.29d" "$SF" log_started false
# An early record must say `unknown`, never an empty string: every key has to
# stay inside its documented domain even before anything has been observed.
assert_status_key "2.29d" "$SF" containerd_io_release_expected unknown
assert_status_key "2.29d" "$SF" containerd_io_release_after unknown
assert_untouched_strict "2.29d" baseline a29d

# --- 2.29e: a usage error writes NOTHING ---
vm "rm -f $SF" >/dev/null 2>&1
capture_strict_state a29e
rc=$(vm_try "cd /opt/docker-offline && ./upgrade-docker.sh --nonsense-flag --status-file=$SF </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "1" ]; then
    ok "2.29e unrecognised argument exits 1"
else
    bad "2.29e unrecognised argument exited '$rc', want 1"
fi
if vm_try "test -e $SF; echo \$?" | tail -1 | grep -qx 1; then
    ok "2.29e usage error wrote no status file"
else
    bad "2.29e usage error wrote a status file"
fi
assert_untouched_strict "2.29e" baseline a29e

# --- 2.29f: run_id differs between runs, and every record terminates ---
vm "rm -f $SF" >/dev/null 2>&1
vm_try "runuser -u nobody -- /opt/docker-offline/upgrade-docker.sh --status-file=$SF" >/dev/null
id1=$(status_key "$SF" run_id)
vm_try "runuser -u nobody -- /opt/docker-offline/upgrade-docker.sh --status-file=$SF" >/dev/null
id2=$(status_key "$SF" run_id)
if [ -n "$id1" ] && [ -n "$id2" ] && [ "$id1" != "$id2" ]; then
    ok "2.29f run_id differs between runs ($id1 / $id2)"
else
    bad "2.29f run_id did not change ('$id1' / '$id2')"
fi
assert_status_complete "2.29f" "$SF"

# --- 2.29g: every documented key is present, not merely the terminator ---
# This is what catches a mid-file write failure. A last-line check alone
# cannot: the terminator is written after the failure and still lands.
# The key list comes from the script itself, not from a copy maintained here:
# a hand-written list drifts, and a drifted list turns this from a check into
# decoration. tests/static-checks.sh already proves the script's keys and the
# runbook's agree, so either source is the same set.
mapfile -t DOC_KEYS < <(grep -vE '^[[:space:]]*#' "$HARNESS_REPO_DIR/upgrade-docker.sh" \
    | grep -oE '(^|[^a-z_])status_kv [a-z0-9_]+' \
    | grep -oE 'status_kv [a-z0-9_]+' | awk '{print $2}' | LC_ALL=C sort -u)
missing=""
for k in "${DOC_KEYS[@]}"; do
    vm_try "grep -q '^${k}=' $SF; echo \$?" | tail -1 | grep -qx 0 || missing="$missing $k"
done
if [ -z "$missing" ] && [ "${#DOC_KEYS[@]}" -gt 40 ]; then
    ok "2.29g all ${#DOC_KEYS[@]} documented keys are present in the record"
else
    bad "2.29g record is missing keys:${missing:- (or the key list is empty: ${#DOC_KEYS[@]})}"
fi

# --- 2.29h: an unwritable status path refuses before anything happens ---
capture_strict_state a29h
rc=$(vm_try "cd /opt/docker-offline && ./upgrade-docker.sh --status-file=/nonexistent-dir/s.kv </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "1" ]; then
    ok "2.29h unwritable status path exits 1"
else
    bad "2.29h unwritable status path exited '$rc', want 1"
fi
out=$(vm_try "cd /opt/docker-offline && ./upgrade-docker.sh --status-file=/nonexistent-dir/s.kv </dev/null 2>&1")
if printf '%s' "$out" | grep -q "cannot write status file"; then
    ok "2.29h names the path it could not write"
else
    bad "2.29h did not name the unwritable path"
fi
assert_untouched_strict "2.29h" baseline a29h

# --- 2.29i: rollback and cleanup write records too ---
vm "rm -f $SF" >/dev/null 2>&1
capture_strict_state a29i
vm_try "runuser -u nobody -- /opt/docker-offline/rollback-docker.sh --status-file=$SF" >/dev/null
assert_status_key "2.29i rollback" "$SF" script rollback-docker.sh
assert_status_key "2.29i rollback" "$SF" refusal_reason not-root
assert_status_key "2.29i rollback" "$SF" result refused
assert_status_complete "2.29i rollback" "$SF"
# The guard's job is to stop a non-root run doing anything. Asserting the
# status alone would pass for a run that downgraded the node and then failed.
assert_untouched_strict "2.29i rollback" baseline a29i

vm "rm -f $SF" >/dev/null 2>&1
capture_strict_state a29i2
# Seed one object inside cleanup's exact deletion scope. Without it this case
# proves nothing about the destructive path: the S1 baseline is deliberately
# not a Swarm node, so it has no VXLAN interfaces, no docker_gwbridge and an
# empty netns directory, and a cleanup that deleted everything it could find
# would still leave the node looking untouched.
vm "mkdir -p /var/run/docker/netns && touch /var/run/docker/netns/agent-canary" >/dev/null 2>&1
vm_try "runuser -u nobody -- /opt/docker-offline/clean-swarm-networks.sh --status-file=$SF" >/dev/null
assert_status_key "2.29i cleanup" "$SF" script clean-swarm-networks.sh
assert_status_key "2.29i cleanup" "$SF" refusal_reason not-root
assert_status_key "2.29i cleanup" "$SF" result refused
assert_status_key "2.29i cleanup" "$SF" deleted false
assert_status_complete "2.29i cleanup" "$SF"
assert_untouched_strict "2.29i cleanup" baseline a29i2
if vm_try "test -e /var/run/docker/netns/agent-canary; echo \$?" | tail -1 | grep -qx 0; then
    ok "2.29i cleanup: the seeded netns object survived the refusal"
else
    bad "2.29i cleanup: the seeded netns object was DELETED by a non-root run"
fi
vm "rm -f /var/run/docker/netns/agent-canary" >/dev/null 2>&1

# --- 2.29j: an exit-0 decline is distinguishable from a completed upgrade ---
# Exit 0 has meant three different things in this script for as long as it has
# existed. The record is what separates them; the exit code still cannot.
#
# This covers the already-at-target decline. The unverified-baseline decline
# takes the same path through derive_result and is not separately staged here,
# because reaching it needs a version that is neither the baseline nor the
# target -- a fixture this suite does not have.
./reset-baseline.sh >/dev/null 2>&1
restore_pkgs
vm_try "cd /opt/docker-offline && ./upgrade-docker.sh --status-file=$SF </dev/null 2>&1" >/dev/null
capture_strict_state a29j
vm "rm -f $SF" >/dev/null 2>&1
# Already at target now. Answer "no" on a real stream -- with stdin closed the
# EOF guard fires first and this would test the wrong thing.
rc=$(vm_try "cd /opt/docker-offline && printf 'n\n' | ./upgrade-docker.sh --status-file=$SF >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "0" ]; then
    ok "2.29j already-at-target decline still exits 0"
else
    bad "2.29j already-at-target decline exited '$rc', want 0"
fi
assert_status_key "2.29j" "$SF" result nothing-to-do
assert_status_key "2.29j" "$SF" pkg_state untouched
assert_status_complete "2.29j" "$SF"
assert_strict_state_unchanged "2.29j" a29j
r=$(status_key "$SF" result)
if [ "$r" != "completed" ]; then
    ok "2.29j a decline is not recorded as a completed upgrade"
else
    bad "2.29j decline recorded as result=completed -- exit 0 is still ambiguous"
fi


#############################################
head_ "2.30  Agent mode: --preflight"
#############################################
# Slice 3. Every case here asserts STATE, not the exit code: a preflight that
# mutated the node and then reported the right answer would pass an exit-code
# check, and mutating nothing is the entire promise of the flag.
./reset-baseline.sh >/dev/null 2>&1
restore_pkgs
vm "rm -f $SF" >/dev/null 2>&1

# Three cases below deliberately point the containerd config at a path that
# does not exist. An interrupted suite would leave it there, which is a broken
# node. Restore whatever backup exists on any exit, including a signal.
restore_pf_config() {
    vm "for b in /etc/containerd/config.toml.pf30c /etc/containerd/config.toml.d2 /etc/containerd/config.toml.pf /etc/containerd/config.toml.pf30f; do
            [ -f \"\$b\" ] && mv -f \"\$b\" /etc/containerd/config.toml
        done; true" >/dev/null 2>&1 || true
}
# INT and TERM route through the EXIT trap rather than doing the cleanup and
# letting bash resume the suite -- a signal that only ran a handler would leave
# the next case running against a half-restored guest.
trap 'restore_pf_config' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- 2.30a: preflight on a healthy node reports ready and changes nothing ---
capture_strict_state a30a
# The log is appended to, so count the phase markers before and after. A
# preflight that reached phase 4 would add one, and no state assertion on
# packages or services would necessarily catch it.
p4_before=$(vm_try "grep -c '=== Phase 4: Stop Services ===' /var/log/docker-upgrade.log 2>/dev/null || echo 0" | tail -1)
rc=$(vm_try "cd /opt/docker-offline && ./upgrade-docker.sh --preflight --status-file=$SF </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "0" ]; then
    ok "2.30a preflight on a healthy node exits 0"
else
    bad "2.30a preflight exited '$rc', want 0"
    vm_try "cd /opt/docker-offline && ./upgrade-docker.sh --preflight </dev/null 2>&1" | tail -15 | sed 's/^/       /'
fi
assert_status_key "2.30a" "$SF" mode preflight
assert_status_key "2.30a" "$SF" result ready
assert_status_key "2.30a" "$SF" containerd_root "$RELOCATED_ROOT"
assert_status_key "2.30a" "$SF" containerd_root_relocated true
assert_status_key "2.30a" "$SF" containerd_root_present true
assert_status_key "2.30a" "$SF" pkg_state untouched
assert_status_key "2.30a" "$SF" services_stopped false
assert_status_key "2.30a" "$SF" next_action proceed
assert_status_key "2.30a" "$SF" log_started true
assert_status_key "2.30a" "$SF" node_class baseline
# Phase 1 detection must actually have run. Without these, moving the preflight
# exit above phase 1 would leave every other assertion here green.
assert_status_key "2.30a" "$SF" swarm_active false
assert_status_key "2.30a" "$SF" swarm_role none
assert_status_complete "2.30a" "$SF"
assert_untouched_strict "2.30a" baseline a30a
p4_after=$(vm_try "grep -c '=== Phase 4: Stop Services ===' /var/log/docker-upgrade.log 2>/dev/null || echo 0" | tail -1)
if [ "$p4_before" = "$p4_after" ]; then
    ok "2.30a preflight never reached phase 4 (markers $p4_after)"
else
    bad "2.30a phase 4 marker count changed ($p4_before -> $p4_after) -- preflight stopped services"
fi
# It must also leave no backup and no generated config behind.
if vm_try "test -e /root/docker-backup-preflight; echo \$?" | tail -1 | grep -qx 1; then
    ok "2.30a preflight created no backup directory of its own"
else
    bad "2.30a preflight created a backup directory"
fi

# --- 2.30b: preflight refuses every phase-0 corruption, node untouched ---
# The same corruptions the interactive cases 2.6 through 2.12 use. One of them
# would not prove preflight runs the whole of phase 0, which is most of what
# the flag is for.
for corruption in wrong-bundle duplicates corrupt-rpm wrong-release empty-dir stale-plugins missing-plugins; do
    restore_pkgs
    case "$corruption" in
        wrong-bundle)   vm "rm -f $PKG_DIR/*.rpm && cp /opt/docker-offline/rollback-rhel9/*.rpm $PKG_DIR/" >/dev/null 2>&1 ;;
        duplicates)     vm "cp /opt/docker-offline/rollback-rhel9/docker-ce-*.rpm $PKG_DIR/" >/dev/null 2>&1 ;;
        corrupt-rpm)    vm "truncate -s -1M $PKG_DIR/containerd.io-$TARGET_CONTAINERD-$TARGET_CONTAINERD_RELEASE.el9.x86_64.rpm" >/dev/null 2>&1 ;;
        wrong-release)  vm "rm -f $PKG_DIR/containerd.io-*.rpm
                            cp /opt/docker-offline/rhel8/containerd.io-*.rpm $PKG_DIR/" >/dev/null 2>&1 ;;
        empty-dir)      vm "rm -f $PKG_DIR/*.rpm" >/dev/null 2>&1 ;;
        stale-plugins)  # rollback-rhel9 ships no plugins, so copying from it
                        # would stage MISSING plugins and duplicate the next
                        # case. Fetch the previous round's builds, as 2.11 does.
                        vm "rm -f $PKG_DIR/docker-buildx-plugin-*.rpm $PKG_DIR/docker-compose-plugin-*.rpm
                            dnf download -q --destdir=$PKG_DIR docker-buildx-plugin-$BASELINE_BUILDX docker-compose-plugin-$BASELINE_COMPOSE" >/dev/null 2>&1
                        staged_plugins=$(vm_try "ls $PKG_DIR/docker-buildx-plugin-*.rpm 2>/dev/null | wc -l" | tail -1)
                        if [ "${staged_plugins:-0}" -lt 1 ]; then
                            bad "2.30b could not stage stale plugins -- that iteration is vacuous"
                        fi ;;
        missing-plugins) vm "rm -f $PKG_DIR/docker-buildx-plugin-*.rpm $PKG_DIR/docker-compose-plugin-*.rpm" >/dev/null 2>&1 ;;
    esac
    vm "rm -f $SF" >/dev/null 2>&1
    capture_strict_state "a30b_$corruption"
    rc=$(vm_try "cd /opt/docker-offline && ./upgrade-docker.sh --preflight --status-file=$SF </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
    if [ "$rc" = "1" ]; then
        ok "2.30b preflight refuses: $corruption"
    else
        bad "2.30b preflight exited '$rc' on $corruption, want 1"
    fi
    assert_status_key "2.30b $corruption" "$SF" result refused
    assert_status_key "2.30b $corruption" "$SF" refusal_reason payload-invalid
    assert_status_key "2.30b $corruption" "$SF" next_action rebuild-bundle
    assert_untouched_strict "2.30b $corruption" baseline "a30b_$corruption"
done
restore_pkgs

# --- 2.30b2: a bare preflight writes no status file ---
capture_strict_state a30b2
vm "rm -f /tmp/should-not-exist.kv" >/dev/null 2>&1
rc=$(vm_try "cd /opt/docker-offline && ./upgrade-docker.sh --preflight </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "0" ]; then
    ok "2.30b2 bare preflight exits 0"
else
    bad "2.30b2 bare preflight exited '$rc', want 0"
fi
if vm_try "test -e /tmp/should-not-exist.kv; echo \$?" | tail -1 | grep -qx 1; then
    ok "2.30b2 bare preflight wrote no status file"
else
    bad "2.30b2 bare preflight wrote a status file"
fi
assert_untouched_strict "2.30b2" baseline a30b2

# --- 2.30c: THE HOIST. A relocated root that does not exist. ---
# Today the real run discovers this in phase 6, after the rpm transaction and
# with services stopped. Preflight must find it with everything still up.
#
# Staged by pointing the config at an absent path, NOT by unmounting /data.
# Unmounting cannot stage it here: the harness creates a shadow /data/containerd
# before it mounts, so the directory survives the unmount, and containerd has
# RequiresMountsFor=/data/containerd, so restarting it remounts. Either way the
# root would read as present and this case would pass for a fixture reason.
# Worse, if the remount ever failed, starting containerd against the shadow
# root is itself the data-loss hazard this test exists to prevent.
capture_strict_state a30c
orig_sha=$(vm_try "sha256sum /etc/containerd/config.toml | cut -d' ' -f1" | tail -1)
vm "set -e
    rm -f $SF
    cp /etc/containerd/config.toml /etc/containerd/config.toml.pf30c
    sed -i \"s|^root = .*|root = '/data/absent-root-30c'|\" /etc/containerd/config.toml" >/dev/null 2>&1
staged=$(vm_try "sed -n \"s/^root = '\\(.*\\)'/\\1/p\" /etc/containerd/config.toml | head -1" | tail -1)
absent=$(vm_try "test -d /data/absent-root-30c; echo \$?" | tail -1)
if [ "$staged" = "/data/absent-root-30c" ] && [ "$absent" = "1" ]; then
    ok "2.30c staged a relocated root that does not exist"
else
    bad "2.30c staging failed (root='$staged', absent-rc='$absent') -- the case is vacuous"
fi
rc=$(vm_try "cd /opt/docker-offline && ./upgrade-docker.sh --preflight --status-file=$SF </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "1" ]; then
    ok "2.30c preflight refuses a relocated root that does not exist"
else
    bad "2.30c preflight exited '$rc', want 1"
fi
assert_status_key "2.30c" "$SF" result refused
assert_status_key "2.30c" "$SF" refusal_reason relocated-root-missing
assert_status_key "2.30c" "$SF" next_action fix-mount
assert_status_key "2.30c" "$SF" containerd_root /data/absent-root-30c
assert_status_key "2.30c" "$SF" containerd_root_present false
assert_status_key "2.30c" "$SF" pkg_state untouched
# STATE: the whole point is that this refusal is FREE. All five packages
# untouched and both services still running, which is exactly what phase 6
# cannot offer -- by then the transaction has run and the node is down.
assert_pkg_profile "2.30c" baseline
assert_vm_eq "2.30c docker still active" "systemctl is-active docker" "active"
assert_vm_eq "2.30c containerd still active" "systemctl is-active containerd" "active"
# And it must NOT have created the directory it refused over. Creating it is
# the hazard: containerd would start against an empty root and every image and
# snapshot would look lost.
if vm_try "test -d /data/absent-root-30c; echo \$?" | tail -1 | grep -qx 1; then
    ok "2.30c preflight did NOT create the missing root"
else
    bad "2.30c preflight created /data/absent-root-30c -- that is the hazard itself"
fi
vm "mv -f /etc/containerd/config.toml.pf30c /etc/containerd/config.toml" >/dev/null 2>&1
# Only NOW is the config comparable again: it was deliberately different for
# the run above, so comparing it mid-case would fail on the fixture, not the
# product.
assert_vm_eq "2.30c config restored to the original" \
    "sha256sum /etc/containerd/config.toml | cut -d' ' -f1" "$orig_sha"
assert_strict_state_unchanged "2.30c after restore" a30c

# --- 2.30d: preflight on an already-upgraded node reports nothing-to-do ---
vm "rm -f $SF" >/dev/null 2>&1
run_upgrade >/dev/null
capture_strict_state a30d
rc=$(vm_try "cd /opt/docker-offline && ./upgrade-docker.sh --preflight --status-file=$SF </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "3" ]; then
    ok "2.30d preflight on an at-target node exits 3"
else
    bad "2.30d preflight exited '$rc', want 3"
fi
assert_status_key "2.30d" "$SF" result nothing-to-do
assert_status_key "2.30d" "$SF" next_action none
# The EXIT trap must not print its failure report for a read-only run. On exit
# 3 it would put a red "UPGRADE FAILED" directly under preflight's own green
# "Nothing to do", so the same output says both -- and the report describes
# services, packages and rollback options for a node preflight never touched.
pf_out=$(vm_try "cd /opt/docker-offline && ./upgrade-docker.sh --preflight </dev/null 2>&1")
if printf '%s' "$pf_out" | grep -q "UPGRADE FAILED"; then
    bad "2.30d preflight printed the UPGRADE FAILED report for a run that changed nothing"
else
    ok "2.30d preflight did not print the failure report"
fi
assert_status_key "2.30d" "$SF" node_class at-target
assert_untouched_strict "2.30d" target a30d

# --- 2.30d2: at-target AND a missing relocated root reports nothing-to-do ---
# The real run's default answer to "re-run anyway?" is no, and that branch
# exits before phase 6 -- so a finding only a re-run would hit must not be
# reported as a refusal the default path would produce.
vm "set -e
    rm -f $SF
    cp /etc/containerd/config.toml /etc/containerd/config.toml.d2
    sed -i \"s|^root = .*|root = '/data/absent-root-30d2'|\" /etc/containerd/config.toml" >/dev/null 2>&1
d2_root=$(vm_try "sed -n \"s/^root = '\\(.*\\)'/\\1/p\" /etc/containerd/config.toml | head -1" | tail -1)
if [ "$d2_root" = "/data/absent-root-30d2" ]; then
    ok "2.30d2 staged an absent relocated root"
else
    bad "2.30d2 staging failed (root='$d2_root') -- the precedence test is vacuous"
fi
rc=$(vm_try "cd /opt/docker-offline && ./upgrade-docker.sh --preflight --status-file=$SF </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "3" ]; then
    ok "2.30d2 at-target plus a missing root still exits 3"
else
    bad "2.30d2 exited '$rc', want 3 -- a re-run-only finding was reported as a refusal"
fi
assert_status_key "2.30d2" "$SF" result nothing-to-do
assert_status_key "2.30d2" "$SF" refusal_reason ""
# The finding must still be REPORTED, just not acted on: an at-target node
# whose root is missing is a real fact, it simply is not what the default path
# would refuse over.
assert_status_key "2.30d2" "$SF" containerd_root_present false
vm "mv -f /etc/containerd/config.toml.d2 /etc/containerd/config.toml" >/dev/null 2>&1

# --- 2.30e: preflight is read-only even with a v4 config on disk ---
# It must REPORT the rollback implication, not refuse over it: the upgrade
# itself is unaffected by a v4 config, only a later rollback is.
vm "rm -f $SF && cp /etc/containerd/config.toml /etc/containerd/config.toml.pf && containerd config default > /etc/containerd/config.toml" >/dev/null 2>&1
v4sha=$(vm_try "sha256sum /etc/containerd/config.toml | cut -d' ' -f1" | tail -1)
rc=$(vm_try "cd /opt/docker-offline && ./upgrade-docker.sh --preflight --status-file=$SF </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "3" ] || [ "$rc" = "0" ]; then
    ok "2.30e a v4 config does not make preflight refuse (exit $rc)"
else
    bad "2.30e preflight exited '$rc' on a v4 config; the upgrade is unaffected by it"
fi
assert_vm_eq "2.30e preflight did not rewrite the config" \
    "sha256sum /etc/containerd/config.toml | cut -d' ' -f1" "$v4sha"
assert_status_key "2.30e" "$SF" containerd_config_rollback_safe false
vm "mv -f /etc/containerd/config.toml.pf /etc/containerd/config.toml" >/dev/null 2>&1

# --- 2.30f: an ABSENT config is reported as unknown, never as rollback-safe ---
# The absent-config branch is the one place preflight cannot predict the
# rollback implication: phase 6 will GENERATE a default, and under the target
# containerd that default is v4. Preflight cannot read it -- the binary that
# would answer `containerd config default` today is the OLD one -- so the only
# honest answer is `unknown`. Reporting `true` here would be a lie in the
# dangerous direction, telling an agent a rollback is safe on the one node
# where the upgrade is about to write a config that blocks it.
vm "rm -f $SF && cp /etc/containerd/config.toml /etc/containerd/config.toml.pf30f && rm -f /etc/containerd/config.toml" >/dev/null 2>&1
gone=$(vm_try "test -e /etc/containerd/config.toml; echo \$?" | tail -1)
if [ "$gone" = "1" ]; then
    ok "2.30f staged an absent containerd config"
else
    bad "2.30f staging failed -- the config is still present, the case is vacuous"
fi
rc=$(vm_try "cd /opt/docker-offline && ./upgrade-docker.sh --preflight --status-file=$SF </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "3" ] || [ "$rc" = "0" ]; then
    ok "2.30f an absent config does not make preflight refuse (exit $rc)"
else
    bad "2.30f preflight exited '$rc' on an absent config, want 0 or 3"
fi
assert_status_key "2.30f" "$SF" containerd_config_rollback_safe unknown
# READ-ONLY: phase 6's branch here does `mkdir -p /etc/containerd` and writes
# the file. Preflight must do neither.
if vm_try "test -e /etc/containerd/config.toml; echo \$?" | tail -1 | grep -qx 1; then
    ok "2.30f preflight did not generate a config"
else
    bad "2.30f preflight generated /etc/containerd/config.toml -- it must not write one"
fi
vm "mv -f /etc/containerd/config.toml.pf30f /etc/containerd/config.toml" >/dev/null 2>&1


#############################################
head_ "2.31-2.38  Agent mode: gates, flags and --non-interactive"
#############################################
# Slice 4. Every case here asserts STATE, not the exit code. A gate that failed
# open would also exit non-zero -- just later, and after the node was drained
# and upgraded -- so a status check alone proves nothing about a guard whose
# job is to refuse.
#
# The guest becomes a single-node Swarm MANAGER, which is what arms the drain,
# task-count and reactivation gates. It cannot become a worker: demoting the
# only manager is refused. The worker gate and the worker predictor state stay
# untested here, and this suite says so rather than pretending otherwise.
./reset-baseline.sh >/dev/null 2>&1
restore_pkgs
vm "rm -f $SF" >/dev/null 2>&1

# Armed BEFORE the Swarm exists. An interrupted suite must not leave the guest
# in a Swarm for the next one, and it must still restore the 2.30 config. INT
# and TERM route through EXIT so a signal cannot run the handler and then let
# bash carry on into the next case.
trap 'restore_pf_config; swarm_leave' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if swarm_init; then
    ok "2.31 fixture: guest is a single-node Swarm manager"
else
    bad "2.31 fixture: could not create the Swarm -- every gate case below is vacuous"
fi
assert_node_availability "2.31 fixture" active

# --- 2.31: an unanswered gate fails closed, node untouched ---
capture_strict_state a31
rc=$(vm_try "cd /opt/docker-offline && ./upgrade-docker.sh --non-interactive --status-file=$SF </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "1" ]; then
    ok "2.31 unanswered gate exits 1"
else
    bad "2.31 unanswered gate exited '$rc', want 1"
fi
assert_status_key "2.31" "$SF" result refused
assert_status_key "2.31" "$SF" refusal_reason gate-unanswered:drain-self
assert_status_key "2.31" "$SF" next_action supply-flag
assert_status_key "2.31" "$SF" pkg_state untouched
assert_status_key "2.31" "$SF" mode non-interactive
assert_status_complete "2.31" "$SF"
gu=$(status_key "$SF" gates_unanswered)
case ",$gu," in
    *,drain-self,*) ok "2.31 gates_unanswered names drain-self ($gu)" ;;
    *) bad "2.31 gates_unanswered is '$gu' and does not name drain-self" ;;
esac
# The refusal must name the flag, or an agent cannot act on it.
out=$(vm_try "cd /opt/docker-offline && ./upgrade-docker.sh --non-interactive --status-file=$SF </dev/null 2>&1")
if printf '%s' "$out" | grep -q -- "--drain-self or --no-drain-self"; then
    ok "2.31 the refusal names both flags"
else
    bad "2.31 the refusal does not name the flags"
fi
# STATE: this is the assertion that matters. A fall-through that drained and
# upgraded the node would also exit non-zero, eventually.
assert_untouched_strict "2.31" baseline a31
assert_node_availability "2.31" active

# --- 2.32: --non-interactive never reads stdin ---
# Identical to 2.31 but with a live `yes y` stream attached. A gate() that fell
# through to prompt_yes_no gets answered by it and the upgrade proceeds, so
# ONLY the state assertions catch that. Mutant M3 proves they do.
vm "rm -f $SF" >/dev/null 2>&1
capture_strict_state a32
rc=$(vm_try "cd /opt/docker-offline && yes y | ./upgrade-docker.sh --non-interactive --status-file=$SF >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "1" ]; then
    ok "2.32 refuses even with a yes stream on stdin (exit 1)"
else
    bad "2.32 exited '$rc' with a yes stream attached, want 1"
fi
assert_status_key "2.32" "$SF" result refused
assert_status_key "2.32" "$SF" refusal_reason gate-unanswered:drain-self
assert_status_key "2.32" "$SF" pkg_state untouched
assert_status_key "2.32" "$SF" drain_performed false
# gate() must not have reached prompt_yes_no at all. If it had, the EOF guard
# would never fire and the stream would have answered -- so the tell is the
# node, not the log.
assert_untouched_strict "2.32" baseline a32
assert_node_availability "2.32" active

# --- 2.33: --non-interactive without --status-file is refused at parse time ---
vm "rm -f $SF" >/dev/null 2>&1
capture_strict_state a33
rc=$(vm_try "cd /opt/docker-offline && ./upgrade-docker.sh --non-interactive --drain-self </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "1" ]; then
    ok "2.33 --non-interactive without --status-file exits 1"
else
    bad "2.33 exited '$rc' without a status file, want 1"
fi
out=$(vm_try "cd /opt/docker-offline && ./upgrade-docker.sh --non-interactive --drain-self </dev/null 2>&1")
if printf '%s' "$out" | grep -q -- "--non-interactive requires --status-file"; then
    ok "2.33 the refusal names the missing flag"
else
    bad "2.33 the refusal does not name --status-file"
fi
if vm_try "test -e $SF; echo \$?" | tail -1 | grep -qx 1; then
    ok "2.33 nothing was written to the previous status path"
else
    bad "2.33 a status file appeared for a parse-time refusal"
fi
assert_untouched_strict "2.33" baseline a33
assert_node_availability "2.33" active

# --- 2.37: a conditional gate is REPORTED, not refused ---
# Before the upgrade, while the node is still a baseline active manager.
# --status-file is mandatory here: without it the run is refused at parse time
# and this tests nothing.
vm "rm -f $SF" >/dev/null 2>&1
capture_strict_state a37
rc=$(vm_try "cd /opt/docker-offline && ./upgrade-docker.sh --preflight --non-interactive --status-file=$SF --drain-self --reactivate </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "0" ]; then
    ok "2.37 preflight does not refuse over an unanswered CONDITIONAL gate"
else
    bad "2.37 preflight exited '$rc' with proceed-with-tasks unanswered, want 0"
fi
assert_status_key "2.37" "$SF" result ready
assert_status_key "2.37" "$SF" refusal_reason ""
assert_status_key "2.37" "$SF" next_action proceed
assert_status_key "2.37" "$SF" gates_conditional proceed-with-tasks
assert_status_key "2.37" "$SF" gates_unanswered proceed-with-tasks
assert_status_key "2.37" "$SF" gates_answered "drain-self:y,reactivate:y"
assert_untouched_strict "2.37" baseline a37

# --- 2.36: the gate predictor, one state at a time ---
# Bare --preflight, deliberately WITHOUT --non-interactive: both lists are then
# informational and the run cannot refuse, so each assertion is about the
# prediction alone.
predict_case() {
    local label="$1" want_req="$2" want_cond="$3"; shift 3
    vm "rm -f $SF" >/dev/null 2>&1
    vm_try "cd /opt/docker-offline && ./upgrade-docker.sh --preflight --status-file=$SF $* </dev/null >/dev/null 2>&1" >/dev/null
    assert_status_key "$label" "$SF" gates_required "$want_req"
    assert_status_key "$label" "$SF" gates_conditional "$want_cond"
}

predict_case "2.36a active manager, --drain-self"    "drain-self,reactivate" "proceed-with-tasks" --drain-self
predict_case "2.36b active manager, --no-drain-self" "drain-self"            ""                   --no-drain-self
predict_case "2.36c active manager, neither"         "drain-self"            "proceed-with-tasks,reactivate"

set_node_availability drain || true
assert_node_availability "2.36d setup" drain
predict_case "2.36d already-drained manager"         "reactivate"            ""
# The combination that exposed a real predictor bug: phase 1 never CONSULTS
# drain-self on an already-drained manager, so --no-drain-self must not
# suppress the reactivation phase 10 will certainly reach.
predict_case "2.36d2 already-drained manager, --no-drain-self" \
                                                     "reactivate"            "" --no-drain-self

set_node_availability pause || true
assert_node_availability "2.36e setup" pause
predict_case "2.36e paused manager"                  ""                      ""

set_node_availability active || true
assert_node_availability "2.36f setup" active

# The worker state cannot be staged here. A single-node Swarm is always its own
# manager and demoting the last manager is refused, so there is no way to make
# ControlAvailable false. Say so rather than leave the gap invisible.
skip "2.36g worker predictor state -- needs a second node (Tier 3)"

swarm_leave
predict_case "2.36h non-Swarm host"                  ""                      ""
if swarm_init; then
    ok "2.36 fixture: Swarm re-created for the remaining cases"
else
    bad "2.36 fixture: could not re-create the Swarm"
fi

# --- 2.34: a full non-interactive upgrade, end to end ---
vm "rm -f $SF" >/dev/null 2>&1
conf_before=$(vm_try "sha256sum /etc/containerd/config.toml | cut -d' ' -f1" | tail -1)
out=$(vm_try "cd /opt/docker-offline && ./upgrade-docker.sh --non-interactive --status-file=$SF --drain-self --proceed-with-tasks --reactivate </dev/null 2>&1")
if printf '%s' "$out" | grep -q "UPGRADE COMPLETE"; then
    ok "2.34 full non-interactive upgrade completed"
else
    bad "2.34 full non-interactive upgrade did NOT complete"
    printf '%s\n' "$out" | tail -25 | sed 's/^/       /'
fi
assert_status_complete "2.34" "$SF"
assert_status_key "2.34" "$SF" result completed
assert_status_key "2.34" "$SF" exit_code 0
assert_status_key "2.34" "$SF" mode non-interactive
assert_status_key "2.34" "$SF" pkg_state installed
assert_status_key "2.34" "$SF" swarm_active true
assert_status_key "2.34" "$SF" swarm_role manager
# Both availability transitions, which is what an orchestrator has to confirm.
assert_status_key "2.34" "$SF" node_availability_before active
assert_status_key "2.34" "$SF" node_availability_after active
assert_status_key "2.34" "$SF" drain_performed true
# The record says a FLAG was trusted, not that a check was performed.
assert_status_key "2.34" "$SF" drain_attested_by flag
assert_status_key "2.34" "$SF" tasks_remaining 0
# --proceed-with-tasks was on the command line, and the run never needed it:
# the drain left zero tasks, so that gate is not reached. gates_seen records
# what was REACHED, which is the point of having it beside gates_answered.
# A pre-answer for a gate the run does not reach must be harmless.
gs=$(status_key "$SF" gates_seen)
if [ "$gs" = "drain-self,reactivate" ]; then
    ok "2.34 gates_seen records only the gates actually reached ($gs)"
else
    bad "2.34 gates_seen is '$gs', want 'drain-self,reactivate'"
fi
assert_status_key "2.34" "$SF" gates_answered "drain-self:y,proceed-with-tasks:y,reactivate:y"
assert_pkg_profile "2.34" target
assert_vm_eq "2.34 containerd config unchanged by the upgrade" \
    "sha256sum /etc/containerd/config.toml | cut -d' ' -f1" "$conf_before"
assert_vm_eq "2.34 canary data intact" \
    "docker start survivor >/dev/null 2>&1; docker exec survivor cat /data/canary.txt" \
    "VOLUME-CANARY-DATA"
assert_vm_eq "2.34 docker active after the run" "systemctl is-active docker" "active"
assert_vm_eq "2.34 containerd active after the run" "systemctl is-active containerd" "active"
# The node really is back in service, not merely reported as such.
assert_node_availability "2.34" active

# --- 2.35: non-interactive already-at-target exits 3 ---
# Package versions cannot detect this on their own: a forced same-version
# re-run ends at the same versions. Assert that no new backup directory
# appeared and that phase 4 never ran.
vm "rm -f $SF" >/dev/null 2>&1
capture_strict_state a35
p4_before=$(vm_try "grep -c '=== Phase 4: Stop Services ===' /var/log/docker-upgrade.log 2>/dev/null || echo 0" | tail -1)
rc=$(vm_try "cd /opt/docker-offline && ./upgrade-docker.sh --non-interactive --status-file=$SF </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "3" ]; then
    ok "2.35 already-at-target under --non-interactive exits 3"
else
    bad "2.35 exited '$rc' on an at-target node, want 3"
fi
assert_status_key "2.35" "$SF" result nothing-to-do
assert_status_key "2.35" "$SF" next_action none
assert_status_key "2.35" "$SF" node_class at-target
assert_status_key "2.35" "$SF" refusal_reason ""
assert_status_key "2.35" "$SF" pkg_state untouched
gr=$(status_key "$SF" gates_required)
case ",$gr," in
    *,rerun-at-target,*) ok "2.35 gates_required names rerun-at-target ($gr)" ;;
    *) bad "2.35 gates_required is '$gr' and does not name rerun-at-target" ;;
esac
p4_after=$(vm_try "grep -c '=== Phase 4: Stop Services ===' /var/log/docker-upgrade.log 2>/dev/null || echo 0" | tail -1)
if [ "$p4_before" = "$p4_after" ]; then
    ok "2.35 phase 4 never ran (markers $p4_after)"
else
    bad "2.35 phase 4 marker count changed ($p4_before -> $p4_after) -- the run did work"
fi
assert_untouched_strict "2.35" target a35
assert_node_availability "2.35" active

# --- 2.36i: an at-target node reaches NO Swarm gate unless it re-runs ---
# The default answer to the re-run offer is no, and that branch exits before
# phase 1. Listing the drain as "certainly reached" for such a node would be
# false, and would make an agent supply a flag the run never uses.
#
# The node is at target here, straight after 2.35.
predict_case "2.36i at-target, no rerun flag"   "rerun-at-target"                    ""
predict_case "2.36j at-target, --rerun-at-target" \
    "rerun-at-target,drain-self" "proceed-with-tasks,reactivate" --rerun-at-target

# --- 2.33a: contradictory flags are refused, not resolved by order ---
# Each flag states one fact. Letting the last one win is how a wrapper that
# appends a default silently overrides a deliberate answer.
vm "rm -f $SF" >/dev/null 2>&1
capture_strict_state a33a
rc=$(vm_try "cd /opt/docker-offline && ./upgrade-docker.sh --drain-self --no-drain-self --status-file=$SF </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "1" ]; then
    ok "2.33a --drain-self --no-drain-self exits 1"
else
    bad "2.33a contradictory flags exited '$rc', want 1"
fi
out=$(vm_try "cd /opt/docker-offline && ./upgrade-docker.sh --drain-self --no-drain-self --status-file=$SF </dev/null 2>&1")
if printf '%s' "$out" | grep -q "were both given"; then
    ok "2.33a the refusal names the contradiction"
else
    bad "2.33a the refusal does not explain the contradiction"
fi
assert_untouched_strict "2.33a" target a33a

# --- the cleanup script's own gates ---
swarm_leave
./reset-baseline.sh >/dev/null 2>&1
restore_pkgs

# --- 2.38: --confirm-delete alone is refused, in every mode ---
# The inventory is enumerated only AFTER the services stop, so a pre-declared
# yes would authorise deleting a list nothing had seen. Assert TEMPORALLY that
# the services were never stopped: finding them active afterwards would also
# hold after a stop, a delete and a restart.
vm "rm -f $SF" >/dev/null 2>&1
vm "mkdir -p /var/run/docker/netns && touch /var/run/docker/netns/gate-canary" >/dev/null 2>&1
p2_before=$(vm_try "grep -c '=== Phase 2: Stop Services ===' /var/log/docker-network-cleanup.log 2>/dev/null || echo 0" | tail -1)
rc=$(vm_try "cd /opt/docker-offline && ./clean-swarm-networks.sh --non-interactive --status-file=$SF --confirm-delete </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "1" ]; then
    ok "2.38 --confirm-delete without an inventory hash exits 1"
else
    bad "2.38 --confirm-delete exited '$rc', want 1"
fi
assert_status_key "2.38" "$SF" result refused
assert_status_key "2.38" "$SF" refusal_reason inventory-sha-required
assert_status_key "2.38" "$SF" next_action rerun-dry-run
assert_status_key "2.38" "$SF" deleted false
assert_status_complete "2.38" "$SF"
p2_after=$(vm_try "grep -c '=== Phase 2: Stop Services ===' /var/log/docker-network-cleanup.log 2>/dev/null || echo 0" | tail -1)
if [ "$p2_before" = "$p2_after" ]; then
    ok "2.38 services were never stopped (phase 2 markers $p2_after)"
else
    bad "2.38 phase 2 marker count changed ($p2_before -> $p2_after) -- it stopped services"
fi
if vm_try "test -e /var/run/docker/netns/gate-canary; echo \$?" | tail -1 | grep -qx 0; then
    ok "2.38 the seeded netns object survived the refusal"
else
    bad "2.38 the seeded netns object was DELETED"
fi

# --- 2.38a: an unanswered cleanup gate refuses before anything stops ---
vm "rm -f $SF" >/dev/null 2>&1
rc=$(vm_try "cd /opt/docker-offline && yes y | ./clean-swarm-networks.sh --non-interactive --status-file=$SF >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "1" ]; then
    ok "2.38a unanswered cleanup gate exits 1 even with a yes stream"
else
    bad "2.38a exited '$rc' with a yes stream attached, want 1"
fi
assert_status_key "2.38a" "$SF" result refused
assert_status_key "2.38a" "$SF" refusal_reason gate-unanswered:allow-non-swarm
assert_status_key "2.38a" "$SF" next_action supply-flag
assert_status_key "2.38a" "$SF" deleted false
p2_after=$(vm_try "grep -c '=== Phase 2: Stop Services ===' /var/log/docker-network-cleanup.log 2>/dev/null || echo 0" | tail -1)
if [ "$p2_before" = "$p2_after" ]; then
    ok "2.38a services were never stopped (phase 2 markers $p2_after)"
else
    bad "2.38a phase 2 marker count changed -- a refused run stopped services"
fi
if vm_try "test -e /var/run/docker/netns/gate-canary; echo \$?" | tail -1 | grep -qx 0; then
    ok "2.38a the seeded netns object survived the refusal"
else
    bad "2.38a the seeded netns object was DELETED"
fi

# --- 2.38b: every cleanup gate answered runs unattended, end to end ---
# The first three gates by flag, the fourth declined by flag. It stops, it
# enumerates, it restarts, and it deletes nothing.
vm "rm -f $SF" >/dev/null 2>&1
rc=$(vm_try "cd /opt/docker-offline && ./clean-swarm-networks.sh --non-interactive --status-file=$SF --allow-non-swarm --assume-drained --confirm-stop --no-confirm-delete </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "0" ]; then
    ok "2.38b a fully answered cleanup runs without a terminal (exit 0)"
else
    bad "2.38b fully answered cleanup exited '$rc', want 0"
    vm_try "cd /opt/docker-offline && ./clean-swarm-networks.sh --non-interactive --status-file=/tmp/x.kv --allow-non-swarm --assume-drained --confirm-stop --no-confirm-delete </dev/null 2>&1" | tail -15 | sed 's/^/       /'
fi
assert_status_key "2.38b" "$SF" deleted false
assert_status_key "2.38b" "$SF" refusal_reason delete-declined
assert_status_key "2.38b" "$SF" gates_answered "allow-non-swarm:y,assume-drained:y,confirm-stop:y,confirm-delete:n"
assert_status_key "2.38b" "$SF" services_stopped false
assert_status_complete "2.38b" "$SF"
gs=$(status_key "$SF" gates_seen)
if [ "$gs" = "allow-non-swarm,assume-drained,confirm-stop,confirm-delete" ]; then
    ok "2.38b every gate was reached and answered by flag ($gs)"
else
    bad "2.38b gates_seen is '$gs', want all four"
fi
# It DID stop and restart: this is the case that proves the flags drive the
# real path, not just the refusals.
p2_after=$(vm_try "grep -c '=== Phase 2: Stop Services ===' /var/log/docker-network-cleanup.log 2>/dev/null || echo 0" | tail -1)
if [ "$p2_after" -gt "$p2_before" ]; then
    ok "2.38b it really did stop services and bring them back ($p2_before -> $p2_after)"
else
    bad "2.38b phase 2 never ran, so the declined-delete path was not exercised"
fi
assert_vm_eq "2.38b docker active again" "systemctl is-active docker" "active"
assert_vm_eq "2.38b containerd active again" "systemctl is-active containerd" "active"
if vm_try "test -e /var/run/docker/netns/gate-canary; echo \$?" | tail -1 | grep -qx 0; then
    ok "2.38b the declined deletion left the seeded object in place"
else
    bad "2.38b the seeded object was deleted despite --no-confirm-delete"
fi
vm "rm -f /var/run/docker/netns/gate-canary" >/dev/null 2>&1

# Verify the teardown before disarming the trap. swarm_leave swallows every
# failure by design, so a silent failure here would hand the next suite a node
# that is still a Swarm manager.
swarm_leave
sw=$(vm_try "docker info --format '{{.Swarm.LocalNodeState}}'" | tr -d '\r' | tail -1)
if [ "$sw" = "inactive" ]; then
    ok "2.38 teardown: the guest left the Swarm"
    # Disarmed ONLY on success. `bad` increments a counter and returns, and
    # swarm_leave swallows every failure, so clearing the trap unconditionally
    # would hand the next suite a node that is still a Swarm manager.
    trap - EXIT INT TERM
else
    bad "2.38 teardown: guest is still '$sw' -- leaving the EXIT trap armed to retry"
fi

#############################################
head_ "2.39-2.42  Agent mode: the cleanup dry run and the inventory hash"
#############################################
# Slice 5. The cleanup is the one script an agent cannot drive in a single
# invocation: the inventory is enumerated only AFTER the services stop, so
# nobody can be told it in advance. The dry run publishes a hash of what it
# enumerated; the real run hashes ITS OWN enumeration and compares.
#
# THE FIXTURE IS NOT OPTIONAL. Without a Swarm the script refuses at the
# allow-non-swarm gate before stopping anything, and with an empty inventory it
# takes the nothing-to-clean exit. Either way every case below would pass
# without executing the code under test, so the fixture is asserted first.
./reset-baseline.sh >/dev/null 2>&1
restore_pkgs
vm "rm -f $SF" >/dev/null 2>&1
CLEANLOG=/var/log/docker-network-cleanup.log

# Armed before the fixture exists. An interrupted suite must not leave the
# guest in a Swarm carrying a test overlay network.
trap 'swarm_net_teardown; swarm_leave' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if swarm_net_fixture; then
    ok "2.39 fixture: single-node Swarm with an attached overlay network"
else
    bad "2.39 fixture: could not build it -- every case below is vacuous"
fi
docker_settle
capture_inventory inv0
inv_ns=$(vm_try "find /var/run/docker/netns -mindepth 1 -maxdepth 1 2>/dev/null | wc -l" | tail -1)
if [ "${inv_ns:-0}" -gt 0 ] 2>/dev/null; then
    ok "2.39 fixture: $inv_ns network namespace(s) to enumerate"
else
    bad "2.39 fixture: no network namespaces -- an empty inventory proves nothing"
fi
if [ "${INV_KVINO[inv0]}" != "absent" ]; then
    ok "2.39 fixture: libnetwork key-value store present (inode ${INV_KVINO[inv0]})"
else
    bad "2.39 fixture: no key-value store -- an empty inventory proves nothing"
fi
if [ "${INV_GW[inv0]}" = "present" ]; then
    ok "2.39 fixture: docker_gwbridge present"
else
    bad "2.39 fixture: no docker_gwbridge -- an empty inventory proves nothing"
fi
if [ -n "${INV_VXLAN[inv0]}" ]; then
    ok "2.39 fixture: VXLAN interface(s) in the host namespace (${INV_VXLAN[inv0]})"
else
    # Not a failure: an attachable overlay puts its VXLAN inside the network
    # namespace, so a host-namespace list is often empty. Said out loud rather
    # than left invisible, because it means phase 4's VXLAN deletion loop is
    # not exercised by these cases.
    skip "2.39 fixture: no VXLAN interface in the host namespace -- phase 4's VXLAN loop is not exercised here"
fi

# --- 2.39: --dry-run deletes nothing ---
# It really does stop and restart: that is the point. What it must not do is
# reach phase 4, so the proof is the phase-4 marker count plus the key-value
# store's inode, not "the services are up afterwards".
p4_before=$(log_phase_count "$CLEANLOG" '=== Phase 4: Delete Network State ===')
p2_dry_before=$(log_phase_count "$CLEANLOG" '=== Phase 2: Stop Services ===')
rc=$(vm_try "cd /opt/docker-offline && ./clean-swarm-networks.sh --non-interactive --dry-run --status-file=$SF --assume-drained --confirm-stop </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "0" ]; then
    ok "2.39 --dry-run exits 0"
else
    bad "2.39 --dry-run exited '$rc', want 0"
    vm_try "cd /opt/docker-offline && ./clean-swarm-networks.sh --non-interactive --dry-run --status-file=/tmp/x.kv --assume-drained --confirm-stop </dev/null 2>&1" | tail -15 | sed 's/^/       /'
fi
docker_settle
assert_status_complete "2.39" "$SF"
assert_status_key "2.39" "$SF" mode dry-run
assert_status_key "2.39" "$SF" result completed
assert_status_key "2.39" "$SF" deleted false
assert_status_key "2.39" "$SF" next_action proceed
assert_status_key "2.39" "$SF" services_stopped false
assert_status_key "2.39" "$SF" inventory_sha_expected ""
DRY_SHA=$(status_key "$SF" inventory_sha)
if printf '%s' "$DRY_SHA" | grep -qE '^[0-9a-f]{64}$'; then
    ok "2.39 inventory_sha is 64 hex characters (${DRY_SHA:0:12}...)"
else
    bad "2.39 inventory_sha is '$DRY_SHA', not a sha256 digest"
fi
DRY_TOTAL=$(status_key "$SF" inventory_total)
if [ "${DRY_TOTAL:-0}" -gt 0 ] 2>/dev/null; then
    ok "2.39 the dry run enumerated a non-empty inventory ($DRY_TOTAL items)"
else
    bad "2.39 inventory_total is '$DRY_TOTAL' -- the nothing-to-clean exit proves nothing"
fi
# It stopped, and it did not delete.
p2_dry_after=$(log_phase_count "$CLEANLOG" '=== Phase 2: Stop Services ===')
if [ "$p2_dry_after" -gt "$p2_dry_before" ]; then
    ok "2.39 the dry run really did stop and restart services ($p2_dry_before -> $p2_dry_after)"
else
    bad "2.39 phase 2 never ran, so the enumeration was not the post-stop one"
fi
assert_phase_count_unchanged "2.39" "$CLEANLOG" '=== Phase 4: Delete Network State ===' "$p4_before"
assert_inventory_intact "2.39" inv0

# --- 2.40: a wrong hash refuses, node intact ---
vm "rm -f $SF" >/dev/null 2>&1
capture_inventory inv1
ZEROSHA=$(printf '0%.0s' $(seq 1 64))
rc=$(vm_try "cd /opt/docker-offline && ./clean-swarm-networks.sh --non-interactive --status-file=$SF --assume-drained --confirm-stop --confirm-delete --expect-inventory-sha=$ZEROSHA </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "1" ]; then
    ok "2.40 a mismatched inventory hash exits 1"
else
    bad "2.40 mismatched hash exited '$rc', want 1"
fi
docker_settle
assert_status_key "2.40" "$SF" result refused
assert_status_key "2.40" "$SF" refusal_reason inventory-changed
assert_status_key "2.40" "$SF" next_action rerun-dry-run
assert_status_key "2.40" "$SF" deleted false
assert_status_key "2.40" "$SF" inventory_sha_expected "$ZEROSHA"
assert_status_complete "2.40" "$SF"
# Both hashes in the detail, or an operator cannot tell what moved.
rd=$(status_key "$SF" refusal_detail)
if printf '%s' "$rd" | grep -q "$ZEROSHA" && printf '%s' "$rd" | grep -q "$DRY_SHA"; then
    ok "2.40 refusal_detail carries both hashes"
else
    bad "2.40 refusal_detail is '$rd' and does not carry both hashes"
fi
# It DID stop -- the comparison happens after the post-stop enumeration -- and
# it must have restarted before refusing.
assert_phase_count_unchanged "2.40" "$CLEANLOG" '=== Phase 4: Delete Network State ===' "$p4_before"
assert_inventory_intact "2.40" inv1

# --- 2.41: --confirm-delete with no hash refuses, in BOTH modes ---
# Services are never stopped here, so this is asserted temporally: finding them
# active afterwards would also hold after a stop, a delete and a restart.
vm "rm -f $SF" >/dev/null 2>&1
capture_inventory inv2
p2_before=$(log_phase_count "$CLEANLOG" '=== Phase 2: Stop Services ===')
rc=$(vm_try "cd /opt/docker-offline && ./clean-swarm-networks.sh --non-interactive --status-file=$SF --assume-drained --confirm-stop --confirm-delete </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "1" ]; then
    ok "2.41 --confirm-delete with no hash exits 1 under --non-interactive"
else
    bad "2.41 exited '$rc' with no hash, want 1"
fi
assert_status_key "2.41" "$SF" result refused
assert_status_key "2.41" "$SF" refusal_reason inventory-sha-required
assert_status_key "2.41" "$SF" next_action rerun-dry-run
assert_status_key "2.41" "$SF" deleted false
# The interactive form, on a terminal-shaped stdin. A pre-declared answer wins
# in both modes, so this is the case that proves the hash is required in BOTH.
rc=$(vm_try "cd /opt/docker-offline && yes y | ./clean-swarm-networks.sh --confirm-delete >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "1" ]; then
    ok "2.41 --confirm-delete with no hash exits 1 interactively too, with a yes stream"
else
    bad "2.41 interactive form exited '$rc' with a yes stream, want 1"
fi
assert_phase_count_unchanged "2.41" "$CLEANLOG" '=== Phase 2: Stop Services ===' "$p2_before"
# `exact` because no service was stopped in this case: nothing could have
# recreated a namespace in between, so the set itself must be identical.
assert_inventory_intact "2.41" inv2 exact

# --- 2.41a: a malformed hash is a usage error ---
vm "rm -f $SF" >/dev/null 2>&1
capture_inventory inv3
p2_before=$(log_phase_count "$CLEANLOG" '=== Phase 2: Stop Services ===')
rc=$(vm_try "cd /opt/docker-offline && ./clean-swarm-networks.sh --non-interactive --status-file=$SF --assume-drained --confirm-stop --confirm-delete --expect-inventory-sha=nothex </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "1" ]; then
    ok "2.41a a malformed --expect-inventory-sha exits 1"
else
    bad "2.41a malformed hash exited '$rc', want 1"
fi
out=$(vm_try "cd /opt/docker-offline && ./clean-swarm-networks.sh --non-interactive --status-file=$SF --assume-drained --confirm-stop --confirm-delete --expect-inventory-sha=nothex </dev/null 2>&1")
if printf '%s' "$out" | grep -q "64 lowercase hex characters"; then
    ok "2.41a the refusal says the value is malformed, not that the inventory changed"
else
    bad "2.41a the refusal does not identify the value as malformed"
    printf '%s\n' "$out" | tail -6 | sed 's/^/       /'
fi
# A usage error is rejected at parse time, before the traps are armed, so NO
# record is written -- the same contract every other usage error follows and
# the reason the runbook tells a caller to compare run_id.
if vm_try "test -e $SF; echo \$?" | tail -1 | grep -qx 1; then
    ok "2.41a a parse-time usage error wrote no status file"
else
    bad "2.41a a status file appeared for a usage error"
fi
assert_phase_count_unchanged "2.41a" "$CLEANLOG" '=== Phase 2: Stop Services ===' "$p2_before"
assert_inventory_intact "2.41a" inv3 exact

# --- 2.41b: --dry-run beside a delete answer is a usage error ---
vm "rm -f $SF" >/dev/null 2>&1
capture_inventory inv4
p2_before=$(log_phase_count "$CLEANLOG" '=== Phase 2: Stop Services ===')
rc=$(vm_try "cd /opt/docker-offline && ./clean-swarm-networks.sh --non-interactive --status-file=$SF --assume-drained --confirm-stop --dry-run --confirm-delete </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "1" ]; then
    ok "2.41b --dry-run --confirm-delete exits 1"
else
    bad "2.41b --dry-run --confirm-delete exited '$rc', want 1"
fi
out=$(vm_try "cd /opt/docker-offline && ./clean-swarm-networks.sh --non-interactive --status-file=$SF --assume-drained --confirm-stop --dry-run --confirm-delete </dev/null 2>&1")
if printf '%s' "$out" | grep -q "cannot be combined with"; then
    ok "2.41b the refusal names the contradiction"
else
    bad "2.41b the refusal does not name the contradiction"
    printf '%s\n' "$out" | tail -6 | sed 's/^/       /'
fi
# The same combination with --expect-inventory-sha instead of the gate answer.
rc=$(vm_try "cd /opt/docker-offline && ./clean-swarm-networks.sh --non-interactive --status-file=$SF --assume-drained --confirm-stop --dry-run --expect-inventory-sha=$DRY_SHA </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "1" ]; then
    ok "2.41b --dry-run --expect-inventory-sha exits 1 as well"
else
    bad "2.41b --dry-run --expect-inventory-sha exited '$rc', want 1"
fi
if vm_try "test -e $SF; echo \$?" | tail -1 | grep -qx 1; then
    ok "2.41b a parse-time usage error wrote no status file"
else
    bad "2.41b a status file appeared for a usage error"
fi
assert_phase_count_unchanged "2.41b" "$CLEANLOG" '=== Phase 2: Stop Services ===' "$p2_before"
assert_inventory_intact "2.41b" inv4 exact

# --- 2.42: a matching hash proceeds, and deletes exactly what was listed ---
# Two passes, back to back, exactly as docs/AGENT-RUNBOOK.md tells an agent to
# run them.
vm "rm -f $SF" >/dev/null 2>&1
vm_try "cd /opt/docker-offline && ./clean-swarm-networks.sh --non-interactive --dry-run --status-file=$SF --assume-drained --confirm-stop </dev/null >/dev/null 2>&1" >/dev/null
docker_settle
PASS1_SHA=$(status_key "$SF" inventory_sha)
PASS1_TOTAL=$(status_key "$SF" inventory_total)
if printf '%s' "$PASS1_SHA" | grep -qE '^[0-9a-f]{64}$'; then
    ok "2.42 pass one published a hash for $PASS1_TOTAL item(s)"
else
    bad "2.42 pass one published no usable hash ('$PASS1_SHA')"
fi
kv_before=$(vm_try "stat -c %i $KV_DB_PATH 2>/dev/null || echo absent" | tail -1)
vm "rm -f $SF" >/dev/null 2>&1
# The cleanup log is append-only and every earlier case in this suite has
# written to it. Record its length so the phase-4 assertions below read THIS
# run's block rather than the first one in the file.
loglines_before=$(vm_try "wc -l < $CLEANLOG 2>/dev/null || echo 0" | tr -d ' \r' | tail -1)
rc=$(vm_try "cd /opt/docker-offline && ./clean-swarm-networks.sh --non-interactive --status-file=$SF --assume-drained --confirm-stop --confirm-delete --expect-inventory-sha=$PASS1_SHA </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "0" ] || [ "$rc" = "2" ]; then
    ok "2.42 pass two ran with the matching hash (exit $rc)"
else
    bad "2.42 pass two exited '$rc', want 0 or 2"
    vm_try "tail -40 $CLEANLOG" | sed 's/^/       /'
fi
docker_settle
assert_status_complete "2.42" "$SF"
assert_status_key "2.42" "$SF" deleted true
assert_status_key "2.42" "$SF" failed_items 0
assert_status_key "2.42" "$SF" inventory_sha "$PASS1_SHA"
assert_status_key "2.42" "$SF" inventory_sha_expected "$PASS1_SHA"
assert_status_key "2.42" "$SF" services_stopped false
# It deleted, and it deleted exactly the listed items. The key-value store is
# the direct observation: dockerd opens an existing one rather than replacing
# it, so a changed inode means the file was genuinely removed. Counting
# namespaces afterwards would measure what dockerd rebuilt on restart, not what
# was deleted, so the removal itself is read from the run's own log.
kv_after=$(vm_try "stat -c %i $KV_DB_PATH 2>/dev/null || echo absent" | tail -1)
if [ "$kv_after" != "$kv_before" ]; then
    ok "2.42 the key-value store was really deleted (inode $kv_before -> $kv_after)"
else
    bad "2.42 the key-value store inode is unchanged ($kv_after) -- nothing was deleted"
fi
p4_after=$(log_phase_count "$CLEANLOG" '=== Phase 4: Delete Network State ===')
if [ "$p4_after" -gt "$p4_before" ]; then
    ok "2.42 phase 4 ran ($p4_before -> $p4_after)"
else
    bad "2.42 phase 4 never ran, so nothing was deleted"
fi
# The tick is multibyte, and `.` in a C locale matches one BYTE, so an awk
# pattern of `^  . ` can count zero removals on a guest with no UTF-8 locale.
# Slice the block and count the literal character instead.
removed=$(vm_try "tail -n +$((loglines_before + 1)) $CLEANLOG | sed -n '/=== Phase 4: Delete Network State ===/,/=== Phase 5: Start Services ===/p' | grep -cF '✓' || echo 0" | tr -d ' \r' | tail -1)
if [ "${removed:-0}" = "$PASS1_TOTAL" ]; then
    ok "2.42 phase 4 removed exactly the $PASS1_TOTAL enumerated item(s)"
else
    bad "2.42 phase 4 reported $removed removals for an inventory of $PASS1_TOTAL"
fi
# "already gone" is also printed with a tick. Within one run that enumerated
# after the stop and deleted straight away, nothing should have vanished on its
# own -- and counting those as removals would let a phase 4 that deleted
# NOTHING report a full tally.
noops=$(vm_try "tail -n +$((loglines_before + 1)) $CLEANLOG | sed -n '/=== Phase 4: Delete Network State ===/,/=== Phase 5: Start Services ===/p' | grep -cF 'already gone' || echo 0" | tr -d ' \r' | tail -1)
if [ "${noops:-0}" = "0" ]; then
    ok "2.42 every removal was a real deletion, not an 'already gone'"
else
    bad "2.42 $noops item(s) were already gone before phase 4 reached them"
fi
assert_vm_eq "2.42 docker active again" "systemctl is-active docker" "active"
assert_vm_eq "2.42 containerd active again" "systemctl is-active containerd" "active"
# Containers, images and volumes are NOT touched by this script.
assert_vm_eq "2.42 canary data intact" \
    "docker start survivor >/dev/null 2>&1; docker exec survivor cat /data/canary.txt" \
    "VOLUME-CANARY-DATA"

swarm_net_teardown
swarm_leave
sw=$(vm_try "docker info --format '{{.Swarm.LocalNodeState}}'" | tr -d '\r' | tail -1)
if [ "$sw" = "inactive" ]; then
    ok "2.42 teardown: the guest left the Swarm"
    trap - EXIT INT TERM
else
    bad "2.42 teardown: guest is still '$sw' -- leaving the EXIT trap armed to retry"
fi

#############################################
head_ "2.43-2.48  Agent mode: rollback preflight and backup selection"
#############################################
# Slice 6. rollback-docker.sh gains --preflight, --config-backup and
# --non-interactive. Phase 0c gains NOTHING: there is no safe way to downgrade
# into a runtime that cannot start, so --config-backup can only turn a refusal
# into `ready` by naming a backup the older containerd can genuinely load.
#
# The node must be AT TARGET for any of this to mean anything: a v4 config is
# what the target containerd generates, and 2.48 has to have something to roll
# back FROM.
./reset-baseline.sh >/dev/null 2>&1
restore_pkgs
vm "rm -f $SF" >/dev/null 2>&1
RBLOG=/var/log/docker-rollback.log
CONF=/etc/containerd/config.toml

out=$(vm_try "cd /opt/docker-offline && ./upgrade-docker.sh --status-file=$SF </dev/null 2>&1")
if printf '%s' "$out" | grep -q "UPGRADE COMPLETE"; then
    ok "2.43 fixture: node upgraded to the target"
else
    bad "2.43 fixture: the upgrade did not complete -- every case below is vacuous"
    printf '%s\n' "$out" | tail -20 | sed 's/^/       /'
fi
# Two config fixtures kept off the node's live path: the v3 the baseline wrote,
# and a v4 the TARGET containerd generates. Both are read back and asserted,
# because a fixture that silently produced the same version twice would make
# 2.44 and 2.45 pass without testing anything.
vm "cp $CONF /root/cv3.toml" >/dev/null 2>&1
vm "containerd config default > /root/cv4.toml" >/dev/null 2>&1
conf_v3=$(vm_try "sed -n 's/^version *= *//p' /root/cv3.toml | head -1" | tr -d '\r' | tail -1)
conf_v4=$(vm_try "sed -n 's/^version *= *//p' /root/cv4.toml | head -1" | tr -d '\r' | tail -1)
if [ "${conf_v3:-0}" -le 3 ] 2>/dev/null && [ "${conf_v4:-0}" -gt 3 ] 2>/dev/null; then
    ok "2.43 fixture: on-disk config is v$conf_v3, the target generates v$conf_v4"
else
    bad "2.43 fixture: config versions are v'$conf_v3' and v'$conf_v4' -- the boundary is not staged"
fi

# --- 2.43: --preflight on a healthy node ---
vm "rm -f $SF" >/dev/null 2>&1
capture_strict_state a43
rc=$(vm_try "cd /opt/docker-offline && ./rollback-docker.sh --preflight --status-file=$SF </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "0" ]; then
    ok "2.43 rollback --preflight on a healthy node exits 0"
else
    bad "2.43 rollback --preflight exited '$rc', want 0"
    vm_try "cd /opt/docker-offline && ./rollback-docker.sh --preflight --status-file=/tmp/x.kv </dev/null 2>&1" | tail -20 | sed 's/^/       /'
fi
assert_status_complete "2.43" "$SF"
assert_status_key "2.43" "$SF" result ready
assert_status_key "2.43" "$SF" mode preflight
assert_status_key "2.43" "$SF" next_action proceed
assert_status_key "2.43" "$SF" config_rollback_safe true
assert_status_key "2.43" "$SF" refusal_reason ""
assert_status_key "2.43" "$SF" pkg_state untouched
assert_status_key "2.43" "$SF" services_stopped false
# STATE: read-only means read-only.
assert_untouched_strict "2.43" target a43

# --- 2.44: --preflight with a v4 config and no usable backup refuses ---
# This is case 2.27 re-expressed as a preflight: the same guard, reached on a
# node nobody has touched, instead of after the services stop.
vm "rm -f $SF" >/dev/null 2>&1
vm "rm -rf /root/docker-backup-*" >/dev/null 2>&1
vm "cp /root/cv4.toml $CONF" >/dev/null 2>&1
capture_strict_state a44
rc=$(vm_try "cd /opt/docker-offline && ./rollback-docker.sh --preflight --status-file=$SF </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "1" ]; then
    ok "2.44 --preflight refuses a v$conf_v4 config with no usable backup (exit 1)"
else
    bad "2.44 exited '$rc' with a v$conf_v4 config and no backup, want 1"
fi
assert_status_key "2.44" "$SF" result refused
assert_status_key "2.44" "$SF" refusal_reason config-version-blocks-rollback
assert_status_key "2.44" "$SF" next_action restore-config
assert_status_key "2.44" "$SF" config_version_effective "$conf_v4"
assert_status_key "2.44" "$SF" config_rollback_safe false
assert_status_key "2.44" "$SF" config_backup_source none
assert_status_key "2.44" "$SF" pkg_state untouched
assert_status_complete "2.44" "$SF"
out=$(vm_try "cd /opt/docker-offline && ./rollback-docker.sh --preflight --status-file=$SF </dev/null 2>&1")
if printf '%s' "$out" | grep -q "CONFIG VERSION BLOCKS THIS ROLLBACK"; then
    ok "2.44 the refusal names the config version"
else
    bad "2.44 the refusal does not name the config version"
    printf '%s\n' "$out" | tail -8 | sed 's/^/       /'
fi
# STATE: the node is untouched, which is the whole point of hoisting the guard.
# A refusal that downgraded and THEN failed to start containerd also exits 1.
assert_untouched_strict "2.44" target a44
assert_vm_eq "2.44 the config file is byte-identical" \
    "sha256sum $CONF | cut -d' ' -f1" "$(vm_try "sha256sum /root/cv4.toml | cut -d' ' -f1" | tail -1)"
p1_before=$(log_phase_count "$RBLOG" '=== Phase 1: Stop Services ===')

# --- 2.45: --config-backup selects an older, loadable backup ---
# The newest backup holds the v4; an older one holds the v3. Naming the older
# turns a refusal into ready -- not by overriding the guard, but by giving it a
# different, genuine fact to judge.
vm "rm -rf /root/docker-backup-*" >/dev/null 2>&1
vm "mkdir -p /root/docker-backup-20250101-000000 /root/docker-backup-20260101-000000" >/dev/null 2>&1
vm "cp /root/cv3.toml /root/docker-backup-20250101-000000/config.toml" >/dev/null 2>&1
vm "cp /root/cv4.toml /root/docker-backup-20260101-000000/config.toml" >/dev/null 2>&1
vm "rm -f $SF" >/dev/null 2>&1
capture_strict_state a45
rc=$(vm_try "cd /opt/docker-offline && ./rollback-docker.sh --preflight --status-file=$SF --config-backup=/root/docker-backup-20250101-000000 </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "0" ]; then
    ok "2.45 --config-backup naming the older, loadable backup exits 0"
else
    bad "2.45 exited '$rc' with a loadable backup named, want 0"
    vm_try "cd /opt/docker-offline && ./rollback-docker.sh --preflight --status-file=/tmp/x.kv --config-backup=/root/docker-backup-20250101-000000 </dev/null 2>&1" | tail -20 | sed 's/^/       /'
fi
assert_status_key "2.45" "$SF" result ready
assert_status_key "2.45" "$SF" config_backup_source flag
assert_status_key "2.45" "$SF" config_backup_selected /root/docker-backup-20250101-000000
assert_status_key "2.45" "$SF" config_rollback_safe true
# What 0c judged is the BACKUP's version, not the v4 sitting on disk. Reporting
# the on-disk version here would tell an agent the opposite of the decision.
assert_status_key "2.45" "$SF" config_version_effective "$conf_v3"
assert_status_key "2.45" "$SF" config_version_on_disk "$conf_v4"
assert_status_complete "2.45" "$SF"
# The same node, the same two backups, with NO flag: the newest is the v4 one,
# so the guard fires. This is the pair that proves the flag did the work.
vm "rm -f /tmp/noflag.kv" >/dev/null 2>&1
rc=$(vm_try "cd /opt/docker-offline && ./rollback-docker.sh --preflight --non-interactive --status-file=/tmp/noflag.kv --config-backup=newest </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "1" ]; then
    ok "2.45 the same node with --config-backup=newest refuses (exit 1)"
else
    bad "2.45 --config-backup=newest exited '$rc' with a v$conf_v4 newest backup, want 1"
fi
assert_status_key "2.45 newest" /tmp/noflag.kv refusal_reason config-version-blocks-rollback
assert_status_key "2.45 newest" /tmp/noflag.kv config_version_effective "$conf_v4"
vm "rm -f /tmp/noflag.kv" >/dev/null 2>&1
assert_untouched_strict "2.45" target a45

# --- 2.46: --config-backup naming a directory that is not there ---
vm "rm -f $SF" >/dev/null 2>&1
capture_strict_state a46
rc=$(vm_try "cd /opt/docker-offline && ./rollback-docker.sh --preflight --status-file=$SF --config-backup=/root/docker-backup-does-not-exist </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "1" ]; then
    ok "2.46 --config-backup naming a missing directory exits 1"
else
    bad "2.46 exited '$rc' for a missing backup directory, want 1"
fi
assert_status_key "2.46" "$SF" result refused
assert_status_key "2.46" "$SF" refusal_reason config-backup-not-found
assert_status_key "2.46" "$SF" next_action supply-flag
assert_status_key "2.46" "$SF" pkg_state untouched
assert_status_complete "2.46" "$SF"
# It must NOT silently fall back to the newest, which here is the unloadable
# v4 one: a fallback would restore a file the caller did not choose.
assert_status_key "2.46" "$SF" config_backup_selected none
# A directory that exists but holds no config.toml is the same refusal.
vm "mkdir -p /root/empty-backup-dir" >/dev/null 2>&1
vm "rm -f /tmp/empty.kv" >/dev/null 2>&1
rc=$(vm_try "cd /opt/docker-offline && ./rollback-docker.sh --preflight --status-file=/tmp/empty.kv --config-backup=/root/empty-backup-dir </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "1" ]; then
    ok "2.46 a backup directory with no config.toml is refused too"
else
    bad "2.46 an empty backup directory exited '$rc', want 1"
fi
assert_status_key "2.46 empty" /tmp/empty.kv refusal_reason config-backup-not-found
vm "rm -rf /root/empty-backup-dir /tmp/empty.kv" >/dev/null 2>&1
assert_untouched_strict "2.46" target a46

# --- 2.47: an ambiguous selection refuses under --non-interactive ---
# NOT a preflight: this is a real rollback that must stop in phase 0b, before
# phase 1 stops anything. The two backups from 2.45 are still in place.
vm "rm -f $SF" >/dev/null 2>&1
capture_strict_state a47
rc=$(vm_try "cd /opt/docker-offline && ./rollback-docker.sh --non-interactive --status-file=$SF </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "1" ]; then
    ok "2.47 two backups and no --config-backup exits 1 under --non-interactive"
else
    bad "2.47 exited '$rc' with an ambiguous selection, want 1"
fi
assert_status_key "2.47" "$SF" result refused
assert_status_key "2.47" "$SF" refusal_reason config-backup-ambiguous
assert_status_key "2.47" "$SF" next_action supply-flag
assert_status_key "2.47" "$SF" pkg_state untouched
assert_status_complete "2.47" "$SF"
cands=$(status_key "$SF" config_backup_candidates)
if printf '%s' "$cands" | grep -q "20250101-000000" && printf '%s' "$cands" | grep -q "20260101-000000"; then
    ok "2.47 config_backup_candidates lists both backups ($cands)"
else
    bad "2.47 config_backup_candidates is '$cands' and does not list both"
fi
# Temporal: it refused BEFORE phase 1. Finding the services active afterwards
# would also hold after a stop, a downgrade and a restart.
assert_phase_count_unchanged "2.47" "$RBLOG" '=== Phase 1: Stop Services ===' "$p1_before"
assert_untouched_strict "2.47" target a47

# --- 2.48: a full non-interactive rollback completes ---
# A loadable config everywhere: one backup holding the v3, and the v3 on disk.
vm "rm -rf /root/docker-backup-*" >/dev/null 2>&1
vm "mkdir -p /root/docker-backup-20260202-000000" >/dev/null 2>&1
vm "cp /root/cv3.toml /root/docker-backup-20260202-000000/config.toml" >/dev/null 2>&1
vm "cp /root/cv3.toml $CONF" >/dev/null 2>&1
vm "rm -f $SF" >/dev/null 2>&1
# --non-interactive without --status-file is refused at parse time here too.
rc=$(vm_try "cd /opt/docker-offline && ./rollback-docker.sh --non-interactive --config-backup=newest </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
if [ "$rc" = "1" ]; then
    ok "2.48 --non-interactive without --status-file is refused at parse time"
else
    bad "2.48 --non-interactive with no status file exited '$rc', want 1"
fi
if vm_try "test -e $SF; echo \$?" | tail -1 | grep -qx 1; then
    ok "2.48 that parse-time refusal wrote no status file"
else
    bad "2.48 a status file appeared for a parse-time refusal"
fi
out=$(vm_try "cd /opt/docker-offline && ./rollback-docker.sh --non-interactive --status-file=$SF --config-backup=newest </dev/null 2>&1")
if printf '%s' "$out" | grep -q "ROLLBACK COMPLETE"; then
    ok "2.48 a fully answered rollback runs without a terminal"
else
    bad "2.48 the non-interactive rollback did NOT complete"
    printf '%s\n' "$out" | tail -25 | sed 's/^/       /'
fi
assert_status_complete "2.48" "$SF"
assert_status_key "2.48" "$SF" result completed
assert_status_key "2.48" "$SF" exit_code 0
assert_status_key "2.48" "$SF" mode non-interactive
assert_status_key "2.48" "$SF" pkg_state installed
assert_status_key "2.48" "$SF" config_backup_source flag
assert_status_key "2.48" "$SF" config_backup_selected /root/docker-backup-20260202-000000
assert_status_key "2.48" "$SF" services_stopped false
assert_status_key "2.48" "$SF" next_action none
# STATE: the packages really went back, and the node really came up.
#
# The THREE packages the rollback bundle carries, not all five:
# rollback-docker.sh downgrades docker-ce, docker-ce-cli and containerd.io and
# deliberately leaves the plugins alone, because buildx and compose version
# independently of docker-ce. Asserting a full baseline profile here would
# demand a downgrade the script does not perform and never claimed to.
assert_vm_eq "2.48 docker-ce back to $BASELINE_DOCKER" \
    "rpm -q docker-ce --queryformat '%{VERSION}'" "$BASELINE_DOCKER"
assert_vm_eq "2.48 docker-ce-cli back to $BASELINE_DOCKER" \
    "rpm -q docker-ce-cli --queryformat '%{VERSION}'" "$BASELINE_DOCKER"
assert_vm_eq "2.48 containerd.io back to $BASELINE_CONTAINERD" \
    "rpm -q containerd.io --queryformat '%{VERSION}'" "$BASELINE_CONTAINERD"
# And the plugins are left where the upgrade put them -- asserted, so a future
# change that started downgrading them would be noticed rather than assumed.
assert_vm_eq "2.48 buildx left at $TARGET_BUILDX" \
    "rpm -q docker-buildx-plugin --queryformat '%{VERSION}'" "$TARGET_BUILDX"
assert_vm_eq "2.48 compose left at $TARGET_COMPOSE" \
    "rpm -q docker-compose-plugin --queryformat '%{VERSION}'" "$TARGET_COMPOSE"
assert_vm_eq "2.48 docker active after the rollback" "systemctl is-active docker" "active"
assert_vm_eq "2.48 containerd active after the rollback" "systemctl is-active containerd" "active"
assert_vm_eq "2.48 canary data intact" \
    "docker start survivor >/dev/null 2>&1; docker exec survivor cat /data/canary.txt" \
    "VOLUME-CANARY-DATA"
# The relocated root survived the downgrade too.
# The same expression config-version-check.sh B7 uses, byte for byte.
# `containerd config dump` quotes the value with SINGLE quotes, so
# stripping only double quotes compares a quoted string against a bare
# path and fails on a perfectly healthy node.
assert_vm_eq "2.48 containerd still uses the relocated root" \
    "containerd config dump 2>/dev/null | awk '/^[[:space:]]*\\[/ { exit } { print }' | sed -n \"s/^[[:space:]]*root[[:space:]]*=[[:space:]]*['\\\"]\\{0,1\\}\\([^'\\\"]*\\)['\\\"]\\{0,1\\}.*/\\1/p\" | head -1" \
    "$RELOCATED_ROOT"

vm "rm -rf /root/docker-backup-* /root/cv3.toml /root/cv4.toml" >/dev/null 2>&1
vm "rm -f $SF" >/dev/null 2>&1
./reset-baseline.sh >/dev/null 2>&1
fi

summary

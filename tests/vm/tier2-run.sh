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
#   tests/vm/tier2-run.sh agent      # agent-mode cases only (2.29a-2.29h)
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

# The precondition, asserted rather than assumed, and it GATES the case. A setup
# that half-applied -- the downgrade done, containerd not restarted -- would
# otherwise let the assertions below run against a node in an unknown state and
# report on a scenario that never existed. This script has no errexit, so the
# gate has to be explicit.
if [ "$SETUP_2_6B" = ok ]; then
    assert_vm_eq "2.6b setup: node is on the wrong build $TARGET_CONTAINERD-$WRONG_CONTAINERD_RELEASE.el9" \
        "rpm -q containerd.io --queryformat '%{VERSION}-%{RELEASE}'" \
        "$TARGET_CONTAINERD-$WRONG_CONTAINERD_RELEASE.el9"
    assert_vm_eq "2.6b setup: docker-ce is still at the target $TARGET_DOCKER" \
        "rpm -q docker-ce --queryformat '%{VERSION}'" "$TARGET_DOCKER"
    assert_vm_eq "2.6b setup: runc is the wrong build's $WRONG_RUNC" \
        "runc --version 2>/dev/null | head -1 | awk '{print \$3}'" "$WRONG_RUNC"
else
    skip "2.6b assertions (setup failed -- see above)"
fi

# The corrective run happens either way: it is what returns the node to the
# target build, and the rollback section below starts from there.
restore_pkgs
out=$(run_upgrade)

if [ "$SETUP_2_6B" != ok ]; then
    skip "2.6b result assertions (setup failed -- the node was not on the wrong build)"
elif printf '%s' "$out" | grep -q "already fully at the target versions"; then
    bad "2.6b the gate called a node on $TARGET_CONTAINERD-$WRONG_CONTAINERD_RELEASE.el9 already-at-target"
    printf '%s\n' "$out" | tail -8 | sed 's/^/       /'
else
    ok "2.6b the already-at-target gate does not accept the wrong containerd build"
fi
if [ "$SETUP_2_6B" = ok ]; then
    if printf '%s' "$out" | grep -q "UPGRADE COMPLETE"; then
        ok "2.6b the run completed rather than exiting with nothing to do"
    else
        bad "2.6b the run did not complete"
        printf '%s\n' "$out" | tail -20 | sed 's/^/       /'
    fi
    if printf '%s' "$out" | grep -q "containerd.io release $TARGET_CONTAINERD_RELEASE.el9"; then
        ok "2.6b phase 9 reported the installed containerd.io release"
    else
        bad "2.6b phase 9 did not report the installed containerd.io release"
    fi

    # STATE, not the exit code -- a node the gate waved through and a node that
    # was upgraded can both exit 0. Only these tell them apart.
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

vm "rm -f $SF" >/dev/null 2>&1
./reset-baseline.sh >/dev/null 2>&1
fi

summary

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

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source ./lib.sh

require_vm
PHASE_ARG="${1:-all}"
PKG_DIR="/opt/docker-offline/rhel9"

# Restore a pristine package directory from the recorded bundle.
restore_pkgs() {
    vm "rm -rf /opt/docker-offline && tar xzf /opt/docker-upgrade-bundle.tar.gz -C /opt/" >/dev/null 2>&1
}

# Run the upgrade with stdin closed. Any prompt is a hard failure by design
# (prompt_yes_no refuses EOF), which makes an unexpected prompt loud rather
# than silently auto-answered.
run_upgrade() { vm_try "cd /opt/docker-offline && ./upgrade-docker.sh </dev/null 2>&1"; }

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
vm "truncate -s -1M $PKG_DIR/containerd.io-$TARGET_CONTAINERD-1.el9.x86_64.rpm" >/dev/null 2>&1
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
vm "rm -f $PKG_DIR/containerd.io-$TARGET_CONTAINERD-1.el9.x86_64.rpm
    cp /opt/docker-offline/rhel8/containerd.io-$TARGET_CONTAINERD-1.el8.x86_64.rpm $PKG_DIR/" >/dev/null 2>&1
out=$(run_upgrade)
if printf '%s' "$out" | grep -qi "is not el9"; then
    ok "2.9 wrong-release (el8 in rhel9 dir) rejected"
else
    bad "2.9 wrong-release NOT rejected"
    printf '%s\n' "$out" | tail -5 | sed 's/^/       /'
fi
assert_untouched "2.9"

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
assert_vm_eq "2.3 containerd.io is $TARGET_CONTAINERD" \
    "rpm -q containerd.io --queryformat '%{VERSION}'" "$TARGET_CONTAINERD"
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
    "docker exec survivor cat /data/canary.txt" "BOUBYAN-CANARY-DATA"
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
    "docker info 2>/dev/null | grep -q mirror.internal.boubyan.local"

# --- 2.14: idempotent re-run ---
head_ "2.14  Idempotent re-run (already at target)"
out=$(run_upgrade)
if printf '%s' "$out" | grep -q "already fully at the target versions"; then
    ok "2.14 re-run detects already-at-target"
else
    bad "2.14 re-run did NOT detect already-at-target"
    printf '%s\n' "$out" | tail -8 | sed 's/^/       /'
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
    "BOUBYAN-CANARY-DATA"
fi

summary

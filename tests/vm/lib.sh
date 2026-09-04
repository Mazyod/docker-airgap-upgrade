#!/bin/bash
# shellcheck disable=SC2034  # version constants are consumed by scripts that source this
# tests/vm/lib.sh
# Shared helpers for the VM test harness. Source this; do not run it.
#
# The harness drives a Rocky Linux 9 guest, which is a RHEL rebuild: `rpm -E
# %rhel` returns the right major, the packages are the same el9 builds, and
# systemd is PID 1. It is NOT RHEL, and it is not bare metal -- see
# tests/vm/README.md for exactly what that does and does not prove.
#
# TWO BACKENDS provide that guest:
#
#   orb     an OrbStack Linux machine on macOS (the original)
#   docker  a privileged Rocky 9 systemd container on a Linux host
#
# Everything above the backend is identical, because the backend contract is
# small. The CORE is six operations:
#
#   need_backend   the backend's tooling is present and usable, or exit 1
#   vm_exists      does a guest named $VM_NAME exist (running or not)
#   vm             run a command in the guest as root; status is preserved
#   vm_try         same, but never fails the caller
#   vm_create      create and start the guest
#   vm_delete      destroy the guest and everything it allocated
#
# Two further operations exist for the harness's own lifecycle code and are NOT
# part of that core: vm_wake (make an existing guest usable) and vm_restart
# (used only by preflight-host.sh). Both backends implement all eight.
#
# NOTE for future edits: CLAUDE.md and tests/vm/README.md used to claim the port
# surface was FOUR helpers. It never was -- create and delete were raw hypervisor
# calls sitting in bootstrap-vm.sh and teardown-vm.sh, outside any helper.

HARNESS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_REPO_DIR="$(cd "$HARNESS_LIB_DIR/../.." && pwd)"

VM_NAME="${VM_NAME:-rhel9test}"
VM_DISTRO="${VM_DISTRO:-rocky}"
VM_RELEASE="${VM_RELEASE:-9}"
VM_ARCH="${VM_ARCH:-amd64}"

# The versions under test. Keep in sync with the scripts -- see CLAUDE.md.
BASELINE_DOCKER="29.1.5"
BASELINE_CONTAINERD="2.2.1"
BASELINE_CONTAINERD_RELEASE="1"
BASELINE_BUILDX="0.30.1"
BASELINE_COMPOSE="5.0.1"
TARGET_DOCKER="29.8.0"
TARGET_CONTAINERD="2.3.4"
TARGET_BUILDX="0.37.0"
TARGET_COMPOSE="5.5.1"

# The containerd.io RPM RELEASE suffix. Everything else in the bundle is -1, so
# this used to be safe to hard-code at the call sites -- it is not any more.
# containerd.io 2.3.4 exists as -1 and -2 with the same %{VERSION}, differing
# only in the runc they carry (1.4.3 vs 1.5.1). Harness cases that build a
# containerd RPM path by hand must use this, or they name a file the bundle does
# not contain and fail for a reason unrelated to what they test.
TARGET_CONTAINERD_RELEASE="2"

# The OTHER build of the same containerd version -- the one case 2.6a stages to
# prove phase 0 refuses it. It is a real upstream RPM, not a doctored file, so
# the case tests the release assertion rather than the digest check.
#
# This is a test fixture, not a target. If a future retarget lands on a
# containerd version that upstream published only once, there is no wrong build
# to stage and 2.6a has nothing to test -- 2.6a asserts the two differ and fails
# loudly rather than passing vacuously.
WRONG_CONTAINERD_RELEASE="1"

# The runc each containerd.io build carries. This is the DIFFERENCE the release
# guard exists to catch -- the two builds are otherwise identical -- so cases
# 2.6a and 2.6b assert it directly rather than trusting %{RELEASE} to stand for
# it. These are test fixtures tied to the two builds above; move them together.
# A stale value here makes a Tier 2 case FAIL, never pass, which is why they are
# not mirrored in tests/static-checks.sh.
TARGET_RUNC="1.5.1"
WRONG_RUNC="1.4.3"

# Where the relocated containerd root lives, and the loopback image backing it.
# A backend may override LOOP_IMG -- the container backend keeps the 3 GB image
# on a named volume rather than in the container's writable layer.
RELOCATED_ROOT="/data/containerd"
LOOP_IMG="/var/data.img"
MANIFEST="/root/baseline-manifest.txt"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'

PASS=0; FAIL=0; SKIP=0
ok()   { printf '  %sPASS%s %s\n' "$GREEN" "$NC" "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  %sFAIL%s %s\n' "$RED" "$NC" "$1";   FAIL=$((FAIL + 1)); }
skip() { printf '  %sSKIP%s %s\n' "$YELLOW" "$NC" "$1"; SKIP=$((SKIP + 1)); }
head_(){ printf '\n== %s ==\n' "$1"; }

# SHA-256 of a file on the HOST, on either kind of host. Stock macOS has
# `shasum` but no `sha256sum`; most Linux distributions have the reverse.
# Prints the bare digest; returns non-zero when neither tool exists.
harness_sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        return 1
    fi
}

#############################################
# Backend selection
#############################################
# HARNESS_BACKEND=auto|orb|docker. Auto prefers OrbStack when it is installed,
# because on a Mac that is the only thing that works; otherwise it falls back
# to a reachable Docker daemon. Set the variable explicitly to override.
HARNESS_BACKEND="${HARNESS_BACKEND:-auto}"

if [ "$HARNESS_BACKEND" = "auto" ]; then
    if command -v orbctl >/dev/null 2>&1; then
        HARNESS_BACKEND="orb"
    elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        HARNESS_BACKEND="docker"
    elif command -v docker >/dev/null 2>&1; then
        echo "ERROR: found the docker CLI but the daemon is not reachable, and" >&2
        echo "       orbctl is not installed. The Tier 2 harness needs one of:" >&2
        echo "         - macOS + OrbStack   (brew install orbstack)" >&2
        echo "         - Linux + a running Docker daemon you can reach" >&2
        echo "       Set HARNESS_BACKEND=orb|docker to override auto-detection." >&2
        exit 1
    else
        echo "ERROR: no Tier 2 backend available. The harness needs one of:" >&2
        echo "         - macOS + OrbStack   (brew install orbstack)" >&2
        echo "         - Linux + a running Docker daemon you can reach" >&2
        echo "       Set HARNESS_BACKEND=orb|docker to override auto-detection." >&2
        exit 1
    fi
fi

case "$HARNESS_BACKEND" in
    orb|docker) ;;
    *) echo "ERROR: HARNESS_BACKEND='$HARNESS_BACKEND' is not 'orb' or 'docker'." >&2; exit 1 ;;
esac

# The sourced path is chosen at runtime, so point shellcheck at both candidates
# and tell it to resolve them relative to this file rather than to the caller's
# working directory (tools/make-release.sh sources this from the repo root).
# shellcheck source-path=SCRIPTDIR
# shellcheck source=backend-orb.sh
# shellcheck source=backend-docker.sh
# shellcheck disable=SC1091  # the backend is chosen at runtime; `shellcheck -x` follows both source= directives above, a bare `shellcheck` cannot
source "$HARNESS_LIB_DIR/backend-$HARNESS_BACKEND.sh"

#############################################
# Guest-side helpers shared by both backends
#############################################

# Wait for systemd inside the guest to finish coming up.
#
# `is-system-running` exits non-zero for `degraded`, which is the normal state
# for a guest with pruned units, so READ THE WORD rather than trusting the exit
# status. /run/systemd/system exists from very early in the boot, so testing for
# it would return while units are still starting -- data.mount among them, which
# is the one thing this waiter exists to wait for.
#
# ONE implementation for both backends. The two copies this replaces had already
# drifted: the OrbStack one stripped carriage returns and took the last line, the
# container one did neither, so identical guest output was parsed two ways.
vm_wait_systemd_settled() {
    local waited=0 state
    while [ "$waited" -lt 120 ]; do
        state=$(vm_try "systemctl is-system-running" | tr -d '\r' | tail -1)
        case "$state" in
            running|degraded) return 0 ;;
        esac
        sleep 2
        waited=$((waited + 2))
    done
    echo "ERROR: systemd in '$VM_NAME' did not settle (last state: '${state:-none}')." >&2
    return 1
}

# Copy files from the host repo into a directory inside the guest, and VERIFY
# every destination byte-for-byte against the host's copy.
#
#   vm_cp_verified <dst_dir> <src_file>...
#
# Both backends expose the repo inside the guest at its identical absolute path,
# so the copy runs IN the guest and is a plain `cp` rather than a push. That is
# exactly why verification is needed: the guest's view of that path is an
# assumption, not a fact. A forwarded or Desktop daemon can hold an older
# checkout at the same absolute path, OrbStack's `orbctl push` silently discards
# an absolute destination while exiting 0, and a partial or shadowed copy exits 0
# too. Comparing the host's digest of the SOURCE against the guest's digest of
# the DESTINATION checks the mount and the copy in one move, per file, at every
# transfer site -- rather than trusting one sentinel file to stand for the tree.
#
# All digests come back in one guest round trip. Failure is loud and fatal to the
# caller: staging the wrong scripts means every product assertion afterwards is
# about code nobody wrote.
vm_cp_verified() {
    local dst_dir="${1:-}"
    shift || true
    if [ -z "$dst_dir" ] || [ "$#" -eq 0 ]; then
        echo "ERROR: vm_cp_verified needs a destination directory and at least one file." >&2
        return 1
    fi

    # Host digests first. A source this host cannot read is a problem to name
    # here, not a mismatch to puzzle over after the copy.
    local f want want_list=""
    for f in "$@"; do
        if [ ! -f "$f" ]; then
            echo "ERROR: vm_cp_verified: '$f' is not a readable file on this host." >&2
            return 1
        fi
        if ! want=$(harness_sha256_of "$f"); then
            echo "ERROR: vm_cp_verified: neither sha256sum nor shasum is on this host," >&2
            echo "       so a copy into the guest cannot be verified." >&2
            return 1
        fi
        want_list="$want_list$want
"
    done

    # Remove each destination FIRST. Otherwise a failed copy leaves whatever a
    # previous run put there and every digest below is taken against a stale file.
    # The DIGEST marker lets the digests be picked out of whatever else the guest
    # says on the way.
    local quoted="" out
    for f in "$@"; do
        quoted="$quoted \"$f\""
    done
    if ! out=$(vm "set -e
mkdir -p \"$dst_dir\"
for f in$quoted; do rm -f \"$dst_dir/\$(basename \"\$f\")\"; done
cp$quoted \"$dst_dir\"/
for f in$quoted; do
    printf 'DIGEST %s\n' \"\$(sha256sum \"$dst_dir/\$(basename \"\$f\")\" | cut -d' ' -f1)\"
done" 2>&1); then
        echo "ERROR: vm_cp_verified: copying into $dst_dir inside '$VM_NAME' failed." >&2
        if [ -n "$out" ]; then printf '       %s\n' "$out" >&2; fi
        return 1
    fi

    local got_list mismatch=0 i=0 base got
    got_list=$(printf '%s\n' "$out" | tr -d '\r' | awk '$1 == "DIGEST" { print $2 }')
    for f in "$@"; do
        i=$((i + 1))
        base="${f##*/}"
        # want_list already ends in a newline; do not add another.
        want=$(printf '%s' "$want_list" | sed -n "${i}p")
        got=$(printf '%s\n' "$got_list" | sed -n "${i}p")
        if [ -z "$got" ] || [ "$want" != "$got" ]; then
            if [ "$mismatch" -eq 0 ]; then
                echo "ERROR: files staged into $dst_dir inside '$VM_NAME' do not match this checkout." >&2
            fi
            echo "       $base: host ${want:-<unreadable>} != guest ${got:-<missing>}" >&2
            mismatch=1
        fi
    done
    if [ "$mismatch" -ne 0 ]; then
        echo "       The guest is not reading $HARNESS_REPO_DIR from this filesystem, or" >&2
        echo "       the copy did not complete. Refusing to run against unknown scripts." >&2
        return 1
    fi
    return 0
}

require_vm() {
    need_backend
    if ! vm_exists; then
        echo "ERROR: VM '$VM_NAME' does not exist. Run tests/vm/bootstrap-vm.sh first." >&2
        exit 1
    fi
    # Do NOT swallow this. A guest that will not come up, or one whose repo
    # bind mount does not resolve to this checkout, must stop the run here
    # rather than produce failures further down that look like product bugs.
    if ! vm_wake; then
        echo "ERROR: VM '$VM_NAME' exists but is not usable." >&2
        exit 1
    fi
}

#############################################
# The relocated root
#############################################
# Establish /data as a real, separate, loop-backed XFS filesystem -- and do it
# through a systemd MOUNT UNIT rather than a bare `mount -o loop`.
#
# The unit is what makes the mount survive a guest restart. A bare mount does
# not: the mount namespace goes away, the 3 GB backing file does not, and
# systemd then starts containerd on an EMPTY shadow /data/containerd directory
# while reporting it active. Zero snapshots, no images, canary container dead --
# and every Tier 2 assertion failing for a reason that has nothing to do with
# the scripts under test.
#
# Installed on BOTH backends, from one code path, for three reasons: the hazard
# is not specific to containers (an OrbStack machine that reboots loses a bare
# mount too), a production node with a relocated containerd root would carry an
# fstab entry anyway so this makes the baseline more faithful, and one code path
# cannot drift against itself.
ensure_relocated_mount() {
    local loop_dir
    loop_dir="$(dirname "$LOOP_IMG")"

    # $RELOCATED_ROOT is deliberately NOT created here. Creating it before the
    # mount lands puts it on the guest's OWN root filesystem, where the mount
    # then hides it -- which is precisely the shadow-root hazard described
    # above, manufactured by the code that exists to prevent it. The leaf is
    # created after the mount is verified active, at the end of this function.
    vm "set -e
mkdir -p $loop_dir /data
[ -f $LOOP_IMG ] || dd if=/dev/zero of=$LOOP_IMG bs=1M count=3072 status=none
blkid $LOOP_IMG >/dev/null 2>&1 || mkfs.xfs -q -n ftype=1 $LOOP_IMG

mkdir -p /etc/systemd/system/containerd.service.d
cat > /etc/systemd/system/data.mount <<'UNIT_EOF'
[Unit]
Description=Harness XFS filesystem for the relocated containerd root
Before=containerd.service

[Mount]
What=$LOOP_IMG
Where=/data
Type=xfs
Options=loop

[Install]
WantedBy=local-fs.target
UNIT_EOF

cat > /etc/systemd/system/containerd.service.d/10-harness-mount.conf <<'DROPIN_EOF'
[Unit]
RequiresMountsFor=$RELOCATED_ROOT
DROPIN_EOF

systemctl daemon-reload
systemctl enable data.mount

# Is /data an actual MOUNT POINT? findmnt with a bare path (no --target)
# matches an exact mountpoint or source and exits 1 when there is none. The
# --target form walks up instead and would report the containing filesystem,
# which is NOT what is wanted here. Compare the output explicitly rather than
# relying on the exit status, so the intent cannot be misread.
# (No backticks in this comment: it lives inside a double-quoted host string,
#  where backticks would be command substitution.)
if [ \"\$(findmnt -n -o TARGET /data 2>/dev/null)\" != /data ]; then
    systemctl start data.mount
fi

# Do not assume the start worked.
if ! systemctl is-active --quiet data.mount; then
    echo 'ERROR: data.mount did not become active. systemctl status:' >&2
    systemctl status data.mount --no-pager -l >&2 || true
    exit 1
fi
mkdir -p $RELOCATED_ROOT"
}

# Hard precondition: the relocated root must actually be on the separate XFS.
#
# If it is not, everything downstream is theatre -- the canary data gets written
# to a shadow directory on the guest's own root filesystem and the whole S1
# premise is a lie. Refuse rather than produce a green run built on it.
# FSTYPE alone is not enough. An XFS filesystem mounted somewhere other than
# /data, or one backed by something that is not the harness's loopback image, is
# a different baseline than the one every downstream assertion assumes. Check
# five facts and name the ones that failed.
#
# On is-active vs is-enabled, measured rather than assumed: systemd ADOPTS any
# mount at /data into data.mount, so `is-active` reports `active` for a
# hand-made `mount -o loop` -- and keeps reporting it even with the unit file
# deleted. It therefore proves only "something is mounted there", and is kept
# for the case where the unit is `failed` with a stale mount underneath.
# `is-enabled` is the one that carries weight: it is what makes the mount come
# back after a restart, and a hand mount does not satisfy it. (The other half of
# restart survival, containerd.service's RequiresMountsFor drop-in, is asserted
# by preflight-host.sh.)
require_relocated_xfs() {
    local tgt fs src active enabled backing fail=""
    tgt=$(vm_try     "findmnt -n -o TARGET --target $RELOCATED_ROOT 2>/dev/null" | tr -d '\r' | tail -1)
    fs=$(vm_try      "findmnt -n -o FSTYPE --target $RELOCATED_ROOT 2>/dev/null" | tr -d '\r' | tail -1)
    src=$(vm_try     "findmnt -n -o SOURCE --target $RELOCATED_ROOT 2>/dev/null" | tr -d '\r' | tail -1)
    active=$(vm_try  "systemctl is-active data.mount 2>/dev/null"  | tr -d '\r' | tail -1)
    enabled=$(vm_try "systemctl is-enabled data.mount 2>/dev/null" | tr -d '\r' | tail -1)
    # Which loop device(s) the harness image is actually attached to. "It is a
    # loop device" is not the claim being made -- "it is THIS image" is.
    backing=$(vm_try "losetup -j $LOOP_IMG 2>/dev/null | cut -d: -f1 | tr '\\n' ' '" | tr -d '\r' | tail -1)

    [ "$tgt" = "/data" ]      || fail="$fail\n       mount point is '${tgt:-<none>}', want /data"
    [ "$fs" = "xfs" ]         || fail="$fail\n       filesystem is '${fs:-<none>}', want xfs"
    case "$src" in
        /dev/loop*) ;;
        *) fail="$fail\n       source is '${src:-<none>}', want a /dev/loop* device" ;;
    esac
    case " ${backing% } " in
        *" $src "*) ;;
        *) fail="$fail\n       source '${src:-<none>}' is not backed by $LOOP_IMG (losetup -j reports: ${backing:-<none>})" ;;
    esac
    [ "$active" = "active" ]   || fail="$fail\n       data.mount is '${active:-<none>}', want active"
    [ "$enabled" = "enabled" ] || fail="$fail\n       data.mount is '${enabled:-<none>}', want enabled -- the mount would NOT survive a restart"

    if [ -n "$fail" ]; then
        echo "" >&2
        echo "${RED}ERROR${NC}: $RELOCATED_ROOT is not on the harness's separate XFS filesystem." >&2
        # shellcheck disable=SC2059  # $fail carries the \n separators deliberately
        printf "$fail\n" >&2
        echo "       The S1 baseline REQUIRES it. Without it, containerd is running on a" >&2
        echo "       shadow directory and every relocated-root assertion is meaningless." >&2
        echo "       Fix:  tests/vm/reset-baseline.sh   (or bootstrap-vm.sh --recreate)" >&2
        exit 1
    fi
    echo "  relocated root: $RELOCATED_ROOT on $src ($fs at $tgt; data.mount $active, $enabled)"
}

# Stage the in-guest manifest writer.
#
# vm_cp_verified does the copy AND the content check, so the removal-first and
# digest-compare logic that used to live here is gone rather than duplicated.
stage_manifest_writer() {
    vm_cp_verified /tmp "$HARNESS_LIB_DIR/vm-write-manifest.sh" || exit 1
    vm "chmod +x /tmp/vm-write-manifest.sh" || exit 1
}

# Assert a command in the VM prints exactly the expected string.
assert_vm_eq() {
    local label="$1" cmd="$2" want="$3" got
    got=$(vm_try "$cmd" | tr -d '\r' | tail -1)
    if [ "$got" = "$want" ]; then
        ok "$label"
    else
        bad "$label (got '$got', want '$want')"
    fi
}

# Assert a command in the VM succeeds.
assert_vm_ok() {
    local label="$1" cmd="$2"
    if vm_try "$cmd >/dev/null 2>&1; echo \$?" | tail -1 | grep -qx 0; then
        ok "$label"
    else
        bad "$label"
    fi
}

# Assert a command in the VM FAILS (for rejection tests).
assert_vm_fails() {
    local label="$1" cmd="$2" rc
    rc=$(vm_try "$cmd >/dev/null 2>&1; echo \$?" | tail -1)
    if [ "$rc" != "0" ]; then
        ok "$label (exit $rc)"
    else
        bad "$label (expected non-zero, got 0)"
    fi
}

# --- agent-mode state helpers -------------------------------------------
#
# assert_untouched in tier2-run.sh checks docker-ce and the docker service
# only, which can miss a partial containerd or plugin change. These are the
# strict versions, used by the agent-mode cases. assert_untouched itself is
# deliberately NOT changed: doing so would alter the pre-existing assertion
# count and break the interactive-path regression gate.

# Package versions for a whole profile: baseline | target.
assert_pkg_profile() {
    local label="$1" profile="$2"
    local d c b m
    case "$profile" in
        baseline) d="$BASELINE_DOCKER"; c="$BASELINE_CONTAINERD"; b="$BASELINE_BUILDX"; m="$BASELINE_COMPOSE" ;;
        target)   d="$TARGET_DOCKER";   c="$TARGET_CONTAINERD";   b="$TARGET_BUILDX";   m="$TARGET_COMPOSE" ;;
        *) bad "$label: unknown package profile '$profile'"; return ;;
    esac
    assert_vm_eq "$label: docker-ce $d"             "rpm -q docker-ce --queryformat '%{VERSION}'" "$d"
    assert_vm_eq "$label: docker-ce-cli $d"         "rpm -q docker-ce-cli --queryformat '%{VERSION}'" "$d"
    assert_vm_eq "$label: containerd.io $c"         "rpm -q containerd.io --queryformat '%{VERSION}'" "$c"
    assert_vm_eq "$label: buildx $b"                "rpm -q docker-buildx-plugin --queryformat '%{VERSION}'" "$b"
    assert_vm_eq "$label: compose $m"               "rpm -q docker-compose-plugin --queryformat '%{VERSION}'" "$m"
}

# Snapshot the state an "unchanged" claim is about. A profile alone cannot
# express this: the backup count grows with every upgrade, and some cases
# deliberately create more than one, so "unchanged" has to be measured against
# the moment before the invocation under test.
#
# It captures config sha, backup count and the canary. It does NOT capture the
# service states: assert_strict_state_unchanged requires both units to be
# `active` afterwards, which is the right assertion for every case that uses
# it. A case that starts from stopped services needs its own assertion.
capture_strict_state() {
    local name="$1"
    STRICT_CONF_SHA[$name]=$(vm_try "sha256sum /etc/containerd/config.toml 2>/dev/null | cut -d' ' -f1" | tail -1)
    STRICT_BACKUPS[$name]=$(vm_try "ls -d /root/docker-backup-*/ 2>/dev/null | wc -l" | tail -1)
    STRICT_CANARY[$name]=$(vm_try "docker start survivor >/dev/null 2>&1; docker exec survivor cat /data/canary.txt 2>/dev/null" | tail -1)
}

assert_strict_state_unchanged() {
    local label="$1" name="$2" got
    got=$(vm_try "sha256sum /etc/containerd/config.toml 2>/dev/null | cut -d' ' -f1" | tail -1)
    if [ "$got" = "${STRICT_CONF_SHA[$name]}" ]; then
        ok "$label: containerd config unchanged"
    else
        bad "$label: containerd config CHANGED (${STRICT_CONF_SHA[$name]:0:12} -> ${got:0:12})"
    fi
    got=$(vm_try "ls -d /root/docker-backup-*/ 2>/dev/null | wc -l" | tail -1)
    if [ "$got" = "${STRICT_BACKUPS[$name]}" ]; then
        ok "$label: no new backup directory ($got)"
    else
        bad "$label: backup count changed (${STRICT_BACKUPS[$name]} -> $got)"
    fi
    assert_vm_eq "$label: docker still active"     "systemctl is-active docker" "active"
    assert_vm_eq "$label: containerd still active" "systemctl is-active containerd" "active"
    got=$(vm_try "docker start survivor >/dev/null 2>&1; docker exec survivor cat /data/canary.txt 2>/dev/null" | tail -1)
    if [ "$got" = "${STRICT_CANARY[$name]}" ]; then
        ok "$label: canary data intact"
    else
        bad "$label: canary data changed ('${STRICT_CANARY[$name]}' -> '$got')"
    fi
}
declare -A STRICT_CONF_SHA STRICT_BACKUPS STRICT_CANARY

assert_untouched_strict() {
    local label="$1" profile="$2" name="$3"
    assert_pkg_profile "$label" "$profile"
    assert_strict_state_unchanged "$label" "$name"
}

# Read one key out of a status file inside the guest. Prints nothing when the
# file or the key is absent, so a caller comparing against an expected value
# fails rather than silently matching.
status_key() {
    local path="$1" key="$2"
    vm_try "sed -n 's/^${key}=//p' '$path' 2>/dev/null | head -1" | tail -1
}

assert_status_key() {
    local label="$1" path="$2" key="$3" want="$4" got
    got=$(status_key "$path" "$key")
    if [ "$got" = "$want" ]; then
        ok "$label: $key=$want"
    else
        bad "$label: $key is '$got', want '$want'"
    fi
}

# A record is only readable if its last line is the terminator. Anything else
# is a partial write and must be treated as unknown, not as its last result.
assert_status_complete() {
    local label="$1" path="$2" got
    got=$(vm_try "tail -n 1 '$path' 2>/dev/null" | tail -1)
    if [ "$got" = "status_complete=1" ]; then
        ok "$label: status file is complete"
    else
        bad "$label: status file does not end in status_complete=1 (got '$got')"
    fi
}

summary() {
    printf '\n==========================================\n'
    printf 'passed %d, failed %d, skipped %d\n' "$PASS" "$FAIL" "$SKIP"
    printf '==========================================\n'
    [ "$FAIL" -gt 0 ] && return 1
    return 0
}

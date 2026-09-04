#!/bin/bash
# upgrade-docker.sh
# Run on each AIR-GAPPED server to upgrade Docker 29.1.5 → 29.8.0
VERSION="2.2.0"
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
# SCOPE OF THIS VERSION (2.2.0)
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

# Log file
exec > >(tee -a /var/log/docker-upgrade.log) 2>&1

echo "=========================================="
echo "Docker Upgrade: 29.1.5 → 29.8.0"
echo "Script Version: $VERSION"
echo "Server: $(hostname)"
echo "Date: $(date)"
echo "=========================================="

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

# shellcheck disable=SC2329  # invoked indirectly by `trap on_exit EXIT` below
on_exit() {
    local rc=$?
    [ "$rc" -eq 0 ] && exit 0

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
    local max_wait=60
    local waited=0

    echo "Waiting for Swarm services to stabilize..."
    while [ $waited -lt $max_wait ]; do
        local pending
        # `docker service ls` renders .Replicas as running/desired, so a service
        # that has not converged looks like 0/1 or 1/3. The previous
        # `grep -v "0/0" | grep -c "/0"` counted services whose DESIRED count
        # was zero, which is not the question being asked and matched nothing in
        # practice; a second bug (`|| echo "0"` appending a duplicate zero when
        # grep found no match) masked it by forcing the full 60s wait.
        #
        # Count rows where running != desired -- the actual definition of
        # "not yet converged".
        #
        # `docker service ls` is run on its own first: piping it straight into
        # awk without pipefail means a FAILED docker command feeds awk nothing,
        # awk prints 0, and "no services" becomes indistinguishable from "all
        # converged". Keep waiting instead of declaring victory blindly.
        local replicas
        if ! replicas=$(docker service ls --format '{{.Replicas}}' 2>/dev/null); then
            echo "  Waiting: 'docker service ls' not answering yet... ($waited/$max_wait seconds)"
            sleep 5
            waited=$((waited + 5))
            continue
        fi

        # Split the FIRST whitespace-delimited token, then on "/". A replicated
        # job renders as "0/1 (0/3 completed)", which splitting the whole line
        # on "/" turns into three fields -- so an NF==2 guard silently dropped
        # unconverged jobs from the count. Taking $1 first handles both forms.
        # A garbage row yields an empty second field and is skipped.
        pending=$(printf '%s' "$replicas" |
            awk '{ split($1, r, "/"); if (r[1] != "" && r[2] != "" && r[1] != r[2]) n++ } END { print n+0 }')
        pending=${pending:-0}

        if [ "$pending" = "0" ]; then
            echo "All services are running."
            return 0
        fi

        echo "  Waiting for services... ($waited/$max_wait seconds)"
        sleep 5
        waited=$((waited + 5))
    done

    echo -e "${YELLOW}WARNING: Some services may still be starting.${NC}"
    # `|| true`: this is the timeout path of a NON-fatal wait, reached at phase
    # 10 when packages are installed, versions asserted, services up and the
    # node reactivated. A failing `docker service ls` here would trip set -e and
    # make the trap announce "UPGRADE FAILED during: phase 10" over a completely
    # successful upgrade.
    docker service ls || true
    return 0
}

#############################################
# Pre-flight Checks
#############################################

# Detect RHEL version
RHEL_VER=$(rpm -E %rhel)
PKG_DIR="/opt/docker-offline/rhel${RHEL_VER}"

if [ ! -d "$PKG_DIR" ]; then
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

    if [ -z "$found" ]; then
        # Either no containerd.io in the payload, or one whose earlier checks
        # rejected it (arch, el-major, duplicate) and `continue`d before the
        # release was recorded. check_version has already said which; this
        # exists so an empty string can never be mistaken for agreement.
        echo -e "${RED}  ERROR: containerd.io RPM release is empty (expected ${want}.el${RHEL_VER})${NC}"
        PKG_ERRORS=$((PKG_ERRORS + 1))
        return
    fi

    if containerd_release_matches "$found" "$want" "$RHEL_VER"; then
        echo -e "  ${GREEN}✓ containerd.io release $found${NC}"
        return
    fi

    echo -e "${RED}  ERROR: containerd.io release is $found, expected ${want}.el${RHEL_VER}${NC}"
    echo "         containerd.io $EXPECTED_CONTAINERD_VERSION was published more than once."
    echo "         Release -1 carries runc 1.4.3; -2 carries runc 1.5.1."
    echo "         This bundle has the wrong build. Re-download it."
    PKG_ERRORS=$((PKG_ERRORS + 1))
}

check_containerd_release "$FOUND_CONTAINERD_REL" "$EXPECTED_CONTAINERD_RELEASE"

if [ "$PKG_ERRORS" -gt 0 ]; then
    echo ""
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
if [ "$CURRENT_DOCKER" = "$EXPECTED_DOCKER_VERSION" ] &&
   [ "$CURRENT_DOCKER_CLI" = "$EXPECTED_DOCKER_VERSION" ] &&
   [ "$CURRENT_CONTAINERD" = "$EXPECTED_CONTAINERD_VERSION" ] &&
   containerd_release_matches "$CURRENT_CONTAINERD_REL" "$EXPECTED_CONTAINERD_RELEASE" "$RHEL_VER" &&
   [ "$CURRENT_BUILDX" = "$EXPECTED_BUILDX_VERSION" ] &&
   [ "$CURRENT_COMPOSE" = "$EXPECTED_COMPOSE_VERSION" ]; then
    echo ""
    echo -e "${YELLOW}NOTE: this node is already fully at the target versions:${NC}"
    echo "  docker-ce $CURRENT_DOCKER, docker-ce-cli $CURRENT_DOCKER_CLI,"
    echo "  containerd.io $CURRENT_CONTAINERD-$CURRENT_CONTAINERD_REL, buildx $CURRENT_BUILDX,"
    echo "  compose $CURRENT_COMPOSE"
    if ! prompt_yes_no "Re-run the upgrade anyway? [y/N]" "n"; then
        echo "Nothing to do. Exiting without changes."
        exit 0
    fi
elif [ "$CURRENT_DOCKER" = "$EXPECTED_DOCKER_VERSION" ] ||
     [ "$CURRENT_CONTAINERD" = "$EXPECTED_CONTAINERD_VERSION" ]; then
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
    if [ "$CURRENT_DOCKER" != "$SUPPORTED_FROM_DOCKER" ] ||
       [ "$CURRENT_CONTAINERD" != "$SUPPORTED_FROM_CONTAINERD" ]; then
        echo ""
        echo -e "${YELLOW}=========================================="
        echo "WARNING: UNEXPECTED STARTING VERSION"
        echo -e "==========================================${NC}"
        echo ""
        echo "  tested upgrade path: $SUPPORTED_FROM_DOCKER / containerd.io $SUPPORTED_FROM_CONTAINERD"
        echo "  this node has:       ${CURRENT_DOCKER:-absent} / containerd.io ${CURRENT_CONTAINERD:-absent}"
        echo ""
        if ! prompt_yes_no "Continue from this unverified starting version? [y/N]" "n"; then
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
        echo "This node is a Swarm MANAGER (Node ID: $SWARM_NODE_ID)"
    else
        echo "This node is a Swarm WORKER (Node ID: $SWARM_NODE_ID)"
    fi

    # Check current availability (only managers can inspect nodes)
    if [ "$IS_MANAGER" = true ]; then
        NODE_AVAILABILITY=$(docker node inspect "$SWARM_NODE_ID" --format '{{.Spec.Availability}}' 2>/dev/null || echo "unknown")
        echo "Current availability: $NODE_AVAILABILITY"
    else
        # Workers cannot check their own status, assume active
        NODE_AVAILABILITY="unknown"
        echo "Current availability: unknown (worker nodes cannot self-inspect)"
    fi

    if [ "$NODE_AVAILABILITY" = "active" ] || [ "$NODE_AVAILABILITY" = "unknown" ]; then
        if [ "$IS_MANAGER" = true ]; then
            # Manager can drain itself
            echo ""
            echo -e "${YELLOW}WARNING: This node is currently ACTIVE in the Swarm.${NC}"
            echo "It should be drained before upgrading to avoid service disruption."
            echo ""

            if prompt_yes_no "Drain this node now? [Y/n]" "y"; then
                echo "Draining node..."
                docker node update --availability drain "$SWARM_NODE_ID"

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
                    if ! prompt_yes_no "Continue with upgrade anyway? [y/N]" "n"; then
                        echo "Aborting. Confirm the drain from a manager and re-run."
                        exit 1
                    fi
                elif [ "$TASKS" -gt 0 ]; then
                    echo "Tasks still on this node: $TASKS"
                    docker node ps "$SWARM_NODE_ID" --filter "desired-state=running" || true
                    echo ""
                    if ! prompt_yes_no "Continue with upgrade anyway? [y/N]" "n"; then
                        echo "Aborting. Please wait for tasks to migrate and re-run."
                        exit 1
                    fi
                else
                    echo "All tasks migrated successfully."
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

            if ! prompt_yes_no "Has this node been drained from a manager? [y/N]" "n"; then
                echo "Aborting. Please drain this node from a manager and re-run."
                exit 1
            fi
        fi
    else
        echo "Node is already drained/paused. Proceeding with upgrade."
    fi
else
    echo "This node is NOT part of a Docker Swarm."
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
# and to ensure the directory exists.
#
# The awk stops at the first `[section]` header so only TOP-LEVEL keys are
# considered. Both halves of that matter:
#
#   - Without it, a config whose only `root` key lives inside a
#     [plugins."..."] section would yield that plugin's path as if it were
#     containerd's root.
#   - The sed tolerates leading whitespace, because an INDENTED top-level
#     `root` previously parsed as empty and silently fell back to
#     /var/lib/containerd -- which would defeat the relocated-root mount check
#     below, since that only fires for a non-default root.
#
# Generated configs single-quote paths; hand-edited ones may double-quote or
# leave bare, so accept all three, and ignore any trailing inline comment.
CONTAINERD_ROOT=$(awk '/^[[:space:]]*\[/ { exit } { print }' "$CONTAINERD_CONF" 2>/dev/null \
    | sed -n "s/^[[:space:]]*root[[:space:]]*=[[:space:]]*['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}.*/\1/p" \
    | head -1)
CONTAINERD_ROOT=${CONTAINERD_ROOT:-/var/lib/containerd}

echo "containerd root directory: $CONTAINERD_ROOT"

if [ ! -d "$CONTAINERD_ROOT" ]; then
    if [ "$CONTAINERD_ROOT" = "/var/lib/containerd" ]; then
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
            echo -e "${GREEN}NVIDIA packages installed.${NC}"
        else
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
        echo "Current node availability: $CURRENT_AVAILABILITY"

        if [ "$CURRENT_AVAILABILITY" = "drain" ]; then
            echo ""
            if prompt_yes_no "Set this node back to ACTIVE? [Y/n]" "y"; then
                echo "Activating node..."
                docker node update --availability active "$SWARM_NODE_ID"

                echo ""
                wait_for_services

                echo ""
                echo "Node status:"
                docker node ls

                echo ""
                echo "Services on this node:"
                docker node ps "$SWARM_NODE_ID" | head -20
            else
                echo ""
                echo "Node remains drained. To activate later, run:"
                echo "  docker node update --availability active $SWARM_NODE_ID"
            fi
        else
            echo "Node is already active."
        fi
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
echo -e "${GREEN}UPGRADE COMPLETE${NC}"
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

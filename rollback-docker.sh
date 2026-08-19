#!/bin/bash
# rollback-docker.sh
# Emergency rollback: Docker 29.7.2 → 29.1.5
VERSION="2.1.0"
#
# Use this script if:
# - Services fail to start after upgrade
# - Applications break due to API changes
# - Cluster nodes have version mismatch issues
# - Any other critical issues requiring immediate rollback
#
# Prerequisites:
# - Rollback packages in /opt/docker-offline/rollback-rhel{8,9}/
#
# SCOPE
#
# This rolls back to 29.1.5 / containerd.io 2.2.1 -- the state the cluster ran
# before this upgrade. No network-state reset is involved.
#
# It DOES step containerd back across a config-version boundary: 2.3.3 supports
# config version 4, 2.2.1 supports at most 3. The upgrade never writes a v4
# file, so in the normal case the config on disk is still the v3 one 2.2.1
# wrote and nothing needs to change. But if something did write a v4 config --
# most plausibly an operator running `containerd config default >
# /etc/containerd/config.toml` -- then downgrading would leave containerd
# unable to start at all:
#
#   containerd: failed to load TOML from /etc/containerd/config.toml:
#   expected containerd config version equal to or less than `3`, got `4`
#
# Phase 0c detects that while the node is still up and running, and refuses to
# proceed rather than producing a node with a dead runtime.
#
# It does NOT roll back to 28.5.1 / containerd 1.7.x. That would cross the
# containerd major boundary in reverse and would have to be done on every node
# in the cluster simultaneously, because containerd 2.x and 1.7.x cannot
# coexist in one Swarm (ALPN handshake errors). If you genuinely need that,
# it is a planned cluster-wide operation, not an emergency single-node action.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

exec > >(tee -a /var/log/docker-rollback.log) 2>&1

echo "=========================================="
echo "Docker Rollback: 29.7.2 → 29.1.5"
echo "Script Version: $VERSION"
echo "Server: $(hostname)"
echo "Date: $(date)"
echo "=========================================="

#############################################
# Expected package versions
#############################################
# Asserted against RPM metadata, not filenames.
# Keep in sync with download-docker-packages.sh, upgrade-docker.sh,
# simulate-upgrade.sh and README.md -- see CLAUDE.md.
ROLLBACK_DOCKER_VERSION="29.1.5"
ROLLBACK_CONTAINERD_VERSION="2.2.1"
ALLOWED_PKGS="docker-ce docker-ce-cli containerd.io"

#############################################
# Failure Handling
#############################################
CURRENT_PHASE="startup"
SERVICES_STOPPED=false

# Tracked separately from service state, so the trap can never claim the node
# is unchanged after a partially applied downgrade.
#   untouched | attempted | installed
PKG_STATE="untouched"

# shellcheck disable=SC2329  # invoked indirectly by `trap on_exit EXIT` below
on_exit() {
    local rc=$?
    [ "$rc" -eq 0 ] && exit 0

    echo ""
    echo -e "${RED}==========================================${NC}"
    echo -e "${RED}ROLLBACK FAILED during: $CURRENT_PHASE (exit $rc)${NC}"
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
            echo -e "Packages:  ${RED}UNKNOWN - the downgrade did not complete cleanly${NC}"
            ;;
        installed)
            echo "Packages:  downgraded successfully"
            ;;
    esac

    echo ""
    echo "Establish what is actually installed before acting:"
    echo "  rpm -q docker-ce docker-ce-cli containerd.io"
    echo "  journalctl -u containerd --no-pager -n 100"
    echo "  journalctl -u docker --no-pager -n 100"

    if [ "$SERVICES_STOPPED" = true ]; then
        echo ""
        echo "Then try to bring the node up on whatever is installed:"
        echo "  systemctl start containerd"
        echo "  ctr version                 # wait until this responds"
        echo "  systemctl start docker"
        if [ "$PKG_STATE" = "attempted" ]; then
            echo ""
            echo -e "${YELLOW}If containerd.io downgraded but docker-ce did not, the engine${NC}"
            echo -e "${YELLOW}is NEWER than its runtime. Re-run this script to finish.${NC}"
        fi
    fi

    echo ""
    echo "Log: /var/log/docker-rollback.log"
    echo "=========================================="
    exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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

# Start containerd, wait for it to be genuinely usable, then start docker.
# systemd reports containerd active before its snapshotter is ready -- a bare
# `sleep` here is what produced the race this project already had to fix once.
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

# Detect RHEL version
RHEL_VER=$(rpm -E %rhel)
ROLLBACK_DIR="/opt/docker-offline/rollback-rhel${RHEL_VER}"

if [ ! -d "$ROLLBACK_DIR" ]; then
    echo -e "${RED}ERROR: Rollback directory not found: $ROLLBACK_DIR${NC}"
    exit 1
fi

echo "Detected RHEL version: $RHEL_VER"
echo "Using rollback packages from: $ROLLBACK_DIR"

#############################################
# Phase 0: Validate Rollback Payload
#############################################
# Everything checkable runs BEFORE services stop. A rollback that discovers a
# missing package after shutdown strands a node that was merely misbehaving.
echo ""
echo "=== Phase 0: Validate Rollback Payload ==="
CURRENT_PHASE="phase 0 (validate payload)"

shopt -s nullglob
PKG_FILES=("$ROLLBACK_DIR"/*.rpm)
shopt -u nullglob

if [ "${#PKG_FILES[@]}" -eq 0 ]; then
    echo -e "${RED}ERROR: No .rpm files found in $ROLLBACK_DIR${NC}"
    exit 1
fi
echo "Found ${#PKG_FILES[@]} package(s)"

PKG_ERRORS=0
FOUND_DOCKER_CE=""
FOUND_DOCKER_CLI=""
FOUND_CONTAINERD=""
HOST_ARCH=$(uname -m)
SEEN_NAMES=""

# Resolved paths, so the downgrade installs exactly what was validated rather
# than re-globbing. A glob that matches nothing expands to its literal self and
# would be handed to rpm as a filename.
CONTAINERD_RPM=""
DOCKER_RPMS=()

echo ""
echo "Package inventory:"
for rpmfile in "${PKG_FILES[@]}"; do
    if ! rpm -K --nosignature "$rpmfile" >/dev/null 2>&1; then
        echo -e "${RED}  ERROR: ${rpmfile##*/} failed digest verification${NC}"
        PKG_ERRORS=$((PKG_ERRORS + 1))
        continue
    fi

    meta=$(rpm -qp --queryformat '%{NAME} %{VERSION} %{RELEASE} %{ARCH}' "$rpmfile" 2>/dev/null || true)
    if [ -z "$meta" ]; then
        echo -e "${RED}  ERROR: ${rpmfile##*/} is not a readable RPM${NC}"
        PKG_ERRORS=$((PKG_ERRORS + 1))
        continue
    fi

    read -r p_name p_ver p_rel p_arch <<< "$meta"
    echo "  $p_name $p_ver-$p_rel.$p_arch"

    case " $ALLOWED_PKGS " in
        *" $p_name "*) ;;
        *)
            echo -e "${RED}  ERROR: unexpected package '$p_name' in rollback dir${NC}"
            PKG_ERRORS=$((PKG_ERRORS + 1))
            continue
            ;;
    esac

    # Duplicates would append twice to DOCKER_RPMS and let the scalar version
    # assertion below remember only whichever copy was read last.
    case " $SEEN_NAMES " in
        *" $p_name "*)
            echo -e "${RED}  ERROR: duplicate $p_name in $ROLLBACK_DIR${NC}"
            echo "         Remove the directory and re-extract the bundle cleanly."
            PKG_ERRORS=$((PKG_ERRORS + 1))
            continue
            ;;
    esac
    SEEN_NAMES="$SEEN_NAMES $p_name"

    if [ "$p_arch" != "$HOST_ARCH" ] && [ "$p_arch" != "noarch" ]; then
        echo -e "${RED}  ERROR: $p_name is $p_arch, host is $HOST_ARCH${NC}"
        PKG_ERRORS=$((PKG_ERRORS + 1))
        continue
    fi

    # RELEASE carries the RHEL major (e.g. "1.el9"); catch an el8 RPM sitting
    # in the rhel9 rollback directory.
    case "$p_rel" in
        *".el${RHEL_VER}"*) ;;
        *)
            echo -e "${RED}  ERROR: $p_name release '$p_rel' is not el${RHEL_VER}${NC}"
            PKG_ERRORS=$((PKG_ERRORS + 1))
            continue
            ;;
    esac

    case "$p_name" in
        docker-ce)
            FOUND_DOCKER_CE="$p_ver"
            DOCKER_RPMS+=("$rpmfile")
            ;;
        docker-ce-cli)
            FOUND_DOCKER_CLI="$p_ver"
            DOCKER_RPMS+=("$rpmfile")
            ;;
        containerd.io)
            FOUND_CONTAINERD="$p_ver"
            CONTAINERD_RPM="$rpmfile"
            ;;
    esac
done

check_version() {
    local label="$1" found="$2" want="$3"
    if [ -z "$found" ]; then
        echo -e "${RED}  ERROR: no $label package found${NC}"
        PKG_ERRORS=$((PKG_ERRORS + 1))
    elif [ "$found" != "$want" ]; then
        echo -e "${RED}  ERROR: $label is $found, expected $want${NC}"
        PKG_ERRORS=$((PKG_ERRORS + 1))
    else
        echo -e "  ${GREEN}✓ $label $found${NC}"
    fi
}

echo ""
check_version "docker-ce"     "$FOUND_DOCKER_CE"  "$ROLLBACK_DOCKER_VERSION"
check_version "docker-ce-cli" "$FOUND_DOCKER_CLI" "$ROLLBACK_DOCKER_VERSION"
check_version "containerd.io" "$FOUND_CONTAINERD" "$ROLLBACK_CONTAINERD_VERSION"

if [ "$PKG_ERRORS" -gt 0 ]; then
    echo ""
    echo -e "${RED}ERROR: $PKG_ERRORS problem(s) with the rollback payload.${NC}"
    echo "Nothing on this node has been changed."
    exit 1
fi

# Dry-run the exact transaction phase 2 will perform, while services are still
# running and the node is still recoverable. This is the only way to learn that
# rpm will refuse the downgrade -- for a dependency it cannot satisfy, say --
# without finding out after the node is already down.
echo ""
echo "Dry-running the downgrade transaction..."
# --replacepkgs matters for RESUMABILITY. --oldpackage permits installing a
# lower EVR, but not reinstalling an identical one. If a previous run failed
# after containerd.io had already reached 2.2.1, a rerun without this would be
# rejected with "package is already installed" -- making the trap's "re-run
# this script" advice impossible to follow on exactly the node that needs it.
if ! rpm -Uvh --test --oldpackage --replacepkgs "$CONTAINERD_RPM" "${DOCKER_RPMS[@]}" 2>&1; then
    echo ""
    echo -e "${RED}ERROR: rpm rejected the downgrade transaction (dry run).${NC}"
    echo "Nothing on this node has been changed. The output above says why."
    echo ""
    echo "Common cause: another installed package depends on the newer versions."
    echo "Inspect with: rpm -q --whatrequires containerd.io"
    exit 1
fi
echo -e "${GREEN}Transaction dry run passed.${NC}"
echo -e "${YELLOW}NOTE: the dry run validates rpm's planned transaction only.${NC}"
echo "Package scriptlets and the actual file writes run in phase 2 and can"
echo "still fail there."

echo -e "${GREEN}Rollback payload validated.${NC}"

#############################################
# Phase 0b: Select the containerd Config Backup
#############################################
# Chosen HERE, while the node is still up and nothing has been changed.
#
# This used to happen in phase 3, after the downgrade had already run with
# services stopped -- so an operator who saw the wrong backup named could only
# either accept it or interrupt a half-finished rollback. Deciding first means
# a wrong backup costs nothing.
echo ""
echo "=== Phase 0b: Select Config Backup ==="
CURRENT_PHASE="phase 0b (select config backup)"

# upgrade-docker.sh names backups docker-backup-YYYYmmdd-HHMMSS, so the glob's
# lexical ordering is already chronological -- the last element is the newest.
shopt -s nullglob
BACKUP_DIRS=(/root/docker-backup-*/)
shopt -u nullglob

BACKUP_DIR=""
if [ "${#BACKUP_DIRS[@]}" -eq 0 ]; then
    echo "No /root/docker-backup-* directories found."
    echo "The existing containerd config will be kept as-is."
    echo "Phase 0c checks whether containerd $ROLLBACK_CONTAINERD_VERSION can actually load it."
else
    BACKUP_DIR="${BACKUP_DIRS[-1]%/}"

    if [ "${#BACKUP_DIRS[@]}" -gt 1 ]; then
        echo -e "${YELLOW}${#BACKUP_DIRS[@]} backups exist:${NC}"
        for d in "${BACKUP_DIRS[@]}"; do
            if [ "${d%/}" = "$BACKUP_DIR" ]; then
                echo "    ${d%/}   <-- will be used (newest)"
            else
                echo "    ${d%/}"
            fi
        done
        echo ""
        echo "The newest backup is not necessarily the one belonging to the"
        echo "upgrade you are rolling back."
        echo ""
        if ! prompt_yes_no "Use the backup marked above? [Y/n]" "y"; then
            echo ""
            echo "Aborting. Nothing has been changed."
            echo "To use a different backup, copy its config.toml into place"
            echo "manually before re-running:"
            echo "  cp <backup>/config.toml /etc/containerd/config.toml"
            exit 0
        fi
    else
        echo "Using backup: $BACKUP_DIR"
    fi

    if [ ! -f "$BACKUP_DIR/config.toml" ]; then
        echo -e "${YELLOW}NOTE: $BACKUP_DIR has no config.toml.${NC}"
        echo "The existing containerd config will be kept as-is."
        BACKUP_DIR=""
    fi
fi

#############################################
# Phase 0c: containerd Config Version Guard
#############################################
echo ""
echo "=== Phase 0c: containerd Config Version ==="
CURRENT_PHASE="phase 0c (containerd config version)"

# containerd $ROLLBACK_CONTAINERD_VERSION loads config version 3 at most.
# containerd 2.3.3 -- what this node is being rolled back FROM -- generates
# version 4, and 2.2.1 refuses such a file outright:
#
#   containerd: failed to load TOML from /etc/containerd/config.toml:
#   expected containerd config version equal to or less than `3`, got `4`
#
# upgrade-docker.sh never writes a v4 file, but an operator who ran
# `containerd config default > /etc/containerd/config.toml` at any point after
# the upgrade has one. Left undetected, the downgrade succeeds and containerd
# then fails to start -- on the node that is already in trouble.
#
# So this is checked HERE, in phase 0c: docker and containerd are still running,
# nothing has been touched, and aborting costs nothing.
ROLLBACK_MAX_CONFIG_VERSION=3
CONTAINERD_CONF="/etc/containerd/config.toml"

# Read the top-level `version` key. The awk stops at the first [section] header
# so only top-level keys count. Prints nothing when the key is absent, which
# containerd treats as a legacy config and still loads.
read_config_version() {
    # Tolerate an optionally quoted value. containerd wants an integer here, so
    # `version = "4"` is not a config it would accept anyway -- but reading it
    # as 4 makes this guard FIRE, whereas failing to match would silently read
    # as "no version key" and wave the file through. Err toward firing.
    awk '/^[[:space:]]*\[/ { exit } { print }' "$1" 2>/dev/null \
        | sed -n "s/^[[:space:]]*version[[:space:]]*=[[:space:]]*['\"]\{0,1\}\([0-9][0-9]*\)['\"]\{0,1\}.*/\1/p" \
        | head -1
}

# A config is loadable by the rollback containerd when it has no version key at
# all, or a version at or below ROLLBACK_MAX_CONFIG_VERSION.
config_is_loadable() {
    local v
    # A missing file is not a loadable config. Without this, read_config_version
    # would return empty for it and the "no version key" case below would report
    # it as fine.
    [ -f "$1" ] || return 1
    v=$(read_config_version "$1")
    # An explicit `if` rather than `[ -z "$v" ] && return 0` -- readability only,
    # the two forms behave identically. Worth stating the real constraint though:
    # this is a PREDICATE, so it returns 1 for "not loadable", and under `set -e`
    # that aborts the script unless the call sits in a condition. Every call site
    # below is an if/elif, which is what makes it safe. Keep it that way.
    if [ -z "$v" ]; then
        return 0
    fi
    # A version wider than four digits is not a containerd config version, it is
    # a corrupt file. It also cannot be compared: bash's `[` handles 64-bit
    # integers only and prints "integer expression expected" on anything larger,
    # which would land a raw shell error in the middle of a rollback refusal.
    # Treat it as unreadable -- and for a rollback, unreadable means NOT
    # loadable, so the guard still fires.
    if [ "${#v}" -gt 4 ]; then
        return 1
    fi
    [ "$v" -le "$ROLLBACK_MAX_CONFIG_VERSION" ]
}

# Check the config containerd will ACTUALLY be asked to load after phase 3 --
# not simply whatever is on disk right now. Phase 3's logic is: restore the
# selected backup if there is one, otherwise keep the on-disk file, otherwise
# generate a default. Those are different files, and the guard has to follow the
# same branch phase 3 will.
#
# Checking only the on-disk file leaves a hole exactly where this guard claims
# cover: an absent or hand-moved config plus a backup that itself holds a v4
# file. Phase 3 would restore that backup and containerd would refuse it -- the
# precise outcome this phase exists to prevent.
#
# The generate-a-default case needs no check: it runs AFTER the phase 2
# downgrade, so it is the rollback containerd's own binary emitting its own
# version.
if [ -n "$BACKUP_DIR" ] && [ -f "$BACKUP_DIR/config.toml" ]; then
    EFFECTIVE_CONF="$BACKUP_DIR/config.toml"
    EFFECTIVE_DESC="the backup phase 3 will restore, $EFFECTIVE_CONF"
elif [ -f "$CONTAINERD_CONF" ]; then
    EFFECTIVE_CONF="$CONTAINERD_CONF"
    EFFECTIVE_DESC="$CONTAINERD_CONF"
else
    EFFECTIVE_CONF=""
    EFFECTIVE_DESC=""
fi

if [ -z "$EFFECTIVE_CONF" ]; then
    echo "No config and no backup. Phase 3 generates a default after the"
    echo "downgrade, so it will carry containerd $ROLLBACK_CONTAINERD_VERSION's own version."
elif config_is_loadable "$EFFECTIVE_CONF"; then
    echo "Will load: $EFFECTIVE_DESC"
    echo "Config version $(read_config_version "$EFFECTIVE_CONF" | grep . || echo unset) -- containerd $ROLLBACK_CONTAINERD_VERSION can load it."
else
    # Name a different backup that WOULD work, if one exists. Phase 0b only ever
    # selects the newest, so "the selected backup is bad" and "no usable config
    # exists anywhere" are different statements, and telling an operator the
    # second when the first is true sends them looking for a file they have.
    ALT_CONF=""
    shopt -s nullglob
    for d in /root/docker-backup-*/; do
        if [ -f "${d}config.toml" ] && config_is_loadable "${d}config.toml"; then
            ALT_CONF="${d}config.toml"
        fi
    done
    shopt -u nullglob

    BAD_VERSION=$(read_config_version "$EFFECTIVE_CONF" | grep . || echo "unreadable")

    echo ""
    echo -e "${RED}=========================================="
    echo "ERROR: CONFIG VERSION BLOCKS THIS ROLLBACK"
    echo -e "==========================================${NC}"
    echo ""
    echo "  Config that would be loaded: $EFFECTIVE_DESC"
    echo "  Its version:                 $BAD_VERSION"
    echo "  containerd $ROLLBACK_CONTAINERD_VERSION loads at most version $ROLLBACK_MAX_CONFIG_VERSION"
    echo ""
    echo "Downgrading now would succeed, and containerd would then refuse to"
    echo "start with:"
    echo ""
    echo "  failed to load TOML from $CONTAINERD_CONF: expected containerd"
    echo "  config version equal to or less than \`$ROLLBACK_MAX_CONFIG_VERSION\`, got \`$BAD_VERSION\`"
    echo ""
    echo -e "${GREEN}Nothing has been changed. This node is still running.${NC}"
    echo ""

    if [ -n "$ALT_CONF" ]; then
        echo "A DIFFERENT backup on this node does hold a usable config:"
        echo ""
        echo "  $ALT_CONF"
        echo ""
        echo "Put it in place and re-run:"
        echo "  cp $ALT_CONF $CONTAINERD_CONF"
        if [ -n "$BACKUP_DIR" ] && [ -f "$BACKUP_DIR/config.toml" ]; then
            echo ""
            echo "Phase 0b selects the NEWEST backup, which is the unusable one."
            echo "Move it aside so the copy above is what phase 3 restores:"
            echo "  mv $BACKUP_DIR/config.toml $BACKUP_DIR/config.toml.rejected"
        fi
    else
        echo "No usable config was found in any /root/docker-backup-* directory,"
        echo "so this script cannot fix it for you. To proceed, put a config that"
        echo "containerd $ROLLBACK_CONTAINERD_VERSION can read at $CONTAINERD_CONF, then re-run:"
        echo ""
        echo "  - restore a pre-upgrade copy, if you have one off this node, or"
        echo ""
        echo "  - hand-edit the file: set 'version = $ROLLBACK_MAX_CONFIG_VERSION' and remove any keys"
        echo "    that only exist in version 4. KEEP the top-level 'root' and"
        echo "    'state' values exactly as they are -- changing 'root' repoints"
        echo "    this node at a different containerd data directory."
    fi

    if [ -f "$EFFECTIVE_CONF" ]; then
        echo ""
        echo "  Top-level root currently configured:"
        awk '/^[[:space:]]*\[/ { exit } { print }' "$EFFECTIVE_CONF" 2>/dev/null \
            | sed -n 's/^[[:space:]]*root[[:space:]]*=/      root =/p' | head -1
    fi
    echo ""
    exit 1
fi

#############################################
# Phase 1: Stop Services
#############################################
echo ""
echo "=== Phase 1: Stop Services ==="
CURRENT_PHASE="phase 1 (stop services)"

SERVICES_STOPPED=true

echo "Stopping docker..."
systemctl stop docker docker.socket 2>/dev/null || true
sleep 2

echo "Stopping containerd..."
systemctl stop containerd 2>/dev/null || true
sleep 2

# Verify rather than assume. On a degraded node -- and this script only runs on
# degraded nodes -- a stop can genuinely fail, and rewriting packages under a
# live daemon is how a recoverable problem becomes an unrecoverable one.
#
# docker.socket is included deliberately: if it survives, anything touching the
# socket socket-activates dockerd again, mid-transaction.
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
    echo "Refusing to downgrade packages under a running daemon."
    echo "Investigate with: systemctl status docker docker.socket containerd"
    exit 1
fi

echo "Services confirmed stopped."

#############################################
# Phase 2: Downgrade Packages
#############################################
echo ""
echo "=== Phase 2: Downgrade Packages ==="
CURRENT_PHASE="phase 2 (downgrade packages)"

PKG_STATE="attempted"

# ONE transaction, not two. Splitting containerd.io and docker-ce into separate
# rpm invocations means a failure in the second leaves the node with a
# downgraded runtime under a newer engine. Resolving the whole set together
# closes that deterministic gap, and rpm -- not the argument order here --
# decides the actual install ordering from package dependencies.
#
# This is NOT atomic. rpm has no general rollback once execution begins: a
# failing scriptlet or an interruption can still leave partial state. That is
# what PKG_STATE="attempted" exists to communicate.
echo "Downgrading containerd.io to $ROLLBACK_CONTAINERD_VERSION and"
echo "docker-ce / docker-ce-cli to $ROLLBACK_DOCKER_VERSION (single transaction)..."
rpm -Uvh --oldpackage --replacepkgs "$CONTAINERD_RPM" "${DOCKER_RPMS[@]}"

PKG_STATE="installed"
echo "Packages downgraded."

#############################################
# Phase 3: containerd Config
#############################################
echo ""
echo "=== Phase 3: containerd Config ==="
CURRENT_PHASE="phase 3 (containerd config)"

# containerd 2.3.3 reads a version = 3 config and never rewrites it, so the
# file on disk after an upgrade is normally still the v3 file 2.2.1 wrote --
# valid here, nothing to migrate, nothing to restore.
#
# Phase 0c already proved this node's config is one containerd
# $ROLLBACK_CONTAINERD_VERSION can load, or that the backup selected below
# supplies one. That check ran before anything stopped; by the time control
# reaches here the question is settled.
#
# This deliberately does NOT regenerate a default config when no backup exists.
# Regenerating would discard a relocated `root` path, registry mirrors and
# runtime configuration -- the same hazard phase 6 of upgrade-docker.sh avoids.
# The existing file is correct; leave it alone.

# BACKUP_DIR was chosen and confirmed in phase 0b, before anything was touched.
if [ -n "$BACKUP_DIR" ] && [ -f "$BACKUP_DIR/config.toml" ]; then
    if cmp -s "$BACKUP_DIR/config.toml" /etc/containerd/config.toml 2>/dev/null; then
        echo "Config matches the pre-upgrade backup; leaving it in place."
    else
        echo "Restoring containerd config from $BACKUP_DIR..."
        cp /etc/containerd/config.toml "/etc/containerd/config.toml.pre-rollback" 2>/dev/null || true
        cp "$BACKUP_DIR/config.toml" /etc/containerd/config.toml
        echo "Config restored (previous saved as config.toml.pre-rollback)."
    fi
elif [ -f /etc/containerd/config.toml ]; then
    echo "No pre-upgrade backup found."
    echo "Keeping the existing config -- phase 0c confirmed containerd"
    echo "$ROLLBACK_CONTAINERD_VERSION can load it."
else
    # Safe to generate here specifically because the downgrade in phase 2 has
    # already happened: this is the ROLLBACK containerd's binary, so it emits a
    # config at its own version, not the newer one. Generating this before the
    # downgrade would write a version the downgraded binary cannot read.
    echo -e "${YELLOW}No config and no backup; generating a default.${NC}"
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml
fi

#############################################
# Phase 4: Restart Services (CORRECT ORDER)
#############################################
echo ""
echo "=== Phase 4: Restart Services ==="
CURRENT_PHASE="phase 4 (restart services)"

start_services
SERVICES_STOPPED=false

echo -e "${GREEN}Services started.${NC}"

#############################################
# Phase 5: Verification
#############################################
echo ""
echo "=== Phase 5: Verification ==="
CURRENT_PHASE="phase 5 (verification)"

echo "Docker version:"
docker version

echo ""
echo "containerd version:"
containerd --version

echo ""
echo "Installed packages:"
rpm -q docker-ce docker-ce-cli containerd.io

# Assert the downgrade actually landed, rather than trusting rpm's exit status.
echo ""
echo "Asserting rolled-back versions..."
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

assert_installed docker-ce     "$ROLLBACK_DOCKER_VERSION"
assert_installed docker-ce-cli "$ROLLBACK_DOCKER_VERSION"
assert_installed containerd.io "$ROLLBACK_CONTAINERD_VERSION"

if [ "$VERIFY_FAILED" -ne 0 ]; then
    echo ""
    echo -e "${RED}ERROR: rollback did not produce the expected versions.${NC}"
    echo "Services are running, but this node is NOT on $ROLLBACK_DOCKER_VERSION."
    exit 1
fi

echo ""
echo "Service status:"
systemctl is-active docker && echo "  docker: running"
systemctl is-active containerd && echo "  containerd: running"

echo ""
echo "Existing containers:"
docker ps -a

echo ""
echo "=========================================="
echo -e "${GREEN}ROLLBACK COMPLETE${NC}"
echo "=========================================="
echo ""
echo "Rolled back to:"
echo "  - docker-ce: $ROLLBACK_DOCKER_VERSION"
echo "  - containerd.io: $ROLLBACK_CONTAINERD_VERSION"
echo ""
echo "This node is back on the version the cluster ran before the upgrade."
echo "It can coexist with nodes already on 29.7.2: both are Docker 29.x engines"
echo "and speak the same Swarm protocol. The containerd difference (2.2.1 here"
echo "vs 2.3.3 there) is local to each node and does not cross the wire."
echo ""
echo "Investigate what went wrong before retrying the upgrade:"
echo "  /var/log/docker-upgrade.log"
echo "  journalctl -u containerd -u docker --no-pager -n 200"
echo ""
echo "For Swarm nodes, remember to reactivate from a manager:"
echo "  docker node update --availability active $(hostname)"
echo "=========================================="

#!/bin/bash
# rollback-docker.sh
# Emergency rollback: Docker 29.6.2 → 29.1.5
VERSION="2.0.0"
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
# before this upgrade. It stays inside the containerd 2.2.x line, so there is
# no config-format migration and no network-state reset involved.
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
echo "Docker Rollback: 29.6.2 → 29.1.5"
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
    systemctl start containerd

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
            echo -e "${RED}ERROR: containerd API never became responsive${NC}"
            return 1
        fi
    fi

    echo "  Verifying overlayfs snapshotter..."
    if ! ctr snapshots --snapshotter overlayfs ls &>/dev/null; then
        echo -e "${YELLOW}  Snapshotter not ready, restarting containerd...${NC}"
        systemctl restart containerd || true
        sleep 5
        if ! ctr snapshots --snapshotter overlayfs ls &>/dev/null; then
            echo -e "${RED}ERROR: overlayfs snapshotter is not usable${NC}"
            return 1
        fi
    fi
    echo "  containerd is fully ready."

    echo "Starting docker..."
    systemctl start docker

    if ! systemctl is-active docker &>/dev/null; then
        echo -e "${RED}ERROR: docker is not active after start${NC}"
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

# upgrade-docker.sh names backups docker-backup-YYYYmmdd-HHMMSS, so the glob's
# lexical ordering is already chronological -- the last element is the newest.
shopt -s nullglob
BACKUP_DIRS=(/root/docker-backup-*/)
shopt -u nullglob

BACKUP_DIR=""
if [ "${#BACKUP_DIRS[@]}" -eq 0 ]; then
    echo "No /root/docker-backup-* directories found."
    echo "The existing containerd config will be kept as-is (valid for 2.2.x)."
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

# 2.2.6 and 2.2.1 share config v3, so a config written under 2.2.6 is valid
# under 2.2.1. There is nothing to migrate and nothing to restore.
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
    echo "Keeping the existing config -- it is valid for containerd 2.2.x."
else
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
echo "It can coexist with nodes already on 29.6.2 -- both speak containerd"
echo "2.2.x gRPC, so a mixed 29.1.5/29.6.2 Swarm is supported."
echo ""
echo "Investigate what went wrong before retrying the upgrade:"
echo "  /var/log/docker-upgrade.log"
echo "  journalctl -u containerd -u docker --no-pager -n 200"
echo ""
echo "For Swarm nodes, remember to reactivate from a manager:"
echo "  docker node update --availability active $(hostname)"
echo "=========================================="

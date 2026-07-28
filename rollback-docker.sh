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
if ! rpm -Uvh --test --oldpackage "$CONTAINERD_RPM" "${DOCKER_RPMS[@]}" 2>&1; then
    echo ""
    echo -e "${RED}ERROR: rpm rejected the downgrade transaction (dry run).${NC}"
    echo "Nothing on this node has been changed. The output above says why."
    echo ""
    echo "Common cause: another installed package depends on the newer versions."
    echo "Inspect with: rpm -q --whatrequires containerd.io"
    exit 1
fi
echo -e "${GREEN}Transaction dry run passed.${NC}"

echo -e "${GREEN}Rollback payload validated.${NC}"

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
STILL_UP=""
systemctl is-active docker        &>/dev/null && STILL_UP="$STILL_UP docker"
systemctl is-active docker.socket &>/dev/null && STILL_UP="$STILL_UP docker.socket"
systemctl is-active containerd    &>/dev/null && STILL_UP="$STILL_UP containerd"

if [ -n "$STILL_UP" ]; then
    echo -e "${RED}ERROR: still active after stop:$STILL_UP${NC}"
    echo "Refusing to downgrade packages under a running daemon."
    echo "Investigate with: systemctl status$STILL_UP"
    exit 1
fi

echo "Services confirmed stopped."

#############################################
# Phase 2: Downgrade Packages
#############################################
echo ""
echo "=== Phase 2: Downgrade Packages ==="
CURRENT_PHASE="phase 2 (downgrade packages)"

# containerd.io first: docker-ce depends on it, and the engine must never be
# left newer than the runtime it talks to.
PKG_STATE="attempted"

# ONE transaction, not two. Splitting containerd.io and docker-ce into separate
# rpm invocations means a failure in the second leaves the node with a
# downgraded runtime under a newer engine -- a mixed state that is worse than
# either endpoint. rpm resolves the whole set together and either applies all
# of it or none of it. This is the same set the phase-0 dry run approved.
echo "Downgrading containerd.io to $ROLLBACK_CONTAINERD_VERSION and"
echo "docker-ce / docker-ce-cli to $ROLLBACK_DOCKER_VERSION (single transaction)..."
rpm -Uvh --oldpackage "$CONTAINERD_RPM" "${DOCKER_RPMS[@]}"

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

# upgrade-docker.sh names backups docker-backup-YYYYmmdd-HHMMSS, so the glob's
# lexical ordering is already chronological -- the last element is the newest.
shopt -s nullglob
BACKUP_DIRS=(/root/docker-backup-*/)
shopt -u nullglob

BACKUP_DIR=""
if [ "${#BACKUP_DIRS[@]}" -gt 0 ]; then
    BACKUP_DIR="${BACKUP_DIRS[-1]%/}"
    echo "Most recent backup: $BACKUP_DIR"
fi

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

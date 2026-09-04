#!/bin/bash
# recover-dnf.sh
# Run if dnf reports dependency issues after a failed upgrade
VERSION="1.3.0"
#
# This script helps recover from:
# - Broken package dependencies
# - Corrupted RPM database
# - Partial upgrades
# - Manual package removal issues

set -e

SCRIPT_NAME="$(basename "$0")"

# Pre-declared answer for the Option A question at the end of the run: "y",
# "n", or empty for "nobody said". Empty is what preserves today's behaviour
# exactly -- the question is asked, and a closed stdin skips it and exits 0.
RUN_OPTION_A=""

usage() {
    cat <<USAGE
$SCRIPT_NAME $VERSION

Usage: $SCRIPT_NAME [OPTIONS]

Diagnostic. It cleans the dnf caches, rebuilds the RPM database, reports what
is installed, and prints recovery commands. Then it offers to run Option A.

Options:
  --run-option-a, --no-run-option-a
                       Pre-answer the Option A question. Read the warning
                       below before passing --run-option-a.
  --help, -h           Show this help and exit.
  --version            Print the script version and exit.

With no options the behaviour is unchanged: the question is asked, and a
closed stdin skips Option A and exits 0. This script does NOT refuse
end-of-file the way the upgrade, rollback and cleanup scripts do -- it fails
open, in the safe direction, because declining Option A changes nothing.

WARNING: Option A runs dnf against a repository named docker-local, which
exists only on hosts that ran the simulation path. On a production air-gapped
node it stops docker and containerd and then fails. See docs/AGENT-RUNBOOK.md.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        # Contradictory answers are refused rather than resolved by order, the
        # same rule the gate flags follow: each states one fact, so a pair is
        # two incompatible claims and letting the last win is how a wrapper
        # appending a default silently overrides a deliberate answer.
        --run-option-a)
            if [ "$RUN_OPTION_A" = "n" ]; then
                echo "ERROR: --run-option-a and --no-run-option-a are contradictory" >&2
                exit 1
            fi
            RUN_OPTION_A="y"
            ;;
        --no-run-option-a)
            if [ "$RUN_OPTION_A" = "y" ]; then
                echo "ERROR: --run-option-a and --no-run-option-a are contradictory" >&2
                exit 1
            fi
            RUN_OPTION_A="n"
            ;;
        --help|-h) usage; exit 0 ;;
        --version) echo "$SCRIPT_NAME $VERSION"; exit 0 ;;
        *)
            echo "ERROR: unrecognised argument: $1" >&2
            echo "Try --help." >&2
            exit 1
            ;;
    esac
    shift
done

echo "=========================================="
echo "DNF Dependency Recovery"
echo "Script Version: $VERSION"
echo "Server: $(hostname)"
echo "Date: $(date)"
echo "=========================================="

#############################################
# Step 1: Clean all caches
#############################################
echo ""
echo "=== Step 1: Cleaning dnf caches ==="
dnf clean all
echo "Caches cleaned."

#############################################
# Step 2: Rebuild RPM database
#############################################
echo ""
echo "=== Step 2: Rebuilding RPM database ==="
rpm --rebuilddb
echo "RPM database rebuilt."

#############################################
# Step 3: Check for issues
#############################################
echo ""
echo "=== Step 3: Checking for dependency issues ==="
if dnf check; then
    echo "No dependency issues found."
else
    echo ""
    echo "WARNING: Dependency issues detected!"
    echo ""
fi

#############################################
# Step 4: Identify broken packages
#############################################
echo ""
echo "=== Step 4: Identifying potentially broken packages ==="
echo "Running rpm verification (may take a moment)..."
BROKEN_PKGS=$(rpm -Va --nofiles --nodigest 2>/dev/null | grep -E "(docker|containerd)" || true)
if [ -n "$BROKEN_PKGS" ]; then
    echo "Potentially broken Docker packages:"
    echo "$BROKEN_PKGS"
else
    echo "No obvious issues with Docker packages."
fi

#############################################
# Step 5: Show current Docker package state
#############################################
echo ""
echo "=== Step 5: Current Docker package state ==="
echo "Installed Docker-related packages:"
rpm -qa | grep -E "(docker|containerd)" | sort || echo "  (none found)"

#############################################
# Guided Recovery Options
#############################################
echo ""
echo "=========================================="
echo "RECOVERY OPTIONS"
echo "=========================================="
echo ""
echo "If issues persist, try these options in order:"
echo ""
echo "OPTION A: Re-run distro-sync (least disruptive)"
echo "  dnf distro-sync -y --disablerepo='*' --enablerepo=docker-local --allowerasing \\"
echo "      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
echo ""
echo "OPTION B: Force reinstall specific package"
echo "  dnf reinstall -y --disablerepo='*' --enablerepo=docker-local <package-name>"
echo ""
echo "OPTION C: Remove and reinstall all Docker packages (nuclear option)"
echo "  rpm -e --nodeps docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
echo "  dnf install -y --disablerepo='*' --enablerepo=docker-local \\"
echo "      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
echo ""
echo "OPTION D: Complete reset (last resort)"
echo "  1. Stop services:"
echo "     systemctl stop docker docker.socket containerd"
echo "  2. Remove all packages:"
echo "     rpm -e --nodeps \$(rpm -qa | grep -E '(docker|containerd)')"
echo "  3. Clean up directories (CAUTION: preserves data):"
echo "     rm -rf /var/lib/docker/network"
echo "     rm -rf /var/lib/docker/plugins"
echo "  4. Fresh install:"
echo "     dnf install -y --disablerepo='*' --enablerepo=docker-local \\"
echo "         docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
echo "  5. Start services:"
echo "     systemctl start containerd && sleep 3 && systemctl start docker"
echo ""
echo "=========================================="
echo "IMPORTANT NOTES"
echo "=========================================="
echo ""
echo "- The package is 'containerd.io' (Docker's), NOT 'containerd'"
echo "- Always stop docker BEFORE containerd"
echo "- Always start containerd BEFORE docker"
echo "- Backup /var/lib/docker before Option D"
echo ""

# Offer to run Option A automatically.
#
# `read` returns non-zero on EOF, and under `set -e` that killed this script
# with a bare exit 1 and no message -- after `dnf clean all` and
# `rpm --rebuilddb` had already run, leaving the operator with no indication
# that the diagnostic steps above had completed successfully.
#
# A pre-declared answer is used in place of the read, never in addition to it,
# so --no-run-option-a and a typed "n" reach the same branch below. The EOF
# arm is reached only when nobody answered, and is unchanged.
if [ -n "$RUN_OPTION_A" ]; then
    response="$RUN_OPTION_A"
    if [ "$response" = "y" ]; then
        echo "OPTION A: requested by --run-option-a."
    else
        echo "OPTION A: declined by --no-run-option-a."
    fi
else
    echo "Would you like to run OPTION A now? (y/N)"
    if ! read -r response; then
        echo ""
        echo "No input available (stdin closed). Skipping Option A."
        echo "The diagnostics above completed; run the commands manually if needed."
        exit 0
    fi
fi
if [[ "$response" =~ ^[Yy]$ ]]; then
    echo ""
    echo "Running Option A..."
    systemctl stop docker docker.socket 2>/dev/null || true
    systemctl stop containerd 2>/dev/null || true

    dnf distro-sync -y --disablerepo='*' --enablerepo=docker-local --allowerasing \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    systemctl start containerd
    sleep 3
    systemctl start docker

    echo ""
    echo "Recovery complete. Verifying..."
    docker version
    containerd --version
fi

#!/bin/bash
# /root/recover-dnf.sh
# Run if dnf reports dependency issues after a failed upgrade
#
# This script helps recover from:
# - Broken package dependencies
# - Corrupted RPM database
# - Partial upgrades
# - Manual package removal issues

set -e

echo "=========================================="
echo "DNF Dependency Recovery"
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

# Offer to run Option A automatically
echo "Would you like to run OPTION A now? (y/N)"
read -r response
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

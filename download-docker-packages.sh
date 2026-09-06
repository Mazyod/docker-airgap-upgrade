#!/bin/bash
# download-docker-packages.sh
# Run on the ONLINE RHEL 8 server to collect all packages needed for air-gapped upgrade
VERSION="2.3.2"
#
# This script downloads:
# - Docker 29.8.0 packages for RHEL 8 and RHEL 9
# - Rollback packages (29.1.5) for emergency recovery
# - NVIDIA Container Toolkit packages (for GPU servers)
# - All upgrade/rollback/recovery scripts
#
# Output: /opt/docker-upgrade-bundle.tar.gz (single artifact to transfer)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_BASE="/opt/docker-offline"
# A failed rebuild must not leave an older artifact looking ready to transfer.
rm -f /opt/docker-upgrade-bundle.tar.gz
# Check the checkout before downloading or replacing the extracted bundle.
for required in upgrade-docker.sh rollback-docker.sh recover-dnf.sh clean-swarm-networks.sh \
    README.md RUNBOOK.md docs/AGENT-RUNBOOK.md; do
    if [ ! -r "$SCRIPT_DIR/$required" ]; then
        echo "ERROR: required file $required missing or unreadable in $SCRIPT_DIR; bundle not created." >&2
        exit 1
    fi
done
rm -rf "$DEST_BASE"
mkdir -p "$DEST_BASE"/{rhel8,rhel9,nvidia,rollback-rhel8,rollback-rhel9}

echo "=========================================="
echo "Docker Offline Package Downloader"
echo "Script Version: $VERSION"
echo "Date: $(date)"
echo "=========================================="

# NOTE ON THE RELEASE SUFFIX in the filenames below. Every package here is "-1"
# except containerd.io, which is "-2". That is not a typo and it is not cosmetic:
# containerd.io 2.3.4 was published twice. -1 and -2 carry the same version, the
# same file list and the same Requires, and a different /usr/bin/runc -- 1.4.3 in
# -1, 1.5.1 in -2. Both exist upstream, so a mechanical version bump that leaves
# the suffix at "-1" downloads successfully and builds a bundle that
# upgrade-docker.sh phase 0 will refuse on the air-gapped server.
#
# Download one RPM into the current directory.
#
# -f is load-bearing: without it curl writes the server's 404 HTML body into a
# file named *.rpm and exits 0, so a typo'd version silently produces a bundle
# full of error pages that only fails on the air-gapped server. With -f the
# download fails here, where there is still a network to fix it from.
fetch_pkg() {
    local rel="$1" pkg="$2"
    echo "  Downloading: $pkg"
    if ! curl -fLO --retry 3 --retry-delay 2 \
        "https://download.docker.com/linux/rhel/${rel}/x86_64/stable/Packages/${pkg}"; then
        echo "ERROR: failed to download $pkg (rhel${rel})" >&2
        echo "       Check the version exists at:" >&2
        echo "       https://download.docker.com/linux/rhel/${rel}/x86_64/stable/Packages/" >&2
        exit 1
    fi
    echo "    ✓ $pkg"
}

echo ""
echo "=== Downloading Docker 29.8.0 packages ==="

# RHEL 8
echo ""
echo "Downloading RHEL 8 packages..."
cd "$DEST_BASE/rhel8"
for pkg in \
    docker-ce-29.8.0-1.el8.x86_64.rpm \
    docker-ce-cli-29.8.0-1.el8.x86_64.rpm \
    containerd.io-2.3.4-2.el8.x86_64.rpm \
    docker-buildx-plugin-0.37.0-1.el8.x86_64.rpm \
    docker-compose-plugin-5.5.1-1.el8.x86_64.rpm
do
    fetch_pkg 8 "$pkg"
done

# RHEL 9
echo ""
echo "Downloading RHEL 9 packages..."
cd "$DEST_BASE/rhel9"
for pkg in \
    docker-ce-29.8.0-1.el9.x86_64.rpm \
    docker-ce-cli-29.8.0-1.el9.x86_64.rpm \
    containerd.io-2.3.4-2.el9.x86_64.rpm \
    docker-buildx-plugin-0.37.0-1.el9.x86_64.rpm \
    docker-compose-plugin-5.5.1-1.el9.x86_64.rpm
do
    fetch_pkg 9 "$pkg"
done

# Rollback packages (IMPORTANT!)
echo ""
echo "=== Downloading rollback packages ==="

echo "Downloading RHEL 8 rollback packages..."
cd "$DEST_BASE/rollback-rhel8"
for pkg in \
    docker-ce-29.1.5-1.el8.x86_64.rpm \
    docker-ce-cli-29.1.5-1.el8.x86_64.rpm \
    containerd.io-2.2.1-1.el8.x86_64.rpm
do
    fetch_pkg 8 "$pkg"
done

echo ""
echo "Downloading RHEL 9 rollback packages..."
cd "$DEST_BASE/rollback-rhel9"
for pkg in \
    docker-ce-29.1.5-1.el9.x86_64.rpm \
    docker-ce-cli-29.1.5-1.el9.x86_64.rpm \
    containerd.io-2.2.1-1.el9.x86_64.rpm
do
    fetch_pkg 9 "$pkg"
done

# NVIDIA Container Toolkit (for GPU servers)
echo ""
echo "=== Downloading NVIDIA Container Toolkit ==="
cd "$DEST_BASE/nvidia"

# Add NVIDIA repo (correct URL as of 2024+)
# Note: Must disable repo_gpgcheck due to GPG signature issues
echo "Adding NVIDIA repository..."
curl -sL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo | \
    sed 's/repo_gpgcheck=1/repo_gpgcheck=0/g' | \
    tee /etc/yum.repos.d/nvidia-container-toolkit.repo

# Download with dependencies
echo "Downloading NVIDIA packages with dependencies..."
dnf download --resolve --destdir=. nvidia-container-toolkit || {
    echo "WARNING: Failed to download NVIDIA packages (may not be needed if no GPU servers)"
}

echo ""
echo "=== Verifying downloads ==="
echo ""
echo "RHEL 8 packages:"
ls -lh "$DEST_BASE/rhel8/"
echo ""
echo "RHEL 9 packages:"
ls -lh "$DEST_BASE/rhel9/"
echo ""
echo "Rollback RHEL 8:"
ls -lh "$DEST_BASE/rollback-rhel8/"
echo ""
echo "Rollback RHEL 9:"
ls -lh "$DEST_BASE/rollback-rhel9/"
echo ""
echo "NVIDIA packages:"
ls -lh "$DEST_BASE/nvidia/" 2>/dev/null || echo "  (none)"

# Verify RPM integrity.
#
# --nosignature disables signature verification while leaving the embedded
# package/header digest checks enabled. Plain `rpm -K` also verifies the GPG
# signature, which fails with NOKEY on any host that hasn't imported Docker's
# key -- that is not corruption, and treating it as such would make this check
# cry wolf. Digest failure IS corruption, and it is fatal here: a truncated RPM
# discovered on an air-gapped server is discovered too late.
#
# This detects transfer corruption, NOT publisher authenticity.
echo ""
echo "=== Verifying RPM integrity ==="
CORRUPT=0
for dir in rhel8 rhel9 rollback-rhel8 rollback-rhel9; do
    echo "Checking $dir..."
    for rpm in "$DEST_BASE/$dir"/*.rpm; do
        if [ -f "$rpm" ]; then
            if ! rpm -K --nosignature "$rpm" >/dev/null 2>&1; then
                echo "  ERROR: $rpm failed digest verification" >&2
                CORRUPT=$((CORRUPT + 1))
            fi
        fi
    done
done

if [ "$CORRUPT" -gt 0 ]; then
    echo ""
    echo "ERROR: $CORRUPT package(s) are corrupt. Delete $DEST_BASE and re-run." >&2
    exit 1
fi
echo "All packages passed digest verification."

# Record what is actually in the bundle, from RPM METADATA rather than from
# filenames -- the same rule upgrade-docker.sh phase 0 and
# tools/vm-bundle-manifest.sh follow. A filename is a claim; the header is the
# fact, and the two can disagree after a rename or a partial re-download.
#
# VERSION-RELEASE, not VERSION. containerd.io 2.3.4 exists as both -1 and -2
# with identical versions and different runc binaries, so a manifest that
# recorded only the version would not answer the one question an operator needs
# it to answer: which build is on this node?
#
# This file travels inside the tarball, so an air-gapped operator can read it
# with no network and no release notes.
echo ""
echo "=== Writing bundle manifest ==="
MANIFEST="$DEST_BASE/MANIFEST.txt"
{
    echo "Bundle manifest"
    echo "Built:  $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "By:     download-docker-packages.sh $VERSION"
    echo ""
    printf '%-14s  %-24s  %-18s  %s\n' "DIRECTORY" "PACKAGE" "VERSION-RELEASE" "ARCH"
    for dir in rhel8 rhel9 rollback-rhel8 rollback-rhel9 nvidia; do
        [ -d "$DEST_BASE/$dir" ] || continue
        shopt -s nullglob
        for rpmfile in "$DEST_BASE/$dir"/*.rpm; do
            meta=$(rpm -qp --queryformat '%{NAME} %{VERSION}-%{RELEASE} %{ARCH}' \
                "$rpmfile" 2>/dev/null || echo "")
            if [ -z "$meta" ]; then
                # Unreadable header. Say so rather than omitting the row: a
                # short manifest reads as a short bundle.
                printf '%-14s  %-24s  %-18s  %s\n' "$dir" "${rpmfile##*/}" "UNREADABLE" "?"
                continue
            fi
            read -r m_name m_evr m_arch <<< "$meta"
            printf '%-14s  %-24s  %-18s  %s\n' "$dir" "$m_name" "$m_evr" "$m_arch"
        done
        shopt -u nullglob
    done
} > "$MANIFEST"
cat "$MANIFEST"

# Copy scripts into bundle
echo ""
echo "=== Including scripts ==="
# A missing script is fatal, not a warning. The completion summary below claims
# every script shipped; letting one silently go missing hands the operator a
# bundle that is short a recovery tool exactly when they need it.
MISSING_SCRIPTS=0
for script in upgrade-docker.sh rollback-docker.sh recover-dnf.sh clean-swarm-networks.sh; do
    if [ -f "$SCRIPT_DIR/$script" ]; then
        cp "$SCRIPT_DIR/$script" "$DEST_BASE/"
        chmod +x "$DEST_BASE/$script"
        echo "  ✓ $script"
    else
        echo "  ERROR: $script not found in $SCRIPT_DIR" >&2
        MISSING_SCRIPTS=$((MISSING_SCRIPTS + 1))
    fi
done

if [ "$MISSING_SCRIPTS" -gt 0 ]; then
    echo ""
    echo "ERROR: $MISSING_SCRIPTS script(s) missing from $SCRIPT_DIR." >&2
    echo "       Run this from a full checkout of the repo. Bundle not created." >&2
    exit 1
fi

# Operator documentation travels WITH the bundle. On an air-gapped server the
# tarball is all there is -- there is no repo to read the runbook from, and no
# internet to fetch it. Missing instructions make this an incomplete bundle.
echo ""
echo "=== Including operator documentation ==="
for doc in RUNBOOK.md README.md docs/AGENT-RUNBOOK.md; do
    if [ -f "$SCRIPT_DIR/$doc" ]; then
        cp "$SCRIPT_DIR/$doc" "$DEST_BASE/"
        echo "  ✓ $doc"
    else
        echo "  ERROR: $doc not found in $SCRIPT_DIR; bundle not created." >&2
        exit 1
    fi
done

# Create final bundle
echo ""
echo "=== Creating bundle ==="
cd /opt
rm -f docker-upgrade-bundle.tar.gz
tar czvf docker-upgrade-bundle.tar.gz docker-offline/

echo ""
echo "=========================================="
echo "DOWNLOAD COMPLETE"
echo "=========================================="
echo ""
echo "Bundle ready: /opt/docker-upgrade-bundle.tar.gz"
echo "Size: $(du -h /opt/docker-upgrade-bundle.tar.gz | cut -f1)"
echo ""
echo "Contents:"
echo "  - Docker 29.8.0 / containerd.io 2.3.4-2 packages (RHEL 8 & 9), runc 1.5.1"
echo "  - Rollback packages (29.1.5 / containerd.io 2.2.1)"
echo "  - NVIDIA Container Toolkit"
echo "  - upgrade-docker.sh"
echo "  - rollback-docker.sh"
echo "  - recover-dnf.sh"
echo "  - clean-swarm-networks.sh"
echo "  - MANIFEST.txt (every package by NAME and VERSION-RELEASE)"
echo "  - README.md, RUNBOOK.md, AGENT-RUNBOOK.md"
echo ""
echo "On air-gapped server:"
echo "  tar xzf docker-upgrade-bundle.tar.gz -C /opt"
echo "  cd /opt/docker-offline && ./upgrade-docker.sh"
echo "=========================================="

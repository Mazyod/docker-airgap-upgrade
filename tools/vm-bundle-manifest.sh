#!/bin/bash
# tools/vm-bundle-manifest.sh
# Runs INSIDE a Linux machine that has `rpm`. Emits a Markdown manifest of
# everything in a built bundle, for the GitHub release notes.
#
# The package table is generated from RPM METADATA, never from filenames. A
# release note that enumerates versions is a claim about what an operator will
# actually install, so it has to come from the packages themselves -- the same
# rule upgrade-docker.sh phase 0 follows.
#
# Usage (inside the VM):
#   ./vm-bundle-manifest.sh /opt/docker-upgrade-bundle.tar.gz

set -euo pipefail

BUNDLE="${1:-/opt/docker-upgrade-bundle.tar.gz}"
# Optional: the name the artifact will carry on the release. The reader
# downloads THAT name, so the Artifact table must show it -- not the
# VM-internal build path.
DISPLAY_NAME="${2:-$(basename "$BUNDLE")}"

if [ ! -f "$BUNDLE" ]; then
    echo "ERROR: bundle not found: $BUNDLE" >&2
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
tar xzf "$BUNDLE" -C "$WORK"
ROOT="$WORK/docker-offline"

if [ ! -d "$ROOT" ]; then
    echo "ERROR: bundle does not contain docker-offline/" >&2
    exit 1
fi

# Human label for each directory in the bundle.
label_for() {
    case "$1" in
        rhel8)          echo "Upgrade — RHEL 8" ;;
        rhel9)          echo "Upgrade — RHEL 9" ;;
        rollback-rhel8) echo "Rollback — RHEL 8" ;;
        rollback-rhel9) echo "Rollback — RHEL 9" ;;
        nvidia)         echo "NVIDIA Container Toolkit" ;;
        *)              echo "$1" ;;
    esac
}

emit_dir() {
    local dir="$1" path="$ROOT/$1"
    shopt -s nullglob
    local rpms=("$path"/*.rpm)
    shopt -u nullglob
    [ "${#rpms[@]}" -eq 0 ] && return 0

    echo "### $(label_for "$dir")"
    echo ""
    echo "| Package | Version | Release | Arch |"
    echo "|---|---|---|---|"
    local f
    for f in "${rpms[@]}"; do
        rpm -qp --queryformat '| %{NAME} | %{VERSION} | %{RELEASE} | %{ARCH} |\n' "$f" 2>/dev/null \
            || echo "| ${f##*/} | ? | ? | ? |"
    done | sort
    echo ""
}

for d in rhel8 rhel9 rollback-rhel8 rollback-rhel9 nvidia; do
    emit_dir "$d"
done

echo "### Scripts and documentation in the bundle"
echo ""
echo "| File | Version |"
echo "|---|---|"
shopt -s nullglob
for f in "$ROOT"/*.sh; do
    v=$(grep -m1 '^VERSION="' "$f" | sed 's/^VERSION="\(.*\)"/\1/' || true)
    echo "| ${f##*/} | ${v:-—} |"
done
for f in "$ROOT"/*.md; do
    echo "| ${f##*/} | — |"
done
shopt -u nullglob
echo ""

echo "### Artifact"
echo ""
echo "| | |"
echo "|---|---|"
echo "| File | \`$DISPLAY_NAME\` |"
echo "| Size | $(du -h "$BUNDLE" | cut -f1)iB ($(stat -c %s "$BUNDLE") bytes) |"
echo "| SHA-256 | \`$(sha256sum "$BUNDLE" | cut -d' ' -f1)\` |"
echo "| RPMs | $(find "$ROOT" -name '*.rpm' | wc -l | tr -d ' ') |"
echo ""

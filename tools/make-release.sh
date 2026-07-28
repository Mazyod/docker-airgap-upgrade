#!/bin/bash
# shellcheck disable=SC2016,SC1091  # single-quoted VM commands must expand INSIDE the VM
# tools/make-release.sh
# Cut a GitHub release: one tag, one artifact, one enumeration of exactly what
# ships. This is the standing practice -- see docs/RELEASING.md.
#
# The artifact is the COMPLETE bundle: every RPM for RHEL 8 and 9, the rollback
# set, the NVIDIA packages, all operator scripts, and the runbook. An operator
# should be able to download one file, carry it to an air-gapped server, and
# have everything they need.
#
# The bundle is always REBUILT from the current checkout rather than reused.
# Shipping a stale bundle -- one whose embedded scripts predate the fixes in
# the tag being released -- is the failure mode this guards against.
#
# Usage:
#   tools/make-release.sh v29.6.2-1
#   tools/make-release.sh v29.6.2-1 --draft
#   tools/make-release.sh v29.6.2-1 --reuse-bundle   # skip the rebuild (fast, for retries)

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
REPO_DIR="$(pwd)"

# shellcheck source=../tests/vm/lib.sh
source tests/vm/lib.sh

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
die() { echo "${RED}ERROR${NC}: $*" >&2; exit 1; }
step() { printf '\n%s==>%s %s\n' "$GREEN" "$NC" "$1"; }

TAG="${1:-}"
[ -z "$TAG" ] && die "usage: tools/make-release.sh <tag> [--draft] [--reuse-bundle]"
shift

DRAFT=false
REUSE_BUNDLE=false
for a in "$@"; do
    case "$a" in
        --draft)        DRAFT=true ;;
        --reuse-bundle) REUSE_BUNDLE=true ;;
        *) die "unknown option: $a" ;;
    esac
done

BUNDLE_VM="/opt/docker-upgrade-bundle.tar.gz"
OUT_DIR="$REPO_DIR/dist"
OUT_BUNDLE="$OUT_DIR/docker-upgrade-bundle-${TAG}.tar.gz"
NOTES="$OUT_DIR/release-notes-${TAG}.md"

#############################################
step "Preflight"
#############################################
command -v gh >/dev/null 2>&1 || die "gh CLI not installed (brew install gh)"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (gh auth login)"
need_orbctl
vm_exists || die "VM '$VM_NAME' not found. Run tests/vm/bootstrap-vm.sh first."

[ -n "$(git status --porcelain)" ] && die "working tree is dirty -- commit or stash first"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ "$BRANCH" = "main" ] || echo "${YELLOW}WARNING${NC}: releasing from '$BRANCH', not main"

git fetch origin >/dev/null 2>&1
AHEAD=$(git rev-list --count origin/"$BRANCH".."$BRANCH" 2>/dev/null || echo 0)
[ "$AHEAD" != "0" ] && die "$AHEAD local commit(s) not pushed -- push before releasing"

git rev-parse "$TAG" >/dev/null 2>&1 && die "tag $TAG already exists locally"
gh release view "$TAG" >/dev/null 2>&1 && die "release $TAG already exists on GitHub"

COMMIT=$(git rev-parse HEAD)
echo "  branch:  $BRANCH"
echo "  commit:  ${COMMIT:0:12}"
echo "  tag:     $TAG"
mkdir -p "$OUT_DIR"

#############################################
step "Static checks must pass before anything ships"
#############################################
if ! ./tests/static-checks.sh >/dev/null 2>&1; then
    ./tests/static-checks.sh 2>&1 | tail -20
    die "static checks failed -- not releasing"
fi
echo "  tests/static-checks.sh: PASSED"

#############################################
step "Building the bundle in the VM from THIS checkout"
#############################################
if [ "$REUSE_BUNDLE" = true ]; then
    echo "  --reuse-bundle: skipping rebuild"
    vm "test -f $BUNDLE_VM" || die "no existing bundle in the VM to reuse"
else
    vm "set -e
        rm -rf /root/scripts && mkdir -p /root/scripts
        cp $REPO_DIR/*.sh /root/scripts/
        cp $REPO_DIR/*.md /root/scripts/ 2>/dev/null || true
        chmod +x /root/scripts/*.sh" || die "failed to stage scripts into the VM"
    vm 'cd /root/scripts && ./download-docker-packages.sh' >/dev/null 2>&1 \
        || die "download-docker-packages.sh failed in the VM"
    echo "  bundle rebuilt"
fi

#############################################
step "Generating the package manifest from RPM metadata"
#############################################
vm "cp $REPO_DIR/tools/vm-bundle-manifest.sh /tmp/ && chmod +x /tmp/vm-bundle-manifest.sh" \
    || die "failed to stage the manifest script"
MANIFEST_MD=$(vm "/tmp/vm-bundle-manifest.sh $BUNDLE_VM") || die "manifest generation failed"
[ -z "$MANIFEST_MD" ] && die "manifest came back empty"
echo "  $(printf '%s' "$MANIFEST_MD" | grep -c '^|') table rows"

#############################################
step "Copying the artifact out of the VM"
#############################################
rm -f "$OUT_BUNDLE"
vm "cat $BUNDLE_VM" > "$OUT_BUNDLE" || die "failed to copy the bundle out"
[ -s "$OUT_BUNDLE" ] || die "copied bundle is empty"

VM_SHA=$(vm "sha256sum $BUNDLE_VM | cut -d' ' -f1" | tr -d '\r\n')
MAC_SHA=$(shasum -a 256 "$OUT_BUNDLE" | cut -d' ' -f1)
[ "$VM_SHA" = "$MAC_SHA" ] || die "checksum mismatch after copy (VM=$VM_SHA mac=$MAC_SHA)"
echo "  $(du -h "$OUT_BUNDLE" | cut -f1)  sha256 ${MAC_SHA:0:16}...  (verified end to end)"

#############################################
step "Composing release notes"
#############################################
{
    echo "Complete air-gapped upgrade package for Docker Engine on RHEL 8/9."
    echo ""
    echo "**Download the single artifact below** — it contains every RPM, all operator"
    echo "scripts, and the runbook. Nothing else is needed on the air-gapped side."
    echo ""
    echo "\`\`\`bash"
    echo "rm -rf /opt/docker-offline"
    echo "tar xzf $(basename "$OUT_BUNDLE") -C /opt/"
    echo "cd /opt/docker-offline && ./upgrade-docker.sh"
    echo "\`\`\`"
    echo ""
    echo "## Contents"
    echo ""
    printf '%s\n' "$MANIFEST_MD"
    echo "## Verify before use"
    echo ""
    echo "\`\`\`bash"
    echo "sha256sum -c <<< '$MAC_SHA  $(basename "$OUT_BUNDLE")'"
    echo "\`\`\`"
    echo ""
    echo "## Provenance"
    echo ""
    echo "| | |"
    echo "|---|---|"
    echo "| Commit | \`$COMMIT\` |"
    echo "| Built from | \`$BRANCH\` |"
    echo "| Bundle built on | $(vm 'cat /etc/os-release | sed -n "s/^PRETTY_NAME=\"\(.*\)\"/\1/p"' | tr -d '\r\n') |"
    echo ""
    if [ -f docs/TEST-PLAN.md ]; then
        echo "## Testing"
        echo ""
        sed -n '/^## Execution status/,/^## What each tier/p' docs/TEST-PLAN.md | sed '$d'
    fi
} > "$NOTES"
echo "  $NOTES ($(wc -l < "$NOTES" | tr -d ' ') lines)"

#############################################
step "Creating the GitHub release"
#############################################
GH_ARGS=(release create "$TAG" "$OUT_BUNDLE"
         --title "$TAG — Docker $TARGET_DOCKER / containerd.io $TARGET_CONTAINERD"
         --notes-file "$NOTES"
         --target "$COMMIT")
[ "$DRAFT" = true ] && GH_ARGS+=(--draft)

gh "${GH_ARGS[@]}" || die "gh release create failed"

echo ""
echo "=========================================="
echo "${GREEN}RELEASE $TAG PUBLISHED${NC}"
echo "=========================================="
gh release view "$TAG" --json url,name,isDraft \
    --template '{{.name}}{{if .isDraft}} (DRAFT){{end}}
{{.url}}
'
echo "Local copies:"
echo "  $OUT_BUNDLE"
echo "  $NOTES"

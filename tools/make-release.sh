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
#   tools/make-release.sh v29.8.0-1
#   tools/make-release.sh v29.8.0-1 --draft
#   tools/make-release.sh v29.8.0-1 --reuse-bundle   # skip the rebuild (fast, for retries)

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
REPO_DIR="$(pwd)"

# shellcheck source=../tests/vm/lib.sh
source tests/vm/lib.sh

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
die() { echo "${RED}ERROR${NC}: $*" >&2; exit 1; }
step() { printf '\n%s==>%s %s\n' "$GREEN" "$NC" "$1"; }

# harness_sha256_of (tests/vm/lib.sh) prefers sha256sum and falls back to
# `shasum -a 256`, because stock macOS has no sha256sum.
#
# It is called ONLY at its use site below, never through a wrapper. A wrapper
# that ends in `|| die` reads as fail-closed and is not: every call is inside a
# command substitution, so `die`'s `exit 1` kills the SUBSHELL and the parent
# carries on with an empty digest. With the VM-side digest empty too -- a guest
# whose sha256sum call failed -- "" = "" compared equal, the script printed
# "verified end to end", and the release notes shipped `sha256sum -c` with no
# digest in it. Check the status where the value is assigned.

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
command -v gh >/dev/null 2>&1 || die "gh CLI not installed (macOS: brew install gh; Linux: see cli.github.com)"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (gh auth login)"
# require_vm, not need_backend + vm_exists. vm_exists only asks whether a guest
# EXISTS: on the container backend that is `docker container inspect`, which
# succeeds for a STOPPED container, while every `vm` call below is `docker exec`,
# which refuses one. A host reboot therefore let this preflight pass and the run
# die later with "failed to stage scripts into the VM" -- or, under
# --reuse-bundle, with the flatly wrong "no existing bundle in the VM to reuse".
# require_vm also wakes the guest, and waking is where the repo bind mount is
# re-verified by content; the one path that publishes a bundle was the one path
# that never re-verified the guest is reading this checkout.
require_vm
echo "  backend: $HARNESS_BACKEND"

# Every git question below is asked with its STATUS checked. There is no
# errexit in this script, so `X=$(git ...)` swallows a failure and hands the
# next line an empty string -- and every one of these preflight questions reads
# an empty answer as permission to proceed: no output from `git status` looks
# like a clean tree, and a `git rev-list` that cannot resolve the remote looks
# like nothing to push.
DIRTY=$(git status --porcelain) || die "git status failed -- cannot tell whether the tree is clean"
[ -n "$DIRTY" ] && die "working tree is dirty -- commit or stash first"

BRANCH=$(git rev-parse --abbrev-ref HEAD) || die "could not determine the current branch"
[ -n "$BRANCH" ] || die "git reported an empty branch name"
[ "$BRANCH" = "main" ] || echo "${YELLOW}WARNING${NC}: releasing from '$BRANCH', not main"

git fetch origin >/dev/null 2>&1 || die "git fetch origin failed -- cannot check for unpushed commits"
git rev-parse --verify "origin/$BRANCH" >/dev/null 2>&1 \
    || die "origin/$BRANCH does not exist -- push the branch before releasing"
AHEAD=$(git rev-list --count "origin/$BRANCH..$BRANCH") \
    || die "could not count commits ahead of origin/$BRANCH"
[ "$AHEAD" != "0" ] && die "$AHEAD local commit(s) not pushed -- push before releasing"

git rev-parse "$TAG" >/dev/null 2>&1 && die "tag $TAG already exists locally"
gh release view "$TAG" >/dev/null 2>&1 && die "release $TAG already exists on GitHub"

COMMIT=$(git rev-parse HEAD) || die "could not resolve HEAD"
[ -n "$COMMIT" ] || die "git reported an empty commit id"
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
    # Content-verified per file. This is the path that PUBLISHES the bundle, so
    # "the guest is reading this checkout" has to be a fact rather than an
    # assumption -- a stale tree at the same absolute path would ship scripts
    # that predate the tag being released, which is the failure this whole
    # script is built to prevent.
    vm "rm -rf /root/scripts" || die "failed to clear /root/scripts in the VM"
    vm_cp_verified /root/scripts "$REPO_DIR"/*.sh "$REPO_DIR"/*.md \
        || die "failed to stage scripts into the VM"
    vm "chmod +x /root/scripts/*.sh" || die "failed to make the staged scripts executable"
    vm 'cd /root/scripts && ./download-docker-packages.sh' >/dev/null 2>&1 \
        || die "download-docker-packages.sh failed in the VM"
    echo "  bundle rebuilt"
fi

#############################################
step "Generating the package manifest from RPM metadata"
#############################################
vm_cp_verified /tmp "$REPO_DIR/tools/vm-bundle-manifest.sh" \
    || die "failed to stage the manifest script"
vm "chmod +x /tmp/vm-bundle-manifest.sh" || die "failed to make the manifest script executable"
MANIFEST_MD=$(vm "/tmp/vm-bundle-manifest.sh $BUNDLE_VM $(basename "$OUT_BUNDLE")") || die "manifest generation failed"
[ -z "$MANIFEST_MD" ] && die "manifest came back empty"
echo "  $(printf '%s' "$MANIFEST_MD" | grep -c '^|') table rows"

#############################################
step "Copying the artifact out of the VM"
#############################################
rm -f "$OUT_BUNDLE"
vm "cat $BUNDLE_VM" > "$OUT_BUNDLE" || die "failed to copy the bundle out"
[ -s "$OUT_BUNDLE" ] || die "copied bundle is empty"

# Both digests are checked for status AND for emptiness. An empty digest on
# both sides compares equal, which is the one way this verification can pass
# while proving nothing -- and the notes it feeds tell an operator to run
# `sha256sum -c` against a blank.
VM_SHA=$(vm "sha256sum $BUNDLE_VM | cut -d' ' -f1" | tr -d '\r\n') \
    || die "could not read the bundle checksum inside the VM"
[ -n "$VM_SHA" ] || die "the VM returned an empty bundle checksum"
HOST_SHA=$(harness_sha256_of "$OUT_BUNDLE") \
    || die "neither sha256sum nor shasum is available -- cannot verify the artifact"
[ -n "$HOST_SHA" ] || die "the host checksum of $OUT_BUNDLE came back empty"
[ "$VM_SHA" = "$HOST_SHA" ] || die "checksum mismatch after copy (VM=$VM_SHA host=$HOST_SHA)"
echo "  $(du -h "$OUT_BUNDLE" | cut -f1)  sha256 ${HOST_SHA:0:16}...  (verified end to end)"

#############################################
step "Composing release notes"
#############################################
# Read the provenance BEFORE the notes are composed, so a failed query dies here
# rather than publishing a release whose "Bundle built on" row is blank.
BUILD_HOST=$(vm 'cat /etc/os-release | sed -n "s/^PRETTY_NAME=\"\(.*\)\"/\1/p"' | tr -d '\r\n') \
    || die "could not read the guest's OS name for the provenance table"
[ -n "$BUILD_HOST" ] || die "the guest returned an empty OS name"

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
    echo ""
    echo "## Verify before use"
    echo ""
    echo "\`\`\`bash"
    echo "sha256sum -c <<< '$HOST_SHA  $(basename "$OUT_BUNDLE")'"
    echo "\`\`\`"
    echo ""
    echo "## Provenance"
    echo ""
    echo "| | |"
    echo "|---|---|"
    echo "| Commit | \`$COMMIT\` |"
    echo "| Built from | \`$BRANCH\` |"
    echo "| Bundle built on | $BUILD_HOST |"
    echo ""
    if [ -f docs/TEST-PLAN.md ]; then
        echo "## Testing"
        echo ""
        sed -n '/^## Execution status/,/^## What each tier/p' docs/TEST-PLAN.md \
            | sed '$d' | sed '1s/^## Execution status/### Execution status/'
    fi
} > "$NOTES"
echo "  $NOTES ($(wc -l < "$NOTES" | tr -d ' ') lines)"

#############################################
step "Creating the GitHub release"
#############################################
GH_ARGS=(release create "$TAG" "$OUT_BUNDLE"
         --title "$TAG — Docker $TARGET_DOCKER / containerd.io $TARGET_CONTAINERD-$TARGET_CONTAINERD_RELEASE"
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

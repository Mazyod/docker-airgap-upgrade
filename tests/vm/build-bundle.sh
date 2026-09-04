#!/bin/bash
# shellcheck disable=SC2016,SC1091  # single-quoted VM commands must expand INSIDE the VM
# tests/vm/build-bundle.sh
# Run the REAL download-docker-packages.sh inside the VM and record the
# resulting artifact's checksum.
#
# This is deliberately not a hand-staged directory of RPMs. Building the bundle
# with the shipped script is itself Tier 2 coverage: it exercises the download
# loops, the curl -f failure path, the digest verification, the missing-script
# guard, and the tar layout that every other script depends on.
#
# The recorded SHA-256 is the artifact identity. docs/TEST-PLAN.md requires the
# SAME artifact be used for every subsequent tier and for production.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source ./lib.sh

require_vm
REPO_DIR="$(cd ../.. && pwd)"

echo "=== Refreshing scripts in the VM from the repo ==="
# Content-verified, because the bundle this builds is what every later tier and
# every production node runs. See vm_cp_verified in lib.sh.
vm "rm -rf /root/scripts"
vm_cp_verified /root/scripts "$REPO_DIR"/*.sh
vm "chmod +x /root/scripts/*.sh"

echo ""
echo "=== Running download-docker-packages.sh (downloads ~333 MB) ==="
vm 'cd /root/scripts && ./download-docker-packages.sh' | tail -25

echo ""
echo "=== Artifact ==="
vm 'set -e
ls -lh /opt/docker-upgrade-bundle.tar.gz | awk "{print \"size:   \" \$5}"
echo "sha256: $(sha256sum /opt/docker-upgrade-bundle.tar.gz | cut -d" " -f1)"
sha256sum /opt/docker-upgrade-bundle.tar.gz > /root/bundle.sha256
echo ""
echo "contents:"
tar tzf /opt/docker-upgrade-bundle.tar.gz | grep -E "\.sh$|/$" | sed "s/^/  /"'

echo ""
echo "Bundle built and checksummed. Use tests/vm/tier2-run.sh next."

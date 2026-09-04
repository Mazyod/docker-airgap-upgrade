#!/bin/bash
# shellcheck disable=SC1091
# tests/vm/teardown-vm.sh
# Delete the test machine. The loopback image and all test state go with it.
#
# On the container backend this also removes the named data volume holding the
# 3 GB loopback image and sweeps any host loop device still backed by it --
# `--privileged` allocates loops from the HOST's global table, so leaving one
# attached is a real host-hygiene leak.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source ./lib.sh
need_backend
if vm_exists; then
    echo "Deleting VM '$VM_NAME' (backend: $HARNESS_BACKEND)..."
    vm_delete
    echo "Deleted."
else
    echo "VM '$VM_NAME' does not exist; nothing to do."
fi

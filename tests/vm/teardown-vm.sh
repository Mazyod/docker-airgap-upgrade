#!/bin/bash
# shellcheck disable=SC1091
# tests/vm/teardown-vm.sh
# Delete the test machine. The loopback image and all test state go with it.
#
# On the container backend the guest is only one of three host objects: there is
# also the named data volume holding the 3 GB loopback image and the built
# image. `vm_delete` removes all of them and then VERIFIES each is gone, so it
# runs unconditionally -- a missing container is no reason to leave a 3 GB
# volume behind.
#
# It also reports, without touching, any host loop device still backed by the
# harness image. `--privileged` allocates loops from the HOST's global table.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source ./lib.sh
need_backend

if vm_exists; then
    echo "Deleting VM '$VM_NAME' (backend: $HARNESS_BACKEND)..."
else
    echo "VM '$VM_NAME' does not exist; removing any leftover state anyway."
fi

if vm_delete; then
    echo "Deleted."
else
    echo "Teardown INCOMPLETE -- see the errors above." >&2
    exit 1
fi

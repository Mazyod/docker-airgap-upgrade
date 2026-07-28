#!/bin/bash
# shellcheck disable=SC1091
# tests/vm/teardown-vm.sh
# Delete the test machine. The loopback image and all test state go with it.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source ./lib.sh
need_orbctl
if vm_exists; then
    echo "Deleting VM '$VM_NAME'..."
    orbctl delete -f "$VM_NAME"
    echo "Deleted."
else
    echo "VM '$VM_NAME' does not exist; nothing to do."
fi

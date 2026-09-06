#!/bin/bash
# Real single-node recovery coverage. Leaves packages at target and removes its Swarm.
VERSION="1.0.0"
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck disable=SC1091 # shared harness lives beside this script
source ./lib.sh
echo "Swarm recovery checks $VERSION"
require_vm
require_relocated_xfs
# Refuse to take over a Swarm belonging to another test/session.
[ "$(vm "docker info --format '{{.Swarm.LocalNodeState}}'")" = inactive ] || {
    echo "Guest must start outside a Swarm." >&2; exit 1;
}
vm "docker image inspect alpine:3.19 >/dev/null"
vm_cp_verified /root/recovery-check "$HARNESS_REPO_DIR/upgrade-docker.sh"
vm "cp /root/recovery-check/upgrade-docker.sh /opt/docker-offline/recovery-test-upgrade.sh"
SCENARIOS="no-drain reactivate timeout"
case "${1:-}" in
    --mutant-no-wait)
        # Deliberate regression: the normal assertions below MUST exit nonzero.
        vm "sed -i 's/active) wait_for_services ;;/active) : ;;/' /opt/docker-offline/recovery-test-upgrade.sh"
        SCENARIOS="no-drain"
        ;;
    '') ;;
    *) echo "Usage: $0 [--mutant-no-wait]" >&2; exit 1 ;;
esac
cleanup() {
    swarm_leave
    vm_try "rm -f /opt/docker-offline/recovery-test-upgrade.sh" >/dev/null 2>&1
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
swarm_init
# The local image avoids pulling from any registry. Health readiness is separate
# from replica convergence; deterministic delayed counts are tested in fixtures.
vm "docker service create --detach --no-resolve-image --name recovery-canary \
    --health-cmd 'test -f /tmp/ready' --health-interval 1s --health-retries 30 \
    --health-start-period 20s alpine:3.19 sh -c 'sleep 8; touch /tmp/ready; exec sleep 3600'"

for scenario in $SCENARIOS; do
    flags='--no-drain-self'
    expected=converged
    if [ "$scenario" = reactivate ]; then flags='--drain-self --reactivate --no-proceed-with-tasks'; fi
    if [ "$scenario" = timeout ]; then
        expected=timeout
        vm "docker service create --detach --no-resolve-image --name recovery-pending \
            --constraint 'node.labels.recovery_missing==true' alpine:3.19 sleep 3600"
    fi
    sf="/tmp/recovery-$scenario.kv"
    echo "=== Real upgrade: $scenario ==="
    if vm "cd /opt/docker-offline && bash ./recovery-test-upgrade.sh --rerun-at-target \
        --non-interactive --status-file=$sf $flags > /tmp/recovery-$scenario.log 2>&1"; then
        ok "$scenario exits zero"
    else
        bad "$scenario upgrade failed"
        vm_try "tail -40 /tmp/recovery-$scenario.log"
        summary
        exit 1
    fi
    assert_status_complete "$scenario" "$sf"
    assert_status_key "$scenario" "$sf" result completed
    assert_status_key "$scenario" "$sf" workload_state "$expected"
    assert_status_key "$scenario" "$sf" node_availability_after active
    assert_pkg_profile "$scenario" target
    assert_vm_eq "$scenario docker active" "systemctl is-active docker" active
    assert_vm_eq "$scenario containerd active" "systemctl is-active containerd" active
    assert_vm_eq "$scenario canary data intact" \
        "docker start survivor >/dev/null; docker exec survivor cat /data/canary.txt" VOLUME-CANARY-DATA
    if [ "$scenario" = timeout ]; then
        assert_vm_eq "pending service remains unscheduled" \
            "docker service ls --filter name=recovery-pending --format '{{.Replicas}}'" 0/1
    else
        assert_vm_eq "$scenario service recovered" \
            "docker service ls --filter name=recovery-canary --format '{{.Replicas}}'" 1/1
    fi
done
summary

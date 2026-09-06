#!/bin/bash
# Prove the recovery fixtures reject regressions, without modifying the checkout.
VERSION="1.0.0"
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MUTANT_DIR=$(mktemp -d)
trap 'rm -rf "$MUTANT_DIR"' EXIT
echo "Recovery negative controls $VERSION"
bash "$REPO_DIR/tests/recovery-checks.sh" > "$MUTANT_DIR/baseline.log"
for mutant in skip-wait false-convergence false-timeout unknown-as-active drain-pause docs README-stage agent-stage stale-artifact startup; do
    mkdir -p "$MUTANT_DIR/docs" "$MUTANT_DIR/tests/vm"
    cp "$REPO_DIR/upgrade-docker.sh" "$REPO_DIR/download-docker-packages.sh" \
        "$REPO_DIR/README.md" "$REPO_DIR/RUNBOOK.md" "$MUTANT_DIR/"
    cp "$REPO_DIR/docs/AGENT-RUNBOOK.md" "$MUTANT_DIR/docs/"
    cp "$REPO_DIR/tests/vm/build-bundle.sh" "$MUTANT_DIR/tests/vm/"
    case "$mutant" in
        skip-wait) sed 's/active) wait_for_services ;;/active) : ;;/' "$MUTANT_DIR/upgrade-docker.sh" > "$MUTANT_DIR/changed" ;;
        false-convergence) sed 's/WORKLOAD_STATE="converged"/WORKLOAD_STATE="not-checked"/' "$MUTANT_DIR/upgrade-docker.sh" > "$MUTANT_DIR/changed" ;;
        false-timeout) sed 's/WORKLOAD_STATE="timeout"/WORKLOAD_STATE="converged"/' "$MUTANT_DIR/upgrade-docker.sh" > "$MUTANT_DIR/changed" ;;
        unknown-as-active) sed 's/\*) CURRENT_AVAILABILITY="unknown"/\*) CURRENT_AVAILABILITY="active"/' "$MUTANT_DIR/upgrade-docker.sh" > "$MUTANT_DIR/changed" ;;
        drain-pause) sed 's/active) wait_for_services/active|drain|pause) wait_for_services/' "$MUTANT_DIR/upgrade-docker.sh" > "$MUTANT_DIR/changed" ;;
        stale-artifact|startup)
            if [ "$mutant" = stale-artifact ]; then
                sed '\|^rm -f /opt/docker-upgrade-bundle.tar.gz$|d' "$MUTANT_DIR/download-docker-packages.sh" > "$MUTANT_DIR/changed"
            else
                sed '/^# Check the checkout/,/^done/s/exit 1/:/' "$MUTANT_DIR/download-docker-packages.sh" > "$MUTANT_DIR/changed"
            fi
            mv "$MUTANT_DIR/changed" "$MUTANT_DIR/download-docker-packages.sh"
            ;;
        docs)
            sed '/^# Operator documentation travels/,/^# Create final bundle/s/exit 1/:/' \
                "$MUTANT_DIR/download-docker-packages.sh" > "$MUTANT_DIR/changed"
            mv "$MUTANT_DIR/changed" "$MUTANT_DIR/download-docker-packages.sh"
            ;;
        README-stage|agent-stage)
            if [ "$mutant" = README-stage ]; then pattern='REPO_DIR/README.md'; else pattern='REPO_DIR/docs/AGENT-RUNBOOK.md'; fi
            sed "\|$pattern|d" "$MUTANT_DIR/tests/vm/build-bundle.sh" > "$MUTANT_DIR/changed"
            mv "$MUTANT_DIR/changed" "$MUTANT_DIR/tests/vm/build-bundle.sh"
            ;;
    esac
    if [ -f "$MUTANT_DIR/changed" ]; then mv "$MUTANT_DIR/changed" "$MUTANT_DIR/upgrade-docker.sh"; fi
    if RECOVERY_TEST_REPO="$MUTANT_DIR" bash "$REPO_DIR/tests/recovery-checks.sh" > "$MUTANT_DIR/$mutant.log" 2>&1; then
        echo "FAIL: $mutant escaped the checks" >&2; exit 1
    fi
    echo "PASS: $mutant rejected with nonzero exit"
done

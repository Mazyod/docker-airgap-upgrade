#!/bin/bash
# shellcheck disable=SC2016,SC1091  # single-quoted VM commands must expand INSIDE the VM
# tests/vm/negative-control.sh
# Prove that test 2.4 is a REAL regression test.
#
# A passing 2.4 only means something if it would FAIL against the old
# behaviour. This builds a one-line mutant of upgrade-docker.sh whose phase 6
# restores the pre-v2.0.0 line:
#
#     containerd config default > /etc/containerd/config.toml
#
# ...runs it against the same relocated-root baseline, and asserts the mutant
# DESTROYS the config. If the mutant does not destroy it, 2.4 proves nothing
# and this script fails loudly.
#
# A one-line mutant is used rather than the full v1.2.3 script because v1.2.3
# targets a different version pair (28.5.1 -> 29.1.5) and would change far more
# than the behaviour under test.
#
# This is DESTRUCTIVE: it deliberately wrecks the VM's containerd config. It
# resets the baseline before and after.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source ./lib.sh

require_vm

echo "=== Resetting to a known baseline first ==="
./reset-baseline.sh >/dev/null 2>&1

# The relocated root is the thing this test is about, so refuse to run on a
# baseline that does not have one.
require_relocated_xfs

# Stage the manifest writer HERE rather than assuming a previous bootstrap or
# reset left it in /tmp. If it were missing, BEFORE_ROOT would come back empty,
# the guard below would abort with a confusing "not in the expected
# relocated-root state" -- and if that guard ever loosened, every comparison
# downstream would silently be against the empty string.
stage_manifest_writer

BEFORE_SHA=$(vm_try "sha256sum /etc/containerd/config.toml | cut -d' ' -f1" | tail -1)
BEFORE_ROOT=$(vm_try "/tmp/vm-write-manifest.sh /tmp/nc-manifest.txt >/dev/null 2>&1; sed -n 's/^CONTAINERD_ROOT=//p' /tmp/nc-manifest.txt" | tail -1)
echo "  baseline config sha: ${BEFORE_SHA:0:16}..."
echo "  baseline root:       $BEFORE_ROOT"

if [ -z "$BEFORE_SHA" ] || [ "$BEFORE_ROOT" != "$RELOCATED_ROOT" ]; then
    echo "ERROR: baseline is not in the expected relocated-root state." >&2
    echo "       root='$BEFORE_ROOT' expected='$RELOCATED_ROOT'" >&2
    exit 1
fi

echo ""
echo "=== Building the mutant (phase 6 regenerates the config, as v1.2.3 did) ==="
vm 'set -e
cp /opt/docker-offline/upgrade-docker.sh /opt/docker-offline/upgrade-MUTANT.sh
python3 - <<PYEOF
import pathlib
p = pathlib.Path("/opt/docker-offline/upgrade-MUTANT.sh")
s = p.read_text()
# Anchor inside PHASE 6 specifically. The same `-f` test now also appears in
# preflight_report, which a plain "first occurrence" replace would hit -- and
# preflight_report does not run during a normal upgrade, so the mutant would
# change nothing and this control would report that the hazard is not real.
# That is exactly what happened once; scope the search instead.
phase6 = s.index("CURRENT_PHASE=" + chr(34) + "phase 6 (containerd config)" + chr(34))
anchor = """if [ ! -f "\$CONTAINERD_CONF" ]; then"""
i = s.find(anchor, phase6)
assert i != -1, "phase 6 anchor not found -- update this mutant"
# Reinstate the pre-v2.0.0 behaviour: unconditionally regenerate.
s = s[:i] + """containerd config default > "\$CONTAINERD_CONF"   # MUTANT: pre-v2.0.0 behaviour
""" + s[i:]
p.write_text(s)
print("mutant built")
PYEOF
chmod +x /opt/docker-offline/upgrade-MUTANT.sh
grep -n "MUTANT: pre-v2.0.0" /opt/docker-offline/upgrade-MUTANT.sh'

echo ""
echo "=== Running the mutant ==="
vm_try 'cd /opt/docker-offline && ./upgrade-MUTANT.sh </dev/null 2>&1' | tail -4

AFTER_SHA=$(vm_try "sha256sum /etc/containerd/config.toml | cut -d' ' -f1" | tail -1)
AFTER_ROOT=$(vm_try "awk '/^[[:space:]]*\[/ { exit } { print }' /etc/containerd/config.toml | sed -n \"s/^[[:space:]]*root[[:space:]]*=[[:space:]]*'\\(.*\\)'.*/\\1/p\" | head -1" | tail -1)

echo ""
head_ "Negative control result"
echo "  after config sha: ${AFTER_SHA:0:16}..."
echo "  after root:       $AFTER_ROOT"
echo ""

if [ "$AFTER_SHA" != "$BEFORE_SHA" ]; then
    ok "mutant CHANGED the containerd config (2.4's sha assertion would catch it)"
else
    bad "mutant did NOT change the config -- test 2.4 proves nothing"
fi

if [ "$AFTER_ROOT" != "$BEFORE_ROOT" ]; then
    ok "mutant LOST the relocated root: '$BEFORE_ROOT' -> '$AFTER_ROOT'"
    echo "       This is precisely the data-loss hazard v2.0.0 exists to prevent."
else
    bad "mutant kept the relocated root -- the hazard is not reproduced"
fi

echo ""
echo "=== Restoring the baseline ==="
vm "rm -f /opt/docker-offline/upgrade-MUTANT.sh" >/dev/null 2>&1
./reset-baseline.sh >/dev/null 2>&1
RESTORED=$(vm_try "sha256sum /etc/containerd/config.toml | cut -d' ' -f1" | tail -1)
if [ "$RESTORED" = "$BEFORE_SHA" ]; then
    ok "baseline restored"
else
    bad "baseline NOT restored -- run tests/vm/bootstrap-vm.sh --recreate"
fi

summary

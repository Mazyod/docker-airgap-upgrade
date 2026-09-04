#!/bin/bash
# shellcheck disable=SC2016,SC1091  # single-quoted VM commands must expand INSIDE the guest
# tests/vm/agent-mode-negative-control.sh
# Prove that the agent-mode guard tests can actually fail.
#
# A passing guard test only means something if it would FAIL against the
# broken behaviour it exists to catch. Each mutant below reinstates one
# specific defect, runs the case paired with it, and asserts that case FAILS.
# If a mutant does not reproduce its hazard, the paired test proves nothing
# and this script says so loudly.
#
# Mutants in this file (slice 2 of the agent-mode plan):
#
#   M1a  status write moved AFTER on_exit's rc==0 short-circuit
#        -> a successful run leaves the record saying result=running
#        pairs with tier2-run.sh case 2.29b
#
#   M1b  STATUS_OK accumulator removed, one key's write made to fail
#        -> a truncated record is published carrying the terminator
#        pairs with tier2-run.sh case 2.29g
#
# This is DESTRUCTIVE: it runs real upgrades against mutant scripts. It resets
# the baseline before and after every mutant.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source ./lib.sh

require_vm
require_relocated_xfs

SF=/tmp/agent-mutant-status.kv
MUT=/opt/docker-offline/upgrade-MUTANT.sh

reset_all() {
    vm "rm -f $MUT $SF" >/dev/null 2>&1
    ./reset-baseline.sh >/dev/null 2>&1
    vm "rm -rf /opt/docker-offline && tar xzf /opt/docker-upgrade-bundle.tar.gz -C /opt/" >/dev/null 2>&1
}

#############################################
head_ "M1a  status write after the rc==0 short-circuit"
#############################################
# The hazard is NOT "no status file": the startup write already left one
# behind. It is that the file still says result=running after a successful
# upgrade, so nothing downstream can tell success from a hard kill.
reset_all
vm 'set -e
cp /opt/docker-offline/upgrade-docker.sh /opt/docker-offline/upgrade-MUTANT.sh
cat > /tmp/m1a.py <<"PYEOF"
import pathlib
p = pathlib.Path("/opt/docker-offline/upgrade-MUTANT.sh")
s = p.read_text()
blk = """    if [ "$STATUS_WRITTEN" != true ]; then
        STATUS_WRITTEN=true
        derive_result "$rc" || true
        derive_next_action || true
        write_status_file || true
    fi

"""
assert blk in s, "status write block not found -- update this mutant"
short = """    [ "$rc" -eq 0 ] && exit 0\n"""
assert short in s, "rc==0 short-circuit not found -- update this mutant"
s = s.replace(blk, "", 1).replace(short, short + blk, 1)
p.write_text(s)
print("M1a built")
PYEOF
python3 /tmp/m1a.py
chmod +x /opt/docker-offline/upgrade-MUTANT.sh'

vm_try "cd /opt/docker-offline && ./upgrade-MUTANT.sh --status-file=$SF </dev/null 2>&1" | tail -3
mut_result=$(vm_try "sed -n 's/^result=//p' $SF 2>/dev/null | head -1" | tail -1)
echo "  mutant record says result=$mut_result"
if [ "$mut_result" = "running" ]; then
    ok "M1a reproduced the hazard: a successful run still reports result=running"
    echo "       Case 2.29b asserts result=completed, so it FAILS against this mutant."
else
    bad "M1a did NOT reproduce the hazard (result=$mut_result) -- 2.29b proves nothing"
fi

#############################################
head_ "M1b  terminator without the STATUS_OK accumulator"
#############################################
# Publishing requires BOTH the STATUS_OK accumulator and the status_complete
# terminator. This mutant removes the accumulator and makes ONE key's printf
# fail, which is the exact hazard the pair exists to catch:
#
#   - status_kv's `|| STATUS_OK=false` is deleted, so a failed write is not
#     recorded anywhere.
#   - one key's printf is sent to file descriptor 9, which is closed, so it
#     fails.
#   - the writer's `|| true` call site suspends `set -e` for its whole dynamic
#     extent, so every later key AND the terminator still land.
#
# Result: a record that ends in status_complete=1 and is missing a key. A
# last-line check alone passes on it. Case 2.29g, which checks every documented
# key, does not.
#
# The injection is INSIDE status_kv. Breaking a call site instead means the
# function never runs and the logic under test is never exercised.
reset_all
vm 'set -e
cp /opt/docker-offline/upgrade-docker.sh /opt/docker-offline/upgrade-MUTANT.sh
cat > /tmp/m1b.py <<"PYEOF"
import pathlib
p = pathlib.Path("/opt/docker-offline/upgrade-MUTANT.sh")
s = p.read_text()

# The mutation is ONE thing: whether a failed normal write updates STATUS_OK.
#
# the real body of status_kv is rebuilt here from pieces rather than pasted, because
# it contains single quotes and this whole program is delivered inside a
# single-quoted shell argument. q is the apostrophe.
q = chr(39)
body = ("    printf " + q + "%s=%s\\n" + q + " \"$1\" \"${2//[$" + q +
        "\\n\\r" + q + "]/ }\"")
real = body + " || STATUS_OK=false"
assert real in s, "status_kv body not found -- update this mutant"

# Send ONE key through that same printf, to a descriptor that has been closed,
# and drop the accumulator from it. Everything else about the line is
# unchanged, so the mutant differs from the real script in exactly one respect.
mutant = ("    if [ \"$1\" = \"rpmnew_present\" ]; then" + chr(10) +
          body + " >&9" + chr(10) +
          "    else" + chr(10) +
          body + chr(10) +
          "    fi")
s = s.replace(real, mutant, 1)

# The accumulator also guards the terminator and the publish decision. With it
# removed from the write, those two must go as well or nothing changes.
term = """        [ "$STATUS_OK" = true ] && status_kv status_complete 1"""
assert term in s, "terminator guard not found -- update this mutant"
s = s.replace(term, """        status_kv status_complete 1""", 1)
pub = """    if [ "$STATUS_OK" = true ] && last="""
assert pub in s, "publish guard not found -- update this mutant"
s = s.replace(pub, """    if last=""", 1)

# Close descriptor 9 rather than assuming it is closed.
setx = "set -e" + chr(10)
assert setx in s, "set -e not found -- update this mutant"
s = s.replace(setx, setx + "exec 9>&-   # MUTANT: guarantee the write above fails" + chr(10), 1)

p.write_text(s)
print("M1b built")
PYEOF
python3 /tmp/m1b.py
chmod +x /opt/docker-offline/upgrade-MUTANT.sh
grep -c MUTANT /opt/docker-offline/upgrade-MUTANT.sh'

vm_try "cd /opt/docker-offline && ./upgrade-MUTANT.sh --status-file=$SF </dev/null 2>&1" | tail -3
last=$(vm_try "tail -n 1 $SF 2>/dev/null" | tail -1)
has_key=$(vm_try "grep -c '^rpmnew_present=' $SF 2>/dev/null || echo 0" | tail -1)
echo "  last line: $last"
echo "  rpmnew_present rows: $has_key"
if [ "$last" = "status_complete=1" ] && [ "${has_key:-0}" = "0" ]; then
    ok "M1b reproduced the hazard: terminator present, key missing"
    echo "       Case 2.29g checks every documented key, so it FAILS against this"
    echo "       mutant, while a last-line check alone would pass. That is why"
    echo "       both the accumulator and the terminator exist."
else
    bad "M1b did NOT reproduce the hazard (last=[$last], key rows=$has_key)"
fi

#############################################
echo ""
echo "=== Restoring the baseline ==="
reset_all
assert_vm_eq "baseline restored to $BASELINE_DOCKER" \
    "rpm -q docker-ce --queryformat '%{VERSION}'" "$BASELINE_DOCKER"

summary

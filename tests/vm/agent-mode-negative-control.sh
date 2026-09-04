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
# Mutants in this file (slices 2, 3 and 4 of the agent-mode plan):
#
#   M1a  status write moved AFTER on_exit's rc==0 short-circuit
#        -> a successful run leaves the record saying result=running
#        pairs with tier2-run.sh case 2.29b
#
#   M1b  STATUS_OK accumulator removed, one selected key made to fail
#        -> a truncated record is published carrying the terminator
#        pairs with tier2-run.sh case 2.29g
#
#   M2   the hoisted relocated-root check deleted from preflight
#        -> preflight reports ready for a node the real run refuses in phase 6,
#           AFTER the rpm transaction and with services stopped
#        pairs with tier2-run.sh case 2.30c
#
#   M3   gate() falls through to prompt_yes_no under --non-interactive
#        -> a `yes y` stream answers every gate; the node is drained and
#           upgraded by a run that was supposed to refuse
#        pairs with tier2-run.sh case 2.32
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
head_ "M2  preflight without the hoisted relocated-root check"
#############################################
# Confirming only that the mutant reports "ready" would prove nothing: case
# 2.30c's untouched-state assertions still pass against it, because a preflight
# that gives the wrong answer still touches nothing. The hazard is what happens
# when an agent BELIEVES that answer, so this mutant follows the ready through
# into a real upgrade and asserts the hazard reproduces: packages replaced,
# services stopped, and the run aborted in phase 6.
#
# That is precisely the state the hoist exists to prevent, and it leaves the
# guest wrecked -- hence the reset immediately afterwards.
reset_all
vm 'set -e
cp /opt/docker-offline/upgrade-docker.sh /opt/docker-offline/upgrade-MUTANT.sh
cat > /tmp/m2.py <<"PYEOF"
import pathlib
p = pathlib.Path("/opt/docker-offline/upgrade-MUTANT.sh")
s = p.read_text()
# Delete only the hoisted check inside preflight_report. Phase 6 keeps its own,
# so the mutant still refuses -- just far too late to be free, which is the
# whole point.
start = s.index("    CONTAINERD_ROOT=$(read_containerd_root \"$CONTAINERD_CONF\")")
marker = "    if relocated_root_is_missing \"$CONTAINERD_ROOT\"; then"
i = s.index(marker, start)
j = s.index("    elif [ \"$CONTAINERD_ROOT\" != \"/var/lib/containerd\" ]; then", i)
s = s[:i] + "    if false; then   # MUTANT: hoisted relocated-root check deleted" + chr(10) + "        :" + chr(10) + s[j:]
p.write_text(s)
print("M2 built")
PYEOF
python3 /tmp/m2.py
chmod +x /opt/docker-offline/upgrade-MUTANT.sh
grep -c MUTANT /opt/docker-offline/upgrade-MUTANT.sh'

# Stage the hazard by pointing the config at an absent relocated root, with
# services left running. NOT by unmounting /data: the harness creates a shadow
# /data/containerd before it mounts and gives containerd RequiresMountsFor, so
# an unmount neither removes the directory nor survives a restart -- and
# starting containerd against that shadow root is itself the data-loss hazard.
# Armed before the fixture exists: an interrupted run would otherwise leave the
# node's containerd config pointing at a path that does not exist.
restore_m2_config() {
    vm "[ -f /etc/containerd/config.toml.m2 ] && mv -f /etc/containerd/config.toml.m2 /etc/containerd/config.toml; true" >/dev/null 2>&1 || true
}
# INT and TERM route through EXIT rather than running the handler and letting
# bash resume a destructive suite.
trap 'restore_m2_config' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
vm "set -e
    cp /etc/containerd/config.toml /etc/containerd/config.toml.m2
    sed -i \"s|^root = .*|root = '/data/absent-root-m2'|\" /etc/containerd/config.toml" >/dev/null 2>&1
m2_root=$(vm_try "sed -n \"s/^root = '\\(.*\\)'/\\1/p\" /etc/containerd/config.toml | head -1" | tail -1)
if [ "$m2_root" = "/data/absent-root-m2" ]; then
    ok "M2 staged an absent relocated root"
else
    bad "M2 staging failed (root='$m2_root') -- the mutant proves nothing"
fi

mut_rc=$(vm_try "cd /opt/docker-offline && ./upgrade-MUTANT.sh --preflight --status-file=$SF </dev/null >/dev/null 2>&1; echo \$?" | tail -1)
mut_result=$(vm_try "sed -n 's/^result=//p' $SF 2>/dev/null | head -1" | tail -1)
echo "  mutant preflight: exit $mut_rc, result=$mut_result"
if [ "$mut_rc" = "0" ] && [ "$mut_result" = "ready" ]; then
    ok "M2 mutant preflight reports READY on a node the real run refuses"
else
    bad "M2 mutant preflight did not report ready (exit $mut_rc, result=$mut_result)"
fi

echo ""
echo "=== Following that ready into a real run, as an agent would ==="
vm "rm -f $SF" >/dev/null 2>&1
vm_try "cd /opt/docker-offline && ./upgrade-MUTANT.sh --status-file=$SF </dev/null 2>&1" | tail -4
after_ph=$(vm_try "sed -n 's/^phase=//p' $SF 2>/dev/null | head -1" | tail -1)
after_reason=$(vm_try "sed -n 's/^refusal_reason=//p' $SF 2>/dev/null | head -1" | tail -1)
after_pkg=$(vm_try "sed -n 's/^pkg_state=//p' $SF 2>/dev/null | head -1" | tail -1)
after_ct=$(vm_try "rpm -q containerd.io --queryformat '%{VERSION}'" | tail -1)
d_state=$(vm_try "systemctl is-active docker || true" | tail -1)
s_state=$(vm_try "systemctl is-active docker.socket || true" | tail -1)
c_state=$(vm_try "systemctl is-active containerd || true" | tail -1)
echo "  after the run: phase=$after_ph reason=$after_reason pkg_state=$after_pkg"
echo "                 containerd.io=$after_ct docker=$d_state docker.socket=$s_state containerd=$c_state"
# Assert WHERE it failed, not merely that it failed. A partial phase-5 failure
# would also leave packages changed and services down, and reporting that as
# the phase-6 hazard would be a false positive for this whole mutant.
if [ "$after_ph" = "phase 6 (containerd config)" ] &&
   [ "$after_reason" = "relocated-root-missing" ] &&
   [ "$after_pkg" = "installed" ] &&
   [ "$after_ct" = "$TARGET_CONTAINERD" ] &&
   [ "$d_state" != "active" ] && [ "$s_state" != "active" ] && [ "$c_state" != "active" ]; then
    ok "M2 reproduced the hazard: refused in phase 6, packages replaced, services DOWN"
    echo "       That is the post-transaction, node-down state the hoist exists to"
    echo "       prevent. Case 2.30c asserts all five packages at baseline and both"
    echo "       services active, so it FAILS against this mutant."
else
    bad "M2 did NOT reproduce the phase-6 hazard exactly"
    echo "       wanted phase='phase 6 (containerd config)' reason=relocated-root-missing"
    echo "       pkg_state=installed containerd.io=$TARGET_CONTAINERD docker!=active"
fi
vm "mv -f /etc/containerd/config.toml.m2 /etc/containerd/config.toml" >/dev/null 2>&1


#############################################
head_ "M3  gate() falls through to prompt_yes_no under --non-interactive"
#############################################
# The pair that matters for slice 4. Per CLAUDE.md, a guard test asserting only
# the exit code proves nothing: a fall-through that drains and upgrades the
# node and then fails for an unrelated reason also exits non-zero. So this
# mutant reinstates the fall-through, runs it with a live `yes y` stream
# exactly as case 2.32 does, and asserts the HAZARD -- the node drained, the
# packages replaced -- rather than a status.
#
# Case 2.32 asserts all five packages at baseline and the node still `active`,
# so it FAILS against this mutant.
reset_all

# 2.32 runs on a Swarm manager: that is what arms the drain gate. Without the
# fixture the mutant reaches no gate at all and reproduces nothing.
# INT and TERM route through EXIT so a signal cannot run the handler and then
# let bash carry on with the guest still in a Swarm.
leave_swarm_m3() { vm_try "docker swarm leave --force" >/dev/null 2>&1 || true; }
trap 'leave_swarm_m3' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if swarm_init; then
    ok "M3 fixture: guest is a single-node Swarm manager"
else
    bad "M3 fixture: could not create the Swarm -- the mutant proves nothing"
fi
avail_before=$(node_availability)
if [ "$avail_before" = "active" ]; then
    ok "M3 fixture: node availability is active before the mutant runs"
else
    bad "M3 fixture: availability is '$avail_before', want active"
fi

vm 'set -e
cp /opt/docker-offline/upgrade-docker.sh /opt/docker-offline/upgrade-MUTANT.sh
cat > /tmp/m3.py <<"PYEOF"
import pathlib
p = pathlib.Path("/opt/docker-offline/upgrade-MUTANT.sh")
s = p.read_text()

# The mutation is ONE thing: whether --non-interactive stops control reaching
# prompt_yes_no. Everything else about gate() is untouched, so the mutant
# differs from the real script in exactly that respect.
q = chr(39)
real = ("""    if [ "$NON_INTERACTIVE" != true ]; then""" + chr(10) +
        """        # Explicit branches rather than a bare call plus `return`. Both forms""")
assert real in s, "gate() interactive branch not found -- update this mutant"
mutant = ("""    if true; then   # MUTANT: --non-interactive no longer bypasses the prompt""" +
          chr(10) +
          """        # Explicit branches rather than a bare call plus `return`. Both forms""")
s = s.replace(real, mutant, 1)
p.write_text(s)
print("M3 built")
PYEOF
python3 /tmp/m3.py
chmod +x /opt/docker-offline/upgrade-MUTANT.sh
grep -c MUTANT /opt/docker-offline/upgrade-MUTANT.sh'

vm "rm -f $SF" >/dev/null 2>&1
# EXACTLY case 2.32's invocation: --non-interactive, no gate flags, and a live
# `yes y` on stdin.
mut_rc=$(vm_try "cd /opt/docker-offline && yes y | ./upgrade-MUTANT.sh --non-interactive --status-file=$SF >/dev/null 2>&1; echo \$?" | tail -1)
mut_result=$(vm_try "sed -n 's/^result=//p' $SF 2>/dev/null | head -1" | tail -1)
mut_pkg=$(vm_try "sed -n 's/^pkg_state=//p' $SF 2>/dev/null | head -1" | tail -1)
mut_drain=$(vm_try "sed -n 's/^drain_performed=//p' $SF 2>/dev/null | head -1" | tail -1)
after_docker=$(vm_try "rpm -q docker-ce --queryformat '%{VERSION}'" | tail -1)
after_ct=$(vm_try "rpm -q containerd.io --queryformat '%{VERSION}'" | tail -1)
echo "  mutant run: exit $mut_rc result=$mut_result pkg_state=$mut_pkg drain_performed=$mut_drain"
echo "              docker-ce=$after_docker containerd.io=$after_ct"

# The hazard is the NODE, not the status. A mutant that answered the drain gate
# from the stream and then died would also exit non-zero.
if [ "$mut_drain" = "true" ] && [ "$mut_pkg" != "untouched" ] &&
   [ "$after_docker" = "$TARGET_DOCKER" ] && [ "$after_ct" = "$TARGET_CONTAINERD" ]; then
    ok "M3 reproduced the hazard: the yes stream answered the gates, node drained and upgraded"
    echo "       Case 2.32 asserts all five packages still at baseline and the node"
    echo "       still active, so it FAILS against this mutant. An exit-code check"
    echo "       would not have: this run exits 0."
else
    bad "M3 did NOT reproduce the hazard"
    echo "       wanted drain_performed=true, pkg_state!=untouched,"
    echo "       docker-ce=$TARGET_DOCKER containerd.io=$TARGET_CONTAINERD"
fi

leave_swarm_m3
sw=$(vm_try "docker info --format '{{.Swarm.LocalNodeState}}'" | tr -d '\r' | tail -1)
if [ "$sw" = "inactive" ]; then
    ok "M3 left the Swarm"
    # Disarmed only on success; see tier2-run.sh for why.
    trap - EXIT INT TERM
else
    bad "M3 could not leave the Swarm (state '$sw') -- leaving the EXIT trap armed"
fi

#############################################
echo ""
echo "=== Restoring the baseline ==="
reset_all
assert_vm_eq "baseline restored to $BASELINE_DOCKER" \
    "rpm -q docker-ce --queryformat '%{VERSION}'" "$BASELINE_DOCKER"

summary

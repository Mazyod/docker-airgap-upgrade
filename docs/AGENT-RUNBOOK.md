# Agent Runbook — operating a node

Operating guide for a non-human operator. If you are changing these scripts rather than
running them, read `CLAUDE.md`; nothing here is about editing.

**Sections one to five are the whole procedure for an upgrade**, which is the only thing you
should be doing routinely. Follow them and you do not need to read further. The **rollback** and
the **network cleanup** are remedies, not steps: each has its own section in the Reference, and
you go there when the decision table or a human sends you. `RUNBOOK.md` has the node ordering
and the soak timings between nodes; nothing here repeats them.

## 1. The standing rule

**Never assert a fact you have not verified.** Every flag states one fact you are accountable
for, not a preference. `--assume-drained` asserts that a manager drained this node; it drains
nothing. The record writes `drain_attested_by=flag`, so an audit can tell a flag that was
trusted from a question a human answered.

- **Preflight every node, and gate on `result`.** Only `ready` means go.
- **Gate on the record, never on the exit code.** Exit 1 covers both a safe refusal and a
  failure after the node was modified, and only the record separates them. That is why
  `--non-interactive` refuses to run without `--status-file`.
- **Never pass a flag to make a refusal go away.** `gate-unanswered:<name>` is a question, not
  an obstacle. If you cannot verify the fact, answer no, or report and stop.

A refused upgrade costs a maintenance window. An upgrade that proceeds on a false attestation
costs whatever was running on the node.

## 2. Before you start

Run as root, from the extracted bundle directory `/opt/docker-offline`. Extract into an **empty**
directory — `rm -rf /opt/docker-offline` first, then extract into `/opt`. The previous bundle has
an identical layout, so leftovers read as duplicate packages and the run is refused.

Know whether this node is a Swarm manager or a worker, and have manager access either way.
Workers cannot drain or inspect themselves. From a manager, run `docker node ls` to
identify the topology. A single-node Swarm has no other node to run its workloads;
a single manager with workers is a different topology. Record `docker service ls`
before maintenance so existing replica shortfalls are not mistaken for new failures.

**Record two things nothing on the node captures for you**, the availability and the containerd
root:

```bash
docker node inspect <node-hostname> --format '{{.Spec.Availability}}'   # RECORD THIS

root=$(awk '/^[[:space:]]*\[/ { exit } { print }' /etc/containerd/config.toml \
  | sed -n "s/^[[:space:]]*root[[:space:]]*=[[:space:]]*['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}.*/\1/p" \
  | head -1)
echo "containerd root: ${root:-/var/lib/containerd}"                    # RECORD THIS
findmnt --target "${root:-/var/lib/containerd}"
```

An absent `root` key means the default, `/var/lib/containerd`. A plain `grep '^root'` misses an
indented top-level key, which the script deliberately accepts, and says nothing when the key is
absent.

**Do not pre-drain an active manager.** Phase 0 validates the payload and dry-runs the rpm
transaction *before* it drains, precisely so a bad bundle cannot leave a manager drained;
pre-draining throws that ordering away. When draining is appropriate, let the script
do it with `--drain-self`. For an active single-node Swarm with an authorized workload
and control-plane outage, use `--no-drain-self`; draining cannot migrate tasks elsewhere.

Two node kinds need work from a manager first, and neither is an active manager:

- A **worker** cannot drain itself, so drain it and confirm it is empty. Accept that a phase-0
  refusal then leaves it drained, and restore it if you are not retrying.
- A manager **already in `drain` or `pause`** stays as it is — do not re-drain it — but the
  script skips its own drain *and its task count* on a node that is not `active`, so nothing
  will check emptiness unless you do.

```bash
docker node update --availability drain <node-hostname>       # the worker case only
docker node ps <node-hostname> --filter desired-state=running --format '{{.Name}}'
```

Poll the second command until it prints **nothing at all**. Without `--format` it prints a
header even when there are no tasks, so "looks empty" is not empty. Do not proceed on a timer.

## 3. The upgrade, one node

One node at a time, least critical first, with a soak between nodes; `RUNBOOK.md` has the
timings. Use a **fresh status-file path for every run** — a usage error leaves the previous
run's record in place at a reused path.

```bash
cd /opt/docker-offline

# Preflight. Read result: ready means go, refused sends you to section 4, and
# nothing-to-do (exit 3) means this node is already at the target -- move on.
./upgrade-docker.sh --preflight --non-interactive --status-file=/run/pre-$(date +%s).kv \
    <the gate flags for this node>

# The real run. Same gate flags, fresh status file.
./upgrade-docker.sh --non-interactive --status-file=/run/up-$(date +%s).kv \
    <the gate flags for this node>
```

The gate flags, by role and by the availability you recorded:

| Node | Gate flags |
|---|---|
| Not in a Swarm | none |
| **Worker**, drained from a manager and confirmed empty | `--assume-drained` |
| **Manager** recorded `active`, with other eligible nodes | `--drain-self --reactivate`, plus `--proceed-with-tasks` or `--no-proceed-with-tasks` |
| **Manager** already `drain` | `--reactivate` if you recorded `active`, otherwise `--no-reactivate`. The run does not re-drain or re-count tasks, so confirm it is empty yourself first |
| **Manager** already `pause` | none. Both the drain and the reactivation are skipped on a paused node |
| **Manager** recorded `active`, single-node Swarm or another authorized no-drain outage | `--no-drain-self` |

**Answer `--proceed-with-tasks` explicitly when using `--drain-self`.** It is a
conditional gate: an unanswered gate can stop the run after draining.
`--no-proceed-with-tasks` stops if tasks remain assigned here with desired state
running, or the query fails. An empty local query does not prove tasks are running
elsewhere. This gate is not reached on an active manager using `--no-drain-self`.

For an **active single-node Swarm**, with the outage authorized:

```bash
./upgrade-docker.sh --preflight --non-interactive --no-drain-self \
    --status-file=/run/pre-single-$(date +%s).kv
# Read the record; run the next command only when result=ready.
./upgrade-docker.sh --non-interactive --no-drain-self \
    --status-file=/run/up-single-$(date +%s).kv
```

**Verify runtime health, restore recorded availability, then observe workload recovery.**
Do this after `result=completed`; failures go to section 4.

```bash
systemctl is-active containerd docker
docker version
rpm -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
docker ps -a
# From a manager, for Swarm nodes only:
docker node ls
docker node inspect <node-hostname> --format '{{.Spec.Availability}}'
# Only if availability differs from what you recorded:
docker node update --availability <the value you recorded> <node-hostname>
```

Re-run the containerd-root extraction above and confirm it still reports the path you recorded.
Compare the installed versions against **this run's** record — `docker_ce_expected`,
`containerd_io_expected` and `containerd_io_release_expected` — never against a version you
remember. The release matters as much as the version: the same containerd version has been
published more than once with a different `runc` inside.

`active` goes back to `active`, `pause` back to `pause`, `drain` back to `drain`; never default
to `active`. A manager that passed `--reactivate` is already back, a worker always needs this
done from a manager, and `node_availability_after` and `drain_performed` say what the run did.

The script polls cluster-wide Swarm replica counts for up to 60 seconds when its
manager finishes `active`, including the no-drain path. `workload_state=converged`
means running and desired counts matched; it does not prove application health.
`Starting` tasks and `0/1` counts just after restart can be transient. `timeout`
means the last observation still had a mismatch; `unknown` means recovery could
not be established. Neither changes a completed package upgrade into a failure.
`not-checked` means no recovery observation ran (including workers and managers
left drained/paused). Check those workloads from a manager after restoring availability.

```bash
# From a manager: repeat every 5 seconds until counts recover or the deadline expires.
docker service ls
docker service ps --no-trunc <service-name>
```

Use a bounded recovery window: 60 seconds initially, or a longer window agreed
before maintenance for slow-starting workloads. Compare with the pre-upgrade state;
distinguish tasks progressing through `Starting` from repeated failures or rejected
tasks. At the deadline, report pending services and task errors, and inspect
`journalctl -u docker --since '-5 minutes'` on the affected node. Do not automatically
roll back or run network cleanup for a replica shortfall. Confirm application access
and expected persistent data before proceeding to the next node.

## 4. The decision table

Read this from the status file. Its last line is always `status_complete=1`; a file without it
is incomplete and means unknown, whatever its `result` says.

```bash
SF=<the path you passed to --status-file>
tail -1 "$SF" | grep -qx 'status_complete=1' || echo 'INCOMPLETE RECORD - treat as unknown'
sed -n 's/^\(result\|refusal_reason\|next_action\|phase\|pkg_state\|workload_state\|node_availability_after\)=/\1 = /p' "$SF"
```

| `result` | `refusal_reason` | `next_action` | Do this |
|---|---|---|---|
| _file absent_ | — | — | the run never started; fix the invocation and retry |
| _no `status_complete=1`_ | — | — | incomplete file; treat it as unknown |
| `running` | — | — | no complete final record was published — a kill, a power loss, or a trap that could not write. Inspect the node before rerunning |
| `ready` | — | `proceed` | run the real upgrade, answering every gate in `gates_required` and every applicable gate in `gates_conditional` |
| `completed` | — | `none` | verify runtime health, restore recorded availability, then check `workload_state` and application recovery |
| `completed` | — | `investigate` | `clean-swarm-networks.sh` only, exit **2**: the cleanup ran but `failed_items` is non-zero. **Not success** — some state was not removed |
| `nothing-to-do` | — | `none` | move to the next node |
| `refused` | `not-root` | `rerun-as-root` | re-invoke as root |
| `refused` | `bad-usage` | `none` | fix the invocation. **A usage error writes no status file**, so any file at that path is from an earlier run — check `run_id` |
| `refused` | `payload-invalid` | `rebuild-bundle` | stop the rollout; the bundle is wrong on this node |
| `refused` | `dry-run-failed` | `investigate` | stop; report `refusal_detail` |
| `refused` | `containerd-1x` | `investigate` | stop; this node needs the major-boundary script |
| `refused` | `unverified-baseline` | `investigate` | stop and report the versions. Only a human approves an untested starting version |
| `refused` | `gate-unanswered:<name>` | `supply-flag` | **verify the fact, then supply the flag.** Never supply it to clear the error |
| `refused` | `relocated-root-missing` | `fix-mount` | mount the filesystem — do **not** create the directory — then preflight again. If this came from **phase 6** rather than from preflight, packages are already replaced and services are down: follow the relocated-root recovery in the Reference, which requires `--rerun-at-target` and a manual availability restore |
| `refused` | `tasks-present` | `investigate` | the drain already ran; wait, then look from a manager |
| `refused` | `drain-unconfirmed` | `drain-from-manager` | drain it from a manager, confirm it is empty, retry |
| `refused` | `stop-failed` | `investigate` | a unit was not conclusively stopped; nothing was replaced |
| `refused` | `verification-failed` | `investigate` | installed versions do not match the target; escalate |
| `refused` | `config-version-blocks-rollback` | `restore-config` | restore the named backup, then retry. If a *different* backup holds a config the older containerd can load, `--config-backup=DIR` naming it is the fix |
| `refused` | `config-backup-ambiguous` | `supply-flag` | choose from `config_backup_candidates` and pass `--config-backup=DIR` |
| `refused` | `config-backup-not-found` | `supply-flag` | the directory is absent or holds no `config.toml`; choose from `config_backup_candidates` |
| `refused` | `config-backup-declined` | `investigate` | the newest backup was declined interactively; nothing changed |
| `refused` | `non-swarm-declined` / `stop-declined` / `delete-declined` / `drain-unconfirmed` **in the cleanup** | `investigate` | a cleanup gate was declined. Nothing was deleted, services are up, and the run **exits 0** — read `result`, not the status. The upgrade's own `drain-unconfirmed` is the row above and behaves differently |
| `refused` | `inventory-sha-required` | `rerun-dry-run` | you cannot pre-answer the deletion; dry run first, then pass its hash |
| `refused` | `inventory-changed` | `rerun-dry-run` | the node changed between the passes; dry run again and use the new hash |
| `refused` | `enumeration-failed` | `investigate` | the inventory could not be read or hashed. Services were restored; nothing was deleted |
| `failed` / `interrupted` | — | `start-services` | packages untouched, services down: start containerd, wait for readiness, then docker |
| `failed` / `interrupted` | — | `investigate` | report `pkg_state`, `phase` and the log. Do not guess between retry and rollback |

**A `result` of `refused` can carry an `exit_code` of 0.** Declining the upgrade's
unverified-baseline question, the rollback's backup-selection question, or any of the cleanup's
four gates exits 0 and records `refused`. Declining the upgrade's already-at-target question is
different again: it records `nothing-to-do` with an empty `refusal_reason`, and exits 0
interactively or 3 under `--non-interactive`. Either way the status alone tells you nothing —
which is the sharpest reason to read `result`. The full split is in the Reference.

`next_action` never says `rollback`, and never will: after an rpm transaction that choice
depends on why it failed. An empty `refusal_reason` with `result=failed` includes the
end-of-file refusal — the prompt helper exits 1 without setting a token, and the log line
`stdin closed - cannot read an answer.` identifies it.

**After any failure at or after phase 1, check Swarm availability from a manager.**
`pkg_state=untouched` says only that rpm was never invoked: by that point the node may already
have been drained, `dnf clean all` and `rpm --rebuilddb` may have run, and a backup directory
may exist. Checking is immediate; **restoring is not**. Put the recorded value back only once
the node is healthy and whatever this table sent you to do is finished — restoring `active` on a
node you have not resolved schedules work onto it. Until then leave it drained and say so.

## 5. Never do this

Each of these has a failure mode that has happened or been measured.

- **Never pass `--assume-drained`, or answer that attestation yes, without having drained.** It
  asserts a fact about the rest of the cluster and performs nothing.
- **Never pass a gate flag to make a refusal go away**, and never pass `--rerun-at-target` to
  turn an exit 3 into an exit 0. Exit 3 means the node is already done; the only situation that
  needs that flag is the relocated-root repair in the Reference.
- **Never continue past `--proceed-with-tasks` to save time.** That gate exists because the
  drain did not finish. Prefer `--no-proceed-with-tasks`.
- **Never pass `--non-interactive` and then read only the exit code.**
- **Never run `containerd config default > /etc/containerd/config.toml`.** On an upgraded node
  it writes a config version the rollback containerd cannot read, arming a trap that springs
  only during an emergency.
- **Never substitute the `containerd` package for `containerd.io`.** Different packages; the
  plain one is the wrong thing.
- **Never install or downgrade the engine and the runtime in separate rpm transactions.**
  Resolving them together is what stops a downgraded runtime ending up under a newer engine.
- **Never skip phase 0 or the `rpm -Uvh --test` dry run**, and never hand-edit the package
  directory to get past a rejection.
- **Never replace packages or delete network state until docker, `docker.socket` and
  containerd are all conclusively stopped.** A nonzero `systemctl is-active` is not proof — it
  also returns nonzero for `activating`, for `deactivating`, and for failing to reach systemd.
  If `docker.socket` survives while dockerd is down, anything touching the socket starts dockerd
  again, mid-transaction.
- **Never start docker until containerd is actually ready** — both `ctr version` and
  `ctr snapshots --snapshotter overlayfs ls` must succeed. systemd reports containerd active
  before its snapshotter is usable, and a sleep is not readiness.
- **Never re-enumerate the cleanup inventory after the confirmation.** The list you were shown
  is the list that gets deleted. That is also why `--confirm-delete` alone is refused in every
  mode: a pre-declared yes would authorise deleting a list nothing had seen.
- **Never assume a version, or blindly restart services, after `UNKNOWN - the rpm
  transaction`.** Inspect what is installed first, and escalate.
- **Never run `clean-swarm-networks.sh` as a routine post-upgrade step.** It is a destructive
  reset of daemon network state and forces an overlay reconvergence.
- **Never run `recover-dnf.sh` Option A on a production air-gapped host**, and never pass
  `--run-option-a` there. Its commands reference a `docker-local` repository that exists only on
  machines that ran the simulation path; on a real node it stops docker and containerd and then
  fails. The script is **not read-only** either: by the time it asks, it has already run
  `dnf clean all` and `rpm --rebuilddb`.
- **Never walk away from a failed run without checking Swarm availability from a manager.** A
  failure at or after phase 1 can leave a manager drained even when `pkg_state=untouched`.
- **Never extract a bundle over an existing `/opt/docker-offline`.**
- **Never blindly return a node to `active`.** Restore the availability you recorded.
- **Never treat a missing anchor string as success.** If you cannot find `UPGRADE COMPLETE` the
  state is unknown, not good — and never treat `NETWORK CLEANUP COMPLETED WITH` as success
  merely because it contains `NETWORK CLEANUP COMPLETE`.
- **Never improvise on a disconnected production node.** If this document does not cover it,
  stop and report.

---

# Reference

For when section four sent you here, or the happy path does not apply. Nothing below repeats
sections one to five; it explains them.

## What this interface is, and is not

**You do not need a terminal for any of the three stateful scripts.** Every question the
upgrade and the cleanup ask is a named gate with a flag for each answer; the rollback's one
question is a value, answered by `--config-backup`. `--non-interactive` turns an unanswered
question into a refusal instead of a prompt.

It is a **strictness** switch, not a consent switch. It grants nothing. It changes exactly two
things: an unanswered question refuses instead of prompting — an unanswered gate in the upgrade
and the cleanup, an ambiguous backup selection in the rollback — and the richer exit codes
become available. Under it the prompt helper is **never reached** — not reached, not auto-answered —
so a wrapper piping `/dev/null`, or `yes y`, still cannot answer anything.

**A pre-declared answer wins in both modes.** `--drain-self` skips that prompt on an
interactive run too. The flag states a fact; the mode only decides what happens to facts nobody
stated.

**Without `--non-interactive` you still need a terminal.** The prompt helper treats end-of-file
as a refusal, not as a default: it prints `ERROR: stdin closed - cannot read an answer.` and
exits 1. So `ssh host /opt/docker-offline/upgrade-docker.sh` with no flags fails at the first
prompt. Use `ssh -t`, or pass the gate flags and `--non-interactive`. Piping input works and is
dangerous, because you are answering questions you cannot read — pass the flags instead.

**An end-of-file refusal is not automatically harmless.** It always exits 1, but the state it
leaves depends on which prompt it hit. In the upgrade, the first two prompts change nothing;
either task prompt means the manager has **already drained itself**; the reactivation prompt
means packages are replaced, services are running, and the manager may still be drained. In the
cleanup, the first three exit before anything stops, but the deletion prompt is reached with
services already stopped and the exit trap then tries to restart them. Check Swarm availability;
do not assume.

**Exit codes.** These are the *controlled* outcomes, not an exhaustive taxonomy: an unexpected
failure under `set -e` propagates its own status, and an interrupt exits 130 or 143, which the
record classifies as `failed` and `interrupted`.

| Exit | Meaning |
|---|---|
| 0 | the run completed — **or** a decline that changed nothing. `result=refused` with `exit_code=0` is normal and is covered below |
| 1 | most refusals, and the controlled failures. **Not every failure**: an unexpected command failure under `set -e` propagates that command's own status, which can be anything |
| 2 | `clean-swarm-networks.sh` only: the cleanup ran but some items could not be removed. `result=completed`, `next_action=investigate`. **Not success** |
| 3 | `--non-interactive` or `--preflight` only: already fully at the target, `result=nothing-to-do`, node untouched |
| 130 / 143 | interrupted |

**Exit 0 alone never means success.** Several declines exit 0 because none of them changes
package or network state, and they do not all record the same `result`. One caveat first: the
cleanup's `delete-declined` is reached **after** services have already been stopped, so its exit
0 follows a stop-and-restart cycle. Nothing was deleted, but the node did have a service
outage, and dockerd recreates namespaces on the way back up. The other declines touch nothing
at all.

- **`result=refused`, with a `refusal_reason`, and `exit_code=0`**: the upgrade's
  `allow-unverified-baseline` question (`unverified-baseline`), the rollback's backup-selection
  question (`config-backup-declined`), and all four cleanup gates (`non-swarm-declined`,
  `drain-unconfirmed`, `stop-declined`, `delete-declined`).
- **`result=nothing-to-do`, with an empty `refusal_reason`**: the upgrade's `rerun-at-target`
  question. Declining it is not a refusal — there was nothing to do. Interactively it exits 0;
  under `--non-interactive` the same decline exits 3, answered or unanswered.

The refusals that exit 1 are the ones that stopped a run already under way, or never let it
start: `tasks-present` and `drain-unconfirmed` in the upgrade, every payload and usage refusal,
`inventory-changed` and `inventory-sha-required` in the cleanup, and every unanswered gate under
`--non-interactive`.

Exit 3 is why the interactive codes are unchanged: an already-at-target decline still exits 0
interactively, so no existing wrapper sees a new code. **Read `result`, not the status**,
whenever both are available.

**The prose output is not a contract; the status file is.** Without `--status-file` nothing is
machine-readable. The anchors quoted in this document are real strings the scripts print today,
but they are prose: match them loosely and treat a non-match as unknown, never as good news.
Some lines carry ANSI colour codes mid-line — `Packages:  UNKNOWN` does **not** match, because
an escape sequence sits between the colon and the word. Match `UNKNOWN - the rpm transaction`
instead. `Packages:  UNCHANGED` and `Packages:  NEW` have no such escape and do match.

An unrecognised argument is a usage error: exit 1 with a message and **no status file**. There
is no `--yes`, and there never will be — a blanket consent flag is exactly what the per-gate
flags replace. Do not invent flags; a misspelled one fails loudly rather than being ignored.

## Every flag, by script

Each gate takes `--NAME` for yes and `--no-NAME` for no. `--NAME` and `--no-NAME` on the same
command line are **refused at parse time**, not resolved by order: each states one fact, so a
contradictory pair is two incompatible claims, and letting the last win is how a wrapper that
appends a default silently overrides a deliberate answer.

### `upgrade-docker.sh`

<!-- flags: upgrade-docker.sh -->

| Flag | What it does |
|---|---|
| `--preflight` | run every check that can be made with the node untouched, report, exit |
| `--status-file` | `=PATH`. Write a `key=value` record of the run. Absolute paths only |
| `--non-interactive` | refuse, rather than prompt, on a question with no answer. **Requires `--status-file`** |
| `--rerun-at-target` | yes: run again although all five packages already match |
| `--no-rerun-at-target` | no: the node is done. Same outcome as leaving it unanswered — `result=nothing-to-do`, exit 0 interactively and **3** under `--non-interactive` |
| `--allow-unverified-baseline` | yes: this untested starting version is acceptable |
| `--no-allow-unverified-baseline` | no: stop on an unrecognised starting version. `result=refused`, `refusal_reason=unverified-baseline`, and it **exits 0** because nothing was touched |
| `--drain-self` | yes: drain this manager now |
| `--no-drain-self` | no: leave this manager as it is |
| `--proceed-with-tasks` | yes: continue although tasks may still be on the node |
| `--no-proceed-with-tasks` | no: stop rather than upgrade a node still running work |
| `--assume-drained` | yes: a manager has already drained this node. An attestation, not an instruction |
| `--no-assume-drained` | no: this node has not been drained |
| `--reactivate` | yes: return this manager to `active` at the end |
| `--no-reactivate` | no: leave it drained and print the command |
| `--help` | usage, exit 0. Works as any user and touches nothing |
| `-h` | same as `--help` |
| `--version` | the script's version, exit 0 |

<!-- /flags -->

### `rollback-docker.sh`

No gate flags: its one question is a value rather than a yes/no.

<!-- flags: rollback-docker.sh -->

| Flag | What it does |
|---|---|
| `--preflight` | run phases 0, 0b and 0c with the node untouched, report, exit |
| `--status-file` | `=PATH`. Write a `key=value` record of the run. Absolute paths only |
| `--non-interactive` | refuse, rather than prompt, on an ambiguous backup selection. **Requires `--status-file`** |
| `--config-backup` | `=newest`, `=none`, or `=DIR`. Which containerd config backup phase 3 restores |
| `--help` | usage, exit 0 |
| `-h` | same as `--help` |
| `--version` | the script's version, exit 0 |

<!-- /flags -->

### `clean-swarm-networks.sh`

<!-- flags: clean-swarm-networks.sh -->

| Flag | What it does |
|---|---|
| `--status-file` | `=PATH`. Write a `key=value` record of the run. Absolute paths only |
| `--non-interactive` | refuse, rather than prompt, on a question with no answer. **Requires `--status-file`** |
| `--dry-run` | stop, enumerate, print the inventory and its hash, restart, exit 0. Deletes nothing |
| `--expect-inventory-sha` | `=SHA`. Refuse unless this run's own enumeration hashes to SHA, 64 lowercase hex characters |
| `--allow-non-swarm` | yes: run on a host that is not in a Swarm anyway |
| `--no-allow-non-swarm` | no: stop on a host that is not in a Swarm |
| `--assume-drained` | yes: a manager has already drained this node. An attestation, not an instruction |
| `--no-assume-drained` | no: this node has not been drained |
| `--confirm-stop` | yes: stop docker and containerd now |
| `--no-confirm-stop` | no: do not stop services |
| `--confirm-delete` | yes: delete the enumerated inventory. **Refused on its own in every mode** — pair it with `--expect-inventory-sha` |
| `--no-confirm-delete` | no: delete nothing. Services are restarted and the run exits 0 |
| `--help` | usage, exit 0 |
| `-h` | same as `--help` |
| `--version` | the script's version, exit 0 |

<!-- /flags -->

### `recover-dnf.sh`

<!-- flags: recover-dnf.sh -->

| Flag | What it does |
|---|---|
| `--run-option-a` | yes: run Option A after the diagnostics. **Do not pass this on a production air-gapped node** |
| `--no-run-option-a` | no: skip Option A. This is what an unattended caller should pass |
| `--help` | usage, exit 0 |
| `-h` | same as `--help` |
| `--version` | the script's version, exit 0 |

<!-- /flags -->

It has no status file, no `--non-interactive` and no `--preflight`.
`download-docker-packages.sh` and `simulate-upgrade.sh` take no flags at all: neither has a
prompt, neither runs on a production node, and neither is in scope here.

A refusal under `--non-interactive` looks like this — exit 1, and on the node nothing has
happened:

```
ERROR: --non-interactive was given and gate 'drain-self' was not answered.
  question: Drain this node now? [Y/n]
  pass --drain-self or --no-drain-self
```

The record then carries `result=refused`, `refusal_reason=gate-unanswered:drain-self`,
`next_action=supply-flag`, and `gates_unanswered` names every gate still missing an answer.

**`--non-interactive` without `--status-file` is refused at parse time**, before anything is
written anywhere: without the file the fields this document tells you to read do not exist.

## `--preflight` on the upgrade

Read-only: nothing is stopped, nothing is installed, no directory is created, and dnf is
checked but not repaired. It exits 0 (`ready`), 1 (`refused`) or 3 (`nothing-to-do`).

It covers the whole of phase 0 — payload digests, RPM metadata, all five package versions, the
containerd RPM release, the architecture, the RHEL major, duplicate packages, and the
`rpm --test` dry run of the exact transaction — then the containerd 1.x hard stop, the
installed-version classification, the Swarm state and role, a dnf check, and two reads lifted
out of phase 6.

**Those two hoisted reads are the point of the flag.** Phase 6 runs *after* the package
transaction, with docker and containerd stopped. A relocated containerd root whose filesystem is
not mounted is discovered there today, on a node that is already down. Preflight finds the same
thing with every service running, where refusing costs nothing. It reports the config version
for the same reason: whether a rollback would be blocked is worth knowing before the upgrade.

Preflight **predicts**; the phases still **enforce**. Phase 6 keeps its own copy of both checks,
through the same helpers, so the two cannot answer differently — and a node can be repaired, or
broken, between the two runs.

**It reports which gates the real run would reach, in two lists.** `gates_required` names the
gates the run certainly reaches; `gates_conditional` names the ones whose reachability depends
on what the run *does*, which preflight cannot see from a node at rest. Without
`--non-interactive` both are informational. With it, preflight **refuses** on any unanswered
gate in `gates_required` — exit 1, `refusal_reason=gate-unanswered:<the first>` — while an
unanswered gate in `gates_conditional` is **reported, not refused**.

The claim is bounded and this document will not overstate it: **preflight validates every gate
that is certain and names the ones that are not.** A run that passes preflight can still stop on
a conditional gate. That is safe, and the record says so, but it is not "validate everything up
front" — which is why section three says to answer the applicable conditional gates
explicitly when draining a manager.

Two of the six gates are promoted or dropped by the flags you already passed. `--drain-self`
promotes `reactivate` from conditional to required, because the run will certainly drain and
therefore certainly offer to reactivate. `--no-drain-self` drops both `proceed-with-tasks` and
`reactivate`, because neither is reached when no drain runs — but **only on a node the drain
question would actually reach**. A manager already in `drain` never reaches that question, so
its reactivation stays required whatever the drain flag says.

## The gates, and how to answer each

The bracketed letter in each question is the default, and the default applies only to an empty
line of typed input: end-of-file is refused, not defaulted, and under `--non-interactive` the
question is never asked at all.

### `upgrade-docker.sh`

| Gate | When it fires | Question | Default | How to decide |
|---|---|---|---|---|
| `rerun-at-target` | All five packages already at target | Re-run the upgrade anyway? | no | **No**, unless you are deliberately repairing a node — see the relocated-root recovery below, where the answer is yes. The no branch changes nothing. Unanswered under `--non-interactive` it exits **3**, `result=nothing-to-do`, rather than refusing: its no branch does nothing at all, so a distinct code beats a refusal |
| `allow-unverified-baseline` | Not at target, not a partial upgrade, and docker or containerd differs from the tested starting pair | Continue from this unverified starting version? | no | **No** by default. Report the versions it printed and stop. Yes only if a human has approved that specific starting version. It does **not** fire on a partial upgrade: if either core package is already at target the script proceeds without asking |
| `drain-self` | Manager whose availability reads `active` **or** `unknown` | Drain this node now? | **yes** | Yes when other eligible nodes can host the tasks. No for an authorized single-node/no-drain outage (section 3). `unknown` means inspect failed: establish the topology and availability first. An already drained or paused manager skips this gate |
| `proceed-with-tasks` | Tasks could not be counted after the drain | Continue with upgrade anyway? | no | **No.** Check `docker node ps` from another manager first. "Could not count" is not "none" |
| `proceed-with-tasks` | Tasks are still on the node after the drain | Continue with upgrade anyway? | no | **No.** Wait for them to migrate, confirm empty from a manager, then re-run |
| `assume-drained` | Worker | Has this node been drained from a manager? | no | Yes **only if you drained it and saw the task list empty**. An attestation, not an instruction — answering yes drains nothing |
| `reactivate` | Manager finished the upgrade while drained | Set this node back to ACTIVE? | **yes** | Yes **only if the availability you recorded was `active`**, and only once you have verified the node. Otherwise no: it leaves the node drained and prints the command |

`proceed-with-tasks` deliberately covers both task questions. The distinction is not lost — it
survives in the record as `tasks_remaining=3` versus `tasks_remaining=unknown`.

### `rollback-docker.sh`

One question, and only when more than one `/root/docker-backup-*` directory exists.

| Question | Default | How to decide |
|---|---|---|
| Use the backup marked above? | **yes** | The newest is not necessarily the one belonging to the upgrade you are rolling back. If you know which is right, pass `--config-backup=DIR` and skip the question. If you cannot tell, answer no — it exits 0 having changed nothing — and **stop**. Do not copy a different `config.toml` into place and re-run instead: with no flag the next run selects the newest again and phase 3 restores it over your copy |

Under `--non-interactive` this question is not asked. More than one backup with no
`--config-backup` is refused with `config-backup-ambiguous`, and `config_backup_candidates`
lists every directory to choose from.

### `clean-swarm-networks.sh`

| Gate | When it fires | Question | Default | Decline does |
|---|---|---|---|---|
| `allow-non-swarm` | Swarm state is anything but `active` | Continue anyway? | no | exits 0, nothing changed |
| `assume-drained` | Always, after the above | Has this node been drained? | no | exits 0, nothing changed |
| `confirm-stop` | Always, after the above | Stop docker and containerd now? | no | exits 0, nothing changed |
| `confirm-delete` | Only when the enumerated inventory is non-empty | Delete the state listed above? | no | restarts services, exits 0, nothing deleted |

The drain attestation here attests only to the drain. The script never checks task emptiness, so
confirm that yourself from a manager before running it.

## The status file

Written twice: once at startup with `result=running`, and once from the exit trap on every path
— success, refusal, failure and interrupts. It is written to a temporary file and renamed, so a
reader never sees a half-written record.

- **The last line is always `status_complete=1`.** A file without it is incomplete; treat it as
  unknown, not as whatever its `result` says.
- **`result=running` means no complete final record was published** — a kill, a power loss, or a
  trap that fired and could not write.
- **A missing file means the run never started.** A usage error writes nothing, because at that
  point the path is not known to be usable. A non-root refusal *does* write one.
- **Check `run_id` before trusting a file at a path you reuse.** Better: a fresh path per run.
- **`unknown` is a valid value for any key.** It means "not observed when this record was
  written", which is the normal state of most keys in a startup record.
- Split each line on the **first** `=`. Values are single-line and unquoted.

If the path cannot be written the script says so and exits 1 **before touching anything**. That
check is the startup write itself, so a path that passes has been proven writable, not probed.

### Keys every script writes

<!-- status-keys: common -->

| Key | Values |
|---|---|
| `schema` | `1` |
| `run_id` | correlation id for this invocation |
| `script` | script basename |
| `script_version` | the script's version |
| `started` | ISO 8601 UTC, or `unknown` |
| `ended` | ISO 8601 UTC, or `unknown` |
| `host` | hostname |
| `rhel` | RHEL major, or `unknown` |
| `mode` | `interactive` \| `non-interactive` \| `preflight` \| `dry-run` (cleanup only) |
| `result` | `running` \| `ready` \| `completed` \| `nothing-to-do` \| `refused` \| `failed` \| `interrupted` |
| `exit_code` | integer, or `unknown` in a startup record |
| `phase` | the phase the script was in |
| `refusal_reason` | a token, or empty. See the refusal table below |
| `refusal_detail` | one line of free text, or empty |
| `next_action` | `none` \| `proceed` \| `start-services` \| `investigate` \| `supply-flag` \| `rerun-as-root` \| `restore-config` \| `rebuild-bundle` \| `fix-mount` \| `drain-from-manager` \| `rerun-dry-run` |
| `log` | log file path |
| `log_started` | `true` \| `false` — false for exits before the log redirection was installed, whose output reached the terminal only |
| `docker_active` | `active` \| `inactive` \| `failed` \| `activating` \| `deactivating` \| `unknown` |
| `docker_socket_active` | same as `docker_active` |
| `containerd_active` | same as `docker_active` |
| `status_complete` | `1`, always the final line |

The three `*_active` keys are read at the moment the record is written, from
`systemctl show`, never from `systemctl is-active` — that returns nonzero for `activating`,
for `deactivating`, and for failing to reach systemd, so treating nonzero as "stopped" fails
open. An unreachable systemd reads here as `unknown`.
`services_stopped` is not the same thing: it records that the script *began* stopping
services, which is what its recovery logic needs. A stop that failed partway leaves
`services_stopped=true` with docker still `active`. Trust the observed pair.

### `refusal_reason` tokens

| Token | Meaning | Scripts |
|---|---|---|
| `not-root` | not run as root | all three |
| `bad-usage` | bad argument, or an unusable `--status-file` path | all three |
| `payload-invalid` | the RPM payload failed validation | upgrade, rollback |
| `dry-run-failed` | `rpm --test` refused the transaction | upgrade, rollback |
| `containerd-1x` | containerd 1.x found; this script does not cross that boundary | upgrade |
| `unverified-baseline` | operator declined an untested starting version | upgrade |
| `tasks-present` | tasks remained, or could not be counted, after the drain | upgrade |
| `drain-unconfirmed` | the drain attestation was declined | upgrade, cleanup |
| `stop-failed` | a unit was not conclusively stopped | all three |
| `gate-unanswered:<name>` | `--non-interactive` was given and that question had no flag | upgrade, cleanup |
| `inventory-sha-required` | `--confirm-delete` was given with no inventory hash to check it against | cleanup |
| `inventory-changed` | this run's inventory does not hash to `--expect-inventory-sha`; nothing was deleted | cleanup |
| `relocated-root-missing` | the configured containerd root does not exist | upgrade |
| `verification-failed` | installed versions do not match the target | upgrade, rollback |
| `config-version-blocks-rollback` | the config the rollback would load is one it cannot read | rollback |
| `config-backup-declined` | operator declined the newest backup | rollback |
| `config-backup-ambiguous` | more than one backup exists and no `--config-backup` named one | rollback |
| `config-backup-not-found` | `--config-backup` named a directory that does not exist or holds no `config.toml` | rollback |
| `non-swarm-declined` | declined to clean a host that is not in a Swarm | cleanup |
| `stop-declined` | declined to stop services | cleanup |
| `delete-declined` | declined to delete the enumerated inventory | cleanup |
| `enumeration-failed` | the inventory could not be read, so nothing was deleted | cleanup |

An empty `refusal_reason` with `result=failed` means the run died somewhere that has no
token — read `phase`, `pkg_state` and the log.

**An end-of-file refusal is one of those.** The prompt helper exits 1 without setting a token,
so a run killed by a closed stdin records `result=failed` with an empty `refusal_reason`. The
log line `stdin closed - cannot read an answer.` is what identifies it. The helper is
deliberately left byte-identical in this change, so this is documented rather than fixed.

`next_action=start-services` is emitted only when docker, `docker.socket` **and** containerd
are all conclusively stopped, by the same rule the scripts use internally: a successful
`systemctl show`, an `ActiveState` of `inactive` or `failed`, and `MainPID=0`. Anything else
gives `investigate`.

<!-- /status-keys -->

### Keys `upgrade-docker.sh` adds

<!-- status-keys: upgrade-docker.sh -->

| Key | Values |
|---|---|
| `services_stopped` | `true` \| `false` |
| `pkg_state` | `untouched` \| `attempted` \| `installed` |
| `backup_dir` | path, or empty |
| `swarm_active` | `true` \| `false` \| `unknown` |
| `swarm_role` | `manager` \| `worker` \| `none` \| `unknown` |
| `swarm_node_id` | node id, or empty |
| `node_availability_before` | `active` \| `drain` \| `pause` \| `unknown` |
| `node_availability_after` | same, or `unknown` if the run never reached reactivation |
| `drain_performed` | `true` \| `false` — whether **this run** drained the node |
| `workload_state` | `converged` \| `timeout` \| `unknown` \| `not-checked` — cluster-wide Swarm replica counts, not application health; see section 3 |
| `drain_attested_by` | `flag` \| `prompt` \| `not-required` — how the drain fact reached this run |
| `gates_required` | comma-separated names this run certainly reaches, or `unknown` |
| `gates_conditional` | comma-separated names it may reach, or `unknown` |
| `gates_answered` | comma-separated `name:y` / `name:n`, or empty |
| `gates_unanswered` | names in either list with no flag, or `unknown` |
| `gates_seen` | names this run actually reached, in order, or empty |
| `tasks_remaining` | integer \| `unknown` \| `n/a` |
| `containerd_config` | path |
| `containerd_config_version` | integer \| `unknown` |
| `containerd_config_rollback_safe` | `true` \| `false` \| `unknown` |
| `containerd_root` | path, or `unknown` |
| `containerd_root_relocated` | `true` \| `false` \| `unknown` |
| `containerd_root_present` | `true` \| `false` \| `unknown` |
| `rpmnew_present` | `true` \| `false` |
| `nvidia` | `installed` \| `install-failed` \| `skipped-corrupt` \| `payload-missing` \| `toolkit-absent` \| `not-attempted` |
| `node_class` | `at-target` \| `partial` \| `baseline` \| `unverified` \| `unknown` |
| `docker_ce_before` | version \| `absent` \| `unknown` |
| `docker_ce_after` | version \| `absent` \| `unknown` |
| `docker_ce_expected` | version \| `unknown` |
| `docker_ce_cli_before` | version \| `absent` \| `unknown` |
| `docker_ce_cli_after` | version \| `absent` \| `unknown` |
| `containerd_io_before` | version \| `absent` \| `unknown` |
| `containerd_io_after` | version \| `absent` \| `unknown` |
| `containerd_io_expected` | version \| `unknown` |
| `containerd_io_release_before` | RPM release, shaped `<release>.el<rhel-major>` \| `absent` \| `unknown` |
| `containerd_io_release_after` | RPM release \| `absent` \| `unknown` |
| `containerd_io_release_expected` | RPM release \| `unknown` |
| `buildx_before` | version \| `absent` \| `unknown` |
| `buildx_after` | version \| `absent` \| `unknown` |
| `buildx_expected` | version \| `unknown` |
| `compose_before` | version \| `absent` \| `unknown` |
| `compose_after` | version \| `absent` \| `unknown` |
| `compose_expected` | version \| `unknown` |

<!-- /status-keys -->

`drain_performed` records what this run did, not what the cluster looks like. A node you drained
yourself shows `false`.

**Check the containerd release, not only its version.** The same containerd version has been
published more than once with different `runc` builds inside, so the version alone does not
identify what is installed. On a **completed** upgrade, `containerd_io_release_after` must equal
`containerd_io_release_expected`. The upgrade asserts this itself in phase 0 for the bundle and
again in phase 9 for what was installed, but the record is where you confirm it. On a run that
never reached the package transaction, `containerd_io_release_after` is legitimately `unknown` —
that is not a mismatch.

The `nvidia` tokens distinguish four ways the toolkit step can end without installing:
`toolkit-absent` means the node has no NVIDIA toolkit so phase 7 never ran, `payload-missing`
means it does but the bundle shipped no NVIDIA packages, `skipped-corrupt` means they failed
their digest check, and `not-attempted` means the run ended before phase 7.

### Keys `rollback-docker.sh` adds

<!-- status-keys: rollback-docker.sh -->

| Key | Values |
|---|---|
| `services_stopped` | `true` \| `false` |
| `pkg_state` | `untouched` \| `attempted` \| `installed` |
| `config_backup_selected` | path, or `none` |
| `config_backup_source` | `flag` \| `newest` \| `prompt` \| `none` \| `unknown` |
| `config_backup_candidates` | comma-separated paths, or empty |
| `config_version_on_disk` | integer \| `unset` \| `absent` \| `unknown` |
| `config_version_effective` | integer \| `unset` \| `none` \| `unreadable` \| `unknown` |
| `config_rollback_safe` | `true` \| `false` \| `unknown` |
| `containerd_config` | path |
| `docker_ce_before` | version \| `absent` \| `unknown` |
| `docker_ce_after` | version \| `absent` \| `unknown` |
| `docker_ce_expected` | version \| `unknown` |
| `containerd_io_before` | version \| `absent` \| `unknown` |
| `containerd_io_after` | version \| `absent` \| `unknown` |
| `containerd_io_expected` | version \| `unknown` |

<!-- /status-keys -->

`config_version_effective` is what phase 0c actually judged: the selected backup's version when
a backup will be restored, the on-disk file's otherwise, and `none` when phase 3 will generate a
fresh default. Reading only `config_version_on_disk` can tell you the opposite of what the guard
decided.

### Keys `clean-swarm-networks.sh` adds

<!-- status-keys: clean-swarm-networks.sh -->

| Key | Values |
|---|---|
| `services_stopped` | `true` \| `false` |
| `docker_data_root` | path, or `unknown` |
| `inventory_total` | integer, or `unknown` |
| `inventory_sha` | sha256 of the inventory this run enumerated, or empty |
| `inventory_sha_expected` | the value passed to `--expect-inventory-sha`, or empty |
| `vxlan_count` | integer, or `unknown` |
| `netns_count` | integer, or `unknown` |
| `kv_db_present` | `true` \| `false` \| `unknown` |
| `gwbridge_present` | `true` \| `false` \| `unknown` |
| `deleted` | `true` \| `false` |
| `failed_items` | integer, or `unknown` |
| `recovery_attempted` | `true` \| `false` |
| `recovery_succeeded` | `true` \| `false` \| `n/a` |
| `gates_required` | comma-separated names this run certainly reaches, or `unknown` |
| `gates_conditional` | comma-separated names it may reach, or `unknown` |
| `gates_answered` | comma-separated `name:y` / `name:n`, or empty |
| `gates_unanswered` | names in either list with no flag, or `unknown` |
| `gates_seen` | names this run actually reached, in order, or empty |

<!-- /status-keys -->

This script's exit trap **restarts the services it stopped**, unlike the other two. Its record is
written after that attempt, so `recovery_attempted` and `recovery_succeeded` say whether the trap
had to intervene and whether it worked. For where the node actually ended up, read the three
`*_active` keys: they are observed at write time. `services_stopped` remains a statement about
what the script began doing, and a partially failed recovery does not make it false.

A failed recovery is recorded as `result=failed` even when the run was refused, because a node
that is down is the fact that matters; `refusal_reason` still says what led there. An interrupt
keeps `result=interrupted`, so the record never contradicts its own `exit_code`.

## The rollback

`rollback-docker.sh` returns the node to the previous versions, which are bundled. It validates
the payload and dry-runs the rpm transaction before stopping anything, so a rollback whose rpm
transaction would be refused outright fails while the node is still up. That is a bounded promise: the dry run proves
rpm's planned transaction resolves, not that scriptlets and file writes will succeed.

**Run `rollback-docker.sh --preflight` before you need it.** It executes phases 0, 0b and 0c —
the payload validation, the `rpm --test` dry run, the backup selection and the config-version
guard — and exits without touching the node, which answers "would a rollback strand this node?"
while docker and containerd are still up. Exit 0 with `result=ready` means it would proceed;
exit 1 means it would refuse and `refusal_reason` says why. There is no exit 3 and there are no
gates. It is a bounded promise: it does not predict rpm scriptlets, or whether a service will
start.

**Phase 0c refuses outright** when the containerd config the rollback would actually load is a
version the older containerd cannot read — because the downgrade would otherwise succeed and
leave the node with a runtime that will not start. Note *would actually load*: that is the
selected backup when one will be restored, and the on-disk file otherwise. Those are different
files. **There is no override, and you should not look for one.**

Unattended, it is two commands, and the second one **must** name a backup: under
`--non-interactive` more than one `/root/docker-backup-*` directory with no `--config-backup` is
refused as `config-backup-ambiguous` rather than resolved by taking the newest.

```bash
cd /opt/docker-offline
./rollback-docker.sh --preflight --non-interactive --status-file=/run/rbpre-$(date +%s).kv
./rollback-docker.sh --non-interactive --status-file=/run/rb-$(date +%s).kv \
    --config-backup=newest
```

The preflight needs no `--config-backup` even when several backups exist: `--preflight` takes
precedence over `--non-interactive` for that one question and **reports** the newest rather than
refusing, because refusing over a question the interactive run would simply ask is a worse
answer than reporting one. Read `result` exactly as for an upgrade: `ready` means go, `refused`
sends you to the decision table. Use `--config-backup=newest` only when the newest backup is the
one belonging to the upgrade you are undoing; otherwise name the directory.

`--config-backup` says which backup phase 3 restores:

| Value | Effect |
|---|---|
| `newest` | take the newest directory without asking — what answering yes does |
| `none` | restore nothing; phase 3 keeps whatever config is on disk |
| a directory | use that one. **Refused** with `config-backup-not-found` if it does not exist or holds no `config.toml` |

With no flag, behaviour is unchanged: exactly one backup, or none, is used without a question;
more than one prompts.

**The flag is a fact, not an override.** Phase 0c still judges the config phase 3 would actually
load. So `--config-backup=DIR` can turn a refusal into `ready`, but only by naming a backup that
passes the config-version guard, which is a different thing from forcing past it. Note what that
guard checks: the top-level `version` key is one the older containerd accepts. It does not parse
the rest of the file, so a backup it approves can still be wrong in some other way.
`--config-backup=none` weakens nothing either: with no backup selected, the config phase 3 loads
is the on-disk file, and a version that blocks the rollback still blocks it.

`config_backup_source` records how the selection was reached — `flag`, `newest`, `prompt` or
`none` — so an audit can tell a flag that was trusted from a question a human answered.

**Follow phase 0c's own recovery message exactly.** It has two shapes. When a usable backup
exists elsewhere it prints the `cp` to run and — if the newest backup is the unusable one — the
`mv` that stops phase 3 restoring that backup over your copy. Run both. When no usable config
exists anywhere it says so and cannot fix it for you: it offers restoring an off-node copy, or
hand-editing the file while keeping the top-level `root` and `state` values exactly as they are.
**Escalate rather than hand-editing a containerd config on a production node.**

## The network cleanup, and its two passes

`clean-swarm-networks.sh` is a remedy, not a step. Run it only when a node comes back from an
upgrade unable to attach to overlay networks, or when dockerd logs `failed adding service
binding`. Drain the node and confirm it is empty first. It exits **2** when the cleanup ran but
some items could not be removed — treat 2 as "not done", not as success.

It is the one script that cannot be driven in a single invocation, and the reason is structural
rather than an omission: the inventory is enumerated **after** docker and containerd stop,
deliberately, so the confirmation describes exactly what gets deleted. Nobody — human or agent —
can know that list before the node is already down.

**Pass one, the dry run.** It stops services, enumerates, prints the inventory and its hash,
restarts services, and exits 0 having deleted nothing.

```
./clean-swarm-networks.sh --non-interactive --status-file=/run/clean-1.kv \
    --assume-drained --confirm-stop --dry-run
```

Read `inventory_sha`. `inventory_total` tells you whether there was anything to clean at all:
`0` means the run took the nothing-to-clean exit, `result=nothing-to-do`, and there is no second
pass to make.

**Pass two, the real run.** Immediately. Same gate flags, plus the delete answer and the hash.

```
./clean-swarm-networks.sh --non-interactive --status-file=/run/clean-2.kv \
    --assume-drained --confirm-stop --confirm-delete \
    --expect-inventory-sha=<inventory_sha from pass one>
```

The second run enumerates again, hashes **its own** list, and compares. On a mismatch it
restarts services and refuses with `refusal_reason=inventory-changed` and
`next_action=rerun-dry-run`, having deleted nothing.

**What the hash proves, and what it does not.** Services restart between the two passes, so
dockerd recreates network namespaces and VXLAN interfaces. The hash covers the **set of names
and paths**, never file contents, so it proves the list is the same list. It does not prove the
objects behind those names are the same objects: a namespace file with the same name after a
daemon restart is a different namespace. It is a name-list equality check and nothing more — not
a check that the node is unchanged, and not consent from anything that inspected what is about
to be destroyed.

**Nothing enforces freshness.** A hash from an hour-old dry run is accepted if the names still
match. Take it from the immediately preceding run and no other. What is enforced regardless is
that the second run deletes **only what it enumerated itself** — a stale hash can never
authorise deleting a name this run did not see.

`--dry-run` on the same command line as `--confirm-delete`, `--no-confirm-delete` or
`--expect-inventory-sha` is a usage error, rejected before anything runs: a dry run's definition
is that it deletes nothing, and a pre-declared delete answer beside it is two contradictory
instructions. A `--expect-inventory-sha` value that is not 64 lowercase hex characters is also a
usage error, not a mismatch — so a typo does not send you inspecting the node.

## Reading a run that had no status file

**Success.** The upgrade prints `UPGRADE COMPLETE` and the rollback prints `ROLLBACK COMPLETE`.
Verify anyway; a banner is not a version check.

**The cleanup banner is the one place a loose match is wrong.** Success prints the exact line
`NETWORK CLEANUP COMPLETE`, but an incomplete cleanup prints
`NETWORK CLEANUP COMPLETED WITH <n> FAILURE(S)` and exits 2 — and the success string is a
**prefix** of the failure string. A substring match reports a partial cleanup as a success.
Require the exact line **and** exit 0. Both banners are printed in colour, so strip the escapes
before matching exactly, or an exact-line match finds nothing:

```bash
sed 's/\x1b\[[0-9;]*m//g' /var/log/docker-network-cleanup.log | grep -xF 'NETWORK CLEANUP COMPLETE'
```

**Failure.** The upgrade and rollback scripts print a state report on every non-zero exit,
naming the phase, whether services are stopped, and what happened to the packages. Those three
facts decide what you do next, and the script does **not** decide for you.

The two scripts use **different package strings**. The services lines are identical:
`Services:  STOPPED - this node is DOWN` and
`Services:  running (or never stopped by this script)`.

| Package line | `upgrade-docker.sh` | `rollback-docker.sh` |
|---|---|---|
| rpm never ran | `Packages:  UNCHANGED - rpm was never run` | same |
| rpm ran, outcome unknown | `UNKNOWN - the rpm transaction` | `UNKNOWN - the downgrade` |
| rpm succeeded | `Packages:  NEW packages installed successfully` | `Packages:  downgraded successfully` |

| Line to match | Services | Packages | Do this |
|---|---|---|---|
| `Packages:  UNCHANGED - rpm was never run` + `Services:  STOPPED` | down | original | `systemctl start containerd`, wait for readiness, `systemctl start docker`. The package transaction was not attempted |
| `Packages:  UNCHANGED - rpm was never run` + `Services:  running` | up | original | The transaction was not attempted. Fix what the phase reported and re-run |
| `UNKNOWN - the rpm transaction` | either | **unknown** | Run `rpm -q docker-ce docker-ce-cli containerd.io` before anything else. Do not assume either version is installed. Then re-run the script, or roll back. **Escalate — do not choose on your own** |
| `Packages:  NEW packages installed successfully` + `Services:  STOPPED` | down | new | Diagnose from `journalctl -u containerd` and `journalctl -u docker`, then start services or roll back. **Escalate** |
| `Packages:  NEW packages installed successfully` + `Services:  running` | up | new | The upgrade did not finish cleanly but the node is up. Verify the five versions before returning it to service |

**Reading a failed rollback, substitute these.** `UNKNOWN - the downgrade` — establish what is
installed, then bring the node up on whatever that is: start containerd, wait for `ctr version`,
start docker. If containerd.io downgraded but docker-ce did not, the engine is newer than its
runtime; **re-run the rollback** to finish. "Roll back" is not a second option here, and the
script says so itself. `Packages:  downgraded successfully` with services stopped — diagnose the
service failure, then start services; the retry is another rollback run, not an upgrade.

Two things the `UNCHANGED` rows do **not** mean. `untouched` says only that rpm was never
invoked. By that point the node may already have been drained, `dnf clean all` and
`rpm --rebuilddb` may have run, and a backup directory may exist. **After any failure at or
after phase 1, check Swarm availability from a manager** and restore the value you recorded if
you are not about to retry. The trap prints a reactivation command, and that command is right
only when `active` is what you recorded. The report also names the backup directory and the log.

**Refusals from phase 0** all exit 1 before anything is stopped and before the real rpm
transaction runs; nothing on the node has been replaced. One caveat, and it is yours not the
script's: if this is a **worker you drained**, it is still drained.

| What the output says | What it means | Do this |
|---|---|---|
| `containerd 1.x DETECTED` | This script does not handle the containerd major migration | Stop. This node needs the older script named in the message. Do not force it |
| A digest, version, release, architecture or duplicate complaint | The bundle on this node is wrong or damaged | Stop the rollout. Re-transfer the bundle; do not patch the directory by hand |
| `rpm --test` refused the transaction | A dependency or space problem | Check `df -h /var` and the printed rpm output. Fix, then re-run |
| `stdin closed - cannot read an answer` **during phase 0** | You ran it without a terminal | Re-run with `ssh -t`, or with the gate flags and `--non-interactive`. Nothing was changed. The same message later in the run means something else |

## The relocated-root recovery — the one refusal that is not free

Phase 6 refuses when the containerd config points at a relocated root that does not exist —
almost always an unmounted filesystem. By then packages have already been replaced and services
are stopped. `--preflight` exists to catch this while the node is still up; this is what to do
when it was not run.

1. Mount the filesystem. **Do not create the directory.** Creating it would start containerd
   against an empty root and make every image and snapshot look lost.
2. Confirm **both** that the directory exists and that it is the real filesystem:
   `test -d <the root> && findmnt --target <the root>`. The guard checks for the directory;
   `findmnt` alone would pass on a mounted parent with the directory still missing.
3. If the node is in a Swarm, confirm from a manager that it is still drained and still empty.
4. Re-run the script from the top. It is safe to re-run.
5. **Pass `--rerun-at-target`**, or answer yes to the "Re-run the upgrade anyway?" question. The
   phase-5 transaction already succeeded, so all five packages are at the target and the re-run
   opens at that gate, which defaults to **no** — and answering no exits 0 (or 3 under
   `--non-interactive`) without ever reaching phase 6, leaving the node with stopped services and
   nothing fixed. This is the one situation in which that flag is correct.
6. **If the node is in a Swarm, restore the recorded availability from a manager afterwards.**
   Do not wait for the script to do it.

Two things about that second run that will look wrong and are not. **The script will report the
node as not being in a Swarm**, because docker is still stopped from the failed run, so the
Swarm query fails, the state reads as unknown, and phase 10 is skipped — which is why step 6 is
yours. And **it creates another backup directory and repeats the rpm transaction** at the same
versions; it also re-runs phase 0 and the dry run, and may run `dnf clean all` and
`rpm --rebuilddb` again in phase 2.

## Things only a manager can do

Three actions cannot happen on the node being upgraded. Do them from a manager, out of band.

1. **Draining a worker**, before the run. The worker's gate only asks whether it happened.
2. **Reactivating a worker**, after the run. The worker prints the command and cannot run it.
3. **Confirming tasks have migrated.** `docker node ps` on a worker cannot see its own tasks, and
   the script skips its own task count entirely on a node that is already drained.

A fourth thing that is not the script's job: **mounting a missing relocated containerd root.**
That is a host problem, and phase 6 stops rather than paper over it.

## The other scripts

**`recover-dnf.sh`** is a diagnostic, and it is the **one script that fails open** at
end-of-file. With stdin closed it skips its Option A and exits 0 rather than refusing. That is
safe because declining Option A changes nothing, and it is the safe direction — but the script is
not read-only: by the time it asks, it has already run `dnf clean all` and `rpm --rebuilddb`.
`--no-run-option-a` states the decline explicitly and is what an unattended caller should pass.

**`download-docker-packages.sh`** builds the bundle on an online host and **`simulate-upgrade.sh`**
is a dnf-path smoke test. Neither runs on a production node, neither has a prompt, and neither
takes any flags.

## When this document does not cover it

Stop and report. Do not improvise on a disconnected production node.

- `RUNBOOK.md` has the human procedure, the node ordering and the soak guidance.
- The logs are `/var/log/docker-upgrade.log`, `/var/log/docker-rollback.log` and
  `/var/log/docker-network-cleanup.log`. They are appended to, not rotated, so a run's output
  sits at the end and older runs sit above it. They contain ANSI escapes.
- Backups are `/root/docker-backup-<timestamp>/`, named so that lexical order is chronological.

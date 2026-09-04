# Agent Runbook — operating a node

This is the operating guide for a non-human operator. If you are changing the scripts
instead of running them, stop and read `CLAUDE.md`; nothing here is about editing.

Read this document and `RUNBOOK.md`. You do not need to read the scripts.

## The standing rule

**Never assert a fact you have not verified.** Several prompts ask you to attest to something
that happened somewhere else — that a manager drained this node, that tasks have migrated.
Answering yes does not make it true. It tells the script to proceed as though it were.

When you cannot verify a fact, answer no and report why. A refused upgrade costs a maintenance
window. An upgrade that proceeds on a false attestation costs whatever was running on the node.

## What this interface is today, honestly

**You no longer need a terminal for any of the three.** Every question the upgrade and the
cleanup ask is a named gate with a flag for each answer, and `--non-interactive` turns an
unanswered gate into a refusal instead of a prompt. The rollback has one question, a value
rather than a yes/no, answered by `--config-backup`.

Under `--non-interactive` the prompt helper is **never reached**. Not reached and
auto-answered — never reached. A wrapper piping `/dev/null`, or `yes y`, still cannot answer
anything, because there is nothing to answer.

**Every flag states one fact you are accountable for.** Not a preference, a fact.
`--assume-drained` asserts that a drain happened somewhere else; it performs none. The record
writes `drain_attested_by=flag`, so an audit afterwards can tell a flag that was trusted from
a question a human answered.

**Without `--non-interactive` you still need a terminal.** The prompt helper treats
end-of-file as a refusal, not as a default: it prints
`ERROR: stdin closed - cannot read an answer.` and exits 1. That is deliberate, and it is what
makes the strict mode a strictness switch rather than a way to auto-answer.

- `ssh host /opt/docker-offline/upgrade-docker.sh` with no flags fails at the first prompt it
  reaches. Use `ssh -t`, or pass the gate flags and `--non-interactive`.
- Piping input works but is dangerous, because you are answering questions you cannot read.
  Do not do it. Pass the flags instead.
- `recover-dnf.sh` is the exception to the end-of-file rule and behaves differently — see
  below.

**A pre-declared answer wins in both modes.** `--drain-self` skips that prompt on an
interactive run too. The flag states a fact; the mode only decides what happens to facts
nobody stated.

**An end-of-file refusal is not automatically harmless.** It always exits 1, but what state it
leaves depends on which prompt it hit. Hitting it at the first two prompts changes nothing.
Hitting it at either task prompt means the manager has **already drained itself**. Hitting it
at the reactivation prompt means packages are replaced, services are running, and the manager
may still be drained. In the cleanup script it depends which of the four prompts it hit: the
first three exit before anything stops, but the deletion prompt is reached with services
already stopped, and the exit trap then tries to restart them. Read the failure table below and
check Swarm availability; do not assume.

**Exit 0 has three meanings** in the upgrade script: the upgrade completed, or the node was
already at the target and you declined the re-run, or the starting version was unrecognised
and you declined to continue. All three exit 0 and only the last two leave the node unchanged.

Under `--non-interactive` the middle one gets its own code: an already-at-target node with no
`--rerun-at-target` exits **3** with `result=nothing-to-do`. Interactively it still exits 0, so
no existing wrapper sees a new code. Read `result`, not the status, whenever both are available.

Nonzero is worse. Every deliberate refusal uses 1, but a command that fails under `set -e`
propagates its own status, and an interrupt exits 130 or 143. **The important point is that a
nonzero status alone does not distinguish a safe refusal from a failure after the node was
modified.** You must read the output.

**The prose output is still not a contract, but there is now a status file.** Pass
`--status-file=PATH` to the upgrade, rollback or cleanup script and it writes a flat
`key=value` record of the run — see the status-file section below. Use it in preference to
matching output.

Without that flag nothing is machine-readable. The anchors below are real strings the scripts
print today, but they are prose. Match them loosely and treat a non-match as unknown, never as
good news.

Some lines carry ANSI colour codes mid-line. `Packages:  UNKNOWN` does **not** match, because
an escape sequence sits between the colon and the word. Match `UNKNOWN - the rpm transaction`
instead. `Packages:  UNCHANGED` and `Packages:  NEW` have no such escape and do match.

## Preconditions

- **Run as root.** The upgrade, rollback and cleanup scripts now check this before they do
  anything else and refuse with a clear message. They have to check early: the log redirection
  they set up cannot open its file as a non-root user, and every line the script prints then
  disappears into it. Measured, a non-root run before the check produced no output at all.
- **Extract the bundle into an empty directory.** `rm -rf /opt/docker-offline` first, then
  extract the tarball into `/opt`. This is not tidiness: the previous bundle has an identical
  directory layout, so leftovers appear as duplicate packages and the run is refused.
- **Run from the extracted directory**, `/opt/docker-offline`.
- **Record the starting state before you begin**, in particular the containerd root. Use the
  same extraction the script uses: top-level keys only, tolerating indentation and any quoting
  style, with the documented fallback when the key is absent.

  ```bash
  rpm -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  root=$(awk '/^[[:space:]]*\[/ { exit } { print }' /etc/containerd/config.toml \
    | sed -n "s/^[[:space:]]*root[[:space:]]*=[[:space:]]*['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}.*/\1/p" \
    | head -1)
  echo "containerd root: ${root:-/var/lib/containerd}"
  findmnt --target "${root:-/var/lib/containerd}"
  ```

  A plain `grep '^root'` is not good enough: it misses an indented top-level key, which the
  script deliberately accepts, and it tells you nothing when the key is absent. An absent key
  means the default root, `/var/lib/containerd`. You need this path to verify afterwards that
  the upgrade preserved it. Nothing captures it for you.
- **Know whether this node is a Swarm manager or a worker**, and have manager access either
  way. Workers cannot drain or inspect themselves.

## The upgrade sequence

One node at a time, least critical first, with a soak between nodes. `RUNBOOK.md` has the
timings.

**Step one — record the availability, then prepare according to role and state.**

Always record the value first, from a manager. Nothing on the node captures it, and it is what
you restore in step four.

```bash
docker node inspect <node-hostname> --format '{{.Spec.Availability}}'   # RECORD THIS
```

What you do next depends on the node. **Do not drain everything reflexively.** The script
validates the entire payload and dry-runs the rpm transaction in phase 0 *before* it drains a
manager, precisely so a bad bundle cannot leave a manager drained. Pre-draining an active
manager throws that ordering away.

| Node | Do this before running the script |
|---|---|
| Not in a Swarm | Nothing |
| **Worker** | Drain it and confirm it is empty. Unavoidable: a worker cannot drain or inspect itself, and the script only asks whether it happened. This does mean a phase-0 refusal leaves the worker drained — restore it and retry later |
| **Manager, `active` or `unknown`** | **Nothing.** Let phase 0 run first, then pass `--drain-self` (or answer the prompt yes) and let the script drain and count tasks for you. This is the ordering the script exists to provide |
| **Manager, already `drain`** | Leave it drained and confirm it is empty. The script skips its own drain and task-count block on a node that is not active, so it will not check |
| **Manager, `pause`** | Confirm it is empty. The script skips its drain block here too. If tasks remain, drain it deliberately and remember to restore `pause` in step four |

To drain and to confirm emptiness:

```bash
docker node update --availability drain <node-hostname>
docker node ps <node-hostname> --filter desired-state=running --format '{{.Name}}'
```

Poll the second command until it prints **nothing at all**. Without `--format` it prints a
header even when there are no tasks, so "looks empty" is not the same as empty. Do not proceed
on a timer.

The same applies to any re-run of a manager that an earlier attempt left drained: the script
will not re-count tasks, so you must.

**Step two — preflight, then run the upgrade.**

Preflight first, on every node, and gate on its result:

```bash
cd /opt/docker-offline
./upgrade-docker.sh --preflight --non-interactive --status-file=/run/preflight-$(date +%s).kv
```

Read `result`. Only `ready` means go. Then run the real upgrade with a **fresh** status-file
path and exactly the gates preflight named, one flag per fact you have verified:

```bash
./upgrade-docker.sh --non-interactive --status-file=/run/upgrade-$(date +%s).kv \
    --drain-self --proceed-with-tasks --reactivate
```

That example is a manager you recorded as `active`. Substitute your own answers:

| Node | Gate flags |
|---|---|
| Not in a Swarm | none |
| Worker, drained in step one and confirmed empty | `--assume-drained` |
| Manager recorded `active` | `--drain-self --reactivate`, plus `--proceed-with-tasks` or `--no-proceed-with-tasks` |
| Manager already `drain` | `--reactivate` if you recorded `active`, otherwise `--no-reactivate`. The run does **not** re-drain or re-count tasks on a node that is already drained, so confirm it is empty yourself first |
| Manager already `pause` | none. The run skips both the drain and the reactivation on a paused node |
| Manager you do not want drained | `--no-drain-self` |

**Answer `--proceed-with-tasks` explicitly on any manager.** It is a conditional gate:
preflight cannot tell you whether the run will reach it, and reaching it with no answer refuses
the run *after* the drain. `--no-proceed-with-tasks` is the safe answer — it stops rather than
upgrade a node whose tasks have not migrated.

On a terminal, with no flags at all, it still behaves exactly as it always has:

```bash
cd /opt/docker-offline && ./upgrade-docker.sh
```

**Step three — verify.** On the node:

```bash
rpm -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
docker ps -a
```

Re-run the containerd-root extraction from the preconditions and confirm it still reports the
path you recorded. The package versions must match what the script's banner and phase 0 named
as the target. Do not compare them against a version you remember; read the target from this
run's output.

From a manager:

```bash
docker node ls
docker node ps <node-hostname>
docker service ls
```

**Step four — restore the availability you recorded in step one.**

```bash
docker node update --availability <the value you recorded> <node-hostname>
```

`active` goes back to `active`, `pause` back to `pause`, `drain` back to `drain`. Do not
default to `active`.

A manager that ends the run drained reaches the `reactivate` gate, which defaults to **yes**.
Pass `--reactivate` only if you recorded `active`. If you recorded `pause` or `drain`, pass
`--no-reactivate` — it prints the command and leaves the node drained — then set the recorded
value yourself. A worker never reaches the gate and always needs this step done from a manager.

The record confirms what happened: `node_availability_before` and `node_availability_after`,
and `drain_performed` for whether **this run** did the draining.

## Flags

| Flag | Scripts | Effect |
|---|---|---|
| `--preflight` | upgrade, rollback | Run every check that can be made with the node untouched, report, exit |
| `--non-interactive` | all three | Refuse, rather than prompt, on a question with no answer. **Requires `--status-file`** |
| `--status-file=PATH` | all three | Write a `key=value` record of the run to PATH. Absolute paths only |
| `--dry-run` | cleanup | Stop, enumerate, print the inventory and its hash, restart, exit 0. Deletes nothing |
| `--expect-inventory-sha=SHA` | cleanup | Refuse unless this run's own enumeration hashes to SHA |
| `--config-backup=WHAT` | rollback | Which containerd config backup phase 3 should restore: `newest`, `none`, or a directory |
| `--help` | all three | Usage, exit 0. Works as any user and touches nothing |
| `--version` | all three | The script's version, exit 0 |

`rollback-docker.sh` has no **gate** flags: its one question is a value, not a yes/no, so it is
`--config-backup` rather than a gate.

### `--non-interactive`

It is a **strictness** switch, not a consent switch. It grants nothing. It changes exactly two
things: an unanswered gate refuses instead of prompting, and the richer exit codes 2 and 3
become available.

Refusing looks like this — exit 1, and on the node nothing has happened:

```
ERROR: --non-interactive was given and gate 'drain-self' was not answered.
  question: Drain this node now? [Y/n]
  pass --drain-self or --no-drain-self
```

The record then carries `result=refused`, `refusal_reason=gate-unanswered:drain-self`,
`next_action=supply-flag`, and `gates_unanswered` names every gate still missing an answer.

**`--NAME` and `--no-NAME` together are refused at parse time**, not resolved by order. Each
flag states one fact, so a contradictory pair is two incompatible claims rather than a
preference; letting the last one win is how a wrapper that appends a default silently overrides
a deliberate answer.

**`--non-interactive` without `--status-file` is refused at parse time**, before anything is
written anywhere. Exit 1 conflates a refusal with a failure, and 130 and 143 say nothing about
phase, service state or package state. Without the file the fields this document tells you to
read do not exist.

### Gate flags — `upgrade-docker.sh`

Every gate takes `--NAME` for yes and `--no-NAME` for no.

| Gate | Fact you are asserting | Unanswered under `--non-interactive` |
|---|---|---|
| `rerun-at-target` | run again although all five packages already match | exit **3**, `result=nothing-to-do`, node untouched |
| `allow-unverified-baseline` | this starting version is acceptable | refuse, exit 1 |
| `drain-self` | drain this manager now | refuse, exit 1 |
| `proceed-with-tasks` | continue although tasks may still be here | refuse, exit 1 |
| `assume-drained` | a manager has already drained this node | refuse, exit 1 |
| `reactivate` | return this manager to active at the end | refuse, exit 1 |

`rerun-at-target` is the only gate whose unanswered state resolves safely by implication: its
"no" branch does nothing at all, so a distinct exit code beats a refusal. **Do not pass
`--rerun-at-target` to make an exit 3 go away.** Pass it only when you are deliberately
repairing a node — see the phase-6 recovery below, where it is required.

`proceed-with-tasks` deliberately covers both task questions. The distinction is not lost: it
survives in the record as `tasks_remaining=3` versus `tasks_remaining=unknown`.

### Gate flags — `clean-swarm-networks.sh`

| Gate | Fact you are asserting | Unanswered under `--non-interactive` |
|---|---|---|
| `allow-non-swarm` | run this on a host that is not in a Swarm anyway | refuse, exit 1 |
| `assume-drained` | a manager has already drained this node | refuse, exit 1 |
| `confirm-stop` | stop docker and containerd now | refuse, exit 1 |
| `confirm-delete` | delete the enumerated inventory | refuse, exit 1 |

**`--confirm-delete` is refused on its own, in every mode**, with
`refusal_reason=inventory-sha-required` and the node untouched. The inventory is enumerated
only *after* the services stop, so a pre-declared yes would authorise deleting a list nothing
had seen — which is the exact bypass this interface exists to prevent. Pair it with
`--expect-inventory-sha` from an immediately preceding `--dry-run`, or answer the live
question after enumeration on a terminal. There is no third way.

### The two-pass cleanup

The cleanup is the one script an agent cannot drive in a single invocation, and the reason is
structural rather than an omission. The inventory is enumerated **after** docker and containerd
stop, deliberately, so the confirmation describes exactly what gets deleted. Nobody — human or
agent — can know that list before the node is already down.

So it takes two passes.

**Pass one, the dry run.** It stops services, enumerates, prints the inventory and its hash,
restarts services, and exits 0 having deleted nothing.

```
./clean-swarm-networks.sh --non-interactive --status-file=/run/clean-1.kv \
    --assume-drained --confirm-stop --dry-run
```

Read `inventory_sha` from that record. `inventory_total` tells you whether there was anything
to clean at all: `0` means the run took the nothing-to-clean exit, `result=nothing-to-do`, and
there is no second pass to make.

**Pass two, the real run.** Immediately. Same gate flags, plus the delete answer and the hash
the first pass printed.

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
daemon restart is a different namespace. It is a name-list equality check and nothing more —
not a check that the node is unchanged, and not consent from anything that inspected what is
about to be destroyed.

**Nothing enforces freshness.** A hash from an hour-old dry run is accepted if the names still
match. Take it from the immediately preceding run and no other. What is enforced regardless is
that the second run deletes **only what it enumerated itself** — a stale hash can never
authorise deleting a name this run did not see.

`--dry-run` on the same command line as `--confirm-delete`, `--no-confirm-delete` or
`--expect-inventory-sha` is a usage error, rejected before anything runs. A dry run's
definition is that it deletes nothing; a pre-declared delete answer beside it is two
contradictory instructions.

A `--expect-inventory-sha` value that is not 64 lowercase hex characters is also a usage error,
not a mismatch — so a typo does not send you inspecting the node.

### `--config-backup` — `rollback-docker.sh`

The rollback's one question is *which* backup phase 3 should restore, and that is a value
rather than a yes/no. Today it is asked only when more than one `/root/docker-backup-*`
directory exists, and answering "no" aborts the rollback — so naming a non-newest backup used
to mean stopping and copying a file by hand.

| Value | Effect |
|---|---|
| `newest` | take the newest directory without asking — what answering yes does today |
| `none` | restore nothing; phase 3 keeps whatever config is on disk |
| a directory | use that one. **Refused** with `config-backup-not-found` if it does not exist or holds no `config.toml` |

With no flag, behaviour is unchanged: exactly one backup, or none, is used without a question;
more than one prompts. Under `--non-interactive` more than one with no flag is refused with
`refusal_reason=config-backup-ambiguous`, and `config_backup_candidates` lists every directory
to choose from.

**The flag is a fact, not an override.** Phase 0c still judges the config phase 3 would
*actually* load, and still refuses one the rollback containerd cannot read. So
`--config-backup=DIR` can turn a refusal into `ready` — but only by naming a backup that
passes the config-version guard, which is a different thing from forcing past it. Note what
that guard checks: the top-level `version` key is one the older containerd accepts. It does not
parse the rest of the file, so a backup it approves can still be wrong in some other way.
`--config-backup=none` weakens nothing either: with no backup selected, the config phase 3
loads is the on-disk file, and a version that blocks the rollback still blocks it.

`config_backup_source` records how the selection was reached — `flag`, `newest`, `prompt` or
`none` — so an audit can tell a flag that was trusted from a question a human answered.

### `--preflight` — `upgrade-docker.sh`

Run this first, on every node, before the real run. It is read-only: nothing is stopped,
nothing is installed, no directory is created, and dnf is checked but not repaired.

Everything in this section — the exit-3 case, the dnf check, the five-package classification,
the two checks hoisted out of phase 6, and the gate prediction — is about the **upgrade**.
`rollback-docker.sh --preflight` is a different, smaller thing: it runs phases 0, 0b and 0c
and exits 0 or 1, with no exit 3 and no gates. It is described under the other two scripts,
below.

| Exit | `result` | Meaning |
|---|---|---|
| 0 | `ready` | the real run would proceed from here |
| 1 | `refused` | it would refuse; read `refusal_reason` |
| 3 | `nothing-to-do` | the node is already fully at the target |

Those are the *controlled* outcomes. They are not an exhaustive exit taxonomy: an unexpected
failure under `set -e` propagates its own status, and an interrupt still exits 130 or 143. The
record classifies those as `failed` and `interrupted`.

What it covers: the whole of phase 0, which is the payload digests, the RPM metadata, all five
package versions, the containerd RPM release, the architecture, the RHEL major, duplicate
packages, and the `rpm --test` dry run of the exact transaction. Then the containerd 1.x hard
stop, the installed-version classification, the Swarm state and role, a dnf check, and two
reads lifted out of phase 6.

**Those two hoisted reads are the point of the flag.** Phase 6 runs *after* the package
transaction, with docker and containerd stopped. A relocated containerd root whose filesystem
is not mounted is discovered there today, on a node that is already down. Preflight finds the
same thing on a node with every service running, where refusing costs nothing. It reports the
config version for the same reason: whether a rollback would be blocked is worth knowing
before the upgrade, not after.

Preflight **predicts**; the phases still **enforce**. Phase 6 keeps its own copy of both
checks, through the same helpers, so the two cannot answer differently. A node can be repaired,
or broken, between the two runs.

**It also reports which gates the real run would reach, in two lists.** `gates_required` names
the gates the run certainly reaches; `gates_conditional` names the ones whose reachability
depends on what the run *does*, which preflight cannot see from a node at rest.

- Without `--non-interactive` both lists are informational.
- With `--non-interactive`, preflight **refuses** on any unanswered gate in `gates_required` —
  exit 1, `refusal_reason=gate-unanswered:<the first>`, `gates_unanswered` listing all of them.
  An unanswered gate in `gates_conditional` is **reported, not refused**: the run may never
  reach it, and refusing would force you to pre-answer a question that may not be asked.

The claim this supports is bounded, and this document will not overstate it: **preflight
validates every gate that is certain and names the ones that are not.** A run that passes
preflight can still stop on a conditional gate. That is safe — the node is drained but not
upgraded, and the record says so — but it is not "validate everything up front".

**So on any Swarm manager, answer `gates_conditional` explicitly.** Pass
`--proceed-with-tasks` or `--no-proceed-with-tasks`, and `--reactivate` or `--no-reactivate`,
rather than relying on a quiet preflight.

Two of the six gates are also promoted or dropped by the flags you already passed.
`--drain-self` promotes `reactivate` from conditional to required, because the run will
certainly drain and therefore certainly offer to reactivate. `--no-drain-self` drops both
`proceed-with-tasks` and `reactivate`, because neither is reached when no drain runs — but
**only on a node the drain question would actually reach**. A manager already in `drain` never
reaches that question, so its reactivation stays required whatever the drain flag says.

An unrecognised argument is now a usage error: it exits 1 with a message and writes no status
file. It used to be ignored silently.

`recover-dnf.sh` takes `--run-option-a`, `--no-run-option-a`, `--help` and `--version`, and nothing else — no status file, no `--non-interactive`, no `--preflight`. `download-docker-packages.sh` and `simulate-upgrade.sh` take no flags at all: neither has a prompt, neither runs on a production node, and neither is in scope here.

### The status file

Written twice: once at startup with `result=running`, and once from the exit trap on every
path — success, refusal, failure, and interrupts. It is written to a temporary file and
renamed, so a reader never sees a half-written record.

Rules for reading it:

- **The last line is always `status_complete=1`.** A file without it is incomplete; treat it as
  unknown, not as whatever its `result` says.
- **`result=running` means no complete final record was published** — a kill, a power loss, or
  a trap that fired and could not write. The run started and did not report an outcome.
- **A missing file means the run never started.** A usage error writes nothing, because at that
  point the path is not known to be usable. A non-root refusal *does* write one.
- **Check `run_id` before trusting a file at a path you reuse.** A usage error leaves the
  previous run's record in place. Better: use a fresh path per run.
- **`unknown` is a valid value for any key.** It means "not observed when this record was
  written", which is the normal state of most keys in a startup record.
- Split each line on the **first** `=`. Values are single-line and unquoted.

If the path cannot be written, the script says so and exits 1 **before touching anything**.
That check is the startup write itself, so a path that passes has been proven writable, not
merely probed.

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
| `mode` | `interactive` \| `non-interactive` \| `preflight` |
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

`next_action` never says `rollback`. After an rpm transaction, retry versus rollback depends on
why it failed, and the script must not make that call for you. `investigate` is the honest
answer; read `pkg_state` and `refusal_detail`.

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

`drain_performed` records what this run did, not what the cluster looks like. A node you
drained yourself in step one shows `false`.

**Check the containerd release, not only its version.** The same containerd version has been
published more than once with different `runc` builds inside, so the version alone does not
identify what is installed. On a **completed** upgrade, `containerd_io_release_after` must equal
`containerd_io_release_expected`. The upgrade asserts this itself in phase 0 for the bundle and
again in phase 9 for what was actually installed, but the record is where you confirm it. On a
run that never reached the package transaction, `containerd_io_release_after` is legitimately
`unknown` — that is not a mismatch.

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
a backup will be restored, the on-disk file's otherwise, and `none` when phase 3 will generate
a fresh default. Reading only `config_version_on_disk` can tell you the opposite of what the
guard decided.

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

This script's exit trap **restarts the services it stopped**, unlike the other two. Its record
is written after that attempt, so `recovery_attempted` and `recovery_succeeded` say whether the
trap had to intervene and whether it worked. For where the node actually ended up, read the
three `*_active` keys: they are observed at write time. `services_stopped` remains a statement
about what the script began doing, and a partially failed recovery does not make it false.

A failed recovery is recorded as `result=failed` even when the run was refused, because a node
that is down is the fact that matters; `refusal_reason` still says what led there. An interrupt
keeps `result=interrupted`, so the record never contradicts its own `exit_code`.

## The gates, and how to answer each

Each question below is a named gate. Pass `--NAME` for yes or `--no-NAME` for no, in either
mode, or answer it live on a terminal. The bracketed letter is the default, and the default
only applies to an empty line of typed input: end-of-file is refused, not defaulted, and under
`--non-interactive` the question is never asked at all.

### `upgrade-docker.sh`

| Gate | When it fires | Question | Default | How to decide |
|---|---|---|---|---|
| `rerun-at-target` | All five packages already at target | Re-run the upgrade anyway? | no | **No**, unless you are deliberately repairing a node — see the phase-6 recovery below, where the answer is yes. The no branch changes nothing and exits 0 |
| `allow-unverified-baseline` | Not at target, not a partial upgrade, and docker or containerd differs from the tested starting pair | Continue from this unverified starting version? | no | **No** by default. Report the versions it printed and stop. Yes only if a human has approved that specific starting version. Note this does **not** fire on a partial upgrade: if either core package is already at target the script proceeds without asking |
| `drain-self` | Manager whose availability reads `active` **or** `unknown` | Drain this node now? | **yes** | Yes. `unknown` means the node inspect failed, so treat it as undrained. If you already drained in step one this prompt does not fire at all |
| `proceed-with-tasks` | Tasks could not be counted after the drain | Continue with upgrade anyway? | no | **No.** Check `docker node ps` from another manager first. "Could not count" is not "none" |
| `proceed-with-tasks` | Tasks are still on the node after the drain | Continue with upgrade anyway? | no | **No.** Wait for them to migrate, confirm empty from a manager, then re-run |
| `assume-drained` | Worker | Has this node been drained from a manager? | no | Yes **only if you performed step one and saw the task list empty**. This is an attestation, not an instruction — answering yes drains nothing |
| `reactivate` | Manager finished the upgrade while drained | Set this node back to ACTIVE? | **yes** | Yes **only if the availability you recorded in step one was `active`**, and only once you have verified the node. Otherwise no: it leaves the node drained and prints the command, and you then set the recorded value |

### `rollback-docker.sh`

One question, and only when more than one `/root/docker-backup-*` directory exists. It is a
value rather than a gate, so it is answered with `--config-backup` rather than a `--NAME` flag.

| Question | Default | How to decide |
|---|---|---|
| Use the backup marked above? | **yes** | The newest is not necessarily the one belonging to the upgrade you are rolling back. If you know which one is right, pass `--config-backup=DIR` and skip the question. If you cannot tell, answer no — it exits 0 having changed nothing — and **stop**. Do not copy a different `config.toml` into place and re-run instead: with no flag the next run selects the newest again and phase 3 restores it over your copy |

Under `--non-interactive` this question is not asked. More than one backup with no
`--config-backup` is refused with `config-backup-ambiguous`, and the candidates are listed in
the record.

### `clean-swarm-networks.sh`

Four gates, two of them unconditional — the drain attestation and the stop confirmation.

| Gate | When it fires | Question | Default | Decline does |
|---|---|---|---|---|
| `allow-non-swarm` | Swarm state is anything but `active` | Continue anyway? | no | exits 0, nothing changed |
| `assume-drained` | Always, after the above | Has this node been drained? | no | exits 0, nothing changed |
| `confirm-stop` | Always, after the above | Stop docker and containerd now? | no | exits 0, nothing changed |
| `confirm-delete` | Only when the enumerated inventory is non-empty | Delete the state listed above? | no | restarts services, exits 0, nothing deleted |

`--confirm-delete` on its own is refused in every mode; pair it with `--expect-inventory-sha`
from a preceding `--dry-run`. See the two-pass procedure above.

The drain attestation here attests only to the drain. The script never checks task emptiness,
so confirm it yourself from a manager before running this.

## Reading the outcome

### The decision table

Read this first, from the status file. The prose below is for a run that had no
`--status-file`, or for a human reading the log afterwards.

| `result` | `refusal_reason` | `next_action` | Do this |
|---|---|---|---|
| _file absent_ | — | — | the run never started; fix the invocation and retry |
| _last line is not `status_complete=1`_ | — | — | incomplete file; treat it as unknown |
| `running` | — | — | no complete final record was published — a kill, a power loss, or a trap that could not write. Inspect the node before rerunning |
| `ready` | — | `proceed` | run the real upgrade, answering every gate in `gates_required` and every gate in `gates_conditional` that applies |
| `completed` | — | `none` | verify, then restore the availability you recorded |
| `nothing-to-do` | — | `none` | move to the next node |
| `refused` | `not-root` | `rerun-as-root` | re-invoke as root |
| `refused` | `bad-usage` | `none` | fix the invocation. **No status file is written for a usage error**, so any file at that path is from an earlier run — check `run_id` |
| `refused` | `payload-invalid` | `rebuild-bundle` | stop the rollout; the bundle is wrong on this node |
| `refused` | `dry-run-failed` | `investigate` | stop; report `refusal_detail` |
| `refused` | `containerd-1x` | `investigate` | stop; this node needs the major-boundary script |
| `refused` | `gate-unanswered:<name>` | `supply-flag` | **verify the fact, then supply the flag.** Never supply it to clear the error |
| `refused` | `relocated-root-missing` | `fix-mount` | mount the filesystem, then preflight again |
| `refused` | `tasks-present` | `investigate` | the drain already ran; wait and look from a manager |
| `refused` | `drain-unconfirmed` | `drain-from-manager` | drain it from a manager, confirm it is empty, then retry |
| `refused` | `config-version-blocks-rollback` | `restore-config` | restore the named backup, then try again. If a *different* backup on the node holds a config the older containerd can load, `--config-backup=DIR` naming it is the fix |
| `refused` | `config-backup-ambiguous` | `supply-flag` | choose from `config_backup_candidates` and pass `--config-backup=DIR` |
| `refused` | `config-backup-not-found` | `supply-flag` | the directory does not exist or holds no `config.toml`; choose from `config_backup_candidates` |
| `refused` | `inventory-sha-required` | `rerun-dry-run` | you cannot pre-answer the deletion; dry run first, then pass its hash |
| `refused` | `inventory-changed` | `rerun-dry-run` | the node changed between the two passes; dry run again and use the new hash |
| `refused` | `enumeration-failed` | `investigate` | the inventory could not be read or hashed. Services were restored; nothing was deleted |
| `failed` / `interrupted` | — | `start-services` | packages untouched, services down: start containerd, wait, then docker |
| `failed` / `interrupted` | — | `investigate` | report `pkg_state`, `phase` and the log; do not guess between retry and rollback |

**Success.** The upgrade prints `UPGRADE COMPLETE` and the rollback prints
`ROLLBACK COMPLETE`. Verify anyway; a banner is not a version check.

**The cleanup banner is the one place a loose match is wrong.** Success prints the exact line
`NETWORK CLEANUP COMPLETE`, but an incomplete cleanup prints
`NETWORK CLEANUP COMPLETED WITH <n> FAILURE(S)` and exits 2 — and the success string is a
**prefix** of the failure string. A substring match reports a partial cleanup as a success.
Require the exact line **and** exit 0. Treat `COMPLETED WITH` or exit 2 as not done.

Both banners are printed in colour, so the log line carries ANSI escapes on either side of the
text. Strip them before matching exactly, or an exact-line match finds nothing:

```bash
sed 's/\x1b\[[0-9;]*m//g' /var/log/docker-network-cleanup.log | grep -xF 'NETWORK CLEANUP COMPLETE'
```

**Failure.** The upgrade and rollback scripts print a state report on every non-zero exit. It
names the phase, whether services are stopped, and what happened to the packages. Those three
facts decide what you do next, and the script does **not** decide for you — after an rpm
transaction, retry versus rollback depends on why it failed.

The two scripts use **different package strings**. The services lines are identical:
`Services:  STOPPED - this node is DOWN` and
`Services:  running (or never stopped by this script)`.

| Package line | `upgrade-docker.sh` | `rollback-docker.sh` |
|---|---|---|
| rpm never ran | `Packages:  UNCHANGED - rpm was never run` | same |
| rpm ran, outcome unknown | `UNKNOWN - the rpm transaction` | `UNKNOWN - the downgrade` |
| rpm succeeded | `Packages:  NEW packages installed successfully` | `Packages:  downgraded successfully` |

The table below uses the upgrade strings. **The decisions are not identical**, so when you are
reading a failed rollback, substitute these actions:

- `UNKNOWN - the downgrade` — establish what is installed, then bring the node up on whatever
  that is: start containerd, wait for `ctr version`, start docker. If containerd.io downgraded
  but docker-ce did not, the engine is newer than its runtime; **re-run the rollback** to
  finish. "Roll back" is not a second option here, and the script says so itself.
- `Packages:  downgraded successfully` with services stopped — diagnose the service failure,
  then start services. The retry is another rollback run, not an upgrade.

| Line to match | Services | Packages | Do this |
|---|---|---|---|
| `Packages:  UNCHANGED - rpm was never run` + `Services:  STOPPED` | down | original | `systemctl start containerd`, wait, `systemctl start docker`. The package transaction was not attempted |
| `Packages:  UNCHANGED - rpm was never run` + `Services:  running` | up | original | The package transaction was not attempted. Fix what the phase reported and re-run |
| `UNKNOWN - the rpm transaction` | either | **unknown** | Run `rpm -q docker-ce docker-ce-cli containerd.io` before anything else. Do not assume either version is installed. Then re-run the script, or roll back. **Escalate — do not choose on your own** |
| `Packages:  NEW packages installed successfully` + `Services:  STOPPED` | down | new | Diagnose the service failure from `journalctl -u containerd` and `journalctl -u docker`, then start services or roll back. **Escalate** |
| `Packages:  NEW packages installed successfully` + `Services:  running` | up | new | The upgrade did not finish cleanly but the node is up. Verify the five versions before returning it to service |

Two things the table's `UNCHANGED` rows do **not** mean. `untouched` says only that rpm was
never invoked. By that point the node may already have been drained, `dnf clean all` and
`rpm --rebuilddb` may have run, and a backup directory may exist. **After any failure at or
after phase 1, check Swarm availability from a manager** and restore the value you recorded in
step one if you are not about to retry. Do not simply set it to `active`: the trap prints a
reactivation command, and that command is right only when `active` is what you recorded.

The report also names the backup directory and the log file.

**Refusals from phase 0.** These all exit 1 before anything is stopped and before the real rpm
transaction runs. Nothing on the node has been replaced.

One caveat, and it is yours not the script's: if this is a **worker you drained in step one**,
it is still drained. Restore its recorded availability before you walk away.

| What the output says | What it means | Do this |
|---|---|---|
| `containerd 1.x DETECTED` | This script does not handle the containerd major migration | Stop. This node needs the older script named in the message. Do not force it |
| A digest, version, release, architecture or duplicate complaint | The bundle on this node is wrong or damaged | Stop the rollout. Re-transfer the bundle; do not patch the directory by hand |
| `rpm --test` refused the transaction | A dependency or space problem | Check `df -h /var` and the printed rpm output. Fix, then re-run |
| `stdin closed - cannot read an answer` **during phase 0** | You ran it without a terminal | Re-run with `ssh -t`. Nothing was changed. The same message later in the run means something else — see above |

**The one refusal that is not free.** Phase 6 refuses when the containerd config points at a
relocated root that does not exist — almost always an unmounted filesystem. By then packages
have already been replaced and services are stopped.

Recovery, in order:

1. Mount the filesystem. **Do not create the directory.** Creating it would start containerd
   against an empty root and make every image and snapshot look lost.
2. Confirm **both** that the directory exists and that it is the real filesystem:
   `test -d <the root> && findmnt --target <the root>`. The guard checks for the directory;
   `findmnt` alone would pass on a mounted parent with the directory still missing.
3. If the node is in a Swarm, confirm from a manager that it is still drained and still empty.
4. Re-run the script from the top. It is safe to re-run.
5. **Pass `--rerun-at-target`, or answer yes to the "Re-run the upgrade anyway?" question.**
   The phase-5 transaction already succeeded, so all five packages are at the target and the
   re-run opens at that gate, which defaults to **no**. Answering no exits 0 (or 3 under
   `--non-interactive`) without ever reaching phase 6, leaving the node with stopped services
   and nothing fixed. This is the one situation in which that flag is correct.
6. **If the node is in a Swarm, restore the recorded availability from a manager
   afterwards.** Do not wait for the script to do it.

Two things about that second run that will look wrong and are not:

- **The script will report the node as not being in a Swarm.** Docker is still stopped from
  the failed run, so the Swarm query fails, the state reads as unknown, and phase 10 is
  skipped entirely. That is why step 6 is yours to do.
- **It creates another backup directory and repeats the rpm transaction** at the same
  versions. Both are expected. It also re-runs phase 0 and the dry run, and may run
  `dnf clean all` and `rpm --rebuilddb` again in phase 2.

## Things only a manager can do

Three actions cannot happen on the node being upgraded. Do them from a manager, out of band.

1. **Draining a worker**, before the run. The worker's prompt only asks whether it happened.
2. **Reactivating a worker**, after the run. The worker prints the command and cannot run it.
3. **Confirming tasks have migrated.** `docker node ps` on a worker cannot see its own tasks,
   and the script skips its own task count entirely on a node that is already drained.

The fourth thing that is not the script's job: **mounting a missing relocated containerd
root.** That is a host problem, and phase 6 stops rather than paper over it.

## The other two scripts

**`rollback-docker.sh`** returns the node to the previous versions, which are bundled. It
validates the payload and dry-runs the rpm transaction before stopping anything, so a rollback
rpm would refuse outright fails while the node is still up. That is a bounded promise: the dry
run proves rpm's planned transaction resolves, not that scriptlets and file writes will
succeed.

**Run `rollback-docker.sh --preflight` before you need it.** It executes phases 0, 0b and 0c —
the payload validation, the `rpm --test` dry run, the backup selection and the config-version
guard — and exits without touching the node. That answers "would a rollback strand this node?"
while docker and containerd are still up, which is exactly when it is cheap to fix. Exit 0 with
`result=ready` means the rollback would proceed; exit 1 means it would refuse, and
`refusal_reason` says why. It is a bounded promise: it does not predict rpm scriptlets, or
whether a service will start.

It refuses outright, in phase 0c, when the containerd config the rollback would actually load
is a version the older containerd cannot read — because the downgrade would otherwise succeed
and leave the node with a runtime that will not start. Note *would actually load*: that is the
selected backup when one will be restored, and the on-disk file otherwise. Those are different
files. There is no override, and you should not look for one.

**Follow phase 0c's own recovery message exactly.** It has two shapes. When a usable backup
exists elsewhere it prints the `cp` to run, and — if the newest backup is the unusable one —
the `mv` that stops phase 3 restoring that backup over your copy. Run both. When no usable
config exists anywhere it says so and cannot fix it for you: it offers restoring an off-node
copy, or hand-editing the file while keeping the top-level `root` and `state` values exactly
as they are. **Escalate rather than hand-editing a containerd config on a production node.**

**`clean-swarm-networks.sh`** is a remedy, not a step. Run it only when a node comes back from
an upgrade unable to attach to overlay networks, or when dockerd logs `failed adding service
binding`. Drain the node and confirm it is empty first. It stops services, lists exactly what
it will delete, asks, and restores services if you decline. It exits **2** when the cleanup
completed but some items could not be removed — treat 2 as "not done", not as success. Without
a terminal it takes two passes; see the two-pass procedure in the flag section.

**`recover-dnf.sh`** is a diagnostic, and it is the **one script that fails open** at
end-of-file. With stdin closed it skips its Option A and exits 0 rather than refusing. That is
safe because declining Option A changes nothing, and it is the safe direction — but it is not
read-only: by the time it asks, it has already run `dnf clean all` and `rpm --rebuilddb`.
`--no-run-option-a` states the decline explicitly and is what an unattended caller should pass;
`--run-option-a` pre-answers yes and you should not pass it on a production air-gapped node —
see the never-do list.

## Never do this

Operational invariants. Each one has a failure mode that has actually happened or been
measured.

- **Never run `containerd config default > /etc/containerd/config.toml`.** On an upgraded node
  it writes a config version the rollback containerd cannot read, arming a trap that springs
  only during an emergency. The upgrade never overwrites an existing config; only its
  missing-file branch generates one, and it warns loudly when it has to.
- **Never pass `--assume-drained`, or answer that attestation yes, without having drained.**
  It asserts a fact about the rest of the cluster. It performs nothing, and the record notes
  that a flag was trusted rather than a check performed.
- **Never pass a gate flag to make a refusal go away.** `refusal_reason=gate-unanswered:<name>`
  is a question, not an obstacle. Verify the fact first; if you cannot, report and stop.
- **Never pass `--rerun-at-target` to turn an exit 3 into an exit 0.** Exit 3 means the node is
  already done. The only reason to re-run at target is a deliberate repair, and the phase-6
  recovery below is the one that needs it.
- **Never continue past `--proceed-with-tasks` to save time.** That gate exists because the
  drain did not finish. Under `--non-interactive` prefer `--no-proceed-with-tasks`: it refuses
  after the drain rather than upgrading a node still running work.
- **Never pass `--non-interactive` and then read only the exit code.** The mode requires
  `--status-file` for exactly this reason. Exit 1 covers both a safe refusal and a failure
  after the node was modified; `result`, `refusal_reason` and `pkg_state` separate them.
- **Never install or downgrade the engine and the runtime in separate rpm transactions.**
  Resolving them together is what stops a downgraded runtime ending up under a newer engine.
- **Never substitute the `containerd` package for `containerd.io`.** They are different
  packages and the plain one is the wrong thing.
- **Never skip phase 0 or the `rpm -Uvh --test` dry run**, and never hand-edit the package
  directory to get past a rejection.
- **Never replace packages or delete network state until docker, `docker.socket` and
  containerd are all conclusively stopped.** Phase 0's metadata validation and the
  `rpm -Uvh --test` dry run deliberately run while services are up; it is the real
  transaction and the network-state deletion that must wait. A nonzero `systemctl is-active` is not proof of that — it also
  returns nonzero for `activating`, for `deactivating`, and for failing to reach systemd. If
  `docker.socket` survives while dockerd is down, anything touching the socket starts dockerd
  again, mid-transaction.
- **Never start docker until containerd is actually ready** — both `ctr version` and
  `ctr snapshots --snapshotter overlayfs ls` must succeed. systemd reports containerd active
  before its snapshotter is usable, and a sleep is not readiness.
- **Never re-enumerate the cleanup inventory after the confirmation.** The list you were shown
  is the list that gets deleted; that is the whole point of enumerating after the stop. It is
  also why `--confirm-delete` alone is refused in every mode: a pre-declared yes would
  authorise deleting a list nothing had seen.
- **Never assume a version, or blindly restart services, after `UNKNOWN - the rpm
  transaction`.** Inspect what is installed first.
- **Never run `clean-swarm-networks.sh` as a routine post-upgrade step.** It is a destructive
  reset of daemon network state and forces an overlay reconvergence.
- **Never run `recover-dnf.sh` Option A on a production air-gapped host.** Its commands
  reference a `docker-local` repository that only exists on machines that ran the simulation
  path. On a real node they fail.
- **Never extract a bundle over an existing `/opt/docker-offline`.**
- **Never blindly return a node to `active`.** Restore the availability you recorded before
  the run. A node that was deliberately `pause` or `drain` must go back to that.
- **Never treat a missing anchor string as success.** If you cannot find `UPGRADE COMPLETE`,
  the state is unknown, not good. And never treat `NETWORK CLEANUP COMPLETED WITH` as success
  merely because it contains `NETWORK CLEANUP COMPLETE`.

## When this document does not cover it

Stop and report. Do not improvise on a disconnected production node.

- `RUNBOOK.md` has the human procedure, the node ordering and the soak guidance.
- The logs are `/var/log/docker-upgrade.log`, `/var/log/docker-rollback.log` and
  `/var/log/docker-network-cleanup.log`. They are appended to, not rotated, so a run's output
  sits at the end and older runs sit above it. They contain ANSI escapes.
- Backups are `/root/docker-backup-<timestamp>/`, named so that lexical order is chronological.

A note on what does not exist. There is no `--yes`, and there never will be: a blanket consent
flag is exactly what the per-gate flags replace. `rollback-docker.sh` has no gate flags, because
its one question is a value — `--config-backup` — rather than a yes/no. `--confirm-delete` has no
form that works on its own, in any mode. Do not invent flags: an unrecognised argument is a
usage error, so a misspelled one fails loudly instead of being ignored.

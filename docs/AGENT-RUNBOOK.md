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

Three things make this hard to drive, and none of them is fixed yet.

**You need a terminal.** In the upgrade, rollback and network-cleanup scripts every prompt
goes through one helper that treats end-of-file as a refusal, not as a default. It prints
`ERROR: stdin closed - cannot read an answer.` and exits 1. That is deliberate: a wrapper
piping `/dev/null` would otherwise silently answer yes to every prompt, including the three
that default to yes. `recover-dnf.sh` is the exception and behaves differently — see below.

- `ssh host /opt/docker-offline/upgrade-docker.sh` fails at the first prompt it reaches. Use
  `ssh -t`. Some runs reach no prompt at all — an expected-baseline upgrade on a non-Swarm
  host, or a rollback with at most one backup — but you cannot know that in advance, so
  always allocate a terminal.
- Piping input works but is dangerous, because you are answering questions you cannot read.
  Do not do it.

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

Nonzero is worse. Every deliberate refusal uses 1, but a command that fails under `set -e`
propagates its own status, and an interrupt exits 130 or 143. **The important point is that a
nonzero status alone does not distinguish a safe refusal from a failure after the node was
modified.** You must read the output.

**Nothing is machine-readable.** There is no status file and no structured output. The anchors
below are real strings the scripts print today, but they are prose and they are not a
contract. Match them loosely and treat a non-match as unknown, never as good news.

Some lines carry ANSI colour codes mid-line. `Packages:  UNKNOWN` does **not** match, because
an escape sequence sits between the colon and the word. Match `UNKNOWN - the rpm transaction`
instead. `Packages:  UNCHANGED` and `Packages:  NEW` have no such escape and do match.

## Preconditions

- **Run as root.** No script checks this. A non-root run fails partway with a permission error
  and no explanation.
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
| **Manager, `active` or `unknown`** | **Nothing.** Let phase 0 run first, then answer the drain prompt yes and let the script drain and count tasks for you. This is the ordering the script exists to provide |
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

**Step two — run the upgrade on the node, on a terminal.**

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

A manager that ends the run drained is offered a reactivation prompt that defaults to **yes**.
Answer yes only if you recorded `active`. If you recorded `pause` or `drain`, answer **no** —
it prints the command and leaves the node drained — then set the recorded value yourself.
A worker is never offered the prompt and always needs this step done from a manager.

## The prompts, and how to answer each

The bracketed letter is the default, but the default only applies to an empty line of input.
End-of-file is refused, not defaulted.

### `upgrade-docker.sh`

| When it fires | Question | Default | How to decide |
|---|---|---|---|
| All five packages already at target | Re-run the upgrade anyway? | no | **No**, unless you are deliberately repairing a node — see the phase-6 recovery below, where the answer is yes. The no branch changes nothing and exits 0 |
| Not at target, not a partial upgrade, and docker or containerd differs from the tested starting pair | Continue from this unverified starting version? | no | **No** by default. Report the versions it printed and stop. Yes only if a human has approved that specific starting version. Note this does **not** fire on a partial upgrade: if either core package is already at target the script proceeds without asking |
| Manager whose availability reads `active` **or** `unknown` | Drain this node now? | **yes** | Yes. `unknown` means the node inspect failed, so treat it as undrained. If you already drained in step one this prompt does not fire at all |
| Tasks could not be counted after the drain | Continue with upgrade anyway? | no | **No.** Check `docker node ps` from another manager first. "Could not count" is not "none" |
| Tasks are still on the node after the drain | Continue with upgrade anyway? | no | **No.** Wait for them to migrate, confirm empty from a manager, then re-run |
| Worker | Has this node been drained from a manager? | no | Yes **only if you performed step one and saw the task list empty**. This is an attestation, not an instruction — answering yes drains nothing |
| Manager finished the upgrade while drained | Set this node back to ACTIVE? | **yes** | Yes **only if the availability you recorded in step one was `active`**, and only once you have verified the node. Otherwise no: it leaves the node drained and prints the command, and you then set the recorded value |

### `rollback-docker.sh`

One prompt, and only when more than one `/root/docker-backup-*` directory exists.

| Question | Default | How to decide |
|---|---|---|
| Use the backup marked above? | **yes** | The newest is not necessarily the one belonging to the upgrade you are rolling back. If you cannot tell which is right, answer no — it exits 0 having changed nothing — and **stop**. Do not simply copy a different `config.toml` into place and re-run: the next run selects the newest backup again and phase 3 restores it over your copy. Escalate so the backup selection is resolved first |

### `clean-swarm-networks.sh`

Four prompts, two of them unconditional — the drain attestation and the stop confirmation.
Because those two always fire, this script cannot be run without a terminal at all.

| When it fires | Question | Default | Decline does |
|---|---|---|---|
| Swarm state is anything but `active` | Continue anyway? | no | exits 0, nothing changed |
| Always, after the above | Has this node been drained? | no | exits 0, nothing changed |
| Always, after the above | Stop docker and containerd now? | no | exits 0, nothing changed |
| Only when the enumerated inventory is non-empty | Delete the state listed above? | no | restarts services, exits 0, nothing deleted |

The drain attestation here attests only to the drain. The script never checks task emptiness,
so confirm it yourself from a manager before running this.

## Reading the outcome

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
5. **Answer yes to the "Re-run the upgrade anyway?" prompt.** The phase-5 transaction already
   succeeded, so all five packages are at the target and the re-run opens with that prompt,
   which defaults to **no**. Answering no exits 0 without ever reaching phase 6, leaving the
   node with stopped services and nothing fixed.
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
completed but some items could not be removed — treat 2 as "not done", not as success.

**`recover-dnf.sh`** is a diagnostic. It does **not** refuse end-of-file: with stdin closed it
skips its Option A and exits 0. That is safe but it is not read-only — by the time it asks, it
has already run `dnf clean all` and `rpm --rebuilddb`.

## Never do this

Operational invariants. Each one has a failure mode that has actually happened or been
measured.

- **Never run `containerd config default > /etc/containerd/config.toml`.** On an upgraded node
  it writes a config version the rollback containerd cannot read, arming a trap that springs
  only during an emergency. The upgrade never overwrites an existing config; only its
  missing-file branch generates one, and it warns loudly when it has to.
- **Never answer the worker drain attestation yes without having drained.** It asserts a fact
  about the rest of the cluster. It performs nothing.
- **Never continue past the tasks-remaining prompt to save time.** That prompt exists because
  the drain did not finish.
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
  is the list that gets deleted; that is the whole point of enumerating after the stop.
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

A note on what does not exist: there is no `--yes`, no `--non-interactive`, no `--preflight`
and no status file. If you find yourself wanting one, that is the correct instinct and the work
is planned — but do not invent flags. An unrecognised argument is silently ignored today, which
means a run you believe was non-interactive is an ordinary interactive run waiting on a prompt.

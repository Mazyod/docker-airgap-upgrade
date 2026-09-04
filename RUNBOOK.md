# Runbook — Docker 29.1.5 → 29.8.0 on Air-Gapped RHEL 8/9 Swarm

**Target:** docker-ce 29.8.0, containerd.io 2.3.4-**2**, buildx 0.37.0, compose 5.5.1
**From:** docker-ce 29.1.5, containerd.io 2.2.1
**Rollback:** 29.1.5 / 2.2.1 (bundled)

This crosses containerd 2.2 → 2.3, a minor bump onto containerd's first annual LTS.
It is substantially lower risk than the 28.5.1 → 29.1.5 round, and **nodes can be
rolled one at a time**.

⚠️ **This bundle changes runc.** `containerd.io` 2.3.4 was published twice. Both
builds report version `2.3.4`; `-1` carries runc 1.4.3 and `-2` carries runc 1.5.1.
This bundle takes `-2`, so every container on the node ends up on a new runtime
binary. `upgrade-docker.sh` phase 0 asserts the RPM release and refuses a bundle
built from `-1`, because the version string alone cannot tell them apart. If phase 0
rejects your bundle for the containerd release, re-download it — do not work around
the check.

⚠️ **One thing to know before you roll back.** containerd 2.3.4 supports config
version 4; 2.2.1 supports at most 3. The upgrade never writes a v4 config, so a
normal rollback is unaffected. But if anyone runs
`containerd config default > /etc/containerd/config.toml` on an upgraded node, that
node can no longer be rolled back until the config is reverted — `rollback-docker.sh`
phase 0c detects this and stops before touching anything. Don't run that command.

> **Driving this from an agent rather than by hand?** `docs/AGENT-RUNBOOK.md` is the
> operating guide: the gate flags, `--preflight`, the `--status-file` record and the
> decision table, in one document. Its first five sections are the whole **upgrade**
> procedure; the rollback and the cleanup have their own sections. This file stays the
> human procedure and the timings.
>
> **Found a `key=value` file on a node and wondering what it is?** That is an agent
> run record, written by `--status-file`. Its last line is `status_complete=1`; without
> that line the record is incomplete and means nothing. `result`, `refusal_reason` and
> `pkg_state` say what happened, and `docs/AGENT-RUNBOOK.md` has the full key reference.

---

## Before you start

- [ ] Tier 2 of `docs/TEST-PLAN.md` has passed on a VM matching each RHEL major you run
- [ ] Maintenance window agreed; know which node is least critical
- [ ] You can reach a Swarm **manager** to drain/reactivate workers
- [ ] The bundle is on every target node, extracted to a clean directory
- [ ] `/var` has room: the bundle is ~340 MB and rpm needs working space

**Do not skip the VM test.** These scripts cannot be executed on a Mac, so nothing in
this repo has been run end to end until you run it.

---

## Stage 1 — Build the bundle (online RHEL server)

Run on an **online** RHEL server, from a full checkout of this repo.

```bash
cd <repo>
chmod +x *.sh
./download-docker-packages.sh
```

Produces `/opt/docker-upgrade-bundle.tar.gz`.

The script aborts if any download 404s, any RPM in the four Docker directories fails
digest verification, or any operator script is missing — so success means the Docker
half of the bundle is complete. The NVIDIA packages are neither pinned nor digest
checked, because phase 7 is best-effort and a GPU-less fleet does not need them.
Verify:

```bash
tar tzf /opt/docker-upgrade-bundle.tar.gz | head -30
du -h /opt/docker-upgrade-bundle.tar.gz
```

Expect `rhel8/`, `rhel9/`, `rollback-rhel8/`, `rollback-rhel9/`, `nvidia/`, and four
`.sh` files.

## Stage 2 — Transfer

Move `docker-upgrade-bundle.tar.gz` to each target node by your approved method.

## Stage 3 — Upgrade one node

Pick the **least critical node first**. Repeat this whole stage per node.

### 3.1 Extract to a clean directory

```bash
rm -rf /opt/docker-offline
tar xzf docker-upgrade-bundle.tar.gz -C /opt/
cd /opt/docker-offline
```

`rm -rf` first is not optional. Extracting over a previous bundle leaves 29.1.5 and
29.8.0 RPMs side by side; the script now rejects that, but avoiding it is cleaner.

### 3.2 Record the starting state

```bash
rpm -q docker-ce docker-ce-cli containerd.io
grep '^root' /etc/containerd/config.toml   # note this if it is not /var/lib/containerd
docker node ls                              # from a manager
```

### 3.3 Drain (workers only — from a MANAGER)

```bash
docker node update --availability drain <node-hostname>
docker node ps <node-hostname>              # wait for tasks to migrate
```

Managers drain themselves interactively during the run.

### 3.4 Run the upgrade

```bash
./upgrade-docker.sh
```

What it will do, in order:

| Phase | What happens | Safe to abort? |
|---|---|---|
| 0 | Validates packages: digests, metadata, all five versions, arch, release, duplicates, `rpm --test` dry run; checks the starting version | **Yes — node untouched** |
| 1 | Swarm detect; manager self-drain or worker attestation | Yes |
| 2 | Pre-upgrade checks | Yes |
| 3 | Backup to `/root/docker-backup-<timestamp>/` | Yes |
| 4 | Stop docker → docker.socket → containerd, verify all conclusively stopped | Node is now down |
| 5 | `rpm -Uvh` the validated set | **Point of no return** |
| 6 | Verify containerd config (does **not** rewrite it) | — |
| 7 | NVIDIA toolkit, if installed (best effort) | — |
| 8 | Start containerd → poll API and snapshotter → start docker | — |
| 9 | Verify, and assert all five installed versions | — |
| 10 | Swarm reactivation | — |

Everything that can fail without consequence fails in phase 0, while the node is
still serving and still active in the Swarm.

**Phase 0 will stop you, deliberately, if:**

| Condition | Why |
|---|---|
| containerd 1.x installed | This script no longer handles the 1.7 → 2.x major migration. Use v1.2.3 (`974683a`). |
| Starting version isn't 29.1.5 / 2.2.1 | Warns and asks. Untested path. |
| Wrong, duplicate, corrupt, wrong-arch or wrong-release RPMs | Checked against RPM **metadata**, not filenames |
| buildx / compose not at 0.37.0 / 5.5.1 | A bundle carrying last round's plugins shouldn't report success |
| `containerd.io` RPM release is not `2` | 2.3.4-1 and 2.3.4-2 share a version and differ only in runc (1.4.3 vs 1.5.1) |
| `rpm --test` refuses the transaction | Dependency or space problem, caught while the node is still up |

**Phase 6 will stop you if** the config points at a relocated containerd root
(e.g. `/data/containerd`) that does not exist. That almost always means its
filesystem isn't mounted; creating the directory would start containerd against an
empty root and make every image and snapshot look lost.

### 3.5 Verify

```bash
docker version | grep -A2 Server        # 29.8.0
containerd --version                    # 2.3.4
runc --version                          # 1.5.1
rpm -q docker-ce docker-ce-cli containerd.io
rpm -q containerd.io --queryformat '%{VERSION}-%{RELEASE}\n'   # 2.3.4-2.el<major>
# <major> is THIS host's RHEL major -- 2.3.4-2.el8 on RHEL 8, 2.3.4-2.el9 on
# RHEL 9. The upgrade builds the same string from `rpm -E %rhel`, so an el8 node
# reporting el8 is correct, not a failed upgrade.

# containerd config was preserved, not regenerated
grep '^root' /etc/containerd/config.toml   # must match what you recorded in 3.2

docker ps -a                            # containers survived
```

From a manager:

```bash
docker node ls                          # node Ready and Active
docker node ps <node-hostname>          # tasks scheduling again
docker service ls                       # all replicas converged
```

### 3.6 Reactivate (workers — from a MANAGER)

```bash
docker node update --availability active <node-hostname>
```

### 3.7 Soak

Give the node 10–15 minutes under real traffic before moving to the next one. Watch:

```bash
journalctl -u docker -f
```

Then return to 3.1 for the next node.

---

## If something goes wrong

The upgrade script tells you which phase failed, whether services are stopped, and
whether the rpm transaction ran. **Read that block before doing anything.** It
distinguishes three package states, and they need different responses:

| Reported state | Meaning | Do this |
|---|---|---|
| `UNCHANGED - rpm was never run` | Failure before phase 5 | `systemctl start containerd && sleep 5 && systemctl start docker` |
| `UNKNOWN - transaction did not complete cleanly` | rpm ran and failed partway | Check `rpm -q docker-ce docker-ce-cli containerd.io` first. Then re-run `./upgrade-docker.sh`, or roll back. Do **not** assume either version is installed. |
| `NEW packages installed successfully` | rpm succeeded, something later failed | Diagnose the service failure, then start services or roll back |

### Node won't attach to overlay networks

Symptom: dockerd logs `failed adding service binding`, or services never schedule
onto the node while running fine elsewhere.

```bash
# Drain from a manager first
docker node update --availability drain <node-hostname>

/opt/docker-offline/clean-swarm-networks.sh
```

It shows exactly what it will delete and asks before deleting. It restores services
on failure and exits 2 if the cleanup was incomplete.

To see the list without deleting anything, add `--dry-run`: it stops, enumerates,
prints the inventory and its hash, restarts and exits 0. Without a terminal the script
takes two passes, and `docs/AGENT-RUNBOOK.md` has the procedure.

### Roll back

```bash
/opt/docker-offline/rollback-docker.sh
```

Add `--preflight` to run the payload validation, the `rpm --test` dry run, the
backup selection and the config-version guard **without touching the node** — that
answers "would a rollback strand this node?" while everything is still up. Add
`--config-backup=DIR` to name the backup phase 3 should restore rather than taking
whichever is newest.

Returns the node to 29.1.5 / 2.2.1. It validates and dry-runs before stopping
anything, so a rollback that cannot succeed fails while the node is still up.

A rolled-back node **can rejoin a cluster containing 29.8.0 nodes** — both are
Docker 29.x engines speaking the same Swarm protocol. containerd's version is local
to each node.

If phase 0c refuses the rollback, it is telling you `/etc/containerd/config.toml` is
a version containerd 2.2.1 cannot load. Restore the copy from
`/root/docker-backup-<timestamp>/config.toml` and re-run. The node stays up
throughout; nothing has been changed.

### dnf dependency problems

```bash
/opt/docker-offline/recover-dnf.sh
```

Note: it prints commands referencing `--enablerepo=docker-local`, which does not
exist on production air-gapped hosts. Create it first or those commands will fail.

---

## Logs

| File | From |
|---|---|
| `/var/log/docker-upgrade.log` | `upgrade-docker.sh` |
| `/var/log/docker-rollback.log` | `rollback-docker.sh` |
| `/var/log/docker-network-cleanup.log` | `clean-swarm-networks.sh` |
| `/root/docker-backup-<timestamp>/` | pre-upgrade state snapshot |

---

## Things worth knowing

**Mixed versions are fine here.** 29.1.5 and 29.8.0 are both Docker 29.x engines
speaking the same Swarm protocol; containerd runs locally on each node and its
version does not cross the wire. A partially upgraded cluster is a supported state,
so you can stop between any two nodes. This is *not* true across the containerd
1.7 ↔ 2.x boundary. (Note: mixed-version clusters are Tier 3 and have not been
executed on a real multi-node cluster — see `docs/TEST-PLAN.md`.)

**containerd config is preserved.** The previous script regenerated
`/etc/containerd/config.toml` from scratch. This one does not — if a node's
containerd `root` was relocated during the last upgrade, or you have registry
mirrors configured, that survives. Verifying this in step 3.5 is worth the ten
seconds.

**cgroup v1 is deprecated** as of Docker 29.0.0 with support through May 2029. RHEL 8
defaults to v1. Not blocking; nothing here changes it.

**NVIDIA is best effort.** A corrupt or missing NVIDIA package warns and skips rather
than aborting the engine upgrade.

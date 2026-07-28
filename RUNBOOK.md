# Runbook — Docker 29.1.5 → 29.6.2 on Air-Gapped RHEL 8/9 Swarm

**Target:** docker-ce 29.6.2, containerd.io 2.2.6, buildx 0.35.0, compose 5.3.1
**From:** docker-ce 29.1.5, containerd.io 2.2.1
**Rollback:** 29.1.5 / 2.2.1 (bundled)

This upgrade stays inside the containerd 2.2.x line. It is substantially lower risk
than the 28.5.1 → 29.1.5 round, and **nodes can be rolled one at a time**.

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

The script aborts if any download 404s, any RPM fails digest verification, or any
operator script is missing — so success means the bundle is complete. Verify:

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
29.6.2 RPMs side by side; the script now rejects that, but avoiding it is cleaner.

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
| 0 | Validates packages: digests, metadata, versions, arch, release, duplicates, rpm dry run | **Yes — node untouched** |
| 1 | Swarm detect; manager self-drain or worker attestation | Yes |
| 2 | Pre-upgrade checks | Yes |
| 3 | Backup to `/root/docker-backup-<timestamp>/` | Yes |
| 4 | Stop docker → docker.socket → containerd, verify all stopped | Node is now down |
| 5 | `rpm -Uvh` the validated set | **Point of no return** |
| 6 | Verify containerd config (does **not** rewrite it) | — |
| 7 | NVIDIA toolkit, if installed (best effort) | — |
| 8 | Start containerd → poll readiness → start docker | — |
| 9 | Verify, and assert installed versions | — |
| 10 | Swarm reactivation | — |

Everything that can fail without consequence fails in phase 0, while the node is
still serving and still active in the Swarm.

### 3.5 Verify

```bash
docker version | grep -A2 Server        # 29.6.2
containerd --version                    # 2.2.6
rpm -q docker-ce docker-ce-cli containerd.io

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

### Roll back

```bash
/opt/docker-offline/rollback-docker.sh
```

Returns the node to 29.1.5 / 2.2.1. It validates and dry-runs before stopping
anything, so a rollback that cannot succeed fails while the node is still up.

A rolled-back node **can rejoin a cluster containing 29.6.2 nodes** — both speak
containerd 2.2.x gRPC.

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

**Mixed versions are fine here.** 29.1.5 and 29.6.2 both speak containerd 2.2.x
gRPC. A partially upgraded cluster is a supported state, so you can stop between any
two nodes. This is *not* true across the containerd 1.7 ↔ 2.x boundary.

**containerd config is preserved.** The previous script regenerated
`/etc/containerd/config.toml` from scratch. This one does not — if a node's
containerd `root` was relocated during the last upgrade, or you have registry
mirrors configured, that survives. Verifying this in step 3.5 is worth the ten
seconds.

**cgroup v1 is deprecated** as of Docker 29.0.0 with support through May 2029. RHEL 8
defaults to v1. Not blocking; nothing here changes it.

**NVIDIA is best effort.** A corrupt or missing NVIDIA package warns and skips rather
than aborting the engine upgrade.

# Docker Engine 29.1.5 → 29.7.2 Upgrade for Air-Gapped RHEL 8/9

Scripts for upgrading Docker Engine from 29.1.5 to 29.7.2 on air-gapped RHEL 8 and
RHEL 9 servers.

## Why This Upgrade

This picks up the cumulative fixes from Docker 29.2 through 29.7, including security
updates and several overlay-networking fixes that matter for Swarm:

- 29.0.0 — NetworkDB fix for overlay entries stuck in a deleted state
- 29.5.0 — fix for stale VIP DNS records during rolling updates
- 29.3.0 — minimum API version lowered from v1.44 back to v1.40
- 29.7.0 — CVE-2026-17106 (`moby/go-archive`); fixes two daemon panics, one of them
  when removing Swarm ingress ports after an ingress proxy listener fails to bind
- 29.7.2 — nftables base-chain policy compatibility fix

It does **not** stay inside one containerd line: containerd.io goes 2.2.1 → 2.3.3,
a minor bump onto containerd's first annual LTS. That raises the containerd config
version from 3 to 4, which is read-compatible going forward and **not** backward —
see [The containerd config version](#the-containerd-config-version) below. It is
still far lower risk than the 28.5.1 → 29.1.5 upgrade that preceded it, which
crossed the containerd 1.7 → 2.x *major* boundary.

### Take 29.7.2 specifically, not 29.7.0 or 29.7.1

29.7.0 shipped three regressions that were fixed across the following week. One of
them matters directly here:

> Fix a regression introduced in Docker Engine 29.7.0 that could cause image pulls
> and `docker cp` to fail on **older Linux kernels** when applying file permissions,
> including for device nodes. ([moby/moby#53305](https://github.com/moby/moby/pull/53305))

RHEL 8 ships a 4.18 kernel. Do not ship 29.7.0 or 29.7.1 to this fleet.

## Versions

| Package | From | To |
|---|---|---|
| docker-ce | 29.1.5 | **29.7.2** |
| docker-ce-cli | 29.1.5 | **29.7.2** |
| containerd.io | 2.2.1 | **2.3.3** |
| docker-buildx-plugin | 0.30.1 | **0.36.1** |
| docker-compose-plugin | 5.0.1 | **5.5.0** |

Rollback target is **29.1.5 / containerd.io 2.2.1**.

`docker-buildx-plugin` and `docker-compose-plugin` version independently of
docker-ce. Do not pin them to the docker-ce version.

**Upstream release dates**, as of the 2026-08-19 retarget — worth a glance, because
"latest" and "settled" are not the same thing on an air-gapped fleet you cannot
easily patch:

| Package | Version | Released | Age at retarget |
|---|---|---|---|
| docker-ce | 29.7.2 | 2026-08-06 | 13 days |
| containerd.io | 2.3.3 | 2026-07-10 | ~6 weeks |
| docker-buildx-plugin | 0.36.1 | 2026-08-04 | 15 days |
| docker-compose-plugin | 5.5.0 | **2026-08-17** | **2 days** |

compose 5.5.0 is the one outlier. It carries no breaking changes over the 5.0.1
baseline (the only 5.x break — the internal builder being replaced by Docker Bake —
landed in 5.0.0, which this cluster is already past), and the compose plugin is a CLI
tool rather than part of the engine or runtime, so the blast radius is small. If you
would rather have something more weathered, `docker-compose-plugin` 5.4.0
(2026-08-03) is a drop-in substitute — change `TARGET_COMPOSE` in
`tests/vm/lib.sh` and `WANT_COMPOSE` in `tests/static-checks.sh` first, then run
`tests/static-checks.sh`; it will name every other file that still needs editing.

### Package Name Clarification

```
WRONG: containerd (standalone package)
RIGHT: containerd.io (Docker's bundled containerd)
```

## The containerd config version

containerd 2.2.1 supports config **version 3**. containerd 2.3.3 raises the current
version to **4**. The compatibility is one-directional, and both directions were
measured on a real node with a relocated containerd root — not read off release
notes. `tests/vm/config-version-check.sh` re-runs the whole thing.

| | Result |
|---|---|
| v3 config under containerd **2.3.3** | **Loads.** Migrated in memory at load time, logging `Configuration migrated from version 3`. The file on disk is not touched — it stayed byte-identical across the rpm transaction. A relocated `root` survives: `containerd config dump` still reports it. |
| v4 config under containerd **2.2.1** | **Refuses to start:** `failed to load TOML from /etc/containerd/config.toml: expected containerd config version equal to or less than 3, got 4` |

So the upgrade itself is safe and needs no config migration. The risk is entirely in
the **rollback** direction: a node that somehow acquires a v4 config is one emergency
rollback away from a runtime that will not start.

Nothing in these scripts writes a v4 config. The realistic way a node gets one is an
operator running `containerd config default > /etc/containerd/config.toml`, since
under 2.3.3 that emits v4. (`containerd config migrate` is harmless — it writes to
stdout, not to the file.)

**`rollback-docker.sh` phase 0c guards this**, *before stopping anything*. It checks
the config containerd will actually be asked to load after the rollback — which is
not always the file currently on disk. Phase 3 restores the selected backup when
there is one, so when a backup exists that is the file phase 0c checks. (Checking
only the on-disk file would miss an absent config paired with a backup that itself
holds a v4 file.) If that config is one containerd 2.2.1 cannot load, the rollback is
refused and the node is left running.

If you hit that refusal, the message names the offending file and its version. Phase
0b only ever selects the *newest* backup, so if an older `/root/docker-backup-*/`
holds a usable config, phase 0c finds it and prints the exact `cp` to run. Otherwise
restore a pre-upgrade copy from off the node, or hand-edit `version = 3` and drop any
v4-only keys — **keeping the top-level `root` and `state` values exactly as they
are**, since changing `root` repoints the node at a different data directory.

## What Changed From the Previous Upgrade Round

Three things the 1.7 → 2.x migration required have been removed, because at a minor
containerd bump they are inert or harmful. All three remain in git history at
`upgrade-docker.sh` v1.2.3 (commit `974683a`) for a future containerd major bump.

| Removed | Why |
|---|---|
| containerd config regeneration (phase 6) | 2.3.3 reads the existing v3 config and migrates it in memory, so there is nothing to migrate on disk. Regenerating would discard a relocated `root` path, registry mirrors, and runtime config — silently repointing a node at an empty `/var/lib/containerd` — and would write a v4 file that blocks rollback. Phase 6 **verifies** the config instead of rewriting it. |
| XFS `ftype=1` check and relocation prompt | Any node already running containerd 2.x has satisfied this requirement. The check cannot fire usefully. |
| Automatic orphaned-network cleanup (phase 4.5) | The daemon now stops cleanly, so there is nothing orphaned. Extracted to `clean-swarm-networks.sh`, to be run on demand. |

## Scripts

| Script | Version | Purpose | Run On |
|---|---|---|---|
| `download-docker-packages.sh` | 2.2.0 | Download all packages, build the bundle | Online RHEL server |
| `upgrade-docker.sh` | 2.1.0 | Perform the upgrade | Air-gapped servers |
| `rollback-docker.sh` | 2.1.0 | Roll back to 29.1.5 | Failed upgrade recovery |
| `clean-swarm-networks.sh` | 1.0.0 | Reset orphaned overlay network state | Node that can't rejoin overlays |
| `recover-dnf.sh` | 1.2.2 | Fix dependency issues | Servers with broken dnf |
| `simulate-upgrade.sh` | — | Test the upgrade path in a VM | RHEL test VM |

Script versions drift on purpose — only scripts that actually changed get bumped.

## Usage

### Step 1: Get the bundle

**Preferred — download a published release** (no online RHEL server needed):

```bash
gh release download v29.7.2-1
sha256sum -c <<< '<sha from the release notes>  docker-upgrade-bundle-v29.7.2-1.tar.gz'
```

Each release enumerates every package and version it contains, and ships one artifact
holding all RPMs, the operator scripts and the runbook. See `docs/RELEASING.md`.

**Or build it yourself on an online RHEL server:**

```bash
chmod +x download-docker-packages.sh
./download-docker-packages.sh
```

Produces `/opt/docker-upgrade-bundle.tar.gz` (~340 MB plus NVIDIA packages),
containing the 29.7.2 packages for RHEL 8 and 9, the 29.1.5 rollback set, the NVIDIA
Container Toolkit, and all operator scripts.

The script fails loudly if any download 404s or any RPM fails digest verification —
a bundle full of HTML error pages is not discovered on the air-gapped side.

### Step 2: Transfer

Move `docker-upgrade-bundle.tar.gz` to the air-gapped servers via USB or approved
transfer.

### Step 3: Upgrade Each Server

```bash
# Extract to a CLEAN directory. Extracting over an existing /opt/docker-offline
# leaves both old and new RPMs in place; the upgrade script now rejects that,
# but it is easier to avoid.
rm -rf /opt/docker-offline
tar xzvf docker-upgrade-bundle.tar.gz -C /opt/

cd /opt/docker-offline
./upgrade-docker.sh
```

The script handles Swarm drain and reactivation interactively. Managers drain
themselves; **workers cannot drain or inspect themselves** and will print the
manager-side command and ask you to confirm the node has been drained.

Nodes can be rolled **one at a time** — see "Rolling node by node" below.

### If Something Goes Wrong

**Upgrade failed:** the script prints which phase it failed in, whether services are
stopped, and whether the RPM transaction completed. Follow the printed guidance; do
not guess.

**Node came back but can't attach to overlay networks** (`failed adding service
binding`, or services never scheduling onto it):

```bash
/opt/docker-offline/clean-swarm-networks.sh
```

Drain the node from a manager first. The script shows exactly what it will delete
and asks before deleting anything.

**Need to roll back:**

```bash
/opt/docker-offline/rollback-docker.sh
```

**dnf dependency issues:**

```bash
/opt/docker-offline/recover-dnf.sh
```

Note: `recover-dnf.sh` prints commands referencing an `--enablerepo=docker-local`
repo. That repo only exists on machines that ran the simulation path. On production
air-gapped hosts it must be created first, or those commands will fail.

## Rolling Node by Node

**The "upgrade the whole cluster together" rule does not apply to this upgrade.**

29.1.5 and 29.7.2 are both Docker 29.x engines and speak the same Swarm protocol, so
a mixed 29.1.5 / 29.7.2 Swarm is supported and will not produce the ALPN handshake
errors a mixed 1.7 / 2.2 cluster did. containerd is a per-node local runtime — the
2.2.1 / 2.3.3 difference does not cross the wire between nodes. Upgrade a node,
verify it, then move to the next.

That rule still applies across the containerd 1.7 ↔ 2.x boundary. Do not mix those.

**Caveat on how well this is tested:** mixed-version clusters are Tier 3 in
`docs/TEST-PLAN.md` and have **not** been executed — the VM harness is a single node.
The claim above rests on both engines being Docker 29.x, not on a measurement.

## Verification

After upgrade:

```bash
# Versions
docker version          # Should show 29.7.2
containerd --version    # Should show 2.3.3

# Packages
rpm -q docker-ce docker-ce-cli containerd.io

# containerd config was preserved, not regenerated
grep '^root' /etc/containerd/config.toml

# Swarm node rejoined and is scheduling
docker node ls                    # from a manager
docker node ps $(hostname)        # from a manager

# DNS on a custom bridge
docker network create test-net
docker run --rm --network test-net alpine nslookup google.com
docker network rm test-net
```

`upgrade-docker.sh` asserts all five installed versions itself in phase 9 and exits
non-zero if any do not match, so "UPGRADE COMPLETE" means the versions were checked.

### What the script refuses to do

Phase 0 aborts, with the node untouched, on: containerd 1.x installed (that is the
major migration this version no longer handles — use v1.2.3, commit `974683a`);
wrong, duplicate, corrupt, wrong-arch or wrong-release RPMs; plugins not at
0.36.1 / 5.5.0; or an `rpm --test` dry run that the transaction fails. An unexpected
starting version warns and asks.

Phase 6 aborts if the config points at a **relocated** containerd root that does not
exist — that normally means its filesystem is unmounted, and creating the directory
would silently orphan every image and snapshot on the node.

## Testing

| Tier | Status | How |
|---|---|---|
| Static | **122/122** | `./tests/static-checks.sh --online` |
| VM (real execution) | **45/45** | `./tests/vm/bootstrap-vm.sh && ./tests/vm/build-bundle.sh && ./tests/vm/tier2-run.sh` |
| Negative control | **3/3** | `./tests/vm/negative-control.sh` |
| Swarm | **not run** | needs a multi-node cluster — see `docs/TEST-PLAN.md` Tier 3 |

The VM tier runs the real scripts against Rocky Linux 9 (x86_64, systemd) via
OrbStack, with containerd's root relocated to a separate XFS filesystem holding real
images, containers and volume data. It covers the phase-0 rejections, the real
upgrade, config preservation, idempotent re-run, and rollback.

**Swarm behaviour is entirely untested** — drain, reactivation, overlay
reconvergence, mixed-version operation and `clean-swarm-networks.sh`. Tier 3 in
`docs/TEST-PLAN.md` is mandatory before a production rollout, and specifically 3.3/3.4
are what authorize rolling node by node.

## Notes

**cgroup v1 is deprecated** as of Docker 29.0.0, with support continuing through May
2029. RHEL 8 defaults to cgroup v1; RHEL 9 defaults to v2. This is not blocking for
this upgrade, and these scripts do not change node cgroup configuration.

**NVIDIA is best-effort.** `libnvidia-container-devel` and
`libnvidia-container1-debuginfo` are force-removed first because they pin old
versions. Failures warn rather than abort. `nvidia-ctk runtime configure
--runtime=containerd` is deliberately skipped — `nvidia-ctk` does not understand
containerd config v3 yet.

**Service order is not optional.** Stop `docker` → `docker.socket` → `containerd`.
Start `containerd` → poll until `ctr version` and the overlayfs snapshotter respond
→ `docker`. systemd reports containerd active before its snapshotter is usable.

## Directory Structure After Download

```
/opt/docker-offline/
├── rhel8/                    # Docker 29.7.2 for RHEL 8
├── rhel9/                    # Docker 29.7.2 for RHEL 9
├── rollback-rhel8/           # Docker 29.1.5 for RHEL 8
├── rollback-rhel9/           # Docker 29.1.5 for RHEL 9
├── nvidia/                   # NVIDIA Container Toolkit
├── upgrade-docker.sh
├── rollback-docker.sh
├── clean-swarm-networks.sh
└── recover-dnf.sh
```

## Sources

- [Docker Engine RHEL Install Docs](https://docs.docker.com/engine/install/rhel/)
- [Docker Engine v29 Release Notes](https://docs.docker.com/engine/release-notes/29/)
- [containerd Releases](https://containerd.io/releases/)
- [NVIDIA Container Toolkit Install Guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)

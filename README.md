# Docker Engine 29.1.5 → 29.6.2 Upgrade for Air-Gapped RHEL 8/9

Scripts for upgrading Docker Engine from 29.1.5 to 29.6.2 on air-gapped RHEL 8 and
RHEL 9 servers.

## Why This Upgrade

This is a **point-release upgrade inside the containerd 2.2.x line**, not a major
migration. It picks up the cumulative fixes from Docker 29.2 through 29.6, including
security updates and several overlay-networking fixes that matter for Swarm:

- 29.0.0 — NetworkDB fix for overlay entries stuck in a deleted state
- 29.5.0 — fix for stale VIP DNS records during rolling updates
- 29.3.0 — minimum API version lowered from v1.44 back to v1.40
- 29.2.0 onward — containerd 2.2.0+ is a hard requirement

It is much lower risk than the 28.5.1 → 29.1.5 upgrade that preceded it, which
crossed the containerd 1.7 → 2.x boundary.

## Versions

| Package | From | To |
|---|---|---|
| docker-ce | 29.1.5 | **29.6.2** |
| docker-ce-cli | 29.1.5 | **29.6.2** |
| containerd.io | 2.2.1 | **2.2.6** |
| docker-buildx-plugin | 0.30.1 | **0.35.0** |
| docker-compose-plugin | 5.0.1 | **5.3.1** |

Rollback target is **29.1.5 / containerd.io 2.2.1**.

`docker-buildx-plugin` and `docker-compose-plugin` version independently of
docker-ce. Do not pin them to the docker-ce version.

### Package Name Clarification

```
WRONG: containerd (standalone package)
RIGHT: containerd.io (Docker's bundled containerd)
```

## What Changed From the Previous Upgrade Round

Three things the 1.7 → 2.x migration required have been removed, because inside
2.2.x they are inert or harmful. All three remain in git history at
`upgrade-docker.sh` v1.2.3 (commit `974683a`) for a future containerd major bump.

| Removed | Why |
|---|---|
| containerd config regeneration (phase 6) | 2.2.1 and 2.2.6 share config v3. Regenerating would discard a relocated `root` path, registry mirrors, and runtime config — silently repointing a node at an empty `/var/lib/containerd`. Phase 6 now **verifies** the config instead of rewriting it. |
| XFS `ftype=1` check and relocation prompt | Any node already running containerd 2.x has satisfied this requirement. The check cannot fire usefully. |
| Automatic orphaned-network cleanup (phase 4.5) | The daemon now stops cleanly, so there is nothing orphaned. Extracted to `clean-swarm-networks.sh`, to be run on demand. |

## Scripts

| Script | Version | Purpose | Run On |
|---|---|---|---|
| `download-docker-packages.sh` | 2.1.0 | Download all packages, build the bundle | Online RHEL server |
| `upgrade-docker.sh` | 2.0.0 | Perform the upgrade | Air-gapped servers |
| `rollback-docker.sh` | 2.0.0 | Roll back to 29.1.5 | Failed upgrade recovery |
| `clean-swarm-networks.sh` | 1.0.0 | Reset orphaned overlay network state | Node that can't rejoin overlays |
| `recover-dnf.sh` | 1.2.2 | Fix dependency issues | Servers with broken dnf |
| `simulate-upgrade.sh` | — | Test the upgrade path in a VM | RHEL test VM |

Script versions drift on purpose — only scripts that actually changed get bumped.

## Usage

### Step 1: Get the bundle

**Preferred — download a published release** (no online RHEL server needed):

```bash
gh release download v29.6.2-1
sha256sum -c <<< '<sha from the release notes>  docker-upgrade-bundle-v29.6.2-1.tar.gz'
```

Each release enumerates every package and version it contains, and ships one artifact
holding all RPMs, the operator scripts and the runbook. See `docs/RELEASING.md`.

**Or build it yourself on an online RHEL server:**

```bash
chmod +x download-docker-packages.sh
./download-docker-packages.sh
```

Produces `/opt/docker-upgrade-bundle.tar.gz` (~340 MB plus NVIDIA packages),
containing the 29.6.2 packages for RHEL 8 and 9, the 29.1.5 rollback set, the NVIDIA
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

29.1.5 and 29.6.2 both speak containerd 2.2.x gRPC, so a mixed 29.1.5 / 29.6.2 Swarm
is supported and will not produce the ALPN handshake errors a mixed 1.7 / 2.2 cluster
did. Upgrade a node, verify it, then move to the next.

That rule still applies across the containerd 1.7 ↔ 2.x boundary. Do not mix those.

## Verification

After upgrade:

```bash
# Versions
docker version          # Should show 29.6.2
containerd --version    # Should show 2.2.6

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
0.35.0 / 5.3.1; or an `rpm --test` dry run that the transaction fails. An unexpected
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
├── rhel8/                    # Docker 29.6.2 for RHEL 8
├── rhel9/                    # Docker 29.6.2 for RHEL 9
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

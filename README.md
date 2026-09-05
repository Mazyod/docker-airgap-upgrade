# Docker Engine 29.1.5 → 29.8.0 for Air-Gapped RHEL 8/9

Six standalone Bash scripts that upgrade Docker Engine and containerd on RHEL 8 and RHEL 9
servers with no internet access. Packages are downloaded once on a connected machine into a
single tarball, hand-carried to the disconnected nodes, and installed with `rpm` against a
validated file list. The scripts are Swarm-aware, and a rollback set for the previous
version travels in the same bundle.

Written for operators running a planned upgrade on a live Swarm. If you are changing the
scripts rather than running them, read [CLAUDE.md](CLAUDE.md) instead.

## What's in the bundle

| Package | From | To |
|---|---|---|
| docker-ce, docker-ce-cli | 29.1.5 | **29.8.0** |
| containerd.io | 2.2.1 | **2.3.4-2** |
| runc, inside containerd.io | 1.4.3 | **1.5.1** |
| docker-buildx-plugin | 0.30.1 | **0.37.0** |
| docker-compose-plugin | 5.0.1 | **5.5.1** |
| rollback set | | **29.1.5 / 2.2.1** |

containerd.io 2.3.4 was published upstream twice and only the `-2` build carries runc
1.5.1, so the RPM release suffix is asserted alongside the version and a bundle built
from `-1` is refused. See [docs/BACKGROUND.md](docs/BACKGROUND.md#the-runc-swap).

The bundle also carries the NVIDIA Container Toolkit, applied best-effort. The package is
`containerd.io`, never the standalone `containerd`, and the two plugins version
independently of docker-ce.

## Quick start

Download a published release, which needs no online RHEL server:

```bash
gh release download v29.8.0-1
sha256sum -c <<< '<sha from the release notes>  docker-upgrade-bundle-v29.8.0-1.tar.gz'
```

Or build the bundle yourself on an online RHEL server, from a full checkout:

```bash
chmod +x download-docker-packages.sh && ./download-docker-packages.sh
```

That writes `/opt/docker-upgrade-bundle.tar.gz`, roughly 340 MB, plus a `MANIFEST.txt`
naming every RPM by the `VERSION-RELEASE` in its header rather than its filename. It aborts
if any download 404s or any Docker RPM fails digest verification.

Transfer the tarball to each node, then run the upgrade:

```bash
rm -rf /opt/docker-offline
tar xzf docker-upgrade-bundle.tar.gz -C /opt/
cd /opt/docker-offline
./upgrade-docker.sh
```

Extract into an empty directory. Leftovers from a previous bundle read as duplicate
packages and the run is refused.

[RUNBOOK.md](RUNBOOK.md) is the per-node procedure for a human operator: pre-checks, drain,
the phase table, verification and soak. It travels inside the bundle.
[docs/AGENT-RUNBOOK.md](docs/AGENT-RUNBOOK.md) covers unattended and agent-driven runs, and
defers to the runbook for node ordering and soak timings. It lives only in this repo, so take
a copy before going air-gapped.

The runbook rolls nodes one at a time, and both engines speak the same Swarm protocol.
The claim is gated on Tier 3 cases 3.3 and 3.4, which have **not been run**; until they are,
`docs/TEST-PLAN.md` says to treat the rollout as whole-cluster.

## Scripts

| Script | Version | Purpose | Run on |
|---|---|---|---|
| `download-docker-packages.sh` | 2.3.0 | Download every package and build the bundle | Online RHEL server |
| `upgrade-docker.sh` | 2.5.0 | Perform the upgrade | Air-gapped node |
| `rollback-docker.sh` | 2.3.0 | Return the node to 29.1.5 / 2.2.1 | Failed upgrade |
| `clean-swarm-networks.sh` | 1.3.0 | Reset orphaned overlay network state | Node that cannot rejoin overlays |
| `recover-dnf.sh` | 1.3.0 | Print dnf dependency recovery steps | Node with broken dnf |
| `simulate-upgrade.sh` | — | Smoke-test the dnf install path | RHEL test VM |

Script versions drift on purpose; only the scripts that changed get bumped.

The three stateful scripts take `--status-file=PATH`, `--non-interactive`, `--help` and
`--version`, and refuse to run as a non-root user. `--non-interactive` grants nothing on
its own: an unanswered question becomes a refusal naming the missing flag, and it requires
`--status-file`, because without the record an exit 1 cannot be told from a failure.

`--preflight`, on the upgrade and the rollback, runs every check that can be made with the
node untouched and then exits. It exits 0 when the real run would proceed and 1 when it
would refuse; the upgrade adds a 3 for a node already at the target, and the rollback has
no third outcome.

The gate flags answer one question each, and each states a fact the caller is accountable
for rather than a preference: `--drain-self` and `--assume-drained` on the upgrade,
`--confirm-stop` and `--confirm-delete` on the cleanup, and others, every one with a `--no-`
form. `rollback-docker.sh` has no gate flags; it takes `--config-backup=newest|none|DIR`,
naming the containerd config backup phase 3 restores. Phase 0c still judges whatever config
phase 3 would load, so naming a different backup can only help by being one that genuinely
loads.

`clean-swarm-networks.sh` is the one script that cannot be driven unattended in a single
invocation, because its inventory can only be enumerated once services are stopped and so
cannot be declared in advance. A `--dry-run` stops, enumerates, prints the inventory hash,
restarts and exits 0; the real second pass then passes that hash back as
`--expect-inventory-sha=SHA` alongside `--confirm-delete`. The dry run cannot be combined
with either. Run by hand, it is one interactive invocation.

`docs/AGENT-RUNBOOK.md` has the full flag table and the decision table.

## If something goes wrong

Read the failure block the script prints, or the `--status-file` record if one was written.
It names the phase that failed, whether services are stopped, and whether the rpm
transaction ran. Those three package states call for different responses, and
[RUNBOOK.md](RUNBOOK.md#if-something-goes-wrong) has the table. Do not guess.

```bash
/opt/docker-offline/rollback-docker.sh --preflight   # would a rollback strand this node?
/opt/docker-offline/rollback-docker.sh               # back to 29.1.5 / 2.2.1
```

Run `clean-swarm-networks.sh`, after draining from a manager, when a node returns unable to
attach to overlay networks: `failed adding service binding` in the dockerd log, or services
never scheduling onto it. It prints what it will delete and asks first. `recover-dnf.sh`
covers dnf dependency problems, but its printed commands reference an
`--enablerepo=docker-local` repo that has to be created first on a production host.

## Safety properties

- Every payload and transaction check runs in phase 0, while the node is still serving and
  still in the Swarm: digests, RPM metadata, all five versions, arch, `el<major>` release,
  duplicates, and an `rpm -Uvh --test` dry run of the exact transaction. `--preflight` also
  lifts the relocated-root check out of phase 6, which otherwise runs with both services
  already stopped.
- Assertions read RPM metadata, never filenames. The previous bundle has an identical layout,
  so a filename check would let 29.1.5 "upgrade" to 29.1.5 and report success. The
  containerd.io RPM release is asserted too, since 2.3.4-1 and 2.3.4-2 differ only in runc.
- All five packages install in one rpm transaction, because splitting them can leave a
  downgraded runtime under a newer engine.
- Services stop in order and each stop is verified conclusively before packages or network
  state are touched. Starting reverses the order and polls containerd's API and its overlayfs
  snapshotter, because systemd reports containerd active before that snapshotter is usable.
- The containerd config is verified, never rewritten. Regenerating it would discard a relocated
  `root`, registry mirrors and runtime config, and write a version 4 file that blocks rollback.
  `rollback-docker.sh` phase 0c refuses a rollback, before anything stops, when the config
  containerd would load after the downgrade is a version 2.2.1 cannot read.
- Failure is reported, not guessed at. The upgrade and rollback exit traps name the phase, the
  service state and a tri-state package state, and deliberately do not auto-restart services,
  because after an rpm transaction retry-versus-rollback is an operator judgement. The cleanup
  script is the exception: it stopped the services itself, so its trap restores them.

## Testing

```bash
./tests/static-checks.sh              # Tier 1; --online adds the 16 RPM URL checks
```

Tier 2 runs the real scripts against a Rocky Linux 9 guest with real systemd, rpm and
Docker, containerd's root relocated to a separate XFS filesystem holding real images,
containers and volume data. It needs macOS with OrbStack or Linux with a local, rootful,
x86_64 Docker daemon. Every figure below came from one campaign on a guest recreated from
scratch, against a bundle rebuilt from the checkout under test.

| Suite | Result | Command |
|---|---|---|
| Static | 231/231 offline, 247/247 online | `tests/static-checks.sh` |
| Host and guest preflight | 8/8 | `tests/vm/preflight-host.sh` |
| VM, interactive path | 67/67 | `tests/vm/tier2-run.sh` |
| VM, agent mode | 697 passed, 0 failed, 2 skipped | `tests/vm/tier2-run.sh agent` |
| containerd config-version boundary | 30/30 | `tests/vm/config-version-check.sh` |
| Negative control | 3/3 | `tests/vm/negative-control.sh` |
| Agent negative control | 24 passed, 8 mutants | `tests/vm/agent-mode-negative-control.sh` |

The agent phase is a separate invocation with its own figure; the two VM numbers are not
additive and neither is a superset of the other.

Untested anywhere in this repo: multi-node Swarm, **worker** behaviour of any kind, overlay
reconvergence, mixed-version clusters, real RHEL and its subscription-manager and satellite
behaviour, GPU nodes, bare metal, and the cleanup script's VXLAN deletion loop. That is Tier
3, it has not been run, and it is what authorizes a production rollout and the node-by-node
claim. See [docs/TEST-PLAN.md](docs/TEST-PLAN.md) and [tests/vm/README.md](tests/vm/README.md).

## Releasing

Every shipment ships as a GitHub release: one tag, one artifact, one enumeration of the
packages read from RPM metadata rather than filenames. An air-gapped operator cannot
rebuild the bundle, so the artifact is the record of what was installed.

```bash
tools/make-release.sh v29.8.0-1        # --draft to review first
```

It refuses a dirty tree, unpushed commits, an existing tag or failing static checks, and
always rebuilds the bundle from the current checkout. See
[docs/RELEASING.md](docs/RELEASING.md).

## Layout after extraction

```
/opt/docker-offline/
├── MANIFEST.txt                        # every RPM by NAME and VERSION-RELEASE, from headers
├── rhel8/  rhel9/                      # Docker 29.8.0
├── rollback-rhel8/  rollback-rhel9/    # Docker 29.1.5
├── nvidia/                             # NVIDIA Container Toolkit
├── upgrade-docker.sh  rollback-docker.sh
├── clean-swarm-networks.sh  recover-dnf.sh
└── README.md  RUNBOOK.md
```

## Further reading

- [docs/BACKGROUND.md](docs/BACKGROUND.md) — why 29.8.0, the runc swap, the containerd
  config-version asymmetry, package freshness, and what changed since the previous round
- [Docker Engine RHEL install docs](https://docs.docker.com/engine/install/rhel/)
- [Docker Engine v29 release notes](https://docs.docker.com/engine/release-notes/29/)
- [containerd releases](https://containerd.io/releases/)
- [NVIDIA Container Toolkit install guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)

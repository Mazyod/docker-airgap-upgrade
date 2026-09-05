# Docker Engine 29.1.5 → 29.8.0 for Air-Gapped RHEL 8/9

Bash scripts that upgrade Docker Engine and containerd on RHEL 8/9 servers with no
internet access. Packages are downloaded once on a connected machine into one tarball,
hand-carried to the disconnected nodes, and installed with `rpm` against a validated file
list. Swarm-aware. A rollback set for the previous version travels in the same bundle.

For operators running a planned upgrade. To change the scripts, read [CLAUDE.md](CLAUDE.md).

## What's in the bundle

| Package | From | To |
|---|---|---|
| docker-ce, docker-ce-cli | 29.1.5 | **29.8.0** |
| containerd.io | 2.2.1 | **2.3.4-2** |
| runc (inside containerd.io) | 1.4.3 | **1.5.1** |
| docker-buildx-plugin | 0.30.1 | **0.37.0** |
| docker-compose-plugin | 5.0.1 | **5.5.1** |
| rollback set | | 29.1.5 / 2.2.1 |
| NVIDIA Container Toolkit | | current at build time, best-effort |

containerd.io 2.3.4 was published twice upstream and only the `-2` build carries runc 1.5.1,
so the scripts assert the RPM release as well as the version.
Details in [docs/BACKGROUND.md](docs/BACKGROUND.md).

## Quick start

Get the bundle from a release:

```bash
gh release download v29.8.0-1
sha256sum -c <<< '<sha from the release notes>  docker-upgrade-bundle-v29.8.0-1.tar.gz'
```

Or build it on an online RHEL server:

```bash
./download-docker-packages.sh        # writes /opt/docker-upgrade-bundle.tar.gz (~340 MB)
```

On each node, as root:

```bash
rm -rf /opt/docker-offline
tar xzf docker-upgrade-bundle.tar.gz -C /opt/
cd /opt/docker-offline
./upgrade-docker.sh
```

Extract into an empty directory. Leftovers from a previous bundle are refused as duplicates.

- [RUNBOOK.md](RUNBOOK.md): the per-node procedure for a human operator. Ships in the bundle.
- [docs/AGENT-RUNBOOK.md](docs/AGENT-RUNBOOK.md): unattended and agent-driven runs. Ships in the bundle.

## Scripts

| Script | Version | Purpose |
|---|---|---|
| `download-docker-packages.sh` | 2.3.1 | Build the bundle on an online RHEL server |
| `upgrade-docker.sh` | 2.5.0 | Upgrade a node |
| `rollback-docker.sh` | 2.3.0 | Return a node to 29.1.5 / 2.2.1 |
| `clean-swarm-networks.sh` | 1.3.0 | Reset orphaned overlay network state |
| `recover-dnf.sh` | 1.3.0 | Print dnf dependency recovery steps |
| `simulate-upgrade.sh` | | Smoke-test the dnf install path on a test VM |

Run with no flags, the scripts are interactive. For unattended runs:

- `--preflight` runs every check possible without touching the node, then exits.
- `--non-interactive --status-file=PATH` writes a machine-readable record and refuses any
  question that has not been answered by a flag. Each gate flag (`--drain-self`,
  `--assume-drained`, `--confirm-delete`, and so on) states one fact the caller is
  accountable for. `rollback-docker.sh` takes `--config-backup=newest|none|DIR` instead.
- `clean-swarm-networks.sh --dry-run` prints the inventory and its hash; the real run
  takes `--expect-inventory-sha=SHA --confirm-delete`.

The full flag and decision tables are in [docs/AGENT-RUNBOOK.md](docs/AGENT-RUNBOOK.md).

## If something goes wrong

The script prints a failure block, and writes the same to `--status-file` if given. It
names the failed phase, whether services are stopped, and whether the rpm transaction ran.
Those states call for different responses; see
[RUNBOOK.md](RUNBOOK.md#if-something-goes-wrong).

```bash
./rollback-docker.sh --preflight     # would a rollback strand this node?
./rollback-docker.sh                 # back to 29.1.5 / 2.2.1
```

Run `clean-swarm-networks.sh` only when a node returns unable to attach to overlay networks
(`failed adding service binding`), after draining it from a manager. `recover-dnf.sh`
prints its commands against an `--enablerepo=docker-local` repo that must exist first.

## Safety properties

- All payload validation, including an `rpm -Uvh --test` dry run, happens before the node
  is touched or drained.
- Assertions read RPM metadata, never filenames, including the containerd.io release.
- All five packages install in one rpm transaction.
- Services stop in order and each stop is verified before anything else happens; start
  waits for containerd's snapshotter, not just systemd.
- The containerd config is verified, never rewritten, so a relocated root and registry
  mirrors survive and rollback stays possible.
- Rollback refuses up front if the config it would load cannot be read by containerd 2.2.1.
- Failures are reported with phase, service state and package state. Nothing is
  auto-restarted after an rpm transaction.

## Testing

```bash
tests/static-checks.sh               # Tier 1, add --online for the RPM URL checks
```

Tier 2 runs the real scripts on a Rocky Linux 9 guest with systemd, rpm and Docker, and
containerd's root on a separate XFS filesystem holding real images and volumes. It needs
macOS with OrbStack or Linux with a local rootful x86_64 Docker daemon.

| Suite | Result |
|---|---|
| `tests/static-checks.sh` | 231/231 offline, 247/247 online |
| `tests/vm/tier2-run.sh` | 67/67 |
| `tests/vm/tier2-run.sh agent` | 697 passed, 2 skipped |
| `tests/vm/config-version-check.sh` | 30/30 |
| `tests/vm/negative-control.sh` | 3/3 |
| `tests/vm/agent-mode-negative-control.sh` | 24/24, 8 mutants |

Not tested: multi-node Swarm, worker nodes, mixed-version clusters, real RHEL with
satellite, GPU nodes, bare metal. That is Tier 3, and it gates a production rollout.
See [docs/TEST-PLAN.md](docs/TEST-PLAN.md) and [tests/vm/README.md](tests/vm/README.md).

## Releasing

Every shipment is a GitHub release: one tag, one artifact, packages enumerated from RPM
metadata. See [docs/RELEASING.md](docs/RELEASING.md).

```bash
tools/make-release.sh v29.8.0-1      # --draft to review first
```

## Bundle layout

```
/opt/docker-offline/
├── MANIFEST.txt                        # every RPM by NAME and VERSION-RELEASE
├── rhel8/  rhel9/                      # Docker 29.8.0
├── rollback-rhel8/  rollback-rhel9/    # Docker 29.1.5
├── nvidia/                             # NVIDIA Container Toolkit
├── upgrade-docker.sh  rollback-docker.sh
├── clean-swarm-networks.sh  recover-dnf.sh
└── README.md  RUNBOOK.md  AGENT-RUNBOOK.md
```

## Further reading

- [docs/BACKGROUND.md](docs/BACKGROUND.md): why 29.8.0, the runc swap, the containerd
  config-version asymmetry, package freshness, what changed since the previous round
- [Docker Engine RHEL install docs](https://docs.docker.com/engine/install/rhel/)
- [Docker Engine v29 release notes](https://docs.docker.com/engine/release-notes/29/)
- [containerd releases](https://containerd.io/releases/)
- [NVIDIA Container Toolkit install guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)

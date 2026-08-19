# VM test harness

Runs the **real** upgrade scripts against a **real** RHEL-like node with **real**
systemd, rpm and Docker — on a MacBook, in a few minutes, repeatably.

Before this existed, nothing in this repo had ever been executed. Static checks
(`tests/static-checks.sh`) only read the source text; they cannot catch a phase
that stops the wrong service or a config that gets silently regenerated.

## Requirements

[OrbStack](https://orbstack.dev) (`brew install orbstack`). It provides Linux
machines with systemd as PID 1 and x86_64 emulation via Rosetta, which is what
makes this possible on Apple Silicon.

## Quick start

```bash
tests/vm/bootstrap-vm.sh      # build the S1 baseline (~5 min, downloads packages)
tests/vm/build-bundle.sh      # run the real download script inside the VM (~333 MB)
tests/vm/tier2-run.sh         # execute the Tier 2 cases
tests/vm/config-version-check.sh  # containerd config v3/v4 boundary + rollback guard
tests/vm/negative-control.sh  # prove test 2.4 would catch the regression
tests/vm/teardown-vm.sh       # delete the machine
```

Between destructive runs:

```bash
tests/vm/reset-baseline.sh    # back to S1 in seconds
tests/vm/bootstrap-vm.sh --recreate   # nuke and rebuild, if state has drifted
```

## What each script does

| Script | Purpose |
|---|---|
| `lib.sh` | Shared helpers, version constants, assertions. Sourced, not run. |
| `bootstrap-vm.sh` | Creates the machine and builds the **S1 baseline** (see below). |
| `build-bundle.sh` | Runs the real `download-docker-packages.sh` in the VM and records the artifact SHA-256. |
| `tier2-run.sh` | The Tier 2 cases: `reject`, `upgrade`, `rollback`, or all. |
| `config-version-check.sh` | The containerd 2.2 → 2.3 config-version boundary, and `rollback-docker.sh` phase 0c. Destructive; reset afterwards. |
| `negative-control.sh` | Builds a one-line mutant with the old phase 6 and proves it destroys the config. |
| `reset-baseline.sh` | Reconstructs S1 without recreating the machine. |
| `vm-write-manifest.sh` | Runs **inside** the VM; records the pre-upgrade truth. |
| `teardown-vm.sh` | Deletes the machine. |

## The S1 baseline

The harness is only meaningful because of what `bootstrap-vm.sh` builds:

- Rocky Linux 9 (RHEL rebuild — `rpm -E %rhel` returns 9), **x86_64**, systemd PID 1
- docker-ce 29.1.5 / containerd.io 2.2.1 / buildx 0.30.1 / compose 5.0.1 — exactly
  what production runs today
- **containerd root relocated to `/data/containerd`** on a *separate* XFS filesystem
  with `ftype=1`, backed by a loopback device
- a representative `/etc/docker/daemon.json` with a registry mirror
- a pulled image, a named container, and a volume holding a canary file
- a manifest recording all of the above

The relocated root is the whole point. It is the configuration the previous script
version silently destroyed, and it cannot be tested any way other than building it
and running the real upgrade over it.

## What this proves — and what it does not

**Proves:** the scripts execute; phase ordering works; systemd service lifecycle and
containerd readiness gating work; real rpm transactions apply and downgrade; phase 0
rejects bad payloads with the node genuinely untouched; the relocated containerd root
and `daemon.json` survive byte-identically; images, containers and volume data
survive; rollback returns the node to 29.1.5 with data intact.

`config-version-check.sh` additionally proves, by measurement rather than by reading
release notes: that containerd 2.3.3 loads a `version = 3` config and leaves the file
byte-identical; that the relocated root survives the in-memory migration; that
`containerd config default` under 2.3.3 emits v4 while `containerd config migrate`
writes only to stdout; that containerd 2.2.1 genuinely refuses a v4 config; and that
`rollback-docker.sh` phase 0c catches that case with the node still running. Its
section E is a negative control — if containerd 2.2.1 ever started on a v4 config,
phase 0c would be guarding nothing and should be reconsidered, not kept.

**Does NOT prove:**

- **Swarm anything.** Single node. Drain, reactivation, overlay reconvergence,
  mixed-version clusters and `clean-swarm-networks.sh` are all untested here — that
  is Tier 3 and needs a real multi-node cluster.
- **Real RHEL.** Rocky is a rebuild, not RHEL. Subscription-manager, satellite
  behaviour, and any RHEL-specific packaging differences are out of scope — and the
  satellite SSL problem is the entire reason these scripts use `rpm` over `dnf`.
- **Production SELinux/cgroup/storage.** The VM's policy and storage layout are not
  your nodes'.
- **NVIDIA.** No GPU.
- **Bare metal.** OrbStack machines are lightweight VMs, not your hardware.

Tier 3 in `docs/TEST-PLAN.md` remains mandatory before a production rollout,
particularly the mixed-version tests that authorize node-by-node rolling.

## Adapting this for the next upgrade

1. Update the version constants at the top of `lib.sh`.
2. Update the target versions in `tier2-run.sh`'s assertions if package names change.
3. Re-run `bootstrap-vm.sh --recreate`.

If a future upgrade crosses a containerd **major** boundary again, the removed
machinery (config migration, XFS ftype check, orphaned-network cleanup) is in git
history at `upgrade-docker.sh` v1.2.3, commit `974683a` — and the negative control
here shows exactly why phase 6 must not regenerate the config.

# VM test harness

Runs the **real** upgrade scripts against a **real** RHEL-like node with **real**
systemd, rpm and Docker — on a laptop or a workstation, in a few minutes, repeatably.

Before this existed, nothing in this repo had ever been executed. Static checks
(`tests/static-checks.sh`) only read the source text; they cannot catch a phase
that stops the wrong service or a config that gets silently regenerated.

## Requirements

Either host works:

| Backend | Host | Guest |
|---|---|---|
| `orb` | **macOS + [OrbStack](https://orbstack.dev)** (`brew install orbstack`) | an OrbStack Linux machine, x86_64 via Rosetta on Apple Silicon |
| `docker` | **Linux + a local, rootful, x86_64 Docker daemon** (no sudo, no KVM) | a privileged Rocky 9 systemd container, built from `Dockerfile.rocky9-systemd` |

`lib.sh` picks one automatically: OrbStack when `orbctl` is installed, otherwise a
Docker daemon it can reach. Override with `HARNESS_BACKEND=orb` or
`HARNESS_BACKEND=docker`. If neither is available it says so and names both.

`need_backend` checks three properties of the Docker daemon rather than assuming them,
because each one silently breaks the baseline rather than failing loudly:

- **Local.** The repo reaches the guest as a bind mount of a host path. A remote
  daemon (`DOCKER_HOST` pointing anywhere but a unix socket) would resolve that path on
  the remote machine and mount the wrong tree, or nothing.
- **Rootful.** The baseline needs a real loop device, a real XFS mount and a nested
  dockerd. Rootless Docker provides none of them, even under `--privileged`.
- **x86_64.** The bundle is el9 x86_64 RPMs. On another architecture the rpm
  transaction — the thing under test — would fail for an unrelated reason. The image
  build and the container are pinned with `--platform linux/amd64`.

Everything above the backend is shared, because the backend contract is small. The
**core is six operations** — `need_backend`, `vm_exists`, `vm`, `vm_try`, `vm_create`,
`vm_delete` — implemented in `backend-orb.sh` and `backend-docker.sh`. Two further
operations, `vm_wake` and `vm_restart`, serve the harness's own lifecycle code and sit
outside that core. (Earlier revisions of this file and of `CLAUDE.md` claimed the port
surface was *four* helpers. It never was: create and delete were raw `orbctl` calls
sitting in `bootstrap-vm.sh` and `teardown-vm.sh`, outside any helper.)

Two helpers sit **above** the backend, in `lib.sh`, and are written once for both:

- `vm_wait_systemd_settled` — polls `systemctl is-system-running` for up to 120 s and
  accepts `running` or `degraded`, `degraded` being normal for a guest with pruned
  units. It replaced two copies that had already drifted in how they parsed the answer.
- `vm_cp_verified <dst_dir> <file>…` — copies files into the guest and compares each
  destination's SHA-256 against the host's copy. Both backends expose the repo at the
  identical absolute path, so every transfer is a plain `cp`; that path being the same
  tree is an *assumption* the digest turns into a fact. A forwarded or Desktop daemon
  can hold an older checkout there, and a partial copy exits 0. Every transfer site
  uses it: `bootstrap-vm.sh`, `build-bundle.sh`, `tools/make-release.sh` and
  `stage_manifest_writer`.

The container backend additionally re-checks one sentinel file on every wake. That is
deliberate duplication rather than dead weight: `tier2-run.sh`,
`config-version-check.sh`, `negative-control.sh` and `preflight-host.sh` transfer no
files at all, so it is the only repo-mount verification those runs get.

### What the container backend costs

`--privileged` is genuine host access, not a VM boundary, and two of its effects reach
the host:

- **Loop devices come from the host's global table.** The relocated root's 3 GB image
  is attached with a host loop device. `mount -o loop` and systemd's `Options=loop`
  both set autoclear, so it is released with the container's mount namespace —
  measured, not assumed. `teardown-vm.sh` **reports** any device still backed by the
  harness image and never detaches one: a loop attached inside another mount namespace
  looks idle from the host, so detaching on that evidence could pull a filesystem out
  from under an unrelated container. Two harness runs on one host contend for the same
  table. Check with `losetup -a` before and after.
- **Mounting XFS autoloads the host kernel's `xfs` module**, and it stays loaded.

Neither backend gives you a RHEL kernel, but they miss it differently:

- **`docker`** — the guest shares **this host's** kernel. On Ubuntu 26.04 that is
  6.x/7.x, and there is no kernel boundary at all between guest and host.
- **`orb`** — the guest runs OrbStack's **own Linux kernel** inside a lightweight VM.
  It is a real, separate kernel with a real VM boundary; it is simply not Rocky's or
  RHEL's, and not the one your nodes run.

Either way, kernel-version-dependent overlayfs, XFS and cgroup behaviour is not RHEL's.

## The restart hazard, and how it is guarded

A guest restart tears down the mount namespace. The 3 GB backing image does not go
away with it. Without something ordering the mount before containerd, systemd starts
containerd first and containerd comes up on an **empty shadow `/data/containerd`** in
the guest's own root filesystem — reporting itself `active` the whole time, with zero
snapshots, no images and the canary container dead.

That is the same "silently repointing a node at an empty root" hazard that
`upgrade-docker.sh` phase 6 exists to prevent, except manufactured by the harness
rather than by the product. A Tier 2 run in that state produces a screenful of
confident-looking failures that say nothing about the scripts, and `reset-baseline.sh`
would cheerfully rebuild the canary data **on the shadow root** and hand back a green
run built on a lie.

Three things stop it, and each has been mutation-tested by breaking it deliberately:

1. `lib.sh`'s `ensure_relocated_mount()` installs a systemd `data.mount` unit and a
   `containerd.service` drop-in carrying `RequiresMountsFor=/data/containerd`. It runs
   on **both** backends — an OrbStack machine that reboots loses a bare `mount -o loop`
   too, and a production node with a relocated containerd root would carry an fstab
   entry anyway, so this makes the baseline more faithful rather than less.
2. `lib.sh`'s `require_relocated_xfs()` refuses to proceed when the relocated root is
   not on XFS. `bootstrap-vm.sh`, `reset-baseline.sh`, `tier2-run.sh`,
   `config-version-check.sh` and `negative-control.sh` all call it, and in the two
   reconstructing scripts it runs *before* any service starts or canary data is written.
3. `preflight-host.sh` restarts the guest and asserts the mount, the ordering and the
   snapshots all come back. `bootstrap-vm.sh` runs it, so a baseline is never declared
   ready without it having passed.

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
| `lib.sh` | Backend selection, shared helpers, version constants, assertions. Sourced, not run. |
| `backend-orb.sh` | The OrbStack implementation of the backend contract. Sourced by `lib.sh`. |
| `backend-docker.sh` | The privileged-container implementation. Sourced by `lib.sh`. |
| `Dockerfile.rocky9-systemd` | The container backend's guest image: systemd PID 1, the `data.mount` unit, the containerd drop-in. |
| `bootstrap-vm.sh` | Creates the machine and builds the **S1 baseline** (see below). |
| `preflight-host.sh` | Restarts the guest and proves the relocated root survives it. Run by `bootstrap-vm.sh`. |
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
  with `ftype=1`, backed by a loopback device mounted through an ordered systemd
  mount unit
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
release notes: that containerd 2.3.4 loads a `version = 3` config and leaves the file
byte-identical; that the relocated root survives the in-memory migration; that
`containerd config default` under 2.3.4 emits v4 while `containerd config migrate`
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
- **Production SELinux/cgroup/storage.** The guest's policy and storage layout are not
  your nodes'. On the container backend SELinux is not enforcing at all.
- **NVIDIA.** No GPU.
- **Bare metal.** OrbStack machines are lightweight VMs and the container backend is
  not a machine at all — no reboot semantics, no kernel command line, no initramfs,
  no udev, no real block devices. Neither is your hardware.
- **A RHEL kernel.** The `docker` backend shares the host's kernel; the `orb` backend
  runs OrbStack's own. Neither is Rocky's or RHEL's, so kernel-version-dependent
  overlayfs, XFS and cgroup behaviour is not your nodes'.

Tier 3 in `docs/TEST-PLAN.md` remains mandatory before a production rollout,
particularly the mixed-version tests that authorize node-by-node rolling.

## Adapting this for the next upgrade

1. Update the version constants at the top of `lib.sh`.
2. Update the target versions in `tier2-run.sh`'s assertions if package names change.
3. Re-run `bootstrap-vm.sh --recreate`.

On the container backend, `--recreate` also deletes the named data volume holding the
loopback image and the built image, verifies all three are gone, and reports any host
loop device still backed by the image.

If a future upgrade crosses a containerd **major** boundary again, the removed
machinery (config migration, XFS ftype check, orphaned-network cleanup) is in git
history at `upgrade-docker.sh` v1.2.3, commit `974683a` — and the negative control
here shows exactly why phase 6 must not regenerate the config.

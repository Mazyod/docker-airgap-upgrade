# Test Plan — Docker 29.1.5 → 29.6.2 Retarget

**Date:** 2026-07-28
**Scope:** the six scripts retargeted in `a65edd7`, `7df0355`, `a095c40` and later

## What each tier can and cannot prove

- **Tier 1 — static.** macOS dev machine. Syntax, lint, internal consistency,
  upstream package availability, bundle integrity.
- **Tier 1b — stubbed orchestration.** A disposable Linux container with `rpm`,
  `systemctl`, `docker`, `ctr` stubbed on `PATH`. Runs the **real scripts** and
  exercises their failure branches deterministically. Does not prove real RPM or
  systemd behaviour.
- **Tier 2 — RHEL VM.** Real packages, real systemd. Minimum bar for rollout.
- **Tier 3 — production-like Swarm.** Drain/reactivate, overlay reconvergence,
  mixed-version operation, rollback in a live cluster.

Tier 1 executes no upgrade logic. Tier 1b executes the orchestration but not the
system calls underneath it. **Neither authorizes a rollout; Tier 2 on the matching
RHEL major is the minimum, and Tier 3 gates the node-by-node claim.**

---

## Tier 1 — Static

Mechanised in `tests/static-checks.sh`. Run `./tests/static-checks.sh --online`.

| # | Test | Pass criteria |
|---|---|---|
| 1.1 | Syntax — `bash -n` × 7 scripts | All parse |
| 1.2 | Lint — `shellcheck` × 7 | No findings; suppressions carry a reason |
| 1.3 | Upstream availability | All 16 RPM URLs return 200 |
| 1.4 | Version constants agree | Target and rollback versions consistent across all files; both el8 and el9 present in every download loop |
| 1.5 | No stale literals in live code | 28.5.1 / 1.7.29 absent everywhere; 0.30.1 / 5.0.1 only in the simulation baseline |
| 1.6 | Phase structure | Phases 0–10 present, 4.5 absent |
| 1.7 | Removed logic gone | No live `check_xfs_ftype`; `containerd config default` appears exactly once (file-absent branch); no live `containerd config migrate` |
| 1.8 | Executable bits | All executable |
| 1.9 | Bundle completeness | Every listed script exists |
| 1.10 | Failure wiring | EXIT/INT/TERM traps and `verify_unit_stopped` in all three stateful scripts; no `is-active` used as a stop check |

### 1.11 — Bundle integrity (must run on the online RHEL server)

HTTP 200 only proves the URL answered. Additionally:

1. Run `download-docker-packages.sh` for real.
2. `sha256sum /opt/docker-upgrade-bundle.tar.gz` — **record this. Every later tier
   must use this exact artifact.**
3. Extract to a scratch dir; confirm the expected tree and all four scripts.
4. `rpm -qp --queryformat` every RPM: name, version, release, arch as expected.
5. `rpm -K` **with Docker's GPG key imported** — the scripts' `--nosignature` digest
   check proves integrity, not authenticity. In a regulated environment, verify publisher signatures
   against a pinned key fingerprint at bundle-build time.

---

## Tier 1b — Stubbed orchestration (recommended)

Run the real scripts in a disposable Linux container with stub `rpm`, `systemctl`,
`docker`, `ctr`, `nvidia-ctk` on `PATH`, driven by a scenario variable. Empty
placeholder files serve as RPMs. This makes failure branches deterministic and
cheap, and none of it requires RHEL.

| # | Scenario | Expect |
|---|---|---|
| 1b.1 | Payload: missing / duplicate / corrupt / unexpected / wrong version / wrong release / wrong arch | Phase 0 rejects each with the specific reason |
| 1b.2 | `rpm --test` returns non-zero | Phase 0 aborts; drain and stop never called |
| 1b.3 | Any phase-0 failure | Stub log shows no `docker node update`, no `systemctl stop`, no real `rpm -U` |
| 1b.4 | Already-at-target (all five packages) | Offers skip; exits 0 on "no" |
| 1b.5 | Partial state permutations | Proceeds, reporting which packages lag |
| 1b.6 | Starting from containerd 1.x | **Hard abort** pointing at v1.2.3 |
| 1b.7 | Starting from an unlisted 29.x | Warns, requires confirmation |
| 1b.8 | Stop order | Stub log shows docker → docker.socket → containerd |
| 1b.9 | `docker.socket` stays active | Phase 4 refuses to continue |
| 1b.10 | Unit reports `deactivating` | `verify_unit_stopped` fails closed |
| 1b.11 | `ctr version` never responds, restart doesn't help | **Fails before docker starts** (regression test for the false-ready bug) |
| 1b.12 | Snapshotter unusable after restart | **Fails before docker starts** |
| 1b.13 | Exit-trap states: fail before stop / during rpm / after rpm / after services up | Correct `PKG_STATE` and correct advice each time |
| 1b.14 | `wait_for_services` fed `0/1`, then `1/1`; `docker service ls` failing; zero-replica services | Waits, converges, does not treat command failure as convergence |
| 1b.15 | Relocated root missing | **Hard abort**, no `mkdir` on `/` |
| 1b.16 | Cleanup: inventory vs deletions, abort path, zero items, enumeration failure, partial deletion → exit 2, recovery failure | Each behaves as specified |
| 1b.17 | Rollback: backup branches (match / differ / none / neither), multiple backups | Correct branch; all backups listed |
| 1b.18 | Downloader: 404, missing script, corrupt RPM, empty dir | Each aborts, no bundle produced |

---

## Tier 2 — RHEL VM

Run on **both** RHEL 8 and RHEL 9.

### Snapshots — do not run these sequentially on one evolving VM

| Snapshot | State |
|---|---|
| **S0** | Clean RHEL, networked, no artifacts |
| **S1** | 29.1.5 / 2.2.1 / buildx 0.30.1 / compose 5.0.1; pristine bundle (the recorded SHA-256); network severed; relocated containerd root on a **separate mounted filesystem**; representative `daemon.json`; images, containers and volumes present |
| **S2** | S1 after a successful canonical upgrade |

Fork each destructive test from the stated snapshot; never repair a damaged bundle
in place. Clear `/var/log/docker-*.log` before any canonical run.

| # | Test | From | Pass criteria |
|---|---|---|---|
| 2.1 | `simulate-upgrade.sh` | S0 | Exits 0; all asserts OK |
| 2.2 | Same on RHEL 9 | S0 | Exits 0 — the script auto-detects the RHEL major, so this runs the **checked-in artifact unmodified** |
| 2.3 | Real air-gapped path | S1 | Exits 0; phase 9 asserts all five packages; `docker version` shows 29.6.2 |
| **2.4** | **Relocated-root regression** ⚑ | S1 | See below — the most important test here |
| 2.5 | `daemon.json` preserved | S1 | Byte-identical after upgrade; daemon restarts; `docker info` shows the configured mirror actually loaded |
| 2.6 | Wrong bundle (29.1.5 RPMs) | S1 | Fails in phase 0; services still running; node untouched |
| 2.7 | Duplicate RPMs (new extracted over old) | S1 | Fails in phase 0 naming the duplicate |
| 2.8 | Corrupt RPM (`truncate -s -1M`) | S1 | Fails digest check in phase 0 |
| 2.9 | Wrong release — **replace** the el9 RPM with its el8 build (do not add it, or it trips the duplicate check first) | S1 | Fails in phase 0 citing the release |
| 2.10 | Empty package dir | S1 | Fails in phase 0 |
| 2.11 | Stale plugins — core RPMs correct, buildx/compose at 0.30.1/5.0.1 | S1 | Fails in phase 0 on the plugin versions |
| 2.12 | Missing plugins — core RPMs only | S1 | Fails in phase 0; installed plugins are not silently left stale |
| 2.13 | Transaction rejection — a complete, correct set that `rpm --test` refuses (e.g. an installed package requiring the newer containerd) | S1 | Fails at the dry run, distinct from the inventory gate |
| 2.14 | Idempotent re-run | S2 | Detects already-at-target, exits 0 on "no" |
| 2.15 | Partial state | S2 clone, containerd.io downgraded to 2.2.1 | Reports partial, proceeds, completes |
| 2.16 | Rollback | clean S2 | Exits 0; all three asserts show 29.1.5/2.2.1; **same container IDs, image accessible, volume data intact, app responds, config unchanged** |
| 2.17 | Rollback resumability | S2 clone with containerd.io already at 2.2.1 | `--replacepkgs` lets the rerun succeed rather than "already installed" |
| 2.18 | Rollback payload gate | S2 clone, `docker-ce-cli` removed from rollback dir | Fails in phase 0 before stopping services |
| 2.19 | Interrupted transaction | S1 clone, **discard afterwards** | Trap reports package state as UNKNOWN and does not claim packages are unchanged. Do the stubbed version (1b.13) first; killing a real rpm transaction risks the rpmdb |
| 2.20 | NVIDIA absent / corrupt / valid | S1 variants | Absent and corrupt both skip cleanly without aborting; valid installs |
| 2.21 | `.rpmnew` surfaced | S1 with a modified config.toml | Phase 6 reports the `.rpmnew` |
| 2.22 | Logs | any canonical run | Cleared beforehand; contains start marker, every expected phase, final marker; process exit status recorded |

### 2.4 — Relocated-root regression, in full

The earlier version of this test only checked that a string survived in a file. That
is not sufficient: the config text could survive while containerd started against an
empty root, losing every image and snapshot, and the run would still pass its version
and service checks.

**Setup (from S1):**

1. Stop docker and containerd.
2. Mount a separate filesystem at `/data`. Set `root = '/data/containerd'` in
   `/etc/containerd/config.toml`.
3. Start containerd and docker against that config.
4. **Now** pull an image, create a named container with a volume, run a workload.
5. Record: SHA-256 of the whole config; image ID; container ID; a successful workload
   response; `findmnt --target /data/containerd`; a file listing under
   `/data/containerd`.

**Run** the real `upgrade-docker.sh` offline.

**Assert all of:**

- config is **byte-identical** (compare the SHA-256, not a substring)
- containerd is genuinely using `/data/containerd`
- the same image ID and container ID are still present and usable
- the pre-existing workload starts and responds
- `ctr snapshots --snapshotter overlayfs ls` works
- `/var/lib/containerd` was **not** newly populated as an alternative root

**Negative control:** from the same S1 snapshot, run a temporary mutant of the
current script whose phase 6 restores the old `containerd config default >
/etc/containerd/config.toml` line. The assertions above **must fail**. A one-line
mutant is the right control — the full v1.2.3 script targets a different version pair
and would change more than the behaviour under test.

**Missing-mount variant:** from S1, leave `/data` unmounted so `/data/containerd`
does not exist. The upgrade must **hard-abort** rather than create an empty directory
on `/`.

---

## Tier 3 — Swarm

Use a **three-manager** topology so quorum is real. Check Raft health before and
after each manager upgrade.

| # | Test | Pass criteria |
|---|---|---|
| 3.1 | Worker drain guard (run first) | Refuses without attestation; prints manager-side command |
| 3.2 | Worker upgrade | Drains, upgrades, reactivates, tasks reschedule |
| 3.3 | **Mixed-version cluster** | One node on 29.6.2, rest on 29.1.5; service spanning both; no ALPN errors; overlay traffic works both directions |
| 3.4 | Mixed-version soak | Sustained representative traffic, not one request. Journals on every node clean of ALPN, overlay, snapshotter, OOM, daemon-restart errors |
| 3.5 | Overlay DNS / VIP / ingress | Service discovery, VIP routing, routing mesh, secrets and configs all functional across versions |
| 3.6 | Manager upgrade | Self-drains; quorum retained; Raft healthy after |
| 3.7 | `wait_for_services` | With a **deliberately non-converged** service (0/1 → 1/1). Must wait for real convergence, not return instantly. Also test `docker service ls` failing, and zero-replica services |
| 3.8 | Cleanup abort | Answer "n" at the final prompt: services restarted, nothing deleted, exit 0 |
| 3.9 | `clean-swarm-networks.sh` | On a dedicated/snapshotted drained node: preview matches deletions exactly; services return; node rejoins overlays; exit 0 |
| 3.10 | Cleanup incomplete | Force one deletion to fail: reports the failure and **exits 2** |
| 3.11 | Rollback in a mixed cluster | A rolled-back 29.1.5 node rejoins a cluster containing 29.6.2 nodes and schedules work |

## Environment fidelity

Tier 2 and 3 environments must match production in: SELinux mode (enforcing),
cgroup version, storage filesystem and mount layout, kernel family, `daemon.json`,
systemd overrides, and any security tooling. A pass on a permissive-SELinux VM does
not transfer.

If any production node has GPUs, 2.20 and a real GPU workload test are mandatory.

## Exit criteria

- **Tier 1:** all pass. Gates everything.
- **Tier 1b:** 1b.11, 1b.12, 1b.15 mandatory — each is a regression test for a
  defect found during review.
- **Tier 2:** all pass on **both** RHEL majors. **2.4 including its negative control
  is mandatory**; without it the primary hazard is unproven. 2.16 rollback must pass
  on both majors with config preservation.
- **Tier 3:** 3.1–3.6 mandatory. **3.7, 3.9, 3.10 and 3.11 are also mandatory**, not
  optional: `wait_for_services` was fixed in this change, `clean-swarm-networks.sh`
  is new and destructive, and rollback-in-cluster is the emergency safety case.
- 3.3 and 3.4 specifically authorize node-by-node rollout. Without them, treat the
  rollout as whole-cluster.

## Rollout gate

Use the exact bundle identified by the SHA-256 recorded in 1.11 for every tier and
for production. Define abort thresholds before starting. Roll the least critical node
first, observe under real traffic for an agreed period, then proceed.

## Known gap

`recover-dnf.sh` was unchanged in this work and has **no dynamic test**. It is
production recovery code that stops services, changes packages, uses a bare readiness
sleep, has no failure trap, and assumes a `docker-local` repo that does not exist on
air-gapped hosts. Treat it as unverified: do not run it on a production node without
first exercising it in a VM. Bringing it to the standard of the other scripts is
follow-up work, deliberately out of scope here.

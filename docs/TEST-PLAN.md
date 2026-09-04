# Test Plan — Docker 29.1.5 → 29.8.0 Retarget

**Date:** 2026-07-28
**Scope:** the six scripts retargeted in `a65edd7`, `7df0355`, `a095c40` and later

## Execution status (2026-09-04, retarget to 29.8.0 / containerd.io 2.3.4-2)

| Tier | Status | Evidence |
|---|---|---|
| Tier 1 static | **PASSED 231/231** offline, **247/247** with `--online` | `tests/static-checks.sh`; the 16 RPM URL checks are the one skip offline |
| Tier 2 VM | **PASSED 67/67** | `tests/vm/tier2-run.sh` (the `all` phases) — the interactive-path regression gate. This is an **assertion** count for the automated cases, not a count of the Tier 2 table below: 2.1, 2.2, 2.13, 2.15 and 2.17 through 2.22 are specified and not automated |
| Tier 2 agent mode | **PASSED 697, 0 failed, 2 skipped** | `tests/vm/tier2-run.sh agent` — cases 2.29 through 2.48. One skip is the worker predictor state, which needs a second node; the other is phase 4's VXLAN loop, which an attachable overlay does not exercise from the host namespace |
| Tier 2 config-version boundary | **PASSED 30/30** | `tests/vm/config-version-check.sh` — cases 2.23–2.28 |
| Tier 2 negative control | **PASSED 3/3** | `tests/vm/negative-control.sh` — mutant loses the relocated root |
| Tier 2 agent negative control | **PASSED 24, 0 failed, 8 mutants** | `tests/vm/agent-mode-negative-control.sh` — M1a, M1b, M2, M3, M4a, M4b, M5 and M6 each reproduce the hazard their paired case exists to catch |
| Tier 1b stubbed | not built | optional; Tier 2 covers most of its intent |
| Tier 3 Swarm | **NOT RUN** | needs a real multi-node cluster |

Every Tier 2 figure above was produced in one campaign against a bundle rebuilt from
the checkout under test, on a Rocky Linux 9 guest recreated from scratch through the
Docker backend, with the baseline reset between suites. `preflight-host.sh` passed
8/8 on that fresh guest before any case ran. The bundle was 334 MB, sha256
`a00715919c1dbd8059e75aaf8958a7daf8eca1d637066bb41530465c2a91a507`, carrying
`containerd.io-2.3.4-2.el8` and `containerd.io-2.3.4-2.el9`. The agent-mode figure covers the cleanup dry run and
the rollback preflight added in the last two slices; it was 486 before them.

The `agent` phase is **not part of `all`** — it runs only as `tests/vm/tier2-run.sh
agent`, resets the baseline before it starts, and therefore carries its own figure.
The two numbers are not additive and neither is a superset of the other.

Two mutations were executed by hand alongside the automated suites, and both are
recorded below: the 2.6b already-at-target mutation, and the trap mutation covering
the preflight report suppression.

The runc swap was verified directly rather than inferred. `/usr/bin/runc` as shipped
by each build, read from the RPM headers on the test node:

| Build | runc | size |
|---|---|---|
| containerd.io-2.3.4-**2** | 1.5.1 | 14,062,896 |
| containerd.io-2.3.4-**1** | 1.4.3 | 15,920,328 |

### The containerd RPM-release guard: 2.6a and 2.6b are both automated

The `EXPECTED_CONTAINERD_RELEASE` assertion has three call sites, and they fail in
different places, so one case does not cover them: phase 0 checks the payload, the already-at-target gate checks what is
installed *before* deciding there is nothing to do, and phase 9 checks what rpm
actually left behind. Both cases below are written to the "assert state, not the exit
code" rule — a bundle that is refused and a bundle that is accepted and then fails
both exit non-zero.

| # | Test | From | Pass criteria |
|---|---|---|---|
| 2.6a ✅ | **Payload gate.** Bundle carries `containerd.io-2.3.4-1` | S1, `rhel9/` containerd RPM swapped for the `-1` build | `upgrade-docker.sh` exits non-zero **in phase 0**, naming the containerd release and the runc difference; **and** `rpm -q containerd.io` still reports the S1 baseline `2.2.1-1.el9`; **and** `docker`, `docker.socket` and `containerd` are all still `active`; **and** the canary data under the relocated root is intact. **Automated in `tier2-run.sh`, 10 assertions, passing.** |
| 2.6b ✅ | **Already-at-target gate.** Node is on every target version but the wrong containerd build | S1 upgraded to the target, then `containerd.io` alone downgraded to the real upstream `-1` build with `rpm -Uvh --oldpackage` | The script must **not** report "already fully at the target" and exit 0. It takes the partial-upgrade branch, runs the transaction, and phase 9 reports `containerd.io release 2.el9`; **and** `rpm -q containerd.io` reports `2.3.4-2.el9` and `runc --version` is 1.5.1 afterwards; **and** docker and containerd are active with the canary data intact. **Automated in `tier2-run.sh`, 11 assertions, passing.** |

The `-1` build is a real upstream RPM, downloaded in the guest with `dnf download`,
so 2.6a uses a genuinely wrong bundle rather than a hand-edited one — a doctored file
would be caught by the digest check instead and the case would pass for the wrong
reason. `WRONG_CONTAINERD_RELEASE` in `tests/vm/lib.sh` names that build; 2.6a fails
loudly if it ever equals the target release, since then no wrong build exists and the
case would be vacuous.

2.6b is the regression that review caught: every `%{VERSION}` matches on such a node,
so a version-only gate exits 0 and leaves runc 1.4.3 in place with the operator told
there was nothing to do.

The automated 2.6b reaches that state by **downgrading `containerd.io` in place**
rather than by running a `-1` bundle with the guard disabled, as this table
originally proposed. Same starting state, and no mutant of the script under test is
ever run — which matters, because a case that requires disabling the guard to set
itself up cannot then be trusted to prove the guard works.

**Mutation executed against 2.6b**, at `093a927`; the captured output is further
down this document. The mutation is: delete the release test
from the already-at-target gate in
`upgrade-docker.sh` — the `containerd_release_matches "$CURRENT_CONTAINERD_REL"`
conjunct — and confirm 2.6b turns red. The node should then be declared already at
the target, take the `exit 0` path, and be left on `2.3.4-1.el9` with runc 1.4.3.
Assert on that state, not on the exit code: with stdin closed the mutant exits
non-zero anyway, because `prompt_yes_no` refuses EOF at the "re-run anyway?" prompt.

**What 2.6b does NOT cover.** Phase 9's own release check has no Tier 2 case and
cannot get one: every scenario the harness can build installs the right release from
a valid bundle, so its failure branch never executes. Deleting its `VERIFY_FAILED=1`
leaves Tier 2 green. `tests/static-checks.sh` 1.4b pins that assignment by text
instead, and that pin is mutation-tested.

**Mutation evidence for 2.6a.** Replacing the body of `check_containerd_release` with
`return 0` in the guest's copy of `upgrade-docker.sh` and staging the `-1` bundle
produced this:

```
docker-ce        29.8.0-1.el9
containerd.io    2.3.4-1.el9
runc             runc version 1.4.3
services: docker=active containerd=active
UPGRADE FAILED during: phase 9 (verification) (exit 1)
Packages:  NEW packages installed successfully
```

The node took the wrong runtime. Note what that means for the test design: the mutant
**also exits 1**, and its services are **also** active, because phase 9 caught the
build only after the transaction had already run. Re-evaluating 2.6a's assertions
against that node:

```
FAIL 2.6a: docker-ce is now 29.8.0 -- the node WAS modified
FAIL 2.6a: containerd.io still 2.2.1 (got '2.3.4', want '2.2.1')
FAIL 2.6a: containerd.io is still 2.2.1-1.el9 exactly (got '2.3.4-1.el9', want '2.2.1-1.el9')
PASS 2.6a: containerd still active
PASS 2.6a: docker.socket still active
```

Only the package assertions distinguish a refusal from an outage. The service
assertions pass in both, exactly as the "assert state, not the exit code" rule
predicts.

**That mutation also found a weak assertion in 2.6a itself.** The case originally
asserted `%{RELEASE}` alone was `1.el9`. That check passed under the mutant, because
the S1 baseline `containerd.io 2.2.1` and the wrong build `2.3.4-1` *both* have
release `1.el9`. It was a green line proving nothing. It now asserts
`%{VERSION}-%{RELEASE}` together, and fails under the mutant as it should.

Setting `EXPECTED_CONTAINERD_RELEASE=""` does **not** work as a mutation: the guard
still rejects, because a payload release of `1.el9` is still not `".el9"`. A mutation
that leaves the guard firing proves nothing about the test.

Mutation-test 2.6b by restoring the version-only gate — delete the
`containerd_release_matches "$CURRENT_CONTAINERD_REL" ...` line from the
already-at-target condition. The script must then exit 0 saying there is nothing to
do, and 2.6b must fail.

**Executed at `093a927`.** The mutant took the already-at-target branch and the case
went red on state, not merely on the exit code:

```
FAIL 2.6b the gate called a node on 2.3.4-1.el9 already-at-target
FAIL 2.6b the run did not complete
FAIL 2.6b: containerd.io is now 2.3.4-2.el9 (got '2.3.4-1.el9', want '2.3.4-2.el9')
FAIL 2.6b: runc is now 1.5.1, not 1.4.3 (got '1.4.3', want '1.5.1')
PASS 2.6b: docker active after the corrective run
PASS 2.6b: containerd active after the corrective run
```

The node was left on `containerd.io 2.3.4-1.el9` running runc 1.4.3, which is the
runtime nobody chose. The service assertions stayed green in both worlds, exactly as
the "assert state, not the exit code" rule predicts.

**That mutation also found a vacuous assertion in 2.6b itself.** `2.6b phase 9
reported the installed containerd.io release` was green under the mutant, on a run
that exited at the gate and never reached phase 9. Phase 0 prints a byte-identical
`containerd.io release 2.el9` line about the *payload*, and the check grepped the
whole transcript. It now scans only from the `=== Phase 9: Verification ===` banner
onward, and goes red under the same mutant.

Tier 1 covers what it can, and more than usual. `tests/static-checks.sh` section 1.4c
extracts both functions from `upgrade-docker.sh` with awk and **executes** them: the
predicate `containerd_release_matches` against 25 inputs, and the phase-0 wrapper
`check_containerd_release` against 7 payloads, asserting that `PKG_ERRORS` actually
moves. The inputs include the two shapes an earlier prefix comparison accepted
(`2.el9.el8`, `2.el9.foo`), the real wrong build on both majors (`1.el9`, `1.el8`),
and an el8 release on an el9 host.

That is a genuine behavioural test of the logic, and it is still not a substitute for
2.6a and 2.6b. It proves the functions decide correctly; it cannot prove the three
call sites are reached on a real node, that phase 0 aborts on the `PKG_ERRORS` those
functions set, or that a refused node is left with its services up and its data
intact. Only Tier 2 shows that.

Tier 2 ran against a **relocated containerd root on a separate XFS filesystem** with
real images, containers and volume data on it — the exact configuration the previous
script version destroyed. The negative control confirms a one-line mutant restoring
the old phase 6 loses that root (`/data/containerd` → `/var/lib/containerd`), so 2.4
is a genuine regression test rather than a vacuous pass. Since the retarget, that
mutant is doubly harmful: regenerating the config under containerd 2.3.4 both loses
the relocated root *and* writes a `version = 4` file that would block a later
rollback.

The config-version guard (`rollback-docker.sh` phase 0c) was **mutation-tested**, not
merely exercised — see 2.27/2.28 above for what the neutered build does to the node.

**Tier 3 remains mandatory before production.** A single-node Swarm manager draining and
reactivating itself IS now executed, in the agent-mode phase, along with the cleanup
script's gates. Nothing else about Swarm is — **worker behaviour of any kind**,
multi-node operation, overlay reconvergence, or mixed-version operation. The
destructive half of `clean-swarm-networks.sh` is now partly exercised — phase 4
really does delete the namespaces, the key-value store and `docker_gwbridge` on a
single-node Swarm — with the host-namespace VXLAN loop still unreached and reported
as a skip. The claim that a mixed
29.1.5 / 29.8.0 cluster is safe rests on both being Docker 29.x engines, **not** on a
measurement. See `tests/vm/README.md` for the full list of what the VM tier does and
does not prove.

## What each tier can and cannot prove

- **Tier 1 — static.** macOS dev machine. Syntax, lint, internal consistency,
  upstream package availability, bundle integrity.
- **Tier 1b — stubbed orchestration.** A disposable Linux container with `rpm`,
  `systemctl`, `docker`, `ctr` stubbed on `PATH`. Runs the **real scripts** and
  exercises their failure branches deterministically. Does not prove real RPM or
  systemd behaviour.
- **Tier 2 — RHEL-like node.** Real packages, real systemd, real rpm transactions.
  Minimum bar for rollout. **As executed it is Rocky Linux 9 through the Docker
  backend, not RHEL and not a machine** — see `tests/vm/README.md`. Rocky is a
  rebuild, so subscription-manager and satellite behaviour are out of scope, and
  the satellite SSL problem is the entire reason these scripts use `rpm` over
  `dnf`. The container backend has no reboot semantics, no kernel command line and
  no real block devices, and shares the host's kernel.
- **Tier 3 — production-like Swarm, on real hardware.** Drain/reactivate, worker
  behaviour of any kind, overlay reconvergence, mixed-version operation, rollback
  in a live cluster — and everything Tier 2 structurally cannot reach: real RHEL,
  GPU nodes, and bare metal.

Tier 1 executes no upgrade logic. Tier 1b executes the orchestration but not the
system calls underneath it. **Neither authorizes a rollout; Tier 2 on the matching
RHEL major is the minimum, and Tier 3 gates the node-by-node claim.**

**The Tier 3 boundary, stated once so the three documents agree.** Untested
everywhere: multi-node Swarm, **worker** behaviour of any kind, overlay
reconvergence, mixed-version clusters, real RHEL, GPU, bare metal, and the
cleanup script's VXLAN deletion loop. `README.md` and `tests/vm/README.md` state
the same list; if they ever diverge, this is the one to believe.

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

## Tier 2 — RHEL-like node (executed on Rocky 9)

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
| 2.3 | Real air-gapped path | S1 | Exits 0; phase 9 asserts all five packages **and the containerd.io RPM release**; `docker version` shows 29.8.0 |
| **2.4** | **Relocated-root regression** ⚑ | S1 | See below — the most important test here |
| 2.5 | `daemon.json` preserved | S1 | Byte-identical after upgrade; daemon restarts; `docker info` shows the configured mirror actually loaded |
| 2.6 | Wrong bundle (29.1.5 RPMs) | S1 | Fails in phase 0; services still running; node untouched |
| 2.7 | Duplicate RPMs (new extracted over old) | S1 | Fails in phase 0 naming the duplicate |
| 2.8 | Corrupt RPM (`truncate -s -1M`) | S1 | Fails digest check in phase 0 |
| 2.9 | Wrong release — **replace** the el9 RPM with its el8 build (do not add it, or it trips the duplicate check first) | S1 | Fails in phase 0 citing the release |
| 2.10 | Empty package dir | S1 | Fails in phase 0 |
| 2.11 | Stale plugins — core RPMs correct, buildx/compose at 0.30.1/5.0.1 | S1 | Fails in phase 0 on the plugin versions |
| 2.12 | Missing plugins — core RPMs only | S1 | Fails in phase 0; installed plugins are not silently left stale |
| 2.6a | Wrong containerd **build** — the real upstream `containerd.io-2.3.4-1`, whose `%{VERSION}` is identical to `-2` | S1 | Fails in phase 0 on the RPM **release**, naming the runc difference; node untouched, including `containerd.io` still `2.2.1-1.el9` exactly |
| 2.13 | Transaction rejection — a complete, correct set that `rpm --test` refuses (e.g. an installed package requiring the newer containerd) | S1 | Fails at the dry run, distinct from the inventory gate |
| 2.14 | Idempotent re-run | S2 | The harness asserts one thing: that the run prints the already-at-target message. It runs with **stdin closed**, so the prompt takes the EOF refusal and the process exits 1 — neither the status nor the node state is captured here. The earlier spec said "exits 0 on no", which was wrong in both directions. Exit 0 on a typed "no", with the state asserted, is case **2.29j**; the machine-readable form is case **2.35**, `--non-interactive` exiting **3** with `result=nothing-to-do` |
| 2.15 | Partial state | S2 clone, containerd.io downgraded to 2.2.1 | Reports partial, proceeds, completes |
| 2.16 | Rollback | clean S2 | Automated with five assertions: the rollback completes, `docker-ce` and `containerd.io` are back at the rollback versions, docker is running, and the canary volume data on the relocated root is intact. Container-ID identity, image accessibility, application response and config identity are **specified and not automated** — check them by hand when it matters |
| 2.17 | Rollback resumability | S2 clone with containerd.io already at 2.2.1 | `--replacepkgs` lets the rerun succeed rather than "already installed" |
| 2.18 | Rollback payload gate | S2 clone, `docker-ce-cli` removed from rollback dir | Fails in phase 0 before stopping services |
| 2.19 | Interrupted transaction | S1 clone, **discard afterwards** | Trap reports package state as UNKNOWN and does not claim packages are unchanged. Do the stubbed version (1b.13) first; killing a real rpm transaction risks the rpmdb |
| 2.20 | NVIDIA absent / corrupt / valid | S1 variants | Absent and corrupt both skip cleanly without aborting; valid installs |
| 2.21 | `.rpmnew` surfaced | S1 with a modified config.toml | Phase 6 reports the `.rpmnew` |
| 2.22 | Logs | any canonical run | Cleared beforehand; contains start marker, every expected phase, final marker; process exit status recorded |

### 2.23–2.28 — the containerd config-version boundary ⚑

New in the 2.2 → 2.3 retarget. containerd 2.2.1 loads config version 3; 2.3.4 raises
the current version to 4, and the compatibility is one-directional. Automated by
`tests/vm/config-version-check.sh`, which is **destructive** — reset the baseline
afterwards.

| # | Test | From | Pass criteria |
|---|---|---|---|
| 2.23 | v3 config under containerd 2.3.4 | S1 | containerd starts; `ctr version` and the overlayfs snapshotter respond; journal logs `Configuration migrated from version 3` |
| 2.24 | Config not rewritten | S1 | `/etc/containerd/config.toml` is byte-identical (sha256) after the rpm transaction; still `version = 3`; no `.rpmsave` |
| 2.25 | Relocated root survives the in-memory migration | S1 | `containerd config dump` under 2.3.4 still reports the relocated `root` |
| 2.26 | The v4 generators | S1 | `containerd config default` under 2.3.4 emits a version above 3; `containerd config migrate` writes to stdout and leaves the file untouched |
| 2.27 | **Rollback guard** ⚑ | S1 + v4 config on disk, no backup dir | `rollback-docker.sh` exits non-zero in phase 0c naming the config version; containerd.io **not** downgraded; docker and containerd still running |
| 2.27a | Guard follows phase 3's branch | S1, config **absent**, backup holds a v4 config | Refused, and the message names the *backup* as the offending file. Phase 3 restores the backup, so the backup — not the on-disk file — is what containerd would be asked to load |
| 2.27b | Older usable backup is found | S1, newest backup v4, older backup v3 | Refused, and the message prints the `cp` for the older, loadable backup rather than claiming none exists |
| 2.28 | Negative control — the hazard is real | S1 + v4 config, downgrade forced past the guard | containerd 2.2.1 fails to start; journal shows `expected containerd config version equal to or less than`; restoring the v3 file recovers it |

2.28 is the one that keeps 2.27 honest. If containerd 2.2.1 ever starts cleanly on a
v4 config, phase 0c is guarding nothing and should be reconsidered rather than kept
for decoration.

**Mutation-tested.** (The two captured blocks below are verbatim output from runs
against the 29.7.2 / containerd.io 2.3.3 build. The `2.3.3` in them is a record of
what the harness printed at the time, not a stale pin — editing it would falsify the
evidence.) Setting `ROLLBACK_MAX_CONFIG_VERSION=99` in the VM's copy of
`rollback-docker.sh` (so the guard can never fire) makes 2.27 fail in exactly the way
that matters — and shows what the guard is worth:

```
FAIL D3 aborted without naming the config version
FAIL D4 containerd.io was NOT downgraded (got '2.2.1', want '2.3.3')
FAIL D5 containerd is still running (got 'activating', want 'active')
FAIL D6 docker is still running (got 'inactive', want 'active')
```

Without the guard the rollback runs to completion and leaves the node with containerd
in a crash-restart loop and docker down. Note that the exit-code check alone (D2)
still passes in the mutant, because the rollback fails *later*, when it cannot start
containerd — so the state assertions D4–D6, not the exit code, are what actually
distinguish "refused safely" from "broke the node".

2.27a/2.27b are mutation-tested the same way. Making the effective-config choice skip
the backup (`if false; then` on that branch, reproducing the original defect found in
review) yields:

```
PASS D7  config absent + v4 BACKUP: rollback exited non-zero (exit 1)
FAIL D7a containerd.io was NOT downgraded (got '2.2.1', want '2.3.3')
FAIL D7b containerd still running (got 'activating', want 'active')
FAIL D8  refusal did not identify the backup as the offending config
```

D7 passing there is the whole point: the mutant's non-zero exit comes from the
rollback completing and *then* failing to start containerd. Any guard test that
checks only an exit code is measuring the outage it was meant to prevent.

### 2.29–2.38 — agent mode: the run record, `--preflight`, and the gates ⚑

New with `--status-file`, `--non-interactive`, `--preflight`, `gate()` and the gate
flags. Automated in `tests/vm/tier2-run.sh agent`, which is **destructive**: it upgrades
the node, builds a real single-node Swarm with `docker swarm init`, and resets the
baseline. The `agent` phase is not part of `all` and carries its own figure.

**The interactive path is the regression gate.** `tests/vm/tier2-run.sh` with its default
phases runs the same modified scripts with **no flags at all**, and its count must not
move. A change to agent mode that shifts it is a change to the interactive path,
whatever it was meant to be.

**The Swarm fixture is asserted before the gate cases run.** Without it the drain,
task-count and reactivation gates are never reached and every case below would pass
vacuously.

| # | Test | From | Pass criteria |
|---|---|---|---|
| 2.29a | Zero arguments behave exactly as before | S1 | The unflagged run still completes; packages at the target profile, containerd config unchanged, canary intact |
| 2.29b | The record of a successful run | S1 | `result=completed`, `exit_code=0`, `pkg_state=installed`, `services_stopped=false`, `next_action=none`, `mode=interactive`, `log_started=true`, `containerd_root` is the relocated path |
| 2.29c | The record of a phase-0 refusal | S1, corrupted payload | `result=refused`, `pkg_state=untouched`, `services_stopped=false`, record terminated, plus `assert_untouched_strict` at the baseline profile. The `refusal_reason=payload-invalid` mapping is asserted seven times over in 2.30b rather than here |
| 2.29d | A non-root invocation | S1 | Refused with `refusal_reason=not-root`, `next_action=rerun-as-root`, `log_started=false` — and it **does** write a record |
| 2.29e | A usage error writes **nothing** | S1 | Exit 1, no status file at the path, so a reused path still holds the previous run's record |
| 2.29f | `run_id` differs between runs | S1 | Two runs at the same path produce two different `run_id` values, which is what makes the "check `run_id` before trusting a reused path" rule usable. The terminator is asserted on the surviving record; the first is overwritten by the second, which is the behaviour being demonstrated |
| 2.29g | Every documented key is present | S1 | Not merely the terminator: each key the runbook documents appears in the record |
| 2.29h | An unwritable status path refuses first | S1 | Exit 1 before anything is stopped or installed; the check is the startup write itself |
| 2.29i | Rollback and cleanup write records too | S1 | Driven through the non-root refusal, the one path both share: each record names its own `script`, carries `refusal_reason=not-root` and `result=refused`, and terminates. Both nodes pass `assert_untouched_strict`, and the cleanup additionally leaves the seeded namespace object in place. It is a per-key check, not a schema validation |
| 2.29j | An at-target decline is not a completed upgrade | S2 | Answered "no" on a **real** stream, not a closed one: exit 0, `result=nothing-to-do`, `pkg_state=untouched`, and explicitly **not** `completed` |
| 2.30a | `--preflight` on a healthy node | S1 | Exit 0, `result=ready`; phase 4 never ran and no backup directory was created |
| 2.30b | `--preflight` refuses the phase-0 corruptions | S1 variants | Seven corruptions — wrong bundle, duplicates, corrupt RPM, wrong release, empty directory, stale plugins, missing plugins — each giving exit 1, `result=refused`, `refusal_reason=payload-invalid`, `next_action=rebuild-bundle` and `assert_untouched_strict`. The containerd release-suffix case is 2.6a and the `rpm --test` rejection is 2.13; neither is in this loop |
| 2.30b2 | A bare `--preflight` writes no status file | S1 | It must not invent a default path |
| 2.30c | **The hoist.** A relocated root that does not exist | S1, `config.toml` repointed at an absent path | Preflight refuses with `relocated-root-missing` and `next_action=fix-mount`, on a node with every service running — and does **not** create the missing directory. The harness repoints the config rather than unmounting the filesystem: on a production node the usual cause is an unmounted filesystem, and the guard reads the same way either way |
| 2.30d | `--preflight` on an already-upgraded node | S2 | Exit 3, `result=nothing-to-do`, and no failure report printed |
| 2.30d2 | At target **and** a missing relocated root | S2, `config.toml` repointed at an absent path | Still exit 3, `result=nothing-to-do`: the at-target classification wins over the relocated-root refusal. Asserted on exit, `result`, `refusal_reason` and the root not having been created — not a full state assertion, because the case deliberately modified the config and restores it afterwards |
| 2.30e | `--preflight` is read-only with a v4 config on disk | S2 + v4 config | A rollback-unsafe config is **reported**, not refused — the upgrade is not blocked by it |
| 2.30f | An absent config is `unknown`, never rollback-safe | S2, config removed | Preflight does not refuse and does **not** generate a config |
| 2.31 | An unanswered gate fails closed | S1 + Swarm fixture | Exit 1, `result=refused`, `refusal_reason=gate-unanswered:drain-self`, `next_action=supply-flag`, `pkg_state=untouched`; the message names both `--drain-self` and `--no-drain-self` |
| 2.32 | `--non-interactive` never reads stdin | S1 + fixture | The same invocation with a live `yes y` stream still refuses: exit 1, `drain_performed=false`, node untouched. This is the case that proves the prompt helper is **not reached** rather than auto-answered |
| 2.33 | `--non-interactive` without `--status-file` | S1 | Refused at parse time, naming the missing flag, and **no** status file appears |
| 2.33a | Contradictory flags are refused, not ordered | S1 | `--drain-self --no-drain-self` exits 1 naming the contradiction |
| 2.34 | A full non-interactive upgrade, end to end | S1 + fixture | `result=completed`, `mode=non-interactive`, `pkg_state=installed`, `swarm_role=manager`, `node_availability_before=active`, `node_availability_after=active`, `drain_performed=true`, and the node really is back `active` |
| 2.35 | Already at target under `--non-interactive` | S2 | Exit **3**, `result=nothing-to-do`, `node_class=at-target`, `pkg_state=untouched`, empty `refusal_reason`, `gates_required` names `rerun-at-target`. Asserted **temporally** — the phase-4 marker count is unchanged, so nothing was stopped |
| 2.36a–j | The gate predictor, one node state at a time | S1/S2 + fixture | Ten states — active manager with `--drain-self`, with `--no-drain-self`, with neither; already-drained manager with and without the drain flag; paused manager; non-Swarm host; at-target with and without `--rerun-at-target` — each asserting the exact `gates_required` and `gates_conditional`. The **worker** state is the one skip: a single node is always its own manager |
| 2.37 | A conditional gate is reported, not refused | S1 + fixture | `--preflight --non-interactive --drain-self --reactivate` with `proceed-with-tasks` unanswered exits **0**: `result=ready`, `next_action=proceed`, `gates_conditional=proceed-with-tasks`, `gates_unanswered=proceed-with-tasks`, `gates_answered=drain-self:y,reactivate:y` |
| 2.38 | `--confirm-delete` alone is refused under `--non-interactive` | S1 + Swarm fixture | Exit 1, `refusal_reason=inventory-sha-required`, `next_action=rerun-dry-run`, `deleted=false`. Asserted **temporally** — the phase-2 marker count is unchanged, so services were never stopped — and the seeded namespace object survives. The **interactive** half of "in every mode" is case 2.41, which runs the same refusal with a live `yes y` stream |
| 2.38a | An unanswered cleanup gate refuses before anything stops | S1 + fixture | Exit 1 even with a `yes y` stream attached; `refusal_reason=gate-unanswered:allow-non-swarm`, `deleted=false`, phase 2 never ran, the seeded object survives |
| 2.38b | Every cleanup gate answered runs unattended | S1 + fixture | Exit 0 with all four gates answered by flag, the last one `--no-confirm-delete`: `gates_answered=allow-non-swarm:y,assume-drained:y,confirm-stop:y,confirm-delete:n`, `refusal_reason=delete-declined`, `deleted=false`. It really did stop services and bring them back — the phase-2 marker count moved — and `services_stopped=false` afterwards because the run restored them |

**Mutation-tested**, in `tests/vm/agent-mode-negative-control.sh`:

- **M1a** moves the status write after `on_exit`'s `rc == 0` short-circuit. The mutant's
  successful run reports `result=running` for ever, which is what case 2.29b's
  `result=completed` assertion catches.
- **M1b** removes the `STATUS_OK` accumulator and makes one key's write fail. The mutant
  publishes a **truncated** record that still ends `status_complete=1` — a last-line check
  alone would pass it, which is why the writer requires both.
- **M2** deletes the hoisted relocated-root check from `preflight_report`. The mutant
  reports `ready` on a node the real run refuses, and the control follows that answer
  through to the upgrade to show what believing it costs: the node ends with packages
  replaced and services down.
- **M3** makes `gate()` fall through to `prompt_yes_no` under `--non-interactive`, run
  with a live `yes y` stream. The mutant drains and upgrades the node, which is exactly
  what case 2.32 asserts cannot happen.
- **M4a**, **M4b** are described with cases 2.40 and 2.41 below.
- **M5** makes rollback phase 0b ignore `--config-backup`; **M6** neuters phase 0c's guard
  and reaches it through `--preflight`. Both are described with cases 2.44–2.45.

### 2.39–2.42 — the cleanup dry run and the inventory hash ⚑

New with `clean-swarm-networks.sh --dry-run` and `--expect-inventory-sha`. Automated in
`tests/vm/tier2-run.sh agent`, which is **destructive** — it resets the baseline
afterwards.

**The fixture is not optional and is asserted before any case runs.** On a host that
is not in a Swarm the script refuses at the `allow-non-swarm` gate before stopping
anything, and an empty inventory takes the nothing-to-clean exit; either way every
case below would pass without executing the code under test. So the guest is made a
single-node Swarm with an attachable overlay network and a container attached to it,
and the harness asserts there are namespaces, a key-value store and a
`docker_gwbridge` to enumerate.

| # | Test | From | Pass criteria |
|---|---|---|---|
| 2.39 | `--dry-run` deletes nothing | S1 + Swarm fixture | Exit 0, `mode=dry-run`, `deleted=false`, `next_action=proceed`, `inventory_sha` is 64 hex characters, `inventory_total > 0`. Phase 2 **did** run and phase 4 did **not**; the key-value store's inode is unchanged; `docker_gwbridge` present; both services `active` |
| 2.40 | A wrong hash refuses, node intact | S1 + fixture | Exit 1, `refusal_reason=inventory-changed`, `next_action=rerun-dry-run`, `deleted=false`, `refusal_detail` carries both hashes. Phase 4 marker count unchanged; key-value store inode unchanged; services back `active` |
| 2.41 | `--confirm-delete` with no hash refuses, in **both** modes | S1 + fixture | Exit 1, `refusal_reason=inventory-sha-required`. Asserted **temporally** — the phase-2 marker count is unchanged, so the services were never stopped — plus the exact set of namespaces unchanged. The interactive form is run with a live `yes y` stream and refuses too |
| 2.41a | A malformed hash is a usage error | S1 + fixture | Exit 1, the message says the value is malformed rather than that the inventory changed, **no status file is written**, phase 2 never ran, inventory intact |
| 2.41b | `--dry-run` beside a delete answer is a usage error | S1 + fixture | Exit 1 for `--dry-run --confirm-delete` and for `--dry-run --expect-inventory-sha`, message names the contradiction, no status file, phase 2 never ran, inventory intact |
| 2.42 | A matching hash proceeds | S1 + fixture | Two passes back to back. Exit 0 or 2, `deleted=true`, `failed_items=0`, `inventory_sha` equals the first pass's. The key-value store's **inode changed**, phase 4 ran, and it reported exactly `inventory_total` removals. Services back `active`, canary volume data intact |

**Mutation-tested**, in `tests/vm/agent-mode-negative-control.sh`:

- **M4a** neuters the hash comparison so it always matches, and runs 2.40's exact
  invocation — a hash of 64 zeros no enumeration can produce. The mutant exits **0**
  and deletes the node's network state, which is why 2.40 asserts the key-value
  store's inode and the phase-4 marker count rather than the exit code.
- **M4b** makes `--confirm-delete` accepted with no hash, and runs 2.41's exact
  invocation on the same fixture. The mutant stops the services and deletes an
  inventory nothing had seen.

Neither mutant reproduces anything without the Swarm fixture: it would refuse at the
`allow-non-swarm` gate long before reaching a stop or a delete.

### 2.43–2.48 — the rollback preflight and the backup selection ⚑

New with `rollback-docker.sh --preflight`, `--config-backup` and `--non-interactive`.
Automated in `tests/vm/tier2-run.sh agent`, which is **destructive** — it upgrades the
node first, because a v4 config is what the target containerd generates and 2.48 needs
something to roll back from, and it resets the baseline afterwards.

The fixture stages two config files off the live path and **asserts their versions
differ across the boundary** before any case runs; two files that happened to carry
the same version would make 2.44 and 2.45 pass without testing anything.

| # | Test | From | Pass criteria |
|---|---|---|---|
| 2.43 | `--preflight` on a healthy node | S2 | Exit 0, `result=ready`, `mode=preflight`, `next_action=proceed`, `config_rollback_safe=true`, `pkg_state=untouched`. **State:** `assert_untouched_strict` at the target profile |
| 2.44 | `--preflight` with a v4 config and no usable backup | S2, backups removed, v4 on disk | Exit 1, `result=refused`, `refusal_reason=config-version-blocks-rollback`, `config_version_effective=4`, `config_rollback_safe=false`. **State:** containerd.io **not** downgraded, both services `active`, canary intact, the config file byte-identical. This is 2.27 re-expressed as a preflight — the same guard, on a node nobody has touched |
| 2.45 | `--config-backup` selects an older loadable backup | S2, newest backup v4, older v3, v4 on disk | Exit 0, `result=ready`, `config_backup_source=flag`, `config_backup_selected` names the older directory, `config_version_effective=3` while `config_version_on_disk=4`. **Paired:** the same node with `--config-backup=newest` refuses, which is what proves the flag did the work |
| 2.46 | `--config-backup` naming a directory that is not there | S2 | Exit 1, `refusal_reason=config-backup-not-found`, `next_action=supply-flag`, and `config_backup_selected=none` — it must **not** fall back to the newest, which here is the unloadable one. A directory that exists but holds no `config.toml` is refused the same way |
| 2.47 | Ambiguous selection refuses | S2, two backups | Real run, not a preflight. Exit 1, `refusal_reason=config-backup-ambiguous`, `config_backup_candidates` lists both. Asserted **temporally** — the phase-1 marker count in the rollback log is unchanged, so nothing was stopped — plus `assert_untouched_strict` |
| 2.48 | Non-interactive rollback completes | S2, one loadable backup | `--non-interactive` without `--status-file` is refused at parse time and writes nothing. With it, `--config-backup=newest` completes: `result=completed`, `pkg_state=installed`, `config_backup_source=flag`, the three rollback packages back at baseline with buildx and compose asserted to be LEFT at target (the rollback bundle carries no plugins), both services `active`, canary intact, and containerd still using the relocated root |

**Mutation-tested**, in `tests/vm/agent-mode-negative-control.sh`:

- **M5** makes phase 0b ignore `--config-backup` and always take the newest, then runs
  2.45's exact invocation. The mutant selects the v4 backup and refuses a rollback the
  flag makes safe. The same invocation against the real script reports `ready`, which
  is the half that proves the mutation is the difference.
- **M6** raises the guard's threshold so phase 0c can never fire — one mutation, and
  it covers both halves, because the threshold is what preflight reports *and* what
  the real run enforces. The mutant preflight reports `ready` for a node whose
  rollback strands it; following that `ready` into a real run completes the downgrade
  and leaves containerd refusing to start, with the journal naming the config version.

M6 is the reason 2.44 asserts `result=refused` and the node's state rather than an
exit code. A rollback that runs to completion and then cannot start containerd also
exits non-zero — just later, and after the outage.

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
| 3.3 | **Mixed-version cluster** | One node on 29.8.0, rest on 29.1.5; service spanning both; no ALPN errors; overlay traffic works both directions |
| 3.4 | Mixed-version soak | Sustained representative traffic, not one request. Journals on every node clean of ALPN, overlay, snapshotter, OOM, daemon-restart errors |
| 3.5 | Overlay DNS / VIP / ingress | Service discovery, VIP routing, routing mesh, secrets and configs all functional across versions |
| 3.6 | Manager upgrade | Self-drains; quorum retained; Raft healthy after |
| 3.7 | `wait_for_services` | With a **deliberately non-converged** service (0/1 → 1/1). Must wait for real convergence, not return instantly. Also test `docker service ls` failing, and zero-replica services |
| 3.8 | Cleanup abort | Answer "n" at the final prompt: services restarted, nothing deleted, exit 0 |
| 3.9 | `clean-swarm-networks.sh` | On a dedicated/snapshotted drained node: preview matches deletions exactly; services return; node rejoins overlays; exit 0 |
| 3.10 | Cleanup incomplete | Force one deletion to fail: reports the failure and **exits 2** |
| 3.11 | Rollback in a mixed cluster | A rolled-back 29.1.5 node rejoins a cluster containing 29.8.0 nodes and schedules work |

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

`recover-dnf.sh` still has **no dynamic test**. It is production recovery code that
stops services, changes packages, uses a bare readiness sleep (no `ctr` polling), has
no failure trap, and assumes a `docker-local` repo that does not exist on air-gapped
hosts. Two changes have been made to it and neither is dynamically tested: v1.2.2 fixed
a bare `read` under `set -e` that killed the script with no message on EOF, after
`dnf clean all` and `rpm --rebuilddb` had already run; v1.3.0 added
`--run-option-a` / `--no-run-option-a`, `--help` and `--version`, checked only by the
Tier 1 usage-and-runbook parity checks. Treat it as unverified: do not run it on a
production node without first exercising it in a VM. Bringing it to the standard of the other scripts is follow-up
work, deliberately out of scope here.

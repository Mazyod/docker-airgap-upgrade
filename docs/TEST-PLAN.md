# Test Plan — Docker 29.1.5 → 29.6.2 Retarget

**Date:** 2026-07-28
**Scope:** the six scripts retargeted in commit `a65edd7`

## What this plan can and cannot prove

Tests are split by where they can actually run.

- **Tier 1 — static.** Runs on the macOS dev machine. Proves syntax, lint, internal
  consistency, and that every pinned package genuinely exists upstream.
- **Tier 2 — RHEL VM.** Requires a RHEL 8 and a RHEL 9 VM. Proves the packages
  upgrade cleanly and services return. Cannot be run from the dev machine.
- **Tier 3 — production-like Swarm.** Requires a multi-node Swarm. Proves the parts
  that only exist in a cluster: drain/reactivate, overlay reconvergence, mixed-version
  operation.

**Tier 1 alone is not sufficient to authorize a production rollout.** It cannot
execute a single line of the upgrade logic. Tier 2 is the minimum bar.

---

## Tier 1 — Static (dev machine)

| # | Test | Method | Pass criteria |
|---|---|---|---|
| 1.1 | Syntax | `bash -n` on all 6 scripts | All parse |
| 1.2 | Lint | `shellcheck` on all 6 scripts | No findings; suppressions carry a reason |
| 1.3 | Package availability | HTTP HEAD every pinned RPM URL, el8 + el9, upgrade + rollback sets | All 16 return 200 |
| 1.4 | Version constant consistency | Grep target versions across scripts + README | 29.6.2 / 2.2.6 / 0.35.0 / 5.3.1 and rollback 29.1.5 / 2.2.1 agree everywhere |
| 1.5 | No stale literals | Grep for 28.5.1 / 1.7.29 / 0.30.1 / 5.0.1 | Only in historical comments and "from" columns |
| 1.6 | Phase structure | Grep phase banners in `upgrade-docker.sh` | 0–10 present, 4.5 absent, order monotonic |
| 1.7 | Removed logic is gone | Grep for `check_xfs_ftype`, `containerd config default >`, `containerd config migrate` | Only in comments; no live `config default >` outside the file-absent branch |
| 1.8 | Executable bits | `ls -l *.sh` | All 6 executable |
| 1.9 | Bundle script list | Compare `download-docker-packages.sh` copy loop against files on disk | Every listed script exists |
| 1.10 | Trap wiring | Grep `trap ... EXIT` / INT / TERM in the three stateful scripts | Present in upgrade, rollback, clean-swarm-networks |

## Tier 2 — RHEL VM

Run on **both** a RHEL 8 and a RHEL 9 VM. `simulate-upgrade.sh` covers the dnf path;
tests 2.3 onward cover the path that actually ships.

| # | Test | Method | Pass criteria |
|---|---|---|---|
| 2.1 | Simulation, RHEL 8 | `./simulate-upgrade.sh` | Exits 0; all asserts OK; containers survive; DNS on custom bridge works |
| 2.2 | Simulation, RHEL 9 | same, adjusting the el8 paths | Exits 0 |
| 2.3 | **Real air-gapped path** | Install 29.1.5/2.2.1, populate `/opt/docker-offline/rhel$N`, sever network, run `upgrade-docker.sh` | Exits 0; phase 9 asserts pass; `docker version` shows 29.6.2 |
| 2.4 | **containerd config preserved** ⚑ | Before 2.3, set `root = '/data/containerd'` in `/etc/containerd/config.toml` and create that dir. Run the upgrade. | Config still contains `/data/containerd` afterwards. **This is the regression the whole change exists to prevent.** |
| 2.5 | Custom daemon.json preserved | Add a registry mirror to `/etc/docker/daemon.json`, upgrade | Still present afterwards |
| 2.6 | Wrong-bundle rejection | Point `/opt/docker-offline/rhel$N` at the **29.1.5** RPMs, run `upgrade-docker.sh` | Fails in phase 0; node untouched; services still running; NOT drained |
| 2.7 | Duplicate-RPM rejection | Extract the new bundle over the old one so both 29.1.5 and 29.6.2 RPMs are present | Fails in phase 0 naming the duplicate |
| 2.8 | Corrupt-RPM rejection | `truncate -s -1M` one RPM | Fails digest check in phase 0; node untouched |
| 2.9 | Wrong-arch / wrong-release rejection | Put an `.el8` RPM in the rhel9 dir | Fails in phase 0 citing the release |
| 2.10 | Empty package dir | Remove all RPMs | Fails in phase 0 with a clear message |
| 2.11 | Idempotent re-run | Run `upgrade-docker.sh` again after a success | Detects already-at-target, offers to skip, exits 0 on "no" |
| 2.12 | Partial-state detection | Downgrade only containerd.io to 2.2.1, re-run | Reports partial upgrade and proceeds |
| 2.13 | Rollback | After a successful upgrade, run `rollback-docker.sh` | Exits 0; asserts show 29.1.5/2.2.1; containers survive |
| 2.14 | Rollback dry-run gate | Remove `docker-ce-cli` from the rollback dir, run rollback | Fails in phase 0 before stopping services |
| 2.15 | Failure reporting | `kill -TERM` the upgrade during phase 5 | Trap reports phase, `PKG_STATE=attempted`, and does NOT claim packages are unchanged |
| 2.16 | NVIDIA absent | Run on a VM with no NVIDIA toolkit | Phase 7 skipped cleanly |
| 2.17 | Log written | Check `/var/log/docker-upgrade.log` | Complete transcript present |

⚑ = the highest-value test in this plan.

## Tier 3 — Swarm

| # | Test | Method | Pass criteria |
|---|---|---|---|
| 3.1 | Manager self-drain | Run on a manager | Drains, upgrades, offers reactivation, converges |
| 3.2 | Worker drain guard | Run on an undrained worker | Prints manager-side command, refuses without attestation |
| 3.3 | Worker upgrade | Drain from manager, upgrade, reactivate | Tasks reschedule onto it |
| 3.4 | **Mixed-version cluster** | Upgrade one node, leave others on 29.1.5, run a service across both | No ALPN errors; overlay traffic works both ways. Validates the node-by-node claim. |
| 3.5 | Overlay survival | Service on an overlay network spanning upgraded and non-upgraded nodes | DNS and VIP routing keep working |
| 3.6 | `wait_for_services` | Watch phase 10 on a manager with a converging service | Waits for real convergence, does not return instantly or burn the full 60s |
| 3.7 | `clean-swarm-networks.sh` | Run on a drained node | Preview matches deletions; services return; node rejoins overlays |
| 3.8 | Cleanup abort path | Answer "n" at the final confirmation | Services restarted, nothing deleted, exit 0 |
| 3.9 | Rollback in cluster | Roll one upgraded node back to 29.1.5 | Rejoins a cluster containing 29.6.2 nodes |

## Exit criteria

- **Tier 1:** all pass. Blocks everything else.
- **Tier 2:** all pass on both RHEL 8 and RHEL 9. **2.4 is mandatory** — a failure
  there means the primary hazard is not actually fixed.
- **Tier 3:** 3.1–3.5 pass. 3.6–3.9 are strongly recommended; 3.4 specifically
  authorizes node-by-node rollout, and without it the rollout must be treated as
  whole-cluster.

## Rollout gate

Do not begin production rollout until Tier 2 passes on the matching RHEL major.
Roll the least critical node first, verify with the README verification block, then
proceed. Keep the rollback bundle on every node before starting.

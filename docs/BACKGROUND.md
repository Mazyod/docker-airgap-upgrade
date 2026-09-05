# Background

Design rationale and history for the 29.1.5 → 29.8.0 upgrade. Nothing here is needed to
run an upgrade; `RUNBOOK.md` and `docs/AGENT-RUNBOOK.md` are the operating documents.

## Why this upgrade

It picks up the cumulative fixes from Docker 29.2 through 29.8, including security
updates and a long run of overlay-networking fixes that matter for Swarm:

- 29.0.0 — NetworkDB fix for overlay entries stuck in a deleted state
- 29.3.0 — minimum API version lowered from v1.44 back to v1.40
- 29.5.0 — fix for stale VIP DNS records during rolling updates
- 29.7.0 — CVE-2026-17106 (`moby/go-archive`); fixes two daemon panics, one of them
  when removing Swarm ingress ports after an ingress proxy listener fails to bind
- 29.7.2 — nftables base-chain policy compatibility fix
- 29.8.0 — the largest batch of Swarm and overlay fixes in the 29.x line: service
  names failing to resolve after a missed membership announcement or a transient node
  failure, stale service-discovery values gossiped after concurrent updates to one
  key, `docker network inspect` failing to find a healthy network when a different one
  could not be allocated, and periodic gossip work spread over time instead of
  bursting. Also: dockerd no longer hangs when `nft` writes enough stderr to fill its
  pipe.

**29.8.0 fixes no CVEs.** Its Security section is two hardening changes: a configurable
default AppArmor profile template, and AppArmor/SELinux rules blocking the 32-bit
`socketcall(2)` path to `AF_VSOCK`. The CVE argument for this fleet was already
satisfied by 29.7.0 and 29.6.2, both of which the current pin includes. The reason to
take 29.8.0 is the Swarm and overlay work above, which is this repo's standing pain
area. `clean-swarm-networks.sh` exists because nodes came back from upgrades unable to
attach to overlay networks.

The upgrade does not stay inside one containerd line: containerd.io goes 2.2.1 → 2.3.4,
a minor bump onto containerd's first annual LTS. That raises the containerd config
version from 3 to 4, which is read-compatible going forward and not backward. See
[The containerd config version](#the-containerd-config-version). It is still far lower
risk than the 28.5.1 → 29.1.5 upgrade that preceded it, which crossed the containerd
1.7 → 2.x *major* boundary.

## The runc swap

`containerd.io-2.3.4-**2**` is the build to take, not `-1`. Upstream published 2.3.4
twice. The two RPMs have the same version, the same file list and the same dependencies;
the only difference is `/usr/bin/runc`, which is **1.4.3 in `-1` and 1.5.1 in `-2`**. So
this upgrade swaps the container runtime out from under every container on the node, and
it arrives as an RPM release-suffix bump rather than as a version bump.

`-2` is still the right choice. docker-ce 29.8.0 bundles containerd 2.3.4 and runc 1.5.1
in its own static binaries, so `-2` is the RPM that matches the combination Docker
actually tested. runc 1.5.1 also carries the fix for `EINVAL` on
`SECCOMP_FILTER_FLAG_WAIT_KILLABLE_RECV` when runc is built against libseccomp 2.6.0 or
newer and run against an older one, which is the RHEL 8 situation.

Because `%{VERSION}` reads as `2.3.4` for both builds, `upgrade-docker.sh` phase 0
asserts the RPM `%{RELEASE}` as well and refuses a bundle carrying `-1`. There is no
runc-specific coverage in the test plan; this is a decision recorded, not a risk
measured. The `/usr/bin/runc` shipped by each build was read from the RPM headers on the
test node and is recorded in `docs/TEST-PLAN.md`.

## Every package in this set is days old

docker-ce 29.8.0, buildx 0.37.0, compose 5.5.1 and the containerd.io `-2` rebuild were
all published within three minutes of each other on 2026-09-03. There is no 29.8.1 and
no reported 29.8.0 regression, but the release is too young for the absence of reports
to carry much weight. The 29.7.0 line needed two patch releases in six days to fix pull
and `docker cp` regressions.

Upstream release dates as of the 2026-09-04 retarget. Upstream release dates and RPM
publish dates are different things, so both are shown:

| Package | Version | Upstream release | RPM published | Age at retarget |
|---|---|---|---|---|
| docker-ce | 29.8.0 | 2026-09-03 | 2026-09-03 | **1 day** |
| containerd.io | 2.3.4-2 | 2026-08-12 | **2026-09-03** | 23 days / **1 day** |
| runc (inside containerd.io) | 1.5.1 | 2026-07-14 | — | 52 days |
| docker-buildx-plugin | 0.37.0 | 2026-09-02 | 2026-09-03 | **2 days** |
| docker-compose-plugin | 5.5.1 | 2026-09-03 | 2026-09-03 | **1 day** |

containerd 2.3.4 itself is three weeks old, but the `-2` rebuild that carries runc 1.5.1
was published on 2026-09-03 with everything else. The two-column split matters: the
version you can look up is older than the artifact you are actually installing.

The previous round shipped compose two days after release and called that the one
outlier. Here it is the whole set. Both plugins are CLI tools rather than parts of the
engine or the runtime, and neither is used by Swarm services, so taking the older
`docker-buildx-plugin` 0.36.1 and `docker-compose-plugin` 5.5.0 is a supported
alternative. Change `WANT_BUILDX` / `WANT_COMPOSE` in `tests/static-checks.sh` first,
then run it; it will name every other file that still needs editing.

### Shipping a weathered set instead

docker-ce 29.8.0 with containerd.io 2.3.3-1, buildx 0.36.1 and compose 5.5.0 also
satisfies every dependency (`docker-ce` 29.8.0 requires only `containerd.io >= 2.1.5`)
and keeps three of the five packages on builds this repo has already tested. Change
`WANT_*` in `tests/static-checks.sh` first and let the failures name the rest, with
three caveats the failures will not explain:

- **2.3.3, 0.36.1 and 5.5.0 are on check 1.5's stale-literal denylist** (the two
  `pattern=` lines in `tests/static-checks.sh`, in the `1.5 No stale version literals`
  section). Adopting them produces Tier 1 failures reading "stale literal in live code"
  for the very versions you were told to adopt. Roll the list: whatever target is being
  replaced becomes stale the moment it is replaced, and whatever you adopt must come off
  it.
- **`WANT_CONTAINERD_RELEASE` and `TARGET_CONTAINERD_RELEASE` go back to `1`.**
  containerd.io 2.3.3 was published upstream once, so `-1` is the only build.
- **`WRONG_CONTAINERD_RELEASE` in `tests/vm/lib.sh` has no valid value.** It names the
  *other* build of the target version, and 2.3.3 has none. Case 2.6a fails loudly rather
  than passing vacuously when it equals the target release, which is correct and which
  means 2.6a has nothing to test on that configuration. Case 2.6b likewise. Nothing in
  `tests/static-checks.sh` mentions this constant, so Tier 1 will not warn you.

## The containerd config version

containerd 2.2.1 supports config **version 3**. containerd 2.3.4 raises the current
version to **4**. The compatibility is one-directional, and both directions were
measured on a real node with a relocated containerd root, not read off release notes.
`tests/vm/config-version-check.sh` re-runs the whole thing.

| | Result |
|---|---|
| v3 config under containerd **2.3.4** | **Loads.** Migrated in memory at load time, logging `Configuration migrated from version 3`. The file on disk is not touched; it stayed byte-identical across the rpm transaction. A relocated `root` survives: `containerd config dump` still reports it. |
| v4 config under containerd **2.2.1** | **Refuses to start:** `failed to load TOML from /etc/containerd/config.toml: expected containerd config version equal to or less than 3, got 4` |

So the upgrade itself is safe and needs no config migration. The risk is entirely in the
**rollback** direction: a node that somehow acquires a v4 config is one emergency
rollback away from a runtime that will not start.

Nothing in these scripts writes a v4 config. The realistic way a node gets one is an
operator running `containerd config default > /etc/containerd/config.toml`, since under
2.3.4 that emits v4. (`containerd config migrate` is harmless; it writes to stdout, not
to the file.)

**`rollback-docker.sh` phase 0c guards this**, before stopping anything. It checks the
config containerd will actually be asked to load after the rollback, which is not always
the file currently on disk. Phase 3 restores the selected backup when there is one, so
when a backup exists that is the file phase 0c checks. Checking only the on-disk file
would miss an absent config paired with a backup that itself holds a v4 file. If that
config is one containerd 2.2.1 cannot load, the rollback is refused and the node is left
running.

If you hit that refusal, the message names the offending file and its version. Phase 0b
selects one backup, by default the newest; phase 0c then looks past that selection and scans
every `/root/docker-backup-*/` directory, so if any of them holds a config the older
containerd can load, the refusal names it and prints the exact `cp` to run. Otherwise restore a pre-upgrade copy from off the node, or hand-edit `version = 3`
and drop any v4-only keys, **keeping the top-level `root` and `state` values exactly as they
are**, since changing `root` repoints the node at a different data directory.

## What changed from the previous upgrade round

Three things the containerd 1.7 → 2.x migration required have been removed, because at a
minor containerd bump they are inert or harmful. All three remain in git history at
`upgrade-docker.sh` v1.2.3 (commit `974683a`) for a future containerd major bump.

| Removed | Why |
|---|---|
| containerd config regeneration (phase 6) | 2.3.4 reads the existing v3 config and migrates it in memory, so there is nothing to migrate on disk. Regenerating would discard a relocated `root` path, registry mirrors, and runtime config, silently repointing a node at an empty `/var/lib/containerd`, and would write a v4 file that blocks rollback. Phase 6 **verifies** the config instead of rewriting it. |
| XFS `ftype=1` check and relocation prompt | Any node already running containerd 2.x has satisfied this requirement. The check cannot fire usefully. |
| Automatic orphaned-network cleanup (phase 4.5) | The daemon now stops cleanly, so there is nothing orphaned. Extracted to `clean-swarm-networks.sh`, to be run on demand. |

Phase 4.5 is intentionally vacant. The number is left unused so phases 5 through 10 keep
the identities they have in the runbook and in logs from prior upgrades.

## Standing notes

**cgroup v1 is deprecated** as of Docker 29.0.0, with support continuing through May
2029. RHEL 8 defaults to cgroup v1; RHEL 9 defaults to v2. This is not blocking for this
upgrade, and these scripts do not change node cgroup configuration.

**NVIDIA is best-effort.** `libnvidia-container-devel` and
`libnvidia-container1-debuginfo` are force-removed first because they pin old versions.
Failures warn rather than abort, and a corrupt NVIDIA RPM skips the toolkit upgrade
rather than aborting the run. `nvidia-ctk runtime configure --runtime=containerd` is
deliberately skipped: `nvidia-ctk` does not understand containerd config v3, let alone
the v4 that 2.3.4 introduces, and rewriting the config is exactly what must not happen
here.

**Mixed 29.1.5 / 29.8.0 Swarm clusters are supported.** Both are Docker 29.x engines
speaking the same Swarm protocol, so nodes roll one at a time and a partially upgraded
cluster is a state you can stop in. containerd is a per-node local runtime and its
version does not cross the wire. This does not hold across the containerd 1.7 ↔ 2.x
boundary. The claim rests on both engines being Docker 29.x, not on a measurement:
mixed-version clusters are Tier 3 in `docs/TEST-PLAN.md` and have not been executed,
because the VM harness is a single node.

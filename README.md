# Docker Engine 29.1.5 → 29.8.0 Upgrade for Air-Gapped RHEL 8/9

Scripts for upgrading Docker Engine from 29.1.5 to 29.8.0 on air-gapped RHEL 8 and
RHEL 9 servers.

## Why This Upgrade

This picks up the cumulative fixes from Docker 29.2 through 29.8, including security
updates and a long run of overlay-networking fixes that matter for Swarm:

- 29.0.0 — NetworkDB fix for overlay entries stuck in a deleted state
- 29.5.0 — fix for stale VIP DNS records during rolling updates
- 29.3.0 — minimum API version lowered from v1.44 back to v1.40
- 29.7.0 — CVE-2026-17106 (`moby/go-archive`); fixes two daemon panics, one of them
  when removing Swarm ingress ports after an ingress proxy listener fails to bind
- 29.7.2 — nftables base-chain policy compatibility fix
- 29.8.0 — the largest batch of Swarm and overlay fixes in the 29.x line: service
  names failing to resolve after a missed membership announcement or a transient
  node failure, stale service-discovery values gossiped after concurrent updates to
  one key, `docker network inspect` failing to find a healthy network when a
  different one could not be allocated, and periodic gossip work spread over time
  instead of bursting. Also: dockerd no longer hangs when `nft` writes enough
  stderr to fill its pipe.

**29.8.0 fixes no CVEs.** Its Security section is two hardening changes — a
configurable default AppArmor profile template, and AppArmor/SELinux rules blocking
the 32-bit `socketcall(2)` path to `AF_VSOCK`. The CVE argument for this fleet was
already satisfied by 29.7.0 and 29.6.2, both of which the current pin includes. The
reason to take 29.8.0 is the Swarm and overlay work above, which is this repo's
standing pain area — `clean-swarm-networks.sh` exists because nodes came back from
upgrades unable to attach to overlay networks.

It does **not** stay inside one containerd line: containerd.io goes 2.2.1 → 2.3.4,
a minor bump onto containerd's first annual LTS. That raises the containerd config
version from 3 to 4, which is read-compatible going forward and **not** backward —
see [The containerd config version](#the-containerd-config-version) below. It is
still far lower risk than the 28.5.1 → 29.1.5 upgrade that preceded it, which
crossed the containerd 1.7 → 2.x *major* boundary.

### This bundle also replaces runc, and it does it quietly

`containerd.io-2.3.4-**2**` is the build to take, not `-1`. Upstream published
2.3.4 twice. The two RPMs have the same version, the same file list and the same
dependencies; the only difference is `/usr/bin/runc`, which is **1.4.3 in `-1` and
1.5.1 in `-2`**. So this upgrade swaps the container runtime out from under every
container on the node, and it arrives as an RPM release-suffix bump rather than as a
version bump.

`-2` is still the right choice: docker-ce 29.8.0 bundles containerd 2.3.4 and runc
1.5.1 in its own static binaries, so `-2` is the RPM that matches the combination
Docker actually tested. runc 1.5.1 also carries the fix for `EINVAL` on
`SECCOMP_FILTER_FLAG_WAIT_KILLABLE_RECV` when runc is built against libseccomp 2.6.0
or newer and run against an older one, which is the RHEL 8 situation.

Because `%{VERSION}` reads as `2.3.4` for both builds, `upgrade-docker.sh` phase 0
asserts the RPM `%{RELEASE}` as well and refuses a bundle carrying `-1`. There is no
runc-specific coverage in the test plan; this is a decision recorded, not a risk
measured.

### Every package in this set is days old

docker-ce 29.8.0, buildx 0.37.0, compose 5.5.1 and the containerd.io `-2` rebuild
were all published within three minutes of each other on 2026-09-03. There is no
29.8.1 and no reported 29.8.0 regression, but the release is too young for the
absence of reports to carry much weight — the 29.7.0 line needed two patch releases
in six days to fix pull and `docker cp` regressions.

If you would rather ship something weathered, docker-ce 29.8.0 with containerd.io
2.3.3-1, buildx 0.36.1 and compose 5.5.0 also satisfies every dependency
(`docker-ce` 29.8.0 requires only `containerd.io >= 2.1.5`) and keeps three of the
five packages on builds this repo has already tested. Change `WANT_*` in
`tests/static-checks.sh` first and let the failures name the rest — with three
caveats the failures will *not* explain:

- **2.3.3, 0.36.1 and 5.5.0 are on check 1.5's stale-literal denylist** (the two
  `pattern=` lines in `tests/static-checks.sh`, in the `1.5 No stale version
  literals` section). Adopting them produces Tier 1 failures reading "stale
  literal in live code" for the very versions you were told to adopt. Roll the
  list: whatever target is being replaced becomes stale the moment it is
  replaced, and whatever you adopt must come off it.
- **`WANT_CONTAINERD_RELEASE` and `TARGET_CONTAINERD_RELEASE` go back to `1`.**
  containerd.io 2.3.3 was published upstream once, so `-1` is the only build.
- **`WRONG_CONTAINERD_RELEASE` in `tests/vm/lib.sh` has no valid value.** It
  names the *other* build of the target version, and 2.3.3 has none. Case 2.6a
  fails loudly rather than passing vacuously when it equals the target release,
  which is correct and which means 2.6a has nothing to test on that
  configuration — 2.6b likewise. Nothing in `tests/static-checks.sh` mentions
  this constant, so Tier 1 will not warn you.

## Versions

| Package | From | To |
|---|---|---|
| docker-ce | 29.1.5 | **29.8.0** |
| docker-ce-cli | 29.1.5 | **29.8.0** |
| containerd.io | 2.2.1 | **2.3.4-2** |
| runc (inside containerd.io) | 1.4.3 | **1.5.1** |
| docker-buildx-plugin | 0.30.1 | **0.37.0** |
| docker-compose-plugin | 5.0.1 | **5.5.1** |

Rollback target is **29.1.5 / containerd.io 2.2.1**.

`docker-buildx-plugin` and `docker-compose-plugin` version independently of
docker-ce. Do not pin them to the docker-ce version.

**Upstream release dates**, as of the 2026-09-04 retarget — worth a glance, because
"latest" and "settled" are not the same thing on an air-gapped fleet you cannot
easily patch. Upstream release dates and RPM publish dates are different things, so
both are shown:

| Package | Version | Upstream release | RPM published | Age at retarget |
|---|---|---|---|---|
| docker-ce | 29.8.0 | 2026-09-03 | 2026-09-03 | **1 day** |
| containerd.io | 2.3.4-2 | 2026-08-12 | **2026-09-03** | 23 days / **1 day** |
| runc (inside containerd.io) | 1.5.1 | 2026-07-14 | — | 52 days |
| docker-buildx-plugin | 0.37.0 | 2026-09-02 | 2026-09-03 | **2 days** |
| docker-compose-plugin | 5.5.1 | 2026-09-03 | 2026-09-03 | **1 day** |

containerd 2.3.4 itself is three weeks old, but the `-2` rebuild that carries runc
1.5.1 was published on 2026-09-03 with everything else. The two-column split matters:
the version you can look up is older than the artifact you are actually installing.

The previous round shipped compose two days after release and called that the one
outlier. Here it is the whole set. Both plugins are CLI tools rather than parts of the
engine or the runtime, and neither is used by Swarm services, so taking the older
`docker-buildx-plugin` 0.36.1 and `docker-compose-plugin` 5.5.0 is a supported
alternative — change `WANT_BUILDX` / `WANT_COMPOSE` in `tests/static-checks.sh`
first, then run `tests/static-checks.sh`; it will name every other file that still
needs editing.

### Package Name Clarification

```
WRONG: containerd (standalone package)
RIGHT: containerd.io (Docker's bundled containerd)
```

## The containerd config version

containerd 2.2.1 supports config **version 3**. containerd 2.3.4 raises the current
version to **4**. The compatibility is one-directional, and both directions were
measured on a real node with a relocated containerd root — not read off release
notes. `tests/vm/config-version-check.sh` re-runs the whole thing.

| | Result |
|---|---|
| v3 config under containerd **2.3.4** | **Loads.** Migrated in memory at load time, logging `Configuration migrated from version 3`. The file on disk is not touched — it stayed byte-identical across the rpm transaction. A relocated `root` survives: `containerd config dump` still reports it. |
| v4 config under containerd **2.2.1** | **Refuses to start:** `failed to load TOML from /etc/containerd/config.toml: expected containerd config version equal to or less than 3, got 4` |

So the upgrade itself is safe and needs no config migration. The risk is entirely in
the **rollback** direction: a node that somehow acquires a v4 config is one emergency
rollback away from a runtime that will not start.

Nothing in these scripts writes a v4 config. The realistic way a node gets one is an
operator running `containerd config default > /etc/containerd/config.toml`, since
under 2.3.4 that emits v4. (`containerd config migrate` is harmless — it writes to
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
| containerd config regeneration (phase 6) | 2.3.4 reads the existing v3 config and migrates it in memory, so there is nothing to migrate on disk. Regenerating would discard a relocated `root` path, registry mirrors, and runtime config — silently repointing a node at an empty `/var/lib/containerd` — and would write a v4 file that blocks rollback. Phase 6 **verifies** the config instead of rewriting it. |
| XFS `ftype=1` check and relocation prompt | Any node already running containerd 2.x has satisfied this requirement. The check cannot fire usefully. |
| Automatic orphaned-network cleanup (phase 4.5) | The daemon now stops cleanly, so there is nothing orphaned. Extracted to `clean-swarm-networks.sh`, to be run on demand. |

## Scripts

| Script | Version | Purpose | Run On |
|---|---|---|---|
| `download-docker-packages.sh` | 2.3.0 | Download all packages, build the bundle | Online RHEL server |
| `upgrade-docker.sh` | 2.5.0 | Perform the upgrade | Air-gapped servers |
| `rollback-docker.sh` | 2.3.0 | Roll back to 29.1.5 | Failed upgrade recovery |
| `clean-swarm-networks.sh` | 1.3.0 | Reset orphaned overlay network state | Node that can't rejoin overlays |
| `recover-dnf.sh` | 1.3.0 | Fix dependency issues | Servers with broken dnf |
| `simulate-upgrade.sh` | — | Test the upgrade path in a VM | RHEL test VM |

Script versions drift on purpose — only scripts that actually changed get bumped.

The three stateful scripts accept `--status-file=PATH`, `--non-interactive`, `--help` and
`--version`, and refuse to run as a non-root user. `upgrade-docker.sh` and
`rollback-docker.sh` also accept `--preflight`.

`upgrade-docker.sh` and `clean-swarm-networks.sh` additionally accept
one flag per question — `--drain-self`, `--assume-drained`, `--confirm-stop` and so on, each
with a `--no-` form. Every flag states one fact the caller is accountable for; none performs
the thing it asserts. `--non-interactive` is a strictness switch, not a consent switch: it
grants nothing, and an unanswered question becomes a refusal that names the missing flag rather
than a default. It requires `--status-file`, because without the record an exit 1 cannot be
told from a failure.

`rollback-docker.sh` has no gate flags, because its one question is a value rather than a
yes/no: `--config-backup=newest|none|DIR` says which containerd config backup phase 3 should
restore. It is a fact, not an override — phase 0c still judges whatever config phase 3 would
actually load and still refuses one the older containerd cannot read, so naming a different
backup can only help by being a backup that genuinely loads.

`clean-swarm-networks.sh` also accepts `--dry-run` and `--expect-inventory-sha=SHA`. It is the
one script that cannot be driven in a single unattended invocation, and the reason is
structural: the inventory is enumerated only *after* the services stop, so nobody can be told
it in advance. The dry run stops, enumerates, prints the inventory with its hash, restarts and
exits 0; the real run hashes its own enumeration and refuses on a mismatch. The hash covers the
set of names and paths, never file contents, and services restart between the two passes — so
it proves the list is unchanged, not that the objects behind it are. See
`docs/AGENT-RUNBOOK.md` for the two-pass procedure.

`--preflight` runs every check that can be made with the node untouched and then exits,
changing nothing: no service stopped, no package installed, no directory created. It exits 0
when the real run would proceed, 1 when it would refuse, and 3 when the node is already at the
target. Its value is that it lifts two checks out of phase 6, which today runs *after* the rpm
transaction with both services stopped. A relocated containerd root whose filesystem is not
mounted is found there on a node that is already down; preflight finds it on a node where
everything is still running and refusing costs nothing.

`rollback-docker.sh --preflight` does the same for the rollback: it runs the payload
validation, the `rpm --test` dry run, the backup selection and the config-version guard, then
exits 0 or 1 without touching the node. That answers "would a rollback strand this node?"
before anyone needs the answer, rather than after the services are down.

**Running these from an agent rather than by hand?** Read `docs/AGENT-RUNBOOK.md`. Its first five sections are the whole **upgrade** procedure — the standing rule, the exact command sequence with a flag table by Swarm role, the decision table keyed on `result` and `refusal_reason`, and the never-do list. The rollback and the network cleanup are remedies rather than steps and have their own sections below its Reference divider, along with the full key and flag tables. `upgrade-docker.sh` and `clean-swarm-networks.sh` run unattended with `--non-interactive` plus the gate flags; `rollback-docker.sh` runs unattended with `--non-interactive` and `--config-backup`. `recover-dnf.sh` takes `--run-option-a` / `--no-run-option-a` and is the one exception to the end-of-file rule: it does not refuse a closed stdin, it skips its Option A and exits 0.

## Usage

### Step 1: Get the bundle

**Preferred — download a published release** (no online RHEL server needed):

```bash
gh release download v29.8.0-1
sha256sum -c <<< '<sha from the release notes>  docker-upgrade-bundle-v29.8.0-1.tar.gz'
```

Each release enumerates every package and version it contains, and ships one artifact
holding all RPMs, the operator scripts and the runbook. See `docs/RELEASING.md`.

**Or build it yourself on an online RHEL server:**

```bash
chmod +x download-docker-packages.sh
./download-docker-packages.sh
```

Produces `/opt/docker-upgrade-bundle.tar.gz` (~340 MB plus NVIDIA packages),
containing the 29.8.0 packages for RHEL 8 and 9 (with `containerd.io-2.3.4-2`, the
build carrying runc 1.5.1), the 29.1.5 rollback set, the NVIDIA Container Toolkit,
and all operator scripts. It also writes `MANIFEST.txt` into the bundle, listing
every RPM by name and `VERSION-RELEASE` read from the package header rather than from
its filename — that is the file to check when you need to know which containerd build
a node was handed.

The script fails loudly if any download 404s or any RPM in the four Docker
directories fails digest verification — a bundle full of HTML error pages is not
discovered on the air-gapped side. The `nvidia/` directory is deliberately outside
both checks: its packages come from `dnf download` rather than a pinned URL, and
phase 7 is best-effort, so a missing or corrupt NVIDIA RPM warns instead of aborting.

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

29.1.5 and 29.8.0 are both Docker 29.x engines and speak the same Swarm protocol, so
a mixed 29.1.5 / 29.8.0 Swarm is supported and will not produce the ALPN handshake
errors a mixed 1.7 / 2.2 cluster did. containerd is a per-node local runtime — the
2.2.1 / 2.3.4 difference does not cross the wire between nodes. Upgrade a node,
verify it, then move to the next.

That rule still applies across the containerd 1.7 ↔ 2.x boundary. Do not mix those.

**Caveat on how well this is tested:** mixed-version clusters are Tier 3 in
`docs/TEST-PLAN.md` and have **not** been executed — the VM harness is a single node.
The claim above rests on both engines being Docker 29.x, not on a measurement.

## Verification

After upgrade:

```bash
# Versions
docker version          # Should show 29.8.0
containerd --version    # Should show 2.3.4
runc --version          # Should show 1.5.1

# Packages, including the containerd.io RELEASE -- 2.3.4 shipped as -1 and -2
rpm -q docker-ce docker-ce-cli containerd.io
rpm -q containerd.io --queryformat '%{VERSION}-%{RELEASE}\n'   # want 2.3.4-2.el<major>

# ...where <major> is THIS host's RHEL major: 2.3.4-2.el8 on RHEL 8 and
# 2.3.4-2.el9 on RHEL 9. The script builds the same string from `rpm -E %rhel`.

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
wrong, duplicate, corrupt, wrong-arch or wrong-release RPMs; a `containerd.io` whose
RPM release is not `2` (which is how a bundle built from `2.3.4-1`, carrying runc
1.4.3, is caught — its version string is identical); plugins not at 0.37.0 / 5.5.1;
or an `rpm --test` dry run that the transaction fails. An unexpected starting version
warns and asks.

Phase 6 aborts if the config points at a **relocated** containerd root that does not
exist — that normally means its filesystem is unmounted, and creating the directory
would silently orphan every image and snapshot on the node.

## Testing

| Tier | Status for 29.8.0 | How |
|---|---|---|
| Static | **231/231** offline, **247/247** online | `./tests/static-checks.sh`; add `--online` for the 16 RPM URL checks |
| Host/guest preflight | **8 passed, 0 failed** | `./tests/vm/preflight-host.sh`, run by `bootstrap-vm.sh` |
| VM (real execution) | **67 passed, 0 failed** | `./tests/vm/bootstrap-vm.sh && ./tests/vm/build-bundle.sh && ./tests/vm/tier2-run.sh` |
| VM agent mode | **697 passed, 0 failed, 2 skipped** | `./tests/vm/tier2-run.sh agent` |
| VM config-version boundary | **30 passed, 0 failed** | `./tests/vm/config-version-check.sh` |
| Negative control | **3 passed, 0 failed** | `./tests/vm/negative-control.sh` |
| Agent negative control | **24 passed, 0 failed, 8 mutants** | `./tests/vm/agent-mode-negative-control.sh` |
| Multi-node Swarm | **not run** | needs a multi-node cluster — see `docs/TEST-PLAN.md` Tier 3 |

Every VM row was measured in one campaign on Rocky Linux 9 via the Docker backend,
against a bundle rebuilt from the checkout under test, on a guest recreated from
scratch, with the baseline reset between suites. The bundle was
`docker-upgrade-bundle.tar.gz`, 334 MB, sha256
`a00715919c1dbd8059e75aaf8958a7daf8eca1d637066bb41530465c2a91a507`, carrying
`containerd.io-2.3.4-2` for both RHEL majors. The `agent` phase is a separate
invocation (`tier2-run.sh agent`) and carries its own figure; the two are not
additive, and neither is a superset of the other. The two skips in the agent phase
are the worker predictor state, which needs a second node, and phase 4's VXLAN loop,
which an attachable overlay does not exercise from the host namespace. See
`docs/TEST-PLAN.md`.

The runc swap was verified directly on the node: `containerd.io-2.3.4-2` ships runc
1.5.1 and `-1` ships 1.4.3. Case 2.6a stages the real upstream `-1` RPM and proves
phase 0 refuses it with the node untouched; case 2.6b covers the other side of that
guard, the already-at-target gate.

The VM tier runs the real scripts against Rocky Linux 9 (x86_64, systemd) — an
OrbStack machine on macOS, or a privileged systemd container on a Linux host with
Docker — with containerd's root relocated to a separate XFS filesystem holding real
images, containers and volume data. It covers the phase-0 rejections, the real
upgrade, config preservation, idempotent re-run, and rollback.

**Swarm coverage is now partial, and the boundary matters.** The agent-mode phase builds a
single-node Swarm with `docker swarm init`, so a **manager draining and reactivating itself**
is exercised for real, as are the cleanup script's gates. Everything else about Swarm is still
untested: **worker** behaviour of any kind (a single node is always its own manager, and
demoting the last manager is refused), multi-node operation, overlay reconvergence, and mixed
versions.

The destructive half of `clean-swarm-networks.sh` is now **partly** exercised: on a real
single-node Swarm with an attached overlay network, phase 4 deletes the network namespaces,
the libnetwork key-value store and `docker_gwbridge` for real, and the services come back.
What is still untested there is the VXLAN deletion loop — an attachable overlay keeps its
VXLAN inside the network namespace, so the host-namespace list is empty and the harness
reports that as a skip rather than passing silently — and overlay reconvergence, which needs
more than one node.

**What no tier here reaches.** The Tier 2 rows above ran on Rocky Linux 9 — a RHEL
rebuild, not RHEL — through a privileged systemd container that shares this host's
kernel. So none of the following is tested anywhere in this repo: multi-node Swarm,
**worker** behaviour of any kind, overlay reconvergence, mixed-version clusters, real
RHEL (subscription-manager and satellite behaviour, which is the entire reason these
scripts use `rpm` over `dnf`), GPU nodes, bare metal, and the cleanup script's VXLAN
deletion loop. `docs/TEST-PLAN.md` states that boundary once and
`tests/vm/README.md` repeats it in detail.

Tier 3 in `docs/TEST-PLAN.md` is still mandatory before a production rollout, and
specifically 3.3/3.4 are what authorize rolling node by node.

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
├── MANIFEST.txt              # every RPM by NAME and VERSION-RELEASE, from headers
├── rhel8/                    # Docker 29.8.0 for RHEL 8
├── rhel9/                    # Docker 29.8.0 for RHEL 9
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

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Six standalone Bash scripts for upgrading Docker Engine 29.1.5 → 29.8.0 (and containerd.io 2.2.1 → 2.3.4-2) on **air-gapped RHEL 8/9 servers**. There is no application code, no build system, no package manager, and no test framework — the deliverable is the scripts themselves, bundled into a tarball and hand-carried to disconnected servers.

The scripts run as root on RHEL. They cannot be executed on the macOS dev machine.

## Working on this repo

There is no lint/test tooling configured. The practical checks:

```bash
bash -n upgrade-docker.sh                 # syntax check (works on macOS)
shellcheck upgrade-docker.sh              # available via homebrew
```

All six scripts are currently `bash -n` clean and `shellcheck` clean. Keep them that way — where a suppression is genuinely warranted, use an inline `# shellcheck disable=SCxxxx` with a reason, not a blanket ignore.

**Real execution happens through `tests/vm/`** — a harness that runs the actual scripts against Rocky Linux 9 (x86_64, systemd PID 1):

```bash
tests/vm/bootstrap-vm.sh      # build the S1 baseline
tests/vm/build-bundle.sh      # real download-docker-packages.sh run
tests/vm/preflight-host.sh    # host/guest fitness, incl. the restart-and-remount proof
tests/vm/tier2-run.sh         # Tier 2 cases: reject / upgrade / rollback
tests/vm/tier2-run.sh agent   # the agent-mode cases; NOT part of the default phases
tests/vm/config-version-check.sh  # containerd config v3/v4 boundary + the rollback guard
tests/vm/negative-control.sh  # prove test 2.4 catches the regression
tests/vm/agent-mode-negative-control.sh  # prove the agent-mode guard tests can fail
tests/vm/reset-baseline.sh    # back to S1 between destructive runs
```

The S1 baseline deliberately puts containerd's root on a **separate XFS filesystem at `/data/containerd`** with real images, containers and volume data on it. That is the configuration the pre-v2.0.0 phase 6 destroyed, and it is the only way to test it. See `tests/vm/README.md` for what this proves and — importantly — what it does not (single-node Swarm only, not real RHEL, no GPU, not bare metal).

Since the agent-mode slices, the harness builds a **single-node Swarm manager** with
`docker swarm init` for the gate cases, so a manager draining and reactivating itself is
exercised for real. **Worker behaviour remains entirely untested** — a single node is always
its own manager and demoting the last manager is refused — as do multi-node operation, overlay
reconvergence and mixed versions. Do not let "Swarm is tested now" grow beyond that sentence.

**The harness has two backends and runs on either host:** macOS with OrbStack, or Linux with a **local, rootful, x86_64** Docker daemon (a privileged Rocky 9 systemd container — no sudo, no KVM). `need_backend` checks those three daemon properties rather than assuming them: the repo reaches the guest as a bind mount of a host path, the baseline needs a real loop device and a nested dockerd, and the bundle is el9 x86_64. `tests/vm/lib.sh` picks one automatically from `HARNESS_BACKEND=auto|orb|docker` and sources `backend-orb.sh` or `backend-docker.sh`.

The backend contract is **six** core operations — `need_backend`, `vm_exists`, `vm`, `vm_try`, `vm_create`, `vm_delete` — plus `vm_wake` and `vm_restart` for the harness's own lifecycle code. This file used to claim the port surface was *four* helpers; that was wrong, because create and delete were raw `orbctl` calls sitting in `bootstrap-vm.sh` and `teardown-vm.sh` outside any helper. Don't reintroduce a raw hypervisor call anywhere but a backend file.

**The container backend's restart hazard is the sharp edge.** A guest restart tears down the mount namespace while the 3 GB loopback image survives, so without an ordered mount unit containerd starts on an empty shadow `/data/containerd` and reports itself active — manufacturing the exact data-loss symptom phase 6 exists to prevent. `ensure_relocated_mount()` installs a `data.mount` unit and a `containerd.service` drop-in (`RequiresMountsFor`) on **both** backends; `require_relocated_xfs()` refuses to proceed when the relocated root is not on XFS; `preflight-host.sh` restarts the guest and proves it comes back. Do not replace any of those with a bare `mount -o loop`.

`simulate-upgrade.sh` remains a separate dnf-path smoke test. It is **not** the same code path as `upgrade-docker.sh` (see below), so passing it does not prove the air-gapped path works.

## Two different install strategies (important)

The repo deliberately contains two incompatible ways of installing the same packages:

| Script | Strategy | Why |
|--------|----------|-----|
| `simulate-upgrade.sh` | `createrepo` + `dnf install` then `dnf distro-sync --allowerasing` | Two-phase dnf; plain `dnf upgrade` is a no-op here |
| `upgrade-docker.sh` | `rpm -Uvh --force` on a validated file list | Corporate satellite servers break dnf with `SSL certificate problem: EE certificate key too weak` |

`recover-dnf.sh` prints recovery commands that reference an `--enablerepo=docker-local` repo. That repo only exists on machines that ran the simulation path; on production air-gapped hosts it must be created first or the commands will fail.

## Current upgrade scope (read this before changing phase logic)

The cluster is on 29.1.5 / containerd.io 2.2.1. This upgrade crosses **containerd 2.2 → 2.3**, a minor bump (2.3 is containerd's first annual LTS), not the 1.7 → 2.x major boundary the previous round crossed. Several things that round required are still gone:

- **No containerd config migration or regeneration.** See the config-version section below — this is now a subtler claim than it used to be. Regenerating would discard a relocated `root` path, registry mirrors and runtime config — silently repointing a node at an empty `/var/lib/containerd` — *and* write a config that blocks rollback. Phase 6 verifies; it does not rewrite.
- **No XFS `ftype=1` check.** Any node running containerd 2.x has already satisfied it.
- **No automatic orphaned-network cleanup.** Extracted to `clean-swarm-networks.sh`, run on demand.

All three are recoverable from git history at `upgrade-docker.sh` v1.2.3 (commit `974683a`) if a future containerd **major** upgrade needs them back. Do not resurrect them for a minor bump.

**The whole-cluster-together rule does not apply here.** 29.1.5 and 29.8.0 are both Docker 29.x engines and speak the same Swarm protocol, so a mixed 29.1.5/29.8.0 Swarm is fine and nodes roll one at a time. containerd is a per-node local runtime; its version does not cross the wire between nodes. The rule still holds across the containerd 1.7 ↔ 2.x boundary. (Mixed-version clusters remain **Tier 3 and untested** — the VM harness is single-node.)

### The containerd.io RPM *release* suffix is load-bearing — this is the newest sharp edge

`containerd.io` 2.3.4 was published upstream **twice**, as `-1` and `-2`. The two RPMs
have identical file lists, identical `Requires` and an identical `%{VERSION}`. The
only difference is `/usr/bin/runc`: **1.4.3 in `-1`, 1.5.1 in `-2`**. Every other
package in the bundle is `-1`.

This bundle takes `-2`, because docker-ce 29.8.0 bundles containerd 2.3.4 and runc
1.5.1 in its own static binaries, so `-2` is the RPM matching the combination Docker
tested.

Consequences the scripts encode:

- **A version-only assertion fails open here.** `check_version` compares `%{VERSION}`,
  which reads `2.3.4` for both builds. `upgrade-docker.sh` therefore also asserts
  `EXPECTED_CONTAINERD_RELEASE="2"` against `%{RELEASE}`, through one shared predicate
  `containerd_release_matches <release> <want> <major>` called from **three** places:
  phase 0 (the payload), the already-at-target gate, and phase 9 (what rpm installed).
  The comparison is **exact string equality** against `"<want>.el<major>"` — not a
  prefix match. `%{RELEASE}` is exactly `"2.el9"` because the architecture lives in
  `%{ARCH}`, so there is nothing legitimate to tolerate on either side and every
  tolerance is a hole: an earlier prefix version accepted `"2"`, `"2.el9.el8"` and
  `"2.el9.foo"`. An empty argument on any of the three refuses.
- **The already-at-target gate is a call site, not an afterthought.** That branch ends
  in `exit 0`, so anything it accepts as "nothing to do" never reaches phase 9. A node
  holding `containerd.io 2.3.4-1` matches every `%{VERSION}` while running runc 1.4.3;
  without the release test there it would be told there was nothing to do. A release
  mismatch falls through to the partial-upgrade branch, which is correct.
- **The filename suffix is not boilerplate.** `download-docker-packages.sh` and
  `simulate-upgrade.sh` name `containerd.io-2.3.4-2`. A mechanical version bump that
  leaves `-1` in place downloads a real RPM that phase 0 then refuses, on the
  air-gapped server. `tests/static-checks.sh` check 1.4b compares the constant, the
  two download paths and `tests/vm/lib.sh` against `WANT_CONTAINERD_RELEASE`.
- **The VM harness builds containerd RPM paths by hand.** `tests/vm/lib.sh` exports
  `TARGET_CONTAINERD_RELEASE`; `tier2-run.sh` and `config-version-check.sh` must use
  it rather than a literal. Check 1.4b fails if a literal creeps back.
- **`download-docker-packages.sh` writes `MANIFEST.txt` into the bundle**, recording
  `VERSION-RELEASE` per package from RPM headers. A manifest that recorded only the
  version could not answer which containerd build a node was handed.
- **Text checks cannot prove a predicate works.** `tests/static-checks.sh` 1.4b greps
  the call sites and pins their full argument lists; 1.4c **extracts
  `containerd_release_matches` and `check_containerd_release` from the script and
  executes them** — 25 predicate cases and 7 wrapper cases, the wrapper ones asserting
  that `PKG_ERRORS` actually moves. Replacing either body with `return 0` passes every
  grep in 1.4b. Extract the real functions, never reimplement them; a copy is the next
  thing to drift. Note what 1.4b can and cannot do: it catches negation, a discarded
  exit status, a transformed input and a duplicate definition, but no text check can
  prove a call site is wired to a real node. Tier 2 cases 2.6a and 2.6b are what close
  that.

**Tier 2 status of the release guard.** Case **2.6a** — phase 0 refusing a payload
built from `containerd.io-2.3.4-1` — is automated in `tests/vm/tier2-run.sh` and
passing; it stages the real upstream `-1` RPM and asserts the node's packages,
services and canary data are untouched. Case **2.6b** — the already-at-target gate,
which decides there is nothing to do *before* phase 9 ever runs — is in
`tier2-run.sh` too and now passing; it downgrades containerd.io
alone to the `-1` build and re-runs the correct bundle. Do not report either as
verified beyond what `docs/TEST-PLAN.md`'s execution status says, and update that
table and this paragraph together.

The one part of the guard no Tier 2 case can reach is **phase 9's own release
check**: every scenario the harness can build installs the right release from a
valid bundle, so its failure branch never executes. Deleting its `VERIFY_FAILED=1`
left Tier 1 at 133/133 and Tier 2 green. `tests/static-checks.sh` 1.4b now pins
that assignment by text; it is the only thing standing between that mutation and a
green suite, so do not "simplify" it away.

### The containerd config version is asymmetric — this is the sharp edge

containerd 2.2.1 supports config **version 3**; 2.3.4 raises the current version to **4**. The compatibility is one-directional, and both directions were measured on a real node with a relocated root (`tests/vm/config-version-check.sh`), not inferred from release notes:

| | Result |
|---|---|
| v3 config under containerd 2.3.4 | **Loads.** Migrated in memory at load, logs `Configuration migrated from version 3`. Nothing written back; the file stays byte-identical. Relocated `root` survives — `containerd config dump` still reports it. |
| v4 config under containerd 2.2.1 | **Refuses to start:** `failed to load TOML from /etc/containerd/config.toml: expected containerd config version equal to or less than \`3\`, got \`4\`` |

Consequences that the scripts encode, and that must not be "simplified" away:

- **Nothing in the upgrade path may write a v4 config.** `containerd config default` under 2.3.4 emits v4, so phase 6's no-config branch warns loudly when it has to generate one. `containerd config migrate` writes to **stdout**, not to the file — that is why running it is harmless and also why it is pointless here.
- **The containerd.io RPM ships `/etc/containerd/config.toml` as `%config(noreplace)`** (verified: flags `cn`, re-verified on 2.3.4-2 for el8 and el9), so an operator's file survives the transaction byte for byte. That is the whole basis for "verify, don't rewrite".
- **`rollback-docker.sh` phase 0c is a fail-closed guard**, and it runs *before* anything stops. A v4 config on disk with no usable backup means the downgrade would succeed and then leave the node with a runtime that will not start — on the node that is already in trouble. Phase 0c refuses instead, while docker and containerd are still up and refusing costs nothing.
- **Order matters in rollback phase 3's "no config and no backup" branch.** It generates a default *after* the phase-2 downgrade, so it is the rollback containerd's own binary emitting its own version. Generating before the downgrade would write a version the downgraded binary cannot read.

## Invariants the scripts depend on

- **Service order is not optional.** Stop `docker` → `docker.socket` → `containerd`. Start `containerd` → wait for readiness → `docker`. Readiness means polling `ctr version` (up to 30×2s) **and** `ctr snapshots --snapshotter overlayfs ls`, because systemd reports containerd active before its snapshotter is usable. A bare `sleep` is not readiness.
- **Verify the stop, don't assume it — and fail closed.** After stopping, confirm `docker`, `docker.socket` and `containerd` are all conclusively stopped before touching packages or network state. Use the `verify_unit_stopped()` helper, not `systemctl is-active`: `is-active` returns nonzero for `activating`, `deactivating`, *and* for failing to reach systemd, so treating nonzero as "stopped" fails open. The helper requires a successful `systemctl show`, an ActiveState of `inactive` or `failed`, and `MainPID=0`. `docker.socket` specifically: if it survives while dockerd is down, anything touching the socket socket-activates dockerd again, mid-transaction.
- **The package is `containerd.io`, never `containerd`.** The standalone `containerd` package is a different, wrong thing.
- **Validate before destroying.** Everything checkable runs before the node is touched: `upgrade-docker.sh` phase 0 and `rollback-docker.sh` phase 0 verify digests, RPM metadata, expected versions, `el${RHEL_VER}` release, arch, and duplicates, then `rpm -Uvh --test` dry-runs the exact transaction — all while services are still up and the node is still in the Swarm.
- **Assert on RPM metadata, never on filenames.** The previous bundle has an identical directory layout, so a filename check would let an operator "upgrade" 29.1.5 → 29.1.5 and be told it succeeded.
- **One rpm transaction, not several.** Splitting containerd.io and docker-ce into separate invocations can leave a downgraded runtime under a newer engine. Resolving the set together closes that gap, and rpm — not argument order — decides install ordering. This is **not** atomicity: rpm has no general rollback once execution starts, so a failing scriptlet can still leave partial state. That is what `PKG_STATE="attempted"` exists to report.
- **`rollback-docker.sh` needs `--replacepkgs`.** `--oldpackage` permits a lower EVR but not reinstalling an identical one, so a rerun after a partially applied downgrade would be refused with "already installed" — on precisely the node that needs the rerun. (`upgrade-docker.sh` uses `--force`, which already implies it.)
- **Whole clusters upgrade together across a containerd major.** containerd 2.x's gRPC API is incompatible with 1.7.x; mixed-version Swarm clusters produce ALPN handshake errors. Does not apply within 2.x, including the 2.2 → 2.3 minor bump.
- **`docker-buildx-plugin` and `docker-compose-plugin` version independently** of docker-ce. Don't pin them to the docker-ce version.

## Version constants are duplicated — change all of them together

**Before changing a single constant, list what upstream actually has.** The version pinned
in this repo reads as authoritative and usually is not: the gap between building a bundle
and hand-carrying it to a disconnected server is long enough for two or three Docker point
releases, and bundles here have gone stale before shipping more than once.

```bash
curl -s https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/ \
  | grep -oE 'docker-ce-[0-9][^"<]*\.rpm' | sort -V -u | tail
```

Repeat for `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`, and for
`rhel/8`. Then check the *dependency*, not just the highest number — `docker-ce` 29.8.0
only requires `containerd.io >= 2.1.5`, so taking the newest containerd is a **choice**,
and crossing a containerd minor has real consequences (see the config-version section).
Check release dates too: "latest" and "settled" are different things, and putting a
two-day-old plugin on a fleet that cannot be patched is a decision to surface, not to make
silently.

**The RPM `%{RELEASE}` moves too, and it is not always `1`.** containerd.io 2.3.4
was published as both `-1` and `-2`, so four more constants have to move with the
versions, and none of them is a version string a mechanical bump would find:

| Constant | File | What it is |
|---|---|---|
| `WANT_CONTAINERD_RELEASE` | `tests/static-checks.sh` | the expectation the rest of Tier 1 is checked against — change this one first |
| `EXPECTED_CONTAINERD_RELEASE` | `upgrade-docker.sh` | what phase 0, the already-at-target gate and phase 9 all assert |
| `TARGET_CONTAINERD_RELEASE` | `tests/vm/lib.sh` | how the harness names containerd RPM paths, and half of the release title |
| `WRONG_CONTAINERD_RELEASE` | `tests/vm/lib.sh` | the OTHER upstream build, staged by cases 2.6a and 2.6b. A target version upstream published only once leaves this with no valid value; both cases then fail loudly rather than passing vacuously, and that is the signal to retire them for that target |

`TARGET_RUNC` / `WRONG_RUNC` in `tests/vm/lib.sh` are fixtures tied to those two
builds and move with them. `rollback-docker.sh` asserts `%{VERSION}` only: the
29.1.5 / 2.2.1 rollback set was published once.

Package versions (`29.8.0`, `2.3.4`, `0.37.0`, `5.5.1`, rollback `29.1.5`/`2.2.1`) appear in:

- `download-docker-packages.sh` — four download loops (rhel8, rhel9, rollback-rhel8, rollback-rhel9)
- `upgrade-docker.sh` — `EXPECTED_DOCKER_VERSION` / `EXPECTED_CONTAINERD_VERSION` constants, plus the header and banner
- `rollback-docker.sh` — `ROLLBACK_DOCKER_VERSION` / `ROLLBACK_CONTAINERD_VERSION` constants, plus the header and banner
- `simulate-upgrade.sh` — its own download loop, the `dnf install` pins, and the `assert_pkg` calls
- `tests/static-checks.sh` — `WANT_DOCKER` / `WANT_CONTAINERD` / `WANT_BUILDX` / `WANT_COMPOSE` / `WANT_CONTAINERD_RELEASE`
- `tests/vm/lib.sh` — `TARGET_*` including `TARGET_CONTAINERD_RELEASE`, plus `WRONG_CONTAINERD_RELEASE`, `TARGET_RUNC` / `WRONG_RUNC`, and `BASELINE_*` when the *starting* version moves. `tools/make-release.sh` sources this file, so the release title follows automatically — check 1.4b now compares all five `TARGET_*` against `WANT_*`, because a forgotten constant here used to pass Tier 1 and follow automatically into a wrong release title
- `README.md` — the bundle table in "What's in the bundle", and the target version wherever it
  is named in prose. Static check 1.4 asserts only that `WANT_DOCKER` appears somewhere in it
- `docs/BACKGROUND.md` — the release-date table, the runc-swap section, the config-version
  section, and the weathered-alternative list. **Nothing in Tier 1 checks this file**, so a
  retarget that skips it goes stale silently. Edit it in the same pass as `README.md`
- `RUNBOOK.md` — the target/from header, the phase-0 refusal table, and the verification block
- `docs/TEST-PLAN.md` — the version references in the Tier 2 table
- **`docs/AGENT-RUNBOOK.md` is deliberately NOT on this list.** Static check 1.14 fails if it contains any `x.y.z` literal at all, so it refers to versions as "what this run reported" and points an agent at `docker_ce_expected` / `containerd_io_release_expected` in the status file. A retarget cannot leave it stale, because there is nothing in it to go stale

The two upgrade/rollback scripts now hold their versions in named constants at the top rather than scattered through the body — change the constant, not the occurrences.

The two test files are the backstop: `tests/static-checks.sh` fails if any script or
README drifts from its `WANT_*` values, so a retarget that forgets a file gets caught
— but only if you update `WANT_*` itself. Change it first, then let the failures tell
you what else to edit.

Directory layout is assumed by path in several scripts: `/opt/docker-offline/rhel${RHEL_VER}`, `rollback-rhel${RHEL_VER}`, `nvidia`. RHEL version comes from `rpm -E %rhel`.

The bundle is `/opt/docker-upgrade-bundle.tar.gz` everywhere (this was previously inconsistent with README and the `upgrade-docker.sh` header; both are now fixed).

## Releasing — every shipment gets a GitHub release

Not optional, and not a per-upgrade decision. The deliverable is a ~330 MB bundle of
RPMs that gets hand-carried onto disconnected servers; a git tag records which scripts
shipped but says nothing about which packages an operator installed, and an air-gapped
operator cannot rebuild the bundle. See `docs/RELEASING.md`.

```bash
tools/make-release.sh v29.8.0-1        # --draft to review first
```

Tag scheme is `v<TARGET_DOCKER_VERSION>-<BUNDLE_REVISION>`. The script refuses to run
on a dirty tree, with unpushed commits, on an existing tag, or with failing static
checks — and it **always rebuilds the bundle from the current checkout** rather than
reusing whatever is in the VM. Release notes enumerate every package from RPM
metadata, never filenames.

## Agent mode — the run record is a compatibility surface

`upgrade-docker.sh`, `rollback-docker.sh` and `clean-swarm-networks.sh` accept
`--status-file=PATH` and write a flat `key=value` record of the run. Callers branch on those
keys, so **the key names are a contract**: adding one is a minor change, removing or
repurposing one is not. `tests/static-checks.sh` section 1.14 fails if the keys a script emits
and the keys `docs/AGENT-RUNBOOK.md` documents disagree in either direction.

**The check compares key NAMES, not value domains.** A new value for an existing key — the
cleanup's `mode=dry-run` was one — passes Tier 1 silently while the runbook's value column goes
stale. Widen the column in the same commit that widens the domain; nothing will catch you.

Four properties of the writer are load-bearing and each has a specific failure mode:

- **The status write precedes `on_exit`'s `rc == 0` short-circuit.** After it, a successful run
  never supersedes its own startup record and reports `result=running` for ever.
- **It publishes only when the `STATUS_OK` accumulator is true *and* the last line is
  `status_complete=1`.** Either alone can be satisfied by a truncated file: the call site's
  `|| true` suspends `set -e` for the writer's whole dynamic extent, so a `status_kv` that
  fails mid-file is followed by later ones that succeed, terminator included.
- **It writes through a direct redirect to a `mktemp` file, then renames** — never through the
  tee'd stdout, whose flush ordering at exit is not guaranteed.
- **`derive_result` is total and always returns 0.** A nonzero return would abort the EXIT trap
  under `set -e`, replacing 130 or 143 with its own status and writing no final record.

`status_kv`, `status_common`, `write_status_file`, `derive_result`, `unit_state` and
`unit_is_stopped` are byte-identical across the three scripts and are drift-checked in section
1.11. `status_keys` and `derive_next_action` differ by design.

`usage` is **not** drift-checked, and deliberately stopped being so once `--preflight` gave
`upgrade-docker.sh` an interface the other two do not have. Byte-identity never proved the help
text matched the parser anyway; section 1.14 now checks that instead, in both directions.

**`clean-swarm-networks.sh` writes its record after its trap's service recovery**, not before
the report. Its trap restarts what it stopped, unlike the other two; writing first would
publish `services_stopped=true` and `next_action=start-services` for a node the trap had just
brought back.

**`next_action` never says `rollback`.** Retry versus rollback after an rpm transaction is an
operator judgement that depends on why it failed, which is the same reason the trap does not
auto-restart services.

The ordering at the top of each script is also load-bearing: **globals → parser → traps →
startup record → root check → tee → banner.** The parser precedes the tee because `--help` must
not need write access to `/var/log`; the traps precede the root check so a non-root refusal is
still reported; and the root check precedes the tee because a non-root run cannot open the log
and the process substitution then swallows every line the script prints — measured, that
produced no output at all.

### `gate()` — the only wrapper around a prompt

`upgrade-docker.sh` and `clean-swarm-networks.sh` reach `prompt_yes_no` **only** through
`gate()`. `rollback-docker.sh` has no `gate()`: its single prompt becomes a value flag, so the
wrapper would be dead code there.

`prompt_yes_no` itself is **unchanged, byte for byte**, EOF refusal included. That is what
makes `--non-interactive` a strictness switch rather than a way to auto-answer: it bypasses the
read instead of relaxing it, so a wrapper piping `/dev/null` or `yes y` still cannot answer
anything.

Five properties are load-bearing:

- **`gate` is byte-identical across the two scripts that have it**, drift-checked in section
  1.11, so it may not reference anything script-specific. The only globals it touches are
  `GATE_ANSWERS`, `NON_INTERACTIVE`, `GATES_SEEN` and `REFUSAL_REASON`.
- **Every call site is an `if` or `if !` condition.** `gate` returns 1 for "no", exactly like
  `prompt_yes_no`, and a bare `gate ...` under `set -e` turns an ordinary no into an abort.
  Section 1.14 enforces the call-site shape, and enforces that `prompt_yes_no` is not called
  directly any more.
- **Under `--non-interactive`, `prompt_yes_no` is never reached.** Not reached and
  auto-answered — never reached. No static check can prove this; Tier 2 case 2.32 runs the
  refusal with a live `yes y` stream attached and asserts the node is untouched.
- **A pre-declared answer wins in BOTH modes.** `--drain-self` skips that prompt on an
  interactive run too. The flag states a fact; the mode only decides what happens to facts
  nobody stated.
- **`declare -A GATE_ANSWERS` precedes the parser.** Assigning `GATE_ANSWERS[x]` first creates
  an indexed array that cannot be converted afterwards.

`--non-interactive` **requires `--status-file`**, refused at parse time. Exit 1 conflates a
refusal with a failure, and this interface then tells the caller to read `refusal_reason` and
`next_action` — fields that do not exist without the file.

Two exit-code changes, and only under `--non-interactive` or `--preflight`: the
already-at-target decline exits **3** instead of 0. Interactively every code is exactly what it
was, which is what keeps the existing harness counts intact.

**`predict_gates()` is pure and total.** It runs from `preflight_report` and from inside the
EXIT trap via `status_keys`, so it may not touch the node and may not return nonzero. It
consumes `NODE_CLASS`, `SWARM_ACTIVE`, `IS_MANAGER` and `NODE_AVAILABILITY` — the same
variables the real branches switch on, never a re-derivation — which is what keeps the
predictor and the branches from disagreeing. Section 1.14 additionally requires every name
passed to `gate` to appear in it.

`gates_required` versus `gates_conditional` is not decoration. Two of the six upgrade gates
depend on what the run *does*, so preflight refuses only over the required list. Advertising
one list that silently omitted them would be worse than advertising none.

**`--confirm-delete` is refused without an inventory hash in every mode**, not only under
`--non-interactive`. A pre-declared answer wins in both modes, so the flag alone would skip the
post-enumeration confirmation with nothing having seen the inventory — the exact bypass the
enumerate-after-the-stop ordering exists to prevent.

### Workload recovery is separate from package completion

`workload_state` records cluster-wide Swarm replica convergence: `not-checked` until
an observation runs, `converged` for matching counts, `timeout` for a last observed
mismatch at the deadline, and `unknown` for an unavailable/malformed observation or
unknown final manager availability. It does not assert application health.
Phase 10 polls once for managers ending active, including `--no-drain-self`, and
preserves intentional drain/pause. Queries and polling share a 60-second deadline.
This advisory outcome does not change `result=completed` or the existing exit codes.

### The exit-code taxonomy

Nothing here may change without a deliberate decision: an agent branches on these, and so do
the Tier 2 cases.

| Exit | When | Notes |
|---|---|---|
| 0 | the run completed — **or** a decline that changed nothing | the reason exit 0 is ambiguous, and the reason `result` exists. See the decline list below |
| 1 | most refusals, and the controlled failures | **not** every failure: an unexpected command failure under `set -e` propagates its own status. Exit 1 conflates a safe refusal with a failure after the node was modified; `result`, `refusal_reason` and `pkg_state` separate them |
| 2 | `clean-swarm-networks.sh` only: cleanup ran, some items could not be removed | pre-dates agent mode. `derive_result` maps it to `completed` and `derive_next_action` to `investigate`. Not success |
| 3 | **`--non-interactive` or `--preflight` only**: already fully at the target | `result=nothing-to-do`, node untouched. `rollback-docker.sh` has no exit 3 — it has no at-target classification, and inventing one would change its interactive path |
| 130 / 143 | interrupt, through the INT/TERM traps | recorded as `result=interrupted` |

**`result=refused` with `exit_code=0` is a normal, reachable combination**, and any change that
makes it unreachable is a breaking change. `derive_result` sets `refused` whenever
`REFUSAL_REASON` is non-empty, *before* it looks at the status, and these declines all exit 0
because none of them changes package or network state: `allow-unverified-baseline` in the
upgrade, `config-backup-declined` in the rollback, and all four cleanup gates
(`non-swarm-declined`, `drain-unconfirmed`, `stop-declined`, `delete-declined`). `delete-declined`
is the one that is not free — it is reached after the stop, so its exit 0 follows a
stop-and-restart cycle. This is the strongest single reason
the interface tells callers to branch on `result` and never on `$?`.

`rerun-at-target` is the exception in the other direction: its decline sets `RESULT` directly
and no `REFUSAL_REASON`, so it records `nothing-to-do`, not `refused`. Declining it is not a
refusal — there was nothing to do — which is why it is the one gate whose unanswered state
resolves to an exit code rather than to a refusal.

Exit 3 exists **only** in the two new modes. Interactively every code is byte-for-byte what it
was, which is what keeps `tests/vm/tier2-run.sh`'s interactive-path regression gate meaningful:
that suite runs the modified scripts with no flags at all and must not move.

### Adding a gate, or any new prompt

A new question is not a prompt any more. It is five things, and section 1.14 enforces the first
four — the fifth is on you:

1. **A `gate NAME "question" default` call**, in an `if` or `if !` condition. Never a bare call:
   `gate` returns 1 for no, and `set -e` turns that into an abort.
2. **`--NAME` and `--no-NAME` parser arms**, spelled out literally, each routing through
   `set_gate`. Generated arms would accept `--no-anything` and record an answer for a gate that
   does not exist.
3. **An entry in that script's `predict_gates`**, in the `req=` or `cond=` assignment — not
   merely a mention. Add a gate and forget the predictor and preflight reports a clean bill
   while the real run refuses.
4. **A row in `docs/AGENT-RUNBOOK.md`**: in the gate table, and in that script's `<!-- flags:
   ... -->` block for both polarities. The runbook is what an agent reads instead of the
   scripts, so an undocumented flag is a flag nobody will use.
5. **A Tier 2 case** that answers it both ways and asserts node state, plus a mutant in
   `tests/vm/agent-mode-negative-control.sh` if the gate guards anything destructive. A guard
   test that asserts only an exit code is decoration: the failure mode the guard prevents also
   exits non-zero, just later and after the damage.

The same rule in reverse: a **status key** may be added freely, but removing or repurposing one
is a breaking change, and either direction needs its runbook row moved in the same commit.

### The cleanup dry run and `--expect-inventory-sha`

`clean-swarm-networks.sh --dry-run` stops, enumerates, prints the inventory and its hash,
restarts, and exits 0 having deleted nothing. It reaches the delete gate's **existing "no"
branch** by flag instead of by prompt — it is not a second route through the script. The real
run then hashes **its own** enumeration and refuses on a mismatch, restarting services first.

Four properties are load-bearing:

- **The hash covers names and paths, never file contents.** The libnetwork key-value store's
  bytes change on every dockerd run, so hashing them would make an honest second pass fail
  every time — and the pressure would then be to drop the check rather than fix it. Section
  1.14 greps `compute_inventory_sha` for any read of a file's bytes.
- **The hashing pipeline runs under `set -o pipefail`, in a subshell.** The script has `set -e`
  without `pipefail`, so a failing `sort` upstream of a succeeding `sha256sum` would produce a
  confident hash of nothing — which a later run would happily "match". A failure is
  `enumeration-failed`, never an empty inventory, by the same rule the enumeration already
  follows.
- **`LC_ALL=C sort` is what makes the hash reproducible at all.** Neither `ip` nor `find`
  guarantees an order.
- **The dry-run exit and the hash comparison both sit BEFORE the delete gate.** After it,
  either could be answered past by a pre-declared `--confirm-delete`.

**The two passes are a weakening, and it is stated rather than hidden.** Services restart in
between, so dockerd recreates namespaces and interfaces: the hash proves the *set of names* is
unchanged, not that the objects behind them are the same objects. What is untouched is the
load-bearing invariant — the destructive run still enumerates after the stop and deletes
exactly those captured arrays, never re-globbing, so a stale hash can never authorise deleting
a name that run did not enumerate. Section 1.14 greps phase 4 for a re-glob.

Freshness is documented, not enforced: nothing stops a caller passing an hour-old hash. A
one-time token was considered and rejected in the design — validating a nonce needs persisted
state that becomes its own stale artifact on a node nobody can reach.

`--dry-run` beside `--confirm-delete`, `--no-confirm-delete` or `--expect-inventory-sha` is a
parse-time usage error, and so is a hash that is not 64 lowercase hex characters. Neither
writes a status file, because at that point the path is not known to be valid.

### `rollback-docker.sh --config-backup` and `--preflight`

The rollback's one question is *which* backup phase 3 restores — a **value**, not a yes/no —
so it becomes `--config-backup=newest|none|DIR` rather than a gate. That is why this script
has no `gate()` and no `GATE_ANSWERS`: the wrapper would be dead code. Naming a non-newest
backup previously required aborting the rollback and copying a file by hand.

Four things are load-bearing:

- **The flag is a fact, not an override.** Phase 0c gains nothing. `--config-backup=DIR` can
  turn a refusal into `ready` only by naming a backup the older containerd can genuinely load.
  Section 1.14 greps the phase 0c block for `force`, `skip`, `override` and `GATE_ANSWERS` and
  requires zero matches, comments included — a comment offering an override is a design
  decision, not noise.
- **`--config-backup=none` weakens nothing.** With no backup selected, the config phase 3
  loads is the on-disk file, which is exactly what phase 0c then judges. A version that blocks
  the rollback still blocks it.
- **Phase 0c and phase 3 branch on the identical condition**, `[ -n "$BACKUP_DIR" ] && [ -f
  "$BACKUP_DIR/config.toml" ]`, and phase 3 never re-globs for a backup. A guard that inspected
  one file while phase 3 restored another would wave through exactly the config it exists to
  catch. Section 1.14 requires the shared condition in both regions and no `docker-backup-`
  glob in phase 3.
- **`config_version_effective` reports what 0c judged**, not what is on disk. With a v4 on disk
  and a v3 backup selected they differ, and reporting the disk would tell an agent the opposite
  of the decision.

Under `--non-interactive`, more than one backup with no `--config-backup` is refused as
`config-backup-ambiguous` rather than resolved by taking the newest. Under `--preflight` the
newest is *reported* with a note that the real interactive run would ask — preflight never
prompts, and refusing over a question the interactive path would simply ask would be a worse
answer than reporting one.

`--preflight` runs phases 0, 0b and 0c and exits before phase 1. Those three phases were
already read-only, so preflight is the same path with an earlier exit, not a parallel one. It
exits 0 (`ready`) or 1; there is no exit 3, because this script has no already-at-baseline
classification and inventing one would change the interactive path. Section 1.14 scans
`preflight_report` plus phases 0, 0b and 0c for mutators and requires the exit to sit after
phase 0c and before phase 1.

Design and plan: `docs/superpowers/specs/2026-09-04-agent-mode-design.md` and
`docs/superpowers/plans/2026-09-04-agent-mode-implementation.md`.

## Script versioning convention

Every script except `simulate-upgrade.sh` declares `VERSION="x.y.z"` on ~line 4 and echoes it in its startup banner. Only the scripts actually changed get bumped — versions across scripts drift on purpose. Currently:

| Script | Version |
|---|---|
| `upgrade-docker.sh` | 2.6.0 |
| `rollback-docker.sh` | 2.3.0 |
| `download-docker-packages.sh` | 2.3.2 |
| `clean-swarm-networks.sh` | 1.3.0 |
| `recover-dnf.sh` | 1.3.0 |

Commit subjects carry the new version in parens, e.g. `Fix NVIDIA toolkit upgrade failures (v1.2.2)`, with a bullet list body.

## upgrade-docker.sh structure

Numbered phase blocks, each fenced by a `####` comment banner: **0 validate payload** → 1 Swarm detect/drain → 2 pre-upgrade checks → 3 backup to `/root/docker-backup-<timestamp>/` → 4 stop services (+ verify stopped) → 5 rpm upgrade → 6 verify containerd config → 7 NVIDIA toolkit → 8 start services → 9 verification + version assertion → 10 Swarm reactivation. Add new work as a new numbered phase rather than inlining it elsewhere.

**Phase 4.5 is intentionally vacant.** It held the orphaned-network cleanup. The number is left unused so phases 5–10 keep the identities they have in the runbook and in logs from prior upgrades.

Things the phase structure encodes:

- **Phase 0 runs before anything mutates the node** — including before the Swarm drain. A payload problem must not leave a node drained.
- **The containerd 1.x hard stop is evaluated unconditionally**, before the already-at-target / partial-upgrade / unexpected-version branches. It was previously nested inside the unexpected-version branch, which made it bypassable: a node with docker-ce already at 29.8.0 but containerd still 1.x took the partial-upgrade branch and never reached it. Any guard that must always fire belongs outside the `if/elif/else`, not in one arm of it.
- **Already-at-target means all five packages**, not the core three. A partially applied transaction can leave correct core packages beside stale plugins, and that node still needs the run.
- **`rollback-docker.sh` has a phase 0b** that selects and confirms the containerd config backup *before* services stop. Choosing it in phase 3 (after the downgrade) left an operator who saw the wrong backup named with no option but to interrupt a half-finished rollback.
- **`rollback-docker.sh` has a phase 0c** that refuses the rollback outright when `/etc/containerd/config.toml` is a version the rollback containerd cannot load and no usable backup exists. It runs before phase 0b's services stop, for the same reason: a node that downgrades and then cannot start its runtime is strictly worse off than one that was told no.
- **Swarm workers cannot drain or inspect themselves** — only managers can run `docker node` commands. Workers get printed instructions and a "has this been drained?" prompt; managers drain themselves interactively. `IS_MANAGER` comes from `.Swarm.ControlAvailable`.
- **Failure is reported, not guessed at.** An EXIT trap tracks `CURRENT_PHASE`, `SERVICES_STOPPED`, and a tri-state `PKG_STATE` (`untouched`/`attempted`/`installed`). It deliberately does **not** auto-restart services: after an rpm transaction, retry-vs-rollback is an operator judgement call. `PKG_STATE` is set to `attempted` *before* the rpm call, because a transaction can change host state and still fail.
- **NVIDIA is best-effort.** `libnvidia-container-devel` and `libnvidia-container1-debuginfo` are force-removed first because they pin old versions; failures warn instead of aborting. A corrupt NVIDIA RPM skips the toolkit upgrade rather than aborting the run. `nvidia-ctk runtime configure --runtime=containerd` is deliberately skipped — nvidia-ctk doesn't understand containerd config v3, let alone the v4 that 2.3.4 introduces, and rewriting the config is exactly what must not happen here.

## clean-swarm-networks.sh

Standalone remedy for a node that returns from an upgrade unable to attach to overlay networks (`failed adding service binding`). Deletes VXLAN interfaces, `/var/run/docker/netns/*`, `<data-root>/network/files/local-kv.db`, and `docker_gwbridge`. The data root is scraped out of `/etc/docker/daemon.json`.

Two things are load-bearing and must not be "simplified":

- **The inventory is enumerated after services stop, and deletion iterates exactly that captured list.** Enumerating before the stop, or re-globbing at deletion time, means the confirmation prompt can describe something different from what actually gets deleted.
- **Enumeration failure is not treated as an empty inventory.** `mapfile < <(cmd || true)` cannot see the command's exit status, so a failing `ip` would silently read as "nothing to clean". Output and status are captured separately, and a failed enumeration aborts.

Exits 2 when cleanup was incomplete, so a wrapper checking `$?` doesn't record a partial remedy as success.

## Bash conventions used here

- `set -e` everywhere, so any command whose failure is acceptable needs an explicit `|| true`.
- `exec > >(tee -a /var/log/docker-<action>.log) 2>&1` at the top of the long-running scripts.
- `RED`/`GREEN`/`YELLOW`/`NC` color vars with `echo -e`.
- Interactive prompts go through `prompt_yes_no "text [Y/n]" "y"`; the default is passed separately from the prompt string. Destructive prompts default to `n`. It **refuses EOF** rather than applying the default — otherwise a non-interactive run (ssh without `-t`, any wrapper) silently auto-answers every prompt, including the drain prompt, which defaults to yes.
- **Every script that calls a helper must also define it.** These are standalone files; there is no shared library. `rollback-docker.sh` once called `prompt_yes_no` without defining it, and because the call sat in an `if !` condition the missing command's exit 127 inverted to "abort", exiting **0** — a silent no-op emergency rollback that reported success. `bash -n` cannot see this and shellcheck does not flag unresolved commands, so `tests/static-checks.sh` check 1.12 enforces it.
- **Compare Swarm state exactly, never `grep -q "active"`** — a non-Swarm host reports `inactive`, which contains `active`.
- **Any new harness check must be mutation-tested.** A check that greps for a function *name* passes even when the definition is deleted, because the call site supplies the string. Break the thing deliberately and confirm the harness fails and exits non-zero before trusting it.
- **A guard test must assert state, not the exit code.** For any guard whose job is to *refuse* a destructive operation, "the script exited non-zero" proves nothing — the failure mode the guard exists to prevent also exits non-zero, just later and after the damage. A neutered `rollback-docker.sh` phase 0c ran the downgrade to completion and then failed to start containerd; its exit status was identical to a clean refusal. Assert the things the guard was protecting — package versions unchanged, services still `active`, canary data intact — alongside the status. A guard test that cannot fail is decoration.
- EXIT traps do `local rc=$?` first, `[ "$rc" -eq 0 ] && exit 0`, and end with `exit "$rc"`. Paired with `trap 'exit 130' INT` / `trap 'exit 143' TERM` so signals route through the same reporting.
- Scripts assume GNU userland (`grep -oP`, `findmnt`, `xfs_info`) with fallbacks where it mattered — don't test behavior against macOS tooling.

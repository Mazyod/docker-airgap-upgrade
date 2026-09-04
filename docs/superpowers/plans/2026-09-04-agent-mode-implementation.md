# Agent Mode — Implementation Plan

**Date:** 2026-09-04
**Design:** `docs/superpowers/specs/2026-09-04-agent-mode-design.md`
**Base:** written against `eb972f0`, to be executed **after** the version-retarget branch
merges.

## How to use this plan

Eight slices. Each is independently committable, independently reviewable, and leaves the
tree green: `bash -n` clean, `shellcheck` clean, `tests/static-checks.sh` passing, and the
interactive-path regression gate intact.

**Line numbers are as of `eb972f0` and will have moved.** Every location is also given as an
anchor — a function name, a phase banner, a constant. Navigate by the anchor and treat the
number as a hint.

**No version literals.** The retarget branch changes package versions and may change script
`VERSION` constants. This plan names neither. Where it says "bump the minor", bump from
whatever the file has when the slice starts.

**Rules that apply to every slice.**

- Bump the `VERSION` constant of every script the slice changes, and only those.
- Commit subject carries the new version in parens, with a bullet-list body.
- Any new harness check is mutation-tested in the same commit: break the thing deliberately,
  confirm the check fails and exits non-zero, then restore.
- Any guard test asserts **state** — package versions, service states, node availability,
  canary data — not just the exit code. A guard's failure mode also exits non-zero.
- `docs/AGENT-RUNBOOK.md` is updated in the same commit as the behaviour it documents. A
  slice that ships a flag without its runbook row is not finished.
- Submit the diff to Codex for review before committing, using that slice's focus questions.

## Test environment

`tests/vm/` is being ported to a Linux Docker backend on a concurrent branch. Once that
merges, Tier 2 runs on this host and every Tier 2 step below is executable. If the port has
not merged when a slice starts, say so plainly — Tier 2 is unrunnable for an environment
reason, not skipped for an unrelated one — and do not claim the slice is done.

Reset the baseline between destructive runs: `tests/vm/reset-baseline.sh`.

---

## Slice 1 — `docs/AGENT-RUNBOOK.md` and the `AGENTS.md` fork

The cheapest independently useful change: it cuts the reading surface from roughly 48k tokens
to roughly 4k with zero script changes and zero risk to any execution path.

**It documents today's interface**, honestly, including the parts that are bad for an agent:
`prompt_yes_no` refuses EOF, exit 0 means three different things, and nothing is
machine-readable. Later slices replace those sections as they replace the behaviour.

### Files

| File | Change |
|---|---|
| `docs/AGENT-RUNBOOK.md` | new, structure per the spec's outline. Estimated ~200 lines; it landed at ~410 after review, because describing today's interface accurately took more room than describing it approximately |
| `AGENTS.md` | +8 lines at the top: a two-way fork |
| `tests/static-checks.sh` | new section 1.14, check 1.14.7 |
| `README.md` | one line pointing at the new document |

`AGENTS.md` today sends every reader to `CLAUDE.md` "in full before changing anything", which
is 21 KB about editing the scripts. The fork:

- changing the scripts → `CLAUDE.md`
- operating a node → `docs/AGENT-RUNBOOK.md`

### Tests

**Static check 1.14.7 — no package version literals in `AGENT-RUNBOOK.md`.**

```
grep -nE '\b[0-9]+\.[0-9]+\.[0-9]+\b' docs/AGENT-RUNBOOK.md
```

Zero matches required. This is the backstop for the design constraint that keeps the runbook
off the version-sync list in `CLAUDE.md`.

The regex also matches three-part section numbers, so do not number the runbook's sections
that way. That is a feature: a blanket ban is easier to reason about than a heuristic that
tries to tell a version from a heading, and it cannot be defeated by a version that happens to
sit in a sentence the heuristic did not expect.

**Mutation test:** insert a line containing a three-part version into the runbook, run
`tests/static-checks.sh`, confirm it FAILS and exits non-zero, remove the line, confirm it
passes.

### Tier 2

None. No script changes.

### Version bump

None — no script changes.

### Commit

`Add docs/AGENT-RUNBOOK.md and fork AGENTS.md by audience`

### Codex focus

- Does the runbook describe today's interface accurately, or has it drifted toward the
  interface this plan is about to build?
- Does it tell an agent anything that would be unsafe if the agent believed it?
- Is the never-do list complete against `CLAUDE.md`'s invariants?

---

## Slice 2 — argument parser, root check, status file

The parser lands here rather than in the gate slice because `--status-file` needs one. The
root check lands here because it belongs structurally beside the parser: both must run
**before** `exec > >(tee -a ...)`, where a non-root run currently dies with an opaque error.

### Files and locations

| File | Anchor | Change |
|---|---|---|
| `upgrade-docker.sh` | after the colour vars (~:66), before `exec > >(tee` (:68) | `usage()`; **all parser-owned globals initialised first**, including `declare -A GATE_ANSWERS=()` and `NON_INTERACTIVE=false` even though slice 4 is what populates them; then the parser; then `RUN_ID` and `STARTED` |
| `upgrade-docker.sh` | ~~move the `EXPECTED_*` constants above the startup write~~ | **Not done, deliberately.** That block is exactly where the concurrent retarget lands, and moving it would guarantee a conflict for no functional gain: `unknown` is a member of every key's domain, so the startup record emits `docker_ce_expected=unknown` and the final record carries the real value. The `*_expected` keys are only ever read from a final record |
| `upgrade-docker.sh` | **move** the failure-handling block (:77–:176) to sit immediately after the parser, still before the tee | `status_kv()`, `write_status_file()`, `derive_result()`, the `RESULT` / `REFUSAL_REASON` / `NEXT_ACTION` / `STATUS_WRITTEN` globals, then `on_exit()` and the three traps, unchanged in content |
| `upgrade-docker.sh` | after the traps | startup write: `RESULT="running"`, then `write_status_file` **required to succeed** — on failure set `REFUSAL_REASON=bad-usage`, report the path, exit 1 |
| `upgrade-docker.sh` | after the startup write | `id -u` root check |
| `upgrade-docker.sh` | `on_exit()` | the `STATUS_WRITTEN` guard plus `write_status_file \|\| true`, **before** the `rc -eq 0` short-circuit |
| `upgrade-docker.sh` | phases 0, 1, 5, 6, 7, 9, 10 | assign the reporting variables the writer emits |
| `rollback-docker.sh` | same shape; `exec > >(tee` at :47, failure block :69–:132 | same |
| `clean-swarm-networks.sh` | same shape; `exec > >(tee` at :48 | same |

**The startup record emits `unknown` for everything not yet observed**, `exit_code` and
`ended` included. Empty strings would violate the documented domains, and inventing a value
would be worse. `unknown` is a member of every key's domain precisely so the startup record can
be schema-valid.

**`OPERATION_COMPLETED`** starts `false` and is set `true` at the completion banner, the same
line that prints `UPGRADE COMPLETE`, `ROLLBACK COMPLETE` or `NETWORK CLEANUP COMPLETE`. It is
what `derive_result` reads for the rc-2 row.

**Assigning `GATE_ANSWERS[x]` before `declare -A GATE_ANSWERS` creates an indexed array and
cannot be converted afterwards.** The declaration must precede the parser even though nothing
populates it until slice 4. Same rule for every other variable the parser or the trap reads:
initialise it to a schema-valid default before either runs.

**The ordering is the substance of this slice**: globals → parser → traps → startup write →
root check → tee → banner. Each step is there for a reason and the reasons are in the spec's write
mechanics section. Moving the failure-handling block earlier is a pure relocation; its
contents do not change.

**But exits before the tee have no log entry.** A non-root refusal, or a signal between arming
the trap and installing the tee, prints to the terminal only. The status file records
`log_started=false` for those, so an agent does not go read stale log content and attribute it
to this run.

The parser recognises only `--status-file=PATH`, `--help` and `--version` in this slice. An
unrecognised flag is a usage error: message on stderr, exit 1, and **no status file**, because
at that point the path is not known to be valid. Zero arguments must leave every variable at
its default and change nothing.

`--help` must not require root and must not touch `/var/log`, so it is handled inside the
parser, before everything else.

If `--status-file` is given, **the startup write itself is the writability check**: perform
it for real and require it to succeed, exiting 1 before anything mutates if it does not. A
sibling create-and-remove probe proves less — it never exercises the rename, which is what a
sticky directory or a root-owned existing target actually blocks.

### Writer requirements (all nine are load-bearing)

1. Called before `on_exit`'s `rc -eq 0` short-circuit.
2. Guarded with `|| true` at the call site.
3. Writes a brace group straight to a temp file beside the destination, then `mv -f` — never
   through the tee'd stdout.
4. `STATUS_WRITTEN` is set by `on_exit`, not by the writer, so the startup write does not
   consume it. The writer contains no `exit`.
5. **Two mechanisms, both required.** `status_kv` sets `STATUS_OK=false` when its `printf`
   fails; the terminator `status_complete=1` is emitted only while `STATUS_OK` is true; the
   rename happens only when `STATUS_OK` is true **and** the last line is the terminator.
   Neither alone is sufficient: the `|| true` at the call site suspends `set -e` for the
   writer's whole dynamic extent, so a mid-file failure is followed by later writes that
   succeed — terminator included.
6. The temp file comes from `mktemp "${STATUS_FILE}.tmp.XXXXXX"`, not `.tmp.$$`. Exclusive
   creation beside the destination means a stale temp from a killed run with a reused pid can
   never be examined and published.
7. `tail`'s status is captured, not discarded: `if last=$(tail -n 1 "$tmp") && [ "$last" = ... ]`.
   A `tail` that prints the right line and then fails must not authorise the rename.
8. On any failure the temp file is removed, the previous content is left in place, and the
   writer **returns nonzero** so the startup call can act on it.
9. `derive_result` is total and always returns 0, and is called `|| true` anyway. A nonzero
   return would abort the trap under `set -e`, replacing 130 or 143 with its own status and
   writing no final record — on precisely the interrupted run an agent most needs to read.

One `status_kv <key> <value>` call per key, so key names stay greppable literals.

**`clean-swarm-networks.sh` gets a different trap order.** Its EXIT trap already restarts
services after a failure (`clean-swarm-networks.sh:229–248`), unlike the other two, which
deliberately do not. Writing the status before that recovery would publish
`services_stopped=true` and `next_action=start-services` on a node whose services the trap
then successfully restored. Its order is: save `rc` → attempt recovery → set
`SERVICES_STOPPED=false` and record the outcome in `recovery_attempted` /
`recovery_succeeded` → derive → write → `exit "$rc"`.

Also add to `tests/vm/lib.sh` a helper the later slices need:

```
assert_pkg_profile        <label> <baseline|target>   # the five package versions only
capture_strict_state      <name>                      # snapshot before the invocation
assert_strict_state_unchanged <label> <name>          # compare after it
assert_untouched_strict   <label> <baseline|target> <name>   # both of the above
```

A profile alone is not enough. "No new backup directory" and "config sha unchanged" are
statements about *this invocation*, not about a fixed constant: the target-state backup count
varies with how many upgrades have run, and case 2.47 deliberately creates two backups. So the
comparison must be against state captured immediately before the invocation under test.

`capture_strict_state` records the containerd config sha, the `/root/docker-backup-*` count,
both service states, and the canary value. `assert_strict_state_unchanged` compares all four.
The profile argument covers only the package versions, which *are* a constant per profile.
Cases 2.33, 2.45, 2.46 and 2.47 run against an upgraded node and pass `target`.

The existing `assert_untouched` at `tier2-run.sh:43` checks only `docker-ce` and the docker
service, which can miss a partial containerd or plugin change. **Do not modify
`assert_untouched`** — that would change the pre-existing 45-assertion count and break the
regression gate.

### Tests

**Static 1.14.5 — documented status keys match emitted keys.** Extract emitted keys with
`grep -oE '^\s*status_kv [a-z0-9_]+'` per script; extract documented keys from the
`AGENT-RUNBOOK.md` key table; require set equality in both directions.

**Mutation test for 1.14.5:** delete one key's row from the runbook table, confirm the check
fails; restore. Then delete one `status_kv` call, confirm it fails; restore.

**Static 1.12 extension:** add `status_kv` and `write_status_file` to the helper list in the
"every helper called is also defined" loop.

### Tier 2

New harness phase `tests/vm/tier2-run.sh agent`, which resets the baseline first and leaves
it reset.

| # | Case | Assertions |
|---|---|---|
| 2.29a | Zero-argument run is unchanged | `./upgrade-docker.sh </dev/null` behaves exactly as case 2.3 does: `UPGRADE COMPLETE`, all five packages at target, config sha unchanged, canary intact. Then reset. |
| 2.29b | Status file on success | run with `--status-file=/tmp/s.kv`; file exists, `result=completed`, `exit_code=0`, `pkg_state=installed`, `services_stopped=false`, `docker_ce_after` equals `docker_ce_expected`, `containerd_root` is the relocated root |
| 2.29c | Status file on refusal | with the case-2.6 corruption (previous round's RPMs in the package dir): `result=refused`, `refusal_reason=payload-invalid`, `pkg_state=untouched`, **and** packages still at baseline, docker and containerd still `active` |
| 2.29d | Non-root refusal | run as an unprivileged user with `--status-file` in a writable location: exit 1, message names root, **status file written** with `result=refused`, `refusal_reason=not-root`, `next_action=rerun-as-root`, last line `status_complete=1`. **State:** packages unchanged, both services `active` |
| 2.29e | Usage error writes nothing | `--nonsense-flag`: exit 1, message on stderr, **no status file**, packages unchanged, both services `active` |
| 2.29f | Terminator present on every path | every status file produced by 2.29b–2.29d ends with `status_complete=1`, and `run_id` differs between runs |
| 2.29g | Every documented key present | each status file carries every key the runbook documents for that script, not merely the terminator. This is what catches a mid-file write failure |
| 2.29h | Unwritable status path refuses early | `--status-file=/nonexistent-dir/s.kv`: exit 1 before any mutation, message names the path, `assert_untouched_strict <label> baseline <snapshot>` |

2.29c through 2.29e assert state, not only the exit code.

**Mutation tests — new file `tests/vm/agent-mode-negative-control.sh`**, following the shape
of `tests/vm/negative-control.sh`: reset the baseline before and after, and assert that each
mutant reproduces its hazard.

- **M1a:** move `write_status_file` to after the `rc -eq 0` short-circuit. Run 2.29b against
  the mutant and confirm it FAILS. The hazard is **not** "no status file" — the startup write
  still leaves one behind. It is that the file still says `result=running` after a successful
  upgrade, so an agent reading it cannot tell success from a crash.
- **M1b:** remove the `STATUS_OK` accumulator, leaving only the terminator check, **and** make
  one selected `status_kv` call fail from the inside — mutate the function so that key's
  `printf` targets a closed descriptor. The injection has to be internal: adding a redirection
  failure at a call site means the function never runs, so the accumulator logic under test is
  never exercised and the mutant proves nothing. Confirm the mutant publishes a file that ends
  in `status_complete=1` but is **missing that key**, and that 2.29g FAILS against it. A
  last-line check alone cannot catch this, which is exactly why both mechanisms exist.

### Deviations recorded during implementation

- **The `EXPECTED_*` constants stay where they are**, per the table above.
- **Three keys added after the rebase onto the retarget**: `containerd_io_release_before`,
  `_after` and `_expected`. The retarget made the RPM `%{RELEASE}` load-bearing, and a record
  carrying only the version could not say which of two builds was installed. Documented in the
  design and the runbook.
- **Two keys added beyond the spec: `docker_active` and `containerd_active`**, read at write
  time. `services_stopped` records that the script *began* stopping services, which is what the
  recovery logic needs; a stop that fails partway leaves it true with docker still running.
  Without an observed pair, `next_action=start-services` could be emitted for a node whose
  daemon is up. `derive_next_action` now requires both units to be observed down.
- **`refusal_reason` is set at every deliberate exit**, not only the two the first draft had.
  Without that, `derive_result` classified every phase-0 rejection as `failed` rather than
  `refused`, and both exit-0 declines as `completed`. The spec always required `result` to be
  precise; this is what makes it so. The full token list is in `docs/AGENT-RUNBOOK.md`.
- **The NVIDIA token set is wider than the spec's four**: `toolkit-absent` (no toolkit on the
  node, so phase 7 never ran) is distinct from `payload-missing` (toolkit present, bundle
  shipped no NVIDIA packages) and from `not-attempted` (the run ended before phase 7).
- **`clean-swarm-networks.sh` arms its traps before `start_services` is defined.** Safe because
  `on_exit` only calls it when `SERVICES_STOPPED` is true, which cannot happen until phase 2.
  Arming them after the helpers instead would leave an interrupt during the root check with no
  record at all.

### Version bump

Minor bump on `upgrade-docker.sh`, `rollback-docker.sh`, `clean-swarm-networks.sh`.

### Commit

`Add --status-file and an argument parser to the stateful scripts (vX.Y.Z)`

### Codex focus

- Is the status write correctly ordered against the `rc == 0` short-circuit **and** the tee?
- Can `write_status_file` re-enter the trap or change the exit code on any path?
- Does the parser have any side effect when given zero arguments?
- Does relocating the failure-handling block above the tee change any existing behaviour?
- Can a partial status file be published on a full or read-only filesystem?
- Does the startup `result=running` write leave a usable file if the script is SIGKILLed?

---

## Slice 3 — `upgrade-docker.sh --preflight`, non-gate parts only

**Scope boundary, and it matters.** This slice ships preflight's *payload, version, Swarm
detection, config and root* reporting. It does **not** predict gates and must **not** emit
`gates_required` or `gates_conditional` — those keys arrive in slice 4, with the gates
themselves. Shipping a predictor before there is anything to predict would either be dead
code or a second source of truth for gate names.

### Files and locations

| Anchor | Change |
|---|---|
| parser | accept `--preflight`; set `MODE=preflight` |
| phase 0 (`# Phase 0: Validate Package Payload`, :368) | unchanged; preflight runs it as-is |
| after the version classification (~:600) | assign shared classification variables into named globals, so slice 4's predictor consumes them rather than re-deriving them |
| phase 1 detection block (:611–:645) | split detection from the prompt calls, so preflight runs detection and stops |
| phase 6 (:930 config version, :1001–:1034 relocated root) | extract both reads into functions called from preflight **and** from phase 6 |
| new preflight exit point | after phase-1 detection: report, write status, exit 0/1/3 |

The phase-6 extraction is the highest-risk edit in the whole plan. Phase 6 must keep enforcing
both checks with identical behaviour; preflight calls the same functions in report-only form.
The relocated-root function must **not** `mkdir` — the mkdir stays in phase 6, outside the
extracted read.

`dnf check` runs without the `dnf clean all` / `rpm --rebuilddb` repair.

### Tests

**Static 1.14.8 — preflight is read-only.** Between the preflight entry marker and its exit,
grep for `mkdir`, `systemctl (start|stop)`, `rpm -Uvh` without `--test`, `dnf clean`,
`rpm --rebuilddb`, `docker node update`, `rm -`. Zero matches required.

**Mutation test:** insert `mkdir -p /tmp/x` into the preflight block, confirm the check fails;
remove it.

### Tier 2

| # | Case | Assertions |
|---|---|---|
| 2.30 | `--preflight` from S1, with `--status-file` | exit 0, `result=ready`, `mode=preflight`, `log_started=true`. **State:** docker-ce and containerd.io still at baseline, both services `active`, `/etc/containerd/config.toml` sha unchanged, canary container running and `/data/canary.txt` intact, no new `/root/docker-backup-*` directory, and the count of `=== Phase 4: Stop Services ===` lines in `/var/log/docker-upgrade.log` unchanged from before the run |
| 2.31 | `--preflight` against each of the 2.6–2.12 corruptions | run with `--status-file`. exit 1, `result=refused`, `refusal_reason=payload-invalid`, `assert_untouched_strict "2.31" baseline <snapshot>` for each |
| 2.32 | `--preflight` with the relocated root unmounted | `umount /data`; with `--status-file`: exit 1, `result=refused`, `refusal_reason=relocated-root-missing`, `containerd_root_present=false`. **State:** packages at baseline, both services `active`, `/data` still not a mountpoint and **not** populated by the script. Remount and reset. |
| 2.33 | `--preflight` already at target | after a real upgrade, with `--status-file`: exit 3, `result=nothing-to-do`. **State:** `assert_untouched_strict "2.33" target <snapshot>` |
| 2.33a | Bare preflight writes no file | `--preflight` with no `--status-file`: exit 0, prose report on stdout, no file created anywhere, `assert_untouched_strict "2.33a" baseline <snapshot>` |

2.32 is the case that justifies the hoist. Today the same condition aborts at phase 6 with
packages already replaced and services stopped.

**Mutation M2** in `agent-mode-negative-control.sh`: delete the hoisted relocated-root check
from the preflight block, with `/data` unmounted.

Confirming only that the mutant reports `result=ready` is **not enough** — 2.32's untouched-
state assertions still pass against it, because a preflight that reports the wrong answer
still touches nothing. The hazard is what happens when an agent *believes* that answer. So M2
must follow the `ready` through into a real upgrade run and assert the hazard reproduces:
`rpm -q containerd.io` shows the target version, docker and containerd are **stopped**, and
the run aborted in phase 6. That is the post-RPM, services-down state the hoist exists to
prevent, and it is what proves 2.32 is a real test. The VM is left wrecked, so reset the
baseline immediately afterwards, exactly as `negative-control.sh` does.

### Version bump

Minor bump on `upgrade-docker.sh`.

### Commit

`Add upgrade-docker.sh --preflight with hoisted phase-6 predictions (vX.Y.Z)`

### Codex focus

- Does anything in the preflight path mutate the node?
- Does the phase-6 extraction change phase 6's enforcement in any observable way, including
  the `mkdir` for a missing default root?
- Can preflight report `ready` for a node the real run would refuse?
- Are the classification variables genuinely shared, so slice 4's predictor can consume them
  without re-deriving?
- Does this slice emit any gate key it cannot yet compute?

---

## Slice 4 — `gate()`, `--non-interactive`, and the gate flags

The only slice that touches prompt control flow, and therefore the only one that needs the
full interactive regression run.

### Files and locations

| File | Anchor | Change |
|---|---|---|
| `upgrade-docker.sh` | after `prompt_yes_no` (:213–:233) | `GATE_ANSWERS`, `NON_INTERACTIVE`, `GATES_SEEN`, `gate()` |
| `upgrade-docker.sh` | :569, :598, :656, :681, :689, :716, :1290 | one-token change per call site |
| `upgrade-docker.sh` | parser | `--non-interactive` and twelve gate flags (`--<name>` / `--no-<name>`) |
| `upgrade-docker.sh` | preflight block | gate prediction: `gates_required`, `gates_conditional`, `gates_unanswered`, consuming slice 3's classification variables |
| `upgrade-docker.sh`, `clean-swarm-networks.sh` | parser | `--non-interactive` requires `--status-file`; refuse the pair at parse time as `bad-usage` |
| `clean-swarm-networks.sh` | after `prompt_yes_no` (:61) | same `gate()`, byte-identical |
| `clean-swarm-networks.sh` | :269, :283, :304, :416 | one-token change per call site |
| `clean-swarm-networks.sh` | parser | `--non-interactive` and eight gate flags |

`prompt_yes_no` is not edited. `rollback-docker.sh` is not touched in this slice; its single
prompt becomes a value flag in slice 6.

The `rerun-at-target` gate's "no" branch changes from `exit 0` to `exit 3` **only when
`--non-interactive` or `--preflight` is in effect**. Interactively it still exits 0.

**Gate prediction is split into two lists**, per the spec's table. Implement these branch
rules exactly:

- `rerun-at-target` — required when all five installed versions equal the expected ones. It is
  the **exception** to "refuse on an unanswered required gate": unanswered resolves to no,
  which does nothing, so preflight reports exit 3 rather than exit 1.
- `allow-unverified-baseline` — required on the unexpected-baseline branch only.
- `drain-self` — required when Swarm is active, `ControlAvailable` is true, and availability is
  `active` or `unknown`.
- `assume-drained` — required when Swarm is active and `ControlAvailable` is false. A worker's
  availability always reads `unknown`, so this gate always fires on a worker.
- `proceed-with-tasks` — conditional. Dropped entirely when `--no-drain-self` was given, and on
  a worker, where no drain runs.
- `reactivate` — conditional, but **promoted to required** when `--drain-self` was given or
  when preflight observes availability already `drain`; **dropped** when `--no-drain-self` was
  given, and dropped for availability `pause`, which phase 10 does not reactivate.

Predictor coverage, as Tier 2 cases: active manager with `--drain-self`, active manager with
`--no-drain-self`, active manager with neither, already-drained manager, paused manager,
worker, and non-Swarm host. Seven states, each asserting the two lists.

### Tests

**Static 1.14.1 — gate/flag parity, both directions.** Every name passed to `gate` has a
`--<name>` and `--no-<name>` case in that script's parser; every gate flag in the parser is
passed to a `gate` call; every gate name appears in the preflight predictor.

**Static 1.14.2 —** `cmp_fn gate upgrade-docker.sh clean-swarm-networks.sh`.

**Static 1.14.4 —** the EOF refusal string `stdin closed` is present in all three stateful
scripts.

**Static 1.14.6 — every `gate` call site is a condition.** Require every line matching
`(^|[^_[:alnum:]])gate ` outside the definition to also match `^\s*(if|if !|elif|elif !|while)\s`
or to be part of one. A bare `gate ...` under `set -e` returning 1 kills the script.

**Mutation tests:** delete one flag case from the parser → 1.14.1 fails. Change one character
in `clean-swarm-networks.sh`'s `gate` → 1.14.2 fails. Convert one `if ! gate ...` call site to
a bare `gate ...` → 1.14.6 fails. Restore each and confirm green.

Static checks cannot honestly prove `--non-interactive` avoids reading stdin — a grep for
`exit 1` in the `gate` body passes even if control also falls through. That is what 2.35 and
2.36 are for.

### Tier 2

The single-node VM becomes a **manager** with `docker swarm init`, which arms the drain,
task-count and reactivation gates. That makes a slice of Swarm behaviour testable in Tier 2
for the first time. It does **not** touch the Tier 3 multi-node gap and must not be described
as if it does. Leave the swarm with `docker swarm leave --force` and reset the baseline
afterwards.

| # | Case | Assertions |
|---|---|---|
| 2.34 | Unanswered gate fails closed | manager VM, `--non-interactive --status-file=...` with neither drain flag. exit 1, `result=refused`, `refusal_reason=gate-unanswered:drain-self`, `gates_unanswered` names it. **State:** `assert_untouched_strict "2.34" baseline <snapshot>`, **plus node availability still `active`** via `docker node inspect self` |
| 2.35 | `--non-interactive` never reads stdin | identical to 2.34 but with stdin attached to a `yes y` stream. **Assert `assert_untouched_strict "2.35" baseline <snapshot>` and availability still `active`.** A fall-through to `prompt_yes_no` gets answered by `yes y` and the upgrade proceeds, so only the state assertion catches it |
| 2.36 | Full non-interactive upgrade | `--non-interactive --status-file=... ` plus exactly the gate flags `--preflight` reported as required. exit 0, `result=completed`, all five packages at target, config sha unchanged, canary intact, `node_availability_before=active`, `node_availability_after=active`, `drain_performed=true`, `drain_attested_by=flag` |
| 2.37 | Non-interactive already-at-target | after 2.36, re-run with `--non-interactive --status-file=...` and no `--rerun-at-target`: exit **3**, `result=nothing-to-do`. **State:** package versions cannot detect this on their own — a forced same-version rerun ends at the same versions. Assert instead that **no new `/root/docker-backup-*` directory was created** and that the count of `=== Phase 4: Stop Services ===` lines in `/var/log/docker-upgrade.log` is unchanged. This is the clean form of the discrepancy in case 2.14's spec |
| 2.37a | Conditional gate is reported, not refused | manager VM, `--preflight --non-interactive --status-file=... --drain-self --reactivate` with no `--proceed-with-tasks`: exit 0, `result=ready`, `gates_conditional` names `proceed-with-tasks`, `gates_unanswered` names it, and preflight does **not** refuse. `--status-file` is mandatory here — without it the run is refused at parse time and tests nothing |
| 2.37b | `--non-interactive` without `--status-file` | refused at parse time: exit 1, message on stderr, no file written anywhere, `assert_untouched_strict "2.37b" target <snapshot>` |
| 2.38 | Interactive path unchanged | every pre-existing case, unmodified, with no new flags |

**Mutation M3** in `agent-mode-negative-control.sh`: build a mutant `gate()` whose unanswered
branch falls through to `prompt_yes_no` instead of exiting. Run 2.35's assertions against the
mutant and confirm they FAIL — the mutant drains and upgrades the node. This is the pair that
matters: per `CLAUDE.md`, a guard test asserting only the exit code proves nothing, because a
fall-through that upgrades the node and then fails for an unrelated reason also exits
non-zero. Leave the swarm and reset the baseline afterwards.

### Regression gate

`tier2-run.sh` 45/45, `config-version-check.sh` 30/30, `negative-control.sh` 3/3, all run
unmodified. Any change to those numbers means the interactive path moved.

### Version bump

Minor bump on `upgrade-docker.sh` and `clean-swarm-networks.sh`.

### Commit

`Add --non-interactive and per-gate attestation flags (vX.Y.Z)`

### Codex focus

- Can any flag combination reach a destructive action that the interactive path would have
  gated?
- Under `--non-interactive`, is `prompt_yes_no` reachable on **any** path?
- Does a pre-answered gate behave identically in both modes?
- Is `gate`'s return value safe at every call site under `set -e`?
- Does the `exit 3` change alter any interactive exit code?

---

## Slice 5 — `clean-swarm-networks.sh --dry-run` and `--expect-inventory-sha`

### Files and locations

| Anchor | Change |
|---|---|
| parser | `--dry-run`, `--expect-inventory-sha=SHA` |
| after the enumeration block (:336–:355) | build the canonical inventory string, hash it, assign `inventory_sha` |
| before the delete gate (:416) | sha comparison; on mismatch restart services and refuse |
| the delete gate's "no" branch (:417–:421) | `--dry-run` reaches this branch by flag instead of by prompt |
| parser | reject `--dry-run` alongside `--confirm-delete`, `--no-confirm-delete` or `--expect-inventory-sha` as `bad-usage` |

Canonical string per the spec: name and path list only, never file contents, sorted with
`LC_ALL=C`, LF-joined and LF-terminated, `sha256sum`, first field.

`--confirm-delete` **always requires** `--expect-inventory-sha`, in every mode, not only under
`--non-interactive`. A pre-declared answer wins in both modes, so the flag alone on an
otherwise interactive run would skip the post-enumeration confirmation with nobody having seen
the inventory. The only sha-free path to deletion is answering the live prompt after
enumeration. Missing sha is `inventory-sha-required`; a value that is not 64 lowercase hex
characters is `bad-usage`, rejected at parse time.

**`--dry-run` combined with a delete answer is a usage error, not a precedence puzzle.** A dry
run's definition is that it reaches the "no" branch; a pre-answered `--confirm-delete` on the
same command line is two contradictory instructions, and guessing which wins is how a dry run
deletes something. Reject the combination at parse time.

The canonicalisation and hashing pipeline must **fail closed**. The script runs `set -e`
without `pipefail`, so a failing `sort` upstream of a succeeding `sha256sum` produces a
confident hash of nothing. Run it in a subshell with `set -o pipefail`, or stage it and check
each status; a failure is `enumeration-failed`, never an empty inventory.

### Tests

**Static 1.14.9 — the inventory hash covers names, not contents.** Require the hashing block
to contain no `sha256sum "$KV_DB"` or equivalent read of a file's bytes. Mutation: change it
to hash the KV database's contents, confirm the check fails.

### Tier 2

**Fixture first, and it is not optional.** Slice 4 left the Swarm and reset the baseline, so
the VM is a non-Swarm host again. `clean-swarm-networks.sh` on a non-Swarm host refuses at the
`allow-non-swarm` gate, long before any of these cases reaches a stop or a deletion, so every
case below would pass for the wrong reason.

Before cases 2.39–2.42 and mutants M4a/M4b, build a node that actually has network state to
enumerate:

```
docker swarm init
docker network create -d overlay --attachable agentmode-test
docker run -d --name agentmode-canary --network agentmode-test <the baseline image> sleep infinity
```

That produces at least one VXLAN interface, at least one `/var/run/docker/netns` entry, a
populated `local-kv.db`, and `docker_gwbridge`. Assert the fixture is non-empty before running
any case; an empty inventory takes the "nothing to clean" early exit and proves nothing. Leave
the Swarm and reset the baseline afterwards.

Prefer this over passing `--allow-non-swarm`: this script exists for Swarm nodes, and testing
it on a host it warns against is testing the wrong thing.

| # | Case | Assertions |
|---|---|---|
| 2.39 | `--dry-run` deletes nothing | `--non-interactive --dry-run --assume-drained --confirm-stop --status-file=...`. exit 0, `deleted=false`, `inventory_sha` non-empty and 64 hex characters. **State:** every VXLAN interface still present, `/var/run/docker/netns` file count unchanged, the KV database still present with an unchanged inode, `docker_gwbridge` still present, docker and containerd both `active` |
| 2.40 | Wrong sha refuses, node intact | `--non-interactive --status-file=... --assume-drained --confirm-stop --confirm-delete --expect-inventory-sha=<64 zeros>`. exit 1, `result=refused`, `refusal_reason=inventory-changed`, `deleted=false`. **State:** identical to 2.39's state assertions — nothing deleted, services back `active` |
| 2.41 | Missing sha refuses | `--confirm-delete` with no sha, in **both** modes — the non-interactive form also passing `--status-file`, `--assume-drained` and `--confirm-stop`: exit 1, `refusal_reason=inventory-sha-required`. **Services were never stopped** — assert temporally, by comparing the count of `=== Phase 2: Stop Services ===` lines in `/var/log/docker-network-cleanup.log` before and after, since finding the services `active` afterwards would also hold after a stop, delete and restart. Plus every inventory object still present |
| 2.41a | Malformed sha is a usage error | `--expect-inventory-sha=nothex`: exit 1, `bad-usage`. Same assertions as 2.41 — the phase-2 log-line count unchanged, and every inventory object still present |
| 2.41b | `--dry-run --confirm-delete` is a usage error | exit 1, `bad-usage`, phase-2 log-line count unchanged, every inventory object still present |
| 2.42 | Matching sha proceeds | dry run, then real run with its sha and the same earlier gate flags plus `--status-file`: exit 0 or 2, `deleted=true`, the VXLAN interfaces and netns entries actually gone, the KV database gone, services back `active` |

**Mutation M4a:** neuter the sha comparison so it always matches. Run 2.40 against the mutant
and confirm it FAILS — the mutant deletes the inventory.

**Mutation M4b:** make `--confirm-delete` accepted without a sha. Run 2.41 against the mutant
**on the Swarm fixture, with every earlier gate answered and a status file supplied** —
`--non-interactive --status-file=... --assume-drained --confirm-stop --confirm-delete`. Without
the fixture the mutant refuses at the `allow-non-swarm` gate; without the earlier flags it
refuses at the first unanswered one. Either way it never reaches the stop or the delete and
reproduces no hazard. Confirm the mutant stops services and deletes the inventory, then leave
the Swarm and reset the baseline.

### Version bump

Minor bump on `clean-swarm-networks.sh`.

### Commit

`Add --dry-run and --expect-inventory-sha to clean-swarm-networks.sh (vX.Y.Z)`

### Codex focus

- Does the two-pass structure disturb "enumerate after the stop, delete exactly that list"
  **within** a single run?
- Is the canonical inventory string reproducible across runs given unordered `ip` and `find`
  output?
- On a sha mismatch, are services restored before the refusal?
- Does `--dry-run` reach the delete loop on any path?

---

## Slice 6 — `rollback-docker.sh --config-backup` and `--preflight`

### Files and locations

| Anchor | Change |
|---|---|
| parser | `--non-interactive`, `--preflight`, `--config-backup=newest\|none\|<dir>` |
| phase 0b (`# Phase 0b: Select the containerd Config Backup`, :435–:492) | resolve the flag instead of prompting; refuse an ambiguous unanswered selection under `--non-interactive` |
| phase 0c (:494 onward) | unchanged logic; it already judges the config phase 3 would actually load, which is what makes `--config-backup` feed it correctly |
| after phase 0c | preflight exit point: report, write status, exit 0/1 |

Phase 0c gains **no** override flag. `--config-backup=<dir>` can turn a refusal into `ready`
only by naming a backup the rollback containerd can actually load — which is a fact, not an
override.

`config_version_effective` reports what 0c judged, not merely what is on disk.

### Tests

**Static 1.14.10 — phase 0c has no override.** Grep the phase 0c block for `force`, `skip`,
`override`, `GATE_ANSWERS`. Zero matches. Mutation: add a `--force-config` escape, confirm the
check fails.

### Tier 2

| # | Case | Assertions |
|---|---|---|
| 2.43 | `--preflight` on a healthy node | with `--status-file`: exit 0, `result=ready`, `config_rollback_safe=true`. **State:** `assert_untouched_strict "2.43" target <snapshot>` |
| 2.44 | `--preflight` with a v4 config on disk, no usable backup | with `--status-file`: exit 1, `result=refused`, `refusal_reason=config-version-blocks-rollback`, `config_version_effective=4`. **State:** containerd.io **not** downgraded, both services `active`, canary intact, config file byte-identical. This is case 2.27 re-expressed as a preflight |
| 2.45 | `--config-backup` selects an older loadable backup | newest backup holds a v4 config, an older one holds v3. `--preflight --status-file=... --config-backup=<older>`: exit 0, `result=ready`, `config_backup_source=flag`, `config_backup_selected` names the older directory. **State:** `assert_untouched_strict "2.45" target <snapshot>` |
| 2.46 | `--config-backup=<missing>` | with `--status-file`: exit 1, `refusal_reason=config-backup-not-found`. **State:** `assert_untouched_strict "2.46" target <snapshot>` |
| 2.47 | Ambiguous selection refuses | two backups, `--non-interactive --status-file=...` with no `--config-backup`: exit 1, `refusal_reason=config-backup-ambiguous`, `config_backup_candidates` lists both. **State:** `assert_untouched_strict "2.47" target <snapshot>`, plus the count of `=== Phase 1: Stop Services ===` lines in `/var/log/docker-rollback.log` unchanged |
| 2.48 | Non-interactive rollback completes | `--non-interactive --status-file=... --config-backup=newest`: exit 0, packages back at baseline, both services `active`, canary intact. The status file is required by `--non-interactive`; slice 6 must enforce that rule in `rollback-docker.sh`'s parser too |

**Mutation M5:** make phase 0b ignore `--config-backup` and always take the newest. Run 2.45
against the mutant and confirm it FAILS — the mutant refuses a rollback that the flag makes
safe.

### Version bump

Minor bump on `rollback-docker.sh`.

### Commit

`Add rollback-docker.sh --preflight and --config-backup (vX.Y.Z)`

### Codex focus

- Can `--config-backup` cause phase 0c to judge a different file than phase 3 restores?
- Does `--config-backup=none` weaken the guard on any path?
- Is `--preflight` read-only in rollback, given that phase 0b previously only read state?
- Is `config_version_effective` computed from the selection or from the disk?

---

## Slice 7 — incidental fixes

Four items found by the analysis, each independently correct and none dependent on agent mode.

| Item | Change |
|---|---|
| `prompt_yes_no` drift check omits `rollback-docker.sh` | `tests/static-checks.sh:276` → `cmp_fn prompt_yes_no upgrade-docker.sh rollback-docker.sh clean-swarm-networks.sh`. The exclusion sits in exactly the script where a missing `prompt_yes_no` once caused a silent no-op rollback that reported success |
| `recover-dnf.sh` cannot be driven | add `--run-option-a` / `--no-run-option-a`, plus `--help` and `--version` for parity with the three stateful scripts; unanswered still skips and exits 0, matching today's EOF behaviour exactly |
| Case 2.14's spec is wrong | `docs/TEST-PLAN.md:149` says "exits 0 on no"; it exits 1 via the EOF refusal. Correct the prose, and point at slice 4's case 2.37 for the clean exit 3 |
| `recover-dnf.sh` EOF divergence undocumented | one paragraph in `AGENT-RUNBOOK.md`'s never-do list: it is the one script that fails open, in the safe direction |

The `id -u` root check is **not** here. It landed in slice 2, between the traps and the tee.

`download-docker-packages.sh` and `simulate-upgrade.sh` get **nothing**. Neither has a prompt,
neither runs on a production node, and neither is in agent mode's scope. Say so in the runbook
rather than leaving an agent to wonder.

### Tests

`tests/static-checks.sh` must go green with the widened `cmp_fn`. Confirm the three copies are
byte-identical today; if they are not, that is a finding, not a fix to paper over.

**Mutation test:** change one character in `rollback-docker.sh`'s `prompt_yes_no`, confirm the
widened check fails, restore.

### Tier 2

None new. `recover-dnf.sh` is a diagnostic and has no Tier 2 coverage today; do not invent
some for this slice.

### Version bump

Minor bump on `recover-dnf.sh`.

### Commit

`Widen the prompt_yes_no drift check and add recover-dnf.sh flags (vX.Y.Z)`

### Codex focus

- Are the three `prompt_yes_no` copies actually byte-identical?
- Does `--run-option-a` change `recover-dnf.sh`'s EOF behaviour in any way?

---

## Slice 8 — consolidation, documentation, and the full regression run

No new behaviour. This slice makes the repo's own documentation true.

### Files

| File | Change |
|---|---|
| `docs/TEST-PLAN.md` | Tier 2 cases 2.29–2.48 in the table; a paragraph on what the agent-mode negative control proves; the case-2.14 correction from slice 7 if not already in |
| `README.md` | an agent-mode section: the three mode flags, the status file, where the runbook is |
| `CLAUDE.md` | a section on the gate/flag contract, the status-file schema being a compatibility surface, and the rule that a new gate needs a flag, a predictor entry, a runbook row and a mutation-tested static check |
| `RUNBOOK.md` | a pointer to `AGENT-RUNBOOK.md`, so a human who finds an agent's status file knows what it is |
| `docs/AGENT-RUNBOOK.md` | final pass: complete flag tables, complete decision table, complete key reference |
| `tests/static-checks.sh` | 1.14.11 — every flag in every parser has a row in `AGENT-RUNBOOK.md`, and the reverse |

### Tests

**Mutation test for 1.14.11:** remove one flag's row from the runbook, confirm the check
fails; restore.

### Tier 2

The full run, in order, on a fresh baseline:

```
tests/vm/bootstrap-vm.sh
tests/vm/build-bundle.sh
tests/vm/tier2-run.sh                    # 45/45 pre-existing
tests/vm/config-version-check.sh         # 30/30
tests/vm/negative-control.sh             # 3/3
tests/vm/tier2-run.sh agent              # the new cases
tests/vm/agent-mode-negative-control.sh  # M1 through M5
```

Report the real numbers. If any mutant fails to reproduce its hazard, the corresponding test
proves nothing and the slice is not done.

### Version bump

None — no script changes.

### Commit

`Document agent mode across TEST-PLAN, README, CLAUDE.md and RUNBOOK`

### Codex focus

- Does `CLAUDE.md`'s new section state the contract completely enough that a future change
  cannot silently break an agent?
- Is anything in the documentation now claiming coverage the harness does not provide?

---

## Definition of done

- [ ] All eight slices committed, each with its own version bump and bullet-list body.
- [ ] `bash -n` clean on all six scripts.
- [ ] `shellcheck` clean on all six scripts; every suppression inline with a reason.
- [ ] `tests/static-checks.sh` passes, including the whole of new section 1.14.
- [ ] Every new static check has been mutation-tested: broken deliberately, observed to fail
      and exit non-zero, then restored.
- [ ] `tests/vm/tier2-run.sh` 45/45, `config-version-check.sh` 30/30,
      `negative-control.sh` 3/3, all run unmodified against the modified scripts.
- [ ] `tests/vm/tier2-run.sh agent` passes every new case.
- [ ] `tests/vm/agent-mode-negative-control.sh` passes: every mutant reproduces its hazard, so
      every guard test is proven capable of failing.
- [ ] Every guard test asserts state — package versions, service states, node availability,
      canary data — and not only an exit code.
- [ ] `docs/AGENT-RUNBOOK.md` contains no package version literals, enforced by 1.14.7.
- [ ] Every flag in every parser has a runbook row, enforced by 1.14.11.
- [ ] Every gate has a flag, a predictor entry and a runbook row, enforced by 1.14.1.
- [ ] Running every script with zero arguments is behaviourally identical to today.
- [ ] `prompt_yes_no` is byte-identical to its pre-change form in all three stateful scripts.
- [ ] No override flag exists for `rollback-docker.sh` phase 0c.
- [ ] `next_action` never emits `rollback`.
- [ ] `--non-interactive` is refused without `--status-file`.
- [ ] `--confirm-delete` is refused without `--expect-inventory-sha`, in every mode.
- [ ] Every status file ends with `status_complete=1`, and a partial write publishes nothing.
- [ ] A non-root invocation writes a status file; a usage error does not.
- [ ] Preflight distinguishes `gates_required` from `gates_conditional` and refuses only on
      the former, with `rerun-at-target` as the documented exception that exits 3.
- [ ] `--dry-run` combined with any delete answer is a usage error.
- [ ] The status writer publishes nothing when any single key fails to write, proven by M1b.
- [ ] `derive_result` is total, always returns 0, and cannot abort the trap.
- [ ] `clean-swarm-networks.sh` writes its status **after** the trap's service recovery, and
      records `recovery_attempted` and `recovery_succeeded`.
- [ ] Every declared global the parser or the trap reads is initialised before either runs,
      `declare -A GATE_ANSWERS` included.
- [ ] `assert_untouched` at `tier2-run.sh:43` is unmodified; new cases use
      `assert_untouched_strict <label> <baseline|target>` with the right profile.
- [ ] Every Tier 2 case that asserts a status key passes `--status-file`, and every case using
      the strict helper passes both a profile and a captured snapshot.
- [ ] The startup record is schema-valid, using `unknown` for every unobserved value.
- [ ] A failed startup write sets `REFUSAL_REASON=bad-usage` before exiting.
- [ ] Slice 5's cases run against a real single-node Swarm with a non-empty network inventory,
      asserted non-empty before any case runs.
- [ ] Codex has reviewed every slice diff, and each finding is either fixed or recorded with a
      reason for declining.
- [ ] Everything in this plan ships in **one release**, cut by the orchestrator **after slice
      8**, not by any individual slice. No slice tags or releases on its own. The release
      follows `docs/RELEASING.md`: the deliverable is the bundle, and a tag alone does not
      record which packages an operator installed.

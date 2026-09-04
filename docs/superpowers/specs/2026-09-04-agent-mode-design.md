# Agent Mode — Design

**Date:** 2026-09-04
**Status:** Approved for implementation
**Implementation plan:** `docs/superpowers/plans/2026-09-04-agent-mode-implementation.md`

## Context

Every operator script in this repo is written for a human at a terminal. `prompt_yes_no`
refuses EOF on purpose, exit 0 carries three different meanings in `upgrade-docker.sh`,
and the only machine-readable output is the absence of one. An LLM agent asked to upgrade
a node today has to read roughly 48k tokens of source and prose, then infer intent from
coloured English in a log.

That is not a documentation gap. It is an interface gap: the scripts have no way to be
*told* a fact, and no way to *report* one.

This design adds an agent-facing interface to the three stateful scripts without changing
the interactive one. It is a strict superset. With no new flags passed, every script
behaves as it does today.

The analysis behind this design measured the reading surface, inventoried every prompt,
and rejected the obvious answer (a blanket `--yes`). This document does not relitigate
that; it specifies what gets built.

## Goals

1. An agent can run the upgrade, the rollback and the network cleanup **without a TTY**,
   stating each fact it is accountable for as a separate flag.
2. An agent can determine, from a **machine-readable file** rather than from prose, what
   happened, what state the node is in, and what to do next.
3. An agent can find out **before touching the node** whether every check the scripts know how
   to make would pass, including the relocated-root check that today aborts after the point of
   no return and the config-version read that today only reports after it. That is a bounded
   promise: it does not predict rpm scriptlets, races, or whether a service will start.
4. An agent reads **one document**, not eleven.
5. Every safety gate the interactive path enforces is enforced at least as strictly on the
   agent path. Where the agent path cannot be as strong, it says so in the file.

## Non-goals

- Replacing the interactive path. It is the shipped, tested, documented path and stays the
  default.
- Orchestrating a fleet. These scripts run on one node; sequencing nodes is the caller's job.
- Making `clean-swarm-networks.sh` a routine step. It stays a remedy for one symptom.
- JSON. There is no guaranteed `jq` on an air-gapped RHEL host, hand-rolled JSON escaping in
  shell is a bug farm, and the harness already parses flat `key=value`.
- A `--force` for `rollback-docker.sh` phase 0c. There is no safe way to downgrade into a
  runtime that cannot start.

## Principles

**Every flag states one fact the caller is accountable for.** Not a preference, a fact.
`--assume-drained` asserts that a drain happened elsewhere; it does not perform one.

**An unstated fact fails closed.** Under `--non-interactive`, a gate with no answer is a
refusal that names the missing flag. It is never resolved by a default, and never by
reading stdin.

**With no flags, behaviour is exactly today's.** Behaviourally identical, not byte-identical:
one extra function frame per gate and a status writer that is a no-op without `--status-file`.

**The status file is authoritative; the exit code is a coarse summary.** Exit codes have to
stay compatible with what exists. The file does not.

---

## The `gate()` wrapper

`prompt_yes_no` is **not modified**. Its EOF refusal, its separately-passed default and its
byte-identity across scripts all stay exactly as they are. A new wrapper sits in front of it.

```bash
# Pre-declared answers to the gates below, populated by the argument parser.
# A gate with no entry is UNANSWERED. Under --non-interactive an unanswered
# gate is a refusal, never a default: a fact nobody stated is a fact nobody
# verified.
declare -A GATE_ANSWERS=()
NON_INTERACTIVE=false
GATES_SEEN=""

# Ask one gate. Returns 0 for yes and 1 for no, exactly like prompt_yes_no --
# and, exactly like prompt_yes_no, EVERY call site must sit in an if/if!
# condition. Under `set -e` a bare `gate ...` that returns 1 kills the script.
# The same suspension is what makes the nested prompt_yes_no call safe here.
gate() {
    local name="$1" prompt="$2" default="$3"
    local ans="${GATE_ANSWERS[$name]:-}"
    GATES_SEEN="${GATES_SEEN:+$GATES_SEEN,}$name"
    case "$ans" in
        y) echo "gate $name: yes (--$name)"; return 0 ;;
        n) echo "gate $name: no (--no-$name)"; return 1 ;;
    esac
    if [ "$NON_INTERACTIVE" != true ]; then
        # Explicit branches rather than a bare call plus `return`. Both forms
        # work, because `set -e` is suspended for the dynamic extent of a
        # function called in a condition -- but relying on that is relying on
        # a subtlety a later refactor can silently break.
        if prompt_yes_no "$prompt" "$default"; then return 0; else return 1; fi
    fi
    REFUSAL_REASON="gate-unanswered:$name"
    echo "" >&2
    echo "ERROR: --non-interactive was given and gate '$name' was not answered." >&2
    echo "  question: $prompt" >&2
    echo "  pass --$name or --no-$name" >&2
    exit 1
}
```

### Contract

- **A pre-declared answer wins in both modes.** `--drain-self` skips that prompt on an
  interactive run too. The flag states a fact; the mode only decides what happens to facts
  nobody stated.
- **Under `--non-interactive`, `prompt_yes_no` is never reached.** Not "reached and
  auto-answered" — never reached. A wrapper piping `/dev/null` or `yes y` still cannot
  answer anything, because there is nothing to answer.
- **`gate` returns 1 like `prompt_yes_no`.** Every call site is an `if` or `if !` condition,
  which is what makes returning 1 safe under `set -e`. Static check 1.14.6 enforces it.
- **`rollback-docker.sh` never gets `gate()`.** Its single prompt becomes a value flag,
  `--config-backup`, not a yes/no gate, so the wrapper would be dead code there. `gate()`
  lives in `upgrade-docker.sh` and `clean-swarm-networks.sh` only.
- **`gate` is byte-identical across the scripts that have it.** Static check 1.14.2 enforces it,
  the same way `verify_unit_stopped` is enforced today. It therefore may not reference
  anything script-specific; the only globals it touches are `GATE_ANSWERS`,
  `NON_INTERACTIVE`, `GATES_SEEN` and `REFUSAL_REASON`, all declared identically in both.
- **Call sites change by one token.** `prompt_yes_no "Drain this node now? [Y/n]" "y"`
  becomes `gate drain-self "Drain this node now? [Y/n]" "y"`. The prompt text and the
  default are unchanged, so the interactive transcript is unchanged.
- **`GATE_ANSWERS` needs bash 4.** RHEL 8 ships 4.4 and RHEL 9 ships 5.1, so the floor is
  met with room. Recorded here because it is the only new interpreter requirement.

### Flag table

Every gate takes `--<name>` for yes and `--no-<name>` for no. The "unanswered under
`--non-interactive`" column is what makes the mode fail closed.

#### `upgrade-docker.sh`

| Gate name | Replaces the prompt at | Fact asserted | Unanswered under `--non-interactive` |
|---|---|---|---|
| `rerun-at-target` | already fully at target | "run it again anyway" | answer **no**: exit **3**, `result=nothing-to-do`, node untouched |
| `allow-unverified-baseline` | unexpected starting version | "this starting version is acceptable" | refuse, exit 1, `refusal_reason=gate-unanswered:allow-unverified-baseline` |
| `drain-self` | manager drain offer | "drain this manager now" | refuse, exit 1 |
| `proceed-with-tasks` | tasks remain, or task count unknown | "upgrade with tasks possibly still here" | refuse, exit 1 |
| `assume-drained` | worker attestation | "a manager already drained this node" | refuse, exit 1 |
| `reactivate` | phase 10 reactivation | "return this manager to active" | refuse, exit 1 |

`rerun-at-target` is the one gate whose unanswered state resolves safely by implication,
because its "no" branch does nothing at all. A distinct exit code beats aborting.

`proceed-with-tasks` deliberately covers both task prompts. The distinction between "could
not count tasks" and "three tasks remain" is not lost: it survives in the status file as
`tasks_remaining=unknown` versus `tasks_remaining=3`.

#### `rollback-docker.sh`

| Flag | Replaces | Semantics |
|---|---|---|
| `--config-backup=newest` | the phase 0b prompt | answers "yes" — today's behaviour |
| `--config-backup=<dir>` | — | use that backup directory; refuse if it does not exist or holds no `config.toml` |
| `--config-backup=none` | — | keep the on-disk config, restore nothing |
| unanswered under `--non-interactive`, **and more than one backup exists** | — | refuse, exit 1, `refusal_reason=config-backup-ambiguous`, listing every candidate in `config_backup_candidates` |

With exactly one backup, or none, the prompt does not fire today and the flag is not
required. `--config-backup` beats a yes/no because naming a non-newest backup currently
requires aborting the rollback and copying a file by hand.

`--config-backup=none` is an addition beyond the source analysis. It makes the flag total
and cannot weaken anything: phase 0c still evaluates the config that would actually be
loaded, and refuses if it is one the rollback containerd cannot read.

#### `clean-swarm-networks.sh`

| Gate name | Replaces | Fact asserted | Unanswered under `--non-interactive` |
|---|---|---|---|
| `allow-non-swarm` | non-Swarm warning | "run this on a non-Swarm host anyway" | refuse, exit 1 |
| `assume-drained` | drain attestation | "a manager already drained this node" | refuse, exit 1 |
| `confirm-stop` | stop confirmation | "stop docker and containerd now" | refuse, exit 1 |
| `confirm-delete` | inventory confirmation | "delete the enumerated inventory" | refuse, exit 1 |

`--confirm-delete` **always requires `--expect-inventory-sha`**, in every mode. Without it,
refuse with `refusal_reason=inventory-sha-required`.

This is stricter than "required under `--non-interactive`", and deliberately so. A
pre-declared answer wins in both modes, so `--confirm-delete` alone on an otherwise
interactive run would skip the post-enumeration confirmation without anyone or anything ever
having seen the inventory. That is precisely the bypass this design exists to prevent. The
only way to delete without a sha is to answer the live prompt **after** enumeration, which is
what a human does today.

#### `recover-dnf.sh`

| Flag | Replaces | Unanswered |
|---|---|---|
| `--run-option-a` / `--no-run-option-a` | the bare `read` | skip Option A and exit 0 — matching today's EOF behaviour exactly |

`recover-dnf.sh` keeps its own EOF semantics. It is a diagnostic that fails open in the safe
direction, and this is the one place where "these scripts refuse EOF" is not true of all of
them. Documented rather than changed.

### Mode flags

| Flag | Scripts | Meaning |
|---|---|---|
| `--non-interactive` | upgrade, rollback, clean | strictness switch. Unanswered gates refuse instead of prompting. Enables the full exit-code taxonomy. **Requires `--status-file`.** |
| `--status-file=PATH` | upgrade, rollback, clean | write the run record to PATH on every exit path |
| `--preflight` | upgrade, rollback | run everything read-only, report, exit without touching the node |
| `--dry-run` | clean | stop, enumerate, print, restart, exit without deleting |
| `--expect-inventory-sha=SHA` | clean | refuse unless the enumerated inventory hashes to SHA |
| `--config-backup=...` | rollback | select the phase 0b backup |
| `--help` / `--version` | the three stateful scripts and `recover-dnf.sh` | usage or version, exit 0, no side effects |

`--non-interactive` is a **strictness** switch, not a consent switch. It grants nothing.

**`--non-interactive` requires `--status-file`.** Exit 1 conflates refusal with failure, and
130 and 143 say nothing about phase, service state or package state. This design calls the
file authoritative and then tells an exit-1 caller to read `refusal_reason` and `next_action`;
without the file those fields do not exist and the caller is back to grepping coloured prose.
Refuse the combination at parse time rather than shipping an interface that can be used
uselessly. Writability is proved by **performing the startup write for real** and requiring it
to succeed, so a run cannot reach phase 5 and only then discover it has nowhere to report.

`--help` and `--version` are implemented in the three stateful scripts and in
`recover-dnf.sh`. `download-docker-packages.sh` runs on the connected build host and
`simulate-upgrade.sh` is a smoke test; neither is invoked on a production node and neither is
in scope.

---

## Exit-code taxonomy

| Code | Meaning |
|---|---|
| 0 | the requested action completed |
| 1 | refused, or failed — read `refusal_reason` and `next_action` from the status file, if one was requested |
| 2 | completed with caveats |
| 3 | nothing to do |
| 130 / 143 | interrupted (INT / TERM), routed through the same trap |

### Coexistence with today's meanings

Codes 2 and 3 are emitted **only when `--non-interactive` or `--preflight` is in effect**.
Without them the scripts exit exactly as they do today: 0 for completion and for a declined
prompt, 1 for every refusal and failure. The caller passing a mode flag is the caller
declaring it understands the richer taxonomy.

One pre-existing exception is preserved unchanged: `clean-swarm-networks.sh` already exits 2
for "cleanup completed but incomplete", interactively, today. It keeps doing so.

`--preflight` always uses the full taxonomy, in both modes, because it is a new entry point
with no prior behaviour to preserve.

This asymmetry is deliberate and is why the status file, not the exit code, is authoritative.
`result` is always precise. The exit code is precise only when the caller asked for it.

---

## The status file

`--status-file=PATH`. Written twice: once at startup with `result=running`, and once from the
EXIT trap on **every** exit path — success, refusal, failure, INT and TERM. Both writes are
atomic and go via a direct redirect rather than through the script's tee'd stdout.

### Write mechanics

Nine properties are load-bearing and each has a specific failure mode if dropped.

1. **The write happens before the `rc -eq 0` short-circuit.** `on_exit` opens with
   `local rc=$?` and then `[ "$rc" -eq 0 ] && exit 0`. A status write placed after that line
   never runs on a successful upgrade — the single most common outcome an agent needs to
   confirm.
2. **The write is guarded with `|| true`.** A failing write inside a trap must not replace
   the real exit code with its own.
3. **The write bypasses the tee.** `exec > >(tee -a ...)` makes stdout a process
   substitution whose flush ordering at exit is not guaranteed. The writer redirects a brace
   group straight to a file, so it never travels through that pipe.
4. **The write is not re-entrant.** `gate` exits from inside the script, which fires the
   trap. A `STATUS_WRITTEN` flag makes a second entry a no-op. The flag is set by `on_exit`,
   not by the writer, so the startup write does not consume it.
5. **A partial file is never published, and the terminator alone does not prove that.**
   `write_status_file || true` puts the call in an OR list, which suspends `set -e` for the
   function's whole dynamic extent. So an early `status_kv` that fails on a full filesystem is
   followed by later ones that succeed — **including the terminator**. A last-line check by
   itself would pass on a file missing keys. Two mechanisms are therefore required together:
   `status_kv` sets `STATUS_OK=false` when its `printf` fails, the terminator is emitted only
   while `STATUS_OK` is still true, and the rename happens only when `STATUS_OK` is true *and*
   the temp file's last line is the terminator. On any failure the temp file is removed, the
   previous content is left in place, and the writer returns nonzero.
6. **The status machinery is defined and armed before the root check and before the tee.**
   The whole failure-handling block — the tracking globals, `on_exit`, and the three traps —
   moves to immediately after the argument parser. It only echoes, so it does not need the tee
   to exist yet. This is what lets a non-root refusal produce `result=refused`,
   `refusal_reason=not-root` rather than nothing. For any exit *after* the tee is installed the
   trap's output reaches the log as it does today; for the early exits — non-root, or a signal
   between arming the trap and installing the tee — it reaches the terminal only, and the
   status file says `log_started=false`.
7. **The startup write is the writability check, and it must succeed.** A sibling
   create-and-remove probe proves less than it looks: it does not exercise the rename, which
   is what a sticky directory or a root-owned existing target actually blocks. So when
   `--status-file` is given, the startup write is performed for real and **verified**; a
   failure is `bad-usage` and the script exits before anything mutates. This replaces a
   separate probe rather than supplementing it.
8. **Every run carries a `run_id` correlation ID.** A usage error happens before the startup
   write, so a caller reusing one path can read a *previous* run's file and believe it is
   current. `run_id` — `<epoch seconds>-<pid>-<4 random hex>` — lets a consumer tell. It is a
   correlation ID, not a guaranteed-unique key: epoch-plus-pid alone collides under pid reuse,
   which is why the random suffix is there, and even then uniqueness is overwhelming rather
   than certain. The runbook tells agents to use a fresh path per run, which is the real fix;
   `run_id` is the backstop for when they do not.
9. **The trap's writer call must not be able to abort the trap.** `derive_result` is a total
   function that always returns 0, and is called `|| true` regardless. If the trap exits early
   because a helper returned nonzero under `set -e`, 130 and 143 get replaced by the helper's
   status and no final record is written — on precisely the interrupted run an agent most
   needs to read.

```bash
STATUS_OK=true
status_kv() { printf '%s=%s\n' "$1" "${2//[$'\n\r']/ }" || STATUS_OK=false; }

write_status_file() {
    [ -n "$STATUS_FILE" ] || return 0
    local tmp last
    # mktemp beside the destination: same filesystem, so the rename is atomic,
    # and exclusive creation, so a stale ".tmp.$$" from a killed run with a
    # reused pid can never be examined and published.
    tmp=$(mktemp "${STATUS_FILE}.tmp.XXXXXX" 2>/dev/null) || return 1
    STATUS_OK=true
    {
        status_kv schema 1
        status_kv run_id "$RUN_ID"
        status_kv script "$SCRIPT_NAME"
        # ... one status_kv call per key ...
        [ "$STATUS_OK" = true ] && status_kv status_complete 1
    } > "$tmp" 2>/dev/null || STATUS_OK=false
    # BOTH conditions are required. The accumulator catches a mid-file write
    # failure; the terminator catches a redirect that died before the last key.
    # Either alone can be satisfied by a truncated file.
    if [ "$STATUS_OK" = true ] && last=$(tail -n 1 "$tmp" 2>/dev/null) \
       && [ "$last" = "status_complete=1" ]; then
        mv -f "$tmp" "$STATUS_FILE" 2>/dev/null && return 0
    fi
    rm -f "$tmp"
    return 1
}

on_exit() {
    local rc=$?
    if [ "$STATUS_WRITTEN" != true ]; then
        STATUS_WRITTEN=true
        derive_result "$rc" || true
        write_status_file || true
    fi
    [ "$rc" -eq 0 ] && exit 0
    # ... existing report, unchanged
}
```

At startup, immediately after the parser and before the root check:

```bash
RESULT="running"
if [ -n "$STATUS_FILE" ] && ! write_status_file; then
    # Set the refusal state BEFORE exiting. Without this the trap's retry can
    # succeed on a transient failure, derive_result sees a plain rc 1, and the
    # record says `failed` where the contract promises `bad-usage`.
    REFUSAL_REASON="bad-usage"
    REFUSAL_DETAIL="cannot write status file: $STATUS_FILE"
    NEXT_ACTION="none"
    echo "ERROR: cannot write status file: $STATUS_FILE" >&2
    exit 1
fi
```

### The startup record uses `unknown`

The startup write happens before almost anything has been observed, so most values are not yet
knowable. Rather than emitting empty strings that violate their own domains, **every key whose
value has not been observed is `unknown`**, `exit_code` and `ended` included. `unknown` is a
member of every key's domain for this reason. A consumer distinguishes a startup record from a
final one by `result=running`, and case 2.29g validates the two shapes separately.

### The completion marker

`derive_result`'s rc-2 row needs a name for "the operation reached its end". That is
`OPERATION_COMPLETED`, a boolean set to `true` at the script's completion banner — the same
point that prints `UPGRADE COMPLETE`, `ROLLBACK COMPLETE` or `NETWORK CLEANUP COMPLETE`. It
starts `false`.

### `derive_result` is total

It always returns 0. A nonzero return would abort the trap under `set -e`, replacing 130 or
143 with its own status and writing nothing.

| Condition, in this order | `result` |
|---|---|
| rc is 130 or 143 | `interrupted` |
| `REFUSAL_REASON` is non-empty | `refused` |
| rc is 3 | `nothing-to-do` |
| rc is 2 and the operation reached its completion marker | `completed` |
| rc is 0 and `RESULT` is already `ready` or `nothing-to-do` | unchanged |
| rc is 0 | `completed` |
| any other rc | `failed` |

`next_action` is derived after `result`, from the table further below.

### `clean-swarm-networks.sh` needs a different trap order

Its EXIT trap **restarts services** after a failure, unlike the other two, which deliberately
do not. Writing the status before that recovery would publish `services_stopped=true` and
`next_action=start-services` on a node whose services the trap then successfully brought back.

So its trap order is: save `rc` → attempt recovery → set `SERVICES_STOPPED=false` and record
whether recovery succeeded → derive → write → `exit "$rc"`. `upgrade-docker.sh` and
`rollback-docker.sh` keep write-before-report, because they have no recovery step to wait for.

Two extra keys carry the outcome: `recovery_attempted` and `recovery_succeeded`.

The temp file sits beside the target so the rename is atomic. One `status_kv` call per key
keeps every key name a greppable literal, which is what static check 1.14.5 compares against
the documented list.

### Format rules

- Flat `key=value`, one per line, LF-terminated, no quoting, no escaping.
- Values are single-line: CR and LF are replaced with a space by `status_kv`.
- Values carry no ANSI escapes. Nothing coloured is ever a value.
- Consumers split on the **first** `=`. Paths may not contain `=`; none of ours do.
- Keys are stable across script versions. Adding a key is a minor change; removing or
  repurposing one is not.
- **`unknown` is a member of every key's domain**, including `exit_code` and `ended`. It means
  "not observed at the time this record was written", which is the normal state of most keys in
  a startup record.
- The final line is always `status_complete=1`. A file lacking it is **incomplete**; treat it
  as unknown, not as its last readable `result`.
- `result=running` means **no complete final record was published**. Usually that is a
  SIGKILL, a power loss or an OOM kill, but it also covers a trap that fired and could not
  write. Either way the run started and did not report an outcome.
- A **missing status file means the run never started**: a usage error, or the script not
  being reached at all. A non-root invocation *does* write one, because the trap is armed
  before the root check. An agent must treat absence as "unknown", never as "nothing
  happened".
- **A usage error happens before the startup write**, so a caller reusing a path can find the
  *previous* run's file sitting there intact. Compare `run_id` before believing a file is
  current. Better, use a fresh path per run; the runbook says so.

### Common keys — all three scripts

| Key | Values |
|---|---|
| `schema` | `1` |
| `script` | script basename |
| `script_version` | the script's `VERSION` |
| `started` / `ended` | ISO 8601 UTC, e.g. `2026-09-04T11:20:03Z` |
| `host` | hostname |
| `rhel` | major version, or `unknown` |
| `mode` | `interactive` \| `non-interactive` \| `preflight` \| `dry-run` |
| `result` | `running` \| `ready` \| `completed` \| `nothing-to-do` \| `refused` \| `failed` \| `interrupted` |
| `exit_code` | integer |
| `phase` | the value of `CURRENT_PHASE` at exit |
| `refusal_reason` | token, or empty |
| `refusal_detail` | one line of free text for a human, or empty |
| `next_action` | token, see below |
| `log` | log file path |
| `log_started` | `true` \| `false` — false for exits before the tee is installed, whose output reached the terminal only |
| `run_id` | `<epoch seconds>-<pid>`, unique per invocation |
| `status_complete` | `1`, always the final line |
| `gates_required` | comma-separated gate names this run will certainly reach |
| `gates_conditional` | comma-separated gate names this run may reach, depending on what happens during it |
| `gates_answered` | comma-separated `name:y` / `name:n` |
| `gates_unanswered` | comma-separated gate names with no answer |

`result=ready` is preflight-only and means "the real run would proceed".

### `upgrade-docker.sh` keys

| Key | Values |
|---|---|
| `services_stopped` | `true` \| `false` |
| `pkg_state` | `untouched` \| `attempted` \| `installed` |
| `backup_dir` | path, or empty |
| `swarm_active` | `true` \| `false` |
| `swarm_role` | `manager` \| `worker` \| `none` |
| `swarm_node_id` | node ID, or empty |
| `node_availability_before` / `node_availability_after` | `active` \| `drain` \| `pause` \| `unknown` \| `n/a` |
| `drain_performed` | `true` \| `false` |
| `drain_attested_by` | `flag` \| `prompt` \| `not-required` |
| `tasks_remaining` | integer \| `unknown` \| `n/a` |
| `containerd_config` | path |
| `containerd_config_version` | integer \| `unset` \| `unreadable` |
| `containerd_config_rollback_safe` | `true` \| `false` \| `unknown` |
| `containerd_root` | path |
| `containerd_root_relocated` | `true` \| `false` |
| `containerd_root_present` | `true` \| `false` |
| `rpmnew_present` | `true` \| `false` |
| `nvidia` | `installed` \| `absent` \| `skipped-corrupt` \| `not-attempted` |
| `node_class` | `at-target` \| `partial` \| `baseline` \| `unverified` \| `unknown` — the installed-version classification, computed once and consumed by both the real branches and the gate predictor |
| `docker_ce_before` / `docker_ce_after` / `docker_ce_expected` | version, or `absent` |
| `containerd_io_before` / `_after` / `_expected` | version, or `absent` |
| `containerd_io_release_before` / `_after` / `_expected` | RPM `%{RELEASE}`, or `absent` |
| `buildx_before` / `_after` / `_expected` | version, or `absent` |
| `compose_before` / `_after` / `_expected` | version, or `absent` |

The `*_expected` keys exist so `docs/AGENT-RUNBOOK.md` can talk about the target versions
without naming them, which is what keeps it off the version-sync list in `CLAUDE.md`.

The `*_release_*` keys were added during implementation, after a retarget made the RPM
`%{RELEASE}` load-bearing: the same containerd `%{VERSION}` has been published more than once
carrying different `runc` builds, so the version alone no longer identifies what is installed.
A record that could not distinguish them would be exactly the ambiguity the release assertion
exists to remove. `_expected` is `unknown` until the RHEL major is detected, because the
constant is only the numeric half of the release string.

### `rollback-docker.sh` keys

`services_stopped`, `pkg_state`, plus:

| Key | Values |
|---|---|
| `config_backup_selected` | path, or `none` |
| `config_backup_source` | `flag` \| `newest` \| `prompt` \| `none` |
| `config_backup_candidates` | comma-separated paths |
| `config_version_on_disk` | integer \| `unset` \| `unreadable` \| `absent` |
| `config_version_effective` | the version of the config phase 3 would leave in place |
| `config_rollback_safe` | `true` \| `false` |
| `docker_ce_before` / `_after` / `_expected`, `containerd_io_before` / `_after` / `_expected` | version, or `absent` |

`config_version_effective` is what phase 0c actually judges: the backup's version when a
backup will be restored, the on-disk version otherwise. Reporting only the on-disk version
would tell an agent the opposite of what the guard decided.

### `clean-swarm-networks.sh` keys

`services_stopped`, plus:

| Key | Values |
|---|---|
| `inventory_sha` | sha256 of the canonical inventory, or empty |
| `inventory_sha_expected` | the value passed to `--expect-inventory-sha`, or empty |
| `inventory_total` | integer |
| `vxlan_count` / `netns_count` | integer |
| `kv_db_present` / `gwbridge_present` | `true` \| `false` |
| `docker_data_root` | path |
| `deleted` | `true` \| `false` |
| `failed_items` | integer |
| `recovery_attempted` | `true` \| `false` |
| `recovery_succeeded` | `true` \| `false` \| `n/a` |

### `refusal_reason` tokens

`not-root`, `bad-usage`, `payload-invalid`, `dry-run-failed`, `containerd-1x`,
`gate-unanswered:<name>`, `relocated-root-missing`, `config-version-blocks-rollback`,
`config-backup-ambiguous`, `config-backup-not-found`, `inventory-sha-required`,
`inventory-changed`, `enumeration-failed`, `stop-failed`.

`payload-invalid` covers every phase 0 payload rejection — digest, version, release, arch,
duplicates, missing package. The distinction does not change what the agent does (rebuild
the bundle), and `refusal_detail` carries the specifics for the human reading the log.

### `next_action` tokens

`none`, `proceed`, `start-services`, `investigate`, `supply-flag`, `fix-mount`,
`restore-config`, `rebuild-bundle`, `drain-from-manager`, `reactivate-from-manager`,
`rerun-as-root`, `rerun-dry-run`.

For a failed run, `next_action` is the token form of the decision `on_exit` already prints in
English today:

| `services_stopped` | `pkg_state` | `next_action` |
|---|---|---|
| true | untouched | `start-services` |
| true | attempted | `investigate` |
| true | installed | `investigate` |
| false | any | `investigate` |

**`next_action` never says `rollback`.** `CLAUDE.md` is explicit that the trap deliberately
does not auto-restart services because retry-versus-rollback is an operator judgement call
that depends on why it failed. Emitting a token that makes that call would contradict the
invariant the trap exists to honour. `investigate` is the honest answer, and `pkg_state`
plus `refusal_detail` carry what the decision needs.

---

## The preflight contract

`--preflight` runs everything checkable with the node untouched, writes a status file **if one
was requested**, and exits. It exists to convert "abort past the point of no return" into
"refuse on a healthy node".

A bare `--preflight` with no `--status-file` is the human interface: prose on the terminal and
an exit code. It is read-only and never prompts, so requiring a file would buy nothing.
`--preflight --non-interactive` is the agent interface and does require one, through the
`--non-interactive` rule.

### What runs

In `upgrade-docker.sh`, in order:

1. Root check, RHEL major detection, package directory existence.
2. **All of phase 0**: per-file digest verification, RPM metadata name/version/release/arch,
   the five expected versions, the `el${RHEL_VER}` release match, the duplicate check, and
   `rpm -Uvh --test` on the exact transaction.
3. The **containerd 1.x hard stop**, evaluated unconditionally, exactly where it is today.
4. The installed-version classification: already-at-target, partial, or unexpected baseline.
5. The **read-only part of phase 1**: Swarm state, role, node ID, and — on a manager —
   current availability.
6. `dnf check`, **without** the `dnf clean all` / `rpm --rebuilddb` repair that phase 2 runs.
7. Two checks **hoisted from phase 6**, as predictions:
   - the containerd config version read, and the rollback-safety implication;
   - the relocated-root existence check and its mount report.
8. NVIDIA presence detection, read-only.
9. Gate prediction: which gates the real run would reach, given what steps 4 and 5 observed.

### Read-only means read-only

Preflight must not: drain, stop or start any service, run `rpm -Uvh` without `--test`, run
`dnf clean all` or `rpm --rebuilddb`, create the backup directory, `mkdir` the containerd
root, write or regenerate any config, or delete anything.

`rpm -Uvh --test` is included and is genuinely read-only — it does not modify the rpmdb. It
is also exactly what phase 0 already runs before any mutation today, so preflight is not
doing anything new to the node.

Preflight **does** append to `/var/log/docker-upgrade.log`, through the existing tee, and
writes the status file when one was requested. Those are the only traces it leaves.

### Predicted versus enforced

Preflight **predicts**; the phases still **enforce**. Phase 6 keeps its own relocated-root
check and its own config-version read, unchanged, even though preflight now reports both.
A node can be repaired, or broken, between the two runs.

The relocated-root hoist is the highest-value item in this design. Today that check aborts at
phase 6 — after `rpm -Uvh` has run, with docker and containerd stopped, on a node whose data
filesystem is not mounted. Hoisted, the same pure filesystem read refuses on a fully healthy
node with every service up.

### Preflight and gates

**Preflight never calls `gate()` and never prompts.** It reports which gates the real run
would reach — and it splits them, because two of them cannot be predicted exactly.

| Gate | List | Condition preflight observes |
|---|---|---|
| `rerun-at-target` | **required**, with an exception | all five installed versions equal the expected ones |
| `allow-unverified-baseline` | required | not at target, not partial, and docker or containerd differs from the supported baseline |
| `drain-self` | required | Swarm active, `ControlAvailable` true, availability `active` or `unknown` |
| `assume-drained` | required | Swarm active, `ControlAvailable` false. A worker's availability always reads `unknown`, so this gate always fires |
| `proceed-with-tasks` | **conditional** | fires only after a drain that leaves tasks or cannot count them. Dropped entirely when `--no-drain-self` was given, and on a worker, where no drain runs |
| `reactivate` | **conditional**, promotable | fires only if the node ends up in `drain`. Promoted to required when `--drain-self` was given, or when preflight observes availability already `drain`. Dropped when `--no-drain-self` was given, and dropped for availability `pause`, which phase 10 does not reactivate |

**Correction recorded during slice 4.** The `reactivate` row above says `--no-drain-self`
drops the gate. That is true only where the drain gate is *reachable*. Phase 1 consults
`drain-self` only when availability is neither `drain` nor `pause`, so on a manager already in
`drain` the flag is never read and phase 10 still reaches `reactivate`. The implemented
predictor drops `reactivate` for `--no-drain-self` only when the drain gate is reachable, and
makes it required unconditionally for availability `drain`. The same review also found that
phase 1's availability test failed open on an empty or unrecognised value; it now skips the
drain only for a conclusive `drain` or `pause`.

**The `rerun-at-target` exception.** The general rule is that preflight refuses on an
unanswered required gate. This one does not: its unanswered state resolves safely by
implication to "no", which does nothing at all, so preflight reports exit 3,
`result=nothing-to-do` rather than exit 1. It is listed as required because the run certainly
reaches it, not because leaving it unanswered is an error.

- Without `--non-interactive`: both lists are informational. Preflight exits 0
  (`result=ready`), 1 (`result=refused`) or 3 (`result=nothing-to-do`) on the non-gate
  findings alone.
- With `--non-interactive`: preflight refuses on any unanswered gate in `gates_required` —
  exit 1, `refusal_reason=gate-unanswered:<first>`, `gates_unanswered` listing all of them.
  An unanswered gate in `gates_conditional` is **reported, not refused**, because the run may
  never reach it and refusing would force the caller to pre-answer a question that may not be
  asked.

The claim this supports is therefore bounded: preflight validates every gate that is certain
and names the ones that are not. It does not guarantee that a run passing preflight will
never stop on a gate. The real run still fails closed if it reaches a conditional gate with no
answer — the safe outcome, on a node that has been drained but not yet upgraded.

Gate prediction re-derives which gates a run reaches, so it is a drift hazard. Mitigation:
the classification the real branches switch on is computed once into named variables, and
both the branches and the predictor consume those variables. Static check 1.14.1 additionally
requires every name passed to `gate` to appear in the predictor, in one list or the other.

### `rollback-docker.sh --preflight`

Runs phases 0, 0b and 0c, then exits. It answers "would a rollback strand this node?" for
free, while everything is still running — which is precisely when an operator wants to know
and precisely when today's answer costs a stopped node.

Phase 0b under preflight resolves `--config-backup` and reports the selection without
prompting, exactly as above. Phase 0c then judges the **selected** backup, so
`--config-backup=<older v3 backup>` can turn a refusal into `result=ready`.

---

## The `clean-swarm-networks.sh` dry-run and inventory-sha protocol

### Why two passes are needed

The inventory is enumerated **after** services stop, deliberately, so the confirmation
describes exactly what gets deleted. An agent therefore cannot be told the inventory in
advance — nobody knows it until the node is already down.

`--dry-run` stops, enumerates, prints, restarts, and exits 0 without deleting. The
restart-on-decline path already exists as the "no" branch of the delete prompt, so the dry
run is that branch reached by a flag instead of a prompt.

### The weakening, stated plainly

Services restart between the two passes. dockerd recreates netns files and VXLAN interfaces.
The second run therefore deletes what **it** enumerated, not what the first run printed.

`--expect-inventory-sha` addresses this. The dry run prints the sha of its captured
inventory; the real run hashes its own, compares, and refuses on mismatch — restarting
services first, so a refusal leaves the node up.

**What the sha does and does not prove.** It proves the *set of names and paths* is unchanged
between the two passes. It does not prove object identity: a netns file with the same name
after a daemon restart is a different namespace, and it says nothing about contents. The
load-bearing invariant — enumerate after the stop, delete exactly that captured list — is
**untouched** by this design and still holds within each run, because deletion iterates the
captured arrays and never re-globs.

So the sha closes the **name-list portion** of the gap the two-pass structure opens, and only
that portion. It is not equivalent to a human reading the list immediately before answering.
Saying otherwise would be worse than not having it at all.

### Canonical inventory string

Hashed input is the **path and name list**, never file contents. The KV database's bytes
change on every dockerd run, so hashing them would guarantee a mismatch.

```
vxlan\t<interface name>     for each, sorted
netns\t<absolute path>      for each, sorted
kv\t<absolute path>         only when present
gwbridge                    only when present
```

Sorted with `LC_ALL=C`, joined with LF, LF-terminated, piped to `sha256sum`, first field
taken. `ip` and `find` do not guarantee output order, so the sort is required for the hash to
be reproducible at all.

**The hashing pipeline must fail closed.** `clean-swarm-networks.sh` runs `set -e` without
`pipefail`, so a failing `sort` upstream of a succeeding `sha256sum` yields a confident hash
of nothing. Run the canonicalisation in a subshell with `set -o pipefail`, or stage it and
check each status. An enumeration or hashing failure is `refusal_reason=enumeration-failed`
and never an empty inventory — the same rule the existing enumeration already follows.

`--expect-inventory-sha` is validated at parse time as exactly 64 lowercase hex characters.
A malformed value is `bad-usage`, not a mismatch.

### Fail-closed rules

`--confirm-delete` without `--expect-inventory-sha` is refused in **every mode**
(`inventory-sha-required`), for the reason given in the flag table: a pre-declared answer wins
in both modes, so the flag alone would skip the post-enumeration confirmation with nothing
having seen the inventory. The only sha-free path to deletion is answering the live prompt
after enumeration, which is what a human does today.

`--dry-run` combined with `--confirm-delete`, `--no-confirm-delete` or
`--expect-inventory-sha` is `bad-usage`. A dry run's whole definition is that it reaches the
"no" branch; a pre-answered yes on the same command line is two contradictory instructions,
and guessing which wins is how a "dry run" deletes something.

On mismatch: restart services, `deleted=false`, `refusal_reason=inventory-changed`, exit 1,
`next_action=rerun-dry-run`, and both shas reported in `refusal_detail`.

### Freshness is documented, not enforced

Nothing stops a caller passing a sha from a dry run an hour old. If the name list happens to
match, the run proceeds. It still cannot delete a name that was not enumerated in this run —
the captured-list invariant holds regardless — but it can delete newly recreated objects
bearing old names, which is the identity gap already stated above.

A one-time token was considered and rejected: validating a nonce requires the real run to read
state the dry run persisted, and that stored token becomes its own stale artifact on a node
nobody can reach. Instead the runbook states that a sha must come from the **immediately
preceding** dry run, and the status file records the dry run's `ended` timestamp alongside
`inventory_sha` so an audit can see how large the gap was.

---

## The worker drain

Workers cannot drain or inspect themselves. Only managers can run `docker node` commands. No
flag changes that, and none pretends to.

The design moves the work to where the authority already is:

1. The orchestrating agent has manager access, because it is upgrading a fleet.
   `AGENT-RUNBOOK.md` gives it the drain command and the `docker node ps <node>` emptiness
   poll, to run **on a manager, before** invoking anything on the node.
2. `--assume-drained` then states what the orchestrator already did. That is what an
   attestation should be: a report of completed work, not a guess.
3. The status file records `drain_attested_by=flag`, so an audit afterwards can tell that a
   flag was trusted rather than a check performed. The flag does not make the fact true, and
   the record says which it was.

A richer `--drain-verified-from=<manager>` provenance field is possible and is deliberately
left out as gold-plating until someone asks for the audit trail.

---

## What must never change

1. **`prompt_yes_no` stays byte-identical**, EOF refusal included. `--non-interactive`
   bypasses the read rather than relaxing it, so a wrapper piping `/dev/null` still cannot
   auto-answer anything.
2. **Phase 0 still runs before any mutation**, including before the Swarm drain. Preflight is
   an additional entry point, not a replacement, and not a way to skip phase 0 later.
3. **`verify_unit_stopped` and the fail-closed stop check are untouched.** No flag skips
   them. No flag makes a nonzero `systemctl` read as "stopped".
4. **The service stop and start order is untouched**, as is the `ctr version` plus
   `ctr snapshots` readiness poll. No flag substitutes a sleep.
5. **Phase 0c stays a refusal, with no override flag.** There is no safe force for
   "downgrade into a runtime that cannot start".
6. **Phase 6's own relocated-root check stays**, even though preflight now predicts it.
7. **Nothing in the upgrade path may write a v4 containerd config.** Phase 6's no-config
   branch keeps its loud warning; nothing new generates a config.
8. **One rpm transaction**, resolved together, with `--force` on upgrade and `--replacepkgs`
   on rollback. No flag splits it.
9. **`rpm -Uvh --test` always runs.** There is no `--skip-dry-run`.
10. **The `containerd.io` package name.** Never `containerd`.
11. **`PKG_STATE` is set to `attempted` before the rpm call**, not after.
12. **INT and TERM still route through the EXIT trap** as 130 and 143, now also writing the
    status file.
13. **The interactive transcript is unchanged.** Same prompt strings, same defaults, same
    order.

---

## The interactive-path regression gate

Do not hand-verify that the interactive path is unchanged. Run the existing harness,
unmodified, against the modified scripts, and require the pre-existing assertion counts:

| Harness | Required |
|---|---|
| `tests/vm/tier2-run.sh` | 45 / 45 |
| `tests/vm/config-version-check.sh` | 30 / 30 |
| `tests/vm/negative-control.sh` | 3 / 3 |

Those numbers are the count of **pre-existing** assertions. New agent-mode cases are added in
a separate harness phase (`tier2-run.sh agent`) so the existing sequence, and therefore the
existing count, is not disturbed. A slice that changes an existing assertion has changed the
interactive path and needs to justify it in its commit message.

That harness is already the regression test. It exercises both prompt behaviours: the
rejection and upgrade cases run with stdin closed, and the rollback case runs with a real
`yes y` stream.

Note that case 2.14's spec in `docs/TEST-PLAN.md` says the idempotent re-run "exits 0 on no".
It actually exits 1, because the run has stdin closed and hits the EOF refusal; the test only
greps for a string and never checks the status, so it passes. Case 2.14 is **left alone** to
preserve the 45. The discrepancy is fixed in the test plan's prose and superseded by a new
case asserting a clean exit 3 under `--non-interactive`.

---

## Risks

**1. Argument parsing must be inert with zero arguments.** It is the only new code on the
default path. Mitigation: parse into variables only, no side effects, and a Tier 2 case that
runs every script with no arguments at all.

**2. `gate` returning 1 under `set -e`.** Safe only because every call site is a condition,
exactly like `prompt_yes_no` and like `config_is_loadable`, which already carries this warning
in `rollback-docker.sh`. The same comment goes on `gate`, and static check 1.14.6 enforces the
call-site shape.

**3. Status-write ordering.** The write must precede `on_exit`'s `rc -eq 0` short-circuit and
be `|| true`-guarded, or a successful run writes nothing and a failing write masks the real
exit code. Mutation-tested: move the write after the short-circuit and confirm the
"status file exists after a successful run" assertion fails.

**4. The status file must bypass the tee.** Flush ordering of the process substitution at exit
is not guaranteed, so a status file written through it can be truncated. Mitigation: a brace
group redirected straight to a temp file, then `mv`.

**5. Trap re-entrancy.** `gate` exits from inside the script, which fires the EXIT trap, which
writes the status file. If that write itself exits, the trap re-enters. Mitigation: the
`STATUS_WRITTEN` flag, and no `exit` anywhere inside `write_status_file`.

**6. Gate-prediction drift.** The preflight predictor re-derives which gates a run reaches. If
a gate is added and the predictor is not updated, preflight reports a clean bill and the real
run refuses. Mitigation: shared classification variables plus static check 1.14.1.

**7. Ordering of the parser, the trap, the root check and the tee.** The required order is
parser → failure-handling block and traps → startup status write → root check → tee → banner.
The parser must precede the tee because `--help` must not require write access to `/var/log`.
The traps must precede the root check so a non-root refusal is reported rather than silent.
The root check must precede the tee because a non-root run currently dies *inside* that
redirect with an opaque error. Only a **usage error** writes no status file, because at that
point the path is not known to be valid.

**8. A partial status file published as authoritative.** The `|| true` at the call site
suspends `set -e` inside the writer, so a mid-write failure does not stop the remaining writes
or the rename — the terminator included. Mitigated by **both** the `STATUS_OK` accumulator and
the terminator's last-line check, since either alone can be satisfied by a truncated file, plus
`mktemp` for exclusive temp creation and a captured `tail` status. Mutation-tested by removing
the accumulator, making one `status_kv` write to a closed descriptor, and confirming the
published file carries the terminator while missing that key.

**9. Conditional gates cannot be pre-validated.** `proceed-with-tasks` and `reactivate` depend
on what the run does, not on what preflight can see. A caller that pre-answers neither and
passes preflight can still be refused mid-run — after the drain. This is safe (the node is
drained but not upgraded, and the status file says so) but it is not the "validate everything
up front" story, and the runbook must not tell agents it is. Mitigation: the two-list split,
and a runbook instruction to pass `--proceed-with-tasks` or `--no-proceed-with-tasks`
explicitly on any Swarm manager.

---

## `docs/AGENT-RUNBOOK.md` — outline

One document, around 200 lines, the only thing an agent operating a node reads. **It contains
no package version literals**, so it does not join the version-sync list in `CLAUDE.md`; it
refers to versions as the `*_expected` and `*_after` values in the status file. Static check
1.14.7 enforces that.

1. **Scope and the standing rule.** Who this is for. Preflight first, gate on its result,
   never pass a flag for a fact you have not verified.
2. **Preconditions.** Root. Bundle extracted after `rm -rf /opt/docker-offline` — the clean
   extraction is not optional, because the previous bundle has an identical layout and its
   leftovers surface as a duplicate rejection. Run from the extracted directory.
3. **The upgrade sequence**, with placeholders: preflight → read status → drain from a
   manager if the node is a worker → run with the flags preflight said were required → read
   status → verify → reactivate from a manager if the node is a worker.
4. **Flag reference**, one compact table per script.
5. **The decision table**, keyed on `result` × `refusal_reason` × `next_action`.
6. **Status-file key reference**, the same list as this spec.
7. **Three things needing out-of-band action**: draining a worker from a manager,
   reactivating a worker from a manager, and mounting a missing relocated containerd root.
   Plus the standing instruction to answer `gates_conditional` explicitly on any Swarm
   manager, because preflight cannot decide those two for the caller.
8. **The never-do list**: redirecting `containerd config default` into the config file;
   running `recover-dnf.sh` Option A on a production air-gapped host, because its printed
   commands reference an `--enablerepo=docker-local` repo that only exists on machines that
   ran the simulation path; running `clean-swarm-networks.sh` as a routine step rather than
   as a remedy for `failed adding service binding`; passing `--assume-drained` without having
   drained; passing `--rerun-at-target` to make an exit 3 go away.
9. **When the table does not cover it**: `RUNBOOK.md` for the human procedure, the log path,
   and the instruction to stop and report rather than improvise.

### Decision table

| `result` | `refusal_reason` | `next_action` | The agent does |
|---|---|---|---|
| _file absent_ | — | — | the run never started; fix the invocation and retry |
| _last line is not `status_complete=1`_ | — | — | incomplete file; treat as unknown |
| `running` | — | — | no complete final record was published — a kill, a power loss, or a trap that fired and could not write. Inspect the node before rerunning |
| `ready` | — | `proceed` | run the real upgrade, answering every gate in `gates_required` and every gate in `gates_conditional` that applies |
| `completed` | — | `none` | verify, then reactivate if this is a worker |
| `nothing-to-do` | — | `none` | move to the next node |
| `refused` | `not-root` | `rerun-as-root` | re-invoke as root |
| `refused` | `bad-usage` | — | fix the invocation. **No status file is written for a usage error**, so any file at that path is from an earlier run — check `run_id` before reading it |
| `refused` | `payload-invalid` | `rebuild-bundle` | stop the rollout; the bundle is wrong on this node |
| `refused` | `dry-run-failed` | `investigate` | stop; report `refusal_detail` |
| `refused` | `containerd-1x` | `investigate` | stop; this node needs the major-boundary script |
| `refused` | `gate-unanswered:<name>` | `supply-flag` | verify the fact, then supply the flag — never supply it to clear the error |
| `refused` | `relocated-root-missing` | `fix-mount` | mount the filesystem, then preflight again |
| `refused` | `config-version-blocks-rollback` | `restore-config` | restore the named backup, then preflight again |
| `refused` | `config-backup-ambiguous` | `supply-flag` | choose from `config_backup_candidates` |
| `refused` | `inventory-sha-required` | `rerun-dry-run` | dry run first, then pass its sha |
| `refused` | `inventory-changed` | `rerun-dry-run` | the node changed between passes; dry run again |
| `failed` / `interrupted` | — | `start-services` | packages untouched, services down: start containerd then docker |
| `failed` / `interrupted` | — | `investigate` | report `pkg_state`, `phase` and the log; do not guess between retry and rollback |

---

## Appendix A — Codex review

Three rounds against `CLAUDE.md`'s invariants, in one thread, `sandbox read-only`, cwd this
worktree. Every finding was accepted; the substantive ones are recorded here because the
reasoning is the design.

### Round 1

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | blocker | `--confirm-delete` bypasses the informed-deletion gate. A pre-declared answer wins in both modes, and the sha was required only under `--non-interactive`, so `--confirm-delete` alone skipped the post-enumeration confirmation with nothing having seen the inventory | Accepted. The sha is now required in **every** mode. The only sha-free path to deletion is answering the live prompt after enumeration |
| 2 | blocker | `--non-interactive` without `--status-file` loses what the caller needs; exit 1 conflates refusal with failure and the design then tells the caller to read fields that do not exist | Accepted. `--non-interactive` requires `--status-file`, refused at parse time |
| 3 | blocker | The writer can publish a partial file. `\|\| true` at the call site suspends `set -e` for the writer's whole dynamic extent, so an early failed write is followed by successful later ones and the rename | Accepted. See rounds 2 and 3 for the mechanism that actually closes it |
| 4 | should-fix | "The sha closes the gap" overclaims; and the hashing pipeline can hide a failure because the script has no `pipefail` | Accepted. Reworded to the name-list portion; a fail-closed pipeline is now required |
| 5 | blocker | Preflight cannot predict `proceed-with-tasks` or `reactivate` — both depend on what the run does. The "validate the complete flag set in one attempt" claim was false | Accepted. Split into `gates_required` and `gates_conditional`; the claim is now bounded |
| 6 | should-fix | Several Tier 2 cases asserted exit codes where `CLAUDE.md` requires state; `assert_untouched` covers only `docker-ce` and the docker service | Accepted. New strict helpers; `assert_untouched` left unmodified to preserve the 45-assertion gate |
| 7 | should-fix | Slice 3 referenced a gate predictor that slice 4 introduces | Accepted. Slice 3 is non-gate preflight only and must not emit gate keys |
| 8 | nit | `gate()`'s bare `prompt_yes_no` plus `return` relies on subtle dynamic-errexit behaviour | Accepted. Explicit `if/then/else` |
| 9 | should-fix | The root/status contract contradicted itself, and a reused path can hold a stale file | Accepted. Traps armed before the root check; startup `result=running` write; `run_id` |
| 10 | nit | `--help`/`--version` promised for "all five" scripts but planned for three | Accepted. Scope narrowed to four and stated |

### Round 2

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | blocker | The `status_complete=1` terminator does not prove the preceding writes landed — a mid-file failure is followed by a successful terminator | Accepted. A `STATUS_OK` accumulator plus the terminator, **both** required before the rename |
| 2 | blocker | `mktemp` was not used, and `tail`'s status was discarded; a stale `.tmp.$$` under pid reuse could be examined and published | Accepted. `mktemp` beside the destination, `tail`'s status captured in the condition |
| 3 | blocker | A sibling create-and-remove probe never exercises the rename, which is what a sticky directory or a root-owned target blocks | Accepted. The startup write **is** the check, performed for real and required to succeed |
| 4 | blocker | `derive_result` was undefined and could abort the trap under `set -e`, replacing 130/143 and writing nothing | Accepted. Specified as total, always returning 0, with an ordered mapping table |
| 5 | blocker | `clean-swarm-networks.sh`'s trap **restarts services**, so writing status before it would publish `next_action=start-services` for a node the trap then recovered | Accepted. That script gets its own trap order and two recovery keys |
| 6 | blocker | Assigning `GATE_ANSWERS[x]` before `declare -A` creates an indexed array that cannot be converted | Accepted. All parser-owned globals initialised first |
| 7 | should-fix | Pre-tee exits reach the terminal, not the log; the claim otherwise was false | Accepted. Added `log_started` |
| 8 | blocker | Gate prediction incomplete: the `rerun-at-target` exception, worker behaviour, and the already-drained and paused manager cases | Accepted. Full branch rules, plus seven predictor states as test cases |
| 9 | should-fix | `--dry-run` combined with `--confirm-delete` was undefined | Accepted. Rejected as `bad-usage`. Sha freshness is documented, not enforced; a one-time token was rejected in writing because validating a nonce needs persistent state that becomes its own stale artifact |
| 10 | blocker | Six specific tests could not work as written | Accepted individually |
| 11 | should-fix | Bare `--preflight` without a status file was described inconsistently | Accepted. "Writes a status file when requested"; bare preflight is the human interface |
| 12 | should-fix | Six residual internal inconsistencies | Accepted individually |

### Round 3

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | blocker | The startup record emits keys whose values are not yet knowable, violating their own domains | Accepted. `unknown` is a member of every domain and is what the startup record uses |
| 2 | blocker | A `baseline`/`target` profile cannot express "unchanged" — backup counts vary and case 2.47 deliberately creates two | Accepted. Snapshot helpers capture state immediately before the invocation; the profile covers package versions only |
| 3 | blocker | Slice 5's cases run after slice 4 left the Swarm, so every one would refuse at the `allow-non-swarm` gate and pass for the wrong reason | Accepted. Slice 5 builds a real single-node Swarm with an attached overlay network, and asserts the inventory is non-empty before any case runs |
| 4 | should-fix | Several status-asserting cases still omitted `--status-file` or the helper's arguments | Accepted. Complete invocations in every row |
| 5 | should-fix | A failed startup write exited without setting `REFUSAL_REASON`, so a successful trap retry would record `failed` where the contract promises `bad-usage`. The rc-2 completion marker was unnamed | Accepted. Both fixed; the marker is `OPERATION_COMPLETED` |
| 6 | should-fix | M1b's failure injection must be internal to `status_kv`, or the function never runs and the logic under test is never exercised | Accepted |
| 7 | should-fix | Seven pieces of stale prose contradicted the corrected writer | Accepted individually |
| 8 | nit | `run_id` is a correlation ID, not a unique key; and goal 3 miscounted the hoisted checks | Accepted. Random suffix added and the claim bounded |

### Standing answers

- **No flag combination bypasses a safety gate the interactive path enforces.** Confirmed
  gate by gate across all three rounds: the containerd 1.x hard stop, phase 0 validation,
  `rpm -Uvh --test`, `verify_unit_stopped`, phase 6's relocated-root check, rollback phase 0c,
  and the cleanup inventory confirmation. A caller can still skip preflight and meet the
  relocated-root guard after the rpm transaction — which is today's enforcement, unchanged,
  not a new bypass.
- **The captured-list invariant survives.** The destructive run still enumerates after the
  stop and deletes exactly those arrays, never re-globbing. A stale sha cannot authorise a
  name that was not enumerated in that run.
- **The writer is correct under `set -e`** with the `|| true` call site, across the `mktemp`,
  redirect-open, `tail` and rename failure paths.

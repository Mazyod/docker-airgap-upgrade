# AGENTS.md

**Two audiences, two documents. Pick one and read only that one.**

| You are | Read |
|---|---|
| **Changing these scripts** | **[CLAUDE.md](CLAUDE.md)** — the invariants, the phase structure, the version-sync list, the agent-mode contract, the release practice |
| **Operating a node** — running an upgrade, a rollback or the network cleanup on a real host | **[docs/AGENT-RUNBOOK.md](docs/AGENT-RUNBOOK.md)** — its first five sections are the whole **upgrade** procedure: the standing rule, the commands, the decision table, the never-do list. The rollback and the cleanup are remedies and have their own Reference sections |

They barely overlap. `CLAUDE.md` is over 40 KB about editing scripts and says almost nothing
about running them; the runbook says nothing about editing. Reading the wrong one costs a
lot of context and answers the wrong question.

The rest of this file is for the first audience.

---

These are **standalone Bash scripts** that run as root on air-gapped RHEL 8/9 hosts. There
is no build system, no package manager and no application code. Read
[CLAUDE.md](CLAUDE.md) in full before changing anything: it is the single source of truth
for the invariants, the two incompatible install strategies, the containerd config-version
asymmetry the rollback guard exists for, the version constants duplicated across several
files, and the agent-mode flag and status-file contract.

```bash
bash -n <script>.sh          # syntax check — works anywhere
shellcheck <script>.sh       # all scripts are shellcheck clean; keep them that way
tests/static-checks.sh       # Tier 1: reads source text, executes no upgrade logic
```

Tier 2 (real execution against a real systemd node) lives in `tests/vm/` and runs on either
macOS with OrbStack or Linux with a local, rootful, x86_64 Docker daemon — see
`tests/vm/README.md`.

## House rules

- Suppress a shellcheck warning only with an inline `# shellcheck disable=SCxxxx` plus a
  reason. Never a blanket ignore.
- Bump the `VERSION="x.y.z"` constant near the top of any script you change, and echo it in
  that script's banner. Versions across scripts drift on purpose.
- Commit subjects carry the new version in parens, with a bullet-list body.
- Any new harness check is mutation-tested in the same commit: break the thing deliberately,
  confirm the check fails and exits non-zero, restore.
- A new prompt goes through `gate()`, with a flag for each answer, a `predict_gates` entry
  and a runbook row. `tests/static-checks.sh` section 1.14 enforces all three.
- Keep this project **generic**. It is vendor-neutral open source: no company names, no
  internal hostnames or domains, no cluster specifics, no engagement details. Use
  `example.com` and reserved ranges in fixtures.

# AGENTS.md

This repository's working instructions live in **[CLAUDE.md](CLAUDE.md)** — read it in
full before changing anything. It is agent-agnostic despite the filename, and it is the
single source of truth for:

- what the six scripts are and why two of them install packages incompatibly
- the numbered phase structure of `upgrade-docker.sh` and what each phase boundary encodes
- the invariants that look like details and are not (service stop/start order, the
  `containerd.io` vs `containerd` package name, one rpm transaction, `--replacepkgs`)
- the asymmetric containerd config-version compatibility that the rollback guard exists for
- the version constants duplicated across eight files, and the order to change them in
- the Bash conventions and the release practice

## Fast facts

These are **standalone Bash scripts** that run as root on air-gapped RHEL 8/9 hosts.
There is no build system, no package manager, and no application code. They cannot be
executed on a Mac.

```bash
bash -n <script>.sh          # syntax check — works anywhere
shellcheck <script>.sh       # all scripts are shellcheck clean; keep them that way
tests/static-checks.sh       # Tier 1: reads source text, executes no upgrade logic
```

Tier 2 (real execution against a real systemd node) lives in `tests/vm/` and currently
requires macOS with OrbStack — see `tests/vm/README.md`.

## House rules

- Suppress a shellcheck warning only with an inline `# shellcheck disable=SCxxxx` plus a
  reason. Never a blanket ignore.
- Bump the `VERSION="x.y.z"` constant near the top of any script you change, and echo it
  in that script's banner. Versions across scripts drift on purpose.
- Commit subjects carry the new version in parens, e.g.
  `Fix NVIDIA toolkit upgrade failures (v1.2.2)`, with a bullet-list body.
- Keep this project **generic**. It is vendor-neutral open source: no company names,
  no internal hostnames or domains, no cluster specifics, no engagement details. Use
  `example.com` and reserved ranges in fixtures.

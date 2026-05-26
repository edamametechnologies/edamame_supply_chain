# EDAMAME supply-chain policy

Canonical source of truth for dependency-policy enforcement across every
Rust crate in the EDAMAME workspace. Each Rust repo in the workspace
mirrors `deny.toml` and the `audit.yml` CI workflow from this repository
via `sync.sh`.

This repository is public so that the per-repo `audit.yml` workflow can
fetch the canonical `deny.toml` for drift detection without needing a
cross-repo Personal Access Token.

## Files in this directory

| File | Purpose |
|---|---|
| [`deny.toml`](deny.toml) | Canonical `cargo-deny` policy. Mirrored into each Rust repo by `sync.sh`. |
| [`audit.yml.template`](audit.yml.template) | Per-repo CI workflow template (cargo-deny + drift check). Stamped into each repo by `sync.sh`. |
| [`renovate.json.template`](renovate.json.template) | Per-repo Renovate config template. Stamped into each repo by `sync.sh`. |
| [`sync.sh`](sync.sh) | Idempotent script that mirrors the three files above into every Rust repo in the workspace. |

## Policy summary

Hard gates wired into every Rust repo's CI (`.github/workflows/audit.yml`):

* **`advisories.vulnerability = deny`** -- any RustSec CVE in any transitive
  dependency fails the build.
* **`advisories.yanked = deny`** -- a yanked version in the lockfile fails
  the build.
* **`licenses`** -- explicit allow-list. Anything outside it fails.
* **`bans.wildcards = warn`** with `allow-wildcard-paths = true` -- no
  literal `foo = "*"` in `Cargo.toml`, but git/path workspace deps are
  permitted.
* **`sources.unknown-registry = deny`** -- only crates.io.
* **`sources.allow-git`** -- explicit allow-list of git sources
  (currently `github.com/edamametechnologies/*` and a small set of
  upstream forks).

Renovate (`renovate.json` per repo) extends the Renovate base config and
applies:

* `rangeStrategy: "pin"` -- never widens version ranges.
* `minimumReleaseAge: "7 days"` -- one-week buffer between an upstream
  upload and our PR. Single most effective defense against same-day
  malicious uploads.
* `automerge: false` -- always operator-approved.
* Weekly schedule, not realtime, so dep churn does not interleave with
  release cycles.

## Editing the policy

```bash
cd edamame_supply_chain
$EDITOR deny.toml         # edit policy
./sync.sh                 # mirror to every Rust repo cloned as a sibling
git add . && git commit -m "supply-chain: <change>" && git push
```

`sync.sh` is idempotent: re-running with no changes produces a clean
working tree across the workspace. Each consumer repo's `audit.yml`
drift-check job also verifies the per-repo `deny.toml` matches the
copy in this repository, so an out-of-band edit is caught on the next
CI run.

## Per-repo verification

From any Rust repo in the workspace:

```bash
cargo install --locked cargo-deny@0.19.7
cargo deny check
```

Specific subsets are useful for fast feedback:

```bash
cargo deny check advisories  # CVE / yanked
cargo deny check licenses    # license allow-list
cargo deny check bans        # wildcards, multiple-versions, banned crates
cargo deny check sources     # crates.io / git allow-list
```

## Repos covered by `sync.sh`

`sync.sh` mirrors into every Rust repo that ships a `Cargo.toml` at the
root. The current list (leaf -> root in the dep graph) is:

```
threatmodels-rs
undeadlock
flodbadd
edamame_backend
edamame_foundation
edamame_core
edamame_helper
edamame_posture
edamame_cli
```

Each of these repos has a `.github/workflows/audit.yml` synced from
[`audit.yml.template`](audit.yml.template) here. The workflow:

1. Runs `cargo-deny --all-features check {advisories,licenses,bans,sources}`
   in a matrix on `ubuntu-latest`.
2. Runs `EDAMAME Posture` for runtime attack-pattern detection during
   the audit (lifts the org IP allow list for the runner and gates the
   job on a clean detector outcome).
3. Runs a drift check that fetches this repository at `main` and
   confirms the consumer repo's `deny.toml` matches the canonical copy.

## License

The contents of this repository (configuration files and helper scripts)
are licensed under the Apache License 2.0. See [`LICENSE`](LICENSE).

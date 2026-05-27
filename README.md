# EDAMAME supply-chain policy

Canonical source of truth for dependency-policy enforcement across every
Rust crate in the EDAMAME workspace. Each Rust repo in the workspace
mirrors `deny.toml`, the `audit.yml` CI workflow, and the per-repo
`renovate.json` from this repository via `sync.sh`. Renovate's per-repo
config also `extends` the `renovate-base.json` here.

This repository is public so:

* The per-repo `audit.yml` workflow can fetch the canonical `deny.toml`
  for drift detection without a cross-repo Personal Access Token.
* Renovate's per-repo `renovate.json` `extends` URL resolves cleanly
  for every consumer (most of which are public crates) without needing
  the Renovate bot to be installed on a private base-config repo.

Nothing in this repo carries secrets, internal URLs, or unreleased
feature details; everything here is policy + process documentation
that is fine for external readers to inspect.

## Files in this directory

| File | Purpose |
|---|---|
| [`deny.toml`](deny.toml) | Canonical `cargo-deny` policy. Mirrored into each Rust repo by `sync.sh`. |
| [`audit.yml.template`](audit.yml.template) | Per-repo CI workflow template (cargo-deny + drift check). Stamped into each repo by `sync.sh`. |
| [`renovate.json.template`](renovate.json.template) | Per-repo Renovate config template that `extends` `renovate-base.json`. Stamped into each repo by `sync.sh`. |
| [`renovate-base.json`](renovate-base.json) | Renovate base config that every per-repo `renovate.json` extends. Lives here (not in the private `edamame_rules`) so Renovate can resolve the `extends` URL for public consumers without a token. |
| [`sync.sh`](sync.sh) | Idempotent script that mirrors `deny.toml`, `audit.yml.template`, and `renovate.json.template` into every Rust repo in the workspace. |

## Policy summary

Hard gates wired into every Rust repo's CI (`.github/workflows/audit.yml`):

* **`advisories.vulnerability = deny`** -- any RustSec CVE in any transitive
  dependency fails the build.
* **`advisories.yanked = deny`** -- a yanked version in the lockfile fails
  the build.
* **`advisories.unmaintained = warn`** -- triage backlog, does not gate.
* **`licenses`** -- explicit allow-list. Anything outside it fails.
* **`bans.multiple-versions = warn`** -- visibility, does not gate.
* **`bans.wildcards = warn`** with `allow-wildcard-paths = true` -- real
  `foo = "*"` declarations are surfaced, but git/path workspace deps are
  permitted (`flip local` mode and the canonical EDAMAME workspace
  convention).
* **`sources.unknown-registry = deny`** -- only crates.io.
* **`sources.unknown-git = warn`** with explicit allow-list of git sources
  (currently `github.com/edamametechnologies/*` plus a small set of
  upstream forks).

Renovate (per-repo `renovate.json` extending `renovate-base.json`) applies:

* `rangeStrategy: "pin"` -- never widens version ranges.
* `minimumReleaseAge: "7 days"` -- one-week buffer between an upstream
  upload and our PR. Single most effective defense against same-day
  malicious uploads.
* `automerge: false` -- always operator-approved.
* Weekly schedule (`before 06:00 on monday`) so dep churn does not
  interleave with release cycles.
* EDAMAME workspace crates (`edamame_core`, `flodbadd`, ...) are
  explicitly disabled from Renovate management because their lockfile
  cascade is owned by `commit_all.sh` in `edamame_app`.
* `pinDigests: true` on `github-actions` so workflows reference commit
  SHAs (defense against tag-rewrite attacks).

The full operational policy (when `commit_all.sh` runs the
`cargo deny check advisories` gate, how new advisories are triaged,
what `[advisories.ignore]` reasons must contain) is documented in the
internal `edamame_app/.cursor/rules/workspace.mdc` "Supply-chain
hardening (MUST follow)" section. This README is intentionally scoped
to the public-facing surface.

## Threat model

Each gate in this policy maps to a specific attack class. None of them
overlaps with another -- removing any one of them leaves a corresponding
class of attack undefended.

### 1. Same-day malicious upload (xz-utils class)

> *An attacker compromises a maintainer's crates.io account and ships a
> backdoored version. Anyone who runs `cargo update` in the next hours
> pulls it.*

**Defended by `renovate-base.json::minimumReleaseAge: "7 days"`.**
Renovate will not even open a PR for a new upstream version until 7
days after upload. By then RustSec or community detection typically
yanks/flags it; on day 7 the `cargo deny check advisories` gate
blocks the merge. cargo-deny alone cannot defend against this --
RustSec entries appear in the DB after detection, not at upload time.

### 2. Tag-rewrite attacks on GitHub Actions

> *An attacker (or compromised maintainer) force-pushes a malicious
> commit to an existing `@v4` tag of a popular GitHub Action. Workflows
> that reference the tag pull the malicious code with their normal
> permissions on the next run.*

**Defended by `renovate-base.json::pinDigests: true`** for the
`github-actions` manager. Tag references in `.github/workflows/*.yml`
are rewritten to immutable commit SHAs. When the maintainer ships a
real new version, Renovate opens a PR to bump the SHA, operator-reviewable.

### 3. Yanked / known-CVE / banned-license / banned-source slipping into the lockfile

> *An existing transitive dependency drifts into a yanked version (the
> upstream maintainer pulled it for a reason), or a CVE is published
> against a version we already ship, or a transitive dep changes
> license to something we cannot redistribute, or a fork appears under
> a non-allowlisted git origin.*

**Defended by `deny.toml::advisories.{vulnerability, yanked} = "deny"`,
`deny.toml::licenses.allow` allow-list, `deny.toml::sources.unknown-registry = "deny"`,
`deny.toml::sources.allow-git` allow-list.** Per-repo `audit.yml`
runs `cargo-deny --all-features check {advisories,licenses,bans,sources}`
on every push and PR plus a daily 04:00 UTC cron, so a regression
is caught within at most 24h regardless of dev activity.

### 4. Drift / latent CVE accumulation

> *Without routine bumps, dep versions drift months behind upstream.
> When a critical CVE drops in `tokio` or `hyper`, the security patch
> requires a multi-major-version migration that takes weeks under
> time pressure.*

**Defended by `renovate-base.json` weekly schedule + grouping.**
Renovate proposes minor + patch bumps grouped into one PR per repo
per week (`groupName: "rust-deps-weekly"`). Versions stay within
~2 weeks of upstream, so any future security bump is a small,
reviewable diff instead of an emergency refactor. Vulnerability
alerts get an emergency lane (`vulnerabilityAlerts` block, no delay).

### 5. Out-of-band edits to the per-repo policy mirror

> *A contributor with write access to a Rust repo edits the local
> `deny.toml` to suppress a real CVE and ships, bypassing the
> centralized policy.*

**Defended by `audit.yml.template::drift-check`** -- a daily CI job
that fetches `deny.toml` from this repo at `main` and `diff -u`'s it
against the per-repo copy. Any out-of-band edit fails the build.
The drift-check needs no PAT because this repo is public.

### What is NOT yet defended

* **Provenance / human review of upstream code.** No one on the
  EDAMAME team has read the source of every transitive dep we ship.
  This is what `cargo-vet` is designed to address (Phase 3,
  not yet adopted).
* **Build reproducibility / SBOM.** Releases do not yet carry a
  signed SBOM listing exact bytes. Planned for `release_all.sh`
  Phase 1 integration.

These are documented as known gaps so external auditors do not
mistake the current policy for a complete supply-chain story.

## Editing the policy

```bash
cd edamame_supply_chain
$EDITOR deny.toml          # edit policy
./sync.sh --check          # preview drift before applying
./sync.sh                  # mirror to every Rust repo cloned as a sibling
git add -A
git commit -m "supply-chain: <descriptive change>"
git push
```

`sync.sh` is idempotent: re-running with no changes produces a clean
working tree across the workspace. Each consumer repo's `audit.yml`
drift-check job also verifies the per-repo `deny.toml` matches the
copy in this repository, so an out-of-band edit is caught on the next
CI run.

After `sync.sh` runs, the working tree of each consumer Rust repo
will carry the propagated changes; commit and push each consumer
repo with its own descriptive commit message.

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
threatmodels-rs       (PUBLIC)
undeadlock            (PUBLIC)
flodbadd              (PUBLIC)
edamame_backend       (PUBLIC)
edamame_foundation    (PUBLIC)
edamame_core          (INTERNAL)
edamame_helper        (PUBLIC)
edamame_posture       (PUBLIC)
edamame_cli           (PUBLIC)
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

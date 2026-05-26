#!/usr/bin/env bash
# sync.sh - Mirror canonical supply-chain config into every Rust repo.
#
# Source of truth lives in edamametechnologies/edamame_supply_chain.
# This script:
#   * copies deny.toml -> <repo>/deny.toml
#   * copies audit.yml.template -> <repo>/.github/workflows/audit.yml
#   * copies renovate.json.template -> <repo>/renovate.json
#
# Usage:
#   ./sync.sh                # apply (default)
#   ./sync.sh --check        # exit non-zero if any repo is out of sync
#   ./sync.sh --dry-run      # show diffs without writing
#
# Prerequisites: every Rust repo cloned as a sibling of edamame_supply_chain.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"

# Rust repos in the workspace that ship a Cargo.toml at the root and need
# the supply-chain gate. Order matches the dep graph (leaf -> root).
RUST_REPOS=(
    threatmodels-rs
    undeadlock
    flodbadd
    edamame_backend
    edamame_foundation
    edamame_core
    edamame_helper
    edamame_posture
    edamame_cli
)

DRY_RUN=false
CHECK=false
case "${1:-}" in
    --dry-run) DRY_RUN=true ;;
    --check)   CHECK=true; DRY_RUN=true ;;
    "")        ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
esac

CANON_DENY="$SCRIPT_DIR/deny.toml"
CANON_AUDIT="$SCRIPT_DIR/audit.yml.template"
CANON_RENOVATE="$SCRIPT_DIR/renovate.json.template"

for f in "$CANON_DENY" "$CANON_AUDIT" "$CANON_RENOVATE"; do
    if [[ ! -f "$f" ]]; then
        echo "ERROR: missing canonical file: $f" >&2
        exit 1
    fi
done

DRIFT=0
SUCCESS=0
SKIPPED=0

# copy_canonical SRC DEST
#   - prints a one-line status
#   - in --dry-run / --check, only diffs and increments DRIFT counter
#   - in apply mode, writes DEST and increments SUCCESS counter
copy_canonical() {
    local src="$1"
    local dest="$2"
    local label="$3"

    if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
        echo "    OK    $label"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo "    DRIFT $label"
        if [[ -f "$dest" ]]; then
            diff -u "$dest" "$src" || true
        else
            echo "         (file missing -- would be created from $src)"
        fi
        DRIFT=$((DRIFT + 1))
        return 0
    fi

    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    echo "    SYNC  $label"
    SUCCESS=$((SUCCESS + 1))
}

echo "Canonical supply-chain config: $SCRIPT_DIR"
echo "Workspace parent:              $PARENT_DIR"
if [[ "$CHECK" == true ]]; then
    echo "Mode: --check (read-only, exit non-zero on drift)"
elif [[ "$DRY_RUN" == true ]]; then
    echo "Mode: --dry-run (read-only)"
else
    echo "Mode: apply"
fi
echo

for repo in "${RUST_REPOS[@]}"; do
    repo_path="$PARENT_DIR/$repo"
    if [[ ! -d "$repo_path" ]]; then
        echo "--- $repo ---"
        echo "    SKIP  not cloned at $repo_path"
        SKIPPED=$((SKIPPED + 1))
        echo
        continue
    fi
    if [[ ! -f "$repo_path/Cargo.toml" ]]; then
        echo "--- $repo ---"
        echo "    SKIP  no Cargo.toml at repo root"
        SKIPPED=$((SKIPPED + 1))
        echo
        continue
    fi

    echo "--- $repo ---"
    copy_canonical "$CANON_DENY"     "$repo_path/deny.toml"                              "deny.toml"
    copy_canonical "$CANON_AUDIT"    "$repo_path/.github/workflows/audit.yml"            ".github/workflows/audit.yml"
    copy_canonical "$CANON_RENOVATE" "$repo_path/renovate.json"                          "renovate.json"
    echo
done

echo "========================================="
if [[ "$CHECK" == true ]]; then
    if [[ "$DRIFT" -gt 0 ]]; then
        echo "DRIFT DETECTED: $DRIFT file(s) out of sync. Run ./sync.sh to fix."
        exit 1
    else
        echo "OK: all Rust repos in sync with canonical supply-chain config."
        exit 0
    fi
elif [[ "$DRY_RUN" == true ]]; then
    echo "Dry-run summary: $DRIFT file(s) would change, $SKIPPED repo(s) skipped."
else
    echo "Sync summary: $SUCCESS file(s) updated, $SKIPPED repo(s) skipped."
fi

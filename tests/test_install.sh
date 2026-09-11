#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

SOURCE_COPY="${TMP_ROOT}/source"
TEST_HOME="${TMP_ROOT}/home"
cp -a "$REPO_ROOT" "$SOURCE_COPY"
mkdir -p "$TEST_HOME"

HERMES_HOME="$TEST_HOME/.hermes" HOME="$TEST_HOME" bash "$SOURCE_COPY/scripts/install.sh" >/dev/null
SKILL_DIR="${TEST_HOME}/.hermes/skills/quality/chatgpt-pro-review"
LEDGER="${SKILL_DIR}/references/allowed-private-sources.md"

printf '\n| private/example | exact repository | approval-message-123 | 2026-09-11 |\n' >> "$LEDGER"
LEDGER_HASH_BEFORE="$(sha256sum "$LEDGER" | cut -d' ' -f1)"
printf '\nUpgrade marker.\n' >> "$SOURCE_COPY/SKILL.md"
printf '\nTemplate changed upstream.\n' >> "$SOURCE_COPY/references/allowed-private-sources.md"
chmod 0644 "$LEDGER"

HERMES_HOME="$TEST_HOME/.hermes" HOME="$TEST_HOME" bash "$SOURCE_COPY/scripts/install.sh" >/dev/null
LEDGER_HASH_AFTER="$(sha256sum "$LEDGER" | cut -d' ' -f1)"

[[ "$LEDGER_HASH_BEFORE" == "$LEDGER_HASH_AFTER" ]]
grep -q 'approval-message-123' "$LEDGER"
grep -q 'Upgrade marker.' "$SKILL_DIR/SKILL.md"

python3 - "$SKILL_DIR" "$SKILL_DIR/references" "$LEDGER" <<'PY'
import stat
import sys
from pathlib import Path

skill_dir, references_dir, ledger = map(Path, sys.argv[1:])
assert stat.S_IMODE(skill_dir.stat().st_mode) == 0o700
assert stat.S_IMODE(references_dir.stat().st_mode) == 0o700
assert stat.S_IMODE(ledger.stat().st_mode) == 0o600
PY

printf 'install upgrade preserves the operator ledger and private modes\n'

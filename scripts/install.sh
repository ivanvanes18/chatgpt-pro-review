#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERMES_ROOT="${HERMES_HOME:-${HOME}/.hermes}"
SKILL_DIR="${HERMES_ROOT}/skills/quality/chatgpt-pro-review"
REFERENCES_DIR="${SKILL_DIR}/references"
LEDGER="${REFERENCES_DIR}/allowed-private-sources.md"

ensure_private_directory() {
  local path="$1"
  if [[ -L "$path" ]]; then
    printf 'Refusing symlinked install directory: %s\n' "$path" >&2
    exit 1
  fi
  if [[ -e "$path" && ! -d "$path" ]]; then
    printf 'Install path exists and is not a directory: %s\n' "$path" >&2
    exit 1
  fi
  install -d -m 0700 "$path"
  chmod 0700 "$path"
}

umask 077
ensure_private_directory "$SKILL_DIR"
ensure_private_directory "$REFERENCES_DIR"

if [[ -L "${SKILL_DIR}/SKILL.md" ]]; then
  printf 'Refusing symlinked SKILL.md: %s\n' "${SKILL_DIR}/SKILL.md" >&2
  exit 1
fi
install -m 0644 "${REPO_ROOT}/SKILL.md" "${SKILL_DIR}/SKILL.md"

if [[ -L "$LEDGER" ]]; then
  printf 'Refusing symlinked approval ledger: %s\n' "$LEDGER" >&2
  exit 1
fi
if [[ -e "$LEDGER" ]]; then
  if [[ ! -f "$LEDGER" ]]; then
    printf 'Approval ledger exists and is not a regular file: %s\n' "$LEDGER" >&2
    exit 1
  fi
  chmod 0600 "$LEDGER"
  printf 'Preserved existing approval ledger: %s\n' "$LEDGER"
else
  install -m 0600 "${REPO_ROOT}/references/allowed-private-sources.md" "$LEDGER"
  printf 'Initialized approval ledger: %s\n' "$LEDGER"
fi

printf 'Installed chatgpt-pro-review at %s\n' "$SKILL_DIR"

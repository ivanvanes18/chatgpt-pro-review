# ChatGPT Pro Review skill for Hermes

A fail-closed workflow for sending a frozen, sanitized artifact set to the ChatGPT web **Pro** model, preserving submission evidence, and adjudicating every material finding locally.

This repository contains the workflow only. It does **not** contain ChatGPT credentials, browser profiles, review transcripts, private-source approvals, customer files, or reviewed repositories.

## What it does

- freezes the exact review object and acceptance criteria;
- blocks secrets, credentials, private data, unsupported formats, and unapproved private sources;
- verifies the destination account/workspace and visible Pro mode before transmission;
- stages inspected outbound files with hashes and a manifest;
- submits once and records delivery evidence without blind retries;
- requires local evidence for every accepted or rejected external finding;
- reports coverage gaps instead of turning a partial review into a false approval.

## Assumptions

Before installing, take these as given — the skill does not check or provide them for you:

- **Verified on Linux and WSL2 only.** That is the whole verified surface. Other platforms are **unverified** here: nothing in this repository promises they work, and you should follow upstream (Hermes, chip-relay) documentation rather than these commands if you are on one.
- **Tooling you need present:** POSIX `sh` for the install blocks below; **Bash** (chip-relay's launcher is `#!/usr/bin/env bash`); **Git**; **Python 3** with `venv` (chip-relay runs its CLI from a virtualenv, falling back to `python3` on `PATH`); **network access** to github.com for the clones; and a supported browser/display backend for chip-relay's chosen backend (CloakBrowser or BrowserOS), per upstream.
- **Hermes is already installed** and on `PATH` ([Hermes Agent](https://github.com/NousResearch/hermes-agent)). See *Choosing the Hermes home* below for where the install actually lands.
- **The operator supplies and authenticates the ChatGPT account and browser profile.** You bring an account with visible Pro access and sign it in yourself, in an operator-controlled browser profile, before a review runs. This repository contains **no credentials, cookies, session stores, or browser profiles**, and the skill never supplies, extracts, or bypasses them — an authentication challenge stops the run as `AUTH_REQUIRED` and hands back to you.
- **ChatGPT UI availability may change.** Model labels, input routes, per-chat controls, and connectors are outside this repository's control and can change or disappear without notice. The skill is written to stop fail-closed when an expected control is missing rather than guess; it cannot guarantee any ChatGPT feature exists on your account.
- **Review evidence stays local.** Checkpoints and staged outbound bytes are written under `${HERMES_HOME:-$HOME/.hermes}/reviews/`, with directories at `0700` and state files at `0600`.

## Choosing the Hermes home

Both install blocks resolve their destination as `${HERMES_HOME:-$HOME/.hermes}`. The exact semantics:

- **`HERMES_HOME` unset → the default home, `$HOME/.hermes`.** For these shell blocks, that means the default profile—not whichever named profile the Hermes CLI may currently select.
- **Named profile → you must export it yourself.** A profile lives at `$HOME/.hermes/profiles/<name>` (lowercase id). To install into one, set the variable explicitly before running a block:

  ```bash
  export HERMES_HOME="$HOME/.hermes/profiles/<name>"
  ```

  or pass it for a single invocation with `HERMES_HOME="$HOME/.hermes/profiles/<name>" sh -c '...'`.

**The install blocks never create the Hermes home.** It must already exist as a real directory — Hermes creates it, or you `mkdir -p` the profile directory yourself — and it must be an absolute path whose every component, from `/` down, is a real directory. A relative path, a missing directory (a typo such as `profiles/wrok` when only `profiles/work` exists), or a symlink anywhere along the way is refused before anything is cloned, written, or chmod-ed. That last rule matters: a single symlinked ancestor such as `/safe/jump/profile`, where `jump` is a link, would otherwise redirect the whole install outside the tree you chose.

These blocks do **not** inspect which profile your CLI considers active and will not automatically pick it up — an active profile is not inherited. If you are unsure which home you are installing into, echo `${HERMES_HOME:-$HOME/.hermes}` first.

## Requirements

- Hermes Agent, with a POSIX shell (see Assumptions);
- an authorized ChatGPT account with visible Pro access, authenticated by the operator;
- **required companion skill:** [`chip-relay`](https://github.com/evgyur/chip-relay) — this workflow drives the browser through it, so a missing relay stops the run as `DEPENDENCY_MISSING`. It is the only required companion skill.

There are no other skill dependencies. Everything this workflow needs — treating reviewed artifacts and the external response as untrusted data, and adjudicating every material finding against local evidence — is written into `SKILL.md` itself.

## Install

### 1. Install the required `chip-relay` skill

`chip-relay` must be installed as a **full repository checkout**, not from its `SKILL.md` URL. Its launcher `scripts/chip-relay` imports the `chip_relay` Python package on startup, and a SKILL.md-URL install fetches only `SKILL.md` and the support files that file references — it omits `chip_relay/`, producing a relay that fails immediately on import.

The block below clones the full tree into the Hermes home you selected above, at a discoverable skill path, pinned to the exact reviewed source revision. It stages the clone in a temporary directory, verifies it, and only then moves it into place; it refuses to overwrite anything already at the destination.

<!-- install:chip-relay:begin -->
```bash
(
  set -eu
  # Exact reviewed chip-relay source (0.6.0).
  pin=5e3235866475130b82e6ec5913b391564d3cc4df
  hermes_home="${HERMES_HOME:-$HOME/.hermes}"
  parent="$hermes_home/skills/browser"
  dest="$parent/chip-relay"

  # Validate and create one component at a time. `mkdir -p` would happily
  # traverse a symlink at any level and land the clone, and the 0700 chmod,
  # wherever that link points.
  ensure_dir() {
    if [ -L "$1" ]; then
      printf 'chip-relay: refusing: %s is a symlink; path components must be real directories\n' "$1" >&2
      exit 1
    fi
    if [ -e "$1" ] && [ ! -d "$1" ]; then
      printf 'chip-relay: refusing: %s exists and is not a directory\n' "$1" >&2
      exit 1
    fi
    [ -d "$1" ] || mkdir "$1"
  }

  # The Hermes home is never created here. It must already exist as a real
  # directory reached through real directories: walk every component from / and
  # reject a symlink or non-directory anywhere along the way, without following
  # links. One symlinked ancestor (/safe/jump/profile) would otherwise redirect
  # the clone and the 0700 chmod outside the tree you selected.
  require_real_dir_chain() {
    case "$1" in
      /*) ;;
      *) printf 'chip-relay: refusing: HERMES_HOME must be an absolute path, got: %s\n' "$1" >&2; exit 1 ;;
    esac
    _cur=
    _rem="${1#/}"
    while [ -n "$_rem" ]; do
      _comp="${_rem%%/*}"
      case "$_rem" in
        */*) _rem="${_rem#*/}" ;;
        *)   _rem= ;;
      esac
      [ -n "$_comp" ] || continue
      _cur="$_cur/$_comp"
      if [ -L "$_cur" ]; then
        printf 'chip-relay: refusing: %s is a symlink; every component of HERMES_HOME must be a real directory\n' "$_cur" >&2
        exit 1
      fi
      if [ ! -d "$_cur" ]; then
        printf 'chip-relay: refusing: %s is missing or not a directory\n' "$_cur" >&2
        printf 'chip-relay: create the Hermes home (or profile directory) first; this installer will not create it\n' >&2
        exit 1
      fi
    done
    if [ ! -d "$1" ]; then
      printf 'chip-relay: refusing: %s is not an existing directory\n' "$1" >&2
      exit 1
    fi
  }

  require_real_dir_chain "$hermes_home"
  ensure_dir "$hermes_home/skills"
  ensure_dir "$parent"

  if [ -e "$dest" ] || [ -L "$dest" ]; then
    printf 'chip-relay: refusing to overwrite existing path: %s\n' "$dest" >&2
    printf 'chip-relay: inspect and move it aside yourself if you want a fresh install\n' >&2
    exit 1
  fi

  staging="$(mktemp -d "$hermes_home/.chip-relay-install.XXXXXX")"
  trap 'rm -rf "$staging"' EXIT INT TERM
  src="$staging/chip-relay"

  git clone https://github.com/evgyur/chip-relay.git "$src"
  git -C "$src" checkout --quiet "$pin"

  # Verify exact source identity before anything is moved into place.
  head="$(git -C "$src" rev-parse HEAD)"
  if [ "$head" != "$pin" ]; then
    printf 'chip-relay: HEAD %s is not the pinned commit %s\n' "$head" "$pin" >&2
    exit 1
  fi
  grep -q '^name: chip-relay$' "$src/SKILL.md" || {
    printf 'chip-relay: SKILL.md does not declare name: chip-relay\n' >&2; exit 1; }
  [ -d "$src/chip_relay" ] || {
    printf 'chip-relay: missing chip_relay Python package\n' >&2; exit 1; }
  [ -x "$src/scripts/chip-relay" ] || {
    printf 'chip-relay: missing executable scripts/chip-relay\n' >&2; exit 1; }

  mv "$src" "$dest"
  chmod 0700 "$dest"
  printf 'installed chip-relay %s at %s\n' "$pin" "$dest"
  grep -m1 '^version:' "$dest/SKILL.md"
)
```
<!-- install:chip-relay:end -->

If verification fails, nothing is moved into place and the staging directory is removed. To update or reinstall later, move the existing `chip-relay` directory aside yourself and re-run the block — it will not overwrite it for you.

Confirm the checkout on disk and the exact skill name Hermes will load — this skill loads `chip-relay` by that literal name and will not accept a renamed copy:

```bash
d="${HERMES_HOME:-$HOME/.hermes}/skills/browser/chip-relay"
test -f "$d/SKILL.md" && echo "SKILL.md present"
test -d "$d/chip_relay" && echo "chip_relay package present"
git -C "$d" rev-parse HEAD
grep -m1 '^name:' "$d/SKILL.md"
grep -m1 '^version:' "$d/SKILL.md"
```

`rev-parse HEAD` must print `5e3235866475130b82e6ec5913b391564d3cc4df`, the name must be exactly `chip-relay`, and the version `0.6.0` — that commit is the reviewed 0.6.0 source.

Then confirm the agent can actually load it. In a Hermes session, run `/reload-skills` (or start a fresh session) and load it by exact name:

```
/reload-skills
/skill chip-relay
```

Loading by exact name is the authoritative check. Do not rely on the `hermes skills` CLI inventory here: it reports how skills were installed, and a skill placed by a manual full-repository checkout like this one may not appear there the way a registry install does.

Then set up a browser backend and bring the relay up, following chip-relay's own documentation at <https://github.com/evgyur/chip-relay> — backends are installed separately and are not part of this skill:

```bash
cd "${HERMES_HOME:-$HOME/.hermes}/skills/browser/chip-relay"
scripts/install-cloakbrowser.sh        # CloakBrowser backend; see upstream README
scripts/chip-relay doctor              # environment preflight
scripts/chip-relay launch --backend cloakbrowser
scripts/chip-relay health
scripts/chip-relay status
```

BrowserOS is an alternative backend, installed per upstream instructions and launched with `scripts/chip-relay launch --backend browseros`. `doctor` must pass and `health` must report the relay live on its loopback CDP endpoint before a review runs; otherwise this skill stops as `DEPENDENCY_MISSING`.

### 2. Install this skill

This installer refreshes `SKILL.md` on every run and never overwrites your approval ledger:

<!-- install:skill:begin -->
```bash
(
  set -eu
  hermes_home="${HERMES_HOME:-$HOME/.hermes}"
  dest="$hermes_home/skills/quality/chatgpt-pro-review"
  ledger="$dest/references/allowed-private-sources.md"

  tmp=
  tmpledger=
  cleanup() {
    if [ -n "$tmp" ]; then rm -rf "$tmp"; fi
    if [ -n "$tmpledger" ]; then rm -f "$tmpledger"; fi
  }
  trap cleanup EXIT INT TERM

  # Validate and create one component at a time. `mkdir -p` would happily
  # traverse a symlink at any level and land every write and chmod below on
  # whatever that link points at. A normal existing directory is fine and kept.
  ensure_dir() {
    if [ -L "$1" ]; then
      printf 'refusing: %s is a symlink; path components must be real directories\n' "$1" >&2
      exit 1
    fi
    if [ -e "$1" ] && [ ! -d "$1" ]; then
      printf 'refusing: %s exists and is not a directory\n' "$1" >&2
      exit 1
    fi
    [ -d "$1" ] || mkdir "$1"
  }

  # The Hermes home is never created here — Hermes creates it, or you create a
  # named profile directory yourself. It must already exist as a real directory
  # reached through real directories: walk every component from / and reject a
  # symlink or non-directory anywhere along the way, without following links.
  # A single symlinked ancestor (/safe/jump/profile) would otherwise redirect
  # the whole install.
  require_real_dir_chain() {
    case "$1" in
      /*) ;;
      *) printf 'refusing: HERMES_HOME must be an absolute path, got: %s\n' "$1" >&2; exit 1 ;;
    esac
    _cur=
    _rem="${1#/}"
    while [ -n "$_rem" ]; do
      _comp="${_rem%%/*}"
      case "$_rem" in
        */*) _rem="${_rem#*/}" ;;
        *)   _rem= ;;
      esac
      [ -n "$_comp" ] || continue
      _cur="$_cur/$_comp"
      if [ -L "$_cur" ]; then
        printf 'refusing: %s is a symlink; every component of HERMES_HOME must be a real directory\n' "$_cur" >&2
        exit 1
      fi
      if [ ! -d "$_cur" ]; then
        printf 'refusing: %s is missing or not a directory\n' "$_cur" >&2
        printf 'create the Hermes home (or profile directory) first; this installer will not create it\n' >&2
        exit 1
      fi
    done
    if [ ! -d "$1" ]; then
      printf 'refusing: %s is not an existing directory\n' "$1" >&2
      exit 1
    fi
  }

  require_real_dir_chain "$hermes_home"
  ensure_dir "$hermes_home/skills"
  ensure_dir "$hermes_home/skills/quality"
  ensure_dir "$dest"
  ensure_dir "$dest/references"
  chmod 0700 "$dest" "$dest/references"

  # The approval ledger must be a plain file. A symlink or any other
  # non-regular file is refused outright and never followed, read, or chmod-ed.
  if [ -L "$ledger" ]; then
    printf 'refusing: %s is a symlink; approval ledger must be a regular file\n' "$ledger" >&2
    exit 1
  fi
  if [ -e "$ledger" ] && [ ! -f "$ledger" ]; then
    printf 'refusing: %s is not a regular file\n' "$ledger" >&2
    exit 1
  fi

  tmp="$(mktemp -d)"
  git clone --depth 1 https://github.com/ivanvanes18/chatgpt-pro-review.git "$tmp/repo"

  # Workflow file: refreshed on every install, so updates actually apply.
  install -m 0644 "$tmp/repo/SKILL.md" "$dest/SKILL.md"

  if [ -f "$ledger" ]; then
    # Existing ledger: preserve the operator's bytes exactly, and end up with a
    # private single-link file. chmod follows hard links, so tightening in place
    # would silently re-mode any other name sharing the inode. Copy to a private
    # temp inside the verified references dir, verify byte equality, then replace.
    tmpledger="$(mktemp "$dest/references/.allowed-private-sources.XXXXXX")"
    chmod 0600 "$tmpledger"
    cat "$ledger" > "$tmpledger"
    if ! cmp -s "$ledger" "$tmpledger"; then
      printf 'refusing: failed to copy %s byte-for-byte\n' "$ledger" >&2
      exit 1
    fi
    mv "$tmpledger" "$ledger"
    tmpledger=
  else
    # Absent ledger: seed the empty template once.
    install -m 0600 "$tmp/repo/references/allowed-private-sources.md" "$ledger"
  fi

  printf 'installed: %s\n' "$dest"
)
```
<!-- install:skill:end -->

Re-run the same block to update. It is idempotent: `SKILL.md` is replaced, `references/allowed-private-sources.md` keeps your bytes exactly and is repaired to `0600` if its mode was loosened, and the skill directories stay at `0700`. An ordinary pre-existing skill directory is kept as-is, and unrelated files in it are left alone.

The install refuses, before cloning or writing anything, if the destination directory, its `references/` directory, or the ledger is a symlink or any other non-regular file — those are never followed, written through, or chmod-ed.

Outside `$dest`, both install blocks also use network access (a `git clone` from GitHub) and a temporary directory that is removed when the block exits — the chip-relay block stages under `${HERMES_HOME:-$HOME/.hermes}`, this one under the system temporary directory. Nothing else in your Hermes home is modified.

> Do **not** use `hermes skills install` to update this skill once you have recorded approvals. That installer removes the existing skill directory before writing the new copy, which deletes your `references/allowed-private-sources.md`. Use it only for a first install onto a machine with no ledger yet, and back the ledger up otherwise.

Verify the install on disk:

```bash
d="${HERMES_HOME:-$HOME/.hermes}/skills/quality/chatgpt-pro-review"
test -f "$d/SKILL.md" && echo "SKILL.md present"
test -f "$d/references/allowed-private-sources.md" && echo "approval ledger present"
grep -m1 '^name:' "$d/SKILL.md"
grep -m1 '^version:' "$d/SKILL.md"
```

The name must be exactly `chatgpt-pro-review` and the version `0.2.0`.

Then make the agent see it. In a Hermes session, run `/reload-skills` (or start a fresh session) and load it by exact name:

```
/reload-skills
/skill chatgpt-pro-review
```

That load is the verification that matters — a skill placed by manual copy is not necessarily reported by the `hermes skills` CLI inventory the way a registry install is. In normal use you do not load it by hand: it is invoked when an external ChatGPT Pro review is explicitly requested.

## Private-source approvals

The shipped `references/allowed-private-sources.md` is intentionally empty. Add only exact, auditable approvals for sources the operator is authorized to transmit. Never copy an approval ledger from the review target itself, and never treat approval for one object as approval for siblings.

## Data handling

By default, do not transmit:

- `.env` files, API keys, cookies, private keys, tokens, payment data;
- browser profiles, session stores, logs, caches, backups, build output;
- customer/client content or private repositories without exact approval;
- binaries, archives, image-only PDFs, or compound packages without a verified extraction and coverage workflow.

Use an ordinary saved chat by default so the review is observable. Use Temporary chat only after the user explicitly accepts that it will not appear in history or synchronize across browsers.

## Scope

This skill orchestrates review and evidence. It does not replace domain-specific review, provide ChatGPT Pro access, guarantee availability of the ChatGPT UI, or authorize changes to the reviewed object.

## Tests

`tests/install_contract_test.sh` runs both install blocks above into a throwaway `HERMES_HOME` (offline, via a local `git` stand-in) and asserts the install contract:

- this skill: owner-only modes, `SKILL.md` refreshed on reinstall, the approval ledger preserved byte-for-byte, a loosened ledger repaired to `0600` without byte changes, and a symlinked ledger refused without being followed;
- `chip-relay`: full repository tree, exact pinned commit verified before anything is moved into place, the `chip_relay` Python package present, an existing checkout never overwritten;
- the documented dependency, approval, and manifest wording.

No network access and no writes outside a temporary directory.

A second, **opt-in** gate checks the claim this README makes about the real world — that the pinned upstream commit still exists, carries the reviewed identity, and yields a launcher that starts and imports its Python package. It needs network access, so it is off by default:

```bash
sh tests/live_pin_gate_test.sh
# or, as part of the offline suite:
RUN_LIVE_PIN_GATE=1 sh tests/install_contract_test.sh
```

```bash
sh tests/install_contract_test.sh
```

## License

MIT. See [LICENSE](LICENSE).

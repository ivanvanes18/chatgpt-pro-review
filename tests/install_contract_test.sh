#!/bin/sh
# Regression test for the public installation/usability contract.
#
# Runs the documented installers from README.md into a throwaway HERMES_HOME
# (offline, through a local `git` stand-in) and checks:
#   * this skill's install semantics — refresh SKILL.md, never clobber or follow
#     the operator ledger, owner-only modes;
#   * the chip-relay installer — full repository tree pinned to an exact commit,
#     including the chip_relay Python package the launcher imports;
#   * the documentation contract a new public user depends on.
#
# Usage: sh tests/install_contract_test.sh
# Portable POSIX shell; no network access required.

set -u

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

# The exact chip-relay source revision this skill is written against.
CHIP_PIN=5e3235866475130b82e6ec5913b391564d3cc4df

pass=0
fail=0

ok() {
    pass=$((pass + 1))
    printf 'PASS  %s\n' "$1"
}

ko() {
    fail=$((fail + 1))
    printf 'FAIL  %s\n' "$1"
    [ $# -gt 1 ] && printf '      %s\n' "$2"
}

check() { # name, condition-result (0/1), detail
    if [ "$2" -eq 0 ]; then ok "$1"; else ko "$1" "${3-}"; fi
}

has() { grep -Fq -- "$2" "$1" 2>/dev/null; }
hasre() { grep -Eq -- "$2" "$1" 2>/dev/null; }

file_mode() { # portable octal permission bits, e.g. 700
    if m=$(stat -c '%a' "$1" 2>/dev/null); then
        printf '%s\n' "$m"
    else
        stat -f '%Lp' "$1" 2>/dev/null
    fi
}

# extract_block <marker-name> <outfile> -- the fenced shell block between
# <!-- <marker>:begin --> and <!-- <marker>:end --> in README.md.
extract_block() {
    awk -v begin="<!-- $1:begin -->" -v end="<!-- $1:end -->" '
        index($0, begin) { inblock = 1; next }
        index($0, end)   { inblock = 0; next }
        inblock && /^```/ { infence = !infence; next }
        inblock && infence { print }
    ' "$repo_root/README.md" > "$2"
    [ -s "$2" ]
}

readme="$repo_root/README.md"
skill="$repo_root/SKILL.md"
ledger_src="$repo_root/references/allowed-private-sources.md"

# ---------------------------------------------------------------------------
# Offline git stand-in
# ---------------------------------------------------------------------------

bin="$work/bin"
mkdir -p "$bin"
cat > "$bin/git" <<'SHIM'
#!/bin/sh
# Offline stand-in for the git commands the documented installers use.
# Any other git usage is a test bug and fails loudly.
if [ "${1-}" = "-C" ]; then
    repo=$2
    shift 2
    case "${1-}" in
        checkout)
            shift
            sha=
            for a in "$@"; do case "$a" in -*) ;; *) sha=$a ;; esac; done
            mkdir -p "$repo/.git"
            printf '%s\n' "${GIT_SHIM_HEAD:-$sha}" > "$repo/.git/HEAD_SHA"
            exit 0 ;;
        rev-parse)
            cat "$repo/.git/HEAD_SHA" 2>/dev/null || exit 1
            exit 0 ;;
        *)
            echo "git shim: unsupported: -C $repo $*" >&2; exit 127 ;;
    esac
fi
[ "${1-}" = "clone" ] || { echo "git shim: unexpected subcommand: $*" >&2; exit 127; }
url=; dest=
shift
for a in "$@"; do
    case "$a" in
        -*) ;;
        http://*|https://*) url=$a ;;
        *) dest=$a ;;
    esac
done
[ -n "$dest" ] || { echo "git shim: no destination in: $*" >&2; exit 2; }
mkdir -p "$dest/.git" || exit 1
case "$url" in
    *chip-relay*)
        # Minimal stand-in for the upstream chip-relay tree.
        mkdir -p "$dest/scripts" "$dest/references" "$dest/templates"
        printf '%s\n' '---' 'name: chip-relay' 'version: 0.6.0' '---' > "$dest/SKILL.md"
        # Launcher modelled on upstream scripts/chip-relay: bash, and it imports
        # chip_relay.capabilities at startup before doing anything else. A tree
        # without the package must fail here, not silently "install".
        cat > "$dest/scripts/chip-relay" <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PYTHONPATH="$REPO_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 -c \
    'import os; from chip_relay.capabilities import reject_credential_environment; reject_credential_environment(os.environ)'
case "${1-}" in
    --help|help) echo "chip-relay fixture launcher: startup import OK"; exit 0 ;;
esac
exit 0
LAUNCHER
        chmod 0755 "$dest/scripts/chip-relay"
        printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$dest/scripts/install-cloakbrowser.sh"
        chmod 0755 "$dest/scripts/install-cloakbrowser.sh"
        # CHIP_SHIM_OMIT_PKG reproduces the SKILL.md-URL install defect: the
        # Python package that scripts/chip-relay imports is missing.
        if [ "${CHIP_SHIM_OMIT_PKG:-0}" != "1" ]; then
            mkdir -p "$dest/chip_relay"
            : > "$dest/chip_relay/__init__.py"
            cat > "$dest/chip_relay/capabilities.py" <<'CAPS'
def reject_credential_environment(env):
    """Stand-in for the upstream startup guard the launcher imports."""
    return True
CAPS
        fi
        ;;
    *)
        mkdir -p "$dest/references"
        cp "$REPO_UNDER_TEST/SKILL.md" "$dest/SKILL.md" || exit 1
        cp "$REPO_UNDER_TEST/references/allowed-private-sources.md" \
           "$dest/references/allowed-private-sources.md" || exit 1
        ;;
esac
exit 0
SHIM
chmod 0755 "$bin/git"

mkdir -p "$work/fake-home"

run_block() { # script, HERMES_HOME  (extra env comes from the caller)
    HERMES_HOME="$2" REPO_UNDER_TEST="$repo_root" \
        PATH="$bin:$PATH" HOME="$work/fake-home" \
        sh "$1" >"$work/run.out" 2>&1
}

run_block_no_hermes_home() { # script, HOME  -- HERMES_HOME deliberately unset
    env -u HERMES_HOME REPO_UNDER_TEST="$repo_root" \
        PATH="$bin:$PATH" HOME="$2" \
        sh "$1" >"$work/run.out" 2>&1
}

skip() { printf 'SKIP  %s\n' "$1"; }

# ---------------------------------------------------------------------------
# This skill's installer
# ---------------------------------------------------------------------------

installer="$work/install-skill.sh"
if extract_block "install:skill" "$installer"; then
    ok "README.md contains a delimited install:skill block"
    skill_installable=0
else
    ko "README.md contains a delimited install:skill block" \
       "expected <!-- install:skill:begin --> ... <!-- install:skill:end --> around a shell fence"
    skill_installable=1
fi

if [ "$skill_installable" -eq 0 ]; then
    if sh -n "$installer" 2>"$work/syntax.err"; then
        ok "install:skill block is syntactically valid POSIX shell"
    else
        ko "install:skill block is syntactically valid POSIX shell" "$(cat "$work/syntax.err")"
        skill_installable=1
    fi
fi

if [ "$skill_installable" -eq 0 ]; then
    check "install:skill resolves the active Hermes home via \${HERMES_HOME:-\$HOME/.hermes}" \
        "$(has "$installer" 'HERMES_HOME:-$HOME/.hermes' && echo 0 || echo 1)"
    check "install:skill does not hard-code ~/.hermes paths" \
        "$(hasre "$installer" '~/\.hermes' && echo 1 || echo 0)"
    check "install:skill contains no wildcard removal" \
        "$(hasre "$installer" 'rm.*\*' && echo 1 || echo 0)" \
        "wildcard rm can destroy unrelated operator files"

    hh="$work/hh-skill"
    mkdir -p "$hh"   # Hermes home must pre-exist; the installer never creates it
    if run_block "$installer" "$hh"; then
        ok "first install succeeds"
        skill_dir=$(find "$hh/skills" -name chatgpt-pro-review -type d 2>/dev/null | head -n 1)
    else
        ko "first install succeeds" "$(cat "$work/run.out")"
        skill_dir=
    fi

    if [ -n "$skill_dir" ] && [ -d "$skill_dir" ]; then
        ok "install creates the skill directory under the temporary HERMES_HOME"
        ledger="$skill_dir/references/allowed-private-sources.md"

        check "skill directory mode is 0700" \
            "$([ "$(file_mode "$skill_dir")" = "700" ] && echo 0 || echo 1)" \
            "got $(file_mode "$skill_dir")"
        check "references directory mode is 0700" \
            "$([ "$(file_mode "$skill_dir/references")" = "700" ] && echo 0 || echo 1)" \
            "got $(file_mode "$skill_dir/references" 2>/dev/null)"
        check "first install creates the approval ledger" \
            "$([ -f "$ledger" ] && echo 0 || echo 1)"
        check "approval ledger mode is 0600" \
            "$([ "$(file_mode "$ledger" 2>/dev/null)" = "600" ] && echo 0 || echo 1)" \
            "got $(file_mode "$ledger" 2>/dev/null)"
        check "installed SKILL.md matches the repository copy" \
            "$(cmp -s "$repo_root/SKILL.md" "$skill_dir/SKILL.md" && echo 0 || echo 1)"

        # --- reinstall over operator-modified state -------------------------
        printf '\n| acme/private-repo | docs only | approval msg 2026-09-11 | 2026-09-11 |\n' \
            >> "$ledger"
        cp "$ledger" "$work/ledger.before"
        printf '\nLOCAL SENTINEL EDIT\n' >> "$skill_dir/SKILL.md"

        if run_block "$installer" "$hh"; then
            ok "reinstall succeeds"
        else
            ko "reinstall succeeds" "$(cat "$work/run.out")"
        fi

        check "reinstall preserves the approval ledger byte-for-byte" \
            "$(cmp -s "$work/ledger.before" "$ledger" && echo 0 || echo 1)" \
            "operator approvals must never be overwritten by an install"
        check "reinstall keeps the approval ledger at mode 0600" \
            "$([ "$(file_mode "$ledger" 2>/dev/null)" = "600" ] && echo 0 || echo 1)" \
            "got $(file_mode "$ledger" 2>/dev/null)"
        check "reinstall refreshes SKILL.md from the repository" \
            "$(cmp -s "$repo_root/SKILL.md" "$skill_dir/SKILL.md" && echo 0 || echo 1)" \
            "SKILL.md must be updated on every install"
        check "reinstall keeps directory modes at 0700" \
            "$([ "$(file_mode "$skill_dir")" = "700" ] && echo 0 || echo 1)" \
            "got $(file_mode "$skill_dir")"

        # --- a loosened ledger is tightened back, bytes untouched -----------
        chmod 0644 "$ledger"
        cp "$ledger" "$work/ledger.loose"
        if run_block "$installer" "$hh"; then
            ok "reinstall over a 0644 ledger succeeds"
        else
            ko "reinstall over a 0644 ledger succeeds" "$(cat "$work/run.out")"
        fi
        check "reinstall tightens an existing 0644 ledger to 0600" \
            "$([ "$(file_mode "$ledger" 2>/dev/null)" = "600" ] && echo 0 || echo 1)" \
            "got $(file_mode "$ledger" 2>/dev/null); a world-readable approval ledger must be repaired"
        check "tightening the ledger leaves its bytes unchanged" \
            "$(cmp -s "$work/ledger.loose" "$ledger" && echo 0 || echo 1)"

        # --- a symlinked ledger is refused, never followed ------------------
        outside="$work/outside-ledger.md"
        printf 'OUTSIDE TARGET\n' > "$outside"
        cp "$outside" "$work/outside.before"
        chmod 0644 "$outside"
        rm -f "$ledger"
        ln -s "$outside" "$ledger"

        if run_block "$installer" "$hh"; then
            ko "install refuses a symlinked approval ledger" \
               "installer exited 0 with a symlinked ledger"
        else
            ok "install refuses a symlinked approval ledger"
        fi
        check "refusal explains the non-regular ledger" \
            "$(grep -Eqi 'symlink|regular file' "$work/run.out" && echo 0 || echo 1)" \
            "output: $(cat "$work/run.out")"
        check "refused install leaves the ledger path a symlink" \
            "$([ -L "$ledger" ] && echo 0 || echo 1)"
        check "refused install does not write through the symlink" \
            "$(cmp -s "$work/outside.before" "$outside" && echo 0 || echo 1)" \
            "the symlink target must not be modified"
        check "refused install does not chmod the symlink target" \
            "$([ "$(file_mode "$outside")" = "644" ] && echo 0 || echo 1)" \
            "got $(file_mode "$outside")"
    else
        ko "install creates the skill directory under the temporary HERMES_HOME"
    fi

    # --- every path component is validated one level at a time --------------
    # An installer that reaches its destination with `mkdir -p` through
    # unchecked components will follow a symlink at *any* level and land its
    # writes and chmods on whatever that link points at. Each component of the
    # path each installer creates or uses gets its own case.
    #
    # redirect_case <installer> <label> <path-under-hermes-home | ROOT> [extra-env-name=value]
    redirect_case() {
        rc_inst=$1
        rc_label=$2
        rc_rel=$3
        rc_tag=$(printf '%s' "$rc_label" | tr -cs 'a-zA-Z0-9' '-')
        rhh="$work/hh-redir-$rc_tag"
        target="$work/redir-target-$rc_tag"
        rm -rf "$rhh" "$target"
        mkdir -p "$target"
        printf 'OUTSIDE FILE\n' > "$target/outside.txt"
        chmod 0755 "$target"

        if [ "$rc_rel" = "ROOT" ]; then
            mkdir -p "$(dirname "$rhh")"
            linkpath="$rhh"
        else
            linkpath="$rhh/$rc_rel"
            mkdir -p "$(dirname "$linkpath")"
        fi
        ln -s "$target" "$linkpath"

        if run_block "$rc_inst" "$rhh"; then
            ko "install refuses $rc_label" "installer exited 0"
        else
            ok "install refuses $rc_label"
        fi
        check "refusal for $rc_label names a symlink or non-directory" \
            "$(grep -Eqi 'symlink|not a directory' "$work/run.out" && echo 0 || echo 1)" \
            "output: $(cat "$work/run.out")"
        check "refused $rc_label leaves the path a symlink" \
            "$([ -L "$linkpath" ] && echo 0 || echo 1)"
        check "refused $rc_label does not chmod the outside target" \
            "$([ "$(file_mode "$target")" = "755" ] && echo 0 || echo 1)" \
            "got $(file_mode "$target"); the symlink target must not be chmod-ed"
        check "refused $rc_label writes nothing into the outside target" \
            "$([ "$(find "$target" -mindepth 1 | wc -l | tr -d ' ')" = "1" ] && \
               [ -f "$target/outside.txt" ] && echo 0 || echo 1)" \
            "target now holds: $(find "$target" -mindepth 1 | tr '\n' ' ')"

        # a non-directory at the same component must also be refused
        rm -f "$linkpath"
        printf 'NOT A DIRECTORY\n' > "$linkpath"
        cp "$linkpath" "$work/notdir.before"
        if run_block "$rc_inst" "$rhh"; then
            ko "install refuses a non-directory at $rc_label" "installer exited 0"
        else
            ok "install refuses a non-directory at $rc_label"
        fi
        check "non-directory at $rc_label is left untouched" \
            "$(cmp -s "$work/notdir.before" "$linkpath" && echo 0 || echo 1)"
    }

    redirect_case "$installer" "a symlinked Hermes root" ROOT
    redirect_case "$installer" "a symlinked skills directory" "skills"
    redirect_case "$installer" "a symlinked quality category directory" "skills/quality"
    redirect_case "$installer" "a symlinked install destination" \
        "skills/quality/chatgpt-pro-review"
    redirect_case "$installer" "a symlinked references directory" \
        "skills/quality/chatgpt-pro-review/references"

    # --- a hard-linked ledger is replaced atomically, alias untouched -------
    # chmod follows hard links: tightening a ledger that shares an inode with a
    # file elsewhere would silently re-mode that file too. The install must
    # break the alias by replacing the ledger with a fresh single-link copy.
    lhh="$work/hh-hardlink"
    mkdir -p "$lhh"
    if run_block "$installer" "$lhh"; then
        ldest=$(find "$lhh/skills" -name chatgpt-pro-review -type d 2>/dev/null | head -n 1)
        lledger="$ldest/references/allowed-private-sources.md"
        printf '\n| acme/private | docs | approval 2026-09-11 | 2026-09-11 |\n' >> "$lledger"
        cp "$lledger" "$work/hardlink.before"
        alias_path="$work/ledger-alias.md"
        rm -f "$alias_path"
        ln "$lledger" "$alias_path"
        chmod 0644 "$alias_path"          # both names, one inode, mode 0644

        if run_block "$installer" "$lhh"; then
            ok "reinstall over a hard-linked ledger succeeds"
        else
            ko "reinstall over a hard-linked ledger succeeds" "$(cat "$work/run.out")"
        fi
        check "hard-linked ledger keeps its exact bytes" \
            "$(cmp -s "$work/hardlink.before" "$lledger" && echo 0 || echo 1)"
        check "ledger ends up 0600 after the hard-link case" \
            "$([ "$(file_mode "$lledger")" = "600" ] && echo 0 || echo 1)" \
            "got $(file_mode "$lledger")"
        check "ledger ends up with a single link" \
            "$([ "$(stat -c '%h' "$lledger" 2>/dev/null || stat -f '%l' "$lledger")" = "1" ] && echo 0 || echo 1)" \
            "link count $(stat -c '%h' "$lledger" 2>/dev/null || stat -f '%l' "$lledger"); the alias must be broken, not re-moded"
        check "the other hard-link alias is not chmod-ed" \
            "$([ "$(file_mode "$alias_path")" = "644" ] && echo 0 || echo 1)" \
            "got $(file_mode "$alias_path")"
        check "the other hard-link alias keeps its bytes" \
            "$(cmp -s "$work/hardlink.before" "$alias_path" && echo 0 || echo 1)"
        check "no temporary ledger copy is left behind" \
            "$([ -z "$(find "$ldest/references" -name '.*' -type f 2>/dev/null)" ] && echo 0 || echo 1)" \
            "leftovers: $(find "$ldest/references" -name '.*' -type f 2>/dev/null | tr '\n' ' ')"
    else
        ko "hard-link ledger setup install succeeds" "$(cat "$work/run.out")"
    fi

    # --- Hermes home selection is explicit, never inferred -------------------
    # Unset HERMES_HOME means the DEFAULT home, even if a named profile is
    # "active" in the CLI; a named profile must be exported explicitly.
    dhome="$work/profile-default-home"
    mkdir -p "$dhome/.hermes"   # default home pre-exists, as Hermes would create it
    if run_block_no_hermes_home "$installer" "$dhome"; then
        ok "install with HERMES_HOME unset succeeds"
    else
        ko "install with HERMES_HOME unset succeeds" "$(cat "$work/run.out")"
    fi
    check "unset HERMES_HOME installs into the default home" \
        "$([ -f "$dhome/.hermes/skills/quality/chatgpt-pro-review/SKILL.md" ] && echo 0 || echo 1)" \
        "expected \$HOME/.hermes/skills/quality/chatgpt-pro-review/SKILL.md"

    phome="$work/profile-named-home"
    mkdir -p "$phome/.hermes/profiles/work"
    if HOME="$phome" run_block "$installer" "$phome/.hermes/profiles/work"; then
        ok "install into an explicitly exported named profile succeeds"
    else
        ko "install into an explicitly exported named profile succeeds" "$(cat "$work/run.out")"
    fi
    check "named profile installs under profiles/<name>" \
        "$([ -f "$phome/.hermes/profiles/work/skills/quality/chatgpt-pro-review/SKILL.md" ] && echo 0 || echo 1)"
    check "named profile install does not touch the default home" \
        "$([ ! -e "$phome/.hermes/skills/quality/chatgpt-pro-review" ] && echo 0 || echo 1)" \
        "the default home and a named profile must be distinct destinations"

    # HERMES_HOME must already exist; a mistyped profile is not created for you.
    hermes_home_chain_cases() { # installer, label-suffix
        hc_inst=$1
        hc_sfx=$2

        # (a) typo'd profile name, profiles/ itself exists
        thome="$work/profile-typo$hc_sfx"
        mkdir -p "$thome/.hermes/profiles/work"
        if run_block "$hc_inst" "$thome/.hermes/profiles/wrok"; then
            ko "install refuses a missing profile directory$hc_sfx" "installer exited 0"
        else
            ok "install refuses a missing profile directory$hc_sfx"
        fi
        check "refusal for a missing profile is actionable$hc_sfx" \
            "$(grep -Eqi 'missing or not a directory|will not create it' "$work/run.out" && echo 0 || echo 1)" \
            "output: $(cat "$work/run.out")"
        check "mistyped profile directory is not created$hc_sfx" \
            "$([ ! -e "$thome/.hermes/profiles/wrok" ] && echo 0 || echo 1)" \
            "HERMES_HOME must never be created by the installer"
        check "refusing a mistyped profile leaves the real profile alone$hc_sfx" \
            "$([ -z "$(find "$thome/.hermes/profiles/work" -mindepth 1 2>/dev/null)" ] && echo 0 || echo 1)"

        # (b) /safe/jump/profile — a symlinked ANCESTOR of HERMES_HOME
        jroot="$work/safe$hc_sfx"
        jtarget="$work/jump-target$hc_sfx"
        rm -rf "$jroot" "$jtarget"
        mkdir -p "$jroot" "$jtarget/profile"
        printf 'OUTSIDE FILE\n' > "$jtarget/profile/outside.txt"
        chmod 0755 "$jtarget" "$jtarget/profile"
        ln -s "$jtarget" "$jroot/jump"          # /safe/jump -> outside
        # HERMES_HOME = /safe/jump/profile: the final component is a real dir,
        # but it is only reachable through the symlinked ancestor.
        if run_block "$hc_inst" "$jroot/jump/profile"; then
            ko "install refuses a symlinked ancestor of HERMES_HOME$hc_sfx" "installer exited 0"
        else
            ok "install refuses a symlinked ancestor of HERMES_HOME$hc_sfx"
        fi
        check "refusal names the symlinked ancestor$hc_sfx" \
            "$(grep -Eqi 'symlink' "$work/run.out" && echo 0 || echo 1)" \
            "output: $(cat "$work/run.out")"
        check "symlinked ancestor is left intact$hc_sfx" \
            "$([ -L "$jroot/jump" ] && echo 0 || echo 1)"
        check "no write lands through the symlinked ancestor$hc_sfx" \
            "$([ "$(find "$jtarget" -mindepth 1 | wc -l | tr -d ' ')" = "2" ] && \
               [ -f "$jtarget/profile/outside.txt" ] && echo 0 || echo 1)" \
            "target now holds: $(find "$jtarget" -mindepth 1 | tr '\n' ' ')"
        check "no mode change lands through the symlinked ancestor$hc_sfx" \
            "$([ "$(file_mode "$jtarget")" = "755" ] && \
               [ "$(file_mode "$jtarget/profile")" = "755" ] && echo 0 || echo 1)" \
            "got $(file_mode "$jtarget") and $(file_mode "$jtarget/profile")"

        # (c) a relative HERMES_HOME is refused outright
        if run_block "$hc_inst" "relative/hermes/home"; then
            ko "install refuses a relative HERMES_HOME$hc_sfx" "installer exited 0"
        else
            ok "install refuses a relative HERMES_HOME$hc_sfx"
        fi
        check "refusal names the absolute-path requirement$hc_sfx" \
            "$(grep -Eqi 'absolute path' "$work/run.out" && echo 0 || echo 1)" \
            "output: $(cat "$work/run.out")"
    }

    hermes_home_chain_cases "$installer" ""

    # --- a normal pre-existing skill directory is preserved, not refused ----
    phh="$work/hh-preexisting"
    mkdir -p "$phh"
    pdest="$phh/skills/quality/chatgpt-pro-review"
    mkdir -p "$pdest/references"
    printf 'OPERATOR FILE\n' > "$pdest/operator-note.txt"
    if run_block "$installer" "$phh"; then
        ok "install accepts a normal pre-existing skill directory"
    else
        ko "install accepts a normal pre-existing skill directory" "$(cat "$work/run.out")"
    fi
    check "install preserves unrelated files in an existing skill directory" \
        "$([ -f "$pdest/operator-note.txt" ] && echo 0 || echo 1)"
    check "install into an existing directory still writes SKILL.md" \
        "$(cmp -s "$repo_root/SKILL.md" "$pdest/SKILL.md" && echo 0 || echo 1)"
fi

# ---------------------------------------------------------------------------
# chip-relay installer
# ---------------------------------------------------------------------------

chip="$work/install-chip.sh"
if extract_block "install:chip-relay" "$chip"; then
    ok "README.md contains a delimited install:chip-relay block"
    chip_installable=0
else
    ko "README.md contains a delimited install:chip-relay block" \
       "expected <!-- install:chip-relay:begin --> ... <!-- install:chip-relay:end --> around a shell fence"
    chip_installable=1
fi

if [ "$chip_installable" -eq 0 ]; then
    if sh -n "$chip" 2>"$work/syntax.err"; then
        ok "install:chip-relay block is syntactically valid POSIX shell"
    else
        ko "install:chip-relay block is syntactically valid POSIX shell" "$(cat "$work/syntax.err")"
        chip_installable=1
    fi
fi

check "chip-relay is installed from the full repository, not a bare SKILL.md URL" \
    "$(has "$readme" 'https://github.com/evgyur/chip-relay.git' && echo 0 || echo 1)" \
    "the launcher imports the chip_relay package, which a SKILL.md-URL install omits"
check "README no longer installs chip-relay via hermes skills install from a URL" \
    "$(hasre "$readme" 'hermes skills install.*chip-relay' && echo 1 || echo 0)" \
    "that path omits the chip_relay Python package and yields a broken relay"
check "README pins chip-relay to the exact reviewed 40-char commit" \
    "$(hasre "$readme" "(^|[^0-9a-f])$CHIP_PIN([^0-9a-f]|$)" && echo 0 || echo 1)" \
    "expected $CHIP_PIN"
check "README documents upstream backend setup" \
    "$(has "$readme" 'install-cloakbrowser.sh' && echo 0 || echo 1)"
check "README documents the chip-relay doctor command" \
    "$(has "$readme" 'chip-relay doctor' && echo 0 || echo 1)"
check "README documents the chip-relay launch command" \
    "$(hasre "$readme" 'chip-relay launch --backend' && echo 0 || echo 1)"
check "README documents the chip-relay health command" \
    "$(has "$readme" 'chip-relay health' && echo 0 || echo 1)"

if [ "$chip_installable" -eq 0 ]; then
    check "install:chip-relay resolves the active Hermes home" \
        "$(has "$chip" 'HERMES_HOME:-$HOME/.hermes' && echo 0 || echo 1)"
    check "install:chip-relay does not hard-code ~/.hermes paths" \
        "$(hasre "$chip" '~/\.hermes' && echo 1 || echo 0)"
    check "install:chip-relay contains no wildcard removal" \
        "$(hasre "$chip" 'rm.*\*' && echo 1 || echo 0)"
    check "install:chip-relay carries the 40-char pin" \
        "$(hasre "$chip" "(^|[^0-9a-f])$CHIP_PIN([^0-9a-f]|$)" && echo 0 || echo 1)"

    chh="$work/hh-chip"
    mkdir -p "$chh"
    if run_block "$chip" "$chh"; then
        ok "chip-relay install succeeds"
        chip_dir=$(find "$chh/skills" -name chip-relay -type d -not -path '*/chip-relay/*' 2>/dev/null | head -n 1)
    else
        ko "chip-relay install succeeds" "$(cat "$work/run.out")"
        chip_dir=
    fi

    if [ -n "$chip_dir" ] && [ -d "$chip_dir" ]; then
        ok "chip-relay lands in a discoverable skill directory"
        check "installed chip-relay exposes SKILL.md for discovery" \
            "$([ -f "$chip_dir/SKILL.md" ] && echo 0 || echo 1)"
        check "installed chip-relay includes the chip_relay Python package" \
            "$([ -d "$chip_dir/chip_relay" ] && echo 0 || echo 1)" \
            "scripts/chip-relay imports chip_relay.capabilities at startup"
        check "installed chip-relay includes the launcher script" \
            "$([ -x "$chip_dir/scripts/chip-relay" ] && echo 0 || echo 1)"
        check "installed chip-relay records the verified commit" \
            "$([ "$(cat "$chip_dir/.git/HEAD_SHA" 2>/dev/null)" = "$CHIP_PIN" ] && echo 0 || echo 1)"
        check "chip-relay directory mode is 0700" \
            "$([ "$(file_mode "$chip_dir")" = "700" ] && echo 0 || echo 1)" \
            "got $(file_mode "$chip_dir")"

        # Durable proof: the installed tree must actually start. The launcher
        # imports chip_relay.capabilities before anything else, so this fails
        # on exactly the tree a SKILL.md-URL install would have produced.
        if command -v bash >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
            if "$chip_dir/scripts/chip-relay" --help >"$work/launch.out" 2>&1; then
                ok "installed chip-relay launcher starts and imports chip_relay"
            else
                ko "installed chip-relay launcher starts and imports chip_relay" \
                   "$(cat "$work/launch.out")"
            fi
            check "launcher startup reports the import succeeded" \
                "$(grep -q 'startup import OK' "$work/launch.out" && echo 0 || echo 1)" \
                "output: $(cat "$work/launch.out")"
        else
            skip "chip-relay launcher startup (bash and/or python3 unavailable)"
        fi

        # re-running must refuse rather than clobber an existing checkout
        printf 'OPERATOR LOCAL EDIT\n' > "$chip_dir/.local-marker"
        if run_block "$chip" "$chh"; then
            ko "chip-relay install refuses an existing target" "installer exited 0"
        else
            ok "chip-relay install refuses an existing target"
        fi
        check "refused chip-relay install preserves the existing checkout" \
            "$([ -f "$chip_dir/.local-marker" ] && echo 0 || echo 1)"
    else
        ko "chip-relay lands in a discoverable skill directory" "$(cat "$work/run.out")"
    fi

    # a tree without the Python package must be rejected, not installed
    chh2="$work/hh-chip-nopkg"
    mkdir -p "$chh2"
    if CHIP_SHIM_OMIT_PKG=1 run_block "$chip" "$chh2"; then
        ko "chip-relay install rejects a tree missing the chip_relay package" "installer exited 0"
    else
        ok "chip-relay install rejects a tree missing the chip_relay package"
    fi
    check "no partial chip-relay checkout is left behind after rejection" \
        "$([ -z "$(find "$chh2/skills" -maxdepth 3 -name chip-relay -type d 2>/dev/null)" ] && echo 0 || echo 1)"

    # a commit other than the pin must be rejected
    chh3="$work/hh-chip-drift"
    mkdir -p "$chh3"
    if GIT_SHIM_HEAD=0000000000000000000000000000000000000000 run_block "$chip" "$chh3"; then
        ko "chip-relay install rejects a HEAD that is not the pinned commit" "installer exited 0"
    else
        ok "chip-relay install rejects a HEAD that is not the pinned commit"
    fi

    # every component the chip-relay installer creates or uses is validated too
    redirect_case "$chip" "a symlinked Hermes root (chip-relay)" ROOT
    redirect_case "$chip" "a symlinked skills directory (chip-relay)" "skills"
    redirect_case "$chip" "a symlinked browser category directory" "skills/browser"
    redirect_case "$chip" "a symlinked chip-relay destination" "skills/browser/chip-relay"
    hermes_home_chain_cases "$chip" " (chip-relay)"
fi

# ---------------------------------------------------------------------------
# SKILL.md contract
# ---------------------------------------------------------------------------

check "SKILL.md version is 0.2.0" \
    "$(hasre "$skill" '^version: 0\.2\.0$' && echo 0 || echo 1)" \
    "the public contract changed; got: $(grep -E '^version:' "$skill" | head -n 1)"
check "SKILL.md has no stale V0.1 scope label" \
    "$(hasre "$skill" 'V0\.1' && echo 1 || echo 0)" \
    "format scope must not be labelled with a package version"
check "SKILL.md states a text-only admission scope" \
    "$(hasre "$skill" '[Tt]ext-only' && echo 0 || echo 1)"

required_line=$(grep -F 'REQUIRED' "$skill" | head -n 1)
check "SKILL.md requires chip-relay" \
    "$(printf '%s' "$required_line" | grep -Fq 'chip-relay' && echo 0 || echo 1)" \
    "required line: ${required_line:-<none>}"

rel_line=$(grep -F 'related_skills' "$skill" | head -n 1)
check "metadata related_skills lists chip-relay" \
    "$(printf '%s' "$rel_line" | grep -Fq 'chip-relay' && echo 0 || echo 1)" \
    "related_skills: ${rel_line:-<none>}"

# The removed dependency names must not reappear anywhere in the public docs.
for name in anti-prompt-injection adversarial-review; do
    check "SKILL.md does not mention $name" \
        "$(has "$skill" "$name" && echo 1 || echo 0)" \
        "$(grep -n -F "$name" "$skill" | head -n 1)"
    check "README does not mention $name" \
        "$(has "$readme" "$name" && echo 1 || echo 0)" \
        "$(grep -n -F "$name" "$readme" | head -n 1)"
done
check "SKILL.md carries no optional-dependency prose" \
    "$(hasre "$skill" 'defense-in-depth|defence-in-depth|if .* skill is installed' && echo 1 || echo 0)"
check "README carries no optional-dependency prose" \
    "$(hasre "$readme" 'defense-in-depth|defence-in-depth' && echo 1 || echo 0)"

check "SKILL.md keeps the untrusted-artifact rule inline" \
    "$(hasre "$skill" 'untrusted' && echo 0 || echo 1)"
check "SKILL.md keeps local evidence-based adjudication inline" \
    "$(hasre "$skill" '[Mm]aterial .*finding' && hasre "$skill" 'local evidence' && echo 0 || echo 1)"

check "SKILL.md grants no blanket allowance to all installed skills" \
    "$(hasre "$skill" '[Ii]nstalled Hermes skills( and public sources)? are allowed by default' && echo 1 || echo 0)"
check "approval ledger grants no blanket allowance to all installed skills" \
    "$(hasre "$ledger_src" '^- Installed Hermes skills: allowed by default' && echo 1 || echo 0)"
check "SKILL.md requires exact approval for non-public installed skills" \
    "$(hasre "$skill" 'non-public|private, or local|local, or private' && echo 0 || echo 1)"

check "SKILL.md review state uses the active Hermes home" \
    "$(has "$skill" 'HERMES_HOME:-$HOME/.hermes' && echo 0 || echo 1)"
check "SKILL.md has no hard-coded ~/.hermes path" \
    "$(hasre "$skill" '~/\.hermes' && echo 1 || echo 0)"
check "SKILL.md states owner-only modes for review state" \
    "$(hasre "$skill" '0700' && hasre "$skill" '0600' && echo 0 || echo 1)"
check "SKILL.md lists DEPENDENCY_MISSING as a fail-closed status" \
    "$(has "$skill" 'DEPENDENCY_MISSING' && echo 0 || echo 1)"
# --- manifest: two independent clauses, each separately required -----------
# Scoped to the Run contract section, and mutation-checked: removing either
# clause must break its own assertion and only its own.
run_contract="$work/run-contract.txt"
awk '/^## Run contract/{f=1;next} /^## /{f=0} f' "$skill" > "$run_contract"
check "SKILL.md has a Run contract section to scope manifest wording to" \
    "$([ -s "$run_contract" ] && echo 0 || echo 1)"

PAT_FILES='[Tt]ransmit[^.]*files listed in the manifest'
PAT_MANIFEST='the manifest itself'

check "Run contract: outbound files listed in the manifest are transmitted" \
    "$(hasre "$run_contract" "$PAT_FILES" && echo 0 || echo 1)" \
    "the file set itself must be stated as transmitted"
check "Run contract: the manifest itself is additionally transmitted" \
    "$(hasre "$run_contract" "$PAT_MANIFEST" && echo 0 || echo 1)" \
    "the manifest must be sent in addition to the files"

# Mutation sensitivity: delete one clause at a time and confirm exactly the
# matching assertion flips to failing.
mut_files="$work/mutant-no-files.txt"
mut_manifest="$work/mutant-no-manifest.txt"
sed 's/files listed in the manifest/OMITTED/g' "$run_contract" > "$mut_files"
sed 's/plus the manifest itself//g; s/the manifest itself is [a-z]* *\(sent\|transmitted\)//g' \
    "$run_contract" > "$mut_manifest"

check "mutation: dropping the transmitted-files clause fails its assertion" \
    "$(hasre "$mut_files" "$PAT_FILES" && echo 1 || echo 0)" \
    "the files assertion is insensitive to its own clause"
check "mutation: dropping the manifest-itself clause fails its assertion" \
    "$(hasre "$mut_manifest" "$PAT_MANIFEST" && echo 1 || echo 0)" \
    "the manifest assertion is insensitive to its own clause"
check "mutation: the two manifest assertions are independent" \
    "$(hasre "$mut_files" "$PAT_MANIFEST" && hasre "$mut_manifest" "$PAT_FILES" && echo 0 || echo 1)" \
    "each clause must be asserted separately, not by one combined pattern"

# --- public-source admission requires an immutable, undiverged revision ----
for f in "$skill" "$ledger_src"; do
    label=$(basename "$f")
    check "$label binds default eligibility to an immutable public revision" \
        "$(hasre "$f" 'immutable public revision|immutable, publicly resolvable revision' && echo 0 || echo 1)"
    check "$label disqualifies local or untracked divergence" \
        "$(hasre "$f" 'untracked' && hasre "$f" 'diverg' && echo 0 || echo 1)" \
        "uncommitted edits and untracked files must remove default eligibility"
    check "$label requires approval when the revision is not provable" \
        "$(hasre "$f" '(otherwise|if not|unless).*(requires?|needs?) (an? )?approval|requires approval' && echo 0 || echo 1)"
done

# ---------------------------------------------------------------------------
# README contract
# ---------------------------------------------------------------------------

check "README documents the canonical chip-relay source" \
    "$(has "$readme" 'https://github.com/evgyur/chip-relay' && echo 0 || echo 1)"
# `hermes skills list` is a CLI inventory whose contents depend on how a skill
# was installed and on the CLI version; both skills here arrive by manual
# full-repo/manual-copy paths. Verify on disk and in session instead.
check "README does not verify installs with hermes skills list" \
    "$(hasre "$readme" 'hermes skills (list|check)' && echo 1 || echo 0)" \
    "a CLI inventory can report a manually installed skill as absent"
check "README verifies the installed skill by SKILL.md frontmatter name" \
    "$(hasre "$readme" "grep -m1 '\^name:'" && echo 0 || echo 1)"
check "README verifies the installed files on disk" \
    "$(hasre "$readme" 'test -f .*SKILL\.md|\[ -f .*SKILL\.md' && echo 0 || echo 1)"
check "README documents /reload-skills as the discovery step" \
    "$(has "$readme" '/reload-skills' && echo 0 || echo 1)"
check "README loads chip-relay in session by exact name" \
    "$(has "$readme" '/skill chip-relay' && echo 0 || echo 1)"
check "README loads chatgpt-pro-review in session by exact name" \
    "$(has "$readme" '/skill chatgpt-pro-review' && echo 0 || echo 1)"
check "README records the reviewed chip-relay version" \
    "$(has "$readme" '0.6.0' && echo 0 || echo 1)"

check "README documents a POSIX shell assumption" \
    "$(hasre "$readme" 'POSIX' && echo 0 || echo 1)"

# --- platform assumptions: verified surface only ---------------------------
check "README states the verified platforms are Linux and WSL2" \
    "$(hasre "$readme" 'Linux' && hasre "$readme" 'WSL2' && echo 0 || echo 1)"
check "README does not imply macOS support" \
    "$(hasre "$readme" 'macOS|Mac OS|OSX' && echo 1 || echo 0)" \
    "this setup is not verified there"
check "README does not imply Git Bash support" \
    "$(hasre "$readme" 'Git Bash' && echo 1 || echo 0)" \
    "this setup is not verified there"
check "README marks other platforms unverified and defers upstream" \
    "$(hasre "$readme" 'unverified' && echo 0 || echo 1)"
check "README requires Bash for the chip-relay launcher" \
    "$(hasre "$readme" 'Bash' && echo 0 || echo 1)"
check "README requires Git" \
    "$(hasre "$readme" '\bGit\b' && echo 0 || echo 1)"
check "README requires Python 3 with venv" \
    "$(hasre "$readme" 'Python 3' && hasre "$readme" 'venv' && echo 0 || echo 1)"
check "README requires network access" \
    "$(hasre "$readme" 'network access' && echo 0 || echo 1)"
check "README requires a browser/display backend" \
    "$(hasre "$readme" 'display|browser backend' && echo 0 || echo 1)"

# --- Hermes home / profile semantics are stated, not assumed ---------------
check "README does not call the resolved home automatically active" \
    "$(hasre "$readme" 'active Hermes home' && echo 1 || echo 0)" \
    "unset HERMES_HOME means the DEFAULT home, not whichever profile is active"
check "SKILL.md does not call the resolved home automatically active" \
    "$(hasre "$skill" 'active Hermes home' && echo 1 || echo 0)"
check "README states the default home applies when HERMES_HOME is unset" \
    "$(hasre "$readme" 'unset' && hasre "$readme" 'default home' && echo 0 || echo 1)"
check "README requires an explicit export for a named profile" \
    "$(hasre "$readme" 'export HERMES_HOME=' && echo 0 || echo 1)"
check "README documents the profiles/<name> layout" \
    "$(hasre "$readme" 'profiles/<name>|profiles/[a-z]+' && echo 0 || echo 1)"
check "README warns that an active profile is not inherited automatically" \
    "$(hasre "$readme" 'not inherit|does not follow|will not pick up|not automatically' && echo 0 || echo 1)"
check "README documents that Hermes must already be installed" \
    "$(hasre "$readme" 'Hermes .*(already )?installed|installed Hermes' && echo 0 || echo 1)"
check "README documents operator-supplied and operator-authenticated ChatGPT access" \
    "$(hasre "$readme" 'operator supplies|operator-supplied' && echo 0 || echo 1)"
check "README documents that the ChatGPT UI may change" \
    "$(hasre "$readme" 'UI .*(may|can) change|availability .*may change' && echo 0 || echo 1)"
check "README documents that no credentials are included" \
    "$(hasre "$readme" 'no credentials|never supplies' && echo 0 || echo 1)"
check "README documents the assumptions explicitly" \
    "$(hasre "$readme" '^## Assumptions' && echo 0 || echo 1)"
check "README does not claim installs touch nothing outside the destination" \
    "$(hasre "$readme" 'nothing outside .* is touched' && echo 1 || echo 0)" \
    "installs also use a temporary directory and network access"
check "README discloses the temporary directory and network use" \
    "$(hasre "$readme" 'temporary (clone )?director|network access' && echo 0 || echo 1)"

check "README documents the opt-in live pin gate" \
    "$(has "$readme" 'RUN_LIVE_PIN_GATE=1' && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
# Optional live gate (network). Off by default so this suite stays offline.
# ---------------------------------------------------------------------------

if [ "${RUN_LIVE_PIN_GATE:-0}" = "1" ]; then
    printf '\n--- live pin gate (network) ---\n'
    if sh "$repo_root/tests/live_pin_gate_test.sh"; then
        ok "live pin gate passes against the pinned upstream commit"
    else
        ko "live pin gate passes against the pinned upstream commit" \
           "see live pin gate output above"
    fi
    printf -- '--- end live pin gate ---\n\n'
else
    skip "live pin gate (set RUN_LIVE_PIN_GATE=1 to clone the pinned commit and start its launcher)"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

#!/bin/sh
# Live pin gate for chip-relay — OPT-IN, requires network access.
#
# The offline suite (tests/install_contract_test.sh) proves the installer's
# logic against a fixture. This gate proves the claim the README actually makes
# about the real world: that the pinned upstream commit exists, still carries
# the reviewed skill identity, and produces a tree whose launcher starts and
# imports its Python package.
#
# Run it explicitly:
#     sh tests/live_pin_gate_test.sh
# or from the offline suite:
#     RUN_LIVE_PIN_GATE=1 sh tests/install_contract_test.sh
#
# Requires: git, python3, bash, and network access to github.com.
#
# Scope of writes: this gate clones into its own temp dir and never touches a
# Hermes home. The launcher is invoked with HOME and CHIP_RELAY_BASE_DIR rooted
# under that temp dir, because upstream defaults CHIP_RELAY_BASE_DIR to
# $HOME/.local/share/chip-relay and would otherwise create relay state in the
# real home. The gate asserts afterwards that nothing was created outside those
# temp roots. It does not launch a browser.

set -u

CHIP_PIN=5e3235866475130b82e6ec5913b391564d3cc4df
CHIP_REPO=https://github.com/evgyur/chip-relay.git
CHIP_VERSION=0.6.0

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
ko()  { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; }
check() { if [ "$2" -eq 0 ]; then ok "$1"; else ko "$1" "${3-}"; fi; }

for tool in git python3 bash; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'SKIP  live pin gate: %s not available\n' "$tool"
        exit 0
    fi
done

printf 'live pin gate: cloning %s at %s\n' "$CHIP_REPO" "$CHIP_PIN"
src="$work/chip-relay"
if git clone --quiet "$CHIP_REPO" "$src" 2>"$work/clone.err"; then
    ok "pinned upstream repository clones"
else
    ko "pinned upstream repository clones" "$(cat "$work/clone.err")"
    printf '\n%s passed, %s failed\n' "$pass" "$fail"
    exit 1
fi

if git -C "$src" checkout --quiet "$CHIP_PIN" 2>"$work/checkout.err"; then
    ok "pinned commit exists upstream and checks out"
else
    ko "pinned commit exists upstream and checks out" "$(cat "$work/checkout.err")"
fi

head=$(git -C "$src" rev-parse HEAD 2>/dev/null)
check "HEAD is exactly the pinned commit" \
    "$([ "$head" = "$CHIP_PIN" ] && echo 0 || echo 1)" \
    "got ${head:-<none>}, expected $CHIP_PIN"

check "pinned tree declares name: chip-relay" \
    "$(grep -q '^name: chip-relay$' "$src/SKILL.md" && echo 0 || echo 1)" \
    "got: $(grep -m1 '^name:' "$src/SKILL.md" 2>/dev/null)"
check "pinned tree declares the reviewed version" \
    "$(grep -q "^version: $CHIP_VERSION\$" "$src/SKILL.md" && echo 0 || echo 1)" \
    "got: $(grep -m1 '^version:' "$src/SKILL.md" 2>/dev/null)"

check "pinned tree ships the chip_relay Python package" \
    "$([ -d "$src/chip_relay" ] && echo 0 || echo 1)" \
    "a SKILL.md-URL install omits this directory"
check "pinned tree ships an executable launcher" \
    "$([ -x "$src/scripts/chip-relay" ] && echo 0 || echo 1)"
check "launcher is a bash script" \
    "$(head -n 1 "$src/scripts/chip-relay" | grep -q 'bash' && echo 0 || echo 1)" \
    "got: $(head -n 1 "$src/scripts/chip-relay")"
check "launcher imports chip_relay.capabilities at startup" \
    "$(grep -q 'chip_relay.capabilities' "$src/scripts/chip-relay" && echo 0 || echo 1)"

# The import the launcher performs before doing anything else.
if PYTHONPATH="$src" python3 -c \
    'import os
from chip_relay.capabilities import reject_credential_environment
print("import OK")' >"$work/import.out" 2>&1; then
    ok "chip_relay.capabilities imports from the pinned tree"
else
    ko "chip_relay.capabilities imports from the pinned tree" "$(cat "$work/import.out")"
fi

# Launcher startup, no browser: --help must reach argument handling, which means
# the startup import guard already ran and passed. HOME and CHIP_RELAY_BASE_DIR
# are rooted under $work so any state the launcher creates is contained; upstream
# otherwise defaults the base dir to $HOME/.local/share/chip-relay.
real_home=$HOME
fake_home="$work/fake-home"
relay_base="$work/relay-base"
mkdir -p "$fake_home" "$relay_base"
marker="$work/.run-marker"
: > "$marker"

# Snapshot the paths the launcher would touch if it ignored the overrides.
outside_probe="$real_home/.local/share/chip-relay"
if [ -e "$outside_probe" ]; then
    outside_before=$(ls -la "$outside_probe" 2>/dev/null | sha1sum 2>/dev/null || echo present)
else
    outside_before=absent
fi

if env HOME="$fake_home" CHIP_RELAY_BASE_DIR="$relay_base" \
       "$src/scripts/chip-relay" --help >"$work/help.out" 2>&1; then
    ok "launcher startup succeeds (--help, no browser launched)"
else
    rc=$?
    # Upstream may exit non-zero for an unknown flag while still proving startup;
    # only a startup/import failure is a real failure here.
    if grep -qiE 'ModuleNotFoundError|ImportError|No module named' "$work/help.out"; then
        ko "launcher startup succeeds (--help, no browser launched)" \
           "startup import failed: $(cat "$work/help.out")"
    else
        ok "launcher startup reached argument handling (exit $rc, no import error)"
    fi
fi
check "launcher startup produced no Python import error" \
    "$(grep -qiE 'ModuleNotFoundError|ImportError|No module named' "$work/help.out" && echo 1 || echo 0)" \
    "$(head -n 5 "$work/help.out")"

if [ -e "$outside_probe" ]; then
    outside_after=$(ls -la "$outside_probe" 2>/dev/null | sha1sum 2>/dev/null || echo present)
else
    outside_after=absent
fi
check "launcher created no state in the real home" \
    "$([ "$outside_before" = "$outside_after" ] && echo 0 || echo 1)" \
    "$outside_probe changed during the run"
check "no Hermes home was created or touched by this gate" \
    "$([ ! -e "$fake_home/.hermes" ] && echo 0 || echo 1)" \
    "this gate installs nothing into a Hermes home"
# Any chip-relay state must live under the temp roots, never in the real home.
outside_state=$(find "$real_home/.local/share" "$real_home/.chip-relay" \
                     -maxdepth 1 -name 'chip-relay*' -newer "$marker" 2>/dev/null | tr '\n' ' ')
check "no chip-relay state was created in the real home" \
    "$([ -z "$outside_state" ] && echo 0 || echo 1)" \
    "found: $outside_state"
printf '      launcher state under temp roots: %s\n' \
    "$(find "$relay_base" "$fake_home" -mindepth 1 2>/dev/null | tr '\n' ' ')"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

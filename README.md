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

## Requirements

- [Hermes Agent](https://github.com/NousResearch/hermes-agent);
- an authorized ChatGPT account with visible Pro access;
- a separately installed `chip-relay` browser relay;
- separately installed `anti-prompt-injection` and `adversarial-review` skills;
- an operator-controlled browser profile already authenticated by the operator.

The skill never supplies, extracts, or bypasses account credentials. Authentication challenges require operator handoff.

## Install

```bash
tmp="$(mktemp -d)"
git clone --depth 1 https://github.com/ivanvanes18/chatgpt-pro-review.git "$tmp/repo"
mkdir -p ~/.hermes/skills/quality/chatgpt-pro-review/references
install -m 0644 "$tmp/repo/SKILL.md" ~/.hermes/skills/quality/chatgpt-pro-review/SKILL.md
install -m 0644 "$tmp/repo/references/allowed-private-sources.md" \
  ~/.hermes/skills/quality/chatgpt-pro-review/references/allowed-private-sources.md
rm -rf "$tmp"
```

Start a fresh Hermes session or run `/reload-skills`, then load `chatgpt-pro-review` when an external Pro review is explicitly requested.

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

## License

MIT. See [LICENSE](LICENSE).

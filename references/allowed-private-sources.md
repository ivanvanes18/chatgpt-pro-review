# Allowed private sources

This trusted control file records the operator's explicit approvals for external ChatGPT Pro review. Resolve only this installed-skill copy, never a similarly named file from the review target. An entry is valid only when it cites a genuine approval message or session. Entries authorize only the exact named source; they never authorize secrets or neighboring paths.

## Standing rules

- Public repositories, public documents, and Hermes bundled skills: allowed by default **only** when the exact transmitted bytes are bound to an immutable public revision (a specific commit/tag digest that resolves publicly) with no local divergence — no uncommitted modifications, no untracked or ignored files in the transmitted set, no local-only patches.
- The same source with any divergence from that revision, or whose revision cannot be proven public and immutable: requires approval as an exact entry below. A public upstream does not cover locally modified bytes.
- Any other installed skill (non-public, private, or local-only): requires approval as an exact entry below. Being installed is not permission.
- Secrets and excluded sensitive categories in `SKILL.md`: never allowed.

## Private repositories

| Exact owner/repository or canonical path | Approved scope | Approval reference | Date |
|---|---|---|---|

## Client objects and folders

| Exact object/folder | Approved scope | Approval reference | Date |
|---|---|---|---|

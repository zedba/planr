# Ticket format

## Filenames

```
.plan/
  epics/   <NN>-<slug>.md
  stories/ <NN>-<slug>.md
  tasks/   <NN>-<slug>.md
```

- **`NN`** — a 2-digit sort-hint prefix, monotonic *within each kind's
  directory* (`epics/`, `stories/`, `tasks/` each count independently). It
  gives stable `ls` / `git log` ordering. It is **not** the identity.
- **`slug`** — the human handle: short, kebab-case, no spaces, no slashes.
  Example: `http-connect-proxy`. The slug is the identity; frontmatter `id`
  repeats it for grep.
- Uniqueness is guaranteed by the tech lead being the sole creator (it can
  just `ls` the directory) and checked by `scripts/lint.sh` (a duplicate slug
  anywhere in the backlog is an error).

## Frontmatter (YAML)

```yaml
---
id: http-connect-proxy            # matches the filename slug
aliases: [http-connect-proxy]     # lets Obsidian resolve [[http-connect-proxy]]
kind: task                        # epic | story | task
parent: network-firewall          # parent slug; ABSENT for epics
title: Implement HTTP CONNECT allowlist proxy
status: todo                      # todo | in_progress | review | done | blocked
assignee: null                    # agent id when claimed; else null
created: 2025-07-29
updated: 2025-07-29
tags: [firewall, v1]              # optional
depends_on: []                    # slugs of any tickets that must be done first
---
```

### Fields

| Field | Required | Notes |
|---|---|---|
| `id` | yes | The slug; matches filename without `.md`. |
| `aliases` | no | `[<slug>]`, so Obsidian resolves `[[slug]]` links despite the `NN-` filename prefix. Never read by scripts. |
| `kind` | yes | `epic`, `story`, or `task`. |
| `parent` | stories & tasks | The parent's slug. Omit entirely for epics. `lint.sh` errors if the slug doesn't exist. |
| `title` | yes | Human-readable; may differ from slug. |
| `status` | yes | `todo` · `in_progress` · `review` · `done` · `blocked`. |
| `assignee` | no | Agent id when claimed; `null` otherwise. |
| `created` | yes | `YYYY-MM-DD`. |
| `updated` | yes | `YYYY-MM-DD`; bump on any edit. |
| `tags` | no | Free-form list. |
| `depends_on` | no | List of ticket slugs — **any** ticket, not just siblings — that must be `done` before this ticket is dispatchable. Enforced by `claim.sh`; shown as `BLOCKED-BY` on the board; `lint.sh` errors on dangling slugs, cycles, and non-inline lists (always write the inline `[a, b]` form — block-style YAML is not parsed). Prefer this over the `blocked` status for ordering within the plan. |

### Status lifecycle

```
todo  -->  in_progress  -->  review  -->  done
                |               |              ^
                +--> blocked <--+              |
                       |                       |
                       +------ (re-dispatch) --+
```

- `todo` — created on trunk, not yet dispatched.
- `in_progress` — a worker has claimed it (worktree branched). Also set by a
  reviewer who requests changes (back from `review`).
- `review` — worker has self-validated against `## Acceptance` and recorded
  `## Validation`; awaiting independent review.
- `done` — an independent reviewer approved (`## Review` verdict: approved)
  and the tech lead merged. Only ever appears on trunk after `merge-task.sh`.
- `blocked` — cannot proceed for a reason a dependency can't express (external
  decision, etc.); reason in `## Notes`. Prefer `depends_on` for sibling
  ordering.

**`review` → `done` is never self-served.** A worker sets `review`; a
reviewer's approved verdict + the tech lead's merge set `done`. The scripts
enforce this: `merge-task.sh` refuses a merge without `status: review` and an
approved `## Review` verdict.

## Body

Free-form markdown. Sections grow through the lifecycle:

```markdown
## Goal
One or two sentences on the desired outcome.

## Context
Links to the parent story and relevant code paths / files. Anything a worker
needs to orient.

## Acceptance
- [ ] concrete, checkable criteria
```
The worker adds, when self-validating:
```markdown
## Validation
- 2025-07-29 <who>: ran `cargo test --release firewall` -> 4 passed
- 2025-07-29 <who>: manually ran `examples/pi-bootstrap` against Gemini -> ok
```
The reviewer adds, after independently re-checking:
```markdown
## Review
verdict: approved          # or: changes-requested
reviewer: <agent id>
date: 2025-07-29
<what was re-checked and the result>
```

Epics and stories may omit `Acceptance`/`Validation`/`Review` (those live on
tasks) and instead carry a `## Scope` / `## Out of scope` section. Stories may
use `depends_on` for cross-story ordering.

### Wiki-links (soft references)

Bodies may reference other tickets with Obsidian-style links:

```markdown
## Context
Part of [[network-firewall]]. Builds on the resolver from
[[dns-allowlist|the DNS allowlist task]].

## Notes
- 2025-07-29 discovered while implementing [[http-connect-proxy]]
```

The target is the **slug** (not the `NN-` filename); `|label` and `#heading`
suffixes are fine. Links are soft context — related work, discovered-from,
supersedes — and are **never parsed by scripts**: ordering/gating lives only
in `depends_on`, hierarchy only in `parent`. Backlinks are derived, not
stored: `grep -rn '\[\[<slug>' .plan/`. `lint.sh` warns (never errors) on a
link that matches no ticket slug, since links may legitimately point at
non-ticket notes. The `aliases` frontmatter field makes `[[slug]]` resolve in
Obsidian, so `.plan/` doubles as a vault (graph view + backlinks as a free
read-only UI over the working tree).

### Review verdict format (machine-checked)

`merge-task.sh` parses the `## Review` section for a `verdict:` line. Use
exactly:
```markdown
verdict: approved
```
or
```markdown
verdict: changes-requested
```
If a second review round occurs, append a new `## Review` block dated beneath
the first (do not delete history); `merge-task.sh` reads the *last* `## Review`
block's verdict.

## Examples

See [../templates/](../templates/) for starter files of each kind.

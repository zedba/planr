# The plan process

## Why this design

The goal is a backlog system where **two agents working two different tickets
never edit the same file**. That property lets any number of workers run in
parallel worktrees without coordination overhead, and it lets merges be
trivial (no plan-bookkeeping conflicts).

Three rules deliver it:

1. **One file per ticket.** All mutable state for a ticket lives in that
   ticket's file.
2. **Downward is stored in the child.** A task names its parent story and its
   `depends_on` prerequisites in frontmatter; a story names its parent epic.
   The parent never records child state. So updating a child never touches its
   parent or any other ticket.
3. **Roll-up is derived, never stored.** A story's progress is computed by
   scanning its child task files on trunk; an epic's by scanning its stories.
   Nobody edits a parent to reflect child progress.

Combined with worktrees, rule 2 means each task branch modifies exactly one
`.plan/` file (its own) plus code — so rebasing or merging alongside other
task branches is conflict-free in `.plan/`. (Code conflicts between two tasks
editing the same source file can still happen — and should: that signals real
overlap between tasks, not a bookkeeping failure to paper over.)

## Roles

- **Tech lead** (foreground, with the developer) — sole writer to the backlog:
  creates tickets, sets `depends_on`, dispatches workers and reviewers, merges
  approved branches. Does not implement or review.
- **Worker** — implements one task in a worktree; self-validates; sets
  `review`. Does not set `done`.
- **Reviewer** — fresh-context, independent; re-runs acceptance checks; edits
  only the task file's `## Review` section with a `verdict`. Does not edit
  code.

## Trunk is the board (plus open branches)

Trunk (default `main`; `PLAN_TRUNK` to override) is the single source of truth
for what tickets exist and their merged statuses. A worktree branch only sees
tickets that existed when it was cut, so workers must read the board from
trunk, not their checkout. `scripts/board.sh` does this read-only via
`git show trunk:.plan/...` for the backlog **and** scans `plan/*` branches for
in-flight status — so a task a worker has flipped to `review` on its branch
shows up as "ready for review" immediately, without waiting for merge.

## Definition of done (no honor system)

`review` → `done` requires an **independent reviewer**, not the worker's say-so:

1. **Worker completes** implementation and self-validates every `## Acceptance`
   criterion, recording what was checked in a `## Validation` section (commands
   + results). Sets `status: review`. Commits on the task branch.
2. **Reviewer (fresh context)** reads the task, the diff, and `## Validation`,
   then **runs the acceptance checks itself** in the worktree. It edits only
   the task file:
   - `verdict: approved` → leaves `status: review`, adds `## Review`, commits.
   - `verdict: changes-requested` → adds `## Review`, flips `status: in_progress`,
     commits. The tech lead re-dispatches the worker.
3. **Tech lead merges** with `merge-task.sh`, which requires both
   `status: review` **and** an approved `## Review` verdict, then flips the
   task to `done` on trunk as part of the merge.

A worker setting `status: review` without a `## Validation` section, or a
merge without an approved verdict, is refused by the scripts. This is the
guardrail against the most common agent failure mode: declaring done on the
honor system.

## Dependencies (one graph, any ticket to any ticket)

A ticket declares what must be `done` before it, via frontmatter:
```yaml
depends_on: [http-connect-proxy, wire-firewall-into-cli]
```
These are slugs of **any** tickets in the backlog — most often siblings under
the same story, but cross-story and cross-epic edges are equally valid (the
scripts resolve a dep slug across `epics/`, `stories/`, and `tasks/`).
Hierarchy (`parent`) and ordering (`depends_on`) are independent relations:
`parent` structures the backlog for roll-up; `depends_on` gates dispatch.
Together they form one dependency graph over the whole backlog. Enforcement:

- **`claim.sh`** refuses to create a worktree for a task whose `depends_on`
  are not all `status: done` on trunk, printing the blockers. So a worker is
  never dispatched onto a task whose prerequisites are unfinished.
- **`board.sh`** shows a `BLOCKED-BY` column for tasks: any dep not `done` on
  trunk is listed, so the tech lead can see at a glance what's ready versus
  what's waiting.
- **`lint.sh`** keeps the graph sound: a `depends_on` slug that doesn't exist
  (a gate nothing can satisfy), a dangling `parent` (an orphan that roll-up
  would silently miss), a duplicate slug, a `depends_on` **cycle** (nothing
  in the cycle can ever become ready), or a `depends_on` written as a
  block-style YAML list (the scripts parse only the inline `[a, b]` form —
  block-style deps would silently stop gating) are all errors. Run it after
  any frontmatter edit; `new-ticket.sh` and `claim.sh` also run it
  informationally.
- `blocked` (the status) is still available for *ad-hoc* blockers a dependency
  can't express (an external decision, a bug in a dep outside this plan). Put
  the reason in `## Notes`. Prefer `depends_on` for ordering within the plan.

Dependencies are set/edited by the tech lead on trunk (a backlog edit), never
by workers on a task branch.

## Workflow

### Planning (tech lead + developer, on trunk)

1. Read the board: `./scripts/board.sh`.
2. Create tickets with `scripts/new-ticket.sh`, fill bodies, set `depends_on`
   in frontmatter for ordering, run `scripts/lint.sh`, commit.
3. Dispatch ready tasks (deps `done`) via `scripts/claim.sh`; hand each
   worktree to a worker.

### Execution (worker, in a worktree)

1. Work in the assigned worktree; `claim.sh` set `status: in_progress`.
2. Read the task + parent story; note `depends_on` (already verified `done`).
3. Edit only your task file + code.
4. Implement; log to `## Notes`.
5. Self-validate every `## Acceptance` item; record `## Validation`; set
   `status: review`; commit; hand back.

### Review (reviewer, fresh context, in the worktree)

1. `scripts/review.sh <slug>` prints branch, worktree, acceptance, and diff.
2. Run the acceptance checks yourself.
3. Edit only the task file's `## Review`: `verdict: approved` (leave
   `status: review`) or `verdict: changes-requested` (flip `status: in_progress`).
4. Commit; hand back.

### Integration (tech lead, on trunk)

1. `scripts/merge-task.sh <slug>`:
   - requires `status: review` + `verdict: approved` (refuses otherwise with
     guidance);
   - `git merge --no-ff`; on conflict, aborts, lists conflicted files, and
     prints rebase guidance for the worker (worktree + branch preserved);
   - on success, flips the task to `done` on trunk, removes the worktree,
     deletes the branch.
2. Re-branch the next round of workers from fresh trunk.

## Concurrency notes

- **Claiming a task** = branching a worktree. No locks: two agents cannot both
  write the same task file because they're in separate checkouts on separate
  branches. `status: in_progress` is a record, not a coordination primitive.
- **Ticket creation** is racy only if workers create tickets. They don't —
  only the tech lead does, in a single sequential session.
- **Review is independent** by construction: the reviewer runs fresh-context
  and reads the worktree, so it is not influenced by the worker's session.
- **Reading the board** is always safe: `git show` / `git branch` are
  read-only and never block writers.

## Edge cases

- **A worker discovers missing work.** It does *not* create a ticket. It
  records the gap in its task's `## Notes` for the tech lead to triage.
- **A task needs to split.** The worker finishes or pauses, hands back the
  branch; the tech lead creates the new sub-tasks on trunk (with
  `depends_on` as needed) and re-dispatches.
- **Two tasks touch the same code.** Let them conflict at merge time — that's
  a real signal the tasks overlap. `merge-task.sh` aborts and tells the worker
  to rebase onto fresh trunk; resolve by sequencing (merge one, rebase the
  other) or by re-splitting the work in planning.
- **Review requests changes.** The branch stays alive with `status: in_progress`
  and a `changes-requested` verdict; the tech lead re-dispatches the worker to
  the same worktree. The worker addresses the notes, re-validates, and sets
  `review` again (the reviewer's earlier `## Review` stays in the file as a
  record; the new review appends a second `## Review` block or amends —
  convention: append a dated block so the history is visible).
- **Renaming a story/epic.** The parent link is in frontmatter (not the
  filename), so renaming a story's file only requires updating `parent:` in its
  child tasks and any `depends_on` that reference it — a small, well-contained
  edit the tech lead does on trunk. Run `scripts/lint.sh` afterwards: it
  errors on any `parent`/`depends_on` still pointing at the old slug and warns
  on stale `[[wiki-links]]`.
- **No trunk yet / fresh repo.** `scripts/new-ticket.sh` writes to the working
  tree; commit `.plan/` to trunk before any `claim.sh` so workers branch from a
  backlog that exists.

## What this scheme deliberately does not have

- **No central `index.md` / `board.md` as source of truth.** A board file is a
  derived view; if you commit one, treat it as a regenerable snapshot.
- **No lock files or claim markers.** The branch is the claim.
- **No hierarchical filenames** (`E01/S02/T03`). Flat slugs per kind keep
  renames cheap and `git log` readable; the parent link lives in frontmatter.
- **No worker-created tickets.** Creation is the tech lead's job, which makes
  allocation race-free.
- **No self-merge.** `done` requires an independent reviewer's approved
  verdict; the scripts enforce it.
- **No load-bearing links.** Body `[[wiki-links]]` are soft references for
  humans, agents, and Obsidian; no script reads them. Gating lives only in
  `depends_on`, hierarchy only in `parent` — both in frontmatter, both
  checked by `lint.sh`. Links are sugar, never state; backlinks are derived
  (`grep`), never stored.

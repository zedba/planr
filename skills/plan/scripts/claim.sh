#!/usr/bin/env bash
# Create a worktree branch for a task and flip it to in_progress.
# Refuses if the task's depends_on are not all `done` on trunk.
#
# Usage: claim.sh <task-slug> [worktree-path] [trunk]
# Env:   PLAN_TRUNK (default main), PLAN_DIR (default .plan)
#
# Creates branch plan/<slug> in a new worktree (default ../wt-<slug>) off
# trunk, verifies dependencies are done, sets the task's status: in_progress
# and bumps updated:, and commits that flip on the task branch. Prints the
# worktree path (only).
set -euo pipefail

slug="${1:?task slug required}"
wt="${2:-../wt-$slug}"
trunk="${3:-${PLAN_TRUNK:-main}}"
plan="${PLAN_DIR:-.plan}"
branch="plan/$slug"

path=$(git ls-tree -r --name-only "$trunk" -- "$plan/tasks" 2>/dev/null \
       | grep -E -- "/[0-9]+-${slug}\.md$" | head -n1 || true)
[[ -z "$path" ]] && { echo "no task file for slug '$slug' on $trunk" >&2; exit 1; }

# Informational backlog lint of trunk (dangling refs, cycles) on stderr; the
# authoritative gate is the per-task dependency check below.
here="$(cd "$(dirname "$0")" && pwd)"
"$here/lint.sh" "$trunk" >&2 || true

# Dependency check: every depends_on prerequisite (any ticket, not just a
# sibling) must be status: done on trunk.
deps=$(git show "$trunk:$path" | awk '
  /^---$/ { f = !f; next }
  f && /^depends_on:/ {
    sub(/^depends_on:[[:space:]]*/, "")
    gsub(/^\[|\]$/, ""); gsub(/[[:space:]]/, "")
    n = split($0, a, ",")
    for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
    exit
  }
')
if [[ -n "$deps" ]]; then
  blockers=""
  for d in $deps; do
    dst=""
    for kd in epics stories tasks; do
      df=$(git ls-tree -r --name-only "$trunk" -- "$plan/$kd" 2>/dev/null \
           | grep -E -- "/[0-9]+-${d}\.md$" | head -n1 || true)
      [[ -n "$df" ]] && { dst=$(git show "$trunk:$df" | awk '/^---$/{f=!f;next} f&&/^status:/{sub(/^status:[[:space:]]*/,"");print;exit}'); break; }
    done
    [[ "$dst" != "done" ]] && blockers="$blockers $d($dst)"
  done
  if [[ -n "$blockers" ]]; then
    echo "refuse claim: '$slug' has unfinished depends_on:${blockers}" >&2
    echo "resolve or complete these first, or have the tech lead update depends_on." >&2
    exit 1
  fi
fi

git worktree add -b "$branch" "$wt" "$trunk" >/dev/null

date="$(date +%F)"
(
  cd "$wt"
  sed -i -E \
    -e "s/^status: .*/status: in_progress/" \
    -e "s/^updated: .*/updated: $date/" \
    "$path"
  git add "$path"
  git commit -m "plan: claim $slug (in_progress)" >/dev/null
)

echo "$wt"

#!/usr/bin/env bash
# Scaffold a new ticket file from a template. Run on trunk (tech lead only).
#
# Usage: new-ticket.sh <kind> <slug> <title> [parent-slug]
# Env:   PLAN_DIR (default .plan)
#
# Writes <plan>/<kind-plural>/<NN>-<slug>.md with frontmatter filled and
# prints the path. The caller then fills the body and commits. The parent slug
# is required for stories and tasks (and must already exist); ignored for
# epics. Runs lint.sh afterwards, informationally, on stderr.
set -euo pipefail

kind="${1:?kind required: epic|story|task}"
slug="${2:?slug required}"
title="${3:?title required}"
parent="${4:-}"

plan="${PLAN_DIR:-.plan}"
case "$kind" in
  epic)  subdir="epics" ;;
  story) subdir="stories" ;;
  task)  subdir="tasks" ;;
  *) echo "unknown kind: $kind (want epic|story|task)" >&2; exit 1 ;;
esac

# Slugs are identity: every script greps for them, and [[wiki-links]] target
# them, so keep them to kebab-case.
if [[ ! "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "bad slug '$slug': want kebab-case ([a-z0-9-], starting with [a-z0-9])" >&2
  exit 1
fi

if [[ "$kind" != "epic" && -z "$parent" ]]; then
  echo "parent slug required for $kind" >&2
  exit 1
fi

# The parent must already exist (any kind) — a dangling parent orphans the
# child, since roll-up is derived by scanning children for their parent slug.
if [[ -n "$parent" && "$kind" != "epic" ]]; then
  found=""
  for kd in epics stories tasks; do
    if ls "$plan/$kd" 2>/dev/null | grep -qE "^[0-9]+-${parent}\.md$"; then
      found=1
      break
    fi
  done
  if [[ -z "$found" ]]; then
    echo "parent '$parent' not found under $plan/ — create the parent first" >&2
    exit 1
  fi
fi

dir="$plan/$subdir"
mkdir -p "$dir"
last=$(ls "$dir" 2>/dev/null | grep -oE '^[0-9]+' | sort -n | tail -1 || true)
nn=$(printf '%02d' $((10#${last:-0} + 1)))
path="$dir/${nn}-${slug}.md"

[[ -e "$path" ]] && { echo "already exists: $path" >&2; exit 1; }

here="$(cd "$(dirname "$0")" && pwd)"
template="$here/../templates/${kind}.md"
date="$(date +%F)"

# Escape a string for use in a perl s||| replacement: backslash, $, @, and the
# delimiter | are special and must be backslash-escaped.
repl_escape() { printf '%s' "$1" | perl -pe 's/([\\$@|])/\\$1/g'; }

slug_e=$(repl_escape "$slug")
title_e=$(repl_escape "$title")
parent_e=$(repl_escape "$parent")

# Copy first, then edit only the destination (never the template).
cp "$template" "$path"
perl -i -pe "
  s|__SLUG__|$slug_e|g;
  s|__TITLE__|$title_e|g;
  s|__PARENT__|$parent_e|g;
  s|__DATE__|$date|g;
" "$path"

# Informational backlog-wide lint (dangling refs, cycles) on stderr. The new
# ticket itself is valid by construction; pre-existing issues don't block it.
"$here/lint.sh" >&2 || true

echo "$path"

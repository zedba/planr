#!/usr/bin/env bash
# Lint the backlog: reference and structure checks the other scripts rely on.
#
# Usage: lint.sh [ref]
#        No argument: lint the working tree's $PLAN_DIR (what you just edited).
#        With a git ref (e.g. main): lint the backlog as committed on that ref.
# Env:   PLAN_DIR (default .plan)
#
# Errors (exit 1) — these break claiming, roll-up, or merging:
#   - missing id, or id not matching the filename slug
#   - duplicate slug anywhere in the backlog (slugs are identity)
#   - kind not matching the directory; invalid status
#   - epic with a parent; story/task without one; a parent slug that
#     doesn't exist (derived roll-up would silently orphan the child)
#   - depends_on slug that doesn't exist (a gate nothing can ever satisfy)
#   - depends_on cycle (nothing in the cycle can ever be claimed)
#   - depends_on without an inline [a, b] value (block-style YAML lists are
#     not parsed by any script, so the deps would silently stop gating)
# Warnings (exit 0) — worth a look, may be intentional:
#   - parent of an unexpected kind (a task's parent is usually a story,
#     a story's an epic)
#   - a body [[wiki-link]] that matches no ticket slug (links are soft
#     references; fine if it points at a non-ticket note)
#
# Prints nothing and exits 0 on a clean backlog.
set -euo pipefail

ref="${1:-}"
plan="${PLAN_DIR:-.plan}"

errors=0
warnings=0
error() { echo "error: $*"; errors=$((errors + 1)); }
warn()  { echo "warning: $*"; warnings=$((warnings + 1)); }

list_files() {
  if [[ -n "$ref" ]]; then
    git ls-tree -r --name-only "$ref" -- "$plan/epics" "$plan/stories" "$plan/tasks" 2>/dev/null \
      | grep -E '\.md$' || true
  else
    local d
    for d in "$plan/epics" "$plan/stories" "$plan/tasks"; do
      if [[ -d "$d" ]]; then
        find "$d" -maxdepth 1 -name '*.md' | sort
      fi
    done
  fi
}

read_file() {
  if [[ -n "$ref" ]]; then git show "$ref:$1"; else cat "$1"; fi
}

fm_field() {
  awk -v k="$1" '
    /^---$/ { f = !f; next }
    f && $0 ~ "^" k ":" {
      sub("^" k ":[[:space:]]*", "")
      sub(/[[:space:]]+$/, "")
      print
      exit
    }
  '
}

# Parse a YAML inline list value like "depends_on: [a, b]" -> one slug per line.
fm_list() {
  awk -v k="$1" '
    /^---$/ { f = !f; next }
    f && $0 ~ "^" k ":" {
      sub("^" k ":[[:space:]]*", "")
      gsub(/^\[|\]$/, "")
      gsub(/[[:space:]]/, "")
      n = split($0, a, ",")
      for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
      exit
    }
  '
}

declare -A file_of kind_of parent_of deps_of links_of

files=$(list_files)
[[ -z "$files" ]] && exit 0

# Pass 1: parse every ticket; per-file checks that need no cross-references.
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  blob=$(read_file "$f")

  base="${f##*/}"; base="${base%.md}"
  fslug=$(printf '%s' "$base" | sed -E 's/^[0-9]+-//')
  case "$f" in
    */epics/*)   dkind="epic" ;;
    */stories/*) dkind="story" ;;
    */tasks/*)   dkind="task" ;;
    *)           dkind="" ;;
  esac

  id=$(printf '%s' "$blob" | fm_field id)
  kind=$(printf '%s' "$blob" | fm_field kind)
  status=$(printf '%s' "$blob" | fm_field status)

  if [[ -z "$id" ]]; then
    error "$f: missing id in frontmatter"
    id="$fslug"
  elif [[ "$id" != "$fslug" ]]; then
    error "$f: id '$id' does not match filename slug '$fslug'"
  fi
  if [[ -n "$dkind" && "$kind" != "$dkind" ]]; then
    error "$f: kind '${kind:-<missing>}' but the file lives in the ${dkind}s directory"
  fi
  case "$status" in
    todo|in_progress|review|done|blocked) ;;
    *) error "$f: invalid status '${status:-<missing>}' (want todo|in_progress|review|done|blocked)" ;;
  esac

  # A depends_on with no inline value (block-style YAML list, or a bare
  # "depends_on:") parses as empty here AND in claim.sh — the deps would
  # silently stop gating. Must be loud: that is the one failure mode the
  # dependency graph cannot survive.
  if printf '%s' "$blob" | awk '
       /^---$/ { f = !f; next }
       f && /^depends_on:[[:space:]]*$/ { bad = 1; exit }
       END { exit !bad }
     '; then
    error "$f: depends_on has no inline value — write depends_on: [a, b] (or []); block-style lists are not parsed and would silently disable gating"
  fi

  if [[ -n "${file_of[$id]:-}" ]]; then
    error "$f: duplicate slug '$id' (also ${file_of[$id]}) — slugs are identity and must be unique across the backlog"
    continue
  fi
  file_of[$id]="$f"
  kind_of[$id]="$kind"
  parent_of[$id]=$(printf '%s' "$blob" | fm_field parent)
  deps_of[$id]=$(printf '%s' "$blob" | fm_list depends_on | tr '\n' ' ')
  # Body [[wiki-link]] targets, one per line; strip |alias and #heading parts.
  links_of[$id]=$(printf '%s' "$blob" | grep -oE '\[\[[^]]+\]\]' \
    | sed -E 's/^\[\[//; s/\]\]$//; s/[|#].*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' \
    | sort -u || true)
done <<< "$files"

# Pass 2: cross-reference checks (parents, deps, links).
for id in $(printf '%s\n' "${!file_of[@]}" | sort); do
  f="${file_of[$id]}"
  kind="${kind_of[$id]}"
  parent="${parent_of[$id]}"

  if [[ "$kind" == "epic" ]]; then
    if [[ -n "$parent" && "$parent" != "null" ]]; then
      error "$f: epics must not have a parent (found '$parent')"
    fi
  else
    if [[ -z "$parent" || "$parent" == "null" ]]; then
      error "$f: a $kind must name a parent slug"
    elif [[ -z "${file_of[$parent]:-}" ]]; then
      error "$f: parent '$parent' does not exist — roll-up is derived by scanning children, so this $kind would be orphaned"
    else
      expected="story"
      [[ "$kind" == "story" ]] && expected="epic"
      if [[ "${kind_of[$parent]}" != "$expected" ]]; then
        warn "$f: parent '$parent' is a ${kind_of[$parent]} (a $kind's parent is usually a $expected)"
      fi
    fi
  fi

  for d in ${deps_of[$id]:-}; do
    if [[ "$d" == "$id" ]]; then
      error "$f: depends_on itself"
    elif [[ -z "${file_of[$d]:-}" ]]; then
      error "$f: depends_on '$d' does not exist — claim.sh could never be satisfied"
    fi
  done

  if [[ -n "${links_of[$id]:-}" ]]; then
    while IFS= read -r l; do
      [[ -z "$l" ]] && continue
      if [[ -z "${file_of[$l]:-}" ]]; then
        warn "$f: [[${l}]] matches no ticket slug (fine if it points at a non-ticket note)"
      fi
    done <<< "${links_of[$id]}"
  fi
done

# Pass 3: depends_on cycle detection (DFS; each cycle reported once).
declare -A color
declare -a stack=()
visit() {
  local n="$1"
  local c="${color[$n]:-w}"
  [[ "$c" == "b" ]] && return 0
  if [[ "$c" == "g" ]]; then
    local cyc="" s started=0
    for s in ${stack[@]+"${stack[@]}"}; do
      [[ "$s" == "$n" ]] && started=1
      [[ "$started" == 1 ]] && cyc+="$s -> "
    done
    error "depends_on cycle: ${cyc}${n} — nothing in the cycle can ever be claimed"
    return 0
  fi
  color[$n]="g"
  stack+=("$n")
  local d
  for d in ${deps_of[$n]:-}; do
    if [[ -n "${file_of[$d]:-}" ]]; then
      visit "$d"
    fi
  done
  color[$n]="b"
  unset 'stack[-1]'
  return 0
}
for id in $(printf '%s\n' "${!file_of[@]}" | sort); do
  visit "$id"
done

if (( errors > 0 || warnings > 0 )); then
  echo "lint: $errors error(s), $warnings warning(s)"
fi
if (( errors > 0 )); then
  exit 1
fi
exit 0

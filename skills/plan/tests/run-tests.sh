#!/usr/bin/env bash
# End-to-end tests for the plan skill scripts, run in a throwaway git repo.
#
# Usage: tests/run-tests.sh [sandbox-dir]
#        With no argument, uses a fresh mktemp dir (removed on success, kept
#        and printed on failure). An explicit sandbox-dir must not exist yet
#        and is always kept.
#
# Covers: ticket creation guards (dangling parent, bad slug), template
# alias fill, cross-story depends_on gating through claim.sh, every lint.sh
# error class, lint warning-vs-error exit codes, ref-mode lint, and the
# stdout/stderr contract of new-ticket.sh.
set -uo pipefail

skill="$(cd "$(dirname "$0")/.." && pwd)"

keep=0
if [[ -n "${1:-}" ]]; then
  root="$1"
  if [[ -e "$root" ]]; then
    echo "refusing to test in existing path: $root" >&2
    exit 1
  fi
  keep=1
else
  root="$(mktemp -d)"
fi
repo="$root/repo"
mkdir -p "$repo"
cd "$repo"

pass=0; fail=0
check() { # check <desc> <expected-exit> <actual-exit>
  if [[ "$2" == "$3" ]]; then pass=$((pass+1)); echo "PASS: $1";
  else fail=$((fail+1)); echo "FAIL: $1 (want exit $2, got $3)"; fi
}
contains() { # contains <desc> <needle> <file>
  if grep -qF "$2" "$3"; then pass=$((pass+1)); echo "PASS: $1";
  else fail=$((fail+1)); echo "FAIL: $1 (no '$2' in $3)"; cat "$3"; fi
}

git init -q -b main .
git config user.email plan-tests@example.invalid
git config user.name "plan tests"
git commit -q --allow-empty -m init

out="$root/out"; errf="$root/err"

# --- new-ticket guards ---
"$skill/scripts/new-ticket.sh" task bad "Orphan" no-such-parent >"$out" 2>"$errf"
check "new-ticket refuses dangling parent" 1 $?
contains "  ...with a clear message" "create the parent first" "$errf"

"$skill/scripts/new-ticket.sh" epic "Bad Slug!" "Nope" >"$out" 2>"$errf"
check "new-ticket refuses non-kebab slug" 1 $?

# --- happy path: epic -> two stories -> tasks, cross-story dep ---
"$skill/scripts/new-ticket.sh" epic v1 "Ship v1" >"$out" 2>"$errf"
check "create epic" 0 $?
"$skill/scripts/new-ticket.sh" story net-firewall "Network firewall" v1 >"$out" 2>"$errf"
check "create story 1" 0 $?
"$skill/scripts/new-ticket.sh" story cli-wiring "CLI wiring" v1 >"$out" 2>"$errf"
check "create story 2" 0 $?
"$skill/scripts/new-ticket.sh" task http-proxy "HTTP proxy" net-firewall >"$out" 2>"$errf"
check "create task 1" 0 $?
"$skill/scripts/new-ticket.sh" task wire-cli "Wire into CLI" cli-wiring >"$out" 2>"$errf"
check "create task 2 (other story)" 0 $?

grep -q 'aliases: \[http-proxy\]' .plan/tasks/01-http-proxy.md
check "template fills aliases with slug" 0 $?

# cross-story dep: wire-cli (story cli-wiring) depends on http-proxy (story net-firewall)
sed -i 's/^depends_on: \[\]/depends_on: [http-proxy]/' .plan/tasks/02-wire-cli.md
cat >> .plan/tasks/02-wire-cli.md <<'EOF'

Extra context: builds on [[http-proxy|the proxy task]] under [[net-firewall]].
EOF

"$skill/scripts/lint.sh" >"$out" 2>&1
check "lint clean backlog (cross-story dep, valid links)" 0 $?
if [[ -s "$out" ]]; then fail=$((fail+1)); echo "FAIL: lint not silent on clean backlog:"; cat "$out";
else pass=$((pass+1)); echo "PASS: lint silent on clean backlog"; fi

git add .plan && git commit -qm "backlog"

# --- ref mode ---
"$skill/scripts/lint.sh" main >"$out" 2>&1
check "lint ref mode (main) clean" 0 $?

# --- claim: cross-story dep gates ---
"$skill/scripts/claim.sh" wire-cli ../wt-wire-cli >"$out" 2>"$errf"
check "claim refused while cross-story dep not done" 1 $?
contains "  ...naming the blocker" "http-proxy(todo)" "$errf"

sed -i 's/^status: todo/status: done/' .plan/tasks/01-http-proxy.md
git add .plan && git commit -qm "http-proxy done"
"$skill/scripts/claim.sh" wire-cli ../wt-wire-cli >"$out" 2>"$errf"
check "claim succeeds once cross-story dep done" 0 $?
contains "  ...prints worktree path" "wt-wire-cli" "$out"
git worktree remove --force ../wt-wire-cli 2>/dev/null
git branch -qD plan/wire-cli 2>/dev/null

# --- lint error classes (working tree edits, not committed) ---
sed -i 's/^depends_on: \[http-proxy\]/depends_on: [ghost-task]/' .plan/tasks/02-wire-cli.md
"$skill/scripts/lint.sh" >"$out" 2>&1
check "lint errors on dangling depends_on" 1 $?
contains "  ...names the ghost" "depends_on 'ghost-task' does not exist" "$out"
sed -i 's/^depends_on: \[ghost-task\]/depends_on: [http-proxy]/' .plan/tasks/02-wire-cli.md

# Block-style depends_on parses as empty in lint.sh AND claim.sh — the dep
# would silently stop gating, so lint must error even though the dep exists.
sed -i 's/^depends_on: \[http-proxy\]/depends_on:\n  - http-proxy/' .plan/tasks/02-wire-cli.md
"$skill/scripts/lint.sh" >"$out" 2>&1
check "lint errors on block-style depends_on" 1 $?
contains "  ...saying gating would be disabled" "silently disable gating" "$out"
sed -i -e '/^  - http-proxy$/d' -e 's/^depends_on:$/depends_on: [http-proxy]/' .plan/tasks/02-wire-cli.md

sed -i 's/^depends_on: \[\]/depends_on: [wire-cli]/' .plan/tasks/01-http-proxy.md
"$skill/scripts/lint.sh" >"$out" 2>&1
check "lint errors on dependency cycle" 1 $?
contains "  ...prints the cycle" "depends_on cycle" "$out"
sed -i 's/^depends_on: \[wire-cli\]/depends_on: []/' .plan/tasks/01-http-proxy.md

sed -i 's/^parent: cli-wiring/parent: gone-story/' .plan/tasks/02-wire-cli.md
"$skill/scripts/lint.sh" >"$out" 2>&1
check "lint errors on dangling parent" 1 $?
contains "  ...says orphaned" "parent 'gone-story' does not exist" "$out"
sed -i 's/^parent: gone-story/parent: cli-wiring/' .plan/tasks/02-wire-cli.md

sed -i 's/^parent: cli-wiring/parent: http-proxy/' .plan/tasks/02-wire-cli.md
"$skill/scripts/lint.sh" >"$out" 2>&1
check "wrong-kind parent is only a warning (exit 0)" 0 $?
contains "  ...warns" "usually a story" "$out"
sed -i 's/^parent: http-proxy/parent: cli-wiring/' .plan/tasks/02-wire-cli.md

cp .plan/tasks/01-http-proxy.md .plan/tasks/03-http-proxy.md
"$skill/scripts/lint.sh" >"$out" 2>&1
check "lint errors on duplicate slug" 1 $?
contains "  ...says duplicate" "duplicate slug 'http-proxy'" "$out"
rm .plan/tasks/03-http-proxy.md

echo 'See [[no-such-note]] for background.' >> .plan/stories/01-net-firewall.md
"$skill/scripts/lint.sh" >"$out" 2>&1
check "unknown [[link]] is only a warning (exit 0)" 0 $?
contains "  ...mentions the link" "[[no-such-note]] matches no ticket slug" "$out"
git checkout -q .plan/stories/01-net-firewall.md

sed -i 's/^status: done/status: finished/' .plan/tasks/01-http-proxy.md
"$skill/scripts/lint.sh" >"$out" 2>&1
check "lint errors on invalid status" 1 $?
sed -i 's/^status: finished/status: done/' .plan/tasks/01-http-proxy.md

# --- new-ticket runs lint informationally: create a dangling dep first ---
sed -i 's/^depends_on: \[http-proxy\]/depends_on: [ghost-task]/' .plan/tasks/02-wire-cli.md
"$skill/scripts/new-ticket.sh" task another "Another" net-firewall >"$out" 2>"$errf"
check "new-ticket still succeeds with pre-existing lint errors" 0 $?
contains "  ...but surfaces them on stderr" "ghost-task" "$errf"
contains "  ...and stdout stays just the path" ".plan/tasks/03-another.md" "$out"
if [[ $(wc -l <"$out") -eq 1 ]]; then pass=$((pass+1)); echo "PASS: stdout is exactly one line";
else fail=$((fail+1)); echo "FAIL: stdout polluted"; cat "$out"; fi

echo
echo "=== $pass passed, $fail failed ==="
if [[ $fail -eq 0 ]]; then
  if [[ $keep -eq 0 ]]; then rm -rf "$root"; else echo "sandbox kept at $root"; fi
  exit 0
fi
echo "sandbox kept for inspection at $root"
exit 1

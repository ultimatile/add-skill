#!/bin/bash
#
# Smoke tests for add-skill.
#
# Covers the failure contract: a skill that cannot be installed is reported and
# aborts the run with a non-zero status, and nothing ever waits for input.
#
# Usage:
#   tests/smoke.sh
#   ADD_SKILL=/path/to/add-skill tests/smoke.sh
#
# Targets bash 3.2 (the /bin/bash macOS ships), so no associative arrays,
# mapfile, or ${var^^}.

set -u

ADD_SKILL="${ADD_SKILL:-$(cd "$(dirname "$0")/.." && pwd)/add-skill}"

PASS=0
FAIL=0
WORK=""

cleanup() {
  # A test that leaves the destination unwritable would otherwise defeat rm.
  [ -n "$WORK" ] && [ -d "$WORK" ] && chmod -R u+w "$WORK" 2>/dev/null
  [ -n "$WORK" ] && rm -rf "$WORK"
}
trap cleanup EXIT

ok() {
  PASS=$((PASS + 1))
  echo "  ok   - $1"
}

no() {
  FAIL=$((FAIL + 1))
  echo "  FAIL - $1"
  [ $# -gt 1 ] && echo "         $2"
}

# assert_contains <label> <file> <pattern>
assert_contains() {
  if grep -q "$3" "$2"; then
    ok "$1"
  else
    no "$1" "expected /$3/ in $(basename "$2"), got: $(tr '\n' '|' <"$2" | cut -c1-200)"
  fi
}

# assert_absent <label> <file> <pattern>
assert_absent() {
  if grep -q "$3" "$2"; then
    no "$1" "unexpected /$3/ in $(basename "$2")"
  else
    ok "$1"
  fi
}

# assert_true <label> <command...>  — the command's own status is the verdict
assert_true() {
  local label=$1
  shift
  if "$@"; then
    ok "$label"
  else
    no "$label"
  fi
}

# assert_status <label> <expected: zero|nonzero> <actual>
assert_status() {
  case "$2" in
  zero)
    if [ "$3" -eq 0 ]; then ok "$1"; else no "$1" "expected exit 0, got $3"; fi
    ;;
  nonzero)
    if [ "$3" -ne 0 ]; then ok "$1"; else no "$1" "expected non-zero exit, got $3"; fi
    ;;
  esac
}

# Poll until the pid exits. Returns 0 if it did within the budget, 1 otherwise.
wait_for_exit() {
  local pid=$1 tenths=$2 i=0
  while [ "$i" -lt "$tenths" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

reset_dest() {
  rm -rf "${DEST:?}"/*
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/add-skill-smoke.XXXXXX")"
SRC="$WORK/src"
DEST="$WORK/proj/.claude/skills"

for s in alpha bravo; do
  mkdir -p "$SRC/skills/$s"
  printf -- '---\nname: %s\ndescription: smoke fixture\n---\n' "$s" >"$SRC/skills/$s/SKILL.md"
done
mkdir -p "$DEST"

run() { # run <outfile> <errfile> <args...>
  local out=$1 err=$2
  shift 2
  (cd "$WORK/proj" && SKILLS_INSTALL_PATH="$DEST" "$ADD_SKILL" "$SRC" "$@" </dev/null >"$out" 2>"$err")
}

echo "add-skill smoke tests ($ADD_SKILL)"

echo "[install succeeds]"
reset_dest
run "$WORK/o" "$WORK/e" --symlink
assert_status "symlink install exits 0" zero $?
assert_true "alpha is a symlink" test -L "$DEST/alpha"
assert_true "bravo is a symlink" test -L "$DEST/bravo"

run "$WORK/o" "$WORK/e" --symlink
assert_status "re-running over the install exits 0" zero $?

run "$WORK/o" "$WORK/e" --symlink-force
assert_status "symlink-force exits 0" zero $?
assert_true "symlink-force leaves a symlink behind" test -L "$DEST/alpha"

reset_dest
run "$WORK/o" "$WORK/e"
assert_status "copy install exits 0" zero $?
assert_true "copy install produces a directory" test -d "$DEST/alpha"
assert_true "the copied skill is not a symlink" test ! -L "$DEST/alpha"

# README promises the destination is replaced in every mode, copy included, so
# a file left inside a previous copy must not survive the next one.
echo stale >"$DEST/alpha/stale.txt"
run "$WORK/o" "$WORK/e"
assert_status "re-running the copy install exits 0" zero $?
assert_true "the copy install replaces what was there" test ! -e "$DEST/alpha/stale.txt"

# An unwritable destination makes the link or the copy fail while nothing
# occupies the target, so the failure is never "the target already exists".
echo "[install fails]"
# Each spec is "label|flag|tool": the flag to pass (empty for the default copy
# mode) and the command whose own stderr must carry the reason. Kept as split
# strings because bash 3.2 has no associative arrays.
for spec in "--symlink|--symlink|ln" "--symlink-force|--symlink-force|ln" "copy mode||cp"; do
  label="${spec%%|*}"
  rest="${spec#*|}"
  flag="${rest%%|*}"
  tool="${rest#*|}"

  reset_dest
  chmod a-w "$DEST"
  if [ -n "$flag" ]; then
    run "$WORK/o" "$WORK/e" "$flag"
  else
    run "$WORK/o" "$WORK/e"
  fi
  status=$?
  chmod u+w "$DEST"

  assert_status "$label aborts with non-zero status" nonzero $status
  cat "$WORK/o" "$WORK/e" >"$WORK/both"
  assert_contains "$label names the skill it could not install" "$WORK/both" '\[ERROR\].*alpha'
  assert_contains "$label lets $tool report the reason on stderr" "$WORK/e" "^$tool:"
  assert_absent "$label asks no question" "$WORK/both" '(y/N)'
done

# A failure must stop the run rather than carry on to the remaining skills.
# Ask for a name the source does not have, followed by one it does.
echo "[a failure stops the run]"
reset_dest
run "$WORK/o" "$WORK/e" --symlink --skill nosuch --skill alpha
assert_status "an unknown skill aborts with non-zero status" nonzero $?
assert_true "the skill queued after the failure is not installed" test ! -e "$DEST/alpha"

# The failure path must not read from stdin. A fifo this script holds open
# delivers nothing and never signals end of file, so anything that reads it
# blocks instead of falling through. That blocking-with-no-EOF property is what
# an agent harness or a script(1)-style wrapper produces by handing the command
# a terminal nobody types into; the fifo reproduces it without needing one.
echo "[never waits for input]"
reset_dest
chmod a-w "$DEST"
mkfifo "$WORK/fifo"
exec 9<>"$WORK/fifo"
(cd "$WORK/proj" && SKILLS_INSTALL_PATH="$DEST" "$ADD_SKILL" "$SRC" --symlink <&9 >/dev/null 2>&1) &
blocked_pid=$!
if wait_for_exit "$blocked_pid" 50; then
  ok "exits on its own when stdin is open but silent"
else
  no "exits on its own when stdin is open but silent" "still running after 5s; killing"
  kill -9 "$blocked_pid" 2>/dev/null
fi
wait "$blocked_pid" 2>/dev/null
exec 9>&-
chmod u+w "$DEST"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]

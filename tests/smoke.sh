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

# assert_status <label> <expected: zero|nonzero> <actual>
assert_status() {
  case "$2" in
  zero) [ "$3" -eq 0 ] && ok "$1" || no "$1" "expected exit 0, got $3" ;;
  nonzero) [ "$3" -ne 0 ] && ok "$1" || no "$1" "expected non-zero exit, got $3" ;;
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
rm -rf "${DEST:?}"/*
run "$WORK/o" "$WORK/e" --symlink
assert_status "symlink install exits 0" zero $?
[ -L "$DEST/alpha" ] && [ -L "$DEST/bravo" ] &&
  ok "both skills are symlinks" || no "both skills are symlinks"

run "$WORK/o" "$WORK/e" --symlink
assert_status "re-running over the install exits 0" zero $?

run "$WORK/o" "$WORK/e" --symlink-force
assert_status "symlink-force exits 0" zero $?

rm -rf "${DEST:?}"/*
run "$WORK/o" "$WORK/e"
assert_status "copy install exits 0" zero $?
[ -d "$DEST/alpha" ] && [ ! -L "$DEST/alpha" ] &&
  ok "copy install produces a real directory" || no "copy install produces a real directory"

# An unwritable destination makes ln fail for a reason that is not "the target
# already exists" — the case the removed prompt used to claim.
echo "[install fails]"
for mode in --symlink --symlink-force; do
  rm -rf "${DEST:?}"/*
  chmod a-w "$DEST"
  run "$WORK/o" "$WORK/e" "$mode"
  status=$?
  chmod u+w "$DEST"

  assert_status "$mode aborts with non-zero status" nonzero $status
  cat "$WORK/o" "$WORK/e" >"$WORK/both"
  assert_contains "$mode names the skill it could not install" "$WORK/both" '\[ERROR\].*alpha'
  assert_contains "$mode lets ln report the reason on stderr" "$WORK/e" '^ln:'
  assert_absent "$mode asks no question" "$WORK/both" '(y/N)'
done

# The failure path must not read from stdin. A fifo held open by this script
# delivers nothing and never signals end of file, so anything that reads will
# block rather than fall through — which is what an agent harness or a
# script(1)-style wrapper hands the command.
echo "[never waits for input]"
rm -rf "${DEST:?}"/*
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

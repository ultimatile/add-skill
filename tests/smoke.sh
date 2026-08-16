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

# assert_false <label> <command...>
assert_false() {
  local label=$1
  shift
  if "$@"; then
    no "$label"
  else
    ok "$label"
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

# Without set -e a failed mktemp would leave WORK empty and every path below
# would resolve against the filesystem root.
# TMPDIR conventionally carries a trailing slash, which would leave every path
# below with a doubled separator that cd collapses and a string compare does not.
tmp_root="${TMPDIR:-/tmp}"
while [ "${tmp_root%/}" != "$tmp_root" ]; do
  tmp_root="${tmp_root%/}"
done
WORK="$(mktemp -d "$tmp_root/add-skill-smoke.XXXXXX")" || WORK=""
if [ -z "$WORK" ] || [ ! -d "$WORK" ]; then
  echo "cannot create a temporary directory to work in" >&2
  exit 2
fi
SRC="$WORK/src"
DEST="$WORK/proj/.claude/skills"

for s in alpha bravo; do
  mkdir -p "$SRC/skills/$s"
  printf -- '---\nname: %s\ndescription: smoke fixture\n---\n' "$s" >"$SRC/skills/$s/SKILL.md"
done
mkdir -p "$DEST"

# The failure cases below are built by making a directory unwritable. A user who
# bypasses permission checks — root, or a container granting CAP_DAC_OVERRIDE —
# writes through that anyway, which would turn every failure assertion red
# against correct code. Check the mechanism itself rather than the user id, and
# exit non-zero so the run cannot be mistaken for a pass.
mkdir -p "$WORK/wperm" && chmod a-w "$WORK/wperm"
if touch "$WORK/wperm/probe" 2>/dev/null; then
  echo "cannot run here: this user can write into a directory with write permission removed" >&2
  echo "the failure assertions are unconstructible; run the suite as an ordinary user" >&2
  exit 2
fi
chmod u+w "$WORK/wperm"

# run_at <cwd> <install-path> <outfile> <errfile> <args...>
run_at() {
  local cwd=$1 install=$2 out=$3 err=$4
  shift 4
  (cd "$cwd" && SKILLS_INSTALL_PATH="$install" "$ADD_SKILL" "$@" </dev/null >"$out" 2>"$err")
}

# The common case: the standard fixture, installed into the standard destination.
run() { # run <outfile> <errfile> <args...>
  local out=$1 err=$2
  shift 2
  run_at "$WORK/proj" "$DEST" "$out" "$err" "$SRC" "$@"
}

echo "add-skill smoke tests ($ADD_SKILL)"

# path_within decides the self-source guard. Its root cases cannot be reached
# through a real install without an install path at /, so lift the function out
# and exercise it directly.
echo "[path_within]"
eval "$(sed -n '/^path_within() {/,/^}/p' "$ADD_SKILL")"
if ! type path_within >/dev/null 2>&1; then
  echo "could not lift path_within out of $ADD_SKILL" >&2
  exit 2
fi
assert_true "a path is within itself" path_within /a/b /a/b
assert_true "a child is within its parent" path_within /a/b/c /a/b
assert_false "a sibling with a shared prefix is not" path_within /a/bc /a/b
assert_false "a parent is not within its child" path_within /a/b /a/b/c
assert_true "everything is within the root" path_within /a/b /
assert_true "the root is within itself" path_within / /
assert_true "a doubled separator names the same place" path_within /tmp/x //tmp
assert_false "an unresolved inner is within nothing" path_within "" /a
# The other order is the one the empty guard is actually needed for: without it
# the outer becomes "" and the pattern /* matches every absolute path.
assert_false "an unresolved outer contains nothing" path_within /a ""

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
assert_contains "symlink-force marks the per-skill line forced" "$WORK/o" '(forced)'
assert_contains "symlink-force names replacement in the summary" "$WORK/o" 'Replaces a real file'

reset_dest
run "$WORK/o" "$WORK/e"
assert_status "copy install exits 0" zero $?
assert_true "copy install produces a directory" test -d "$DEST/alpha"
assert_true "the copied skill is not a symlink" test ! -L "$DEST/alpha"

# Copy mode replaces a real directory, so a file left inside a previous copy
# must not survive the next one.
echo stale >"$DEST/alpha/stale.txt"
run "$WORK/o" "$WORK/e"
assert_status "re-running the copy install exits 0" zero $?
assert_true "the copy install replaces what was there" test ! -e "$DEST/alpha/stale.txt"

# A real entry at the destination is content this tool did not put there.
echo "[real content at the destination]"
reset_dest
mkdir -p "$DEST/alpha" && echo mine >"$DEST/alpha/mine.txt"
run "$WORK/o" "$WORK/e" --symlink
assert_status "plain --symlink refuses a real directory" nonzero $?
assert_true "the real directory is untouched" test -f "$DEST/alpha/mine.txt"
cat "$WORK/o" "$WORK/e" >"$WORK/both"
assert_contains "it points at --symlink-force" "$WORK/both" '\[ERROR\].*symlink-force'

run "$WORK/o" "$WORK/e" --symlink-force
assert_status "--symlink-force replaces it" zero $?
assert_true "the destination became a symlink" test -L "$DEST/alpha"

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

# Installing a skill onto its own source would have the removal delete the
# source before anything reads it, leaving a self-referencing symlink and a
# success status.
echo "[refuses to install onto its own source]"
SELF="$WORK/self"
mkdir -p "$SELF/my-skill"
printf -- '---\nname: my-skill\ndescription: smoke fixture\n---\n' >"$SELF/my-skill/SKILL.md"
run_at "$SELF" "$SELF" "$WORK/o" "$WORK/e" "$SELF/my-skill" --symlink
assert_status "installing onto its own source aborts" nonzero $?
assert_true "the source file survives" test -f "$SELF/my-skill/SKILL.md"
assert_true "the source is still a directory" test ! -L "$SELF/my-skill"
cat "$WORK/o" "$WORK/e" >"$WORK/both"
assert_contains "it says what it refused" "$WORK/both" '\[ERROR\].*own source'

# The destination can also be the source's own entry when that entry is itself a
# symlink. Resolving the source through it would compare the target instead and
# let the removal delete the entry.
for mode in --symlink ""; do
  label=${mode:-copy mode}
  LINKED="$WORK/linked-$$-${mode:-copy}"
  mkdir -p "$LINKED/repo/skills" "$LINKED/elsewhere/alpha"
  printf -- '---\nname: alpha\ndescription: smoke fixture\n---\n' >"$LINKED/elsewhere/alpha/SKILL.md"
  ln -s "$LINKED/elsewhere/alpha" "$LINKED/repo/skills/alpha"
  if [ -n "$mode" ]; then
    run_at "$LINKED" "$LINKED/repo/skills" "$WORK/o" "$WORK/e" "$LINKED/repo" "$mode"
  else
    run_at "$LINKED" "$LINKED/repo/skills" "$WORK/o" "$WORK/e" "$LINKED/repo"
  fi
  assert_status "$label onto a symlinked source entry aborts" nonzero $?
  assert_true "$label leaves the source entry pointing where it did" \
    test "$(readlink "$LINKED/repo/skills/alpha")" = "$LINKED/elsewhere/alpha"
done

# The other half of the guard: the destination is not the source entry but what
# that entry points at, so removing it would empty the source from underneath.
POINTED="$WORK/pointed"
mkdir -p "$POINTED/repo/skills" "$POINTED/dest/alpha"
printf -- '---\nname: alpha\ndescription: smoke fixture\n---\n' >"$POINTED/dest/alpha/SKILL.md"
ln -s "$POINTED/dest/alpha" "$POINTED/repo/skills/alpha"
# --symlink-force, not --symlink: the destination is a real directory, so plain
# --symlink refuses it before the guard is consulted and the assertions would
# hold with the guard deleted.
run_at "$POINTED" "$POINTED/dest" "$WORK/o" "$WORK/e" "$POINTED/repo" --symlink-force
assert_status "installing onto what the source entry points at aborts" nonzero $?
assert_true "the pointed-at content survives" test -f "$POINTED/dest/alpha/SKILL.md"

# --skill takes the name as given, so it can carry path components. The
# destination's parent then absorbs them and the comparison has to account for
# it rather than re-appending the whole name.
NESTED="$WORK/nested"
mkdir -p "$NESTED/repo/skills/sub/alpha"
printf -- '---\nname: alpha\ndescription: smoke fixture\n---\n' >"$NESTED/repo/skills/sub/alpha/SKILL.md"
run_at "$NESTED" "$NESTED/repo/skills" "$WORK/o" "$WORK/e" "$NESTED/repo" --symlink-force --skill sub/alpha
assert_status "a slash-carrying skill name cannot slip past the guard" nonzero $?
assert_true "the nested source survives" test -f "$NESTED/repo/skills/sub/alpha/SKILL.md"
cat "$WORK/o" "$WORK/e" >"$WORK/both"
assert_contains "the guard is what stopped it" "$WORK/both" 'is or contains its own source'

# Containment, not just equality: a destination that is an ancestor of the
# source would have rm -rf take the whole source tree with it.
ANCESTOR="$WORK/ancestor"
mkdir -p "$ANCESTOR/inst/alpha/skills/alpha"
printf -- '---\nname: alpha\ndescription: smoke fixture\n---\n' >"$ANCESTOR/inst/alpha/skills/alpha/SKILL.md"
echo keep >"$ANCESTOR/inst/alpha/README.md"
run_at "$ANCESTOR" "$ANCESTOR/inst" "$WORK/o" "$WORK/e" "$ANCESTOR/inst/alpha" --symlink-force
assert_status "a destination containing the source aborts" nonzero $?
assert_true "the surrounding repository survives" test -f "$ANCESTOR/inst/alpha/README.md"
cat "$WORK/o" "$WORK/e" >"$WORK/both"
assert_contains "the guard is what stopped that too" "$WORK/both" 'is or contains its own source'

# rm -rf through a trailing slash follows a symlink and empties its target, so
# the removal has to work on the normalized entry.
TRAILING="$WORK/trailing"
mkdir -p "$TRAILING/repo/skills/alpha" "$TRAILING/dest"
printf -- '---\nname: alpha\ndescription: smoke fixture\n---\n' >"$TRAILING/repo/skills/alpha/SKILL.md"
echo payload >"$TRAILING/repo/skills/alpha/payload.txt"
run_at "$TRAILING" "$TRAILING/dest" "$WORK/o" "$WORK/e" "$TRAILING/repo" --symlink --skill alpha
assert_status "the first install exits 0" zero $?
run_at "$TRAILING" "$TRAILING/dest" "$WORK/o" "$WORK/e" "$TRAILING/repo" --symlink --skill alpha/
assert_status "a trailing-slash name still installs" zero $?
assert_true "a trailing slash does not reach through the link" test -f "$TRAILING/repo/skills/alpha/payload.txt"
assert_true "the destination is still the expected link" \
  test "$(readlink "$TRAILING/dest/alpha")" = "$TRAILING/repo/skills/alpha"

# The opposite direction is legitimate: a repository that is itself a skill,
# installing into the .claude/skills inside it. The removal there only reaches
# the destination, so the guard must not refuse it.
OWN="$WORK/own"
mkdir -p "$OWN/my-skill"
printf -- '---\nname: my-skill\ndescription: smoke fixture\n---\n' >"$OWN/my-skill/SKILL.md"
run_at "$OWN/my-skill" "$OWN/my-skill/.claude/skills" "$WORK/o" "$WORK/e" "$OWN/my-skill" --symlink
assert_status "a single-skill repo installs inside its own tree" zero $?
assert_true "that install is a symlink" test -L "$OWN/my-skill/.claude/skills/my-skill"
rm -rf "$OWN/my-skill/.claude"
# Only that the guard allows it: whether cp itself copies a tree into its own
# subtree differs between BSD and GNU cp, and that predates this change.
run_at "$OWN/my-skill" "$OWN/my-skill/.claude/skills" "$WORK/o" "$WORK/e" "$OWN/my-skill"
cat "$WORK/o" "$WORK/e" >"$WORK/both"
assert_absent "copy mode is not refused there either" "$WORK/both" 'is or contains its own source'

# A filename may contain a newline. Any line-delimited list of the chain would
# split such a name into unrelated entries and lose the relationship.
NEWLINE="$WORK/newline"
mkdir -p "$NEWLINE/repo/skills"
odd="$(printf 'alpha\nbeta')"
mkdir -p "$NEWLINE/repo/skills/$odd"
printf -- '---\nname: alpha\ndescription: smoke fixture\n---\n' >"$NEWLINE/repo/skills/$odd/SKILL.md"
run_at "$NEWLINE" "$NEWLINE/repo/skills" "$WORK/o" "$WORK/e" "$NEWLINE/repo" --symlink-force --skill "$odd"
assert_status "a newline in the name does not split the comparison" nonzero $?
assert_true "the oddly named source survives" test -f "$NEWLINE/repo/skills/$odd/SKILL.md"

# The destination can sit in the middle of the source's resolution chain, where
# it is neither the entry nor what the entry finally reaches. Unlinking it there
# and pointing it back at the source closes a cycle.
CHAIN="$WORK/chain"
mkdir -p "$CHAIN/repo/skills" "$CHAIN/dest" "$CHAIN/real/alpha"
printf -- '---\nname: alpha\ndescription: smoke fixture\n---\n' >"$CHAIN/real/alpha/SKILL.md"
ln -s "$CHAIN/real/alpha" "$CHAIN/dest/alpha"
ln -s "$CHAIN/dest/alpha" "$CHAIN/repo/skills/alpha"
run_at "$CHAIN" "$CHAIN/dest" "$WORK/o" "$WORK/e" "$CHAIN/repo" --symlink --skill alpha
assert_status "a destination inside the resolution chain aborts" nonzero $?
assert_true "the middle link still points where it did" \
  test "$(readlink "$CHAIN/dest/alpha")" = "$CHAIN/real/alpha"
cat "$WORK/o" "$WORK/e" >"$WORK/both"
assert_contains "the guard is what stopped the chain case" "$WORK/both" 'is or contains its own source'

# cd follows a symlink and then has to enter what it lands on, so a source entry
# pointing at an unenterable directory used to resolve to nothing and slip past
# the guard: the destination was removed and replaced with a link cycle, exit 0.
UNENTERABLE="$WORK/unenterable-target"
mkdir -p "$UNENTERABLE/repo/skills" "$UNENTERABLE/dest/alpha"
ln -s "$UNENTERABLE/dest/alpha" "$UNENTERABLE/repo/skills/alpha"
chmod 600 "$UNENTERABLE/dest/alpha"
run_at "$UNENTERABLE" "$UNENTERABLE/dest" "$WORK/o" "$WORK/e" "$UNENTERABLE/repo" --symlink-force --skill alpha
status=$?
chmod 700 "$UNENTERABLE/dest/alpha" 2>/dev/null
assert_status "an unenterable symlink target does not slip past the guard" nonzero $status
assert_true "the target directory survives" test -d "$UNENTERABLE/dest/alpha"
assert_true "the destination did not become a link" test ! -L "$UNENTERABLE/dest/alpha"

# A source directory that cannot be entered is still linkable, and was before
# the guard existed, so the guard must not turn that into a failure.
UNREADABLE="$WORK/unreadable"
mkdir -p "$UNREADABLE/repo/skills/alpha" "$UNREADABLE/dest"
printf -- '---\nname: alpha\ndescription: smoke fixture\n---\n' >"$UNREADABLE/repo/skills/alpha/SKILL.md"
chmod 600 "$UNREADABLE/repo/skills/alpha"
run_at "$UNREADABLE" "$UNREADABLE/dest" "$WORK/o" "$WORK/e" "$UNREADABLE/repo" --symlink --skill alpha
status=$?
chmod 700 "$UNREADABLE/repo/skills/alpha"
assert_status "an unenterable source still installs" zero $status
assert_true "it was linked" test -L "$UNREADABLE/dest/alpha"

# A destination that cannot even be created is still a skill that could not be
# installed, so it gets the same report as the ln and cp failures.
echo "[reports a destination it cannot create]"
mkdir -p "$WORK/locked" && chmod a-w "$WORK/locked"
run_at "$WORK/proj" "$WORK/locked/skills" "$WORK/o" "$WORK/e" "$SRC" --symlink
status=$?
chmod u+w "$WORK/locked"
assert_status "an uncreatable destination aborts" nonzero $status
cat "$WORK/o" "$WORK/e" >"$WORK/both"
assert_contains "it names the destination it could not create" "$WORK/both" 'Failed to create.*alpha'

# The removal only runs when something already occupies the destination, so an
# unwritable parent with the entry present is what reaches its failure branch.
echo "[reports an existing install it cannot clear]"
# --symlink-force, not --symlink: plain --symlink refuses a real directory
# before it ever tries to remove one, so it never reaches this branch.
reset_dest
mkdir -p "$DEST/alpha"
chmod a-w "$DEST"
run "$WORK/o" "$WORK/e" --symlink-force
status=$?
chmod u+w "$DEST"
assert_status "an unclearable install aborts" nonzero $status
cat "$WORK/o" "$WORK/e" >"$WORK/both"
assert_contains "it names the install it could not remove" "$WORK/both" 'Failed to remove'

# cp -r copies what it can before failing, and skill discovery only looks for
# SKILL.md, so a half-copied tree would read as a complete skill.
echo "[leaves nothing behind after a partial copy]"
reset_dest
mkdir -p "$SRC/skills/alpha/sub" && echo secret >"$SRC/skills/alpha/sub/locked.txt"
chmod a-r "$SRC/skills/alpha/sub/locked.txt"
run "$WORK/o" "$WORK/e"
assert_status "a partial copy aborts" nonzero $?
assert_true "no half-copied skill is left behind" test ! -e "$DEST/alpha"
chmod u+r "$SRC/skills/alpha/sub/locked.txt"
rm -rf "$SRC/skills/alpha/sub"

# --install symlinks the script into ~/.local/bin. When the script being run is
# already the real file at that path, resolving it yields the destination
# itself, and removing-then-linking would destroy the only copy.
echo "[--install leaves a copy already at the destination alone]"
FAKE="$WORK/home"
mkdir -p "$FAKE/.local/bin"
cp "$ADD_SKILL" "$FAKE/.local/bin/add-skill"
chmod +x "$FAKE/.local/bin/add-skill"
HOME="$FAKE" "$FAKE/.local/bin/add-skill" --install </dev/null >"$WORK/o" 2>"$WORK/e"
assert_status "--install onto its own location exits 0" zero $?
assert_true "the script is still a regular file" test -f "$FAKE/.local/bin/add-skill"
assert_true "the script was not replaced by a symlink" test ! -L "$FAKE/.local/bin/add-skill"
assert_true "the script still has content" test -s "$FAKE/.local/bin/add-skill"
cat "$WORK/o" "$WORK/e" >"$WORK/both"
assert_contains "it still says where PATH stands" "$WORK/both" 'PATH'

# --install's own filesystem calls report the same way the skill path's do.
echo "[--install reports what it could not do]"
FAKE_LN="$WORK/home-ln"
mkdir -p "$FAKE_LN/.local/bin" && chmod a-w "$FAKE_LN/.local/bin"
HOME="$FAKE_LN" "$ADD_SKILL" --install </dev/null >"$WORK/o" 2>"$WORK/e"
status=$?
chmod u+w "$FAKE_LN/.local/bin"
assert_status "--install aborts when it cannot link" nonzero $status
cat "$WORK/o" "$WORK/e" >"$WORK/both"
assert_contains "--install says it could not link" "$WORK/both" 'Failed to symlink'

# An entry already at the destination, in a directory that cannot be written:
# this reaches the removal rather than the link.
FAKE_RM="$WORK/home-rm"
mkdir -p "$FAKE_RM/.local/bin" && : >"$FAKE_RM/.local/bin/add-skill"
chmod a-w "$FAKE_RM/.local/bin"
HOME="$FAKE_RM" "$ADD_SKILL" --install </dev/null >"$WORK/o" 2>"$WORK/e"
status=$?
chmod u+w "$FAKE_RM/.local/bin"
assert_status "--install aborts when it cannot remove what is there" nonzero $status
cat "$WORK/o" "$WORK/e" >"$WORK/both"
assert_contains "--install says it could not remove it" "$WORK/both" 'Failed to remove'

FAKE_MK="$WORK/home-mk"
mkdir -p "$FAKE_MK/.local" && chmod a-w "$FAKE_MK/.local"
HOME="$FAKE_MK" "$ADD_SKILL" --install </dev/null >"$WORK/o" 2>"$WORK/e"
status=$?
chmod u+w "$FAKE_MK/.local"
assert_status "--install aborts when it cannot create the directory" nonzero $status
cat "$WORK/o" "$WORK/e" >"$WORK/both"
assert_contains "--install says it could not create it" "$WORK/both" 'Failed to create'

# Removing write permission leaves the directory enterable; removing execute
# permission does not, and that reaches a different call.
FAKE_X="$WORK/home-x"
mkdir -p "$FAKE_X/.local/bin" && chmod a-x "$FAKE_X/.local/bin"
HOME="$FAKE_X" "$ADD_SKILL" --install </dev/null >"$WORK/o" 2>"$WORK/e"
status=$?
chmod u+x "$FAKE_X/.local/bin"
assert_status "--install aborts when it cannot enter the directory" nonzero $status
cat "$WORK/o" "$WORK/e" >"$WORK/both"
assert_contains "--install says it could not enter it" "$WORK/both" 'Failed to enter'

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

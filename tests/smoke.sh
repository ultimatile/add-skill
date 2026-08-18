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
SKIPPED=0
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

# skipped <count> <reason...> — a guarded block that did not run, and how many
# assertions went with it. Counted so the summary can say so.
skipped() {
  SKIPPED=$((SKIPPED + $1))
  shift
  echo "  skip - $*"
}

# The captured output can hold bytes that are not valid in the ambient encoding —
# a skill name is whatever the filesystem allows, and quoting it can leave a
# half-escaped mixture. In a UTF-8 locale grep declines to match anything at all
# on such a line, so an assertion over it would pass or fail for a reason that has
# nothing to do with what it asserts. LC_ALL=C makes the comparison bytewise.
#
# On the grep only. The runs keep the ambient locale, because that is the setting
# whose behavior is under test.
#
# -- so a pattern beginning with - is a pattern, not an option.

# assert_contains <label> <file> <pattern>
assert_contains() {
  if LC_ALL=C grep -q -- "$3" "$2"; then
    ok "$1"
  else
    no "$1" "expected /$3/ in $(basename "$2"), got: $(tr '\n' '|' <"$2" | cut -c1-200)"
  fi
}

# assert_absent <label> <file> <pattern>
assert_absent() {
  if LC_ALL=C grep -q -- "$3" "$2"; then
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

# assert_link_to <label> <path> <target>  — readlink, so an unfollowed compare
assert_link_to() {
  assert_true "$1" test "$(readlink "$2")" = "$3"
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

# write_skill_md <dir> <name> — the frontmatter every fixture skill carries.
# Only the directory and the name differ across fixtures; the surrounding
# mkdir -p lines are not boilerplate and stay written out, because what each
# fixture creates alongside the skill is the shape it is testing.
#
# Defined up here rather than beside the other run helpers: the standard fixture
# below is built before that point, and a function is not callable until its
# definition has been read.
write_skill_md() {
  printf -- '---\nname: %s\ndescription: smoke fixture\n---\n' "$2" >"$1/SKILL.md"
}

# Several assertions need a pattern matched against the run's stdout and stderr
# together, without caring which stream carried it.
#
# Every call also enforces the routing invariant on the run it just captured. A
# diagnostic tag on stdout is wrong whether the run succeeded or failed, so the
# check belongs here rather than appended to each fixture: the combined capture
# the assertions below read cannot see which stream carried a match, and this is
# the one place that still can. Numbered, because the label is otherwise the
# same at every site and a failure has to be locatable.
ROUTING_CHECKS=0
capture_both() {
  cat "$WORK/o" "$WORK/e" >"$WORK/both"
  ROUTING_CHECKS=$((ROUTING_CHECKS + 1))
  assert_absent "no diagnostic tag on stdout (#$ROUTING_CHECKS)" "$WORK/o" '\[\(ERROR\|WARN\)\]'
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
  write_skill_md "$SRC/skills/$s" "$s"
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

# install_at <home> <script> [args...] — self-install against a throwaway HOME,
# capturing both streams. <script> is a parameter because one case runs the copy
# already sitting at the destination rather than this suite's own. PATH is left
# as the caller has it, so a case that turns on which side of the PATH check it
# lands on sets it as a prefix on the call: a variable assignment before a
# function name applies to that call and is restored after it.
install_at() {
  local home=$1 script=$2
  shift 2
  HOME="$home" "$script" --install "$@" </dev/null >"$WORK/o" 2>"$WORK/e"
}

# run_bare <args...> — add-skill with neither a source repository nor an install
# path, for the flags that exit before either is read. Distinct from run_at,
# whose cwd and SKILLS_INSTALL_PATH would be inert noise at these sites.
run_bare() {
  "$ADD_SKILL" "$@" </dev/null >"$WORK/o" 2>"$WORK/e"
}

# real_entry_at <skill> — a real directory where a skill would otherwise be
# linked. This is the entry --force is gated on, and is never something the
# script creates itself.
real_entry_at() {
  mkdir -p "$DEST/$1" && echo mine >"$DEST/$1/mine.txt"
}

# fake_home <slug> — a throwaway HOME holding an empty ~/.local/bin, and sets
# FAKE_HOME to it. Used by the cases that want that directory usable; one of them
# then plants a copy inside it. The cases that need it broken instead — a
# permission removed, or the directory never created — build it themselves in the
# same breath as breaking it, so they do not come through here.
fake_home() {
  FAKE_HOME="$WORK/home-$1"
  mkdir -p "$FAKE_HOME/.local/bin"
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

# The containment test builds a case pattern from the outer path. Quoting is
# what keeps a bracket, a question mark or a star in a directory name literal;
# without it the guard would both miss real containment and invent it.
assert_true "a bracket in a directory name is a bracket" path_within '/a[b]/c' '/a[b]'
assert_true "and so is a question mark" path_within '/a?c/d' '/a?c'
assert_true "and so is a star" path_within '/a*c/d' '/a*c'
assert_false "a name a bracket would have matched is not within it" path_within '/ab/c' '/a[b]'
assert_false "nor one a question mark would have matched" path_within '/axc/d' '/a?c'

# Identity, for the aliases text cannot see. A bind mount is the case this
# exists for and cannot be created here; a symlink is the same shape — two
# spellings, one inode — and does exercise the comparison.
eval "$(sed -n '/^path_under_identity() {/,/^}/p' "$ADD_SKILL")"
if ! type path_under_identity >/dev/null 2>&1; then
  echo "could not lift path_under_identity out of $ADD_SKILL" >&2
  exit 2
fi
mkdir -p "$WORK/ident/real/sub"
ln -s "$WORK/ident/real" "$WORK/ident/alias"
assert_true "a path is the same file as itself" \
  path_under_identity "$WORK/ident/real" "$WORK/ident/real"
assert_true "another spelling is the same file" \
  path_under_identity "$WORK/ident/alias" "$WORK/ident/real"
assert_true "and so is something beneath that spelling" \
  path_under_identity "$WORK/ident/alias/sub" "$WORK/ident/real"
assert_false "an unrelated path is not" \
  path_under_identity "$WORK/ident/real" "$WORK/ident/real/sub"
assert_false "a destination that does not exist holds nothing" \
  path_under_identity "$WORK/ident/real" "$WORK/ident/nope"

echo "[install succeeds]"
reset_dest
run "$WORK/o" "$WORK/e"
assert_status "install exits 0" zero $?
assert_true "alpha is a symlink" test -L "$DEST/alpha"
assert_true "bravo is a symlink" test -L "$DEST/bravo"
assert_absent "the summary is silent about replacement" "$WORK/o" 'Replaced a real file'

run "$WORK/o" "$WORK/e"
assert_status "re-running over the install exits 0" zero $?
assert_true "re-running leaves a symlink behind" test -L "$DEST/alpha"

# --force permits the replacement of real content; it does not perform one. Where
# a link or nothing was in the way, nothing gets replaced, so the outcome, the
# per-skill line and the closing summary all read as they would without it.
#
# Asserted under --verbose, because '(forced)' is a per-skill marker and the
# default level prints no per-skill line for it to be absent from. Left at the
# default level these would pass against a string that cannot appear either way.
run "$WORK/o" "$WORK/e" --force --verbose
assert_status "--force over a symlink exits 0" zero $?
assert_true "--force over a symlink leaves a symlink behind" test -L "$DEST/alpha"
assert_absent "--force over a symlink is not marked forced" "$WORK/o" '(forced)'
assert_absent "--force over a symlink claims no replacement" "$WORK/o" 'Replaced a real file'

reset_dest
run "$WORK/o" "$WORK/e" --force --verbose
assert_status "--force onto an absent destination exits 0" zero $?
assert_true "--force onto an absent destination links" test -L "$DEST/alpha"
assert_absent "--force onto an absent destination is not marked forced" "$WORK/o" '(forced)'

# A broken link is -L true where -e is false, so only a -L test reaches it. With
# an -e test alone it reads as absent, nothing is unlinked, and ln then fails on
# the entry that is still sitting there.
reset_dest
ln -s "$WORK/no-such-target" "$DEST/alpha"
run "$WORK/o" "$WORK/e"
assert_status "a broken link at the destination exits 0" zero $?
assert_link_to "the broken link now points at the source" "$DEST/alpha" "$SRC/skills/alpha"

reset_dest
ln -s "$WORK/no-such-target" "$DEST/alpha"
run "$WORK/o" "$WORK/e" --force
assert_status "--force over a broken link exits 0" zero $?
assert_link_to "--force replaced the broken link" "$DEST/alpha" "$SRC/skills/alpha"

# A real entry at the destination is not something this creates: it only ever
# links.
echo "[real content at the destination]"
reset_dest
real_entry_at alpha
run "$WORK/o" "$WORK/e"
assert_status "a real directory is refused" nonzero $?
assert_true "the real directory is untouched" test -f "$DEST/alpha/mine.txt"
# Not discriminating on its own: dropping the clearing branch is what lets the
# link land inside the directory, and that also makes the run exit 0, which the
# status assertion above catches. Kept as the one place the ln-descends-into-a-
# directory hazard is asserted rather than only argued in a comment.
assert_true "no link was created inside the refused directory" test ! -e "$DEST/alpha/alpha"
capture_both
assert_contains "it points at --force" "$WORK/both" '\[ERROR\].*--force'

run "$WORK/o" "$WORK/e" --force
assert_status "--force replaces the real directory" zero $?
assert_true "the destination became a symlink" test -L "$DEST/alpha"
# On the error stream specifically, not the combined capture: the routing is
# what this asserts, and a combined grep would pass either way.
assert_contains "the deletion is announced before it happens" "$WORK/e" 'Deleting the real file or directory'
assert_absent "the deletion is not announced on stdout" "$WORK/o" 'Deleting the real file or directory'
# The replacement is reported per skill at both levels, in different shapes. At
# the default level it is a name on the replaced-list; bravo was absent rather
# than replaced, so it must not appear there. A grep for the whole line cannot
# tell a per-skill marker from one set once per run, which is what the second
# assertion is for.
assert_contains "the replaced-list names the skill that was replaced" "$WORK/o" 'Replaced a real file or directory for:.*alpha'
assert_false "and does not name the one that was not" \
  grep -q -- 'Replaced a real file or directory for:.*bravo' "$WORK/o"

reset_dest
real_entry_at alpha
run "$WORK/o" "$WORK/e" --force --verbose
assert_status "--force replaces the real directory under --verbose too" zero $?
assert_contains "the replacement is marked forced" "$WORK/o" 'Symlinked alpha (forced)'
assert_absent "the skill that was not replaced is unmarked" "$WORK/o" 'Symlinked bravo (forced)'
assert_contains "and the closing summary reports it" "$WORK/o" 'Replaced a real file or directory at the destination'

# A real regular file takes the same branch — the test is -e, which does not
# distinguish the two — and rm -rf removes it just as well.
reset_dest
echo mine >"$DEST/alpha"
run "$WORK/o" "$WORK/e"
assert_status "a real file is refused" nonzero $?
assert_true "the real file is untouched" test -f "$DEST/alpha"
assert_true "the real file is still not a symlink" test ! -L "$DEST/alpha"

run "$WORK/o" "$WORK/e" --force
assert_status "--force replaces the real file" zero $?
assert_true "the file's destination became a symlink" test -L "$DEST/alpha"

# An unwritable destination makes the link fail while nothing occupies the
# target, so the failure is never "the target already exists". One run covers
# both flag settings: the destination is empty, so neither clearing branch
# fires, USE_FORCE is never read, and --force cannot change the outcome. The
# case where it does reach the removal is below, under an unclearable install.
echo "[install fails]"
reset_dest
chmod a-w "$DEST"
run "$WORK/o" "$WORK/e"
status=$?
chmod u+w "$DEST"

assert_status "an unwritable destination aborts with non-zero status" nonzero $status
capture_both
assert_contains "it names the skill it could not install" "$WORK/both" '\[ERROR\].*alpha'
assert_contains "it lets ln report the reason on stderr" "$WORK/e" '^ln:'
assert_absent "it asks no question" "$WORK/both" '(y/N)'

# A failure must stop the run rather than carry on to the remaining skills.
# Ask for a name the source does not have, followed by one it does.
echo "[a failure stops the run]"
reset_dest
run "$WORK/o" "$WORK/e" --skill nosuch --skill alpha
assert_status "an unknown skill aborts with non-zero status" nonzero $?
assert_true "the skill queued after the failure is not installed" test ! -e "$DEST/alpha"

# Installing a skill onto its own source would have the removal delete the
# source before anything reads it, leaving a self-referencing symlink and a
# success status.
echo "[refuses to install onto its own source]"
SELF="$WORK/self"
mkdir -p "$SELF/my-skill"
write_skill_md "$SELF/my-skill" my-skill
run_at "$SELF" "$SELF" "$WORK/o" "$WORK/e" "$SELF/my-skill"
assert_status "installing onto its own source aborts" nonzero $?
assert_true "the source file survives" test -f "$SELF/my-skill/SKILL.md"
assert_true "the source is still a directory" test ! -L "$SELF/my-skill"
capture_both
assert_contains "it says what it refused" "$WORK/both" '\[ERROR\].*own source'

# The destination can also be the source's own entry when that entry is itself a
# symlink. Resolving the source through it would compare the target instead and
# let the removal delete the entry.
LINKED="$WORK/linked-$$"
mkdir -p "$LINKED/repo/skills" "$LINKED/elsewhere/alpha"
write_skill_md "$LINKED/elsewhere/alpha" alpha
ln -s "$LINKED/elsewhere/alpha" "$LINKED/repo/skills/alpha"
run_at "$LINKED" "$LINKED/repo/skills" "$WORK/o" "$WORK/e" "$LINKED/repo"
assert_status "installing onto a symlinked source entry aborts" nonzero $?
assert_link_to "it leaves the source entry pointing where it did" "$LINKED/repo/skills/alpha" "$LINKED/elsewhere/alpha"

# The other half of the guard: the destination is not the source entry but what
# that entry points at, so removing it would empty the source from underneath.
POINTED="$WORK/pointed"
mkdir -p "$POINTED/repo/skills" "$POINTED/dest/alpha"
write_skill_md "$POINTED/dest/alpha" alpha
ln -s "$POINTED/dest/alpha" "$POINTED/repo/skills/alpha"
# --force, not the default. The destination is a real directory, so with the
# guard deleted the default still refuses — on the --force gate's ground rather
# than the guard's — exiting non-zero with the content intact, and only the two
# message assertions would notice. Under --force the guard is the last thing
# between the run and the source: delete it and the run exits 0 having destroyed
# the pointed-at content, which the status and survival assertions catch too.
run_at "$POINTED" "$POINTED/dest" "$WORK/o" "$WORK/e" "$POINTED/repo" --force
assert_status "installing onto what the source entry points at aborts" nonzero $?
assert_true "the pointed-at content survives" test -f "$POINTED/dest/alpha/SKILL.md"
capture_both
assert_contains "the guard is what refused it" "$WORK/both" '\[ERROR\].*own source'
assert_absent "not the --force gate" "$WORK/both" 'pass --force to replace it'

# --skill takes the name as given, so it can carry path components. The
# destination's parent then absorbs them and the comparison has to account for
# it rather than re-appending the whole name.
NESTED="$WORK/nested"
mkdir -p "$NESTED/repo/skills/sub/alpha"
write_skill_md "$NESTED/repo/skills/sub/alpha" alpha
run_at "$NESTED" "$NESTED/repo/skills" "$WORK/o" "$WORK/e" "$NESTED/repo" --force --skill sub/alpha
assert_status "a name with a path component is refused" nonzero $?
assert_true "the nested source survives" test -f "$NESTED/repo/skills/sub/alpha/SKILL.md"
capture_both
assert_contains "it says why" "$WORK/both" 'cannot contain a path component'

# .. in a name sends both the source and the destination out of their roots.
# The install path is what it escapes on the destination side.
TRAVERSE="$WORK/traverse"
mkdir -p "$TRAVERSE/repo/skills/alpha" "$TRAVERSE/repo/other" "$TRAVERSE/proj/dest" "$TRAVERSE/proj/other"
write_skill_md "$TRAVERSE/repo/other" other
echo mine >"$TRAVERSE/proj/other/keep.txt"
run_at "$TRAVERSE/proj" "$TRAVERSE/proj/dest" "$WORK/o" "$WORK/e" "$TRAVERSE/repo" --force --skill ../other
assert_status "a name climbing out of the skills directory is refused" nonzero $?
assert_true "nothing outside the install path is touched" test -f "$TRAVERSE/proj/other/keep.txt"
assert_true "and it is still a directory" test ! -L "$TRAVERSE/proj/other"

# Containment, not just equality: a destination that is an ancestor of the
# source would have rm -rf take the whole source tree with it.
ANCESTOR="$WORK/ancestor"
mkdir -p "$ANCESTOR/inst/alpha/skills/alpha"
write_skill_md "$ANCESTOR/inst/alpha/skills/alpha" alpha
echo keep >"$ANCESTOR/inst/alpha/README.md"
run_at "$ANCESTOR" "$ANCESTOR/inst" "$WORK/o" "$WORK/e" "$ANCESTOR/inst/alpha" --force
assert_status "a destination containing the source aborts" nonzero $?
assert_true "the surrounding repository survives" test -f "$ANCESTOR/inst/alpha/README.md"
capture_both
assert_contains "the guard is what stopped that too" "$WORK/both" 'is or contains its own source'

# rm -rf through a trailing slash follows a symlink and empties its target, so
# the removal has to work on the normalized entry.
TRAILING="$WORK/trailing"
mkdir -p "$TRAILING/repo/skills/alpha" "$TRAILING/dest"
write_skill_md "$TRAILING/repo/skills/alpha" alpha
echo payload >"$TRAILING/repo/skills/alpha/payload.txt"
run_at "$TRAILING" "$TRAILING/dest" "$WORK/o" "$WORK/e" "$TRAILING/repo" --skill alpha
assert_status "the first install exits 0" zero $?
run_at "$TRAILING" "$TRAILING/dest" "$WORK/o" "$WORK/e" "$TRAILING/repo" --skill alpha/
assert_status "a trailing-slash name still installs" zero $?
assert_true "a trailing slash does not reach through the link" test -f "$TRAILING/repo/skills/alpha/payload.txt"
assert_link_to "the destination is still the expected link" "$TRAILING/dest/alpha" "$TRAILING/repo/skills/alpha"

# The opposite direction is legitimate: a repository that is itself a skill,
# installing into the .claude/skills inside it. The removal there only reaches
# the destination, so the guard must not refuse it.
OWN="$WORK/own"
mkdir -p "$OWN/my-skill"
write_skill_md "$OWN/my-skill" my-skill
run_at "$OWN/my-skill" "$OWN/my-skill/.claude/skills" "$WORK/o" "$WORK/e" "$OWN/my-skill"
assert_status "a single-skill repo installs inside its own tree" zero $?
assert_true "that install is a symlink" test -L "$OWN/my-skill/.claude/skills/my-skill"
capture_both
assert_absent "the guard did not refuse it" "$WORK/both" 'is or contains its own source'

# A filename may contain a newline. Any line-delimited list of the chain would
# split such a name into unrelated entries and lose the relationship.
NEWLINE="$WORK/newline"
mkdir -p "$NEWLINE/repo/skills"
odd="$(printf 'alpha\nbeta')"
mkdir -p "$NEWLINE/repo/skills/$odd"
write_skill_md "$NEWLINE/repo/skills/$odd" alpha
run_at "$NEWLINE" "$NEWLINE/repo/skills" "$WORK/o" "$WORK/e" "$NEWLINE/repo" --force --skill "$odd"
assert_status "a newline in the name does not split the comparison" nonzero $?
assert_true "the oddly named source survives" test -f "$NEWLINE/repo/skills/$odd/SKILL.md"

# Discovery names each skill from its directory, and that reading has to keep
# a trailing newline too: losing it here hands install_skill a name no such
# directory has.
DISCOVER="$WORK/discover"
quirk=$'gamma\n'
mkdir -p "$DISCOVER/repo/skills/$quirk" "$DISCOVER/repo/skills/delta" "$DISCOVER/dest"
write_skill_md "$DISCOVER/repo/skills/$quirk" gamma
write_skill_md "$DISCOVER/repo/skills/delta" delta
run_at "$DISCOVER" "$DISCOVER/dest" "$WORK/o" "$WORK/e" "$DISCOVER/repo"
assert_status "a repository with an oddly named skill installs" zero $?
assert_true "the odd name is installed as it is" test -L "$DISCOVER/dest/$quirk"
assert_true "and its neighbour is too" test -L "$DISCOVER/dest/delta"
# The summary names every installed skill on one line, so a name holding a
# newline has to reach it escaped. Raw, it would break the line in two and blur
# where one name ends and the next begins.
assert_true "the summary stays on one line" test "$(grep -c 'Symlinked 2 skills:' "$WORK/o")" -eq 1
assert_true "and the whole summary is a single line" \
  test "$(sed -n '/Symlinked 2 skills:/,$p' "$WORK/o" | wc -l)" -eq 1
# A literal backslash-n anywhere on the summary line, rather than immediately
# after the name. What matters is that the newline was shown instead of emitted,
# and that holds wherever printf %q puts the quoting; anchoring on the name would
# tie the assertion to one shell's placement of it for no gain.
assert_contains "with the newline shown rather than emitted" "$WORK/o" 'Symlinked 2 skills:.*\\n'

# Command substitution strips every trailing newline, so a name ending in one
# used to resolve to the sibling of that name and clear that instead.
TRAILNL="$WORK/trailnl"
odd=$'alpha\n'
mkdir -p "$TRAILNL/repo/skills/alpha" "$TRAILNL/repo/skills/$odd" "$TRAILNL/dest/alpha"
write_skill_md "$TRAILNL/repo/skills/alpha" alpha
write_skill_md "$TRAILNL/repo/skills/$odd" alpha
echo marker >"$TRAILNL/dest/alpha/keep.txt"
run_at "$TRAILNL" "$TRAILNL/dest" "$WORK/o" "$WORK/e" "$TRAILNL/repo" --force --skill "$odd"
assert_status "a name ending in a newline installs" zero $?
assert_true "the sibling of that name is untouched" test -f "$TRAILNL/dest/alpha/keep.txt"

# The destination can sit in the middle of the source's resolution chain, where
# it is neither the entry nor what the entry finally reaches. Unlinking it there
# and pointing it back at the source closes a cycle.
CHAIN="$WORK/chain"
mkdir -p "$CHAIN/repo/skills" "$CHAIN/dest" "$CHAIN/real/alpha"
write_skill_md "$CHAIN/real/alpha" alpha
ln -s "$CHAIN/real/alpha" "$CHAIN/dest/alpha"
ln -s "$CHAIN/dest/alpha" "$CHAIN/repo/skills/alpha"
run_at "$CHAIN" "$CHAIN/dest" "$WORK/o" "$WORK/e" "$CHAIN/repo" --skill alpha
assert_status "a destination inside the resolution chain aborts" nonzero $?
assert_link_to "the middle link still points where it did" "$CHAIN/dest/alpha" "$CHAIN/real/alpha"
capture_both
assert_contains "the guard is what stopped the chain case" "$WORK/both" 'is or contains its own source'

# cd follows a symlink and then has to enter what it lands on, so a source entry
# pointing at an unenterable directory used to resolve to nothing and slip past
# the guard: the destination was removed and replaced with a link cycle, exit 0.
UNENTERABLE="$WORK/unenterable-target"
mkdir -p "$UNENTERABLE/repo/skills" "$UNENTERABLE/dest/alpha"
ln -s "$UNENTERABLE/dest/alpha" "$UNENTERABLE/repo/skills/alpha"
chmod 600 "$UNENTERABLE/dest/alpha"
run_at "$UNENTERABLE" "$UNENTERABLE/dest" "$WORK/o" "$WORK/e" "$UNENTERABLE/repo" --force --skill alpha
status=$?
chmod 700 "$UNENTERABLE/dest/alpha" 2>/dev/null
assert_status "an unenterable symlink target does not slip past the guard" nonzero $status
assert_true "the target directory survives" test -d "$UNENTERABLE/dest/alpha"
assert_true "the destination did not become a link" test ! -L "$UNENTERABLE/dest/alpha"

# The missing-skills-directory error carries a hint on a following line, and that
# line is a bare echo rather than a print_* call — so the routing invariant
# capture_both enforces, which keys on the [ERROR] / [WARN] tag, cannot see it.
# It needs a reader of its own.
echo "[the missing-skills-directory hint goes with its error]"
NODIR="$WORK/nodir"
mkdir -p "$NODIR"
run_at "$NODIR" "$DEST" "$WORK/o" "$WORK/e" "$NODIR"
assert_status "a source with no skills/ directory aborts" nonzero $?
assert_contains "the error is on stderr" "$WORK/e" 'Skills source directory not found'
assert_contains "and so is the hint below it" "$WORK/e" 'Make sure the repository has a skills/ directory'
assert_absent "with neither left on stdout" "$WORK/o" 'skills/ directory'

# A source directory that cannot be entered is still linkable, and was before
# the guard existed, so the guard must not turn that into a failure.
UNREADABLE="$WORK/unreadable"
mkdir -p "$UNREADABLE/repo/skills/alpha" "$UNREADABLE/dest"
write_skill_md "$UNREADABLE/repo/skills/alpha" alpha
chmod 600 "$UNREADABLE/repo/skills/alpha"
run_at "$UNREADABLE" "$UNREADABLE/dest" "$WORK/o" "$WORK/e" "$UNREADABLE/repo" --skill alpha
status=$?
chmod 700 "$UNREADABLE/repo/skills/alpha"
assert_status "an unenterable source still installs" zero $status
assert_true "it was linked" test -L "$UNREADABLE/dest/alpha"

# A destination that cannot even be created is still a skill that could not be
# installed, so it gets the same report as the ln failures.
echo "[reports a destination it cannot create]"
mkdir -p "$WORK/locked" && chmod a-w "$WORK/locked"
run_at "$WORK/proj" "$WORK/locked/skills" "$WORK/o" "$WORK/e" "$SRC"
status=$?
chmod u+w "$WORK/locked"
assert_status "an uncreatable destination aborts" nonzero $status
capture_both
assert_contains "it names the destination it could not create" "$WORK/both" 'Failed to create.*alpha'

# The removal only runs when something already occupies the destination, so an
# unwritable parent with the entry present is what reaches its failure branch.
echo "[reports an existing install it cannot clear]"
# --force, not the default: the default refuses a real directory before it ever
# tries to remove one, so it never reaches this branch.
reset_dest
mkdir -p "$DEST/alpha"
chmod a-w "$DEST"
run "$WORK/o" "$WORK/e" --force
status=$?
chmod u+w "$DEST"
assert_status "an unclearable install aborts" nonzero $status
capture_both
assert_contains "it names the install it could not remove" "$WORK/both" 'Failed to remove'

# The other removal branch. A symlink is unlinked rather than recursed into,
# and that call can fail on its own; no fixture above reaches it.
reset_dest
ln -s "$SRC/skills/alpha" "$DEST/alpha"
chmod a-w "$DEST"
run "$WORK/o" "$WORK/e"
status=$?
chmod u+w "$DEST"
assert_status "an unremovable link aborts" nonzero $status
capture_both
assert_contains "it names the link it could not remove" "$WORK/both" 'Failed to remove'

# These flags are gone and nothing remaps them, so an invocation written against
# the old spelling fails loudly rather than installing something the caller did
# not ask for.
#
# That is the policy for a flag that was *removed*. A flag that was *reassigned*
# is deliberately different: -v selects verbose where it once printed the
# version, and the cases below pin it doing so. Stating the removal policy
# without that scope would read as a rule the suite itself contradicts.
echo "[removed flags are rejected]"
for gone in --symlink --symlink-force; do
  reset_dest
  run "$WORK/o" "$WORK/e" "$gone"
  assert_status "$gone aborts with non-zero status" nonzero $?
  capture_both
  assert_contains "$gone is reported as an unknown option" "$WORK/both" "Unknown option: $gone"
  assert_true "$gone installed nothing" test ! -e "$DEST/alpha"
done

# Usage printed because a run failed is part of the failure, so it goes where the
# error went. `--help`, which asks for the same text, keeps it on stdout.
echo "[usage on failure goes to stderr, usage on request does not]"
run_at "$WORK/proj" "$DEST" "$WORK/o" "$WORK/e"
assert_status "no argument at all aborts" nonzero $?
assert_contains "the usage lines are on stderr" "$WORK/e" '^Usage: add-skill'
assert_absent "and not on stdout" "$WORK/o" '^Usage: add-skill'

run "$WORK/o" "$WORK/e" --no-such-flag
assert_status "an unknown option aborts" nonzero $?
assert_contains "the help it prints is on stderr" "$WORK/e" 'Show this help message'
assert_absent "and not on stdout" "$WORK/o" 'Show this help message'

run_bare --help
assert_status "--help exits 0" zero $?
assert_contains "--help writes to stdout, where it was asked for" "$WORK/o" 'Show this help message'
assert_true "and leaves stderr empty" test ! -s "$WORK/e"

# --install symlinks the script into ~/.local/bin. When the script being run is
# already the real file at that path, resolving it yields the destination
# itself, and removing-then-linking would destroy the only copy.
echo "[--install leaves a copy already at the destination alone]"
fake_home copy
cp "$ADD_SKILL" "$FAKE_HOME/.local/bin/add-skill"
chmod +x "$FAKE_HOME/.local/bin/add-skill"
install_at "$FAKE_HOME" "$FAKE_HOME/.local/bin/add-skill"
assert_status "--install onto its own location exits 0" zero $?
assert_true "the script is still a regular file" test -f "$FAKE_HOME/.local/bin/add-skill"
assert_true "the script was not replaced by a symlink" test ! -L "$FAKE_HOME/.local/bin/add-skill"
assert_true "the script still has content" test -s "$FAKE_HOME/.local/bin/add-skill"
capture_both
assert_contains "it still says where PATH stands" "$WORK/both" 'PATH'

# --install has its own informational output, so the quiet level has to cover it
# too — in both PATH branches, since the one that reports trouble routes its
# whole message to stderr while the one that reports success is a print_info.
fake_home quiet
PATH="$FAKE_HOME/.local/bin:/usr/bin:/bin" install_at "$FAKE_HOME" "$ADD_SKILL" --quiet
assert_status "--install --quiet exits 0 with the directory on PATH" zero $?
assert_true "and writes nothing to stdout" test ! -s "$WORK/o"
assert_true "the symlink was still made" test -L "$FAKE_HOME/.local/bin/add-skill"

fake_home quiet-nopath
PATH="/usr/bin:/bin" install_at "$FAKE_HOME" "$ADD_SKILL" --quiet
assert_status "--install --quiet exits 0 with it off PATH" zero $?
assert_true "and still writes nothing to stdout" test ! -s "$WORK/o"
assert_contains "the PATH warning goes to stderr" "$WORK/e" 'is not in your PATH'

# A multi-line diagnostic has to arrive whole on one stream. The PATH warning is
# the longest one the script has: a warning line, a lead-in, and a per-shell
# configuration block. Routing only the warning would leave the block behind.
echo "[a multi-line diagnostic is not split across streams]"
fake_home path
PATH="/usr/bin:/bin" install_at "$FAKE_HOME" "$ADD_SKILL"
assert_contains "the PATH warning is on stderr" "$WORK/e" 'is not in your PATH'
assert_contains "and so is the block that explains it" "$WORK/e" 'fish_add_path'
assert_absent "with nothing of it left on stdout" "$WORK/o" 'fish_add_path'

# --install's own filesystem calls report the same way the skill path's do.
echo "[--install reports what it could not do]"
FAKE_LN="$WORK/home-ln"
mkdir -p "$FAKE_LN/.local/bin" && chmod a-w "$FAKE_LN/.local/bin"
install_at "$FAKE_LN" "$ADD_SKILL"
status=$?
chmod u+w "$FAKE_LN/.local/bin"
assert_status "--install aborts when it cannot link" nonzero $status
capture_both
assert_contains "--install says it could not link" "$WORK/both" 'Failed to symlink'

# An entry already at the destination, in a directory that cannot be written:
# this reaches the removal rather than the link.
FAKE_RM="$WORK/home-rm"
mkdir -p "$FAKE_RM/.local/bin" && : >"$FAKE_RM/.local/bin/add-skill"
chmod a-w "$FAKE_RM/.local/bin"
install_at "$FAKE_RM" "$ADD_SKILL"
status=$?
chmod u+w "$FAKE_RM/.local/bin"
assert_status "--install aborts when it cannot remove what is there" nonzero $status
capture_both
assert_contains "--install says it could not remove it" "$WORK/both" 'Failed to remove'

FAKE_MK="$WORK/home-mk"
mkdir -p "$FAKE_MK/.local" && chmod a-w "$FAKE_MK/.local"
install_at "$FAKE_MK" "$ADD_SKILL"
status=$?
chmod u+w "$FAKE_MK/.local"
assert_status "--install aborts when it cannot create the directory" nonzero $status
capture_both
assert_contains "--install says it could not create it" "$WORK/both" 'Failed to create'

# Removing write permission leaves the directory enterable; removing execute
# permission does not, and that reaches a different call.
FAKE_X="$WORK/home-x"
mkdir -p "$FAKE_X/.local/bin" && chmod a-x "$FAKE_X/.local/bin"
install_at "$FAKE_X" "$ADD_SKILL"
status=$?
chmod u+x "$FAKE_X/.local/bin"
assert_status "--install aborts when it cannot enter the directory" nonzero $status
capture_both
assert_contains "--install says it could not enter it" "$WORK/both" 'Failed to enter'

echo "[the three verbosity levels]"
reset_dest
run "$WORK/o" "$WORK/e"
assert_status "the default level exits 0" zero $?
# Exactly three: Source, Destination, and the summary. A replaced-list line
# joins them only when something was replaced, and nothing here was — so an
# upper bound would leave room for a stray line this is meant to catch.
assert_true "the default level prints exactly three lines" test "$(wc -l <"$WORK/o")" -eq 3
assert_contains "it gives the count and both names" "$WORK/o" 'Symlinked 2 skills:.*alpha.*bravo'
assert_absent "and no per-skill line" "$WORK/o" 'Creating symlink for'

reset_dest
run "$WORK/o" "$WORK/e" --verbose
assert_status "--verbose exits 0" zero $?
assert_contains "--verbose announces each skill" "$WORK/o" 'Creating symlink for alpha\.\.\.'
assert_contains "and reports each one linked" "$WORK/o" 'Symlinked alpha:'
assert_absent "and prints no summary line" "$WORK/o" 'Symlinked 2 skills:'

reset_dest
run "$WORK/o" "$WORK/e" -v
assert_status "-v is --verbose" zero $?
assert_contains "-v announces each skill too" "$WORK/o" 'Creating symlink for alpha\.\.\.'

# Byte-empty rather than a line count: wc -l counts newlines, so output carrying
# none — a printf without one, a partial line left behind — reads as zero lines
# while the stream is not in fact silent.
reset_dest
run "$WORK/o" "$WORK/e" --quiet
assert_status "--quiet exits 0" zero $?
assert_true "--quiet writes nothing to stdout" test ! -s "$WORK/o"
assert_true "--quiet still installs" test -L "$DEST/alpha"
assert_true "both of them" test -L "$DEST/bravo"

reset_dest
run "$WORK/o" "$WORK/e" -q
assert_status "-q is --quiet" zero $?
assert_true "-q writes nothing to stdout either" test ! -s "$WORK/o"

# Quiet suppresses information, not diagnosis.
reset_dest
real_entry_at alpha
run "$WORK/o" "$WORK/e" --quiet
assert_status "--quiet over a refused destination still aborts" nonzero $?
assert_true "--quiet still writes nothing to stdout" test ! -s "$WORK/o"
assert_contains "and the reason is still on stderr" "$WORK/e" '\[ERROR\]'
rm -rf "${DEST:?}/alpha"

# No level prints a banner; this is not gated on verbosity.
for level in "" --verbose --quiet; do
  reset_dest
  run "$WORK/o" "$WORK/e" $level
  assert_absent "no banner at the ${level:-default} level" "$WORK/o" 'Skills Installation'
done

echo "[the version flag is -V]"
run_bare -V
assert_status "-V exits 0" zero $?
assert_contains "-V prints the version" "$WORK/o" '^add-skill [0-9]'
run_bare --version
assert_contains "--version still does too" "$WORK/o" '^add-skill [0-9]'
# -v selects verbose, so on its own it reaches the missing-argument path rather
# than printing a version.
run_at "$WORK/proj" "$DEST" "$WORK/o" "$WORK/e" -v
assert_status "-v alone aborts" nonzero $?
assert_absent "-v does not print the version" "$WORK/o" '^add-skill [0-9]'

# The other old spelling of the same flag: with a repository argument, -v parses
# fine and installs. That is a deliberate reassignment rather than an oversight,
# so it is pinned here — otherwise nothing would notice it drifting back.
reset_dest
run "$WORK/o" "$WORK/e" -v
assert_status "<repo> -v exits 0" zero $?
assert_true "and installs, rather than printing a version" test -L "$DEST/alpha"
assert_absent "no version in its output" "$WORK/o" '^add-skill [0-9]'
assert_contains "with per-skill lines, so it selected verbose" "$WORK/o" 'Creating symlink for alpha'

# The not-found branch of the listing routes its warning and that warning's own
# trailing blank to stderr, while the else branch keeps the listing's blank on
# stdout. Both halves are new, and a repository whose skills/ holds a directory
# with no SKILL.md is what reaches the first.
echo "[a source with no installable skill says so on stderr]"
EMPTY="$WORK/emptyrepo"
mkdir -p "$EMPTY/skills/not-a-skill"
run_at "$EMPTY" "$DEST" "$WORK/o" "$WORK/e" "$EMPTY" --list
assert_status "--list over it exits 0" zero $?
assert_contains "the warning is on stderr" "$WORK/e" 'No skills found'
assert_absent "and not on stdout" "$WORK/o" 'No skills found'
# The blank that closes the warning goes with it, so stdout carries the header
# and its spacing and nothing else.
assert_true "stdout holds only the header and its blanks" test "$(wc -l <"$WORK/o")" -eq 3

# Discovery has three modes and each closes its listing with its own blank, so the
# quiet gating has to hold in all three. The multi-skill mode is covered above;
# these are the other two.
echo "[--list in the other two discovery modes]"
ONE="$WORK/onerepo"
mkdir -p "$ONE"
write_skill_md "$ONE" onerepo
run_at "$ONE" "$DEST" "$WORK/o" "$WORK/e" "$ONE" --list
assert_status "--list over a single-skill repo exits 0" zero $?
assert_contains "it names the repo's own skill" "$WORK/o" '• onerepo'
run_at "$ONE" "$DEST" "$WORK/o" "$WORK/e" "$ONE" --list --quiet
assert_contains "the entry survives --quiet" "$WORK/o" '• onerepo'
assert_false "and the blanks around it do not" grep -q '^$' "$WORK/o"

# Marketplace mode reads the manifest with jq, so it is only constructible where
# jq is installed. Counted when skipped, so the summary says so rather than the
# coverage quietly shrinking.
MKT="$WORK/mktrepo"
mkdir -p "$MKT/.claude-plugin" "$MKT/pkg/mskill"
write_skill_md "$MKT/pkg/mskill" mskill
printf '{"plugins":[{"skills":["./pkg/mskill"]}]}\n' >"$MKT/.claude-plugin/marketplace.json"
if command -v jq >/dev/null 2>&1; then
  run_at "$MKT" "$DEST" "$WORK/o" "$WORK/e" "$MKT" --list
  assert_status "--list over a marketplace repo exits 0" zero $?
  assert_contains "it names the skill the manifest lists" "$WORK/o" '• mskill'
  run_at "$MKT" "$DEST" "$WORK/o" "$WORK/e" "$MKT" --list --quiet
  assert_contains "the entry survives --quiet there too" "$WORK/o" '• mskill'
  assert_false "and its blanks do not" grep -q '^$' "$WORK/o"
else
  skipped 4 "jq is not installed; marketplace-mode discovery is not exercised"
fi

echo "[--list keeps its entries at the quiet level]"
run "$WORK/o" "$WORK/e" --list --quiet
assert_status "--list --quiet exits 0" zero $?
assert_contains "the entries survive" "$WORK/o" '• alpha'
# The same guarantee is stated for the whole family, so each member needs its own
# reader; asserting it for --list alone would leave the other two unguarded.
#
# --quiet first, and that order is the whole point: --help and --version exit
# from inside the parse loop, so with either of them leading, --quiet is never
# reached and the assertion would hold however quiet behaved.
run_bare --quiet --help
assert_status "--quiet --help exits 0" zero $?
assert_contains "--help prints under --quiet" "$WORK/o" 'Show this help message'
run_bare --quiet -V
assert_status "--quiet -V exits 0" zero $?
assert_contains "the version prints under --quiet" "$WORK/o" '^add-skill [0-9]'
run "$WORK/o" "$WORK/e" --list --quiet
assert_contains "both of them" "$WORK/o" '• bravo'
assert_absent "the header does not" "$WORK/o" 'Available skills in'
# On the blanks themselves rather than a line count, which would also move if
# the per-entry output ever changed.
assert_false "and neither do the blanks around them" grep -q '^$' "$WORK/o"

echo "[the summary never fires where nothing was installed]"
for flag in --help -V --list; do
  run "$WORK/o" "$WORK/e" "$flag"
  assert_absent "$flag prints no install summary" "$WORK/o" 'Symlinked [0-9]* skill'
done

# The EXIT trap is what reports a run that aborts partway: install_skill is a
# bare command, so set -e ends the script at the failing call and anything
# placed after the loop never runs. alpha links, then a name the source does not
# have fails — the summary must still name what landed, and the status must
# still be the failure's.
echo "[an aborted run still reports what it installed]"
reset_dest
run "$WORK/o" "$WORK/e" --skill alpha --skill nosuch
assert_status "the aborted run exits non-zero" nonzero $?
assert_true "alpha did land" test -L "$DEST/alpha"
assert_contains "and the summary says so" "$WORK/o" 'Symlinked 1 skill: alpha'

# A skill name is attacker-controlled as far as this script is concerned: it is
# whatever directory the source repository happens to hold. echo -e would turn a
# backslash sequence in one into a real escape on output, so a redirected log
# picks up escapes the color gate never emitted.
echo "[a skill name cannot inject an escape]"
EVIL="$WORK/evil"
mkdir -p "$EVIL/repo/skills/lit\\033[31mRED" "$EVIL/dest"
write_skill_md "$EVIL/repo/skills/lit\\033[31mRED" evil
run_at "$EVIL" "$EVIL/dest" "$WORK/o" "$WORK/e" "$EVIL/repo"
assert_status "a skill whose name looks like an escape installs" zero $?
assert_false "no escape reached stdout" grep -q $'\033' "$WORK/o"
assert_false "nor stderr" grep -q $'\033' "$WORK/e"

# Quoting is applied only where it is needed. On the bash the shebang selects,
# printf %q mangles a multibyte name — escaping some of its bytes and leaving the
# rest raw — so quoting unconditionally would report a skill named outside ASCII
# as a mixture that reads as neither, and at the default level the summary is the
# whole report. A name that needs no quoting must therefore arrive intact.
echo "[a name needing no quoting is reported as it is]"
UTF="$WORK/utf8"
utf_name=$(printf '\346\227\245\346\234\254\350\252\236')
mkdir -p "$UTF/repo/skills/$utf_name" "$UTF/dest"
write_skill_md "$UTF/repo/skills/$utf_name" utf
run_at "$UTF" "$UTF/dest" "$WORK/o" "$WORK/e" "$UTF/repo"
assert_status "a non-ASCII skill name installs" zero $?
assert_contains "and the summary shows it, not its bytes" "$WORK/o" "$utf_name"
# Any backslash-octal triple, not just one starting in 3: quoting a UTF-8 name on
# bash 3.2 leaves some bytes raw and escapes others, and which ones depends on the
# name. Anchoring on a particular leading digit made this inert for the very case
# it guards.
assert_absent "with no octal escaping" "$WORK/o" '\\[0-7][0-7][0-7]'
# One skill, so the noun agrees with the count.
assert_contains "the count reads as one skill" "$WORK/o" 'Symlinked 1 skill:'

# A name can also hold a real escape byte, which no output discipline removes —
# it is the caller's data, not this script's formatting. The two levels differ
# there, and the difference is what the docs claim, so both halves are pinned:
# the summary quotes the name, and --verbose reproduces it. Asserting only the
# default level would let the verbose path drift behind a passing suite.
RAW="$WORK/rawesc"
raw_name=$(printf 'raw\033[31mRED')
mkdir -p "$RAW/repo/skills/$raw_name" "$RAW/dest"
write_skill_md "$RAW/repo/skills/$raw_name" raw
run_at "$RAW" "$RAW/dest" "$WORK/o" "$WORK/e" "$RAW/repo"
assert_status "a name holding a real escape byte installs" zero $?
assert_false "the summary carries no raw escape" grep -q $'\033' "$WORK/o"
# The name still reaches the summary — the pair of this and the no-escape check
# above is what says it arrived in some shown form rather than as the raw bytes.
# This half alone does not pin the quoting, and does not claim to.
assert_contains "while the name still reaches it" "$WORK/o" "Symlinked 1 skill:.*raw"

rm -rf "${RAW:?}/dest"
mkdir -p "$RAW/dest"
run_at "$RAW" "$RAW/dest" "$WORK/o" "$WORK/e" "$RAW/repo" --verbose
assert_status "and installs under --verbose too" zero $?
assert_true "where the name is reproduced as it is" grep -q $'\033' "$WORK/o"

# Color needs a terminal, and every fixture above redirects both streams to
# files, so [ -t 1 ] and [ -t 2 ] are false throughout and the color-on branch is
# unreachable without a pty. script(1) supplies one; the two implementations
# spell it differently — BSD, which macOS ships, takes the command as trailing
# arguments, util-linux takes it through -c — so both are tried rather than
# assuming one and skipping everyone on the other.
#
# Unlike the unwritable-directory probe near the top, a miss here does not exit.
# That one exits because without it the failure assertions run against a user who
# writes anyway, and go red against correct code. A miss here leaves the
# color-on assertions unconstructible — absent rather than wrong — so a printed
# note is what keeps the gap visible.
echo "[color is gated on the stream and on NO_COLOR]"
# Several attempts per spelling, not one. Allocating a pty fails transiently
# under load, and that miss is indistinguishable at a single attempt from a
# platform that cannot supply one — so a single probe would hand the skip below a
# case it was never meant to cover, quietly dropping the colour assertions with
# only a note to show for it. Retrying is what separates "this platform cannot",
# where skipping is right, from "this attempt did not".
PTY=""
pty_tries=0
while [ -z "$PTY" ] && [ "$pty_tries" -lt 5 ]; do
  if script -q /dev/null /bin/bash -c 'test -t 1 && printf PTYOK' 2>/dev/null | grep -q PTYOK; then
    PTY=bsd
  elif script -q -c 'test -t 1 && printf PTYOK' /dev/null 2>/dev/null | grep -q PTYOK; then
    PTY=util
  fi
  pty_tries=$((pty_tries + 1))
done

# pty_run <shell-command-string> — run it with stdout, and stderr, on a pty.
pty_run() {
  case "$PTY" in
  bsd) script -q /dev/null /bin/bash -c "$1" ;;
  util) script -q -c "$1" /dev/null ;;
  esac
}

# mkcmd <env-assignments> — the standard install, as one shell command string.
# The assignments land on add-skill itself: prefixing the leading cd instead
# would scope them to that builtin and leave the run without them.
mkcmd() {
  printf 'cd %q && %s SKILLS_INSTALL_PATH=%q %q %q' \
    "$WORK/proj" "$1" "$DEST" "$ADD_SKILL" "$SRC"
}

if [ -z "$PTY" ]; then
  skipped 6 "script(1) supplied no pty in $pty_tries attempts of either spelling;" \
    "the color-on branch is not exercised"
else
  reset_dest
  pty_run "$(mkcmd '')" >"$WORK/o" 2>&1
  assert_true "on a terminal the output is colored" grep -q $'\033' "$WORK/o"

  reset_dest
  pty_run "$(mkcmd 'NO_COLOR=1')" >"$WORK/o" 2>&1
  assert_false "NO_COLOR turns it off" grep -q $'\033' "$WORK/o"

  # The standard disables color when NO_COLOR is present *and not empty*, so an
  # empty value is not a request for monochrome.
  reset_dest
  pty_run "$(mkcmd 'NO_COLOR=')" >"$WORK/o" 2>&1
  assert_true "an empty NO_COLOR leaves it on" grep -q $'\033' "$WORK/o"

  # The case a single shared gate cannot get right: stdout is a terminal and
  # stderr is not, so the error stream must come out clean while stdout does not.
  reset_dest
  real_entry_at alpha
  pty_run "$(mkcmd '') 2>$(printf '%q' "$WORK/e")" >"$WORK/o" 2>/dev/null
  assert_contains "the refusal still reaches the redirected stderr" "$WORK/e" '\[ERROR\]'
  assert_false "with no escape in it" grep -q $'\033' "$WORK/e"
  assert_true "while the terminal stdout keeps its color" grep -q $'\033' "$WORK/o"
  rm -rf "${DEST:?}/alpha"
fi

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
(cd "$WORK/proj" && SKILLS_INSTALL_PATH="$DEST" "$ADD_SKILL" "$SRC" <&9 >/dev/null 2>&1) &
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
# The skipped count belongs on this line rather than only in a note further up.
# A guarded block that does not run lowers PASS silently, and the line a reader
# actually compares between runs is this one — without the count, a drop reads as
# nothing at all.
if [ "$SKIPPED" -gt 0 ]; then
  echo "passed: $PASS  failed: $FAIL  skipped: $SKIPPED"
else
  echo "passed: $PASS  failed: $FAIL"
fi
[ "$FAIL" -eq 0 ]

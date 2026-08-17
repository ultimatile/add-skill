# add-skill

Install skills from a local repository to Claude Code, Codex, or Kiro CLI.

## Install

```bash
# Symlink add-skill to ~/.local/bin
./add-skill --install
```

## Usage

```bash
add-skill <skills-repo-path> [options]
```

The source repository must have either a `.claude-plugin/marketplace.json` (preferred), a `skills/` directory containing skill subdirectories with `SKILL.md`, or a `SKILL.md` at the repo root.

### Basic

```bash
# List available skills
add-skill ~/my-skills-repo --list

# Install all skills (to ./.claude/skills)
add-skill ~/my-skills-repo

# Install specific skills
add-skill ~/my-skills-repo --skill my-skill --skill another-skill

# Replace a real file or directory sitting at the destination
add-skill ~/my-skills-repo --force --all
```

### Target Agents

By default, skills install to `./.claude/skills` (Claude Code). Use flags to target other agents:

| Flag | Location | Scope |
|------|----------|-------|
| *(default)* | `./.claude/skills` | Claude Code (project) |
| `--global` | `~/.claude/skills` | Claude Code (global) |
| `--codex` | `~/.agents/skills` | Codex (global) |
| `--codex-repo` | `./.agents/skills` | Codex (project) |
| `--kiro` | `~/.kiro/skills` | Kiro (global) |
| `--kiro-repo` | `./.kiro/skills` | Kiro (project) |

```bash
# Claude Code (global)
add-skill ~/my-skills-repo --global --all

# Codex (global)
add-skill ~/my-skills-repo --codex --all

# Codex (project)
add-skill ~/my-skills-repo --codex-repo --all

# Kiro (global)
add-skill ~/my-skills-repo --kiro --all

# Kiro (project)
add-skill ~/my-skills-repo --kiro-repo --all
```

Codex searches project-level locations before global ones, but same-name skills are not merged or overridden — both can show up in the skill selector. For Kiro, project-level skills override global skills with the same name.

### What happens at the destination

Each skill is installed as a symlink pointing at the source repository, so an edit there is live in every project that installed from it, with no reinstall in between.

What `add-skill` does with whatever already sits at a skill's destination:

- A **symlink** is replaced. It is unlinked rather than followed, so whatever it pointed at is untouched.
- A **real file or directory** is refused, and the message says so. Pass `--force` to replace it. Since `add-skill` only ever creates symlinks, a real entry there is something else — a hand-written skill, or an install from a version that still copied.

An install whose destination is, or contains, its own source is refused. A destination *inside* the source is not — a repository that is itself a skill can install into the `.claude/skills` within it.

Nothing prompts for confirmation — if a skill cannot be installed, `add-skill` reports the reason and exits non-zero without installing the rest.

### Environment Variable

```bash
# Override the installation path
SKILLS_INSTALL_PATH=/custom/path add-skill ~/my-skills-repo
```

## Tests

```bash
./tests/smoke.sh
```

Builds a throwaway skills repository and installs from it, covering the successful path, the destination guard, and the failure path. Exits non-zero if any assertion fails. Set `ADD_SKILL` to test a different copy of the script.

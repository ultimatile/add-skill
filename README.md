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

# Install all skills (copy mode, to ./.claude/skills)
add-skill ~/my-skills-repo

# Install specific skills
add-skill ~/my-skills-repo --skill my-skill --skill another-skill

# Install with symlinks (recommended — auto-updates on git pull)
add-skill ~/my-skills-repo --symlink --all
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
add-skill ~/my-skills-repo --symlink --global --all

# Codex (global)
add-skill ~/my-skills-repo --symlink --codex --all

# Codex (project)
add-skill ~/my-skills-repo --symlink --codex-repo --all

# Kiro (global)
add-skill ~/my-skills-repo --symlink --kiro --all

# Kiro (project)
add-skill ~/my-skills-repo --symlink --kiro-repo --all
```

Codex searches project-level locations before global ones, but same-name skills are not merged or overridden — both can show up in the skill selector. For Kiro, project-level skills override global skills with the same name.

### Symlink vs Copy

- **Copy** (default): Self-contained. Requires reinstall after updating the source repo.
- **Symlink** (`--symlink`): References the source repo directly. Updates automatically on `git pull`.
- **Symlink force** (`--symlink-force`): Same as `--symlink`, but also replaces a real file or directory at the destination.

A symlink left by an earlier install is replaced in every mode, and is unlinked rather than followed, so whatever it points at is untouched. A real file or directory at the destination is replaced by copy mode and by `--symlink-force`; plain `--symlink` refuses it and says so. An install whose destination is, or contains, its own source is refused. A destination *inside* the source is fine — that is what a repository which is itself a skill does when it installs into the `.claude/skills` within it.

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

Builds a throwaway skills repository and installs from it, covering both the successful modes and the failure path. Exits non-zero if any assertion fails. Set `ADD_SKILL` to test a different copy of the script.

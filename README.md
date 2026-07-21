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
| `--codex` | `~/.codex/skills` | Codex (global) |
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

For Codex and Kiro, project-level skills override global skills with the same name.

### Symlink vs Copy

- **Copy** (default): Self-contained. Requires reinstall after updating the source repo.
- **Symlink** (`--symlink`): References the source repo directly. Updates automatically on `git pull`.
- **Symlink force** (`--symlink-force`): Same as `--symlink` but overwrites existing files without prompt.

### Environment Variable

```bash
# Override the installation path
SKILLS_INSTALL_PATH=/custom/path add-skill ~/my-skills-repo
```

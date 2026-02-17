# Custom Skills Repository

This repository contains custom skills for Claude.

## Structure

**Initial state (before creating any skills):**

```
.
├── .claude-plugin/        # Plugin configuration
│   └── marketplace.json
├── skills/                # Template and your custom skills
│   └── SKILL.md           # Template SKILL.md (use once for first skill)
├── install-skills.sh      # Installation script
└── README.md
```

**After creating skills:**

```
.
├── .claude-plugin/
│   └── marketplace.json
├── skills/
│   ├── your-skill/        # Your actual skills as subdirectories
│   │   ├── SKILL.md       # Required for each skill
│   │   ├── scripts/       # Optional: Executable scripts
│   │   ├── references/    # Optional: Reference documentation
│   │   └── assets/        # Optional: Templates, images, fonts, etc.
│   └── another-skill/
│       └── SKILL.md
├── install-skills.sh
└── README.md
```

**Note**:

- The root `skills/SKILL.md` is a one-time template that moves to your first skill
- Each skill subdirectory must contain its own `SKILL.md`
- Additional directories (`scripts/`, `references/`, `assets/`) are optional and should only be created if needed

## Creating a New Skill

### Option 1: Manual Creation

#### Creating Your First Skill

1. Move the template SKILL.md to create your first skill:

   ```bash
   # Create new skill directory and move template
   mkdir -p skills/your-skill-name
   mv skills/SKILL.md skills/your-skill-name/
   ```

2. Edit `skills/your-skill-name/SKILL.md`:
   - Update `name` to match your skill folder name
   - Write a comprehensive `description` (this is how Claude decides when to use the skill)
   - Add your instructions in the body

3. Add optional resource directories as needed:

   ```bash
   # Only create these if you need them
   mkdir -p skills/your-skill-name/scripts      # For Python/Bash scripts
   mkdir -p skills/your-skill-name/references   # For reference documentation
   mkdir -p skills/your-skill-name/assets       # For templates, images, fonts, etc.
   ```

   **When to use each:**
   - `scripts/` - Deterministic operations, command-line tools, data processing
   - `references/` - Long-form documentation, API references, examples
   - `assets/` - Files used in output (templates, images, fonts, config files)

#### Creating Additional Skills

After creating your first skill, use one of these methods for additional skills:

**Option A: Copy from existing skill**

```bash
# Copy an existing skill as a starting point
cp -r skills/existing-skill skills/new-skill-name
# Then edit the new skill's SKILL.md
```

**Option B: Create from scratch**

```bash
# Create new skill directory
mkdir -p skills/new-skill-name

# Create SKILL.md manually
cat > skills/new-skill-name/SKILL.md << 'EOF'
---
name: new-skill-name
description: What this skill does and when to use it
---

# Skill Instructions

Your skill instructions here...
EOF
```

### Option 2: Using skill-creator (from Anthropic repo)

If you have access to the Anthropic skills repository's `skill-creator`:

```bash
python /path/to/skill-creator/scripts/init_skill.py your-skill-name --path ./skills/
```

This will automatically create the skill structure and template files.

## Plugin Configuration (marketplace.json)

After creating a new skill, update `.claude-plugin/marketplace.json` to register it:

### Initial Setup

Edit `.claude-plugin/marketplace.json` with your repository information:

```json
{
  "name": "your-repo-name",
  "owner": {
    "name": "your-github-username",
    "email": "your-email@example.com"
  },
  "metadata": {
    "description": "Description of your skills collection",
    "version": "1.0.0"
  },
  "plugins": [
    {
      "name": "custom-skills",
      "description": "Your custom Claude skills collection",
      "source": "./",
      "strict": false,
      "skills": [
        "./skills/your-skill-name"
      ]
    }
  ]
}
```

### Adding Skills

When you create a new skill, add its path to the `skills` array:

```json
"skills": [
  "./skills/skill-one",
  "./skills/skill-two",
  "./skills/skill-three"
]
```

## Using with Codex (experimental)

Codex loads skills from multiple locations with different precedence levels. To install this repository's skills for Codex:

1. Enable the experimental feature flag in `~/.codex/config.toml`:

   ```toml
   [features]
   skills = true
   ```

2. Install the skills to Codex's path:

   ```bash
   # Option A: Repository-level (highest precedence, recommended for team use)
   ./install-skills.sh --codex-repo --all

   # Option B: User-level (global, lower precedence)
   ./install-skills.sh --codex --all

   # Option C: With symlinks (recommended for development)
   ./install-skills.sh --symlink --codex-repo --all
   ```

3. Restart Codex so it reloads the newly installed skills.

### Codex Skill Locations

Codex loads skills from these locations in order of precedence (high to low):

| Option | Location | Precedence | Use Case |
|--------|----------|------------|----------|
| `--codex-repo` | `./.codex/skills` | High | Repository-specific skills, team collaboration |
| `--codex` | `~/.codex/skills` | Low | User-specific skills, personal use |

**Recommendations:**
- Use `--codex-repo` for team-shared skills that should be available to everyone working on the repository
- Use `--codex` for personal skills that apply across all your projects
- Use `--symlink` with either option to enable automatic updates when you `git pull`

Notes:
- Repository-level skills (`./.codex/skills`) override user-level skills with the same name
- Each skill must reside in its own directory with `name`/`description` kept to one line and within Codex limits (≤100/≤500 chars respectively)
- Using `--symlink` allows automatic updates when you `git pull` in the repository

**Important**: The skill path format is `"./skills/skill-name"` where `skill-name` matches the directory name under `skills/`.

## Using with Kiro

Kiro loads skills from multiple locations with different precedence levels. To install this repository's skills for Kiro:

1. Install the skills to Kiro's path:

   ```bash
   # Option A: Repository-level (highest precedence, recommended for team use)
   ./install-skills.sh --kiro-repo --all

   # Option B: User-level (global, lower precedence)
   ./install-skills.sh --kiro --all

   # Option C: With symlinks (recommended for development)
   ./install-skills.sh --symlink --kiro-repo --all
   ```

2. Restart Kiro so it reloads the newly installed skills.

### Kiro Skill Locations

Kiro loads skills from these locations in order of precedence (high to low):

| Option | Location | Precedence | Use Case |
|--------|----------|------------|----------|
| `--kiro-repo` | `./.kiro/skills` | High | Repository-specific skills, team collaboration |
| `--kiro` | `~/.kiro/skills` | Low | User-specific skills, personal use |

**Recommendations:**
- Use `--kiro-repo` for team-shared skills that should be available to everyone working on the repository
- Use `--kiro` for personal skills that apply across all your projects
- Use `--symlink` with either option to enable automatic updates when you `git pull`

Notes:
- Repository-level skills (`./.kiro/skills`) override user-level skills with the same name
- Using `--symlink` allows automatic updates when you `git pull` in the repository

## Skill Design Principles

1. **Concise descriptions** - The context window is shared
2. **Progressive disclosure** - Keep SKILL.md under 500 lines, use `references/` for details
3. **Clear triggers** - Specify when Claude should use this skill in the description
4. **Minimal structure** - Start with just SKILL.md, only add directories when needed
5. **Self-contained** - Include all necessary scripts and references within the skill folder

## Using Your Skills

There are three ways to use your skills:

### Option 1: Direct Installation (Single Project)

Copy skills directly to your project:

```bash
# From this repository - installs all skills in skills/*/
./install-skills.sh

# List available skills first
./install-skills.sh --list

# Install specific skills only
./install-skills.sh --skill your-skill-name

# Install with symlinks (recommended for development)
./install-skills.sh --symlink --all

# Install with symlinks, forcefully overwriting existing files
./install-skills.sh --symlink-force --all

# Or manually copy individual skill
cp -r skills/your-skill-name ~/.claude/skills/your-skill-name
```

Skills in `.claude/skills/` are automatically detected by Claude Code. No additional configuration needed.

**Symlink vs Copy Mode:**

- **Copy mode** (default): Skills are copied to the installation directory
  - Pros: Self-contained, won't break if source repository is moved/deleted
  - Cons: Need to reinstall after updating the repository

- **Symlink mode** (`--symlink`): Skills are symlinked to the source repository
  - Pros: Updates automatically when you `git pull` in the source repository
  - Cons: Requires the source repository to remain in place
  - Recommended for: Active development, keeping skills up-to-date
  - Note: If symlink creation fails, you'll be prompted to confirm force overwrite

- **Symlink force mode** (`--symlink-force`): Same as symlink mode but forcefully overwrites existing files
  - Use when: You want to replace existing files without being prompted

**Note**: The install script only installs skill subdirectories (e.g., `skills/your-skill/`), not the template files in the root `skills/` directory.

### Option 2: Plugin Installation (Multiple Projects)

Install this repository as a plugin:

```bash
/plugin install /path/to/this/repo
```

This makes all skills available across all your projects.

### Option 3: Team-Wide Marketplace (Advanced)

For team-wide skill distribution, configure the marketplace in your project's `.claude/settings.json`.

#### Step 1: Locate or Create settings.json

Create `.claude/settings.json` in your project root if it doesn't exist:

```bash
mkdir -p .claude
touch .claude/settings.json
```

#### Step 2: Add Marketplace Configuration

Add the following to `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "custom-skills": {
      "source": {
        "source": "github",
        "repo": "your-username/your-skills-repo"
      }
    }
  },
  "enabledPlugins": {
    "custom-skills@custom-skills": true
  }
}
```

Replace:

- `"custom-skills"` - Your marketplace name (can be any identifier)
- `"your-username/your-skills-repo"` - Your GitHub repository (e.g., "ultimatile/skills-template")
- `"custom-skills@custom-skills"` - Format is `plugin-name@marketplace-name`
  - First part: matches `name` field in `.claude-plugin/marketplace.json`
  - Second part: matches the marketplace identifier you defined above

#### Step 3: Alternative Source Types

You can also use Git URLs or local paths:

**Git repository:**

```json
{
  "extraKnownMarketplaces": {
    "team-skills": {
      "source": {
        "source": "git",
        "url": "https://gitlab.com/company/skills.git"
      }
    }
  }
}
```

**Local path (for development):**

```json
{
  "extraKnownMarketplaces": {
    "local-skills": {
      "source": {
        "source": "local",
        "path": "/absolute/path/to/skills-repo"
      }
    }
  }
}
```

#### Step 4: Commit and Share

```bash
git add .claude/settings.json
git commit -m "Add custom skills marketplace"
git push
```

When team members clone the repository and trust the `.claude` directory in Claude Code, the marketplace and skills will be automatically available.

#### Merging with Existing settings.json

If you already have a `settings.json`, merge the configurations:

**Existing settings.json:**

```json
{
  "someOtherSetting": true,
  "extraKnownMarketplaces": {
    "existing-marketplace": {
      "source": { "source": "github", "repo": "example/repo" }
    }
  }
}
```

**After adding custom-skills:**

```json
{
  "someOtherSetting": true,
  "extraKnownMarketplaces": {
    "existing-marketplace": {
      "source": { "source": "github", "repo": "example/repo" }
    },
    "custom-skills": {
      "source": {
        "source": "github",
        "repo": "your-username/your-skills-repo"
      }
    }
  },
  "enabledPlugins": {
    "custom-skills@custom-skills": true
  }
}
```

### In Claude.ai

Upload the skill folder or packaged .skill file via the Skills menu.

## Resources

- [Agent Skills Specification](https://github.com/anthropics/skills/blob/main/spec/agent-skills-spec.md)
- [Creating Custom Skills Guide](https://support.claude.com/en/articles/12512198-creating-custom-skills)
- [Example Skills](https://github.com/anthropics/skills)

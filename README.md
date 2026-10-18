# agents-env

[English](README.md) | [简体中文](README.zh-CN.md)

One set of Skills and one set of Instructions, wired into every AI agent.

agents-env treats `.agents/skills/` and `AGENTS.md` as the single source of truth and connects them to each agent's private paths as declared in a registry: Skills through relative symlinks, Instructions through entry files that point back to the source. It works at both user scope and project scope.

---

## Why

Every agent you run has its own conventions: Skills go under `.<agent>/skills/`, rules go into `<AGENT>.md` or `.<agent>/rules/<entry-file>`. Maintaining this by hand breaks down quickly:

- **Copies drift apart**: the same Skill copied into N directories, updated in one and forgotten in the rest.
- **A quick `ln -s` causes damage**: a whole-directory link hides the agent's built-in system Skills, and absolute links break as soon as a directory moves or you switch machines.
- **Backups leak into git**: `.bak` files left behind by project-level overwrites show up in `git status` and get committed by accident.
- **Every new tool means starting over**: each additional agent means looking up where it reads from and hand-writing the links again.

agents-env records where each agent reads from, and how to connect it, in the registry `config/agents.json`. The scripts only carry out what the registry declares:

```text
~/.agents/skills/                    ← single source
├── alpha-skill/
└── beta-skill/

~/.<agent>/skills/
├── alpha-skill -> ../../.agents/skills/alpha-skill   ← relative symlink
├── beta-skill  -> ../../.agents/skills/beta-skill
└── <built-in skill>/                                 ← real directory, left untouched
```

## Key features

- **Never overwrites your own entries**: a same-named real directory, or a same-named symlink that points outside the store, is skipped and reported, never replaced. All validation runs before anything is written, so a failure leaves no partial result.
- **Reversible changes**: when `--force` replaces a Skill, the original moves to `<store>.local.bak/`, outside the shared store. An entry file with different content is first backed up as `<file>.local.bak`. The suffix matches the `*.local.*` rule found in common `.gitignore` files, so backups stay out of `git status`.
- **Relative symlinks**: links keep working after the whole tree is moved.
- **Fully declarative**: agent paths and link modes live only in the registry, and the scripts contain no vendor-specific branches. Adding an agent means editing the registry only; see the [registry guide](config/README.md).
- **Single file, pipe-friendly**: each script is self-contained, works with Bash 3.2+ and Zsh, and runs straight from `curl | bash`, with no Node.js or Python. See [Requirements](#requirements).

## Scopes

| | User `--scope user` | Project `--scope project` |
| :--- | :--- | :--- |
| Root | `$HOME` | Repository root (current directory by default, or `--target`) |
| Shared Skills store | `~/.agents/skills/` | `<repo>/.agents/skills/` |
| Instructions entry | e.g. `~/.<agent>/<entry-file>` | e.g. `<AGENT>.md` or `.<agent>/rules/<entry-file>` |
| Link mode | Declared per agent in the registry | Declared per agent in the registry |

The store location comes from `shared.skills_root` in the registry; the scripts don't assume it.

## Requirements

| Dependency | When it's needed |
| :--- | :--- |
| Bash 3.2+ or Zsh | Always |
| `jq` | Always, to read the registry |
| `git` | When `setup-skills.sh` fetches Skills with `--repo` |
| `curl` or `wget` | When a script runs outside a checkout of this repository (for example, `curl \| bash`), to download the registry and templates |

When a script runs inside a checkout of this repository, or `--source` points to one, it uses the local files and doesn't touch the network.

---

## Quick start

Run either script with no arguments to start the interactive wizard (arrow keys to move, Enter to confirm, `q` to quit).

Manage Skills:

```bash
curl -fsSL "https://raw.githubusercontent.com/xianghongai/agents-env/main/setup-skills.sh" | bash
```

Manage Instructions:

```bash
curl -fsSL "https://raw.githubusercontent.com/xianghongai/agents-env/main/setup-instructions.sh" | bash
```

Both scripts print the full plan first and only act after you confirm.

---

## Skills

`setup-skills.sh` does two things. **Fetch** pulls the Skills from a source repository into the shared store, incrementally. **Link** connects the store to each agent as declared in the registry. Without `--repo`, it only links.

Passing any argument switches to non-interactive mode. The script still asks for confirmation once before acting; `--yes` skips the prompt. Same-named Skills already in the store are kept unless you pass `--force`, which replaces them (and implies `--yes`).

Fetch into the user store and link:

```bash
curl -fsSL "https://raw.githubusercontent.com/xianghongai/agents-env/main/setup-skills.sh" \
  | bash -s -- --scope user --repo https://github.com/someone/my-skills.git
```

Fetch into the current repository's `.agents/skills/` and link (`cd` into the target repository first):

```bash
curl -fsSL "https://raw.githubusercontent.com/xianghongai/agents-env/main/setup-skills.sh" \
  | bash -s -- --scope project --repo https://github.com/someone/my-skills.git
```

Rebuild links from the registry without fetching:

```bash
curl -fsSL "https://raw.githubusercontent.com/xianghongai/agents-env/main/setup-skills.sh" \
  | bash -s -- --scope user
```

### Link modes

The registry declares a `mode` for each agent, separately for each scope:

| mode | What it does |
| :--- | :--- |
| `link-dir` | Links the agent's whole Skills directory to the store |
| `link-each` | Creates one symlink per Skill in the store, alongside the agent's own Skills |
| `none` | Creates no links, and removes symlinks in that directory that point into the store |

Linking only considers directories in the store that contain a `SKILL.md`. The tables below show the result for each thing that may already be in an agent's directory. Every "Skipped" entry is listed under "Needs attention" in the plan, and `--force` doesn't override it.

`link-each` works per Skill name in the store:

| Already at that name | Result |
| :--- | :--- |
| Nothing | A relative symlink is created |
| A correct relative symlink into the store | Left as is |
| A symlink into the store written differently (for example, an absolute path) | Replaced with the correct relative symlink |
| A symlink pointing outside the store, broken or not | Skipped |
| A real directory or file | Skipped |

Symlinks in the agent's directory that point into the store but no longer resolve to a Skill (left behind after a Skill is renamed or deleted) are removed. Alias symlinks are kept as long as they still resolve to a Skill. Everything else is left alone, such as the agent's built-in Skills and symlinks pointing elsewhere.

`link-dir` works on the agent's Skills directory as a whole:

| The directory is | Result |
| :--- | :--- |
| Missing | A relative whole-directory symlink is created |
| A correct relative symlink into the store | Left as is |
| A symlink into the store written differently | Replaced with the correct relative symlink |
| A symlink pointing outside the store | Skipped; nothing is linked inside it |
| A real directory that is empty or holds only symlinks into the store | Those symlinks and the empty directory are removed, and a whole-directory symlink takes its place |
| A real directory with other content | Falls back to per-Skill links, handled as in the `link-each` table |

`none` removes the symlinks in that directory that point into the store and leaves everything else alone. It removes symlinks only, never directories.

<details>
<summary><strong>Source detection and filtering (<code>--path</code> / <code>--skill</code> / <code>--ref</code>)</strong></summary>

<br>

The source repository is checked in this order, stopping at the first match:

1. **Single Skill**: a `SKILL.md` at the repository root means the whole repository is one Skill.
2. **Multiple Skills**: every subdirectory of `skills/` that contains a `SKILL.md`; other entries are ignored.

When Skills live elsewhere (for example, a repository nested by category, or a code project that ships Skills alongside its code), use `--path <subdir>` to set where to look. If that directory has a `SKILL.md` directly, only it is taken; otherwise its immediate subdirectories that contain a `SKILL.md` are taken. `--path` only accepts a relative path inside the repository.

`--skill <name>` can be repeated to fetch only the named Skills. If any name is not found, the whole run aborts; nothing is partially installed. `--ref` selects a branch, tag or commit and defaults to the repository's default branch. These three options are command-line only; the wizard doesn't ask for them.

```bash
curl -fsSL "https://raw.githubusercontent.com/xianghongai/agents-env/main/setup-skills.sh" \
  | bash -s -- --scope user --repo https://github.com/someone/mixed-repo.git \
    --path skills/.curated --skill alpha-skill --skill beta-skill
```

A Skill's installed name is the `name` field in its `SKILL.md` frontmatter. Without it, the directory name is used, or the repository name for a single-Skill repository. `--skill` matches against the installed name. Invalid or duplicate names abort the run before anything is written.

</details>

<details>
<summary><strong>Incremental updates and backups</strong></summary>

<br>

- Skills with new names are added; same-named Skills are skipped by default and replaced only with `--force`.
- Replacement swaps the whole Skill; nothing is merged. The original first moves to `<store>.local.bak/<name>`, outside the store, and then the new version is copied in.
- Backups stay outside the store because agents that read the store natively, or link to it as a whole directory, would otherwise load a backup as a duplicate Skill. Legacy `<name>.local.bak` backups left inside the store by older versions are moved out during linking.

</details>

---

## Instructions

`setup-instructions.sh` writes an entry file for each agent that points to `AGENTS.md`. Entry content is rendered from `templates/`. A few agents need frontmatter or an entirely different body; the registry declares the template variant for them. Agents that read `AGENTS.md` natively need no entry file, and none is written for them.

- An entry file with identical content is skipped; one with different content is backed up as `<file>.local.bak` before being overwritten.
- The script doesn't check whether an agent is installed, so you can set up entries first and install the agent later.
- In non-interactive mode the script still asks for confirmation once before acting; `--force` skips the prompt.

User scope:

```bash
curl -fsSL "https://raw.githubusercontent.com/xianghongai/agents-env/main/setup-instructions.sh" \
  | bash -s -- --scope user
```

Project scope (`cd` into the target repository first):

```bash
curl -fsSL "https://raw.githubusercontent.com/xianghongai/agents-env/main/setup-instructions.sh" \
  | bash -s -- --scope project
```

Limit the run to some agents with a comma-separated list of registry agent IDs:

```bash
curl -fsSL "https://raw.githubusercontent.com/xianghongai/agents-env/main/setup-instructions.sh" \
  | bash -s -- --scope project --agent <agent-id>,<agent-id>
```

---

## License

MIT

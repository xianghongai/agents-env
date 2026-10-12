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

- 🛡️ **Never overwrites real directories**: a real directory with the same name in an agent's folder is skipped and reported, never replaced. All validation runs before anything is written, so a failure leaves no partial result.
- ↩️ **Reversible changes**: when `--force` replaces a Skill, the original moves to `<store>.local.bak/`, outside the shared store. An entry file with different content is first backed up as `<file>.local.bak`. The suffix matches the `*.local.*` rule found in common `.gitignore` files, so backups stay out of `git status`.
- 🔗 **Relative symlinks**: links keep working after the whole tree is moved.
- 📜 **Fully declarative**: agent paths and link modes live only in the registry, and the scripts contain no vendor-specific branches. Adding an agent means editing the registry only; see the [registry guide](config/README.md).
- ⚡ **Lightweight**: single-file shell scripts, compatible with Bash 3.2+ and Zsh, runnable straight from `curl | bash`, no Node.js or Python. They require `jq`; fetching Skills also needs `git`; piped runs need `curl` or `wget`.

## Scopes

| | User `--scope user` | Project `--scope project` |
| :--- | :--- | :--- |
| Root | `$HOME` | Repository root (current directory by default, or `--target`) |
| Shared Skills store | `~/.agents/skills/` | `<repo>/.agents/skills/` |
| Instructions entry | e.g. `~/.<agent>/<entry-file>` | e.g. `<AGENT>.md` or `.<agent>/rules/<entry-file>` |
| Link mode | Declared per agent in the registry | Declared per agent in the registry |

The store location comes from `shared.skills_root` in the registry; the scripts don't assume it.

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

| mode | Behavior |
| :--- | :--- |
| `link-dir` | Links the whole directory to the store. If the target is already a real directory with other content, falls back to `link-each` so the agent's built-in Skills stay intact |
| `link-each` | Creates one symlink per Skill in the store, alongside the agent's own Skills |
| `none` | Creates no links, and removes stale symlinks in that directory that point into the store (symlinks only, never directories) |

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
- Linking only considers directories in the store that contain a `SKILL.md`. Symlinks pointing to the wrong place are re-pointed; same-named real directories are skipped and reported.

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

## Repository layout

| Path | Description |
| :--- | :--- |
| `setup-skills.sh` | Skills fetch and link (self-contained, pipe-friendly) |
| `setup-instructions.sh` | Instructions entry files (self-contained, pipe-friendly) |
| `config/agents.json` | Agent registry: paths and link modes for each agent |
| `config/agents.schema.json` | Data schema for the registry |
| [`config/README.md`](config/README.md) | Registry and schema maintenance guide |
| `templates/` | Entry file body and per-agent variant fragments |
| [`templates/README.md`](templates/README.md) | Entry template maintenance guide |
| `test/` | Test scripts and self-contained container setup |

---

## License

MIT

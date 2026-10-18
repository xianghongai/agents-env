# agents-env

[English](README.md) | [简体中文](README.zh-CN.md)

一份 Skills、一份 Instructions，接入所有 AI Agent。

agents-env 以 `.agents/skills/` 与 `AGENTS.md` 为唯一来源，按注册表把它们接到各 Agent 的私有路径：Skills 用相对软链，Instructions 用指向来源的入口文件。支持用户级与项目级两种范围。

---

## 为什么需要它

同时使用多个 Agent 时，每一家都有自己的约定：Skills 放在 `.<agent>/skills/`，规则写进 `<AGENT>.md` 或 `.<agent>/rules/<入口文件>`。手动维护很快会出问题：

- **副本各自漂移**：同一个 Skill 复制到 N 个目录，改一处漏一处。
- **随手 `ln -s` 会误伤**：整目录软链会盖住 Agent 自带的系统 Skill；绝对路径的软链在目录移动或换机后全部失效。
- **备份混进版本库**：项目级覆盖前留下的 `.bak` 文件出现在 `git status` 里，一不小心就被提交。
- **新工具接入要重来一遍**：每多一个 Agent，就要再查一次它读哪里、再手写一遍链接。

agents-env 把「各 Agent 读哪里、用什么方式接入」写进注册表 `config/agents.json`，脚本只按声明执行：

```text
~/.agents/skills/                    ← 唯一来源
├── alpha-skill/
└── beta-skill/

~/.<agent>/skills/
├── alpha-skill -> ../../.agents/skills/alpha-skill   ← 相对软链
├── beta-skill  -> ../../.agents/skills/beta-skill
└── <系统自带 Skill>/                                 ← 实体目录，原样保留
```

## 核心特性

- **不覆盖用户的东西**：Agent 目录里的同名实体目录、指向共享库之外的同名软链，一律跳过并报告，不覆盖。所有校验都在落盘之前完成，失败时不留半成品。
- **改动可回退**：`--force` 替换 Skill 时，原件移到共享库之外的 `<共享库>.local.bak/`；入口文件内容不同时先备份为 `<文件名>.local.bak`。后缀命中常见 `.gitignore` 中的 `*.local.*` 规则，不会混进 `git status`。
- **相对软链**：整体移动目录后链接依然有效。
- **完全声明式**：Agent 的路径与接入方式只写在注册表里，脚本流程中没有任何厂商特例。新增 Agent 只改注册表，具体做法见 [注册表维护指南](config/README.md)。
- **单文件、可管道执行**：每个脚本自包含，兼容 Bash 3.2+ 与 Zsh，可 `curl | bash` 直接运行，不需要 Node.js 或 Python。依赖见 [环境要求](#环境要求)。

## 范围

| | 用户级 `--scope user` | 项目级 `--scope project` |
| :--- | :--- | :--- |
| 根目录 | `$HOME` | 仓库根（默认当前目录，可用 `--target` 指定） |
| Skills 共享库 | `~/.agents/skills/` | `<仓库>/.agents/skills/` |
| Instructions 入口 | 形如 `~/.<agent>/<入口文件>` | 形如 `<AGENT>.md` 或 `.<agent>/rules/<入口文件>` |
| 软链方式 | 由注册表为每个 Agent 声明 | 由注册表为每个 Agent 声明 |

共享库位置由注册表的 `shared.skills_root` 声明，并非脚本内置。

## 环境要求

| 依赖 | 何时需要 |
| :--- | :--- |
| Bash 3.2+ 或 Zsh | 总是 |
| `jq` | 总是，用于读取注册表 |
| `git` | `setup-skills.sh` 带 `--repo` 获取 Skill 时 |
| `curl` 或 `wget` | 不在本仓库的检出中运行时（例如 `curl \| bash`），用于下载注册表与模板 |

在本仓库的检出中运行，或用 `--source` 指向一份检出时，脚本直接使用本地文件，不联网。

---

## 快速开始

不带参数运行即进入交互向导（方向键移动、回车确认、`q` 退出）。

管理 Skills：

```bash
curl -fsSL "https://raw.githubusercontent.com/xianghongai/agents-env/main/setup-skills.sh" | bash
```

管理 Instructions：

```bash
curl -fsSL "https://raw.githubusercontent.com/xianghongai/agents-env/main/setup-instructions.sh" | bash
```

脚本执行前会先列出完整计划，确认后才动手。

---

## Skills

`setup-skills.sh` 做两件事：**获取**，把来源仓库中的 Skill 增量拉进共享库；**软链**，按注册表把共享库接到各 Agent。省略 `--repo` 时只做软链。

带上任意参数即进入非交互模式。执行前仍会请求一次确认，`--yes` 跳过确认。共享库中已有的同名 Skill 默认保留，加 `--force` 才替换（隐含 `--yes`）。

拉取到用户级共享库并软链：

```bash
curl -fsSL "https://raw.githubusercontent.com/xianghongai/agents-env/main/setup-skills.sh" \
  | bash -s -- --scope user --repo https://github.com/someone/my-skills.git
```

拉取到当前仓库的 `.agents/skills/` 并软链（先 `cd` 进目标仓库）：

```bash
curl -fsSL "https://raw.githubusercontent.com/xianghongai/agents-env/main/setup-skills.sh" \
  | bash -s -- --scope project --repo https://github.com/someone/my-skills.git
```

只按注册表重建软链，不拉取：

```bash
curl -fsSL "https://raw.githubusercontent.com/xianghongai/agents-env/main/setup-skills.sh" \
  | bash -s -- --scope user
```

### 软链方式

注册表为每个 Agent 的每个范围各自声明一个 `mode`：

| mode | 作用 |
| :--- | :--- |
| `link-dir` | 把 Agent 的整个 Skills 目录软链到共享库 |
| `link-each` | 为共享库中的每个 Skill 各建一条软链，与 Agent 自带的 Skills 共存 |
| `none` | 不建链接，并清理该目录下指向共享库的软链 |

软链阶段只处理共享库中含 `SKILL.md` 的目录。下面按 Agent 目录中已有的内容，列出各种情况的结果。表中的「跳过」都会列在计划的「需注意」中，`--force` 也不会覆盖。

`link-each` 以共享库中的每个 Skill 名称为单位：

| 同名现状 | 结果 |
| :--- | :--- |
| 没有 | 新建相对软链 |
| 指向共享库的正确相对软链 | 不动 |
| 指向共享库，但路径写法不同（如绝对路径） | 改为正确的相对软链 |
| 指向共享库之外的软链，无论是否有效 | 跳过 |
| 实体目录或文件 | 跳过 |

此外，Agent 目录中指向共享库、但已解析不到 Skill 的软链（Skill 改名或删除后留下的）会被删除。别名软链只要还能解析到 Skill 就保留。其它条目一概不动，例如 Agent 自带的 Skill 和指向别处的软链。

`link-dir` 以 Agent 的 Skills 目录整体为单位：

| 该目录现状 | 结果 |
| :--- | :--- |
| 不存在 | 新建整目录相对软链 |
| 指向共享库的正确相对软链 | 不动 |
| 指向共享库，但路径写法不同 | 改为正确的相对软链 |
| 指向共享库之外的软链 | 跳过，也不往目录里建链 |
| 实体目录，为空或只含指向共享库的软链 | 删除这些软链和空目录，换成整目录软链 |
| 实体目录，含其它内容 | 回退为逐项软链，按 `link-each` 的表处理 |

`none` 删除该目录下指向共享库的软链，其它条目不动。只删软链，不删目录。

<details>
<summary><strong>来源仓库的识别与筛选（<code>--path</code> / <code>--skill</code> / <code>--ref</code>）</strong></summary>

<br>

脚本按以下顺序识别来源仓库，命中即停：

1. **单 Skill**：仓库根下直接有 `SKILL.md`，整个仓库就是一个 Skill。
2. **多 Skill**：取 `skills/` 下含 `SKILL.md` 的子目录，其它条目忽略。

Skill 不在这两个位置时（例如按分类嵌套的仓库，或在项目代码里附带 Skill 的仓库），用 `--path <子目录>` 指定识别位置。该目录下直接有 `SKILL.md` 时只取它一个，否则取其直接子目录中含 `SKILL.md` 的。`--path` 只接受仓库内的相对路径。

`--skill <名称>` 可重复使用，只获取指定的 Skill。只要有一个名称不存在就整体中止，不做部分安装。`--ref` 指定分支、标签或提交，默认取仓库默认分支。这三个选项都只能在命令行提供，交互向导不会询问。

```bash
curl -fsSL "https://raw.githubusercontent.com/xianghongai/agents-env/main/setup-skills.sh" \
  | bash -s -- --scope user --repo https://github.com/someone/mixed-repo.git \
    --path skills/.curated --skill alpha-skill --skill beta-skill
```

落地名称取 `SKILL.md` frontmatter 中的 `name` 字段；缺省时用目录名，单 Skill 仓库用仓库名。`--skill` 按落地名称匹配。名称不合法或出现重名时，在任何落盘之前中止。

</details>

<details>
<summary><strong>增量更新与备份</strong></summary>

<br>

- 名称不同的 Skill 直接新增；名称相同的默认跳过，加 `--force` 才替换。
- 替换是整份替换，不做合并。原件先移到共享库之外的 `<共享库>.local.bak/<名称>`，新版再完整落入。
- 备份不放在共享库内，否则原生读取共享库、或整目录软链到共享库的 Agent 会把备份当成同名 Skill 加载。旧版本遗留在库内的 `<名称>.local.bak` 会在软链阶段迁出。

</details>

---

## Instructions

`setup-instructions.sh` 为各 Agent 写入指向 `AGENTS.md` 的入口文件。入口内容由 `templates/` 渲染；少数 Agent 需要 frontmatter 或整份不同的正文，由注册表声明对应的模板变体。原生读取 `AGENTS.md` 的 Agent 不需要入口文件，脚本不会为它写入。

- 内容一致的入口文件直接跳过；内容不同的先备份为 `<文件名>.local.bak` 再覆盖。
- 不检测 Agent 是否已安装，可以先把入口铺好，之后再装 Agent。
- 非交互模式下执行前仍会请求一次确认，`--force` 跳过确认。

用户级：

```bash
curl -fsSL "https://raw.githubusercontent.com/xianghongai/agents-env/main/setup-instructions.sh" \
  | bash -s -- --scope user
```

项目级（先 `cd` 进目标仓库）：

```bash
curl -fsSL "https://raw.githubusercontent.com/xianghongai/agents-env/main/setup-instructions.sh" \
  | bash -s -- --scope project
```

只处理部分 Agent，用逗号分隔注册表中的 Agent 标识：

```bash
curl -fsSL "https://raw.githubusercontent.com/xianghongai/agents-env/main/setup-instructions.sh" \
  | bash -s -- --scope project --agent <agent-id>,<agent-id>
```

---

## License

MIT

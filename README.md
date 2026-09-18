# agents-env

统一管理各 AI Agent 的 **Instructions**（常驻指令入口）与 **Skills**（按需加载的能力），支持**用户级**与**项目级**两种范围。

各 Agent 的路径与接入方式全部声明在 `config/agents.json`，脚本只按声明执行，不内置任何「谁支持什么」的判断。新增 Agent 或调整约定只改注册表，不改脚本。具体怎么改见 [注册表维护指南](config/README.md)。

| 维度          | 用户级（`--scope user`）  | 项目级（`--scope project`） |
| ------------- | ------------------------- | --------------------------- |
| 根目录        | `$HOME`                   | 仓库根（默认当前目录）      |
| Instructions  | 各 Agent 的用户级入口文件 | 各 Agent 的项目级入口文件   |
| Skills 共享库 | `~/.agents/skills/`       | `<仓库>/.agents/skills/`    |

## 快速开始

不带参数即进入交互向导，方向键移动、回车确认、`q` 取消：

```bash
# Instructions
curl -fsSL "https://raw.githubusercontent.com/xianghongai/agents-env/main/setup-instructions.sh" | bash

# Skills
curl -fsSL "https://raw.githubusercontent.com/xianghongai/agents-env/main/setup-skills.sh" | bash
```

---

## Instructions

为各 Agent 写入指向真实规则来源的入口文件。入口文件内容由 `templates/` 渲染，同一 Scope 下各 Agent 完全一致，不为任何一家开分支。

已存在且内容不同的入口文件会先备份为 `<文件名>.local.bak` 再覆盖；内容一致则跳过。

### 用户级

```bash
# 交互式：选范围后勾选要安装的 Agent
curl -fsSL "https://raw.githubusercontent.com/xianghongai/agents-env/main/setup-instructions.sh" | bash

# 非交互式
curl -fsSL "https://raw.githubusercontent.com/xianghongai/agents-env/main/setup-instructions.sh" \
  | bash -s -- --scope user --force
```

按注册表为各 Agent 声明的用户级路径写入，形如 `~/.<agent>/<入口文件>`。**不检测 Agent 是否已安装**，可以先把环境铺好，之后再装 Agent。

### 项目级

```bash
cd /path/to/repo

# 交互式
curl -fsSL "https://raw.githubusercontent.com/xianghongai/agents-env/main/setup-instructions.sh" | bash

# 非交互式
curl -fsSL "https://raw.githubusercontent.com/xianghongai/agents-env/main/setup-instructions.sh" \
  | bash -s -- --scope project --force
```

按注册表为各 Agent 声明的项目级路径写入，有的落在仓库根（形如 `<AGENT>.md`），有的落在规则目录（形如 `.<agent>/rules/<入口文件>`）。少数 Agent 的入口需要 YAML frontmatter 或整份不同的正文，由注册表声明对应模板。

---

## Skills

提供**获取**（从远程仓库拉取到共享库）与**软链**（按注册表把共享库接到各 Agent）的能力。

来源仓库的唯一约定是**根下有 `skills/` 目录**，其下每个目录为一个 Skill。

获取是增量的：名字不同的新增，名字相同的默认跳过，`--force` 才替换。替换是整份替换而非合并，原件先移为 `<名称>.local.bak`，新版再完整落入。选这个后缀是因为常见 `.gitignore` 含 `*.local.*` 规则，项目级安装时不会混进 `git status`。

软链形态由注册表中每个 Agent **各 Scope 独立声明**的 `mode` 决定：

| mode        | 动作                                                                                               |
| ----------- | -------------------------------------------------------------------------------------------------- |
| `link-dir`  | 整个目录软链到共享库；目标已是含其它内容的实体目录时自动回退为逐项，避免破坏该 Agent 自带的 Skills |
| `link-each` | 为共享库中的每一项各建一条软链，可与该 Agent 自带的 Skills 共存                                    |
| `none`      | 不动作，并清理该目录下指向共享库的冗余软链                                                         |

软链一律使用相对路径，目标整体移动后依然有效。共享库位置由注册表的 `shared.skills_root` 声明，不是脚本里的假定。

### 用户级

```bash
# 交互式：选范围后输入仓库地址，留空则跳过获取、只做软链
curl -fsSL "https://raw.githubusercontent.com/xianghongai/agents-env/main/setup-skills.sh" | bash

# 非交互式
curl -fsSL "https://raw.githubusercontent.com/xianghongai/agents-env/main/setup-skills.sh" \
  | bash -s -- --scope user --repo https://github.com/someone/my-skills.git --force
```

用户级的 Agent 目录常已有其自带的 Skills，因此注册表中多声明为 `link-each`，逐项接入、互不覆盖。

### 项目级

```bash
cd /path/to/repo

# 交互式
curl -fsSL "https://raw.githubusercontent.com/xianghongai/agents-env/main/setup-skills.sh" | bash

# 非交互式
curl -fsSL "https://raw.githubusercontent.com/xianghongai/agents-env/main/setup-skills.sh" \
  | bash -s -- --scope project --repo https://github.com/someone/my-skills.git --force
```

项目级的 Agent 目录通常由本工具独占，可用 `link-dir` 整目录接入；一旦目录里有其它内容，脚本会自动回退为逐项。

---

## 本地运行

克隆本仓库后可不联网运行，`--source` 指向检出目录：

```bash
./setup-instructions.sh --scope project --source . --target /path/to/repo --dry-run
./setup-skills.sh --scope user --source . --repo /path/to/local/skills-repo
```

脚本位于检出目录中时会自动识别，`--source` 可省略。任何改动前都可以先用 `--dry-run` 看计划。完整选项见 `--help`。

---

## 结构

| 路径                        | 职责                                      |
| --------------------------- | ----------------------------------------- |
| `setup-instructions.sh`     | Instructions 入口文件，自包含，可管道执行 |
| `setup-skills.sh`           | Skills 获取与软链，自包含，可管道执行     |
| `config/agents.json`        | Agent 注册表                              |
| `config/agents.schema.json` | 注册表的数据协议                          |
| [`config/README.md`](config/README.md)       | 注册表与协议的维护指南                    |
| `templates/`                | 入口文件正文与少数 Agent 的变体片段       |
| [`templates/README.md`](templates/README.md) | 入口模板的维护指南                        |
| `test/`                     | 测试脚本与自包含的容器配置                |

---

## License

MIT

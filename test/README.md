# 测试

被测脚本只在一次性 Docker 容器内运行，宿主不执行。仓库以只读方式挂载到容器的 `/workspace`，测试产生的文件全部写在容器的 `/tmp`，容器退出即丢弃。

## 目录结构

每个被测脚本对应一个同名目录，目录内的文件名保持一致：

| 路径 | 内容 |
| --- | --- |
| `<脚本名>/tests.sh` | 该脚本的非交互测试 |
| `<脚本名>/pty.exp` | 该脚本 `interactive` 入口的交互菜单，用 `expect` 模拟终端按键 |
| `compose.yaml` | 共用的测试环境定义，镜像与命令都在这里 |

| 目录 | 覆盖范围 |
| --- | --- |
| `setup-instructions/` | 入口文件的安装、幂等、备份、dry-run、资源来源、计划展示、共用入口的合并与冲突检查、安装为命令与自更新、入口与帮助 |
| `setup-skills/` | 来源识别、获取、软链、失效软链清理、计划展示、安装为命令与自更新、悬空软链清理（`prune` 子命令）、入口与帮助 |

新增脚本时按同样的结构建目录，并在 `compose.yaml` 中加上对应命令。

测试只验证机制，不验证注册表内容。断言里的路径一律从 `config/agents.json` 现场推导，注册表增删 Agent 不需要改动本目录。

## 一键运行

在仓库根目录执行：

```sh
# Bash 5 与 Zsh：两个脚本的语法检查、静态检查，再分别用两种 Shell 跑全量测试
docker compose -f test/compose.yaml run --rm test

# Bash 3.2（与 macOS 自带版本一致）+ BusyBox 用户空间
docker compose -f test/compose.yaml run --rm test-bash32

# 交互菜单
docker compose -f test/compose.yaml run --rm test-pty
```

首次运行会构建镜像，之后复用。修改 `compose.yaml` 中的镜像定义后，追加 `--build` 重新构建。

每个测试文件结尾输出 `通过 N，失败 M`，有失败项时以非零状态退出。

## 进入容器手动调试

### 进入容器

进入容器的交互终端，不运行测试：

```sh
docker compose -f test/compose.yaml run --rm test bash
```

进入后当前目录是 `/workspace`，即仓库本身，以只读方式挂载，脚本和测试只能写到临时目录。输入 `exit` 退出，容器随即删除。

### 单独运行测试

单独运行某个脚本的测试。测试文件本身总是用 Bash 运行，`TEST_SHELL` 决定用哪种 Shell 执行被测脚本：

```sh
TEST_SHELL=bash bash test/setup-skills/tests.sh
TEST_SHELL=zsh bash test/setup-skills/tests.sh
TEST_SHELL=zsh bash test/setup-instructions/tests.sh
```

输出较长时，只看失败项和最后一行汇总：

```sh
TEST_SHELL=bash bash test/setup-skills/tests.sh | grep -E 'FAIL|通过'
```

交互测试也可以单独运行。`pty.exp` 末尾的参数是执行被测脚本所用的 Shell。运行前要准备好 `HOME`：`setup-skills/pty.exp` 要求共享库里至少有一个 Skill，`$H` 的准备方式见「手动试用脚本」一节；`setup-instructions/pty.exp` 用空目录即可：

```sh
HOME="$H" expect test/setup-skills/pty.exp bash
HOME="$(mktemp -d)" expect test/setup-instructions/pty.exp zsh
```

### 手动试用脚本

手动试用脚本时，用 `--target` 把目标设为临时目录。脚本只在该目录内读写，相当于把它当成用户主目录：

```sh
# Mock 用户 Home 目录
H="$(mktemp -d)"

# 在共享库里 Mock 几个 Skill，每个只需一个内容随意的 SKILL.md
S="$H/.agents/skills"
for n in alpha beta old-name; do
  mkdir -p "$S/$n" && printf 'x\n' >"$S/$n/SKILL.md"
done

# 先建立软链，作为后面改名、删除的起点；--yes 跳过执行前的确认
bash setup-skills.sh --scope user --target "$H" --yes

# 改名一个、删除一个，再用 --dry-run 只看计划、不执行
mv "$S/old-name" "$S/new-name"
rm -rf "$S/beta"
zsh setup-skills.sh --scope user --target "$H" --dry-run
```

### 体验交互向导

```sh
HOME="$H" bash setup-skills.sh interactive
```

`$H` 是上一节准备的目录，其 Mock 共享库 `.agents/skills` 里已有 Skill。

`setup-instructions.sh` 的交互向导用法相同，换成该脚本名即可。它写的是各 Agent 的入口文件，不读共享库，所以 `HOME` 指向空目录也能看到完整计划。

### Bash 3.2 环境

要在 Bash 3.2 环境里调试，改用 `test-bash32` 服务进入容器：

```sh
docker compose -f test/compose.yaml run --rm test-bash32 bash
```

该镜像只有 Bash 3.2，没有 Zsh、`shellcheck` 和 `shfmt`，前面用到 `zsh` 的命令需改成 `bash`。

## 编写测试的约定

- 断言中不出现任何 Agent 标识符或其私有路径，期望值从注册表按 scope、mode、路径深度推导。
- 推导落空会让断言空转而假通过，因此测试文件开头把所需前提钉死，缺少时直接非零退出。
- 需要固定形态的场景，在测试里现造一份虚构注册表，不依赖真实清单恰好有哪些条目。
- 测试文件开头固定 `AGENTS_ENV_SETUP_LANG=zh-CN`，按报错文字区分拦截原因的断言因此不受容器 locale 影响。
- 只覆盖业务相关的高价值行为：是否写入、写到哪里、结果是否正确、退出码、副作用前的校验与拦截、取消与回滚。不为输出的文案措辞、版式、对齐和帮助文本写自动化断言：这类断言改一次措辞就要改一批用例，收益低。
- 涉及下载的路径不走真实网络：远程仓库用本地 `git` 仓库代替，`curl` 用测试内的替身脚本代替。
- 本目录的测试结论只代表容器内的 Linux 环境，不能当作 macOS/BSD 已验证。

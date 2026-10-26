#!/usr/bin/env bash

# 脚本用到 bash 特性；显式用其他 Shell 执行会绕过 shebang，提前给出明确提示。
# 此时 msg 尚未定义，语言判断与下方 UI_LANG 保持同一规则。
if [ -z "${BASH_VERSION:-}" ] && [ -z "${ZSH_VERSION:-}" ]; then
  case "${AGENTS_ENV_SETUP_LANG:-${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}}" in
    zh* | ZH*) printf '错误：请用 bash 或 zsh 运行本脚本，或 curl ... | bash。\n' >&2 ;;
    *) printf 'Error: run this script with bash or zsh, or curl ... | bash.\n' >&2 ;;
  esac
  exit 1
fi

set -Eeuo pipefail

# 界面语言在入口解析一次：专用变量优先，其次按 POSIX 顺序参考 locale，都没有时用英文。
case "${AGENTS_ENV_SETUP_LANG:-${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}}" in
  zh* | ZH*) UI_LANG="zh-CN" ;;
  *) UI_LANG="en" ;;
esac
readonly UI_LANG

# 按界面语言输出一条文案（不自动换行）：$1 为 zh-CN 的 printf 格式串，$2 为 en 的格式串，其余为参数。
# 格式串只写字面量，路径、名称等外部输入一律作为参数传入，避免其中的 % 被当作格式。
msg() {
  msg_zh_cn="$1"
  msg_en="$2"
  shift 2
  # shellcheck disable=SC2059
  if [ "$UI_LANG" = "zh-CN" ]; then printf "$msg_zh_cn" "$@"; else printf "$msg_en" "$@"; fi
}

readonly GITHUB_REPOSITORY="xianghongai/agents-env"
readonly DEFAULT_GITHUB_BRANCH="main"
# 安装为命令后的固定落点：命令在 ~/.local/bin，数据在 ~/.local/share/<应用名>。
readonly INSTALL_APP_NAME="agents-env"
# 交互菜单的空转轮次上限：每轮一次 1 秒读超时，约等于一小时无按键后放弃等待。
readonly IDLE_ROUNDS_BEFORE_CANCEL=3600
# 控制字符用变量承载：case 分支里不能直接写 $'\r' 这类展开。
CR_CHAR="$(printf '\r')"
# 必须用字面换行：$(printf '\n') 的尾随换行会被命令替换剥掉，结果是空串。
# Bash 回车读到空串，Zsh 读到 LF，两者都要当作确认。
LF_CHAR='
'
ESC_CHAR="$(printf '\033')"
# 按键提示里的按键名着色，只用于写往终端的交互菜单。遵守 NO_COLOR，TERM 未设置或为 dumb 时同样不着色：
# TERM 未设置时 Bash 会自行补成 dumb 而 Zsh 保持为空，两者都不着色才能行为一致。
# 禁用时变量为空，同一个格式串即输出纯文本。
KEY_ON=""
KEY_OFF=""
if [ -z "${NO_COLOR:-}" ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
  KEY_ON="$(printf '\033[1;36m')"
  KEY_OFF="$(printf '\033[0m')"
fi
TAB_CHAR="$(printf '\t')"

SCOPE=""
REPO=""
REPO_REF=""
# 不叫 path：Zsh 中 path 是与 PATH 绑定的特殊数组。
REPO_SUBPATH=""
# 换行分隔的待装名称，可重复的参数逐个追加。
SKILL_FILTER=""
SOURCE_DIRECTORY=""
TARGET_ROOT=""
GITHUB_BRANCH="$DEFAULT_GITHUB_BRANCH"
# 显式给了 --branch 时，资源一律从该分支下载，不使用已安装的数据。
BRANCH_GIVEN=false
DRY_RUN=false
FORCE=false
ASSUME_YES=false
WORK_DIRECTORY=""
CLONE_DIRECTORY=""
RESOURCE_DIRECTORY=""
RESOURCE_SOURCE_LABEL=""
# 资源来源类别：installed 表示已安装的数据，空表示检出或下载。
SOURCE_KIND=""
# install 或 update，空表示普通的获取与软链流程。
SELF_ACTION=""
SKILLS_ROOT=""
BACKUP_ROOT=""
# 顶层捕获调用路径：Zsh 的 FUNCTION_ARGZERO 默认开启，函数内 $0 会变成函数名。
SCRIPT_INVOCATION="$0"
INTERACTIVE=false
TTY_OPENED=false
TERMINAL_STATE_SAVED=""
PENDING_SIGNAL=""
MENU_LABELS=""
MENU_TOTAL=0
MENU_CURSOR=0
MENU_RENDERED_LINES=0
MENU_KEY=""
REPLY_VALUE=""
PLAN=""
# 不产生副作用的计划动作：展示时归入「已就绪」或「需注意」，且不触发执行确认。
readonly PASSIVE_ACTIONS="skip-link skip-link-dir standard fetch-skip fallback blocked-link blocked-bak"
# 任一阶段实际执行过动作才输出「完成」；条数清单里已经展示，不再重复统计。
APPLIED=false

print_usage() {
  if [ "$UI_LANG" != "zh-CN" ]; then
    cat <<'EOF'
Usage: setup-skills.sh [options]

Fetch Skills and link them into each agent as declared in the registry.
Without --repo, only links.

Options:
      --scope <user|project>      Scope
  -r, --repo <repository_url>     Source repository; any URL git can clone
      --ref <branch|tag|commit>   Ref to fetch, default the repository's default branch
      --path <subdir>             Look for Skills only in this subdirectory of the source; requires --repo
      --skill <name>              Fetch only the named Skill; repeatable; requires --repo
  -t, --target <dir>              Scope root. Defaults to $HOME for user, the current directory for project
  -s, --source <dir>              Local checkout of this repository for the registry; downloaded if omitted
      --branch <name>             Branch of this repository to download the registry from, default main
      --dry-run                   Show the plan only; make no persistent changes
  -y, --yes                       Skip the confirmation prompt; required without a terminal (for example, in CI)
  -f, --force                     Replace same-named Skills (originals backed up outside the store); implies --yes
      --install                   Install both commands into ~/.local/bin, with their data
      --update                    Update the installed commands and their data to the latest version
  -h, --help                      Show this help and exit

Behavior:
  With no arguments, starts the interactive wizard. Any argument switches to
  strict non-interactive mode.

  Fetch: finds the Skills in the source repository and copies them into the
        shared store incrementally.
        A SKILL.md at the repository root makes the whole repository one Skill;
        otherwise every subdirectory of skills/ that contains a SKILL.md is taken.
        The installed name is the name field in the SKILL.md frontmatter, or the
        directory name if it is missing.
        New names are added; same names are skipped by default. With --force they
        are replaced, and the original moves to <store>.local.bak/<name>, outside
        the store so agents don't load it.
        If the --path directory has a SKILL.md, only it is taken; otherwise its
        immediate subdirectories that contain a SKILL.md. Use it for repositories
        nested by category or not dedicated to Skills.
        --skill filters by installed name; an unknown name fails before anything is written.

  Link: only directories in the store that contain a SKILL.md are linked, using
        the mode each agent declares per scope in the registry.
        link-dir  Links the whole directory to the store. If the target is a real
                  directory with other content, falls back to link-each so the
                  agent's own Skills stay intact.
        link-each Creates one symlink per item in the store. Broken symlinks into
                  the store, left by renamed or deleted Skills, are removed.
        none      Creates nothing, and removes stale symlinks into the store in that directory.

  Install and update: --install puts both commands into ~/.local/bin and their data into
        ~/.local/share/agents-env. --update refreshes what is already installed and never
        adds a missing command. Changed files are replaced, and originals are kept as .local.bak.
        Only --branch and --dry-run may accompany them; neither asks for confirmation.

Examples:
  setup-skills.sh --scope user --repo https://github.com/someone/my-skills.git
  setup-skills.sh --scope project --ref v1.2.0 --repo git@github.com:someone/my-skills.git
  setup-skills.sh --scope user --repo https://github.com/someone/mixed-repo.git \
    --path skills/.curated --skill alpha-skill --skill beta-skill
  setup-skills.sh --scope user --force
  setup-skills.sh --install
  setup-skills.sh --update --dry-run
EOF
    return 0
  fi
  cat <<'EOF'
用法：setup-skills.sh [选项]

获取 Skills 并按注册表声明为各 Agent 建立软链。
省略 --repo 时不获取，只做软链。

选项：
      --scope <user|project>      安装范围
  -r, --repo <repository_url>     来源仓库，任何 git 可克隆的地址
      --ref <branch|tag|commit>   取源的引用，默认仓库默认分支
      --path <subdir>             只在来源仓库的该子目录识别 Skill；需配合 --repo
      --skill <name>              只获取指定名称的 Skill，可重复；需配合 --repo
  -t, --target <dir>              Scope 根目录，默认 user 为 $HOME、project 为当前目录
  -s, --source <dir>              本仓库的本地检出，用于读取注册表；省略时按需下载
      --branch <name>             省略 --source 时下载注册表所用的本仓库分支，默认 main
      --dry-run                   只展示计划，不产生任何持久化副作用
  -y, --yes                       跳过执行前的确认；无终端的环境（如 CI）必须提供
  -f, --force                     替换同名 Skill（原件备份到共享库之外），隐含 --yes
      --install                   把两个命令装到 ~/.local/bin，并附带数据，见下方「行为」
      --update                    把已安装的命令与数据更新到最新版
  -h, --help                      显示本帮助并退出

行为：
  不带任何参数时进入交互向导；出现任意参数即进入严格非交互模式。

  获取：识别来源仓库中的 Skill，增量搬运到共享库。
        仓库根下有 SKILL.md 时，整个仓库视为一个 Skill；
        否则取 skills/ 下含 SKILL.md 的子目录。
        落地名称取 SKILL.md frontmatter 的 name 字段，缺省时用目录名。
        名字不同的新增，名字相同的默认跳过；--force 时替换，
        原件备份到 <共享库>.local.bak/<名称>，不放在共享库内以免被 Agent 读到。
        --path 指定的目录下直接有 SKILL.md 时只取它一个，否则取其直接子目录中
        含 SKILL.md 的；用于分类嵌套或非 Skills 专用的仓库。
        --skill 按落地名称筛选，名称不存在时在落盘前报错。

  软链：只处理共享库中含 SKILL.md 的目录，按注册表中每个 Agent 各 Scope 声明的 mode 处理。
        link-dir  整个目录软链到共享库；目标已是含其它内容的实体目录时
                  自动回退为 link-each，避免破坏该 Agent 自带的 Skills。
        link-each 为共享库中的每一项各建一条软链；共享库中已改名或删除的 Skill，
                  其指向共享库的失效软链一并清理。
        none      不动作，并清理该目录下指向共享库的冗余软链。

  安装与更新：--install 把两个命令装到 ~/.local/bin，数据装到 ~/.local/share/agents-env。
        --update 只更新已安装的部分，不会新增缺失的命令。
        有变化的文件直接替换，原件保留为 .local.bak。
        只能与 --branch、--dry-run 同用，两者都不需要确认。

示例：
  setup-skills.sh --scope user --repo https://github.com/someone/my-skills.git
  setup-skills.sh --scope project --ref v1.2.0 --repo git@github.com:someone/my-skills.git
  setup-skills.sh --scope user --repo https://github.com/someone/mixed-repo.git \
    --path skills/.curated --skill alpha-skill --skill beta-skill
  setup-skills.sh --scope user --force
  setup-skills.sh --install
  setup-skills.sh --update --dry-run
EOF
}

fail() {
  restore_terminal_state
  msg '错误：%s\n' 'Error: %s\n' "$1" >&2
  exit 1
}

info() {
  printf '%s\n' "$1"
}

cleanup() {
  exit_code=$?
  trap - EXIT INT TERM
  PENDING_SIGNAL=""
  restore_terminal_state
  if [ -n "$WORK_DIRECTORY" ] && [ -d "$WORK_DIRECTORY" ]; then
    rm -rf "$WORK_DIRECTORY"
  fi
  if [ "$TTY_OPENED" = true ]; then
    exec 3>&-
  fi
  exit "$exit_code"
}
trap cleanup EXIT

require_value() {
  # $1 参数名，$2 取到的值
  if [ -z "${2:-}" ]; then
    fail "$(msg '%s 需要一个值。使用 --help 查看用法。' '%s requires a value. See --help for usage.' "$1")"
  fi
}

reject_duplicate() {
  # $1 参数名，$2 当前值
  if [ -n "${2:-}" ]; then
    fail "$(msg '%s 重复指定。' '%s was given more than once.' "$1")"
  fi
}

parse_arguments() {
  if [ "$#" -eq 0 ]; then
    INTERACTIVE=true
    return 0
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --scope)
        reject_duplicate "--scope" "$SCOPE"
        require_value "--scope" "${2:-}"
        SCOPE="$2"
        shift 2
        ;;
      -s | --source)
        reject_duplicate "--source" "$SOURCE_DIRECTORY"
        require_value "--source" "${2:-}"
        SOURCE_DIRECTORY="$2"
        shift 2
        ;;
      -t | --target)
        reject_duplicate "--target" "$TARGET_ROOT"
        require_value "--target" "${2:-}"
        TARGET_ROOT="$2"
        shift 2
        ;;
      -r | --repo)
        reject_duplicate "--repo" "$REPO"
        require_value "--repo" "${2:-}"
        REPO="$2"
        shift 2
        ;;
      --path)
        reject_duplicate "--path" "$REPO_SUBPATH"
        require_value "--path" "${2:-}"
        REPO_SUBPATH="$2"
        shift 2
        ;;
      --skill)
        require_value "--skill" "${2:-}"
        SKILL_FILTER="${SKILL_FILTER}$2
"
        shift 2
        ;;
      --ref)
        reject_duplicate "--ref" "$REPO_REF"
        require_value "--ref" "${2:-}"
        REPO_REF="$2"
        shift 2
        ;;
      --branch)
        require_value "--branch" "${2:-}"
        GITHUB_BRANCH="$2"
        BRANCH_GIVEN=true
        shift 2
        ;;
      --install | --update)
        [ -z "$SELF_ACTION" ] || fail "$(msg '--install 与 --update 只能指定一个。' 'Use only one of --install and --update.')"
        SELF_ACTION="${1#--}"
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      -y | --yes)
        ASSUME_YES=true
        shift
        ;;
      -f | --force)
        FORCE=true
        ASSUME_YES=true
        shift
        ;;
      -h | --help)
        print_usage
        exit 0
        ;;
      *)
        fail "$(msg '无法识别的参数：%s。使用 --help 查看用法。' 'Unknown option: %s. See --help for usage.' "$1")"
        ;;
    esac
  done
}

validate_runtime_dependencies() {
  if ! command -v jq >/dev/null 2>&1; then
    fail "$(msg '未找到 %s。本脚本用它解析 Agent 注册表，请先安装。' '%s not found. This script uses it to parse the agent registry; install it first.' jq)"
  fi
}

open_interactive_terminal() {
  # 管道执行时标准输入是脚本本身，交互必须改读控制终端。
  # 用独立 fd 而非每次重开 /dev/tty：原始模式的终端属性要在同一个描述符上保存与还原。
  if [ "$TTY_OPENED" = true ]; then
    return 0
  fi
  if ! { exec 3<>/dev/tty; } 2>/dev/null; then
    # 非交互模式走到这里只可能是执行确认，引导用户跳过确认而不是改用非交互调用。
    if [ "$INTERACTIVE" = true ]; then
      msg '当前环境没有可用的控制终端，无法进入交互模式。\n' \
        'No controlling terminal is available, so the interactive wizard cannot start.\n' >&2
      msg '请改用非交互调用，例如：\n' 'Run it non-interactively instead, for example:\n' >&2
      printf '  setup-skills.sh --scope user\n' >&2
    else
      msg '当前环境没有可用的控制终端，无法确认执行计划。请追加 %s 跳过确认（%s 还会替换同名 Skill）。\n' \
        'No controlling terminal is available to confirm the plan. Add %s to skip the confirmation (%s also replaces same-named Skills).\n' \
        --yes --force >&2
    fi
    exit 1
  fi
  TTY_OPENED=true
}

# 交互菜单会改动终端属性；正常退出、失败和中断都必须还原，否则终端会停在无回显状态。
enter_raw_mode() {
  TERMINAL_STATE_SAVED="$(stty -g <&3)" ||
    fail "$(msg '无法读取终端属性，请改用 %s 非交互执行。' 'Cannot read the terminal settings. Run non-interactively with %s instead.' --scope)"
  stty -icanon -echo min 1 time 0 <&3 ||
    fail "$(msg '无法进入终端原始模式，请改用 %s 非交互执行。' 'Cannot switch the terminal to raw mode. Run non-interactively with %s instead.' --scope)"
  PENDING_SIGNAL=""
  trap 'note_pending_signal INT' INT
  trap 'note_pending_signal TERM' TERM
}

# read 在读取前后会自行存取终端属性，在信号处理函数里直接还原会被它覆盖。
# 交互期间只记录信号，等 read 返回、控制权回到脚本后再还原并退出。
note_pending_signal() {
  PENDING_SIGNAL="$1"
}

handle_pending_signal() {
  received="$PENDING_SIGNAL"
  [ -n "$received" ] || return 0
  PENDING_SIGNAL=""
  leave_raw_mode
  msg '\n已取消。\n' '\nCancelled.\n' >&3
  case "$received" in
    INT) exit 130 ;;
    *) exit 143 ;;
  esac
}

leave_raw_mode() {
  trap 'exit 130' INT
  trap 'exit 143' TERM
  restore_terminal_state
}

restore_terminal_state() {
  [ -n "$TERMINAL_STATE_SAVED" ] || return 0
  [ "$TTY_OPENED" = true ] || return 0
  stty "$TERMINAL_STATE_SAVED" <&3 2>/dev/null || true
  TERMINAL_STATE_SAVED=""
}

# 单字符读取在两种 Shell 下写法不同：Bash 用 -n 计数，Zsh 用 -k。
# 回车的返回值也不同：Bash 得到空串，Zsh 得到 \r，两者都要当作确认。
read_menu_key() {
  first=""
  second=""
  third=""
  idle_rounds=0

  MENU_KEY="other"
  while true; do
    if [ -n "${ZSH_VERSION:-}" ]; then
      IFS= read -r -s -k 1 -t 1 first <&3 && break
    else
      IFS= read -r -s -n 1 -t 1 first <&3 && break
    fi
    handle_pending_signal
    # Bash 3.2 的超时与 EOF 同为退出码 1，无法区分；用连续空转轮次兜底：
    # 正常静置只是继续等待，终端异常导致的立即失败会很快耗尽轮次。
    idle_rounds=$((idle_rounds + 1))
    if [ "$idle_rounds" -ge "$IDLE_ROUNDS_BEFORE_CANCEL" ]; then
      MENU_KEY="quit"
      return 0
    fi
  done

  case "$first" in
    "" | "$CR_CHAR" | "$LF_CHAR")
      MENU_KEY="enter"
      return 0
      ;;
    " ")
      MENU_KEY="space"
      return 0
      ;;
    a | A)
      MENU_KEY="all"
      return 0
      ;;
    n | N)
      MENU_KEY="none"
      return 0
      ;;
    j | J)
      MENU_KEY="down"
      return 0
      ;;
    k | K)
      MENU_KEY="up"
      return 0
      ;;
    q | Q)
      MENU_KEY="quit"
      return 0
      ;;
    "$ESC_CHAR") ;;
    *)
      return 0
      ;;
  esac

  # 裸 ESC 不是绑定键：只在读到 CSI（[）或 SS3（O）引导符时才继续读第三个字节。
  # SS3 出现在 tmux/screen 的光标应用模式下，方向键为 \eOA / \eOB。
  if [ -n "${ZSH_VERSION:-}" ]; then
    IFS= read -r -s -k 1 -t 1 second <&3 || second=""
  else
    IFS= read -r -s -n 1 -t 1 second <&3 || second=""
  fi
  case "$second" in
    "[" | O) ;;
    *) return 0 ;;
  esac

  if [ -n "${ZSH_VERSION:-}" ]; then
    IFS= read -r -s -k 1 -t 1 third <&3 || third=""
  else
    IFS= read -r -s -n 1 -t 1 third <&3 || third=""
  fi
  case "$third" in
    A) MENU_KEY="up" ;;
    B) MENU_KEY="down" ;;
  esac
}

# 只绘制选项行并记录行数，供上层用转义序列回退重绘。
# 重绘区内不放长度不可控、可能被终端折行的内容，标题留在重绘区之外。
render_menu() {
  index=0
  MENU_RENDERED_LINES=0
  while IFS= read -r label; do
    [ -n "$label" ] || continue
    if [ "$index" -eq "$MENU_CURSOR" ]; then
      printf '  \033[1m>\033[0m %s\n' "$label" >&3
    else
      printf '    %s\n' "$label" >&3
    fi
    MENU_RENDERED_LINES=$((MENU_RENDERED_LINES + 1))
    index=$((index + 1))
  done <<MENU_ITEMS
$MENU_LABELS
MENU_ITEMS
}

# $1 标题，$2 换行分隔的选项标签；选中项序号写入 MENU_CURSOR
run_single_choice_menu() {
  MENU_LABELS="$2"
  MENU_TOTAL="$(printf '%s\n' "$MENU_LABELS" | grep -c .)"
  MENU_CURSOR=0
  MENU_RENDERED_LINES=0

  enter_raw_mode
  printf '\n%s\n' "$1" >&3
  # 着色序列不含 %，拼进格式串是安全的。
  msg "  ${KEY_ON}↑↓${KEY_OFF} 或 ${KEY_ON}j/k${KEY_OFF} 移动，${KEY_ON}回车${KEY_OFF}或${KEY_ON}空格${KEY_OFF}确认，${KEY_ON}q${KEY_OFF} 取消\n\n" \
    "  ${KEY_ON}↑↓${KEY_OFF} or ${KEY_ON}j/k${KEY_OFF} to move, ${KEY_ON}Enter${KEY_OFF} or ${KEY_ON}Space${KEY_OFF} to confirm, ${KEY_ON}q${KEY_OFF} to cancel\n\n" >&3
  while true; do
    if [ "$MENU_RENDERED_LINES" -gt 0 ]; then
      printf '\033[%dA\033[J' "$MENU_RENDERED_LINES" >&3
    fi
    render_menu
    read_menu_key
    handle_pending_signal

    case "$MENU_KEY" in
      up)
        [ "$MENU_CURSOR" -gt 0 ] && MENU_CURSOR=$((MENU_CURSOR - 1))
        ;;
      down)
        [ "$MENU_CURSOR" -lt $((MENU_TOTAL - 1)) ] && MENU_CURSOR=$((MENU_CURSOR + 1))
        ;;
      enter)
        leave_raw_mode
        printf '\n' >&3
        return 0
        ;;
      quit)
        leave_raw_mode
        msg '\n已取消。\n' '\nCancelled.\n' >&3
        exit 0
        ;;
    esac
  done
}

confirm_default_yes() {
  # $1 提示语
  if [ "$ASSUME_YES" = true ]; then
    return 0
  fi
  open_interactive_terminal
  REPLY_VALUE=""
  printf '%s [Y/n] ' "$1" >&3
  if ! IFS= read -r REPLY_VALUE <&3; then
    msg '\n已取消。\n' '\nCancelled.\n' >&3
    exit 1
  fi
  case "$REPLY_VALUE" in
    "" | y | Y | yes | YES) return 0 ;;
    *) return 1 ;;
  esac
}

# 范围选择必须在解析资源之前：资源路径依赖 Scope；
# Agent 选择必须在其之后：选项来自注册表。两者因此分成两个阶段。
collect_interactive_scope() {
  open_interactive_terminal
  msg '获取 Skills 并按注册表声明为各 Agent 建立软链。\n' \
    'Fetch Skills and link them into each agent as declared in the registry.\n' >&3
  run_single_choice_menu "$(msg '选择安装范围' 'Choose the scope')" "$(msg 'user    当前用户（写入用户目录）
project 当前项目（写入项目根目录）' 'user    Current user (writes to your home directory)
project Current project (writes to the project root)')"
  case "$MENU_CURSOR" in
    0) SCOPE="user" ;;
    *) SCOPE="project" ;;
  esac
  msg '已选择：%s\n' 'Selected: %s\n' "$SCOPE" >&3

  msg '\n来源仓库地址（留空则跳过获取，只做软链）：' \
    '\nSource repository URL (leave empty to skip fetching and only link): ' >&3
  if ! IFS= read -r REPLY_VALUE <&3; then
    msg '\n已取消。\n' '\nCancelled.\n' >&3
    exit 1
  fi
  REPO="$REPLY_VALUE"
  if [ -n "$REPO" ]; then
    msg '分支或标签（留空用默认分支）：' 'Branch or tag (leave empty for the default branch): ' >&3
    IFS= read -r REPLY_VALUE <&3 || REPLY_VALUE=""
    REPO_REF="$REPLY_VALUE"
  fi
}

validate_scope() {
  case "$SCOPE" in
    user | project) ;;
    "") fail "$(msg '缺少 %s。使用 --help 查看用法。' 'Missing %s. See --help for usage.' --scope)" ;;
    *) fail "$(msg '%s 只能是 user 或 project，收到：%s' '%s must be user or project, got: %s' --scope "$SCOPE")" ;;
  esac
}

# 只校验字面形态，目录是否存在要等克隆之后才知道。放在任何副作用之前。
validate_repo_options() {
  if [ -z "$REPO" ]; then
    [ -z "$REPO_SUBPATH" ] || fail "$(msg '%s 需要配合 %s 使用。' '%s requires %s.' --path --repo)"
    [ -z "$SKILL_FILTER" ] || fail "$(msg '%s 需要配合 %s 使用。' '%s requires %s.' --skill --repo)"
    return 0
  fi
  [ -n "$REPO_SUBPATH" ] || return 0
  # 前后各补一个斜杠，任意位置的 . 与 .. 段都能用同一组模式命中。
  case "/${REPO_SUBPATH}/" in
    //*) fail "$(msg '%s 必须是仓库内的相对路径，收到：%s' '%s must be a relative path inside the repository, got: %s' --path "$REPO_SUBPATH")" ;;
    */../* | */./*) fail "$(msg '%s 不能包含 . 或 .. 段，收到：%s' '%s must not contain . or .. segments, got: %s' --path "$REPO_SUBPATH")" ;;
    *"$TAB_CHAR"*) fail "$(msg '%s 不能包含制表符。' '%s must not contain tab characters.' --path)" ;;
  esac
  while true; do
    case "$REPO_SUBPATH" in
      */) REPO_SUBPATH="${REPO_SUBPATH%/}" ;;
      *) break ;;
    esac
  done
}

resolve_target_root() {
  if [ -z "$TARGET_ROOT" ]; then
    if [ "$SCOPE" = "user" ]; then
      TARGET_ROOT="$HOME"
    else
      TARGET_ROOT="$PWD"
    fi
  fi
  [ -d "$TARGET_ROOT" ] || fail "$(msg '目标目录不存在：%s' 'Target directory does not exist: %s' "$TARGET_ROOT")"
  TARGET_ROOT="$(cd "$TARGET_ROOT" && pwd)"
}

download_resource() {
  # $1 仓库内相对路径，$2 落地绝对路径
  url="https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/${GITHUB_BRANCH}/$1"
  mkdir -p "$(dirname "$2")"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$2" || fail "$(msg '下载失败：%s' 'Download failed: %s' "$url")"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$url" || fail "$(msg '下载失败：%s' 'Download failed: %s' "$url")"
  else
    fail "$(msg '未找到 curl 或 wget，无法获取资源。可改用 %s 指定本地检出。' \
      'Neither curl nor wget found, so resources cannot be downloaded. Use %s to point to a local checkout.' --source)"
  fi
}

# 脚本自身若位于一份检出中，默认用本地资源，避免在检出目录里运行还要联网。
# 不用 BASH_SOURCE：Zsh 无该变量，且 Bash 3.2 下行为需额外判断。
default_source_directory() {
  case "$SCRIPT_INVOCATION" in
    */*)
      script_dir="$(cd "$(dirname "$SCRIPT_INVOCATION")" 2>/dev/null && pwd)" || return 0
      ;;
    *)
      # 管道执行（curl | bash）时 $0 不是路径，退回当前目录探测。
      script_dir="$PWD"
      ;;
  esac
  if [ -f "${script_dir}/config/agents.json" ]; then
    printf '%s' "$script_dir"
  fi
}

resolve_resources() {
  if [ -z "$SOURCE_DIRECTORY" ]; then
    SOURCE_DIRECTORY="$(default_source_directory)"
  fi
  # 检出目录优先；都没有时，若从已安装的命令运行，就用已安装的数据，省去下载。
  if [ -z "$SOURCE_DIRECTORY" ] && [ "$BRANCH_GIVEN" = false ]; then
    SOURCE_DIRECTORY="$(installed_data_directory)"
    if [ -n "$SOURCE_DIRECTORY" ]; then
      SOURCE_KIND=installed
    fi
  fi
  if [ -n "$SOURCE_DIRECTORY" ]; then
    [ -d "$SOURCE_DIRECTORY" ] ||
      fail "$(msg '%s 目录不存在：%s' '%s directory does not exist: %s' --source "$SOURCE_DIRECTORY")"
    RESOURCE_DIRECTORY="$(cd "$SOURCE_DIRECTORY" && pwd)"
    if [ "$SOURCE_KIND" = installed ]; then
      RESOURCE_SOURCE_LABEL="$(msg '已安装数据 %s' 'installed data %s' "$RESOURCE_DIRECTORY")"
    else
      RESOURCE_SOURCE_LABEL="$(msg '本地检出 %s' 'local checkout %s' "$RESOURCE_DIRECTORY")"
    fi
    [ -f "${RESOURCE_DIRECTORY}/config/agents.json" ] ||
      fail "$(msg '%s 目录下缺少 %s：%s' '%s directory has no %s: %s' --source config/agents.json "$RESOURCE_DIRECTORY")"
    return 0
  fi

  WORK_DIRECTORY="$(mktemp -d "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/setup-skills.XXXXXX")" ||
    fail "$(msg '无法创建临时目录。' 'Cannot create a temporary directory.')"
  RESOURCE_DIRECTORY="$WORK_DIRECTORY"
  RESOURCE_SOURCE_LABEL="GitHub ${GITHUB_REPOSITORY}@${GITHUB_BRANCH}"
  download_resource "config/agents.json" "${RESOURCE_DIRECTORY}/config/agents.json"
}

registry_file() {
  printf '%s' "${RESOURCE_DIRECTORY}/config/agents.json"
}

validate_registry() {
  jq -e . "$(registry_file)" >/dev/null 2>&1 ||
    fail "$(msg '注册表不是合法 JSON：%s' 'The registry is not valid JSON: %s' "$(registry_file)")"
  invalid_mode="$(jq -r --arg scope "$SCOPE" '
    [.agents | to_entries[] | select((.value.skills.scope[$scope].mode // "") | IN("link-dir","link-each","none") | not) | .key] | join(", ")
  ' "$(registry_file)")"
  if [ -n "$invalid_mode" ]; then
    fail "$(msg '注册表中以下 Agent 的 %s 非法：%s' 'Invalid %s for these agents in the registry: %s' "skills.scope.${SCOPE}.mode" "$invalid_mode")"
  fi
  SKILLS_ROOT="$(jq -r --arg scope "$SCOPE" '.shared.skills_root[$scope] // ""' "$(registry_file)")"
  [ -n "$SKILLS_ROOT" ] || fail "$(msg '注册表缺少 %s。' 'The registry is missing %s.' "shared.skills_root.${SCOPE}")"
  # 备份放在共享库的兄弟目录：放在库内会被原生读取共享库或整目录软链的 Agent 当成同名 Skill。
  BACKUP_ROOT="${SKILLS_ROOT%/}.local.bak"
}

# $1 agent id，$2 jq 表达式（相对于该 agent 对象，$scope 可用）
agent_field() {
  jq -r --arg id "$1" --arg scope "$SCOPE" "
    .agents[\$id] | $2 // \"\" | tostring
  " "$(registry_file)"
}

# 从 $1（相对 Scope 根的目录）回到 Scope 根再进共享库，全程相对路径，
# 保证目标整体移动后软链依然有效。
relative_to_skills_root() {
  depth="$(printf '%s' "$1" | awk -F'/' '{print NF}')"
  prefix=""
  i=1
  while [ "$i" -lt "$depth" ]; do
    prefix="${prefix}../"
    i=$((i + 1))
  done
  printf '%s%s' "$prefix" "$SKILLS_ROOT"
}

clone_repository() {
  command -v git >/dev/null 2>&1 ||
    fail "$(msg '未找到 %s。获取远程 Skills 需要它，或省略 %s 只做软链。' '%s not found. Fetching remote Skills requires it; omit %s to only link.' git --repo)"
  CLONE_DIRECTORY="${WORK_DIRECTORY}/clone"
  if [ -n "$REPO_REF" ]; then
    git clone --depth 1 --branch "$REPO_REF" -- "$REPO" "$CLONE_DIRECTORY" >/dev/null 2>&1 ||
      fail "$(msg '克隆失败：%s（ref=%s）' 'Clone failed: %s (ref=%s)' "$REPO" "$REPO_REF")"
  else
    git clone --depth 1 -- "$REPO" "$CLONE_DIRECTORY" >/dev/null 2>&1 ||
      fail "$(msg '克隆失败：%s' 'Clone failed: %s' "$REPO")"
  fi
  discover_skills
}

# $1 Skill 目录，$2 读不到 name 时的回退名。
# 只读首个 frontmatter 块里的 name：规范要求 Skill 目录名与它一致，落地目录因此按它命名。
skill_name_of() {
  name_value="$(awk -v quote="'" '
    { sub(/\r$/, "") }
    NR == 1 { if ($0 !~ /^---[[:space:]]*$/) exit; next }
    /^---[[:space:]]*$/ { exit }
    /^name:/ {
      sub(/^name:[[:space:]]*/, "")
      sub(/[[:space:]]+$/, "")
      gsub("^[\"" quote "]|[\"" quote "]$", "")
      print
      exit
    }
  ' "$1/SKILL.md" 2>/dev/null)" || name_value=""
  printf '%s' "${name_value:-$2}"
}

# 起点目录识别两种形态，按顺序判定、命中即停：
#   起点下直接有 SKILL.md：单 Skill，整个起点就是一个 Skill；
#   否则起点是容器，只取其直接子目录中含 SKILL.md 的，其它条目忽略。
# 起点默认是仓库根，容器默认是 skills/；指定 --path 时起点与容器都是该目录本身，
# 这样分类嵌套（skills/<分类>/<名称>）和非 Skills 专用仓库都能精确指到。
# 结果按「名称<TAB>仓库内相对路径」写入 discovered，计划与落盘共用这一份。
discover_skills() {
  discovered="${WORK_DIRECTORY}/discovered"
  : >"$discovered"
  scan_root="$CLONE_DIRECTORY"
  # 记录的来源路径都相对于克隆根，落盘时直接拼接。
  container_relpath="skills"
  if [ -n "$REPO_SUBPATH" ]; then
    scan_root="${CLONE_DIRECTORY}/${REPO_SUBPATH}"
    container_relpath="$REPO_SUBPATH"
    [ -d "$scan_root" ] || fail "$(msg '来源仓库中不存在目录：%s' 'No such directory in the source repository: %s' "$REPO_SUBPATH")"
    # 仓库里的软链可能指向克隆之外，按物理路径确认仍在仓库内。
    clone_physical="$(cd "$CLONE_DIRECTORY" && pwd -P)"
    case "$(cd "$scan_root" && pwd -P)/" in
      "${clone_physical}/"*) ;;
      *) fail "$(msg '%s 解析后位于来源仓库之外：%s' '%s resolves outside the source repository: %s' --path "$REPO_SUBPATH")" ;;
    esac
  fi

  if [ -f "${scan_root}/SKILL.md" ]; then
    # 单 Skill 缺 name 时用起点目录名兜底；起点是仓库根时用仓库名，克隆目录名是临时的。
    if [ -n "$REPO_SUBPATH" ]; then
      fallback="$(basename "$REPO_SUBPATH")"
      source_relpath="$REPO_SUBPATH"
    else
      fallback="$(basename "${REPO%/}")"
      fallback="${fallback%.git}"
      source_relpath="."
    fi
    printf '%s%s%s\n' "$(skill_name_of "$scan_root" "$fallback")" "$TAB_CHAR" "$source_relpath" >>"$discovered"
  elif [ -d "${CLONE_DIRECTORY}/${container_relpath}" ]; then
    find "${CLONE_DIRECTORY}/${container_relpath}" -mindepth 1 -maxdepth 1 -type d >"${WORK_DIRECTORY}/candidates" 2>/dev/null || true
    while IFS= read -r item; do
      [ -n "$item" ] || continue
      [ -f "${item}/SKILL.md" ] || continue
      dir_name="$(basename "$item")"
      printf '%s%s%s/%s\n' "$(skill_name_of "$item" "$dir_name")" "$TAB_CHAR" "$container_relpath" "$dir_name" >>"$discovered"
    done <"${WORK_DIRECTORY}/candidates"
  fi

  if [ ! -s "$discovered" ]; then
    if [ -n "$REPO_SUBPATH" ]; then
      fail "$(msg '%s 下没有找到 Skill：它自身没有 SKILL.md，直接子目录中也没有含 SKILL.md 的。' \
        'No Skill found in %s: it has no SKILL.md, and none of its immediate subdirectories has one.' "$REPO_SUBPATH")"
    fi
    fail "$(msg '来源仓库中没有找到 Skill。可识别的形态：根下直接有 SKILL.md（单 Skill），或 skills/<名称>/SKILL.md（多 Skill）；其它位置用 %s 指定。' \
      'No Skill found in the source repository. Recognized layouts: SKILL.md at the root (one Skill), or skills/<name>/SKILL.md (several Skills); use %s for other locations.' --path)"
  fi

  # 名称会成为共享库里的目录名并写进计划行，校验必须在任何落盘之前完成。
  while IFS="$TAB_CHAR" read -r name source_relpath; do
    case "$name" in
      "" | .* | *[!A-Za-z0-9._-]* | *.local.bak)
        fail "$(msg 'Skill 名称不合法：「%s」（来源 %s）。名称只能含字母、数字、点、下划线和连字符，且不以点开头。' \
          'Invalid Skill name "%s" (from %s). Names may contain only letters, digits, dots, underscores and hyphens, and must not start with a dot.' \
          "$name" "$source_relpath")"
        ;;
    esac
  done <"$discovered"
  duplicated="$(cut -f1 "$discovered" | sort | uniq -d | tr '\n' ' ')"
  [ -z "$duplicated" ] || fail "$(msg '来源仓库中存在同名 Skill：%s' 'Duplicate Skill names in the source repository: %s' "$duplicated")"

  filter_skills
}

# --skill 按落地名称筛选。任何一个名称找不到都整体中止，不做部分安装。
filter_skills() {
  [ -n "$SKILL_FILTER" ] || return 0
  printf '%s' "$SKILL_FILTER" | sort -u >"${WORK_DIRECTORY}/wanted"
  missing="$(awk -F "$TAB_CHAR" 'NR == FNR { have[$1] = 1; next } !($1 in have)' \
    "$discovered" "${WORK_DIRECTORY}/wanted" | tr '\n' ' ')"
  if [ -n "$missing" ]; then
    fail "$(msg '来源中没有这些 Skill：%s。可选名称：%s' 'These Skills are not in the source: %s. Available names: %s' \
      "$missing" "$(cut -f1 "$discovered" | sort | tr '\n' ' ')")"
  fi
  awk -F "$TAB_CHAR" 'NR == FNR { keep[$1] = 1; next } $1 in keep' \
    "${WORK_DIRECTORY}/wanted" "$discovered" >"${discovered}.filtered"
  mv "${discovered}.filtered" "$discovered"
}

add_plan() {
  PLAN="${PLAN}$1|$2|$3|$4
"
}

# 获取阶段：识别出的 Skill 增量进共享库
plan_fetch() {
  [ -n "$REPO" ] || return 0
  dest_root="${TARGET_ROOT}/${SKILLS_ROOT}"
  while IFS="$TAB_CHAR" read -r name source_relpath; do
    [ -n "$name" ] || continue
    if [ ! -e "${dest_root}/${name}" ]; then
      add_plan "fetch-new" "$name" "${SKILLS_ROOT}/${name}" ""
    elif [ "$FORCE" = true ]; then
      add_plan "fetch-replace" "$name" "${SKILLS_ROOT}/${name}" \
        "$(msg '同名替换，原件备份到 %s' 'original backed up to %s' "${BACKUP_ROOT}/${name}")"
    else
      add_plan "fetch-skip" "$name" "${SKILLS_ROOT}/${name}" ""
    fi
  done <"${WORK_DIRECTORY}/discovered"
}

# 共享库当前的真实 Skill。软链阶段在获取阶段落盘之后才计算，
# 因此这里读到的就是最终内容，不需要预测另一阶段的结果。
# 只认含 SKILL.md 的目录：库里的说明文件、杂项目录不是 Skill，不该接给 Agent。
shared_skill_names() {
  dest_root="${TARGET_ROOT}/${SKILLS_ROOT}"
  [ -d "$dest_root" ] || return 0
  find "$dest_root" -mindepth 1 -maxdepth 1 2>/dev/null >"${WORK_DIRECTORY}/names.raw" || true
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    [ -f "${item}/SKILL.md" ] || continue
    basename "$item"
  done <"${WORK_DIRECTORY}/names.raw" | sort -u
}

# 旧版把备份放在共享库内（<名称>.local.bak），会被 Agent 当成同名 Skill 读到。
# 这里把它们迁到共享库之外；新位置已有同名备份时不覆盖，留给人工处理。
plan_legacy_backups() {
  dest_root="${TARGET_ROOT}/${SKILLS_ROOT}"
  [ -d "$dest_root" ] || return 0
  find "$dest_root" -mindepth 1 -maxdepth 1 -name '*.local.bak' >"${WORK_DIRECTORY}/legacy" 2>/dev/null || true
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    [ -L "$item" ] && continue
    name="$(basename "$item")"
    name="${name%.local.bak}"
    if [ -e "${TARGET_ROOT}/${BACKUP_ROOT}/${name}" ]; then
      add_plan "blocked-bak" "$name" "${SKILLS_ROOT}/${name}.local.bak" \
        "$(msg '%s 已存在，请手动处理' '%s already exists; resolve it manually' "${BACKUP_ROOT}/${name}")"
    else
      add_plan "move-bak" "$name" "${SKILLS_ROOT}/${name}.local.bak" \
        "$(msg '移到 %s' 'move to %s' "${BACKUP_ROOT}/${name}")"
    fi
  done <"${WORK_DIRECTORY}/legacy"
}

# 软链目标（readlink 的原样结果）是否落在共享库内：指向库根本身或库内某项。
# 只看路径文本、不做解析，以免依赖 realpath；因此指向别处另一份同名共享库的软链也会被当成库内。
points_into_store() {
  store="${SKILLS_ROOT%/}"
  case "$1" in
    *"$store" | *"$store/"*) return 0 ;;
  esac
  return 1
}

# 目录中是否存在「不是指向共享库的软链」的内容：有则整目录软链会破坏它们
has_foreign_content() {
  [ -d "$1" ] || return 1
  find "$1" -mindepth 1 -maxdepth 1 >"${WORK_DIRECTORY}/scan" 2>/dev/null || true
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if [ -L "$entry" ] && points_into_store "$(readlink "$entry")"; then
      continue
    fi
    return 0
  done <"${WORK_DIRECTORY}/scan"
  return 1
}

plan_link_each() {
  # $1 展示名，$2 Agent 的 skills 相对路径
  link_root="${TARGET_ROOT}/$2"
  shared_skill_names >"${WORK_DIRECTORY}/shared"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    # 旧版留在库内的备份件不参与软链。
    case "$name" in *.local.bak) continue ;; esac
    link_path="${link_root}/${name}"
    # 深度按软链自身的路径算：它位于 <dir>/<name>，比 <dir> 深一层。
    want="$(relative_to_skills_root "$2/${name}")/${name}"
    if [ -L "$link_path" ]; then
      current="$(readlink "$link_path")"
      if [ "$current" = "$want" ]; then
        add_plan "skip-link" "$1" "$2/${name}" ""
      elif points_into_store "$current"; then
        add_plan "relink" "$1" "$2/${name}" "$(msg '改指向 %s' 'point to %s' "$want")"
      else
        # 指向库外的同名软链是用户自己的安排，与同名实体一样不覆盖，--force 也不例外。
        add_plan "blocked-link" "$1" "$2/${name}" \
          "$(msg '同名软链指向共享库之外（%s），不覆盖' 'a link with this name points outside the store (%s); not replaced' "$current")"
      fi
    elif [ -e "$link_path" ]; then
      add_plan "blocked-link" "$1" "$2/${name}" \
        "$(msg '同名实体存在，不覆盖' 'a real file or directory with this name exists; not replaced')"
    else
      add_plan "link-each" "$1" "$2/${name}" "-> ${want}"
    fi
  done <"${WORK_DIRECTORY}/shared"
  plan_stale_links "$1" "$2"
}

# 共享库中的 Skill 改名或删除后，旧软链不会出现在上面的走访里，需要反向扫描。
# 只清理指向共享库、且已解析不到 Skill 的软链：别名软链只要还能用就保留，
# 指向别处的软链与实体目录一概不碰。
plan_stale_links() {
  # $1 展示名，$2 Agent 的 skills 相对路径
  link_root="${TARGET_ROOT}/$2"
  [ -d "$link_root" ] || return 0
  find "$link_root" -mindepth 1 -maxdepth 1 -type l >"${WORK_DIRECTORY}/links" 2>/dev/null || true
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    points_into_store "$(readlink "$candidate")" || continue
    name="$(basename "$candidate")"
    # 共享库里仍有同名 Skill 的已由上面的 relink 处理。
    grep -Fxq -- "$name" "${WORK_DIRECTORY}/shared" && continue
    # 旧版库内备份迁出后，指向它的软链同样失效，不等到下一次运行。
    case "$name" in
      *.local.bak) ;;
      *) [ -f "${candidate}/SKILL.md" ] && continue ;;
    esac
    add_plan "prune-stale" "$1" "$2/${name}" ""
  done <"${WORK_DIRECTORY}/links"
}

plan_link() {
  plan_legacy_backups
  selected_agent_ids >"${WORK_DIRECTORY}/ids"
  while IFS= read -r agent_id; do
    [ -n "$agent_id" ] || continue
    display_name="$(agent_field "$agent_id" ".name")"
    skills_path="$(agent_field "$agent_id" ".skills.scope[\$scope].path")"
    skills_mode="$(agent_field "$agent_id" ".skills.scope[\$scope].mode")"
    if [ "$skills_path" = "standard" ]; then
      add_plan "standard" "$display_name" "$SKILLS_ROOT" ""
      continue
    fi
    [ -n "$skills_path" ] || continue

    link_path="${TARGET_ROOT}/${skills_path}"
    case "$skills_mode" in
      link-dir)
        want="$(relative_to_skills_root "$skills_path")"
        if [ -L "$link_path" ]; then
          current="$(readlink "$link_path")"
          if [ "$current" = "$want" ]; then
            add_plan "skip-link-dir" "$display_name" "$skills_path" ""
          elif points_into_store "$current"; then
            add_plan "relink-dir" "$display_name" "$skills_path" "$(msg '改指向 %s' 'point to %s' "$want")"
          else
            # 整个目录指向库外：不替换，也不往里面逐项建链，那会写进用户自己的目录。
            add_plan "blocked-link" "$display_name" "$skills_path" \
              "$(msg '目录是指向共享库之外的软链（%s），不覆盖' 'the directory is a link outside the store (%s); not replaced' "$current")"
          fi
        elif has_foreign_content "$link_path"; then
          add_plan "fallback" "$display_name" "$skills_path" \
            "$(msg '目录内有其它内容，回退为逐项软链' 'directory has other content; linking each item instead')"
          plan_link_each "$display_name" "$skills_path"
        elif [ -d "$link_path" ]; then
          # 空目录或只含指向共享库的软链：这些都是本脚本可以重建的，接管为整目录软链。
          add_plan "link-dir" "$display_name" "$skills_path" \
            "$(msg '替换空目录或只含共享库软链的目录 -> %s' 'replace a directory that is empty or holds only store links -> %s' "$want")"
        else
          add_plan "link-dir" "$display_name" "$skills_path" "-> ${want}"
        fi
        ;;
      link-each)
        plan_link_each "$display_name" "$skills_path"
        ;;
      none)
        if [ -d "$link_path" ]; then
          find "$link_path" -maxdepth 1 -type l >"${WORK_DIRECTORY}/stale" 2>/dev/null || true
          while IFS= read -r candidate; do
            [ -n "$candidate" ] || continue
            if points_into_store "$(readlink "$candidate")"; then
              add_plan "prune-link" "$display_name" "${skills_path}/$(basename "$candidate")" \
                "$(msg '注册表声明不建链' 'registry declares no links')"
            fi
          done <"${WORK_DIRECTORY}/stale"
        fi
        ;;
    esac
  done <"${WORK_DIRECTORY}/ids"
}

selected_agent_ids() {
  jq -r --arg scope "$SCOPE" '
    [.agents | to_entries[]
      | select((.value.skills.scope[$scope].path // "") != "")
      | .key]
    | sort
    | .[]
  ' "$(registry_file)"
}

print_context() {
  msg '范围：%s    目标：%s\n' 'Scope: %s    Target: %s\n' "$SCOPE" "$TARGET_ROOT"
  msg '注册表：%s    共享库：%s\n' 'Registry: %s    Store: %s\n' "$RESOURCE_SOURCE_LABEL" "$SKILLS_ROOT"
  # 不能写成 [ -n ... ] && info ...：条件为假时函数以非零状态返回，会被 set -e 杀掉。
  if [ -n "$REPO" ]; then
    msg '来源仓库：%s%s' 'Source: %s%s' "$REPO" "${REPO_REF:+ @${REPO_REF}}"
    if [ -n "$REPO_SUBPATH" ]; then
      msg '    子目录：%s' '    Subdirectory: %s' "$REPO_SUBPATH"
    fi
    printf '\n'
  fi
}

# 计划分层展示：已就绪的只按目录汇总条数，要执行、要清理、需注意的逐条列出。
# 多个 Agent 共用同一目录时，同一动作同一路径只列一行，Agent 名合并展示。
print_plan() {
  printf '%s' "$PLAN" | awk -F'|' -v passive=" $PASSIVE_ACTIONS " -v lang="$UI_LANG" '
    # 与 Shell 侧的 msg 同理：两种语言并排写在调用处。
    function t(zh_cn, en) { return (lang == "zh-CN") ? zh_cn : en }
    function dir_of(p) { sub(/\/[^\/]*$/, "", p); return p }
    function base_of(p) { sub(/^.*\//, "", p); return p }
    function add_who(k, who) {
      if ((k SUBSEP who) in who_seen) return
      who_seen[k SUBSEP who] = 1
      # 先判断再赋值：部分 awk 在求值右侧前就为左侧建键，写成一行会多出前导逗号。
      if (k in who_list) who_list[k] = who_list[k] ", " who
      else who_list[k] = who
    }
    function widen(text) { if (length(text) > width) width = length(text) }
    # 动作编码只供内部流转，展示时换成读者能直接看懂的说法。
    # 同一节内的标签在同一语言内等宽，英文靠尾随空格补齐：awk 按字节计宽，
    # 中文标签对不齐，所以标签放在已对齐的路径之后。
    function label_of(act) {
      if (act == "link-each" || act == "link-dir") return t("新建软链", "new link")
      if (act == "relink" || act == "relink-dir") return t("修正软链", "fix link")
      if (act == "move-bak") return t("迁出备份", "move out")
      if (act == "prune-stale") return t("失效软链", "stale link")
      if (act == "prune-link") return t("冗余软链", "extra link")
      if (act == "fetch-new") return t("新增", "new    ")
      if (act == "fetch-replace") return t("替换", "replace")
      if (act == "fallback") return t("回退", "fallback")
      if (act == "blocked-link" || act == "blocked-bak") return t("跳过", "skip    ")
      return act
    }
    $1 == "" { next }
    {
      act = $1; who = $2; entry = $3; detail = $4
      if (act == "skip-link" || act == "fetch-skip") {
        rk = act SUBSEP dir_of(entry)
      } else if (act == "skip-link-dir" || act == "standard") {
        rk = act SUBSEP entry
      } else {
        rk = ""
      }
      if (rk != "") {
        if (!(rk in ready_count)) {
          ready_order[++ready_total] = rk
          ready_act[rk] = act
          ready_key[rk] = (act == "skip-link" || act == "fetch-skip") ? dir_of(entry) : entry
          ready_count[rk] = 0
          widen(ready_key[rk])
        }
        if (!((rk SUBSEP entry) in ready_entry)) {
          ready_entry[rk SUBSEP entry] = 1
          ready_count[rk]++
        }
        add_who(rk, (act == "fetch-skip") ? base_of(entry) : who)
        next
      }
      if (act == "prune-link" || act == "prune-stale") section = "prune"
      else if (index(passive, " " act " ") > 0) section = "note"
      else section = "change"
      k = act SUBSEP entry
      if (!(k in row_act)) {
        rows[section, ++row_total[section]] = k
        row_act[k] = act
        row_entry[k] = entry
        # 说明与标签重复时不展示：新建类的指向可由路径推导。
        row_detail[k] = (act == "link-each" || act == "link-dir") ? "" : detail
        widen(entry)
      }
      # 获取阶段的名称就是路径末段，不再重复。
      if (who != base_of(entry)) add_who(k, who)
    }
    function print_rows(section, title,    i, k, tail) {
      if (row_total[section] == 0) return
      printf "\n%s\n", sprintf(title, row_total[section])
      for (i = 1; i <= row_total[section]; i++) {
        k = rows[section, i]
        tail = label_of(row_act[k])
        if (k in who_list) tail = tail "  " who_list[k]
        if (row_detail[k] != "") tail = tail "  " row_detail[k]
        # 英文标签的补齐空格落在行尾时去掉。
        sub(/ +$/, "", tail)
        printf "  %-" width "s  %s\n", row_entry[k], tail
      }
    }
    END {
      if (ready_total > 0) {
        printf "\n%s\n", t("已就绪", "Ready")
        for (i = 1; i <= ready_total; i++) {
          rk = ready_order[i]
          act = ready_act[rk]
          if (act == "skip-link") summary = sprintf(t("%d 项已软链", "%d linked"), ready_count[rk])
          else if (act == "skip-link-dir") summary = t("整个目录已软链", "whole directory linked")
          else if (act == "standard") summary = t("原生读取共享库", "reads the store natively")
          else summary = sprintf(t("%d 项同名已存在，--force 才替换", "%d already exist; --force replaces them"), ready_count[rk])
          printf "  %-" width "s  %s%s%s\n", ready_key[rk], summary, t("：", ": "), who_list[rk]
        }
      }
      print_rows("change", t("即将执行（%d）", "To apply (%d)"))
      print_rows("prune", t("即将清理（%d）", "To clean up (%d)"))
      print_rows("note", t("需注意（%d）", "Needs attention (%d)"))
    }
  '
  info ""
}

# 计划里是否有会产生副作用的动作；全部已就绪时无需确认。
plan_has_changes() {
  printf '%s' "$PLAN" | awk -F'|' -v passive=" $PASSIVE_ACTIONS " '
    $1 != "" && index(passive, " " $1 " ") == 0 { found = 1 }
    END { exit !found }
  '
}

apply_plan() {
  # 多个 Agent 共用同一目录时计划行会重复，同一动作同一路径只执行一次。
  printf '%s' "$PLAN" | awk -F'|' '$1 != "" && !seen[$1 FS $3]++' >"${WORK_DIRECTORY}/plan"
  dest_root="${TARGET_ROOT}/${SKILLS_ROOT}"
  while IFS='|' read -r action name entry_relpath _; do
    [ -n "$action" ] || continue
    target="${TARGET_ROOT}/${entry_relpath}"
    case "$action" in
      fetch-new | fetch-replace)
        mkdir -p "$dest_root"
        # 落入前目标必须不存在：cp -R 到已存在的目录会拷进其内部形成合并，
        # 那样旧版残留的文件会与新版混在一起，且没有任何提示。
        if [ -e "$target" ]; then
          backup="${TARGET_ROOT}/${BACKUP_ROOT}/${name}"
          mkdir -p "${TARGET_ROOT}/${BACKUP_ROOT}"
          rm -rf "$backup"
          mv "$target" "$backup"
        fi
        source_relpath="$(awk -F "$TAB_CHAR" -v want="$name" '$1 == want { print $2; exit }' "${WORK_DIRECTORY}/discovered")"
        # 复制「目录/.」而不是目录本身：来源若是仓库内的软链，复制的是它指向的内容而非链接。
        cp -R "${CLONE_DIRECTORY}/${source_relpath}/." "$target"
        # 单 Skill 仓库整份复制时会带上克隆的版本库元数据，它不属于 Skill。
        rm -rf "${target}/.git"
        APPLIED=true
        ;;
      move-bak)
        mkdir -p "${TARGET_ROOT}/${BACKUP_ROOT}"
        mv "$target" "${TARGET_ROOT}/${BACKUP_ROOT}/${name}"
        APPLIED=true
        ;;
      link-dir | relink-dir)
        mkdir -p "$(dirname "$target")"
        if [ -L "$target" ]; then
          rm "$target"
        elif [ -d "$target" ]; then
          # 计划阶段已确认目录里只有指向共享库的软链。只删这些软链，目录用 rmdir 删除，
          # 不递归：运行期间若出现了别的内容，rmdir 失败即中止，不会误删。
          find "$target" -mindepth 1 -maxdepth 1 -type l >"${WORK_DIRECTORY}/takeover" 2>/dev/null || true
          while IFS= read -r entry; do
            [ -n "$entry" ] || continue
            if points_into_store "$(readlink "$entry")"; then
              rm "$entry"
            fi
          done <"${WORK_DIRECTORY}/takeover"
          rmdir "$target" ||
            fail "$(msg '目录不为空，未替换：%s' 'Directory is not empty; not replaced: %s' "$entry_relpath")"
        fi
        ln -s "$(relative_to_skills_root "$entry_relpath")" "$target"
        APPLIED=true
        ;;
      link-each | relink)
        # 目标由路径重新推导，不从展示文案反解：文案变了不该影响行为。
        mkdir -p "$(dirname "$target")"
        [ -L "$target" ] && rm "$target"
        ln -s "$(relative_to_skills_root "$entry_relpath")/$(basename "$entry_relpath")" "$target"
        APPLIED=true
        ;;
      prune-link | prune-stale)
        [ -L "$target" ] && rm "$target"
        APPLIED=true
        ;;
      *)
        # 已就绪与需注意的条目只供展示，没有要执行的动作。
        ;;
    esac
  done <"${WORK_DIRECTORY}/plan"
}

print_summary() {
  if [ "$APPLIED" = true ]; then
    info "$(msg '完成。' 'Done.')"
  fi
}

# 一个阶段 = 计划、展示、确认、应用。两个阶段互不依赖：
# 只做获取、只做软链、或先获取再软链，都是同一套流程的组合。
# $1 阶段名，$2 生成计划的函数名
run_phase() {
  PLAN=""
  "$2"
  if [ -z "$PLAN" ]; then
    info "$(msg '[%s] 没有需要处理的项。' '[%s] Nothing to process.' "$1")"
    return 0
  fi
  info "[$1]"
  print_plan
  if [ "$DRY_RUN" = true ]; then
    return 0
  fi
  if ! plan_has_changes; then
    info "$(msg '[%s] 无需改动。' '[%s] Nothing to change.' "$1")"
    return 0
  fi
  if ! confirm_default_yes "$(msg '是否继续？' 'Continue?')"; then
    info "$(msg '[%s] 已跳过。' '[%s] Skipped.' "$1")"
    return 0
  fi
  apply_plan
}

# 安装与自更新。两个脚本各自内置同一份实现：命令装在 ~/.local/bin，数据装在 ~/.local/share/agents-env。
# 无论执行哪个脚本，都把两个命令与全部数据一起装好或更新，保证版本一致，不会出现新脚本配旧注册表。
# 数据清单以远端注册表为准：注册表声明的模板变体也要带上，否则渲染时会缺文件。

# 只有从 ~/.local/bin 中的命令直接运行时，才读取已安装的数据。
# 管道执行拿到的脚本永远是最新版，配上旧注册表会错位，因此不走这里。
installed_data_directory() {
  [ -n "${HOME:-}" ] || return 0
  case "$SCRIPT_INVOCATION" in
    */*) ;;
    *) return 0 ;;
  esac
  invoked_dir="$(cd "$(dirname "$SCRIPT_INVOCATION")" 2>/dev/null && pwd -P)" || return 0
  local_bin="$(cd "${HOME}/.local/bin" 2>/dev/null && pwd -P)" || return 0
  candidate="${HOME}/.local/share/${INSTALL_APP_NAME}"
  if [ "$invoked_dir" = "$local_bin" ] && [ -f "${candidate}/config/agents.json" ]; then
    printf '%s' "$candidate"
  fi
  return 0
}

# --install 与 --update 只作用于固定位置。其它范围、来源或覆盖类选项与之无关，
# 在下载之前拦下，免得用户以为它们生效了。
validate_self_options() {
  [ -n "$SELF_ACTION" ] || return 0
  if [ -n "$SCOPE" ] || [ -n "$SOURCE_DIRECTORY" ] || [ -n "$TARGET_ROOT" ] || [ -n "$REPO" ] ||
    [ -n "$REPO_REF" ] || [ -n "$REPO_SUBPATH" ] || [ -n "$SKILL_FILTER" ] ||
    [ "$FORCE" = true ] || [ "$ASSUME_YES" = true ]; then
    fail "$(msg '%s 只能与 %s 和 %s 同用。' '%s can only be combined with %s and %s.' "--${SELF_ACTION}" --branch --dry-run)"
  fi
}

# 下载内容先过形态校验，挡住 404 页面、截断的脚本和错位的注册表。全部通过前不写任何文件。
# $1 仓库内相对路径，通过返回 0。
validate_install_file() {
  file="${WORK_DIRECTORY}/stage/$1"
  case "$1" in
    *.sh)
      [ "$(head -n 1 "$file")" = "#!/usr/bin/env bash" ] || return 1
      bash -n "$file" 2>/dev/null || return 1
      [ "$(tail -n 1 "$file")" = "main \"\$@\"" ] || return 1
      ;;
    config/agents.json)
      jq -e '(.agents | type == "object") and (.shared | type == "object")' "$file" >/dev/null 2>&1 || return 1
      ;;
    *)
      [ -s "$file" ] || return 1
      ;;
  esac
}

check_install_file() {
  validate_install_file "$1" ||
    fail "$(msg '%s 未通过校验，未做任何修改。' '%s failed validation; nothing was changed.' "$1")"
}

# 清单 = 两个脚本、注册表、通用模板，加上注册表声明的模板变体（整份替换与前置块）。
# 路径只允许仓库内的相对路径且不含 .. 段，注册表因此无法把写入引到数据目录之外。
build_install_manifest() {
  manifest="${WORK_DIRECTORY}/manifest"
  {
    printf '%s\n' setup-skills.sh setup-instructions.sh config/agents.json templates/entry-user.md templates/entry-project.md
    jq -r '[.agents[] | .instructions // {} | (.template_override // {}), (.template_frontmatter // {}) | .[]? | select(type == "string")] | .[]' \
      "${WORK_DIRECTORY}/stage/config/agents.json"
  } | awk '!seen[$0]++' >"$manifest"
  while IFS= read -r rel; do
    case "$rel" in
      "" | /* | *..*) fail "$(msg '注册表中的路径不合法：%s' 'Invalid path in the registry: %s' "$rel")" ;;
    esac
  done <"$manifest"
}

# $1 目标绝对路径，$2 暂存文件。结果写入 action。
classify_target() {
  if [ -L "$1" ]; then
    action=skip-link
  elif [ ! -e "$1" ]; then
    action=new
  elif cmp -s "$2" "$1"; then
    action=same
  else
    action=update
  fi
}

# 计划只读、不产生副作用。每行：动作<TAB>目标绝对路径<TAB>暂存文件。
plan_installation() {
  : >"$install_plan"
  INSTALLED_COMMANDS=0
  while IFS= read -r rel; do
    src="${WORK_DIRECTORY}/stage/${rel}"
    case "$rel" in
      *.sh)
        dest="${bin_dir}/$(basename "$rel" .sh)"
        if [ -e "$dest" ] || [ -L "$dest" ]; then
          INSTALLED_COMMANDS=$((INSTALLED_COMMANDS + 1))
        fi
        if [ "$SELF_ACTION" = update ] && [ ! -e "$dest" ] && [ ! -L "$dest" ]; then
          action=absent
        else
          classify_target "$dest" "$src"
        fi
        ;;
      *)
        dest="${data_dir}/${rel}"
        classify_target "$dest" "$src"
        ;;
    esac
    printf '%s\t%s\t%s\n' "$action" "$dest" "$src" >>"$install_plan"
  done <"$manifest"
}

install_has_changes() {
  awk -F "$TAB_CHAR" '$1 == "new" || $1 == "update" { found = 1 } END { exit !found }' "$install_plan"
}

install_label() {
  case "$1" in
    new) msg '新增' 'new' ;;
    update) msg '更新，原件备份为 %s' 'updated, original kept as %s' '.local.bak' ;;
    same) msg '已是最新' 'up to date' ;;
    skip-link) msg '跳过：位置是软链，不覆盖' 'skipped: a symlink, not replaced' ;;
    absent) msg '跳过：未安装，--update 不新增命令' 'skipped: not installed; --update does not add commands' ;;
  esac
}

# 命令逐行列出；数据文件数量多，只汇总条数。
print_installation() {
  if [ "$SELF_ACTION" = install ]; then
    info "$(msg '[安装]' '[Install]')"
  else
    info "$(msg '[更新]' '[Update]')"
  fi
  info "$(msg '来源：GitHub %s@%s' 'Source: GitHub %s@%s' "$GITHUB_REPOSITORY" "$GITHUB_BRANCH")"
  data_new=0
  data_update=0
  data_same=0
  while IFS="$TAB_CHAR" read -r action dest src; do
    case "$dest" in
      "${data_dir}"/*)
        case "$action" in
          new) data_new=$((data_new + 1)) ;;
          update) data_update=$((data_update + 1)) ;;
          *) data_same=$((data_same + 1)) ;;
        esac
        ;;
      *)
        printf '  %s  %s\n' "$dest" "$(install_label "$action")"
        ;;
    esac
  done <"$install_plan"
  printf '  %s  %s\n' "$data_dir" "$(msg '%d 个文件：新增 %d，更新 %d，已是最新 %d' '%d files: %d new, %d updated, %d up to date' \
    "$((data_new + data_update + data_same))" "$data_new" "$data_update" "$data_same")"
}

# 先把所有待写内容放到目标旁边的 .new，全部就位后才逐个替换，
# 中途失败不会留下新旧混杂的组合。替换用 mv：正在运行的脚本仍持有旧 inode，不受影响。
apply_installation() {
  mkdir -p "$bin_dir" "$data_dir"
  while IFS="$TAB_CHAR" read -r action dest src; do
    case "$action" in
      new | update)
        mkdir -p "$(dirname "$dest")"
        cp "$src" "${dest}.new"
        case "$dest" in
          "${bin_dir}"/*) chmod 755 "${dest}.new" ;;
        esac
        ;;
    esac
  done <"$install_plan"
  while IFS="$TAB_CHAR" read -r action dest src; do
    case "$action" in
      new) mv "${dest}.new" "$dest" ;;
      update)
        cp "$dest" "${dest}.local.bak"
        mv "${dest}.new" "$dest"
        ;;
    esac
  done <"$install_plan"
}

# 命令固定装在 ~/.local/bin，数据固定在 ~/.local/share/agents-env，两者都不随参数变化。
# 全部文件先下载到暂存区并校验，计划也算完，才写入：任何一步失败都不留下半成品。
manage_installation() {
  [ -n "${HOME:-}" ] ||
    fail "$(msg '未设置 %s，无法确定安装位置。' 'HOME is not set, so the install location cannot be determined.' HOME)"
  bin_dir="${HOME}/.local/bin"
  data_dir="${HOME}/.local/share/${INSTALL_APP_NAME}"
  WORK_DIRECTORY="$(mktemp -d "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/agents-env-install.XXXXXX")" ||
    fail "$(msg '无法创建临时目录。' 'Cannot create a temporary directory.')"
  mkdir -p "${WORK_DIRECTORY}/stage/config"
  # 注册表先下载：清单要从它推导，且 config/agents.json 本身也属于清单。
  download_resource "config/agents.json" "${WORK_DIRECTORY}/stage/config/agents.json"
  check_install_file "config/agents.json"
  build_install_manifest
  while IFS= read -r rel; do
    if [ ! -f "${WORK_DIRECTORY}/stage/${rel}" ]; then
      download_resource "$rel" "${WORK_DIRECTORY}/stage/${rel}"
    fi
    check_install_file "$rel"
  done <"$manifest"

  install_plan="${WORK_DIRECTORY}/plan"
  plan_installation
  if [ "$SELF_ACTION" = update ] && [ "$INSTALLED_COMMANDS" -eq 0 ]; then
    fail "$(msg '尚未安装，请先用 %s 安装。' 'Not installed yet. Install first with %s.' --install)"
  fi
  print_installation
  if [ "$DRY_RUN" = true ]; then
    info "$(msg '%s：未做任何修改。' '%s: no changes made.' --dry-run)"
    exit 0
  fi
  if ! install_has_changes; then
    info "$(msg '无需改动。' 'Nothing to change.')"
    exit 0
  fi
  apply_installation
  case ":${PATH}:" in
    *":${bin_dir}:"*) ;;
    *) msg '提示：%s 不在 PATH 中，请把它加入 shell 配置。\n' 'Note: %s is not in PATH. Add it to your shell configuration.\n' "$bin_dir" ;;
  esac
  info "$(msg '完成。' 'Done.')"
  exit 0
}

main() {
  parse_arguments "$@"
  validate_runtime_dependencies
  if [ -n "$SELF_ACTION" ]; then
    validate_self_options
    manage_installation
  fi
  if [ "$INTERACTIVE" = true ]; then
    collect_interactive_scope
  fi
  validate_scope
  validate_repo_options
  resolve_target_root
  resolve_resources
  validate_registry

  if [ -z "$WORK_DIRECTORY" ]; then
    WORK_DIRECTORY="$(mktemp -d "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/setup-skills.XXXXXX")" ||
      fail "$(msg '无法创建临时目录。' 'Cannot create a temporary directory.')"
  fi

  print_context

  if [ -n "$REPO" ]; then
    clone_repository
    run_phase "$(msg '获取' 'Fetch')" plan_fetch
  fi

  # 软链阶段读取共享库的真实内容。获取阶段若被跳过或取消，这里看到的就是
  # 未变的现状：两个阶段解耦，随时可以只跑其中一个。
  run_phase "$(msg '软链' 'Link')" plan_link

  if [ "$DRY_RUN" = true ]; then
    info "$(msg '%s：未做任何修改。' '%s: no changes made.' --dry-run)"
    exit 0
  fi
  print_summary
}

main "$@"

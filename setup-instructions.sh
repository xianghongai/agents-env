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
# 只影响终端输出；写入的入口文件内容与语言无关，否则不同 locale 的人轮流执行会互相覆盖。
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
# 共享 Skills 库的路径由注册表声明，不在脚本中假定。
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

SCOPE=""
SOURCE_DIRECTORY=""
TARGET_ROOT=""
AGENT_FILTER=""
GITHUB_BRANCH="$DEFAULT_GITHUB_BRANCH"
DRY_RUN=false
FORCE=false
WORK_DIRECTORY=""
RESOURCE_DIRECTORY=""
RESOURCE_SOURCE_LABEL=""
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
MENU_MARKS=""
REPLY_VALUE=""
PLAN=""
# 不产生副作用的计划动作：展示时归入「已就绪」或「未声明入口」，且不触发执行确认。
readonly PASSIVE_ACTIONS="skip-entry standard skip-unknown"
# 实际写入过才输出「完成」；条目清单里已经展示，不再重复统计。
APPLIED=false

print_usage() {
  if [ "$UI_LANG" != "zh-CN" ]; then
    cat <<'EOF'
Usage: setup-instructions.sh [options]

Install or update the Instructions entry files for each AI agent.
Handles entry files only; setup-skills.sh fetches and links Skills.

Options:
      --scope <user|project>  Scope. user writes to your home directory, project to the repository root
  -s, --source <dir>          Path to a local checkout of this repository; downloads from GitHub if omitted
  -t, --target <dir>          Scope root. Defaults to $HOME for user, the current directory for project
  -a, --agent <agent_id>      Comma-separated agent IDs to limit the run to
      --branch <name>         Branch to download from GitHub, default main
      --dry-run               Show the plan only; make no persistent changes
  -f, --force                 Skip the confirmation prompt; required without a terminal (for example, in CI)
  -h, --help                  Show this help and exit

Behavior:
  With no arguments, starts the interactive wizard. Any argument switches to
  strict non-interactive mode: missing required options fail instead of prompting.

  Processes every agent in the registry by default; narrow it with --agent.
  Doesn't check whether an agent is installed, and creates missing entry directories.

Examples:
  setup-instructions.sh --scope user
  setup-instructions.sh --scope project --target ./my-repo --dry-run
  setup-instructions.sh --scope user --agent <agent-id>,<agent-id> --force
EOF
    return 0
  fi
  cat <<'EOF'
用法：setup-instructions.sh [选项]

为各 AI Agent 安装或更新 Instructions 入口文件。
只处理入口文件；Skills 的获取与软链由 setup-skills.sh 负责。

选项：
      --scope <user|project>  安装范围。user 写入用户目录，project 写入仓库根
  -s, --source <dir>          本地仓库检出路径；省略时从 GitHub 下载所需文件
  -t, --target <dir>          Scope 根目录，默认 user 为 $HOME、project 为当前目录
  -a, --agent <agent_id>      逗号分隔的 Agent id，限定处理范围
      --branch <name>         从 GitHub 取源时的分支，默认 main
      --dry-run               只展示计划，不产生任何持久化副作用
  -f, --force                 跳过执行前的确认；无终端的环境（如 CI）必须提供
  -h, --help                  显示本帮助并退出

行为：
  不带任何参数时进入交互向导；出现任意参数即进入严格非交互模式，
  缺少必填项直接失败，不会补问。

  默认处理注册表中的全部 Agent，可用 --agent 收窄。
  不检测 Agent 是否已安装，入口所在目录不存在时一并创建。

示例：
  setup-instructions.sh --scope user
  setup-instructions.sh --scope project --target ./my-repo --dry-run
  setup-instructions.sh --scope user --agent <agent-id>,<agent-id> --force
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
      -a | --agent)
        reject_duplicate "--agent" "$AGENT_FILTER"
        require_value "--agent" "${2:-}"
        AGENT_FILTER="$2"
        shift 2
        ;;
      --branch)
        require_value "--branch" "${2:-}"
        GITHUB_BRANCH="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      -f | --force)
        FORCE=true
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
      printf '  setup-instructions.sh --scope user\n' >&2
    else
      msg '当前环境没有可用的控制终端，无法确认执行计划。请追加 %s 跳过确认。\n' \
        'No controlling terminal is available to confirm the plan. Add %s to skip the confirmation.\n' --force >&2
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

# 多选菜单。与单选共用按键与终端处理，另加空格勾选、a 全选、n 全清。
# 勾选状态用换行分隔的 0/1 串承载，避免数组在 Bash 3.2 与 Zsh 下的下标差异。
nth_line() {
  # $1 内容，$2 序号（从 0 起）
  printf '%s\n' "$1" | sed -n "$(($2 + 1))p"
}

set_all_marks() {
  MENU_MARKS=""
  i=0
  while [ "$i" -lt "$MENU_TOTAL" ]; do
    MENU_MARKS="${MENU_MARKS}$1
"
    i=$((i + 1))
  done
}

toggle_mark() {
  new_marks=""
  i=0
  while [ "$i" -lt "$MENU_TOTAL" ]; do
    current="$(nth_line "$MENU_MARKS" "$i")"
    if [ "$i" -eq "$MENU_CURSOR" ]; then
      if [ "$current" = "1" ]; then current=0; else current=1; fi
    fi
    new_marks="${new_marks}${current}
"
    i=$((i + 1))
  done
  MENU_MARKS="$new_marks"
}

selected_count() {
  printf '%s\n' "$MENU_MARKS" | grep -c '^1$' || true
}

render_multi_menu() {
  index=0
  MENU_RENDERED_LINES=0
  while IFS= read -r label; do
    [ -n "$label" ] || continue
    if [ "$(nth_line "$MENU_MARKS" "$index")" = "1" ]; then box="[x]"; else box="[ ]"; fi
    if [ "$index" -eq "$MENU_CURSOR" ]; then
      printf '  \033[1m> %s %s\033[0m\n' "$box" "$label" >&3
    else
      printf '    %s %s\n' "$box" "$label" >&3
    fi
    MENU_RENDERED_LINES=$((MENU_RENDERED_LINES + 1))
    index=$((index + 1))
  done <<MENU_ITEMS
$MENU_LABELS
MENU_ITEMS
  # 状态行恒占一行，保证重绘回退的行数稳定。
  picked="$(selected_count)"
  if [ "$picked" -eq 0 ]; then
    msg '  \033[2m未选择任何 Agent，按 a 全选，空格勾选当前项\033[0m\n' \
      '  \033[2mNo agent selected. Press a to select all, or Space to toggle the current one\033[0m\n' >&3
  else
    msg '  \033[2m已选择 %s 项\033[0m\n' '  \033[2m%s selected\033[0m\n' "$picked" >&3
  fi
  MENU_RENDERED_LINES=$((MENU_RENDERED_LINES + 1))
}

# $1 标题，$2 换行分隔的选项标签；结果为 MENU_MARKS 中值为 1 的行号
run_multi_choice_menu() {
  MENU_LABELS="$2"
  MENU_TOTAL="$(printf '%s\n' "$MENU_LABELS" | grep -c .)"
  MENU_CURSOR=0
  MENU_RENDERED_LINES=0
  # 默认一项不选：安装范围应由开发者明确表达，不替他决定要动哪些目录。
  # 需要全选时按 a 即可，成本极低。
  set_all_marks 0

  enter_raw_mode
  printf '\n%s\n' "$1" >&3
  msg "  ${KEY_ON}↑↓${KEY_OFF} 或 ${KEY_ON}j/k${KEY_OFF} 移动，${KEY_ON}空格${KEY_OFF}勾选，${KEY_ON}a${KEY_OFF} 全选，${KEY_ON}n${KEY_OFF} 全清，${KEY_ON}回车${KEY_OFF}确认，${KEY_ON}q${KEY_OFF} 取消\n\n" \
    "  ${KEY_ON}↑↓${KEY_OFF} or ${KEY_ON}j/k${KEY_OFF} to move, ${KEY_ON}Space${KEY_OFF} to toggle, ${KEY_ON}a${KEY_OFF} for all, ${KEY_ON}n${KEY_OFF} for none, ${KEY_ON}Enter${KEY_OFF} to confirm, ${KEY_ON}q${KEY_OFF} to cancel\n\n" >&3
  while true; do
    if [ "$MENU_RENDERED_LINES" -gt 0 ]; then
      printf '\033[%dA\033[J' "$MENU_RENDERED_LINES" >&3
    fi
    render_multi_menu
    read_menu_key
    handle_pending_signal

    case "$MENU_KEY" in
      up) [ "$MENU_CURSOR" -gt 0 ] && MENU_CURSOR=$((MENU_CURSOR - 1)) ;;
      down) [ "$MENU_CURSOR" -lt $((MENU_TOTAL - 1)) ] && MENU_CURSOR=$((MENU_CURSOR + 1)) ;;
      space) toggle_mark ;;
      all) set_all_marks 1 ;;
      none) set_all_marks 0 ;;
      enter)
        if [ "$(selected_count)" -eq 0 ]; then
          continue
        fi
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
  if [ "$FORCE" = true ]; then
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
  msg '为各 AI Agent 安装或更新 Instructions 入口文件。\n' \
    'Install or update the Instructions entry files for each AI agent.\n' >&3
  run_single_choice_menu "$(msg '选择安装范围' 'Choose the scope')" "$(msg 'user    当前用户（写入用户目录）
project 当前项目（写入仓库根目录）' 'user    Current user (writes to your home directory)
project Current project (writes to the repository root)')"
  case "$MENU_CURSOR" in
    0) SCOPE="user" ;;
    *) SCOPE="project" ;;
  esac
  msg '已选择：%s\n' 'Selected: %s\n' "$SCOPE" >&3
}

# 注册表中该 Scope 下需要写入口文件的 Agent，供多选菜单使用。
# 一次查出 id 与标签，再拆列，保证两者同序。
installable_agents() {
  jq -r --arg scope "$SCOPE" '
    .agents
    | to_entries
    | map(select((.value.instructions.scope[$scope] // "") | . != "" and . != "standard"))
    | sort_by(.key)
    | .[] | "\(.key)\t\(.value.name)  -  \(.value.instructions.scope[$scope])"
  ' "$(registry_file)"
}

collect_interactive_agents() {
  # 交互阶段早于临时目录创建，因此用变量中转而非临时文件。
  agents_tsv="$(installable_agents)"
  agent_ids="$(printf '%s\n' "$agents_tsv" | cut -f1)"
  agent_labels="$(printf '%s\n' "$agents_tsv" | cut -f2)"
  [ -n "$agent_ids" ] || fail "$(msg '注册表中没有可用于 %s 范围的 Agent。' 'The registry has no agent for the %s scope.' "$SCOPE")"

  run_multi_choice_menu "$(msg '选择要安装的 Agent' 'Choose the agents to install')" "$agent_labels"

  AGENT_FILTER=""
  i=0
  while [ "$i" -lt "$MENU_TOTAL" ]; do
    if [ "$(nth_line "$MENU_MARKS" "$i")" = "1" ]; then
      picked="$(nth_line "$agent_ids" "$i")"
      if [ -z "$AGENT_FILTER" ]; then
        AGENT_FILTER="$picked"
      else
        AGENT_FILTER="${AGENT_FILTER},${picked}"
      fi
    fi
    i=$((i + 1))
  done
  msg '已选择 %s 个 Agent\n' 'Selected %s agent(s)\n' "$(selected_count)" >&3
}

validate_scope() {
  case "$SCOPE" in
    user | project) ;;
    "") fail "$(msg '缺少 %s。使用 --help 查看用法。' 'Missing %s. See --help for usage.' --scope)" ;;
    *) fail "$(msg '%s 只能是 user 或 project，收到：%s' '%s must be user or project, got: %s' --scope "$SCOPE")" ;;
  esac
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
  if [ -n "$SOURCE_DIRECTORY" ]; then
    [ -d "$SOURCE_DIRECTORY" ] ||
      fail "$(msg '%s 目录不存在：%s' '%s directory does not exist: %s' --source "$SOURCE_DIRECTORY")"
    RESOURCE_DIRECTORY="$(cd "$SOURCE_DIRECTORY" && pwd)"
    RESOURCE_SOURCE_LABEL="$(msg '本地检出 %s' 'local checkout %s' "$RESOURCE_DIRECTORY")"
    [ -f "${RESOURCE_DIRECTORY}/config/agents.json" ] ||
      fail "$(msg '%s 目录下缺少 %s：%s' '%s directory has no %s: %s' --source config/agents.json "$RESOURCE_DIRECTORY")"
    return 0
  fi

  WORK_DIRECTORY="$(mktemp -d "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/setup-instructions.XXXXXX")" ||
    fail "$(msg '无法创建临时目录。' 'Cannot create a temporary directory.')"
  RESOURCE_DIRECTORY="$WORK_DIRECTORY"
  RESOURCE_SOURCE_LABEL="GitHub ${GITHUB_REPOSITORY}@${GITHUB_BRANCH}"
  download_resource "config/agents.json" "${RESOURCE_DIRECTORY}/config/agents.json"
  download_resource "templates/entry-${SCOPE}.md" "${RESOURCE_DIRECTORY}/templates/entry-${SCOPE}.md"
}

registry_file() {
  printf '%s' "${RESOURCE_DIRECTORY}/config/agents.json"
}

validate_registry() {
  jq -e . "$(registry_file)" >/dev/null 2>&1 ||
    fail "$(msg '注册表不是合法 JSON：%s' 'The registry is not valid JSON: %s' "$(registry_file)")"
}

selected_agent_ids() {
  jq -r --arg scope "$SCOPE" --arg filter "$AGENT_FILTER" '
    ($filter | if . == "" then [] else split(",") | map(gsub("^\\s+|\\s+$";"")) end) as $want
    | .agents
    | keys
    | map(select($want == [] or IN($want[])))
    | .[]
  ' "$(registry_file)"
}

# $1 agent id，$2 jq 表达式（相对于该 agent 对象，$scope 可用）
agent_field() {
  jq -r --arg id "$1" --arg scope "$SCOPE" "
    .agents[\$id] | $2 // \"\" | tostring
  " "$(registry_file)"
}

# 基准层声明的规则正本位置，供 standard 分支展示
shared_instructions_root() {
  jq -r --arg scope "$SCOPE" '.shared.instructions_root[$scope] // "-"' "$(registry_file)"
}

agent_name() {
  jq -r --arg id "$1" '.agents[$id].name' "$(registry_file)"
}

template_title() {
  # $1 入口文件相对路径
  case "$1" in
    */*) printf '项目上下文入口' ;;
    *) printf '%s' "$1" ;;
  esac
}

render_entry() {
  # $1 agent id，$2 入口文件相对路径；渲染结果写入 $3
  # 变体模板由注册表显式声明，不做文件探测：下载模式下探测会对没有变体的
  # Agent 发起必然失败的请求，而失败即中止。
  override_rel="$(agent_field "$1" ".instructions.template_override[\$scope]")"
  frontmatter_rel="$(agent_field "$1" ".instructions.template_frontmatter[\$scope]")"
  base_template="${RESOURCE_DIRECTORY}/templates/entry-${SCOPE}.md"

  if [ -n "$override_rel" ]; then
    override_file="${RESOURCE_DIRECTORY}/${override_rel}"
    if [ ! -f "$override_file" ]; then
      [ -n "$SOURCE_DIRECTORY" ] &&
        fail "$(msg '注册表声明的模板不存在：%s' 'Template declared in the registry does not exist: %s' "$override_file")"
      download_resource "$override_rel" "$override_file"
    fi
    cat "$override_file" >"$3"
    return 0
  fi

  [ -f "$base_template" ] || fail "$(msg '缺少模板：%s' 'Missing template: %s' "$base_template")"
  : >"$3"
  if [ -n "$frontmatter_rel" ]; then
    frontmatter_file="${RESOURCE_DIRECTORY}/${frontmatter_rel}"
    if [ ! -f "$frontmatter_file" ]; then
      [ -n "$SOURCE_DIRECTORY" ] &&
        fail "$(msg '注册表声明的前置块不存在：%s' 'Frontmatter declared in the registry does not exist: %s' "$frontmatter_file")"
      download_resource "$frontmatter_rel" "$frontmatter_file"
    fi
    cat "$frontmatter_file" >>"$3"
  fi
  title="$(template_title "$2")"
  sed "s|{{TITLE}}|${title}|g" "$base_template" >>"$3"
}

# 计划行：动作|展示名|入口相对路径|说明|agent id。
# agent id 放在最后，只供套用阶段定位渲染结果，不从展示名反查。
add_plan() {
  PLAN="${PLAN}$1|$2|$3|$4|$5
"
}

# 多个 Agent 可以声明同一个入口文件。它们只能写入同一份内容，
# 否则谁后写谁生效，结果取决于遍历顺序；发现不一致在任何写入之前中止。
# $1 agent id，$2 入口相对路径，$3 渲染结果
claim_entry() {
  claimed="${WORK_DIRECTORY}/claimed"
  [ -f "$claimed" ] || : >"$claimed"
  owner="$(awk -F '\t' -v want="$2" '$1 == want { print $2; exit }' "$claimed")"
  if [ -z "$owner" ]; then
    printf '%s\t%s\n' "$2" "$1" >>"$claimed"
    return 0
  fi
  cmp -s "$3" "${WORK_DIRECTORY}/render/${owner}.${SCOPE}.md" ||
    fail "$(msg '%s 与 %s 共用入口 %s，但渲染出的内容不同。请在注册表中让二者使用相同模板，或改用不同路径。' \
      '%s and %s share the entry %s but render different content. Give them the same template in the registry, or use different paths.' \
      "$owner" "$1" "$2")"
}

build_plan() {
  staging="${WORK_DIRECTORY:-${TMPDIR:-/tmp}}"
  if [ -z "$WORK_DIRECTORY" ]; then
    WORK_DIRECTORY="$(mktemp -d "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/setup-instructions.XXXXXX")"
    staging="$WORK_DIRECTORY"
  fi
  mkdir -p "${staging}/render"

  selected_agent_ids | while IFS= read -r agent_id; do
    [ -n "$agent_id" ] || continue
    printf '%s\n' "$agent_id"
  done >"${staging}/ids"

  while IFS= read -r agent_id; do
    [ -n "$agent_id" ] || continue
    display_name="$(agent_name "$agent_id")"
    instructions="$(agent_field "$agent_id" ".instructions.scope[\$scope]")"

    if [ "$instructions" = "standard" ]; then
      add_plan "standard" "$display_name" "$(shared_instructions_root)" "$(msg '原生读取' 'read natively')" "$agent_id"
    elif [ -z "$instructions" ]; then
      add_plan "skip-unknown" "$display_name" "-" "" "$agent_id"
    else
      entry_path="${TARGET_ROOT}/${instructions}"
      rendered="${staging}/render/${agent_id}.${SCOPE}.md"
      render_entry "$agent_id" "$instructions" "$rendered"
      claim_entry "$agent_id" "$instructions" "$rendered"
      if [ -e "$entry_path" ] && cmp -s "$rendered" "$entry_path"; then
        add_plan "skip-entry" "$display_name" "$instructions" "$(msg '内容已一致' 'up to date')" "$agent_id"
      elif [ -e "$entry_path" ]; then
        add_plan "update-entry" "$display_name" "$instructions" \
          "$(msg '原文件备份为 %s' 'original backed up as %s' .local.bak)" "$agent_id"
      else
        add_plan "create-entry" "$display_name" "$instructions" "" "$agent_id"
      fi
    fi

  done <"${staging}/ids"
}

# 计划分层展示：已就绪的每个入口一行，要写入的逐条列出，未声明入口的 Agent 汇总成一行。
# 多个 Agent 共用同一入口时只列一行，Agent 名合并展示。
print_plan() {
  msg '范围：%s    目标：%s\n' 'Scope: %s    Target: %s\n' "$SCOPE" "$TARGET_ROOT"
  msg '资源：%s\n' 'Resources: %s\n' "$RESOURCE_SOURCE_LABEL"
  printf '%s' "$PLAN" | awk -F'|' -v lang="$UI_LANG" '
    # 与 Shell 侧的 msg 同理：两种语言并排写在调用处。
    function t(zh_cn, en) { return (lang == "zh-CN") ? zh_cn : en }
    function add_who(k, who) {
      if ((k SUBSEP who) in who_seen) return
      who_seen[k SUBSEP who] = 1
      # 先判断再赋值：部分 awk 在求值右侧前就为左侧建键，写成一行会多出前导逗号。
      if (k in who_list) who_list[k] = who_list[k] ", " who
      else who_list[k] = who
    }
    function widen(text) { if (length(text) > width) width = length(text) }
    # 动作编码只供内部流转，展示时换成读者能直接看懂的说法。
    # 标签在同一语言内等宽，且放在已对齐的路径之后：awk 按字节计宽，中文放在前面会对不齐。
    function label_of(act) {
      if (act == "create-entry") return t("新建", "create")
      if (act == "update-entry") return t("覆盖", "update")
      return act
    }
    $1 == "" { next }
    {
      act = $1; who = $2; entry = $3; detail = $4
      if (act == "skip-unknown") {
        add_who("unknown", who)
        next
      }
      section = (act == "skip-entry" || act == "standard") ? "ready" : "change"
      k = act SUBSEP entry
      if (!(k in row_act)) {
        rows[section, ++row_total[section]] = k
        row_act[k] = act
        row_entry[k] = entry
        row_detail[k] = detail
        widen(entry)
      }
      add_who(k, who)
    }
    END {
      if (row_total["ready"] > 0) {
        printf "\n%s\n", t("已就绪", "Ready")
        for (i = 1; i <= row_total["ready"]; i++) {
          k = rows["ready", i]
          printf "  %-" width "s  %s%s%s\n", row_entry[k], row_detail[k], t("：", ": "), who_list[k]
        }
      }
      if (row_total["change"] > 0) {
        printf "\n%s\n", sprintf(t("即将执行（%d）", "To apply (%d)"), row_total["change"])
        for (i = 1; i <= row_total["change"]; i++) {
          k = rows["change", i]
          tail = label_of(row_act[k]) "  " who_list[k]
          if (row_detail[k] != "") tail = tail "  " row_detail[k]
          printf "  %-" width "s  %s\n", row_entry[k], tail
        }
      }
      if ("unknown" in who_list) printf "\n%s%s\n", t("未声明入口，不处理：", "No entry declared, skipped: "), who_list["unknown"]
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
  staging="$WORK_DIRECTORY"
  # 共用同一入口的 Agent 已在 claim_entry 中确认内容一致，同一路径只写一次。
  # 重复写会让第二次的备份拿到第一次刚写入的新内容，把真正的原件冲掉。
  printf '%s' "$PLAN" | awk -F'|' '$1 != "" && !seen[$1 FS $3]++' >"${staging}/plan"
  while IFS='|' read -r action _ entry_relpath _ agent_id; do
    [ -n "$action" ] || continue
    case "$action" in
      create-entry | update-entry)
        target="${TARGET_ROOT}/${entry_relpath}"
        mkdir -p "$(dirname "$target")"
        if [ "$action" = "update-entry" ]; then
          cp "$target" "${target}.local.bak"
        fi
        cp "${staging}/render/${agent_id}.${SCOPE}.md" "$target"
        APPLIED=true
        ;;
      *)
        # 已就绪与未声明入口的条目只供展示，没有要执行的动作。
        ;;
    esac
  done <"${staging}/plan"
}

print_summary() {
  if [ "$APPLIED" = true ]; then
    info "$(msg '完成。' 'Done.')"
  fi
}

main() {
  parse_arguments "$@"
  validate_runtime_dependencies
  if [ "$INTERACTIVE" = true ]; then
    collect_interactive_scope
  fi
  validate_scope
  resolve_target_root
  resolve_resources
  validate_registry
  if [ "$INTERACTIVE" = true ]; then
    collect_interactive_agents
  fi
  build_plan

  if [ -z "$PLAN" ]; then
    info "$(msg '没有需要处理的 Agent。' 'No agent to process.')"
    exit 0
  fi

  print_plan

  if [ "$DRY_RUN" = true ]; then
    info "$(msg '%s：未做任何修改。' '%s: no changes made.' --dry-run)"
    exit 0
  fi

  # confirm_default_yes 自己负责按需打开终端；--force 时直接跳过。
  if ! plan_has_changes; then
    info "$(msg '无需改动。' 'Nothing to change.')"
    exit 0
  fi

  if ! confirm_default_yes "$(msg '是否继续？' 'Continue?')"; then
    info "$(msg '已取消，未做任何修改。' 'Cancelled; no changes made.')"
    exit 0
  fi

  apply_plan
  print_summary
}

main "$@"

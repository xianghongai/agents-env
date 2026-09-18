#!/usr/bin/env bash

# 脚本用到 bash 特性；显式用其他 Shell 执行会绕过 shebang，提前给出明确提示。
if [ -z "${BASH_VERSION:-}" ] && [ -z "${ZSH_VERSION:-}" ]; then
  printf '错误：请用 bash 或 zsh 运行本脚本，或 curl ... | bash。\n' >&2
  exit 1
fi

set -Eeuo pipefail

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
APPLIED_COUNT=0
SKIPPED_COUNT=0

print_usage() {
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
  -f, --force                 跳过覆盖确认
  -h, --help                  显示本帮助并退出

行为：
  不带任何参数时进入交互向导；出现任意参数即进入严格非交互模式，
  缺少必填项直接失败，不会补问。

  user    只处理目录已存在的 Agent，不为未安装的工具创建目录。
  project 默认安装注册表中全部 Agent，可用 --agent 收窄。

示例：
  setup-instructions.sh --scope user
  setup-instructions.sh --scope project --target ./my-repo --dry-run
  setup-instructions.sh --scope user --agent claude-code,codex --force
EOF
}

fail() {
  restore_terminal_state
  printf '错误：%s\n' "$1" >&2
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
    fail "${1} 需要一个值。使用 --help 查看用法。"
  fi
}

reject_duplicate() {
  # $1 参数名，$2 当前值
  if [ -n "${2:-}" ]; then
    fail "${1} 重复指定。"
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
        fail "无法识别的参数：${1}。使用 --help 查看用法。"
        ;;
    esac
  done
}

validate_runtime_dependencies() {
  if ! command -v jq >/dev/null 2>&1; then
    fail "未找到 jq。本脚本用 jq 解析 Agent 注册表，请先安装。"
  fi
}

open_interactive_terminal() {
  # 管道执行时标准输入是脚本本身，交互必须改读控制终端。
  # 用独立 fd 而非每次重开 /dev/tty：原始模式的终端属性要在同一个描述符上保存与还原。
  if [ "$TTY_OPENED" = true ]; then
    return 0
  fi
  if ! { exec 3<>/dev/tty; } 2>/dev/null; then
    printf '当前环境没有可用的控制终端，无法进入交互模式。\n' >&2
    printf '请改用非交互调用，例如：\n' >&2
    printf '  setup-instructions.sh --scope user\n' >&2
    exit 1
  fi
  TTY_OPENED=true
}

# 交互菜单会改动终端属性；正常退出、失败和中断都必须还原，否则终端会停在无回显状态。
enter_raw_mode() {
  TERMINAL_STATE_SAVED="$(stty -g <&3)" ||
    fail "无法读取终端属性，请改用 --scope 非交互执行。"
  stty -icanon -echo min 1 time 0 <&3 ||
    fail "无法进入终端原始模式，请改用 --scope 非交互执行。"
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
  printf '\n已取消。\n' >&3
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
  printf '  ↑↓ 或 j/k 移动，回车或空格确认，q 取消\n\n' >&3
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
        printf '\n已取消。\n' >&3
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
    printf '  \033[2m未选择任何 Agent，按 a 全选，空格勾选当前项\033[0m\n' >&3
  else
    printf '  \033[2m已选择 %s 项\033[0m\n' "$picked" >&3
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
  printf '  ↑↓ 或 j/k 移动，空格勾选，a 全选，n 全清，回车确认，q 取消\n\n' >&3
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
        printf '\n已取消。\n' >&3
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
    printf '\n已取消。\n' >&3
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
  printf '为各 AI Agent 安装或更新 Instructions 入口文件。\n' >&3
  run_single_choice_menu "选择安装范围" "user    当前用户（写入用户目录）
project 当前项目（写入项目根目录）（写入仓库根目录）"
  case "$MENU_CURSOR" in
    0) SCOPE="user" ;;
    *) SCOPE="project" ;;
  esac
  printf '已选择：%s\n' "$SCOPE" >&3
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
  [ -n "$agent_ids" ] || fail "注册表中没有可用于 ${SCOPE} 范围的 Agent。"

  run_multi_choice_menu "选择要安装的 Agent" "$agent_labels"

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
  printf '已选择 %s 个 Agent\n' "$(selected_count)" >&3
}

validate_scope() {
  case "$SCOPE" in
    user | project) ;;
    "") fail "缺少 --scope。使用 --help 查看用法。" ;;
    *) fail "--scope 只能是 user 或 project，收到：${SCOPE}" ;;
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
  [ -d "$TARGET_ROOT" ] || fail "目标目录不存在：${TARGET_ROOT}"
  TARGET_ROOT="$(cd "$TARGET_ROOT" && pwd)"
}

download_resource() {
  # $1 仓库内相对路径，$2 落地绝对路径
  url="https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/${GITHUB_BRANCH}/$1"
  mkdir -p "$(dirname "$2")"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$2" || fail "下载失败：${url}"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$url" || fail "下载失败：${url}"
  else
    fail "未找到 curl 或 wget，无法获取资源。可改用 --source 指定本地检出。"
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
    [ -d "$SOURCE_DIRECTORY" ] || fail "--source 目录不存在：${SOURCE_DIRECTORY}"
    RESOURCE_DIRECTORY="$(cd "$SOURCE_DIRECTORY" && pwd)"
    RESOURCE_SOURCE_LABEL="本地检出 ${RESOURCE_DIRECTORY}"
    [ -f "${RESOURCE_DIRECTORY}/config/agents.json" ] ||
      fail "--source 目录下缺少 config/agents.json：${RESOURCE_DIRECTORY}"
    return 0
  fi

  WORK_DIRECTORY="$(mktemp -d "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/setup-instructions.XXXXXX")" ||
    fail "无法创建临时目录。"
  RESOURCE_DIRECTORY="$WORK_DIRECTORY"
  RESOURCE_SOURCE_LABEL="GitHub ${GITHUB_REPOSITORY}@${GITHUB_BRANCH}"
  download_resource "config/agents.json" "${RESOURCE_DIRECTORY}/config/agents.json"
  download_resource "templates/entry-${SCOPE}.md" "${RESOURCE_DIRECTORY}/templates/entry-${SCOPE}.md"
}

registry_file() {
  printf '%s' "${RESOURCE_DIRECTORY}/config/agents.json"
}

validate_registry() {
  jq -e . "$(registry_file)" >/dev/null 2>&1 || fail "注册表不是合法 JSON：$(registry_file)"
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
      [ -n "$SOURCE_DIRECTORY" ] && fail "注册表声明的模板不存在：${override_file}"
      download_resource "$override_rel" "$override_file"
    fi
    cat "$override_file" >"$3"
    return 0
  fi

  [ -f "$base_template" ] || fail "缺少模板：${base_template}"
  : >"$3"
  if [ -n "$frontmatter_rel" ]; then
    frontmatter_file="${RESOURCE_DIRECTORY}/${frontmatter_rel}"
    if [ ! -f "$frontmatter_file" ]; then
      [ -n "$SOURCE_DIRECTORY" ] && fail "注册表声明的前置块不存在：${frontmatter_file}"
      download_resource "$frontmatter_rel" "$frontmatter_file"
    fi
    cat "$frontmatter_file" >>"$3"
  fi
  title="$(template_title "$2")"
  sed "s|{{TITLE}}|${title}|g" "$base_template" >>"$3"
}

add_plan() {
  PLAN="${PLAN}$1|$2|$3|$4
"
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
      add_plan "standard" "$display_name" "$(shared_instructions_root)" "原生读取标准位置，无需指针文件"
    elif [ -z "$instructions" ]; then
      add_plan "skip-unknown" "$display_name" "-" "路径未知，不动作"
    else
      entry_path="${TARGET_ROOT}/${instructions}"
      rendered="${staging}/render/${agent_id}.${SCOPE}.md"
      render_entry "$agent_id" "$instructions" "$rendered"
      if [ -e "$entry_path" ] && cmp -s "$rendered" "$entry_path"; then
        add_plan "skip-entry" "$display_name" "$instructions" "内容已一致"
      elif [ -e "$entry_path" ]; then
        add_plan "update-entry" "$display_name" "$instructions" "内容不同，备份为 .local.bak 后覆盖"
      else
        add_plan "create-entry" "$display_name" "$instructions" "新建"
      fi
    fi

  done <"${staging}/ids"
}

print_plan() {
  info "范围：${SCOPE}    目标：${TARGET_ROOT}"
  info "资源：${RESOURCE_SOURCE_LABEL}"
  info ""
  printf '%s' "$PLAN" | while IFS='|' read -r action name entry_relpath detail; do
    [ -n "$action" ] || continue
    printf '  %-13s %-26s %-40s %s\n' "$action" "$name" "$entry_relpath" "$detail"
  done
  info ""
}

apply_plan() {
  staging="$WORK_DIRECTORY"
  printf '%s' "$PLAN" >"${staging}/plan"
  while IFS='|' read -r action name entry_relpath detail; do
    [ -n "$action" ] || continue
    case "$action" in
      create-entry | update-entry)
        agent_id="$(jq -r --arg n "$name" '.agents | to_entries[] | select(.value.name == $n) | .key' "$(registry_file)")"
        target="${TARGET_ROOT}/${entry_relpath}"
        mkdir -p "$(dirname "$target")"
        if [ "$action" = "update-entry" ]; then
          cp "$target" "${target}.local.bak"
        fi
        cp "${staging}/render/${agent_id}.${SCOPE}.md" "$target"
        APPLIED_COUNT=$((APPLIED_COUNT + 1))
        ;;
      *)
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        ;;
    esac
  done <"${staging}/plan"
}

print_summary() {
  info "完成：写入 ${APPLIED_COUNT} 项，跳过 ${SKIPPED_COUNT} 项。"
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
    info "没有需要处理的 Agent。"
    exit 0
  fi

  print_plan

  if [ "$DRY_RUN" = true ]; then
    info "--dry-run：未做任何修改。"
    exit 0
  fi

  # confirm_default_yes 自己负责按需打开终端；--force 时直接跳过。
  if ! confirm_default_yes "按以上计划执行？"; then
    info "已取消，未做任何修改。"
    exit 0
  fi

  apply_plan
  print_summary
}

main "$@"

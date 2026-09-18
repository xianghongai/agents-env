#!/usr/bin/env bash

# 脚本用到 bash 特性；显式用其他 Shell 执行会绕过 shebang，提前给出明确提示。
if [ -z "${BASH_VERSION:-}" ] && [ -z "${ZSH_VERSION:-}" ]; then
  printf '错误：请用 bash 或 zsh 运行本脚本，或 curl ... | bash。\n' >&2
  exit 1
fi

set -Eeuo pipefail

readonly GITHUB_REPOSITORY="xianghongai/agents-env"
readonly DEFAULT_GITHUB_BRANCH="main"
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
REPO=""
REPO_REF=""
SOURCE_DIRECTORY=""
TARGET_ROOT=""
GITHUB_BRANCH="$DEFAULT_GITHUB_BRANCH"
DRY_RUN=false
FORCE=false
WORK_DIRECTORY=""
CLONE_DIRECTORY=""
RESOURCE_DIRECTORY=""
RESOURCE_SOURCE_LABEL=""
SKILLS_ROOT=""
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
APPLIED_COUNT=0
SKIPPED_COUNT=0

print_usage() {
  cat <<'EOF'
用法：setup-skills.sh [选项]

获取 Skills 并按注册表声明为各 Agent 建立软链。
省略 --repo 时不获取，只做软链。

选项：
      --scope <user|project>      安装范围
  -r, --repo <repository_url>     来源仓库，任何 git 可克隆的地址；仓库根下须有 skills/
      --ref <branch|tag|commit>   取源的引用，默认仓库默认分支
  -t, --target <dir>              Scope 根目录，默认 user 为 $HOME、project 为当前目录
  -s, --source <dir>.             本仓库的本地检出，用于读取注册表；省略时按需下载
      --dry-run                   只展示计划，不产生任何持久化副作用
  -f, --force                     替换同名 Skill、覆盖已有软链（原件备份为 .local.bak）
  -h, --help                      显示本帮助并退出

行为：
  不带任何参数时进入交互向导；出现任意参数即进入严格非交互模式。

  获取：仓库 skills/ 下的条目增量搬运到共享库。名字不同的新增，
        名字相同的默认跳过，--force 时替换并备份。

  软链：按注册表中每个 Agent 各 Scope 声明的 mode 处理。
        link-dir  整个目录软链到共享库；目标已是含其它内容的实体目录时
                  自动回退为 link-each，避免破坏该 Agent 自带的 Skills。
        link-each 为共享库中的每一项各建一条软链。
        none      不动作，并清理该目录下指向共享库的冗余软链。

示例：
  setup-skills.sh --scope user --repo https://github.com/someone/my-skills.git
  setup-skills.sh --scope project --ref v1.2.0 --repo git@github.com:someone/my-skills.git
  setup-skills.sh --scope user --force
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
      -r | --repo)
        reject_duplicate "--repo" "$REPO"
        require_value "--repo" "${2:-}"
        REPO="$2"
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
  printf '获取 Skills 并按注册表声明为各 Agent 建立软链。\n' >&3
  run_single_choice_menu "选择安装范围" "user    当前用户（写入用户目录）
project 当前项目（写入项目根目录）（写入仓库根目录）"
  case "$MENU_CURSOR" in
    0) SCOPE="user" ;;
    *) SCOPE="project" ;;
  esac
  printf '已选择：%s\n' "$SCOPE" >&3

  printf '\n来源仓库地址（留空则跳过获取，只做软链）：' >&3
  if ! IFS= read -r REPLY_VALUE <&3; then
    printf '\n已取消。\n' >&3
    exit 1
  fi
  REPO="$REPLY_VALUE"
  if [ -n "$REPO" ]; then
    printf '分支或标签（留空用默认分支）：' >&3
    IFS= read -r REPLY_VALUE <&3 || REPLY_VALUE=""
    REPO_REF="$REPLY_VALUE"
  fi
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
  invalid_mode="$(jq -r --arg scope "$SCOPE" '
    [.agents | to_entries[] | select((.value.skills.scope[$scope].mode // "") | IN("link-dir","link-each","none") | not) | .key] | join(", ")
  ' "$(registry_file)")"
  if [ -n "$invalid_mode" ]; then
    fail "注册表中以下 Agent 的 skills.scope.${SCOPE}.mode 非法：${invalid_mode}"
  fi
  SKILLS_ROOT="$(jq -r --arg scope "$SCOPE" '.shared.skills_root[$scope] // ""' "$(registry_file)")"
  [ -n "$SKILLS_ROOT" ] || fail "注册表缺少 shared.skills_root.${SCOPE}。"
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
  command -v git >/dev/null 2>&1 || fail "未找到 git。获取远程 Skills 需要 git，或省略 --repo 只做软链。"
  CLONE_DIRECTORY="${WORK_DIRECTORY}/clone"
  if [ -n "$REPO_REF" ]; then
    git clone --depth 1 --branch "$REPO_REF" -- "$REPO" "$CLONE_DIRECTORY" >/dev/null 2>&1 ||
      fail "克隆失败：${REPO}（ref=${REPO_REF}）"
  else
    git clone --depth 1 -- "$REPO" "$CLONE_DIRECTORY" >/dev/null 2>&1 ||
      fail "克隆失败：${REPO}"
  fi
  [ -d "${CLONE_DIRECTORY}/skills" ] ||
    fail "来源仓库根下没有 skills/ 目录。本工具约定：仓库须提供 skills/，其下每个目录为一个 Skill。"
  if [ -z "$(ls -A "${CLONE_DIRECTORY}/skills" 2>/dev/null)" ]; then
    fail "来源仓库的 skills/ 为空。"
  fi
}

add_plan() {
  PLAN="${PLAN}$1|$2|$3|$4
"
}

# 获取阶段：仓库 skills/ 下的顶层条目增量进共享库
plan_fetch() {
  [ -n "$REPO" ] || return 0
  dest_root="${TARGET_ROOT}/${SKILLS_ROOT}"
  find "${CLONE_DIRECTORY}/skills" -mindepth 1 -maxdepth 1 >"${WORK_DIRECTORY}/incoming" 2>/dev/null || true
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    name="$(basename "$item")"
    if [ ! -e "${dest_root}/${name}" ]; then
      add_plan "fetch-new" "$name" "${SKILLS_ROOT}/${name}" "新增"
    elif [ "$FORCE" = true ]; then
      add_plan "fetch-replace" "$name" "${SKILLS_ROOT}/${name}" "同名替换，原件备份为 .local.bak"
    else
      add_plan "fetch-skip" "$name" "${SKILLS_ROOT}/${name}" "同名已存在，--force 才替换"
    fi
  done <"${WORK_DIRECTORY}/incoming"
}

# 共享库当前的真实条目。软链阶段在获取阶段落盘之后才计算，
# 因此这里读到的就是最终内容，不需要预测另一阶段的结果。
shared_skill_names() {
  dest_root="${TARGET_ROOT}/${SKILLS_ROOT}"
  [ -d "$dest_root" ] || return 0
  find "$dest_root" -mindepth 1 -maxdepth 1 2>/dev/null >"${WORK_DIRECTORY}/names.raw" || true
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    basename "$item"
  done <"${WORK_DIRECTORY}/names.raw" | sort -u
}

# 目录中是否存在「不是指向共享库的软链」的内容：有则整目录软链会破坏它们
has_foreign_content() {
  [ -d "$1" ] || return 1
  find "$1" -mindepth 1 -maxdepth 1 >"${WORK_DIRECTORY}/scan" 2>/dev/null || true
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if [ -L "$entry" ]; then
      case "$(readlink "$entry")" in
        *"$SKILLS_ROOT"*) continue ;;
      esac
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
    # 备份件不参与软链。
    case "$name" in *.local.bak) continue ;; esac
    link_path="${link_root}/${name}"
    # 深度按软链自身的路径算：它位于 <dir>/<name>，比 <dir> 深一层。
    want="$(relative_to_skills_root "$2/${name}")/${name}"
    if [ -L "$link_path" ]; then
      if [ "$(readlink "$link_path")" = "$want" ]; then
        add_plan "skip-link" "$1" "$2/${name}" "软链已正确"
      else
        add_plan "relink" "$1" "$2/${name}" "改指向 ${want}"
      fi
    elif [ -e "$link_path" ]; then
      add_plan "blocked-link" "$1" "$2/${name}" "同名实体存在，跳过不覆盖"
    else
      add_plan "link-each" "$1" "$2/${name}" "-> ${want}"
    fi
  done <"${WORK_DIRECTORY}/shared"
}

plan_link() {
  selected_agent_ids >"${WORK_DIRECTORY}/ids"
  while IFS= read -r agent_id; do
    [ -n "$agent_id" ] || continue
    display_name="$(agent_field "$agent_id" ".name")"
    skills_path="$(agent_field "$agent_id" ".skills.scope[\$scope].path")"
    skills_mode="$(agent_field "$agent_id" ".skills.scope[\$scope].mode")"
    if [ "$skills_path" = "standard" ]; then
      add_plan "standard" "$display_name" "$SKILLS_ROOT" "原生读取共享库，无需软链"
      continue
    fi
    [ -n "$skills_path" ] || continue

    link_path="${TARGET_ROOT}/${skills_path}"
    case "$skills_mode" in
      link-dir)
        want="$(relative_to_skills_root "$skills_path")"
        if [ -L "$link_path" ]; then
          if [ "$(readlink "$link_path")" = "$want" ]; then
            add_plan "skip-link" "$display_name" "$skills_path" "整目录软链已正确"
          else
            add_plan "relink-dir" "$display_name" "$skills_path" "改指向 ${want}"
          fi
        elif has_foreign_content "$link_path"; then
          add_plan "fallback" "$display_name" "$skills_path" "目录内有其它内容，回退为逐项软链"
          plan_link_each "$display_name" "$skills_path"
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
            case "$(readlink "$candidate")" in
              *"$SKILLS_ROOT"*)
                add_plan "prune-link" "$display_name" "${skills_path}/$(basename "$candidate")" "声明 none，冗余软链"
                ;;
            esac
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
  info "范围：${SCOPE}    目标：${TARGET_ROOT}"
  info "注册表：${RESOURCE_SOURCE_LABEL}    共享库：${SKILLS_ROOT}"
  # 不能写成 [ -n ... ] && info ...：条件为假时函数以非零状态返回，会被 set -e 杀掉。
  if [ -n "$REPO" ]; then
    info "来源仓库：${REPO}${REPO_REF:+ @${REPO_REF}}"
  fi
}

print_plan() {
  info ""
  printf '%s' "$PLAN" | while IFS='|' read -r action name entry_relpath detail; do
    [ -n "$action" ] || continue
    printf '  %-14s %-26s %-44s %s\n' "$action" "$name" "$entry_relpath" "$detail"
  done
  info ""
}

apply_plan() {
  printf '%s' "$PLAN" >"${WORK_DIRECTORY}/plan"
  dest_root="${TARGET_ROOT}/${SKILLS_ROOT}"
  while IFS='|' read -r action name entry_relpath detail; do
    [ -n "$action" ] || continue
    target="${TARGET_ROOT}/${entry_relpath}"
    case "$action" in
      fetch-new | fetch-replace)
        mkdir -p "$dest_root"
        # 落入前目标必须不存在：cp -R 到已存在的目录会拷进其内部形成合并，
        # 那样旧版残留的文件会与新版混在一起，且没有任何提示。
        if [ -e "$target" ]; then
          rm -rf "${target}.local.bak"
          mv "$target" "${target}.local.bak"
        fi
        cp -R "${CLONE_DIRECTORY}/skills/${name}" "$target"
        APPLIED_COUNT=$((APPLIED_COUNT + 1))
        ;;
      link-dir | relink-dir)
        mkdir -p "$(dirname "$target")"
        [ -L "$target" ] && rm "$target"
        ln -s "$(relative_to_skills_root "$entry_relpath")" "$target"
        APPLIED_COUNT=$((APPLIED_COUNT + 1))
        ;;
      link-each | relink)
        # 目标由路径重新推导，不从展示文案反解：文案变了不该影响行为。
        mkdir -p "$(dirname "$target")"
        [ -L "$target" ] && rm "$target"
        ln -s "$(relative_to_skills_root "$entry_relpath")/$(basename "$entry_relpath")" "$target"
        APPLIED_COUNT=$((APPLIED_COUNT + 1))
        ;;
      prune-link)
        [ -L "$target" ] && rm "$target"
        APPLIED_COUNT=$((APPLIED_COUNT + 1))
        ;;
      *)
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        ;;
    esac
  done <"${WORK_DIRECTORY}/plan"
}

print_summary() {
  info "完成：执行 ${APPLIED_COUNT} 项，跳过 ${SKIPPED_COUNT} 项。"
}

# 一个阶段 = 计划、展示、确认、应用。两个阶段互不依赖：
# 只做获取、只做软链、或先获取再软链，都是同一套流程的组合。
# $1 阶段名，$2 生成计划的函数名
run_phase() {
  PLAN=""
  "$2"
  if [ -z "$PLAN" ]; then
    info "[$1] 没有需要处理的项。"
    return 0
  fi
  info "[$1]"
  print_plan
  if [ "$DRY_RUN" = true ]; then
    return 0
  fi
  if ! confirm_default_yes "执行以上 $1 计划？"; then
    info "[$1] 已跳过。"
    return 0
  fi
  apply_plan
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

  if [ -z "$WORK_DIRECTORY" ]; then
    WORK_DIRECTORY="$(mktemp -d "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/setup-skills.XXXXXX")" ||
      fail "无法创建临时目录。"
  fi

  print_context

  if [ -n "$REPO" ]; then
    clone_repository
    run_phase "获取" plan_fetch
  fi

  # 软链阶段读取共享库的真实内容。获取阶段若被跳过或取消，这里看到的就是
  # 未变的现状：两个阶段解耦，随时可以只跑其中一个。
  run_phase "软链" plan_link

  if [ "$DRY_RUN" = true ]; then
    info "--dry-run：未做任何修改。"
    exit 0
  fi
  print_summary
}

main "$@"

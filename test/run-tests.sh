#!/usr/bin/env bash
# 仅在一次性容器内执行。宿主不运行本文件，也不运行被测脚本。
# 只覆盖 Instructions 的核心能力：两种 Scope 的安装结果、幂等、不破坏既有内容、
# dry-run 无副作用、两种资源来源。Skills 相关能力由 skills-tests.sh 覆盖。
#
# 用法：TEST_SHELL=bash|zsh bash test/run-tests.sh
set -uo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
SCRIPT_UNDER_TEST="${WORKSPACE}/setup-instructions.sh"
REGISTRY="${WORKSPACE}/config/agents.json"
SHELL_BIN="${TEST_SHELL:-bash}"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  [ok]   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1"; }
skip() { printf '  [skip] %s\n' "$1"; }
head_() { printf '\n== %s (%s) ==\n' "$1" "$SHELL_BIN"; }
run() { "$SHELL_BIN" "$SCRIPT_UNDER_TEST" "$@"; }

# 断言只描述机制，期望值一律从注册表现场推导。清单会随厂商支持情况增删，
# 测试里不出现任何 Agent 名字，增删 Agent 不应该需要改动本文件。

# $1 scope：该 Scope 下声明了入口文件的全部 Agent 入口相对路径
entry_paths() {
  jq -r --arg scope "$1" '
    .agents | to_entries[]
    | select((.value.instructions.scope[$scope] // "") | . != "" and . != "standard")
    | .value.instructions.scope[$scope]
  ' "$REGISTRY"
}

# $1 scope：同上，取标识符
entry_agent_ids() {
  jq -r --arg scope "$1" '
    .agents | to_entries[]
    | select((.value.instructions.scope[$scope] // "") | . != "" and . != "standard")
    | .key
  ' "$REGISTRY"
}

# $1 agent id，$2 scope
entry_path_of() {
  jq -r --arg id "$1" --arg scope "$2" '
    .agents[$id].instructions.scope[$scope] // ""
  ' "$REGISTRY"
}

# $1 scope：层级最深的入口路径。取最深的而不是随便一个，
# 才能真正验证多级目录一并创建，且不依赖清单里恰好有哪几家。
deepest_entry_path() {
  entry_paths "$1" | awk -F/ '{ print NF "\t" $0 }' | sort -rn | head -1 | cut -f2-
}

# $1 scope：首个位于 Scope 根、不含目录层级的入口
flat_entry_path() { entry_paths "$1" | awk -F/ 'NF == 1 { print; exit }'; }

# $1 scope：首个声明了 frontmatter 变体模板的 Agent 的入口路径
frontmatter_entry_path() {
  jq -r --arg scope "$1" '
    .agents | to_entries[]
    | select((.value.instructions.template_frontmatter[$scope] // "") != "")
    | .value.instructions.scope[$scope] // empty
  ' "$REGISTRY" | head -1
}

# 基准层的共享落点，同样来自注册表，不写死 .agents/*
shared_instructions_path() {
  jq -r --arg scope "$1" '.shared.instructions_root[$scope] // ""' "$REGISTRY"
}

shared_skills_path() {
  jq -r --arg scope "$1" '.shared.skills_root[$scope] // ""' "$REGISTRY"
}

# 期望值靠推导得来，推导落空会让断言变成空转而假通过，所以先把前提钉死。
require_fixture() {
  [ "$(entry_paths user | wc -l)" -ge 2 ] ||
    { printf '前提不满足：注册表中 user 入口少于 2 个，无法验证 --agent 过滤。\n' >&2; exit 1; }
  [ -n "$(deepest_entry_path user)" ] ||
    { printf '前提不满足：注册表中无位于子目录的 user 入口，无法验证多级目录创建。\n' >&2; exit 1; }
  [ -n "$(shared_skills_path user)" ] ||
    { printf '前提不满足：注册表缺少 shared.skills_root.user。\n' >&2; exit 1; }
}
require_fixture

# 取一个位于子目录下的 user 入口，在其目录内预置哨兵文件，
# 用于验证脚本不破坏 Agent 自带内容。目录名来自注册表，不写死某家。
SENTINEL_REL="$(deepest_entry_path user | sed 's|/[^/]*$||')/vendor-own/keep.txt"

fresh_home() {
  root="$(mktemp -d /tmp/fakehome.XXXXXX)"
  skills="$(shared_skills_path user)"
  mkdir -p "$root/$(dirname "$SENTINEL_REL")" "$root/${skills}/demo-skill"
  printf 'vendor\n' >"$root/$SENTINEL_REL"
  printf 'x\n' >"$root/${skills}/demo-skill/SKILL.md"
  printf '%s' "$root"
}

fresh_project() {
  root="$(mktemp -d /tmp/fakeproj.XXXXXX)"
  mkdir -p "$root/$(shared_skills_path project)"
  shared="$(shared_instructions_path project)"
  [ -n "$shared" ] && printf '# shared\n' >"$root/$shared"
  printf '%s' "$root"
}

head_ "user scope 安装"
H="$(fresh_home)"
run --scope user --source "$WORKSPACE" --target "$H" --force >/dev/null 2>&1
missing=""
for rel in $(entry_paths user); do
  [ -f "$H/$rel" ] || missing="${missing} ${rel}"
done
[ -z "$missing" ] && ok "声明入口的 Agent 全部写入" || bad "以下入口未写入：${missing}"
deepest_user="$(deepest_entry_path user)"
[ -f "$H/$deepest_user" ] && ok "多级目录一并创建" || bad "多级目录未创建：${deepest_user}"
[ -f "$H/$SENTINEL_REL" ] && ok "Agent 自带内容未被破坏" || bad "自带内容被破坏"

head_ "幂等与备份"
first_user="$(entry_paths user | head -1)"
sum1="$(find "$H" -type f -exec md5sum {} + | sort | md5sum)"
run --scope user --source "$WORKSPACE" --target "$H" --force >/dev/null 2>&1
sum2="$(find "$H" -type f -exec md5sum {} + | sort | md5sum)"
[ "$sum1" = "$sum2" ] && ok "重复执行结果一致" || bad "重复执行改变了结果"
printf 'stale\n' >"$H/$first_user"
run --scope user --source "$WORKSPACE" --target "$H" --force >/dev/null 2>&1
[ -f "$H/${first_user}.local.bak" ] && ok "内容不同时备份为 .local.bak" || bad "未备份原文件"

head_ "project scope"
P="$(fresh_project)"
run --scope project --source "$WORKSPACE" --target "$P" --force >/dev/null 2>&1
flat_proj="$(flat_entry_path project)"
if [ -n "$flat_proj" ]; then
  [ -f "$P/$flat_proj" ] && ok "写入根级入口文件" || bad "未写入根级入口文件：${flat_proj}"
else
  skip "注册表中无根级 project 入口，跳过"
fi
deepest_proj="$(deepest_entry_path project)"
if [ -n "$deepest_proj" ]; then
  [ -f "$P/$deepest_proj" ] && ok "写入嵌套规则文件" || bad "未写入嵌套规则文件：${deepest_proj}"
else
  skip "注册表中无嵌套 project 入口，跳过"
fi
fm_proj="$(frontmatter_entry_path project)"
if [ -n "$fm_proj" ]; then
  head -1 "$P/$fm_proj" | grep -q -- '---' &&
    ok "变体模板生效（frontmatter）" || bad "变体模板未生效：${fm_proj}"
else
  skip "注册表中无 project frontmatter 变体，跳过"
fi
shared_proj="$(shared_instructions_path project)"
[ ! -e "$P/${shared_proj}.local.bak" ] &&
  ok "未触碰既有共享规则正本" || bad "误改了 ${shared_proj}"

head_ "dry-run 与 agent 过滤"
H2="$(fresh_home)"
before="$(find "$H2" | sort | md5sum)"
run --scope user --source "$WORKSPACE" --target "$H2" --dry-run >/dev/null 2>&1
[ "$before" = "$(find "$H2" | sort | md5sum)" ] && ok "--dry-run 无副作用" || bad "--dry-run 产生了副作用"
pick_id="$(entry_agent_ids user | head -1)"
other_id="$(entry_agent_ids user | sed -n '2p')"
pick_path="$(entry_path_of "$pick_id" user)"
other_path="$(entry_path_of "$other_id" user)"
run --scope user --source "$WORKSPACE" --target "$H2" --agent "$pick_id" --force >/dev/null 2>&1
[ -f "$H2/$pick_path" ] && [ ! -e "$H2/$other_path" ] &&
  ok "--agent 只处理指定 Agent" || bad "--agent 过滤未生效"

head_ "资源来源"
H4="$(fresh_home)"
out="$(cd "$WORKSPACE" && run --scope user --target "$H4" --force 2>&1)"
printf '%s' "$out" | grep -q "资源：本地检出" && ok "检出目录内自动用本地资源" || bad "未识别本地检出"
probe="$(entry_paths user | head -1)"
FAKEBIN="$(mktemp -d /tmp/fakebin.XXXXXX)"
cat >"$FAKEBIN/curl" <<'FAKE'
#!/usr/bin/env bash
out=""; url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
rel="${url#*/main/}"
[ -f "$FAKE_WORKSPACE/$rel" ] || exit 22
mkdir -p "$(dirname "$out")"; cp "$FAKE_WORKSPACE/$rel" "$out"
FAKE
chmod +x "$FAKEBIN/curl"
ISO="$(mktemp -d /tmp/isolated.XXXXXX)"
cp "$SCRIPT_UNDER_TEST" "$ISO/setup-instructions.sh"
H5="$(fresh_home)"
PATH="$FAKEBIN:$PATH" FAKE_WORKSPACE="$WORKSPACE" \
  "$SHELL_BIN" "$ISO/setup-instructions.sh" --scope user --target "$H5" --force >/dev/null 2>&1
[ -f "$H5/$probe" ] && ok "下载模式可完成安装" || bad "下载模式未完成安装"

printf '\n通过 %s，失败 %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# 仅在一次性容器内执行。覆盖 setup-skills.sh 的核心能力：
# 来源识别（单 Skill / 多 Skill、--path 起点、--skill 筛选）、增量获取与库外备份、两种软链形态与整目录的回退、
# none 的清理、改名与删除后的失效软链清理、同名库外条目不替换、计划的分层展示、纯机制（虚构注册表）。
#
# 用法：TEST_SHELL=bash|zsh bash test/setup-skills/tests.sh
set -uo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
SCRIPT_UNDER_TEST="${WORKSPACE}/setup-skills.sh"
REGISTRY="${WORKSPACE}/config/agents.json"
SHELL_BIN="${TEST_SHELL:-bash}"
# 界面语言固定为 zh-CN：按报错文字区分拦截原因的用例因此不受容器 locale 影响。
export AGENTS_ENV_SETUP_LANG=zh-CN
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  [ok]   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1"; }
head_() { printf '\n== %s (%s) ==\n' "$1" "$SHELL_BIN"; }
run() { "$SHELL_BIN" "$SCRIPT_UNDER_TEST" "$@"; }
# 脱离控制终端运行：docker compose run 默认分配 TTY，确认逻辑的测试不能依赖调用方式。
run_no_tty() { setsid "$SHELL_BIN" "$SCRIPT_UNDER_TEST" "$@" </dev/null; }
command -v setsid >/dev/null 2>&1 || { printf '前提不满足：测试环境缺少 setsid。\n' >&2; exit 1; }

# 断言只描述机制，期望值一律从注册表现场推导：共享库路径取自基准层，
# 被测目录按「声明了哪种 mode」挑选，而不是写死某个厂商。清单增删不影响本文件。
SKILLS_ROOT_USER="$(jq -r '.shared.skills_root.user // ""' "$REGISTRY")"
SKILLS_ROOT_PROJ="$(jq -r '.shared.skills_root.project // ""' "$REGISTRY")"

# $1 scope，$2 mode：首个在该 Scope 声明了该 mode 的 Agent 的私有 Skills 目录
skills_path_with_mode() {
  jq -r --arg scope "$1" --arg mode "$2" '
    .agents | to_entries[]
    | select(.value.skills.scope[$scope].mode == $mode)
    | select((.value.skills.scope[$scope].path // "") | . != "" and . != "standard")
    | .value.skills.scope[$scope].path
  ' "$REGISTRY" | head -1
}

# 从软链所在位置回到 Scope 根的相对前缀。这里独立重算一遍，
# 不复用被测脚本的实现，路径算错才能被发现。
rel_prefix() { printf '%s' "$1" | awk -F/ '{ for (i = 1; i < NF; i++) printf "../" }'; }

LINK_EACH_USER="$(skills_path_with_mode user link-each)"
LINK_DIR_PROJ="$(skills_path_with_mode project link-dir)"

# 推导落空会让断言空转而假通过，先把前提钉死。
[ -n "$SKILLS_ROOT_USER" ] && [ -n "$SKILLS_ROOT_PROJ" ] ||
  { printf '前提不满足：注册表缺少 shared.skills_root。\n' >&2; exit 1; }
[ -n "$LINK_EACH_USER" ] ||
  { printf '前提不满足：注册表中无 user 声明 link-each 的 Agent。\n' >&2; exit 1; }
[ -n "$LINK_DIR_PROJ" ] ||
  { printf '前提不满足：注册表中无 project 声明 link-dir 的 Agent。\n' >&2; exit 1; }

SKILLS_BACKUP_USER="${SKILLS_ROOT_USER%/}.local.bak"

# $1 目录：初始化为 git 仓库并提交全部内容
commit_all() {
  git -C "$1" init -q
  git -C "$1" config user.email t@e.st
  git -C "$1" config user.name test
  git -C "$1" add -A
  git -C "$1" commit -qm init
}

# 来源仓库用本地路径现造，git clone 支持克隆本地目录，全程无需网络。
# 多 Skill 形态，另放一个说明文件和一个不含 SKILL.md 的目录，验证它们不被当成 Skill。
make_repo() {
  root="$(mktemp -d /tmp/srcrepo.XXXXXX)"
  mkdir -p "$root/skills/alpha-skill" "$root/skills/beta-skill" "$root/skills/not-a-skill"
  printf 'alpha v1\n' >"$root/skills/alpha-skill/SKILL.md"
  printf 'beta v1\n' >"$root/skills/beta-skill/SKILL.md"
  printf 'notes\n' >"$root/skills/not-a-skill/notes.md"
  printf 'index\n' >"$root/skills/README.md"
  commit_all "$root"
  printf '%s' "$root"
}

# 单 Skill 形态：SKILL.md 在仓库根，frontmatter 的 name 与仓库目录名不同。
# $1 frontmatter 中的 name
make_single_repo() {
  root="$(mktemp -d /tmp/single-repo.XXXXXX)"
  mkdir -p "$root/references"
  printf -- '---\nname: %s\ndescription: demo\n---\n\nsingle v1\n' "$1" >"$root/SKILL.md"
  printf 'ref\n' >"$root/references/guide.md"
  commit_all "$root"
  printf '%s' "$root"
}

fresh_home() {
  root="$(mktemp -d /tmp/skhome.XXXXXX)"
  mkdir -p "$root/${SKILLS_ROOT_USER}"
  printf '%s' "$root"
}

REPO="$(make_repo)"

head_ "增量获取"
H="$(fresh_home)"
run --scope user --source "$WORKSPACE" --target "$H" --repo "$REPO" --force >/dev/null 2>&1
[ -f "$H/${SKILLS_ROOT_USER}/alpha-skill/SKILL.md" ] && ok "获取到共享库" || bad "未获取到共享库"
[ -f "$H/${SKILLS_ROOT_USER}/beta-skill/SKILL.md" ] && ok "多个条目一并获取" || bad "条目缺失"
[ ! -e "$H/${SKILLS_ROOT_USER}/README.md" ] && [ ! -e "$H/${SKILLS_ROOT_USER}/not-a-skill" ] &&
  ok "skills/ 下不含 SKILL.md 的条目不获取" || bad "非 Skill 条目被获取"

head_ "同名默认跳过，--force 才替换"
printf 'local edit\n' >"$H/${SKILLS_ROOT_USER}/alpha-skill/SKILL.md"
# 容器内没有控制终端，不带 --yes 会停在确认处；只看文件未变会假通过，所以先确认流程走完了。
if run_no_tty --scope user --source "$WORKSPACE" --target "$H" --repo "$REPO" --yes >/dev/null 2>&1; then
  ok "--yes 无终端也能执行完毕"
else
  bad "--yes 未能跳过确认"
fi
grep -q 'local edit' "$H/${SKILLS_ROOT_USER}/alpha-skill/SKILL.md" && ok "--yes 不替换同名" || bad "--yes 替换了同名"
[ ! -e "$H/${SKILLS_BACKUP_USER}/alpha-skill" ] && ok "未替换时不产生备份" || bad "未替换却产生了备份"

HY="$(fresh_home)"
if out="$(run_no_tty --scope user --source "$WORKSPACE" --target "$HY" --repo "$REPO" 2>&1)"; then
  bad "无终端且未带 --yes 时应失败"
else
  ok "无终端且未带 --yes 时非零退出"
fi
printf '%s' "$out" | grep -q -- '--yes' && ok "报错提示追加 --yes" || bad "报错未提示 --yes"
[ ! -e "$HY/${SKILLS_ROOT_USER}/alpha-skill" ] && ok "确认失败时不落盘" || bad "确认失败仍然落盘"
run --scope user --source "$WORKSPACE" --target "$H" --repo "$REPO" --force >/dev/null 2>&1
grep -q 'alpha v1' "$H/${SKILLS_ROOT_USER}/alpha-skill/SKILL.md" && ok "--force 替换同名" || bad "--force 未替换"
[ -f "$H/${SKILLS_BACKUP_USER}/alpha-skill/SKILL.md" ] && ok "替换前备份到共享库之外" || bad "未备份原件"
[ ! -e "$H/${SKILLS_ROOT_USER}/alpha-skill.local.bak" ] && ok "共享库内不留备份件" || bad "备份件留在共享库内"
# 替换必须是整份替换而非合并：旧版独有的文件不得残留在目标里
mkdir -p "$H/${SKILLS_ROOT_USER}/beta-skill/references"
printf 'stale\n' >"$H/${SKILLS_ROOT_USER}/beta-skill/references/legacy.md"
run --scope user --source "$WORKSPACE" --target "$H" --repo "$REPO" --force >/dev/null 2>&1
[ ! -e "$H/${SKILLS_ROOT_USER}/beta-skill/references/legacy.md" ] &&
  ok "替换是整份替换，旧版独有文件不残留" || bad "替换发生了合并，旧版文件残留"
[ -f "$H/${SKILLS_BACKUP_USER}/beta-skill/references/legacy.md" ] &&
  ok "旧版独有文件完整保留在备份中" || bad "备份丢失了旧版文件"

head_ "本地自写 Skill 不被删除"
mkdir -p "$H/${SKILLS_ROOT_USER}/my-own-skill"
printf 'mine\n' >"$H/${SKILLS_ROOT_USER}/my-own-skill/SKILL.md"
run --scope user --source "$WORKSPACE" --target "$H" --repo "$REPO" --force >/dev/null 2>&1
[ -f "$H/${SKILLS_ROOT_USER}/my-own-skill/SKILL.md" ] && ok "来源没有的条目保留" || bad "本地条目被删除"

head_ "单 Skill 仓库"
SINGLE="$(make_single_repo solo-from-root)"
HS="$(fresh_home)"
run --scope user --source "$WORKSPACE" --target "$HS" --repo "$SINGLE" --force >/dev/null 2>&1
[ -f "$HS/${SKILLS_ROOT_USER}/solo-from-root/SKILL.md" ] &&
  ok "根下 SKILL.md 时整个仓库作为一个 Skill，按 name 命名" || bad "单 Skill 仓库未按 name 落地"
[ -f "$HS/${SKILLS_ROOT_USER}/solo-from-root/references/guide.md" ] && ok "Skill 附属文件一并获取" || bad "附属文件缺失"
[ ! -e "$HS/${SKILLS_ROOT_USER}/solo-from-root/.git" ] && ok "不复制版本库元数据" || bad "复制了 .git"
[ -L "$HS/${LINK_EACH_USER}/solo-from-root" ] && ok "单 Skill 同样建软链" || bad "单 Skill 未建软链"

head_ "非法名称在落盘前中止"
EVIL="$(make_single_repo '../escape')"
HE="$(fresh_home)"
before_e="$(find "$HE" | sort | md5sum)"
if run --scope user --source "$WORKSPACE" --target "$HE" --repo "$EVIL" --force >/dev/null 2>&1; then
  bad "非法名称未被拒绝"
else
  ok "非法名称以非零状态退出"
fi
[ "$before_e" = "$(find "$HE" | sort | md5sum)" ] && ok "非法名称无副作用" || bad "非法名称产生了副作用"

head_ "同名 Skill 在落盘前中止"
DUP="$(mktemp -d /tmp/dup-repo.XXXXXX)"
mkdir -p "$DUP/skills/one" "$DUP/skills/two"
printf -- '---\nname: same\n---\n' >"$DUP/skills/one/SKILL.md"
printf -- '---\nname: same\n---\n' >"$DUP/skills/two/SKILL.md"
commit_all "$DUP"
HD="$(fresh_home)"
before_d="$(find "$HD" | sort | md5sum)"
if run --scope user --source "$WORKSPACE" --target "$HD" --repo "$DUP" --force >/dev/null 2>&1; then
  bad "同名 Skill 未被拒绝"
else
  ok "同名 Skill 以非零状态退出"
fi
[ "$before_d" = "$(find "$HD" | sort | md5sum)" ] && ok "同名 Skill 无副作用" || bad "同名 Skill 产生了副作用"

head_ "--path：分类嵌套仓库"
NESTED="$(mktemp -d /tmp/nested-repo.XXXXXX)"
mkdir -p "$NESTED/skills/.curated/cur-one" "$NESTED/skills/.curated/cur-two" "$NESTED/skills/.system/sys-one"
printf 'x\n' >"$NESTED/skills/.curated/cur-one/SKILL.md"
printf 'x\n' >"$NESTED/skills/.curated/cur-two/SKILL.md"
printf 'x\n' >"$NESTED/skills/.system/sys-one/SKILL.md"
commit_all "$NESTED"
HN="$(fresh_home)"
run --scope user --source "$WORKSPACE" --target "$HN" --repo "$NESTED" --path skills/.curated/ --force >/dev/null 2>&1
[ -f "$HN/${SKILLS_ROOT_USER}/cur-one/SKILL.md" ] && [ -f "$HN/${SKILLS_ROOT_USER}/cur-two/SKILL.md" ] &&
  ok "--path 指向分类目录时获取其下 Skill" || bad "--path 分类目录未获取"
[ ! -e "$HN/${SKILLS_ROOT_USER}/sys-one" ] && ok "--path 之外的分类不获取" || bad "获取了 --path 之外的 Skill"
HN2="$(fresh_home)"
if run --scope user --source "$WORKSPACE" --target "$HN2" --repo "$NESTED" --force >/dev/null 2>&1; then
  bad "未指定 --path 时不应识别分类嵌套"
else
  ok "未指定 --path 时不递归识别分类嵌套"
fi

head_ "--path：从非 Skills 专用仓库抽取单个 Skill"
MIXED="$(mktemp -d /tmp/mixed-repo.XXXXXX)"
mkdir -p "$MIXED/src" "$MIXED/tools/agent/picked-skill"
printf 'app\n' >"$MIXED/src/app.txt"
printf 'no frontmatter\n' >"$MIXED/tools/agent/picked-skill/SKILL.md"
ln -s tools/agent/picked-skill "$MIXED/inside-link"
ln -s /etc "$MIXED/outside-link"
commit_all "$MIXED"
HM="$(fresh_home)"
run --scope user --source "$WORKSPACE" --target "$HM" --repo "$MIXED" --path tools/agent/picked-skill --force >/dev/null 2>&1
[ -f "$HM/${SKILLS_ROOT_USER}/picked-skill/SKILL.md" ] &&
  ok "指向单个 Skill 目录时按目录名落地" || bad "单个 Skill 未抽取"
[ ! -e "$HM/${SKILLS_ROOT_USER}/picked-skill/src" ] && ok "只复制该 Skill 目录" || bad "复制了仓库其它内容"
HM2="$(fresh_home)"
run --scope user --source "$WORKSPACE" --target "$HM2" --repo "$MIXED" --path inside-link --force >/dev/null 2>&1
[ -f "$HM2/${SKILLS_ROOT_USER}/inside-link/SKILL.md" ] && [ ! -L "$HM2/${SKILLS_ROOT_USER}/inside-link" ] &&
  ok "仓库内软链按内容复制" || bad "仓库内软链未按内容复制"

head_ "--path 与 --skill 的校验在落盘前完成"
HV="$(fresh_home)"
before_v="$(find "$HV" | sort | md5sum)"
for args in "--path ../escape" "--path /abs" "--path a/./b" "--path missing-dir" "--path outside-link" "--skill no-such-skill"; do
  # shellcheck disable=SC2086
  if run --scope user --source "$WORKSPACE" --target "$HV" --repo "$MIXED" $args --force >/dev/null 2>&1; then
    bad "应当拒绝：${args}"
  else
    ok "拒绝：${args}"
  fi
done
for args in "--path tools" "--skill alpha-skill"; do
  # shellcheck disable=SC2086
  if run --scope user --source "$WORKSPACE" --target "$HV" $args --force >/dev/null 2>&1; then
    bad "缺少 --repo 时应当拒绝：${args}"
  else
    ok "缺少 --repo 时拒绝：${args}"
  fi
done
[ "$before_v" = "$(find "$HV" | sort | md5sum)" ] && ok "校验失败无副作用" || bad "校验失败产生了副作用"

head_ "--skill：只装其中几个"
HK="$(fresh_home)"
run --scope user --source "$WORKSPACE" --target "$HK" --repo "$REPO" --skill beta-skill --skill beta-skill --force >/dev/null 2>&1
[ -f "$HK/${SKILLS_ROOT_USER}/beta-skill/SKILL.md" ] && ok "获取指定的 Skill" || bad "指定的 Skill 未获取"
[ ! -e "$HK/${SKILLS_ROOT_USER}/alpha-skill" ] && ok "未指定的 Skill 不获取" || bad "获取了未指定的 Skill"
HK2="$(fresh_home)"
run --scope user --source "$WORKSPACE" --target "$HK2" --repo "$NESTED" --path skills/.curated --skill cur-two --force >/dev/null 2>&1
[ -f "$HK2/${SKILLS_ROOT_USER}/cur-two/SKILL.md" ] && [ ! -e "$HK2/${SKILLS_ROOT_USER}/cur-one" ] &&
  ok "--path 与 --skill 组合生效" || bad "--path 与 --skill 组合未生效"
HK3="$(fresh_home)"
before_k="$(find "$HK3" | sort | md5sum)"
if run --scope user --source "$WORKSPACE" --target "$HK3" --repo "$REPO" --skill alpha-skill --skill ghost --force >/dev/null 2>&1; then
  bad "部分名称不存在时应当整体拒绝"
else
  ok "部分名称不存在时整体拒绝"
fi
[ "$before_k" = "$(find "$HK3" | sort | md5sum)" ] && ok "整体拒绝无副作用" || bad "整体拒绝产生了副作用"

head_ "逐项软链（user 声明 link-each）"
each_link="${LINK_EACH_USER}/alpha-skill"
want_each="$(rel_prefix "$each_link")${SKILLS_ROOT_USER}/alpha-skill"
[ -L "$H/$each_link" ] && ok "为每个条目建软链" || bad "未逐项建软链：${each_link}"
[ "$(readlink "$H/$each_link")" = "$want_each" ] &&
  ok "逐项软链为相对路径" || bad "逐项软链路径不对：$(readlink "$H/$each_link" 2>/dev/null) 期望 ${want_each}"
[ -L "$H/${LINK_EACH_USER}/my-own-skill" ] && ok "本地自写条目同样接入" || bad "本地条目未接入"

head_ "整目录软链与自带内容的共存"
want_dir="$(rel_prefix "$LINK_DIR_PROJ")${SKILLS_ROOT_PROJ}"
P="$(mktemp -d /tmp/skproj.XXXXXX)"; mkdir -p "$P/${SKILLS_ROOT_PROJ}"
run --scope project --source "$WORKSPACE" --target "$P" --repo "$REPO" --force >/dev/null 2>&1
[ -L "$P/$LINK_DIR_PROJ" ] && ok "project 声明 link-dir 时整目录软链" || bad "未建整目录软链：${LINK_DIR_PROJ}"
[ "$(readlink "$P/$LINK_DIR_PROJ")" = "$want_dir" ] &&
  ok "整目录软链为相对路径" || bad "整目录软链路径不对：$(readlink "$P/$LINK_DIR_PROJ" 2>/dev/null) 期望 ${want_dir}"

P2="$(mktemp -d /tmp/skproj.XXXXXX)"; mkdir -p "$P2/${SKILLS_ROOT_PROJ}" "$P2/${LINK_DIR_PROJ}/vendor-own-skill"
printf 'vendor\n' >"$P2/${LINK_DIR_PROJ}/vendor-own-skill/SKILL.md"
run --scope project --source "$WORKSPACE" --target "$P2" --repo "$REPO" --force >/dev/null 2>&1
[ -d "$P2/${LINK_DIR_PROJ}/vendor-own-skill" ] && ok "目录内已有内容时不被整目录软链覆盖" || bad "自带内容被破坏"
[ -L "$P2/${LINK_DIR_PROJ}/alpha-skill" ] && ok "自动回退为逐项软链" || bad "未回退为逐项软链"

head_ "只做软链，不获取"
H2="$(fresh_home)"
mkdir -p "$H2/${SKILLS_ROOT_USER}/solo-skill"
printf 'solo\n' >"$H2/${SKILLS_ROOT_USER}/solo-skill/SKILL.md"
run --scope user --source "$WORKSPACE" --target "$H2" --force >/dev/null 2>&1
[ -L "$H2/${LINK_EACH_USER}/solo-skill" ] && ok "省略 --repo 时只建软链" || bad "省略 --repo 时未建软链"

head_ "软链只认含 SKILL.md 的目录"
H6="$(fresh_home)"
mkdir -p "$H6/${SKILLS_ROOT_USER}/real-skill" "$H6/${SKILLS_ROOT_USER}/plain-dir"
printf 'x\n' >"$H6/${SKILLS_ROOT_USER}/real-skill/SKILL.md"
printf 'x\n' >"$H6/${SKILLS_ROOT_USER}/README.md"
run --scope user --source "$WORKSPACE" --target "$H6" --force >/dev/null 2>&1
[ -L "$H6/${LINK_EACH_USER}/real-skill" ] && ok "Skill 目录建软链" || bad "Skill 目录未建软链"
[ ! -e "$H6/${LINK_EACH_USER}/README.md" ] && [ ! -e "$H6/${LINK_EACH_USER}/plain-dir" ] &&
  ok "普通文件与无 SKILL.md 的目录不建软链" || bad "非 Skill 条目被建了软链"

head_ "旧版库内备份迁出"
H7="$(fresh_home)"
mkdir -p "$H7/${SKILLS_ROOT_USER}/old-skill.local.bak"
printf 'old\n' >"$H7/${SKILLS_ROOT_USER}/old-skill.local.bak/SKILL.md"
run --scope user --source "$WORKSPACE" --target "$H7" --force >/dev/null 2>&1
[ ! -e "$H7/${SKILLS_ROOT_USER}/old-skill.local.bak" ] &&
  [ -f "$H7/${SKILLS_BACKUP_USER}/old-skill/SKILL.md" ] &&
  ok "库内旧备份迁到共享库之外" || bad "库内旧备份未迁出"
[ ! -e "$H7/${LINK_EACH_USER}/old-skill.local.bak" ] && ok "旧备份不建软链" || bad "旧备份被建了软链"

head_ "来源仓库约定"
BADREPO="$(mktemp -d /tmp/badrepo.XXXXXX)"
git -C "$BADREPO" init -q
git -C "$BADREPO" config user.email t@e.st
git -C "$BADREPO" config user.name test
printf 'x\n' >"$BADREPO/README.md"
git -C "$BADREPO" add -A && git -C "$BADREPO" commit -qm init
H3="$(fresh_home)"
before="$(find "$H3" | sort | md5sum)"
run --scope user --source "$WORKSPACE" --target "$H3" --repo "$BADREPO" --force >/dev/null 2>&1 ||
  ok "仓库既无根 SKILL.md 也无 skills/ 时以非零状态退出"
[ "$before" = "$(find "$H3" | sort | md5sum)" ] && ok "失败时无副作用" || bad "失败仍产生了副作用"

head_ "dry-run 无副作用"
H4="$(fresh_home)"
before4="$(find "$H4" | sort | md5sum)"
run --scope user --source "$WORKSPACE" --target "$H4" --repo "$REPO" --dry-run >/dev/null 2>&1
[ "$before4" = "$(find "$H4" | sort | md5sum)" ] && ok "--dry-run 未修改任何文件" || bad "--dry-run 产生了副作用"

head_ "共享库中 Skill 改名与删除后清理失效软链"
HR="$(fresh_home)"
for n in old-name doomed kept; do
  mkdir -p "$HR/${SKILLS_ROOT_USER}/$n"
  printf 'x\n' >"$HR/${SKILLS_ROOT_USER}/$n/SKILL.md"
done
run --scope user --source "$WORKSPACE" --target "$HR" --force >/dev/null 2>&1
[ -L "$HR/${LINK_EACH_USER}/old-name" ] && [ -L "$HR/${LINK_EACH_USER}/doomed" ] ||
  { printf '前提不满足：初次运行未建立逐项软链。\n' >&2; exit 1; }
mv "$HR/${SKILLS_ROOT_USER}/old-name" "$HR/${SKILLS_ROOT_USER}/new-name"
rm -rf "$HR/${SKILLS_ROOT_USER}/doomed"
# 不该被清理的三种形态：仍可用的别名软链、指向共享库之外的软链、实体目录。
ln -s "$(rel_prefix "${LINK_EACH_USER}/alias")${SKILLS_ROOT_USER}/kept" "$HR/${LINK_EACH_USER}/alias"
ln -s /nonexistent/elsewhere "$HR/${LINK_EACH_USER}/foreign-link"
mkdir -p "$HR/${LINK_EACH_USER}/vendor-own"
printf 'v\n' >"$HR/${LINK_EACH_USER}/vendor-own/SKILL.md"
before_r="$(find "$HR" | sort | md5sum)"
out_r="$(run --scope user --source "$WORKSPACE" --target "$HR" --dry-run 2>&1)"
[ "$before_r" = "$(find "$HR" | sort | md5sum)" ] && ok "--dry-run 不清理" || bad "--dry-run 清理了软链"
printf '%s' "$out_r" | grep -q "${LINK_EACH_USER}/old-name  *失效软链" &&
  ok "计划中列出失效软链" || bad "计划未列出失效软链"
printf '%s' "$out_r" | grep -Eq 'prune-stale|link-each|skip-link' &&
  bad "计划中出现内部动作编码" || ok "计划不展示内部动作编码"
# 分层展示：已就绪只汇总，要执行与要清理各自成节，动作以中文标签而非内部编码展示。
printf '%s' "$out_r" | grep -q '^已就绪' && ok "计划含已就绪汇总" || bad "计划缺少已就绪汇总"
printf '%s' "$out_r" | grep -q '^即将执行' && ok "计划含即将执行一节" || bad "计划缺少即将执行一节"
printf '%s' "$out_r" | grep -q '^即将清理' && ok "计划含即将清理一节" || bad "计划缺少即将清理一节"
printf '%s' "$out_r" | grep -q "${LINK_EACH_USER}/kept" &&
  bad "已就绪的条目仍逐条列出" || ok "已就绪的条目不逐条列出"
run --scope user --source "$WORKSPACE" --target "$HR" --force >/dev/null 2>&1
[ ! -L "$HR/${LINK_EACH_USER}/old-name" ] && ok "改名后旧名软链被清理" || bad "旧名软链残留"
[ -L "$HR/${LINK_EACH_USER}/new-name" ] && [ -f "$HR/${LINK_EACH_USER}/new-name/SKILL.md" ] &&
  ok "改名后新名软链建立" || bad "新名软链未建立"
[ ! -L "$HR/${LINK_EACH_USER}/doomed" ] && ok "删除后软链被清理" || bad "已删除 Skill 的软链残留"
[ -L "$HR/${LINK_EACH_USER}/alias" ] && ok "仍可用的别名软链保留" || bad "别名软链被误删"
[ -L "$HR/${LINK_EACH_USER}/foreign-link" ] && ok "指向共享库之外的软链不碰" || bad "外部软链被误删"
[ -f "$HR/${LINK_EACH_USER}/vendor-own/SKILL.md" ] && ok "实体目录不碰" || bad "实体目录被破坏"
sum_r="$(find "$HR" | sort | md5sum)"
run --scope user --source "$WORKSPACE" --target "$HR" --force >/dev/null 2>&1
[ "$sum_r" = "$(find "$HR" | sort | md5sum)" ] && ok "清理后重复执行结果一致" || bad "重复执行仍有变化"
# 全部已就绪时没有可确认的内容：无终端、不带 --yes 也应直接完成。
if out_n="$(run_no_tty --scope user --source "$WORKSPACE" --target "$HR" 2>&1)"; then
  ok "全部已就绪时不要求确认"
else
  bad "全部已就绪时仍要求确认"
fi
printf '%s' "$out_n" | grep -q '无需改动' && ok "全部已就绪时提示无需改动" || bad "未提示无需改动"
printf '%s' "$out_n" | grep -q '^完成' && bad "无改动时仍输出完成" || ok "无改动时不输出完成"

# link-dir 回退为逐项软链时走同一套清理。
PR="$(mktemp -d /tmp/skproj.XXXXXX)"
mkdir -p "$PR/${SKILLS_ROOT_PROJ}/gone-skill" "$PR/${LINK_DIR_PROJ}/vendor-own-skill"
printf 'x\n' >"$PR/${SKILLS_ROOT_PROJ}/gone-skill/SKILL.md"
printf 'v\n' >"$PR/${LINK_DIR_PROJ}/vendor-own-skill/SKILL.md"
run --scope project --source "$WORKSPACE" --target "$PR" --force >/dev/null 2>&1
[ -L "$PR/${LINK_DIR_PROJ}/gone-skill" ] ||
  { printf '前提不满足：回退场景未建立逐项软链。\n' >&2; exit 1; }
rm -rf "$PR/${SKILLS_ROOT_PROJ}/gone-skill"
run --scope project --source "$WORKSPACE" --target "$PR" --force >/dev/null 2>&1
[ ! -L "$PR/${LINK_DIR_PROJ}/gone-skill" ] && ok "回退为逐项软链时同样清理" || bad "回退场景失效软链残留"
[ -d "$PR/${LINK_DIR_PROJ}/vendor-own-skill" ] && ok "回退场景自带内容不碰" || bad "回退场景自带内容被破坏"

head_ "同名条目指向共享库之外时不替换"
HF="$(fresh_home)"
for n in own-dir foreign-live foreign-dead lookalike in-store-abs; do
  mkdir -p "$HF/${SKILLS_ROOT_USER}/$n"
  printf 'store\n' >"$HF/${SKILLS_ROOT_USER}/$n/SKILL.md"
done
mkdir -p "$HF/${LINK_EACH_USER}/own-dir" "$HF/elsewhere/foreign-live" "$HF/${SKILLS_ROOT_USER%/}-old/lookalike"
printf 'mine\n' >"$HF/${LINK_EACH_USER}/own-dir/SKILL.md"
printf 'mine\n' >"$HF/elsewhere/foreign-live/SKILL.md"
printf 'mine\n' >"$HF/${SKILLS_ROOT_USER%/}-old/lookalike/SKILL.md"
ln -s "$HF/elsewhere/foreign-live" "$HF/${LINK_EACH_USER}/foreign-live"
ln -s /nonexistent/foreign-dead "$HF/${LINK_EACH_USER}/foreign-dead"
# 路径前缀与共享库相同、但并不在库内：子串匹配会误判为库内。
ln -s "$HF/${SKILLS_ROOT_USER%/}-old/lookalike" "$HF/${LINK_EACH_USER}/lookalike"
# 指向库内但写法不对的软链仍应改指向，修复不能把它一并拦下。
ln -s "$HF/${SKILLS_ROOT_USER}/in-store-abs" "$HF/${LINK_EACH_USER}/in-store-abs"
[ -L "$HF/${LINK_EACH_USER}/foreign-live" ] && [ -f "$HF/${SKILLS_ROOT_USER}/foreign-live/SKILL.md" ] ||
  { printf '前提不满足：同名的库外软链与库内 Skill 未就位。\n' >&2; exit 1; }
# --force 只作用于获取阶段，不应让软链阶段覆盖任何东西。
if run --scope user --source "$WORKSPACE" --target "$HF" --force >/dev/null 2>&1; then
  ok "存在同名库外条目时正常退出"
else
  bad "存在同名库外条目时以非零状态退出"
fi
grep -q mine "$HF/${LINK_EACH_USER}/own-dir/SKILL.md" && [ ! -L "$HF/${LINK_EACH_USER}/own-dir" ] &&
  ok "同名实体目录不替换" || bad "同名实体目录被替换"
[ "$(readlink "$HF/${LINK_EACH_USER}/foreign-live")" = "$HF/elsewhere/foreign-live" ] &&
  ok "同名库外软链（有效）不替换" || bad "同名库外软链（有效）被改指向"
[ "$(readlink "$HF/${LINK_EACH_USER}/foreign-dead")" = /nonexistent/foreign-dead ] &&
  ok "同名库外软链（失效）不替换" || bad "同名库外软链（失效）被改指向"
[ "$(readlink "$HF/${LINK_EACH_USER}/lookalike")" = "$HF/${SKILLS_ROOT_USER%/}-old/lookalike" ] &&
  ok "前缀相似的库外软链不替换" || bad "前缀相似的库外软链被改指向"
[ "$(readlink "$HF/${LINK_EACH_USER}/in-store-abs")" = \
  "$(rel_prefix "${LINK_EACH_USER}/in-store-abs")${SKILLS_ROOT_USER}/in-store-abs" ] &&
  ok "指向库内但写法不对的软链改为相对路径" || bad "库内软链未改指向：$(readlink "$HF/${LINK_EACH_USER}/in-store-abs")"

# 整目录软链同理：目录本身指向库外时，既不替换，也不往里面建链。
PF="$(mktemp -d /tmp/skproj.XXXXXX)"
mkdir -p "$PF/${SKILLS_ROOT_PROJ}/some-skill" "$PF/elsewhere" "$(dirname "$PF/${LINK_DIR_PROJ}")"
printf 'x\n' >"$PF/${SKILLS_ROOT_PROJ}/some-skill/SKILL.md"
ln -s "$PF/elsewhere" "$PF/${LINK_DIR_PROJ}"
run --scope project --source "$WORKSPACE" --target "$PF" --force >/dev/null 2>&1
[ "$(readlink "$PF/${LINK_DIR_PROJ}")" = "$PF/elsewhere" ] &&
  ok "指向库外的整目录软链不替换" || bad "指向库外的整目录软链被改指向"
[ -z "$(find "$PF/elsewhere" -mindepth 1)" ] && ok "不往库外目录里建链" || bad "库外目录里被写入了内容"
PI="$(mktemp -d /tmp/skproj.XXXXXX)"
mkdir -p "$PI/${SKILLS_ROOT_PROJ}/some-skill" "$(dirname "$PI/${LINK_DIR_PROJ}")"
printf 'x\n' >"$PI/${SKILLS_ROOT_PROJ}/some-skill/SKILL.md"
ln -s "$PI/${SKILLS_ROOT_PROJ}" "$PI/${LINK_DIR_PROJ}"
run --scope project --source "$WORKSPACE" --target "$PI" --force >/dev/null 2>&1
[ "$(readlink "$PI/${LINK_DIR_PROJ}")" = "$(rel_prefix "$LINK_DIR_PROJ")${SKILLS_ROOT_PROJ}" ] &&
  ok "指向库内但写法不对的整目录软链改为相对路径" || bad "库内整目录软链未改指向：$(readlink "$PI/${LINK_DIR_PROJ}")"

head_ "整目录软链接管空目录与只含库内软链的目录"
want_pd="$(rel_prefix "$LINK_DIR_PROJ")${SKILLS_ROOT_PROJ}"
for shape in empty store-links-only; do
  PD="$(mktemp -d /tmp/skproj.XXXXXX)"
  mkdir -p "$PD/${SKILLS_ROOT_PROJ}/some-skill" "$PD/${LINK_DIR_PROJ}"
  printf 'x\n' >"$PD/${SKILLS_ROOT_PROJ}/some-skill/SKILL.md"
  [ "$shape" = store-links-only ] && ln -s "$PD/${SKILLS_ROOT_PROJ}/some-skill" "$PD/${LINK_DIR_PROJ}/some-skill"
  run --scope project --source "$WORKSPACE" --target "$PD" --force >/dev/null 2>&1
  [ "$(readlink "$PD/${LINK_DIR_PROJ}")" = "$want_pd" ] &&
    ok "${shape}：目录换成整目录软链" || bad "${shape}：目录未换成整目录软链"
  [ -f "$PD/${LINK_DIR_PROJ}/some-skill/SKILL.md" ] &&
    ok "${shape}：经整目录软链可读到 Skill" || bad "${shape}：经整目录软链读不到 Skill"
  sum_pd="$(find "$PD" | sort | md5sum)"
  run --scope project --source "$WORKSPACE" --target "$PD" --force >/dev/null 2>&1
  [ "$sum_pd" = "$(find "$PD" | sort | md5sum)" ] &&
    ok "${shape}：重复执行结果一致" || bad "${shape}：重复执行仍有变化"
done

head_ "纯机制：虚构注册表"
FAKE="$(mktemp -d /tmp/fakereg.XXXXXX)"
mkdir -p "$FAKE/config"
cat >"$FAKE/config/agents.json" <<'JSON'
{
  "shared": { "skills_root": { "user": "shared/library", "project": "shared/library" } },
  "agents": {
    "nonexistent-one": { "name": "Nonexistent One", "vendor": "Fictional",
      "instructions": { "scope": { "user": null, "project": null } },
      "skills": { "scope": {
        "user":    { "path": "vendor-a/bag", "mode": "link-dir" },
        "project": { "path": "vendor-a/bag", "mode": "none" } } } },
    "nonexistent-two": { "name": "Nonexistent Two", "vendor": "Fictional",
      "instructions": { "scope": { "user": null, "project": null } },
      "skills": { "scope": {
        "user":    { "path": "deeply/nested/dir", "mode": "link-each" },
        "project": { "path": "deeply/nested/dir", "mode": "none" } } } }
  }
}
JSON
H5="$(mktemp -d /tmp/fakehome.XXXXXX)"
mkdir -p "$H5/shared/library/some-skill"
printf 'x\n' >"$H5/shared/library/some-skill/SKILL.md"
run --scope user --source "$FAKE" --target "$H5" --force >/dev/null 2>&1
[ "$(readlink "$H5/vendor-a/bag" 2>/dev/null)" = "../shared/library" ] &&
  ok "共享库路径来自注册表而非脚本常量" || bad "未跟随注册表的 shared.skills_root"
[ "$(readlink "$H5/deeply/nested/dir/some-skill" 2>/dev/null)" = "../../../shared/library/some-skill" ] &&
  ok "任意深度路径的逐项软链正确" || bad "深层路径软链不对：$(readlink "$H5/deeply/nested/dir/some-skill" 2>/dev/null)"

head_ "纯机制：同一 Agent 两级声明不同 mode"
P3="$(mktemp -d /tmp/fakeproj.XXXXXX)"
mkdir -p "$P3/shared/library/some-skill" "$P3/vendor-a/bag"
ln -s ../../shared/library/some-skill "$P3/vendor-a/bag/some-skill"
run --scope project --source "$FAKE" --target "$P3" --force >/dev/null 2>&1
[ ! -e "$P3/vendor-a/bag/some-skill" ] && ok "project 声明 none 时清理冗余软链" || bad "none 未清理冗余软链"

head_ "纯机制：多个 Agent 共用同一目录"
FAKE2="$(mktemp -d /tmp/fakereg.XXXXXX)"
mkdir -p "$FAKE2/config"
cat >"$FAKE2/config/agents.json" <<'JSON'
{
  "shared": { "skills_root": { "user": "shared/library", "project": "shared/library" } },
  "agents": {
    "twin-a": { "name": "Twin A", "instructions": { "scope": { "user": null, "project": null } },
      "skills": { "scope": { "user": { "path": "twins/dir", "mode": "link-each" },
                             "project": { "path": null, "mode": "none" } } } },
    "twin-b": { "name": "Twin B", "instructions": { "scope": { "user": null, "project": null } },
      "skills": { "scope": { "user": { "path": "twins/dir", "mode": "link-each" },
                             "project": { "path": null, "mode": "none" } } } }
  }
}
JSON
H8="$(mktemp -d /tmp/fakehome.XXXXXX)"
mkdir -p "$H8/shared/library/twin-skill"
printf 'x\n' >"$H8/shared/library/twin-skill/SKILL.md"
# 结尾不再输出条数，用 ln 的替身记录调用次数来确认只执行一次。
LNBIN="$(mktemp -d /tmp/lnbin.XXXXXX)"
REAL_LN="$(command -v ln)"
cat >"$LNBIN/ln" <<SHIM
#!/bin/sh
printf 'x\n' >>"$LNBIN/calls"
exec "$REAL_LN" "\$@"
SHIM
chmod +x "$LNBIN/ln"
out_t="$(PATH="$LNBIN:$PATH" run --scope user --source "$FAKE2" --target "$H8" --force 2>&1)"
[ "$(printf '%s' "$out_t" | grep -c 'twins/dir/twin-skill')" -eq 1 ] &&
  ok "同一路径只列一行" || bad "同一路径重复列出"
printf '%s' "$out_t" | grep -q 'twins/dir/twin-skill  *新建软链  Twin A, Twin B$' &&
  ok "共用目录的 Agent 名合并展示" || bad "Agent 名未合并"
[ "$(wc -l <"$LNBIN/calls" 2>/dev/null | tr -d ' ')" = "1" ] &&
  ok "同一路径只执行一次" || bad "同一路径执行次数不对：$(wc -l <"$LNBIN/calls" 2>/dev/null)"
printf '%s' "$out_t" | grep -q '^完成。$' && ok "执行后输出完成" || bad "执行后未输出完成"
printf '%s' "$out_t" | grep -Eq '执行 [0-9]+ 项|跳过 [0-9]+ 项' && bad "结尾仍输出统计" || ok "结尾不输出统计"
[ "$(readlink "$H8/twins/dir/twin-skill" 2>/dev/null)" = "../../shared/library/twin-skill" ] &&
  ok "共用目录软链正确" || bad "共用目录软链不对"

head_ "安装为命令与自更新"
# 前提：注册表须声明至少一个模板变体，否则「数据完整」的断言会空转。
declared_template_paths() {
  jq -r '[.agents[] | .instructions // {} | (.template_override // {}), (.template_frontmatter // {}) | .[]? | select(type == "string")] | .[]' "$REGISTRY"
}
[ -n "$(declared_template_paths)" ] ||
  { printf '前提不满足：注册表没有声明任何模板变体。\n' >&2; exit 1; }

# 上游用工作区副本模拟：脚本、注册表与模板都从这里取，改动它即模拟远端出了新版本。
UP="$(mktemp -d /tmp/upstream.XXXXXX)"
mkdir -p "$UP/config" "$UP/templates"
cp "$WORKSPACE/setup-skills.sh" "$WORKSPACE/setup-instructions.sh" "$UP/"
cp "$REGISTRY" "$UP/config/"
cp -R "$WORKSPACE/templates/." "$UP/templates/"
# 假 curl：URL 形如 <仓库>/<分支>/<路径>，按路径从上游取文件，每次请求都记入日志；上游缺文件即失败。
FAKEBIN="$(mktemp -d /tmp/fakebin.XXXXXX)"
LOG="$FAKEBIN/requests"
cat >"$FAKEBIN/curl" <<'FAKE'
#!/usr/bin/env bash
out=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >>"$FAKE_LOG"
rest="${url#*/agents-env/}"
rel="${rest#*/}"
[ -f "$FAKE_UPSTREAM/$rel" ] || exit 22
mkdir -p "$(dirname "$out")"
cp "$FAKE_UPSTREAM/$rel" "$out"
FAKE
chmod +x "$FAKEBIN/curl"

# $1 HOME，其余为要执行的命令：在假 curl 环境下运行
with_home() {
  home="$1"
  shift
  env PATH="$FAKEBIN:$PATH" HOME="$home" FAKE_UPSTREAM="$UP" FAKE_LOG="$LOG" "$@"
}

# 以 curl | bash 同形态执行：脚本从标准输入来，$0 不是路径。在无检出的目录里运行，避免误用检出。
# $1 HOME，$2 作为标准输入的脚本，其余为参数
pipe_install() {
  home="$1"
  script="$2"
  shift 2
  (cd "$FAKEBIN" && cat "$script" | with_home "$home" "$SHELL_BIN" -s -- "$@")
}

# 以目录树内容比对，不比时间戳。$1 目录，$2 快照目录
same_tree() {
  diff -r "$1" "$2" >/dev/null
}

H_A="$(mktemp -d /tmp/instA.XXXXXX)"
pipe_install "$H_A" "$UP/setup-skills.sh" --install >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ -x "$H_A/.local/bin/setup-skills" ] && [ -x "$H_A/.local/bin/setup-instructions" ] &&
  ok "管道执行 --install：两个命令装入 ~/.local/bin" || bad "管道执行 --install 未装好命令（退出码 $rc）"
cmp -s "$H_A/.local/bin/setup-skills" "$UP/setup-skills.sh" &&
  cmp -s "$H_A/.local/bin/setup-instructions" "$UP/setup-instructions.sh" &&
  ok "命令内容与上游一致" || bad "命令内容与上游不一致"
cmp -s "$H_A/.local/share/agents-env/config/agents.json" "$UP/config/agents.json" &&
  ok "注册表装入 ~/.local/share/agents-env" || bad "注册表未装入数据目录"
missing="$(declared_template_paths | while IFS= read -r p; do
  [ -f "$H_A/.local/share/agents-env/$p" ] || printf '%s ' "$p"
done)"
[ -z "$missing" ] && ok "注册表声明的模板变体全部装入" || bad "缺少模板变体：$missing"
[ -z "$(find "$H_A" -name '*.local.bak')" ] && ok "首次安装不产生备份" || bad "首次安装产生了备份"

rm -rf "$FAKEBIN/snap"
cp -R "$H_A/.local" "$FAKEBIN/snap"
pipe_install "$H_A" "$UP/setup-skills.sh" --install >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && same_tree "$H_A/.local" "$FAKEBIN/snap" &&
  ok "重复 --install 不改动任何文件" || bad "重复 --install 有改动"

H_B="$(mktemp -d /tmp/instB.XXXXXX)"
pipe_install "$H_B" "$UP/setup-instructions.sh" --install >/dev/null 2>&1
same_tree "$H_A/.local" "$H_B/.local" &&
  ok "两个脚本各自执行 --install，装出的目录树逐字节相同" || bad "两个脚本装出的目录树不同"

: >"$LOG"
env PATH="$FAKEBIN:$PATH" HOME="$H_A" FAKE_UPSTREAM=/nonexistent FAKE_LOG="$LOG" \
  "$SHELL_BIN" "$H_A/.local/bin/setup-skills" --scope user --target "$H_A" --dry-run >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$LOG" ] &&
  ok "已安装的命令直接使用已安装数据，不联网" || bad "已安装的命令仍然联网或失败（退出码 $rc）"

: >"$LOG"
(cd "$FAKEBIN" && cat "$UP/setup-skills.sh" | with_home "$H_A" "$SHELL_BIN" -s -- --scope user --target "$H_A" --dry-run >/dev/null 2>&1)
grep -q 'config/agents.json' "$LOG" &&
  ok "管道执行的脚本不使用已安装数据" || bad "管道执行误用了已安装数据"

: >"$LOG"
with_home "$H_A" "$SHELL_BIN" "$H_A/.local/bin/setup-skills" --scope user --target "$H_A" --dry-run --branch feature-x >/dev/null 2>&1
grep -q '/feature-x/config/agents.json' "$LOG" &&
  ok "显式 --branch 时从该分支下载，不用已安装数据" || bad "--branch 被忽略"

# 上游出了新版：脚本与模板都变。从已安装的命令运行 --update，原件应留作备份。
cp "$H_A/.local/bin/setup-skills" "$FAKEBIN/old-setup-skills"
sed -i '$i # upstream v2' "$UP/setup-skills.sh"
printf '<!-- upstream v2 -->\n' >>"$UP/templates/entry-user.md"
with_home "$H_A" "$SHELL_BIN" "$H_A/.local/bin/setup-skills" --update >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && cmp -s "$H_A/.local/bin/setup-skills" "$UP/setup-skills.sh" &&
  cmp -s "$H_A/.local/bin/setup-skills.local.bak" "$FAKEBIN/old-setup-skills" &&
  ok "--update 替换脚本，原件备份为 .local.bak" || bad "--update 未正确替换脚本（退出码 $rc）"
cmp -s "$H_A/.local/share/agents-env/templates/entry-user.md" "$UP/templates/entry-user.md" &&
  ok "--update 同时更新数据" || bad "--update 未更新数据"

# 上游脚本语法错误：整次更新中止，已安装的内容一概不动。
rm -rf "$FAKEBIN/snap"
cp -R "$H_A/.local" "$FAKEBIN/snap"
sed -i '$i if' "$UP/setup-instructions.sh"
printf '<!-- upstream v3 -->\n' >>"$UP/templates/entry-user.md"
with_home "$H_A" "$SHELL_BIN" "$H_A/.local/bin/setup-skills" --update >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && same_tree "$H_A/.local" "$FAKEBIN/snap" &&
  ok "上游脚本未通过校验时整体中止，不留半成品" || bad "校验失败后仍有改动（退出码 $rc）"
cp "$WORKSPACE/setup-instructions.sh" "$UP/"
cp "$WORKSPACE/templates/entry-user.md" "$UP/templates/"

# 上游注册表不是合法 JSON：同样整体中止。
printf '{' >"$UP/config/agents.json"
with_home "$H_A" "$SHELL_BIN" "$H_A/.local/bin/setup-skills" --update >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && same_tree "$H_A/.local" "$FAKEBIN/snap" &&
  ok "上游注册表非法时整体中止" || bad "注册表非法时仍有改动（退出码 $rc）"

# 注册表声明的模板路径越出仓库（含 .. 段）：拒绝写入，不得把数据写到目录之外。
jq --arg p '../evil.md' '.agents |= with_entries(.value.instructions.template_override.user = $p)' "$REGISTRY" >"$UP/config/agents.json"
with_home "$H_A" "$SHELL_BIN" "$H_A/.local/bin/setup-skills" --update >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && same_tree "$H_A/.local" "$FAKEBIN/snap" && [ ! -e "$H_A/.local/share/evil.md" ] &&
  ok "注册表中的越界路径被拒绝" || bad "越界路径未被拒绝（退出码 $rc）"
cp "$REGISTRY" "$UP/config/agents.json"

# --dry-run 只展示计划，不写任何东西。
printf '<!-- upstream v4 -->\n' >>"$UP/templates/entry-user.md"
rm -rf "$FAKEBIN/snap"
cp -R "$H_A/.local" "$FAKEBIN/snap"
with_home "$H_A" "$SHELL_BIN" "$H_A/.local/bin/setup-skills" --update --dry-run >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && same_tree "$H_A/.local" "$FAKEBIN/snap" &&
  ok "--update --dry-run 不写入" || bad "--dry-run 仍然写入了文件"
cp "$WORKSPACE/templates/entry-user.md" "$UP/templates/"

# 没有任何已安装命令时 --update 不新增，直接失败。
H_N="$(mktemp -d /tmp/instN.XXXXXX)"
with_home "$H_N" "$SHELL_BIN" "$SCRIPT_UNDER_TEST" --update >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$H_N/.local" ] &&
  ok "未安装时 --update 失败且不写入" || bad "未安装时 --update 未拦截（退出码 $rc）"

# 只更新已安装的命令：缺失的那个不会被补回来。
H_P="$(mktemp -d /tmp/instP.XXXXXX)"
pipe_install "$H_P" "$UP/setup-skills.sh" --install >/dev/null 2>&1
rm "$H_P/.local/bin/setup-instructions"
with_home "$H_P" "$SHELL_BIN" "$H_P/.local/bin/setup-skills" --update >/dev/null 2>&1
[ ! -e "$H_P/.local/bin/setup-instructions" ] && [ -x "$H_P/.local/bin/setup-skills" ] &&
  ok "--update 不补回缺失的命令" || bad "--update 补回了缺失的命令"

# 命令位置是软链：视为用户自行安排，不覆盖。
H_S="$(mktemp -d /tmp/instS.XXXXXX)"
pipe_install "$H_S" "$UP/setup-skills.sh" --install >/dev/null 2>&1
rm "$H_S/.local/bin/setup-instructions"
ln -s "$FAKEBIN/elsewhere" "$H_S/.local/bin/setup-instructions"
with_home "$H_S" "$SHELL_BIN" "$H_S/.local/bin/setup-skills" --update >/dev/null 2>&1
[ -L "$H_S/.local/bin/setup-instructions" ] &&
  [ "$(readlink "$H_S/.local/bin/setup-instructions")" = "$FAKEBIN/elsewhere" ] &&
  ok "命令位置是软链时不覆盖" || bad "软链命令被覆盖"

# 与范围、来源相关的选项在下载之前拦截，不产生任何请求或文件。
: >"$LOG"
H_C="$(mktemp -d /tmp/instC.XXXXXX)"
with_home "$H_C" "$SHELL_BIN" "$SCRIPT_UNDER_TEST" --install --scope user >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ ! -s "$LOG" ] && [ ! -e "$H_C/.local" ] &&
  ok "--install 与 --scope 冲突时在下载前拦截" || bad "选项冲突未被拦截（退出码 $rc）"
with_home "$H_C" "$SHELL_BIN" "$SCRIPT_UNDER_TEST" --update --force >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ ! -s "$LOG" ] &&
  ok "--update 与 --force 冲突时在下载前拦截" || bad "--update 与 --force 未被拦截（退出码 $rc）"

head_ "悬空软链清理（prune 子命令）"
# 夹具：Agent 的逐项软链与共享库各一个有效 Skill，再加上几种形态的软链与目录，断言只看这些形态。
PH="$(fresh_home)"
mkdir -p "$PH/${SKILLS_ROOT_USER}/keep-skill"
printf 'x\n' >"$PH/${SKILLS_ROOT_USER}/keep-skill/SKILL.md"
run --scope user --source "$WORKSPACE" --target "$PH" --force >/dev/null 2>&1
[ -L "$PH/${LINK_EACH_USER}/keep-skill" ] ||
  { printf '前提不满足：初次运行未建立逐项软链。\n' >&2; exit 1; }
mkdir -p "$PH/outside-real"
ln -s /nonexistent/foreign-dead "$PH/${LINK_EACH_USER}/foreign-dead"
ln -s "$PH/outside-real" "$PH/${LINK_EACH_USER}/foreign-live"
ln -s /nonexistent/store-dangle "$PH/${SKILLS_ROOT_USER}/store-dangle"
mkdir -p "$PH/${LINK_EACH_USER}/vendor-own"
printf 'v\n' >"$PH/${LINK_EACH_USER}/vendor-own/SKILL.md"
ln -s /nonexistent/nested "$PH/${LINK_EACH_USER}/vendor-own/nested-dead"

# 常规运行不清理悬空软链（库外的软链属于用户自己的安排）。
run --scope user --source "$WORKSPACE" --target "$PH" --force >/dev/null 2>&1
[ -L "$PH/${LINK_EACH_USER}/foreign-dead" ] && [ -L "$PH/${SKILLS_ROOT_USER}/store-dangle" ] &&
  ok "常规运行时悬空软链保留" || bad "常规运行时悬空软链被清理"

before_p="$(find "$PH" | sort | md5sum)"
out_p="$(run prune --scope user --source "$WORKSPACE" --target "$PH" --dry-run 2>&1)"
[ "$before_p" = "$(find "$PH" | sort | md5sum)" ] && ok "prune --dry-run 不清理" || bad "prune --dry-run 清理了软链"
printf '%s' "$out_p" | grep -q 'foreign-dead' && ok "计划列出悬空软链" || bad "计划未列出悬空软链"
printf '%s' "$out_p" | grep -q 'foreign-live' && bad "计划列出了有效的库外软链" || ok "计划不列出有效的软链"

run prune --scope user --source "$WORKSPACE" --target "$PH" --yes >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ ! -L "$PH/${LINK_EACH_USER}/foreign-dead" ] && [ ! -L "$PH/${SKILLS_ROOT_USER}/store-dangle" ] &&
  ok "prune 清理 Agent 目录与共享库里的悬空软链（库外与库内各一）" || bad "悬空软链未被清理（退出码 $rc）"
[ -L "$PH/${LINK_EACH_USER}/foreign-live" ] && [ -d "$PH/outside-real" ] &&
  ok "库外有效的软链保留" || bad "库外有效的软链被误删"
[ -L "$PH/${LINK_EACH_USER}/keep-skill" ] && [ -f "$PH/${LINK_EACH_USER}/keep-skill/SKILL.md" ] &&
  ok "正常的 Skill 软链保留" || bad "正常的 Skill 软链被误删"
[ -d "$PH/${LINK_EACH_USER}/vendor-own" ] && [ -L "$PH/${LINK_EACH_USER}/vendor-own/nested-dead" ] &&
  ok "实体目录与其中的悬空软链都保留（不递归）" || bad "清理递归进了实体目录"

before_p="$(find "$PH" | sort | md5sum)"
run prune --scope user --source "$WORKSPACE" --target "$PH" --yes >/dev/null 2>&1
[ "$before_p" = "$(find "$PH" | sort | md5sum)" ] && ok "重复 prune 无变化" || bad "重复 prune 仍有变化"

# prune 只清理，不建链：共享库里未建链的 Skill 不会因此被补上软链。
PN="$(fresh_home)"
mkdir -p "$PN/${SKILLS_ROOT_USER}/lonely-skill"
printf 'x\n' >"$PN/${SKILLS_ROOT_USER}/lonely-skill/SKILL.md"
run prune --scope user --source "$WORKSPACE" --target "$PN" --yes >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$PN/${LINK_EACH_USER}/lonely-skill" ] && [ ! -L "$PN/${LINK_EACH_USER}/lonely-skill" ] &&
  ok "prune 不建链" || bad "prune 建立了软链（退出码 $rc）"

# 无终端且未带 --yes：确认失败，什么都不删。
ln -s /nonexistent/again "$PH/${LINK_EACH_USER}/again"
run_no_tty prune --scope user --source "$WORKSPACE" --target "$PH" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ -L "$PH/${LINK_EACH_USER}/again" ] &&
  ok "无终端且未带 --yes 时非零退出且不删" || bad "确认失败后仍删除了软链（退出码 $rc）"

# 文件名含 | 的悬空软链：计划行以 | 分隔，这类条目跳过，不影响其它清理。
ln -s /nonexistent/odd "$PH/${SKILLS_ROOT_USER}/odd|name"
run prune --scope user --source "$WORKSPACE" --target "$PH" --yes >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ -L "$PH/${SKILLS_ROOT_USER}/odd|name" ] && [ ! -L "$PH/${LINK_EACH_USER}/again" ] &&
  ok "名称含 | 的条目跳过，其它悬空软链照常清理" || bad "含 | 的条目处理不当（退出码 $rc）"

# 整目录软链（project 声明 link-dir）本身悬空：prune 清掉，常规运行再重建为正确的相对软链。
PP="$(fresh_home)"
mkdir -p "$PP/${SKILLS_ROOT_PROJ}/some-skill" "$(dirname "$PP/${LINK_DIR_PROJ}")"
printf 'x\n' >"$PP/${SKILLS_ROOT_PROJ}/some-skill/SKILL.md"
ln -s /nonexistent/gone-dir "$PP/${LINK_DIR_PROJ}"
run --scope project --source "$WORKSPACE" --target "$PP" --yes >/dev/null 2>&1
[ -L "$PP/${LINK_DIR_PROJ}" ] && [ ! -e "$PP/${LINK_DIR_PROJ}" ] &&
  ok "常规运行时悬空的整目录软链保留" || bad "常规运行时整目录软链被改动"
run prune --scope project --source "$WORKSPACE" --target "$PP" --yes >/dev/null 2>&1
[ ! -L "$PP/${LINK_DIR_PROJ}" ] && ok "prune 清掉悬空的整目录软链" || bad "prune 未清掉悬空的整目录软链"
run --scope project --source "$WORKSPACE" --target "$PP" --yes >/dev/null 2>&1
want_pp="$(rel_prefix "$LINK_DIR_PROJ")${SKILLS_ROOT_PROJ}"
[ "$(readlink "$PP/${LINK_DIR_PROJ}")" = "$want_pp" ] &&
  ok "常规运行把整目录软链重建为正确的相对软链" || bad "整目录软链未重建（$(readlink "$PP/${LINK_DIR_PROJ}" 2>/dev/null)）"

# 先 prune 再获取：共享库里与来源 Skill 同名的悬空软链，清掉后获取才能落地。
PR="$(fresh_home)"
REPO_P="$(make_repo)"
mkdir -p "$PR/${SKILLS_ROOT_USER}"
ln -s /nonexistent/alpha-skill "$PR/${SKILLS_ROOT_USER}/alpha-skill"
run prune --scope user --source "$WORKSPACE" --target "$PR" --yes >/dev/null 2>&1
run --scope user --source "$WORKSPACE" --target "$PR" --repo "$REPO_P" --yes >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ -f "$PR/${SKILLS_ROOT_USER}/alpha-skill/SKILL.md" ] && [ ! -L "$PR/${SKILLS_ROOT_USER}/alpha-skill" ] &&
  ok "先 prune 清掉同名悬空软链，再获取即可落地" || bad "获取未能落地（退出码 $rc）"

# prune 不接受获取相关的选项：与 --repo 同用时在任何改动之前拦截。
PX="$(fresh_home)"
mkdir -p "$PX/${SKILLS_ROOT_USER}"
ln -s /nonexistent/refused "$PX/${SKILLS_ROOT_USER}/refused"
before_x="$(find "$PX" | sort | md5sum)"
run prune --scope user --source "$WORKSPACE" --target "$PX" --repo "$REPO_P" --yes >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ "$before_x" = "$(find "$PX" | sort | md5sum)" ] &&
  ok "prune 与 --repo 同用时在任何改动之前拦截" || bad "prune 与 --repo 同用未被拦截（退出码 $rc）"

# prune 与 --install 同用：下载前拦截，不产生任何请求与安装。
H_X="$(mktemp -d /tmp/instX.XXXXXX)"
: >"$LOG"
with_home "$H_X" "$SHELL_BIN" "$SCRIPT_UNDER_TEST" prune --install >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ ! -s "$LOG" ] && [ ! -e "$H_X/.local" ] &&
  ok "prune 与 --install 同用时在下载前拦截" || bad "prune 与 --install 同用未被拦截（退出码 $rc）"

head_ "入口：零参数与 help 只显示帮助，交互向导只由 interactive 进入"
PE="$(fresh_home)"
mkdir -p "$PE/${SKILLS_ROOT_USER}/keep-skill"
printf 'x\n' >"$PE/${SKILLS_ROOT_USER}/keep-skill/SKILL.md"
before_e="$(find "$PE" | sort | md5sum)"

# 零参数只显示帮助：退出 0，不进向导、不做任何改动。
run_no_tty >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ "$before_e" = "$(find "$PE" | sort | md5sum)" ] &&
  ok "零参数只显示帮助，退出 0 且无副作用" || bad "零参数未按帮助处理（退出码 $rc）"

help_ok=true
for form in help -h --help; do
  run "$form" >/dev/null 2>&1 || help_ok=false
done
[ "$help_ok" = true ] && [ "$before_e" = "$(find "$PE" | sort | md5sum)" ] &&
  ok "help、-h、--help 退出 0 且无副作用" || bad "help 系列入口未按帮助处理"

# 交互向导只能由 interactive 进入：无终端时在读取输入之前失败，不产生副作用。
iv_ok=true
for form in interactive -i --interactive; do
  run_no_tty "$form" >/dev/null 2>&1 && iv_ok=false
done
[ "$iv_ok" = true ] && [ "$before_e" = "$(find "$PE" | sort | md5sum)" ] &&
  ok "无终端时 interactive、-i 与 --interactive 非零退出且无副作用" || bad "无终端时交互入口未被拒绝"

# interactive 不接受其它参数。
run interactive --scope user --target "$PE" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ "$before_e" = "$(find "$PE" | sort | md5sum)" ] &&
  ok "interactive 与其它参数同用时拒绝且无副作用" || bad "interactive 未拒绝其它参数（退出码 $rc）"

printf '\n通过 %s，失败 %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

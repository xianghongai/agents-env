#!/usr/bin/env bash
# 仅在一次性容器内执行。覆盖 setup-skills.sh 的核心能力：
# 来源识别（单 Skill / 多 Skill、--path 起点、--skill 筛选）、增量获取与库外备份、两种软链形态与整目录的回退、
# none 的清理、纯机制（虚构注册表）。
#
# 用法：TEST_SHELL=bash|zsh bash test/skills-tests.sh
set -uo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
SCRIPT_UNDER_TEST="${WORKSPACE}/setup-skills.sh"
REGISTRY="${WORKSPACE}/config/agents.json"
SHELL_BIN="${TEST_SHELL:-bash}"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  [ok]   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1"; }
head_() { printf '\n== %s (%s) ==\n' "$1" "$SHELL_BIN"; }
run() { "$SHELL_BIN" "$SCRIPT_UNDER_TEST" "$@"; }

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
run --scope user --source "$WORKSPACE" --target "$H" --repo "$REPO" >/dev/null 2>&1
grep -q 'local edit' "$H/${SKILLS_ROOT_USER}/alpha-skill/SKILL.md" && ok "默认不覆盖同名" || bad "默认覆盖了同名"
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

printf '\n通过 %s，失败 %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

# CLAUDE.md

请先阅读 @AGENTS.md 了解当前目录的协作约束，并读取 `package.json` 确认可用命令与实际配置。

本项目的 Skill 通过 `.claude/skills` 符号链接指向 `.agents/skills/`，正常情况下会被自动发现。若该符号链接在当前环境不可用（例如 Windows 未启用 `core.symlinks`），直接读取 `.agents/skills/<name>/SKILL.md`。

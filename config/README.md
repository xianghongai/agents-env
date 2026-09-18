# 注册表维护指南

`config/` 下两个文件构成脚本唯一的厂商知识来源：

| 文件 | 职责 |
| --- | --- |
| `agents.json` | 注册表本体，声明各 Agent 的落点 |
| `agents.schema.json` | 数据协议，约束注册表的形状 |

改动注册表后用 JSON Schema 校验，再跑容器测试：

```bash
npx -p ajv-cli@5 -p ajv-formats@2 ajv validate --spec=draft2020 -c ajv-formats \
  -s config/agents.schema.json -d config/agents.json

docker compose -f test/compose.yaml run --rm test
```

测试**不依赖清单内容**：断言按 scope、mode、路径深度从注册表现场推导，增删 Agent 不需要改 `test/`。

---

## 两层结构

注册表分两层：

```jsonc
{
  "shared": {
    /* 基准层：跨 Agent 的公共投放点 */
  },
  "agents": {
    /* Agent 层：各家自己的落点，以标识符为键 */
  },
}
```

## 基准层 `shared`

```jsonc
{
  "instructions_root": {
    "references": { "docs": "https://agents.md" },
    "user": ".agents/AGENTS.md",
    "project": "AGENTS.md",
  },
  "skills_root": {
    "references": { "docs": "https://agentskills.io" },
    "user": ".agents/skills",
    "project": ".agents/skills",
  },
  "mcp_root": {
    "references": { "docs": "https://modelcontextprotocol.io/" },
    "user": ".agents/mcp.json",
    "project": ".agents/mcp.json",
  },
}
```

这里只放**已被多家 Agent 原生读取的公共约定**：`.agents/AGENTS.md` 是各入口文件共同指向的规则正本，`.agents/skills/` 是软链的共同目标，`.agents/mcp.json` 已有 Agent 直接读取。判据是「跨 Agent 公用」，不是「看起来是全局配置」。

将来的 Hooks / Commands / Plugins 目前没有这种跨厂商约定，各家格式与落点都不同，应当加在 Agent 层、而不是这里。只有当某种机制真的出现了 `.agents/*` 级别的公共投放点，才在 `shared` 下新增一项。

各项均支持 `references` 声明对应的社区公共规范，脚本不读取。

## Agent 层 `agents`

以 Agent 标识符（kebab-case）为键，新增 Agent 只加一条记录：

```json
"some-agent": {
  "name": "Some Agent",
  "vendor": "Someone",
  "references": {
    "docs": "https://example.com/docs",
    "repository": "https://github.com/someone/some-agent"
  },
  "instructions": {
    "scope": {
      "user": ".some/AGENTS.md",
      "project": "SOME.md"
    }
  },
  "skills": {
    "scope": {
      "user": {
        "path": ".some/skills",
        "mode": "link-each"
      },
      "project": {
        "path": ".some/skills",
        "mode": "link-dir"
      }
    }
  },
  "mcp": {
    "scope": {
      "user": {
        "path": ".some/mcp.json",
        "format": "json",
        "key": "mcpServers"
      },
      "project": {
        "path": null,
        "format": null,
        "key": null
      }
    }
  }
}
```

- 键即标识符，用于命令行过滤（`--agent <id>`）。对象内不再重复声明 `id`：编辑器折叠时键名可见，脚本也可直接 `.agents[$id]` 索引。kebab-case 由 schema 的 `propertyNames.pattern` 约束。
- **路径字段统一三种取值**（`instructions.scope.<scope>`、`skills.scope.<scope>.path`、`mcp.scope.<scope>.path` 同一套）：

  | 取值         | 含义                                                   | 脚本动作                       |
  | ------------ | ------------------------------------------------------ | ------------------------------ |
  | 真实相对路径 | 该 Agent 在此 Scope 的私有落点                         | 按 `mode` 投放                 |
  | `"standard"` | 原生读取基准层的标准位置（`shared.*`），不需要单独投放 | 不动作，但在计划中显示一行说明 |
  | `null`       | 未知。厂商没提供、或本项目尚未查到出处，两者不做区分   | 不动作                         |

  真实路径必然含 `.` 或 `/`，schema 用 `pattern` 约束，因此不会与保留词 `standard` 歧义。区分 `standard` 与 `null` 的意义在于：前者是「查证过，确实不需要」，后者是「还没查」，维护者不必反复重查同一条。

- `skills.scope.<scope>.path`：该 Agent 的私有 Skills 目录。`mode` 为 `none` 时仍建议登记，它是清理冗余软链的扫描点。
- `skills.scope.<scope>.mode`：见上表。两个 Scope 各自声明，可以不同。
- `mcp.scope.<scope>`：MCP 配置的落点，声明 `path`、`format`、`key` 三项。`key` 是承载 Server 定义的键路径（点号分隔，如 `mcpServers` 或 `mcp.servers`）；`format` 为 `dir` 时该路径是目录、每个文件描述一个 Server，`key` 为 `null`。`path` 取值见上表，仅界面管理、无文件式配置的同样记 `null`。
- `references`：相关资料地址，是一个**按用途分键的对象**，各键取值为单条 URL 或 URL 数组：

  ```jsonc
  "references": {
    "docs": "https://example.com/docs",              // 约定键：官方文档 / 公共规范
    "repository": "https://github.com/someone/x",    // 约定键：源码仓库
    "changelog": "https://example.com/changelog"     // 协议未声明的键，可自由添加
  }
  ```

  只有 `docs` 与 `repository` 在 schema 中声明并带描述，**其余键无需先改 schema 即可添加**。

  `references` **不参与任何脚本逻辑**，纯粹供维护者查证出处，所以协议在这里刻意宽松：整个对象可以为空 `{}`，单个键也可以为空（`""`、`[]` 或 `null`），不必为了通过校验而编造链接。唯一的限制是非空字符串得是 URL，避免这里变成随手记备注的地方。

  Agent 级放厂商的帮助文档首页，各子模块放对应的功能规范或指引。

入口正文与通用模板不同的 Agent，在 `templates/fragments/` 放整份覆盖或仅 frontmatter 的片段，并在注册表中用 `template_override` / `template_frontmatter` 指明路径，脚本据此精确取用，不做文件探测。片段本身怎么写见 [入口模板维护指南](../templates/README.md)。

> **MCP 目前只有数据协议，脚本尚未实现。** 投放动作的语义（合并进各家配置、还是只维护共享文件）待实现时再定，因此 `mcp` 节点暂不含 `mode`。

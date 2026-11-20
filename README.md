# Local OpenAI API Manager

适用于 Windows x64 的本地 OpenAI API Key 管理器。它为 Codex 提供固定的 Responses 接入地址，让你在一个窗口管理多个 API 项目的 Key、切换当前 Key，以及选择默认模型。

## 主要功能

- **请求过滤**：在本地过滤 Codex 身份头和追踪元数据，保留任务正文、工具定义及工具结果，再转发到 OpenAI API。
- **集中管理 Key**：添加、替换和手动切换 API Key。Key 使用 Windows DPAPI 加密，绑定当前 Windows 用户和电脑。
- **接入 Codex**：通过 CC Switch 的直连模式导入本地供应商；已有供应商时可同步模型目录。Codex 使用本地令牌连接，真实 API Key 由管理器保管。
- **选择模型**：用当前 Key 获取模型列表，支持关键词过滤、方向键选择和手动输入。
- **查看请求状态**：在控制台查看请求来源（Desktop、CLI 或 Unknown）、实际调用的模型、Key 名称、HTTP 状态和耗时。

## 快速开始

1. 从仓库的 **Releases** 下载 `Local-OpenAI-API-Manager-win64.zip` 并完整解压。免安装包内置 Node.js，使用 Windows 自带的 PowerShell 5.1。
2. 双击 `API-Manager.cmd`，按 **1** 添加自己的 OpenAI API Platform Key，按 **M** 搜索并选择模型。
3. 在 CC Switch 的 **Codex** 页面选择**直连模式**。回到管理器按 **I**，确认导入并切换供应商；已有本地供应商时，先选中它再按 **I** 同步。
4. 保持管理器运行，重开 Codex 后发起请求。按 **Q** 停止服务；若直接关窗口后端口仍被占用，运行 `Stop-API-Manager.cmd`。

默认供应商地址为 `http://127.0.0.1:8787/v1`。手动配置、菜单说明及排查入口见 [CC Switch 接入指南](docs/CCSWITCH.md)。

## 技术实现

```text
CC Switch（直连模式）
    │ 写入 Codex 供应商配置
    ▼
Codex App / CLI（标准 Responses 请求）
    │
    │ HTTP: http://127.0.0.1:8787/v1/responses
    ▼
本机 proxy.mjs
    ├─ 验证本地令牌
    ├─ 过滤 Codex 身份头、追踪元数据
    ├─ 保留任务正文、工具定义和工具结果
    └─ 换上当前选中的真实 OpenAI API Key
    │
    │ HTTPS: https://api.openai.com/v1/responses
    ▼
OpenAI 官方 API
    │
    └─ 响应经同一本地代理返回 Codex（支持 SSE 流式响应）
```

| 组件 | 实现 |
| --- | --- |
| **控制台与凭据** · [Manage-Proxy.ps1](Manage-Proxy.ps1) / [ProxyManager.psm1](ProxyManager.psm1) | PowerShell 5.1 提供菜单并启动代理。Key 由 Windows DPAPI 加密后保存在 `.local/vault.json`。Codex 使用固定的本地连接令牌，控制台使用独立的管理令牌切换上游 Key；已经开始的请求继续使用原来的 Key。 |
| **请求转发** · [proxy.mjs](proxy.mjs) | Node.js 代理只监听本机回环地址，支持模型列表和 Responses 接口。校验本地令牌后，默认过滤模式会**在 [`cleanHeaders()`](proxy.mjs#L73) 中过滤请求头**：移除 `originator`、`version` 等身份头，替换原始 `User-Agent`，再换入当前 API Key 向 OpenAI 发出 HTTPS 请求。流式响应（SSE）边接收边传回 Codex。 |
| **配置与模型目录** · [ccswitch-setup.mjs](ccswitch-setup.mjs) / [model-catalog.standard.json](model-catalog.standard.json) | CC Switch 的直连模式只负责配置供应商；请求从 Codex 直接发往本地代理。同步时，管理器先核对生效的供应商，再备份 TOML 并补写 `model_catalog_json`，让目录内的模型使用标准 Responses 格式。菜单 **M** 的模型列表则来自当前 Key 的 `/v1/models`。 |
| **运行记录** · [proxy.mjs](proxy.mjs) | 代理在本地将请求来源归类为 Desktop、CLI 或 Unknown。控制台通过管理接口读取最近请求；`logs/` 中的 JSONL 审计记录保存分类、模型、状态码与耗时等信息，不保存真实 Key、客户端身份头的原始值或请求与响应正文。 |

## 开发和打包

从源码运行需要 Windows x64 和 Node.js 24 或更新版本。克隆后运行 `.\API-Manager.cmd`。构建并验证发布包需用 Python 3.11 或更新版本：

```powershell
node --test tests/test-proxy.mjs tests/test-manager.mjs
python scripts/build-win64.py
python scripts/verify-win64-package.py
```

打包脚本下载并校验固定版本的官方 Node.js x64 运行时，生成 `dist/Local-OpenAI-API-Manager-win64.zip`。源码仓库不包含运行时、发布 ZIP、`.local/` 或 `logs/`。测试使用本地模拟上游，无需真实 Key。

## 使用范围与许可

需要有权调用相应模型的 OpenAI API 项目。用量和计费以 API Platform 为准；模型目录不授予访问权限，本工具也不会改变订阅额度的适用范围。

项目源码采用 [Apache-2.0](LICENSE)。随附模型目录和 TOML 解析库的许可、出处见 [第三方声明](docs/THIRD-PARTY.md)。本项目独立维护，与 OpenAI 或 CC Switch 无隶属关系。

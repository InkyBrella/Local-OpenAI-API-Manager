# CC Switch 接入指南

CC Switch 负责选择供应商，API Manager 保管你的 OpenAI API Platform Key。使用 CC Switch 的 Codex **直连模式**时，请求链路是：

```text
Codex App / CLI → http://127.0.0.1:8787/v1/responses → OpenAI API
```

供应商表单中填写 `http://127.0.0.1:8787/v1`，这是 base URL。Codex 会追加 `/responses`。CC Switch 自己的监听端口不需要改为 8787；如果同时启用它的路由服务，两套服务必须使用不同端口。自动接入功能按直连模式核对配置。

## 自动接入

1. 在管理器按 **1** 添加自己的 API Key，并在 CC Switch 的 Codex 页面选择**直连**。
2. 已有本地供应商卡时，先在 CC Switch 选中它，再在管理器按 **I**。首次使用时，按 **I** 打开导入框，确认导入并立即切换。供应商里保存的是本地令牌。
3. **I** 会核对当前供应商地址、协议和本地令牌。匹配后，管理器在原 TOML 旁创建备份，再补写模型目录。用 **D** 只读检查结果；然后完全退出再重开 Codex。

如果 CC Switch 重新生成配置时覆盖了模型目录，先确认本地供应商已生效，再按 **I** 同步。也可以在该供应商的 TOML 编辑区保留 `model_catalog_json`，让支持该字段的 CC Switch 版本在切换回来时保留目录设置。

## 手动接入

在管理器按 **C** 查看实际地址、本地令牌和导出文件。打开 CC Switch 的 **Codex → 添加供应商 → 自定义**，填写：

| 字段 | 填写内容 |
|---|---|
| 供应商名称 | 自定，例如 Local OpenAI Manager |
| API Key | **C** 显示的本地令牌 |
| API 请求地址 | **C** 显示的 base URL，默认 `http://127.0.0.1:8787/v1` |
| 完整地址开关（如有） | 关闭 |
| 上游格式（如有） | 原生 OpenAI Responses |
| 默认模型 | API 项目实际可用且支持 Responses 的模型 |

将 `.local/connection/ccswitch-config.toml` 的字段合并到该供应商的 TOML 编辑区。`model_catalog_json` 位于**顶层、首个 `[表名]` 之前**。将供应商字段合并到已有表，避免重复建表；保留其他现有设置。需要手动录入 auth JSON 时，参照同目录下的 `ccswitch-auth.json`。

```toml
model_provider = "custom"
model = "你的模型 ID"
model_catalog_json = "C:/你的安装目录/model-catalog.standard.json"

[model_providers.custom]
name = "Local OpenAI Manager"
base_url = "http://127.0.0.1:8787/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
experimental_bearer_token = "管理器导出的本地令牌"
```

保存、选中本地供应商，按 **D** 检查，然后完全重启 Codex。移动安装目录或更换安装副本后，需要更新目录路径及对应的本地连接信息。

## 排查与停止

桌面 App 出现 Responses Lite 的 HTTP 422 时，见 [桌面 App 排查](TROUBLESHOOTING.md)。


保持管理窗口运行，在新对话发送一条简短消息。窗口会显示模型、Key 名称、HTTP 状态和耗时，日志在 `logs/`。本地 `401` 通常表示本地令牌不匹配；`503 no_active_api_key_select_one_in_manager` 表示尚未选择 Key。若日志有上游请求 ID，则可用它核对上游错误与用量。

按 **Q** 退出。若关闭窗口后仍占端口，双击 `Stop-API-Manager.cmd`。若修改端口，按 **C** 重新获取连接地址。返回 200 仅表示请求获得响应，可用模型和实际计费仍以 API 项目为准。

## 临时 CLI 入口

已有 Codex CLI 时，可以在安装目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-Codex.ps1 -Model <可用模型ID>
```

把 `<可用模型ID>` 连同尖括号一起替换为实际模型 ID。此方式为本次 CLI 会话创建独立的代理与临时令牌，退出时停止。与管理器同时运行时需指定不同的 `-Port`。配置示例见 [provider.example.toml](../examples/provider.example.toml)。

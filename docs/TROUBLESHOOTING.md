# 桌面 App 排查

## CLI 可以请求，桌面 App 返回 422

`responses_lite_tool_declarations_not_supported_use_standard_catalog` 表示代理在本地收到无法安全转换的 Lite 工具声明，已结束该请求。CLI 如果是用 `Start-Codex.ps1` 打开的，会直接为本次进程传入目录配置；App 则从自己加载的配置读取。不要因为 CLI 成功而跳过以下检查：

1. 按 **D** 看管理器检查的 `config.toml` 路径和状态。在 CC Switch 选中本地供应商；缺少目录或指向旧安装时按 **I**，再按 **D**。
2. 在 Codex App 核对它实际加载的配置文件与 **D** 显示的是同一份。使用了自定义 `CODEX_HOME`、CC Switch 自定义目录或 Codex profile 时，也检查相应目录和 profile 内的 `model_catalog_json`。
3. 核对 App 实际选择的模型在 `model-catalog.standard.json` 里设为 `"use_responses_lite": false`。**D** 检查的是 TOML 的默认模型；会话里选中的模型可能不同。
4. 完全退出并重开 Codex App，再新建对话测试。保留原会话作为对照。如果新会话仍报错，先记录 **D** 的结果、App 选择的模型和新的日志错误码。不要把含令牌的完整配置发给别人。

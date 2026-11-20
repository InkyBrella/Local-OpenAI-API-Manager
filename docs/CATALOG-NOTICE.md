# Model catalog provenance

`model-catalog.standard.json` is derived from [the OpenAI Codex public model catalog](https://github.com/openai/codex/blob/6c0cee502d215e5df2dd9a303cf2e252229c9e12/codex-rs/models-manager/models.json) at commit `6c0cee502d215e5df2dd9a303cf2e252229c9e12`, retrieved on 2026-11-20. See the upstream [Apache License 2.0](LICENSE.codex.txt) and [NOTICE](NOTICE.codex.txt).

Changes: `use_responses_lite` and `supports_reasoning_effort_updates` are set to `false` for each model so Codex sends standard Responses requests. All other model fields are retained from that snapshot. This file supplies model metadata and instructions; it does not grant account entitlements or API access.

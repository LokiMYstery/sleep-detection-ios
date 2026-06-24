# Sleep Detection iOS POC

这是一个用于验证睡眠检测与助眠音频自动停止能力的 iOS / watchOS POC。当前主链路是统一降级判定: 根据本次 session 实际可用的 iPhone 与 Apple Watch 信号生成 `UnifiedSleepDecision`，并在 `state == .confirmed` 时作为产品动作触发依据。

## 当前集成入口

成熟 App 集成请先看:

[docs/README_睡眠检测统一降级链路集成.md](docs/README_睡眠检测统一降级链路集成.md)

该文档说明了功能目标、`Session` / `FeatureWindow` / `UnifiedSleepDecision` 等基础概念、Watch App 依赖、统一降级链路实现、产品动作接入、调试边界和离线评估口径。

## 文档说明

`docs/旧版_*` 文件是早期 POC 路线设计、调研和评估文档，保留用于历史参考，不作为当前成熟 App 集成 contract。

当前代码中的 iOS UI、Watch UI、`unified.json`、`events.jsonl` 主要服务 POC 调试、回放和验证；正式产品接入时应按业务架构选择性实现。

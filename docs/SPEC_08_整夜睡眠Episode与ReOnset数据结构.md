# SPEC 08: Action-Ready 优先的整夜睡眠 Episode 与 Re-Onset 数据结构

> **状态**：数据结构 / tracker / 持久化已实现；动作执行集成仍在进行
> **前置文档**：SPEC 06 评估框架、SPEC 07 路线 F
> **定位**：把“什么时候可以自动关音乐”作为主目标，把 `onsetEstimate` 降级为离线分析与个性化辅助字段

---

## 1. 目标

当前产品动作是：**在用户已经睡着后自动关掉音乐**。  
这意味着线上真正要优化的时间不是“事后回填的入睡起点”，而是“系统在当下什么时候终于可以安全动作”。

因此新数据层需要同时满足三件事：

1. 把 **`actionReadyAt` / `confirmedAt`** 作为主时间，直接服务自动关音乐。
2. 保留 **`onsetEstimate`**，但仅用于离线误差分析和个性化调参。
3. 记录整夜的 **wake / re-onset**，用于学习 reset、re-arm、假阳性和 stale anchor 问题。

---

## 2. 设计原则

### 2.1 主目标改为 Action-Ready

- 主指标从 `primaryOnset` 调整为 `primaryActionReadyAt`。
- **产品语义上**，线上自动动作应依赖 `actionReadyAt`，不依赖 `onsetEstimate`。
- **当前代码状态**：`SleepTimeline` 已按此语义记录 `actionReadyAt`；但 App 内真正自动关音乐仍保留 Route E-only 运行时逻辑，尚未完全切换到 Timeline 驱动。

### 2.2 onsetEstimate 退居辅助

- `onsetEstimate` 仍然要保留。
- 但它只用于解释：
  - 为什么确认晚了
  - 是否回填过早
  - 个体化 offset 应该怎么学

### 2.3 Re-Onset 保留，但默认不驱动第二次动作

- 一旦音乐已经关闭，后续 re-onset 默认不触发新的 stop 行为。
- 但后续 episode 仍要保存，供离线训练使用。

### 2.4 RoutePrediction 不再承担主评估

- `RoutePrediction` 继续作为 UI 的“当前状态视图”。
- 真正用于产品决策和评估的是 `SleepTimeline`。

### 2.5 当前实现边界

- `SleepTimeline / SleepEpisode / RouteEpisodeEvidence / SleepActionDecision` 已在代码中落地。
- `SleepTimelineTracker` 已在 session start + 每个 processed window 上同步，并持久化到 `timeline.json`。
- 当前 tracker 主要由 Route D 和 Route E 的 `candidateAt / actionReadyAt / confirmedAt` 驱动；其它路线默认只保留诊断价值。
- `actionStatus / actionTakenAt / actionDecisions` 结构已预留，但还没有完整接到统一的 stop-music 执行链路。

---

## 3. 新增核心结构

### 3.1 Session 级结果

```swift
struct SleepTimeline {
    var primaryEpisodeIndex: Int?
    var primaryActionReadyAt: Date?
    var primaryOnsetEstimate: Date?
    var actionTakenAt: Date?
    var actionStatus: SleepActionStatus
    var latestNightState: NightState
    var episodes: [SleepEpisode]
    var actionDecisions: [SleepActionDecision]
    var lastUpdated: Date
}
```

字段语义：

- `primaryEpisodeIndex`：第一次被系统认定为“可动作”的 episode。
- `primaryActionReadyAt`：主产品时间，表示系统何时可以安全关音乐。
- `primaryOnsetEstimate`：该 primary episode 的入睡起点估计，仅作辅助分析。
- `actionTakenAt`：音乐真正被关掉的时间。
- `actionStatus`：当前整夜动作状态，如 `notTriggered / triggered / suppressed / failed`。
- `episodes`：整夜所有 sleep episode。
- `actionDecisions`：动作审计日志。

### 3.2 Episode 级结构

```swift
struct SleepEpisode {
    var episodeIndex: Int
    var kind: EpisodeKind      // primary / reOnset
    var candidateAt: Date?
    var actionReadyAt: Date?
    var onsetEstimate: Date?
    var wakeDetectedAt: Date?
    var endedAt: Date?
    var state: EpisodeState    // monitoring / candidate / actionReady / ended / rejected
    var actionEligibility: ActionEligibility
    var routeEvidence: [RouteEpisodeEvidence]
}
```

字段语义：

- `candidateAt`：该 episode 第一次进入候选态的时间。
- `actionReadyAt`：该 episode 第一次达到“可以自动关音乐”的时间。
- `onsetEstimate`：该 episode 的入睡起点估计。
- `wakeDetectedAt`：该 episode 之后被判定为醒来的时间。
- `endedAt`：该 episode 生命周期结束时间。
- `actionEligibility`：
  - `eligible`：可以驱动自动动作
  - `alreadyHandled`：动作已经执行过，仅保留诊断价值
  - `ineligible`：证据存在，但不允许直接驱动动作

### 3.3 路线证据结构

```swift
struct RouteEpisodeEvidence {
    var routeId: RouteId
    var candidateAt: Date?
    var actionReadyAt: Date?
    var onsetEstimate: Date?
    var confidence: SleepConfidence
    var confirmType: String?
    var evidenceSummary: String
    var isBackfilled: Bool
    var supportsImmediateAction: Bool
    var isLatched: Bool
}
```

要求：

- 每条路线都必须分别记录 `actionReadyAt` 和 `onsetEstimate`。
- `supportsImmediateAction == false` 时，路线结果只能用于辅助聚合或离线诊断，不能单独触发 stop music。
- 如果路线曾确认过，但后续最新状态被覆盖，`isLatched` 仍应允许保留这次历史确认。
- 当前 tracker 中：
  - Route D 读取 `prediction.supportsImmediateAction`
  - Route E 默认视为 `supportsImmediateAction = true`
  - 其它路线默认 `supportsImmediateAction = false`

### 3.4 动作审计结构

```swift
struct SleepActionDecision {
    var episodeIndex: Int
    var action: SleepAction      // stopMusic
    var decidedAt: Date
    var executedAt: Date?
    var result: SleepActionResult // executed / suppressed / skipped / failed
    var reason: String
}
```

这层结构专门回答：

- 系统什么时候认为可以关音乐
- 实际有没有关
- 为什么没关 / 没立即关

说明：

- 该结构已定义并可持久化。
- 当前版本尚未把全部 runtime 动作结果持续写回到 `SleepTimeline`，因此它现在更偏向“统一动作审计接口预留”。

---

## 4. 生命周期规则

### 4.1 Episode 打开条件

- 只要当前任一路线 prediction 暴露出 `candidateAt` 或 `actionReadyAt / confirmedAt`，就视为存在 active evidence。
- 若当前没有 open episode，则创建新 episode：
  - 第一段记为 `kind = primary`
  - 后续再次出现的段记为 `kind = reOnset`
- 新 episode 的 `candidateAt / actionReadyAt / onsetEstimate` 取 active evidence 的最早/最优组合。

### 4.2 Primary Episode 元数据

- 整夜第一个达到 `actionReadyAt` 且 `actionEligibility == .eligible` 的 episode，写入：
  - `primaryEpisodeIndex`
  - `primaryActionReadyAt`
  - `primaryOnsetEstimate`
- 一旦写入，不因后续 wake / unlock / pickup 被覆盖。

### 4.3 Episode 合并规则

- 当 open episode 持续存在时，新的 route evidence 按 `routeId` 合并。
- 合并时保留：
  - 最早的 `candidateAt`
  - 最早的 `actionReadyAt`
  - 优先来自可动作路线的 `onsetEstimate`
  - `supportsImmediateAction / isLatched` 的 OR 语义
- 如果整夜动作尚未触发，只要 merged evidence 中有任一路线支持 immediate action，则该 episode 为 `.eligible`。

### 4.4 关闭 / Wake / Reject

- 当 open episode 的 active evidence 全部消失时，tracker 关闭该 episode。
- 若该 episode 已有 `actionReadyAt`：
  - 写入 `wakeDetectedAt`
  - 写入 `endedAt`
  - `state = .ended`
- 若该 episode 只有 candidate、没有 action-ready：
  - 写入 `endedAt`
  - `state = .rejected`

### 4.5 Re-Onset

- episode 关闭后，只要后续再次出现新的 active evidence，就新建下一段 `kind = reOnset`。
- 如果音乐已经关掉，这些后续 episode 默认 `actionEligibility = .alreadyHandled`。

### 4.6 动作执行边界

- 规范目标仍然是：统一以 `primaryActionReadyAt` 驱动自动关音乐。
- 但当前实现里，**真实自动动作仍然只由 Route E runtime 触发**。
- 因此目前 `SleepTimeline` 的主要作用是：
  - 承载统一的 action-ready 语义
  - 支撑评估和离线分析
  - 为后续把产品动作迁移到 Timeline/episode 层做准备

### 4.7 持久化

- `AppModel` 会在 session start 时初始化 timeline。
- 每处理一个 window，会基于最新 `activePredictions` 调用 `SleepTimelineTracker.sync(...)`。
- timeline 会单独保存到 session 目录下的 `timeline.json`。
- `SessionBundle` / `SessionExportPayload` 已支持携带 optional `timeline`。

---

## 5. 评估语义

### 5.1 主评估

主产品指标改为：

- `action_ready_delay = primaryActionReadyAt - truthOnset`
- `action_execution_delay = actionTakenAt - truthOnset`
- `early_action_minutes`
  - 若 `primaryActionReadyAt < truthOnset`，这是高优先级风险指标

### 5.2 辅助评估

`onsetEstimate` 只用于：

- `onset_estimate_error`
- `confirm_vs_onset_gap`
- 个性化 onset offset 学习

### 5.3 Re-Onset 评估

后续 `reOnset` episode 主要评估：

- wake reset 是否及时
- stale anchor 是否被错误复用
- quiet-only / low-motion 假阳性是否持续存在

### 5.4 禁止事项

- 禁止继续把 `onsetEstimate` 当作线上 stop music 的主时间。
- 禁止只用最新 `RoutePrediction` 作为整夜动作与评估依据。
- 禁止让 wake 事件回滚已经产生的 primary action-ready 记录。

---

## 6. 个性化学习用途

前 1-2 晚优先学习的，应改为 **action-ready 相关参数**：

- `candidate -> actionReady` 所需持续时间
- quiet-only 证据需要多长才能触发动作
- wake reset 阈值
- re-arm quiet duration
- stale anchor reuse 识别
- backfill 样本能否参与动作

`onsetEstimate` 相关参数仍可学习，但优先级下降为：

- `onsetOffset`
- route-specific backfill offset
- HR-only / HR+HRV 的 onset 回填差异

长期分布类参数，如 bedtime prior、夜间低 HR、HRV baseline，仍应依赖更多夜晚。

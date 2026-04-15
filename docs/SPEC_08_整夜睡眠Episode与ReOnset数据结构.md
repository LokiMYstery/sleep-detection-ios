# SPEC 08: Action-Ready 优先的整夜睡眠 Episode 与 Re-Onset 数据结构

> **状态**：方案定义
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
- 线上自动动作只依赖 `actionReadyAt`，不依赖 `onsetEstimate`。

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

---

## 4. 生命周期规则

### 4.1 Primary Episode

- 整夜第一个达到 `actionReadyAt` 且满足主动作门槛的 episode，写入：
  - `primaryEpisodeIndex`
  - `primaryActionReadyAt`
  - `primaryOnsetEstimate`
- 一旦写入，不因后续 wake / unlock / pickup 被覆盖。

### 4.2 动作执行

- 自动关音乐以 `primaryActionReadyAt` 为触发依据。
- 若真的执行，则写入：
  - `actionTakenAt`
  - `actionStatus = .triggered`
  - 一条 `SleepActionDecision`

### 4.3 Wake

- 当已达 `actionReadyAt` 的 episode 之后再次出现显著 activity / interaction / physiology rebound 时，记录 `wakeDetectedAt`。
- wake 只结束该 episode，不回滚 `primaryActionReadyAt`。

### 4.4 Re-Onset

- wake 之后再次进入新的 sleep candidate / actionReady 时，新建 `kind = reOnset` 的 episode。
- 如果音乐已经关掉，这些后续 episode 默认 `actionEligibility = .alreadyHandled`。

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

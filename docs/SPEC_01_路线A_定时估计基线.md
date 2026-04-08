# SPEC 01: 路线 A - 无 HealthKit 依赖的定时估计基线

> **状态**：草稿，待评审
> **前置文档**：SPEC 00 基础框架、《入睡检测 POC 实验路线与验证规划》§4 路线 A
> **定位**：所有路线的对照基线 + 无传感器时的兜底方案

---

## 1. 路线目标

在不依赖任何实时传感器的前提下，仅通过先验知识和交互行为给出"预测入睡时间"，作为：

- 所有高级路线的误差对照组。
- 无 HealthKit、无 Watch、无麦克风权限时的最低可用兜底。

**核心实验问题**：纯定时估计的误差底线能做到什么程度？

---

## 2. 输入源

路线 A 不使用 MotionProvider、AudioProvider、WatchProvider，仅依赖以下输入：

| 输入 | 来源 | 是否必须 |
|---|---|---|
| 用户设定的目标入睡时间 | 设置页手动输入 | 是（P3 用户的唯一输入）|
| 用户估计的入睡潜伏时间 | 设置页手动输入 | 是 |
| 工作日/周末标记 | 系统日历自动判断 | 是 |
| Session 开始时间 | Session 创建时间 | 是 |
| 最后交互时间 | InteractionProvider | 否（增强项）|
| HealthKit 历史睡眠样本 | Day0 先验（P1 用户）| 否（增强项）|
| 应用内历史 | 前 N 晚的 Session 结果 | 否（D1 后逐渐可用）|

---

## 3. 用户输入设计

### 3.1 首次配置问题

首次使用时，设置页收集以下信息（控制在 4 个问题以内）：

| 序号 | 问题 | 输入形式 | 默认值 | 内部字段 |
|---|---|---|---|---|
| 1 | 你通常几点准备睡觉？ | 时间选择器 | 23:00 | `targetBedtime` |
| 2 | 你一般躺下后大概多久会睡着？ | 分段选择（<5min / 5-15min / 15-30min / 30min+）| 5-15min | `estimatedLatency` |
| 3 | 工作日和周末差别大吗？ | 开关 + 周末时间选择器 | 关 | `weekendOffset` |
| 4 | 偏好保守还是激进？ | 分段选择（保守 / 适中 / 激进）| 适中 | `aggressiveness` |

### 3.2 分段选择映射

**入睡潜伏时间**映射为具体分钟数：

| 用户选择 | 映射值（分钟） |
|---|---|
| 不到 5 分钟 | 3 |
| 5-15 分钟 | 10 |
| 15-30 分钟 | 22 |
| 30 分钟以上 | 40 |

**保守/激进偏好**映射为时间偏移：

| 用户选择 | 偏移 | 含义 |
|---|---|---|
| 保守 | +10 min | 宁可延后判定，减少提前误判 |
| 适中 | 0 min | 无偏移 |
| 激进 | -5 min | 倾向于更早判定入睡 |

---

## 4. 预测算法

### 4.1 基础预测公式

```
predictedSleepOnset = anchorTime + latency + aggressivenessOffset
```

其中 `anchorTime` 的选取优先级：

1. **P1 用户且有足够历史**：使用 HealthKit 先验的 `weekdayOnset` 或 `weekendOnset`。
2. **有应用内历史（≥3 晚有标签）**：使用应用内最近 7 晚的入睡时间中位数。
3. **仅用户输入**：使用 `targetBedtime`（及 `weekendOffset`，若为周末）。

`latency` 的选取优先级：

1. **P1 用户**：使用 HealthKit 先验的 `typicalLatency`。
2. **有应用内历史**：使用应用内最近 7 晚的"session 开始到实际入睡"中位差值。
3. **仅用户输入**：使用 `estimatedLatency` 映射值。

### 4.2 交互感知增强

如果 InteractionProvider 可用，路线 A 可在 Session 期间做一次预测更新：

- 当检测到 `timeSinceLastInteraction ≥ 5min` 且 `isLocked == true` 时，标记一个"疑似用户已躺下"时间点 `lastActiveTime`。
- 替换 `anchorTime` 为 `lastActiveTime`，重新计算预测。
- 如果用户之后再次解锁手机，则回退到原始 `anchorTime`。

这是路线 A 唯一允许使用的实时信号，且不依赖运动传感器。

### 4.3 应用内历史自修正

当应用积累了 ≥3 晚有 ground truth 标签的 Session 后：

- 计算最近 7 晚的预测误差中位数。
- 如果误差中位数持续偏向一个方向（例如连续 3 晚提前判定），自动调整 `latency` 偏移。
- 调整幅度每次不超过 ±5 分钟，避免过度修正。

---

## 5. 判定状态流转

路线 A 的状态流转比其他路线简单，因为它不依赖持续观察：

```
idle → predicted → (optional) updated → confirmed
```

| 状态 | 触发条件 | 事件 |
|---|---|---|
| `idle` | Session 启动 | — |
| `predicted` | Session 启动后立即计算出初始预测 | `predictionUpdated` |
| `updated` | 检测到用户停止交互，更新了锚点 | `predictionUpdated` |
| `confirmed` | 到达预测时间 | `confirmedSleep` |

**注意**：路线 A 的 `confirmedSleep` 本质上是"到达预测时间"，而不是基于实时证据确认。这一点在评估时需要明确标注。

---

## 6. 事件日志

路线 A 产生的事件类型及 payload：

| 事件类型 | payload 字段 | 说明 |
|---|---|---|
| `predictionUpdated` | `anchorSource`, `anchorTime`, `latency`, `offset`, `predictedTime` | 每次预测更新时记录 |
| `confirmedSleep` | `predictedTime`, `method: "timer"` | 到达预测时间时触发 |
| `custom("interactionAnchored")` | `lastActiveTime`, `previousAnchor`, `newAnchor` | 交互锚点更新时触发 |
| `custom("interactionResumed")` | `resumeTime` | 用户再次解锁，回退锚点 |

---

## 7. canRun 条件

```swift
func canRun(condition: DeviceCondition, priorLevel: PriorLevel) -> Bool {
    // 路线 A 总是可以运行，它是兜底方案
    return true
}
```

路线 A 的唯一前提是用户完成了首次配置（设定了 `targetBedtime` 和 `estimatedLatency`）。如果用户未配置，则使用默认值（23:00 + 10min）。

---

## 8. 验证重点

本路线在评估框架中需特别关注：

| 指标 | 预期 | 说明 |
|---|---|---|
| 绝对误差中位数 | 可能在 20-40 分钟 | 不依赖实时信号，预期误差较大 |
| 10 分钟命中率 | 可能 < 30% | 纯定时估计的上限测试 |
| 提前/延后占比 | 需观察 | 验证保守/激进偏好是否有效 |
| P1 vs P3 差异 | P1 应该更好 | 验证 HealthKit 先验是否有效缩小误差 |
| 交互增强有效性 | 与纯定时对比 | 验证 §4.2 的交互锚点是否提升精度 |

---

## 9. 与其他 SPEC 的关系

- **基础框架 SPEC**：使用 Session、InteractionProvider、Day0 先验。
- **路线 B**：路线 B 可理解为"路线 A + 惯性锚点"，共享 anchorTime 概念。
- **评估框架**：路线 A 作为所有路线的 baseline 参照，误差报告中应始终包含路线 A 的结果。

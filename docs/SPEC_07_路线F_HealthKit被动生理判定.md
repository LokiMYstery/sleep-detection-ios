# SPEC 07: 路线 F - HealthKit 被动生理判定

> **状态**：已按当前代码实现对齐，待真机夜间验证
> **前置文档**：SPEC 00 基础框架、SPEC 05 路线 E、SPEC 06 评估框架
> **定位**：Route E 的低集成复杂度替代实验路线，主动牺牲实时性，换取“不依赖 Watch 实时通信”的可运行方案
> **核心约束**：Route F 只依赖 iPhone 侧 HealthKit 被动更新的心率 / HRV；`sleepAnalysis` 只用于历史先验和次日 truth，不作为当晚 live 输入

---

## 1. 路线目标

当 Route E 受限于 Watch App、后台通信、腕部加速度回传链路时，Route F 用更保守的方式回答另一个问题：

1. 只靠 HealthKit 被动推送到 iPhone 的心率和 HRV，能否做出可用的入睡判定。
2. 在接受分钟级延迟的前提下，是否可以绕开 Watch 实时通信复杂度。
3. 历史心率先验是否足以把“清醒但安静”与“开始入睡”分开。
4. HRV 是否能作为“确认入睡”的支持性证据，而不是必须的主通道。

Route F 不是 Route E 的降级模式，而是一条独立实验路线。

---

## 2. 设计边界

### 2.1 Route F 关注什么

- 只关心 iPhone 侧是否能收到新的 `heartRate` / `heartRateVariabilitySDNN` 样本。
- 允许 HealthKit 样本晚到、补到、稀疏到。
- 用历史先验先定义个体化的“夜间低心率区间”，再用当晚新样本逐步进入 candidate / confirmed。

### 2.2 Route F 明确不做什么

- 不依赖 Watch 与 iPhone 的实时消息通道。
- 不依赖 Watch 侧腕动、加速度、Workout 会话或镜像连接。
- 不把 `sleepAnalysis` 当作当晚判定输入。
- 不要求 iPhone 的运动、音频、交互信号参与 Route F 核心判定。

---

## 3. 输入源

| 输入 | 来源 | 用途 | 是否 live |
|---|---|---|---|
| 心率样本 `heartRate` | HealthKit quantity sample | 当晚主判定信号 | 是 |
| HRV 样本 `heartRateVariabilitySDNN` | HealthKit quantity sample | 支持确认 / 提升置信度 | 是 |
| 历史睡眠样本 `sleepAnalysis` | HealthKit category sample | P1 对齐先验、次日 truth | 否 |
| 历史心率样本 | HealthKit quantity sample | 个体化 evening / night HR 先验 | 否 |
| 历史 HRV 样本 | HealthKit quantity sample | HRV baseline / readiness | 否 |

### 3.1 当晚 live 输入

当前实现只消费两类 HealthKit 被动更新：

- `HKQuantityTypeIdentifier.heartRate`
- `HKQuantityTypeIdentifier.heartRateVariabilitySDNN`

每条新样本都会被转成一个 `FeatureWindow(source: .healthKit)`，窗口长度为 `0`，时间锚点就是样本时间。

### 3.2 非 live 输入

`sleepAnalysis` 只用于两件事：

- 对齐历史夜晚，计算 Route F 的个体化先验。
- 次日回填真值，做离线误差评估。

---

## 4. Day0 先验与可用性

Route F 的可用性不只看 `PriorLevel`，还单独看 `RouteFReadiness`。

### 4.1 PriorLevel

当前实现：

| Level | 条件 |
|---|---|
| `P1` | 最近睡眠样本 `>= 3` 晚 |
| `P2` | 最近心率天数 `>= 7` 或 HRV 天数 `>= 3` |
| `P3` | 不满足以上条件 |

### 4.2 RouteFReadiness

当前实现：

| Readiness | 条件 | 含义 |
|---|---|---|
| `full` | 心率天数 `>= 7` 且 HRV 天数 `>= 3` | 可用 HR + HRV 联合确认 |
| `hrOnly` | 心率天数 `>= 7`，但 HRV 不足 | 只能走 HR 主通道 |
| `insufficient` | 其他情况 | Route F 不可用 |

> 注意：会出现 `PriorLevel == P2` 但 `RouteFReadiness == insufficient` 的情况，例如只有少量 HRV 历史、没有足够 HR 天数。此时 Route F 仍然不可用。

### 4.3 Route F 个体画像

代码会从历史数据计算三个关键先验：

| 先验 | 含义 | 当前实现来源 |
|---|---|---|
| `historicalEveningHRMedian` | 睡前心率中位基线 | P1 优先取“入睡前 30 分钟”对齐窗口，否则取晚间时段窗口 |
| `historicalNightLowHRMedian` | 夜间低心率目标 | P1 优先取“入睡后 15-60 分钟”对齐窗口，否则取 00:00-06:00 低分位区间 |
| `historicalHRVBaseline` | 夜间 HRV 支持阈值 | P1 优先取“入睡后 60 分钟内”对齐窗口，否则取 00:00-06:00 高分位区间 |

在此基础上，再计算 `RouteFProfile`：

| Profile | 条件 |
|---|---|
| `strong` | `eveningHR - nightLowHR >= 8 bpm` |
| `moderate` | `>= 5 bpm` 且 `< 8 bpm` |
| `weak` | `< 5 bpm` |

`weak` 画像会要求更多 HR 样本才能确认。

---

## 5. iPhone 侧被动采集方案

### 5.1 方案选择

Route F 使用 iPhone 侧：

- `HKObserverQuery`
- `HKAnchoredObjectQuery`

监听心率和 HRV 的新增样本，并开启 `.immediate` background delivery。

设计动机：

- 不需要 Watch 实时回传链路。
- 不需要启动 Watch Workout。
- 接受“系统什么时候同步过来，就什么时候判断”的 delayed-online 语义。

### 5.2 运行流程

```text
开始 session
    ↓
iPhone 订阅 heartRate / HRV 的 HKObserverQuery
    ↓
Observer 触发后执行 HKAnchoredObjectQuery
    ↓
把新样本转成 FeatureWindow(source: .healthKit)
    ↓
AppModel 每 5 秒 flush 一次待处理 physiology windows
    ↓
RouteFEngine 增量重算 candidate / confirmed
```

补充说明：

- RouteFEngine 会收到整晚所有 `FeatureWindow`，不只是 `.healthKit` 窗口。
- 真正的生理证据只来自 `window.physiology`。
- iPhone / Watch 窗口主要用于推进时间，触发 `no live data` 和 `stale sample` 这类超时判断。

### 5.3 样本时效标记

当前实现把样本质量分为：

| 标记 | 条件 |
|---|---|
| `fresh` | 样本到达时间距样本时间 `<= 120s` |
| `backfilled` | 到达延迟 `> 120s` |
| `stale` | UI 快照中，最新生理样本已超过 `15min` 未更新 |

Route F 接受 backfill；它不是实时路线。

---

## 6. 窗口特征定义

```swift
struct PhysiologyFeatures {
    let heartRate: Double?
    let heartRateSampleDate: Date?
    let heartRateTrend: HRTrend
    let hrvSDNN: Double?
    let hrvSampleDate: Date?
    let hrvState: HRVState
    let sampleArrivalTime: Date
    let isBackfilled: Bool
    let dataQuality: DataQuality
}
```

### 6.1 心率趋势

默认参数下，心率趋势基于最近 `20min` 内的 HR 样本做线性回归：

| 状态 | 条件 |
|---|---|
| `dropping` | 斜率 `<= -0.3 bpm/min` |
| `stable` | 斜率在 `(-0.3, 0.3)` |
| `rising` | 斜率 `>= 0.3 bpm/min` |
| `insufficient` | 样本数 `< 3` |

### 6.2 HRV 状态

这里需要区分两个层面：

- `PhysiologyFeatures.hrvState` 是 provider 侧附带的诊断字段。
- Route F 真正是否把一条 HRV 样本当作“支持确认”，并不直接依赖这个字段，而是由引擎重新计算。

当前代码里：

- provider 侧通常只会产出 `neutral` 或 `unavailable`
- RouteFEngine 会额外判断 HRV 时间是否落在支持窗口内
- RouteFEngine 还会判断 `sdnn >= historicalHRVBaseline`

满足这两个条件时，这条 HRV 才会被 Route F 当作 supporting evidence。

---

## 7. 判定规则

### 7.1 目标阈值解析

Route F 不使用固定心率阈值，而是先解析三类目标：

```text
sleepTarget =
    historicalNightLowHRMedian
    or sleepHRTarget
    or preSleepHRBaseline * 0.85

eveningBaseline =
    historicalEveningHRMedian
    or preSleepHRBaseline

hrDropThreshold =
    max(6, eveningBaseline - nightLowHRMedian)
    or max(6, historical hrDropThreshold)
    or max(6, preSleepHRBaseline * 0.1)
```

### 7.2 HR 候选条件

单个 HR 样本满足以下任一条件即可记为“qualified”：

```text
trend != rising
AND (
    heartRate <= sleepTarget
    OR
    eveningBaseline - heartRate >= hrDropThreshold
)
```

也就是说：

- 可以靠“已经降到夜间目标附近”进入候选；
- 也可以靠“相对睡前基线已经下降足够多”进入候选；
- 只要出现 `rising`，就不视为合格样本。

### 7.3 candidate / suspected / confirmed

默认参数下：

| 状态 | 条件 |
|---|---|
| `candidate` | 连续合格 HR 样本 `>= 2` |
| `suspected` | 已超过 candidate 阈值，但尚未满足确认阈值 |
| `confirmed` | 满足 HR+HRV 联合确认，或 HR 样本数达到确认阈值 |

预测入睡时间统一回溯到：

```text
predictedSleepOnset = 第一条 qualified HR 样本的时间
```

补充说明：

- 在默认参数下，`strong / moderate` 画像通常会从 `candidate` 直接进入 `confirmed`，因为第 3 个合格 HR 样本就会确认。
- `suspected` 更常见于 `weak` 画像，或者后续把确认阈值调高的实验设置。

### 7.4 HRV 联合确认

当 `RouteFReadiness == full` 时，如果：

- 已经达到 `candidateMinQualifiedSamples`
- 且在 `hrvSupportWindowMinutes` 支持窗口内出现 HRV 样本（默认 `60min`）
- 且 `hrvSDNN >= historicalHRVBaseline`

则直接确认为：

```text
confirmType = hrPlusHRV
```

联合确认有两种触发方式：

1. 处理一个新的合格 HR 样本时，发现缓存里已经有满足条件的 HRV。
2. 已经处于 `candidate` 后，随后到达一条满足条件的新 HRV 样本。

支持窗口按“HR 样本时间”和“HRV 样本时间”的绝对时间差计算。

### 7.5 HR 样本数回退确认

如果没有 HRV 支持，仍允许只靠 HR 连续样本确认：

```text
confirmRequired =
    confirmMinQualifiedSamples
    + (routeFProfile == weak ? weakProfileExtraConfirmSamples : 0)
```

默认值下：

- `strong / moderate`：`3` 个合格 HR 样本可确认
- `weak`：需要 `4` 个合格 HR 样本
- `hrOnly` readiness：确认方式记为 `hrOnly`
- `full` readiness 但未等到支持性 HRV：确认方式记为 `hrCountFallback`

这里的 `weakProfileExtraConfirmSamples` 只影响“按 HR 样本数回退确认”这条路径，不影响 `hrPlusHRV` 联合确认。

### 7.6 回退与拒绝

以下情况会清空 candidate：

| 场景 | 条件 | rejection reason |
|---|---|---|
| 心率反弹 | `heartRate >= sleepTarget + reboundThresholdBPM`，默认 `+5 bpm` | `heart_rate_rebound` |
| 趋势转升 | `trend == rising` | `heart_rate_rebound` |
| 不再满足候选条件 | 当前 HR 不够低，且下降幅度不够 | `candidate_conditions_not_met` |
| 样本过久未更新 | 距离最新 HR 样本 `> staleSampleThresholdMinutes`，默认 `15min` | `stale_samples` |

### 7.7 无 live 样本超时

如果 session 开始后超过 `noLiveDataTimeoutMinutes` 仍没有任何 HR live 样本到达，默认 `90min`，则 Route F 不给出入睡结果，只记录：

```text
custom.hkNoLiveSamples
```

---

## 8. 参数表

当前 `RouteFParameters` 默认值如下：

| 参数 | 默认值 | 用途 |
|---|---|---|
| `historyLookbackDays` | `14` | 历史先验回看天数 |
| `hrTrendWindowMinutes` | `20` | HR 趋势窗口 |
| `hrTrendMinSamples` | `3` | 计算趋势所需最少 HR 样本 |
| `candidateMinQualifiedSamples` | `2` | 进入 candidate 所需合格 HR 样本数 |
| `confirmMinQualifiedSamples` | `3` | 默认确认样本数 |
| `hrvSupportWindowMinutes` | `60` | HRV 支持确认窗口 |
| `staleSampleThresholdMinutes` | `15` | 样本过期阈值 |
| `reboundThresholdBPM` | `5` | 心率反弹阈值 |
| `weakProfileExtraConfirmSamples` | `1` | weak 画像的额外确认样本 |
| `noLiveDataTimeoutMinutes` | `90` | 无 live 样本超时 |

---

## 9. 事件日志

### 9.1 Provider 侧事件

| 事件 | 说明 |
|---|---|
| `custom.hkLiveSubscribed` | 已开始监听心率 / HRV 的被动更新 |
| `custom.hkSamplesBackfilled` | 收到了延迟补到的样本 |
| `custom.hkLiveSubscriptionFailed` | HK observer / anchored query 失败 |
| `sensorUnavailable` | 当前设备无法提供 HK live physiology |

### 9.2 Route F 侧事件

| 事件 | payload 重点 | 说明 |
|---|---|---|
| `custom.routeFProfileResolved` | `readiness`, `profile`, `eveningHRMedian`, `nightLowHRMedian`, `hrvBaseline` | 会话开始时解析出的先验 |
| `custom.routeFHRVUnavailable` | `readiness` | 仅 HR 模式 |
| `candidateWindowEntered` | `time`, `qualifiedHRCount`, `profile` | 进入候选 |
| `suspectedSleep` | `time`, `qualifiedHRCount`, `readiness` | 候选继续增强 |
| `confirmedSleep` | `predictedTime`, `confirmType`, `hrAtConfirm`, `hrvAtConfirm` | 确认入睡 |
| `sleepRejected` | `reason`, `signal` | candidate 被清空 |
| `custom.hkNoLiveSamples` | `readiness` | 长时间未等到 live HR |

---

## 10. canRun 与实际可用性

Route F 的引擎级 `canRun` 条件为：

```swift
condition.hasHealthKitAccess && priorLevel != .P3
```

但实际开始运行时还会进一步检查：

- `session.deviceCondition.hasHealthKitAccess == true`
- `priors.routeFReadiness != .insufficient`

因此 Route F 的实际可用性应理解为：

```text
HealthKit 可读
AND
至少具备 7 天 HR 历史
```

Watch 是否配对、是否可达、是否有实时通信，都不影响 Route F 是否启动。

---

## 11. 评估与导出

Route F 已接入当前评估框架：

- `SessionAnalytics.trackedRouteIds` 已包含 `.F`
- summary CSV 已导出 `routeF_prediction` 和 `routeF_error_min`
- Route F 会进入与 A-E 相同的次日 truth 误差统计

次日 truth 仍使用 HealthKit 睡眠样本，不使用当晚 Route F 的内部状态充当真值。

---

## 12. 当前实现备注与已知局限

### 12.1 已知局限

| 问题 | 影响 |
|---|---|
| HealthKit 心率 / HRV 到达时间不可控 | Route F 只能做 delayed-online，不能承诺分钟内实时判定 |
| 心率采样天然稀疏 | candidate / confirm 速度会明显慢于 Route E |
| 没有腕动信号 | 更容易遇到“安静清醒”与“真正入睡”混淆 |
| HRV 并不稳定可得 | 很多夜晚会退化为 `hrOnly` 或 `hrCountFallback` |

### 12.2 当前代码与理想 spec 的小差异

| 项目 | 当前状态 |
|---|---|
| `historyLookbackDays` | 参数已定义，但当前 HealthKit 历史查询仍固定取最近 `14` 天，尚未把该参数真正串到查询层 |
| `sleepAnalysis` 历史用途 | 当前实现可参与 P1 先验对齐；次日 truth 会排除 user-entered 样本，但先验阶段未额外剔除 |
| `PhysiologyFeatures.heartRateTrend` | provider 侧构造该字段时仍固定使用 `20min / 3 样本`；RouteFEngine 会按 `RouteFParameters` 再重新计算一次趋势，因此实际判定以 engine 计算为准 |
| `PhysiologyFeatures.hrvState` | 当前更偏向诊断字段；Route F 的确认逻辑实际直接调用 `hrvSupports(...)` 判断，而不是读取 `hrvState` |

### 12.3 验证建议

Route F 下一阶段重点不是继续加复杂规则，而是先观察：

1. 真机夜间样本的实际到达延迟分布。
2. `full`、`hrOnly`、`insufficient` 三种 readiness 的夜晚占比。
3. `hrPlusHRV` 与 `hrCountFallback` 的命中率差异。
4. 相比 Route E，Route F 因延迟牺牲了多少误差表现，是否换来了足够高的实现稳定性。

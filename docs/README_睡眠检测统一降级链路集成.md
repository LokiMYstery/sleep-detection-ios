# 睡眠检测统一降级链路集成 README

这份文档面向把当前 POC 接入成熟 iOS App 的 Swift 工程师。它说明这个模块要解决什么问题、核心概念是什么、统一降级链路怎么跑，以及哪些 POC 内容只是调试设施、不一定要在正式 App 中实装。

## 1. 这个功能是干嘛的

这个模块用于在用户进入睡前场景后，结合 iPhone 与 Apple Watch 的实时信号，判断“用户是否已经达到可以安全执行睡眠动作的状态”。当前最典型的产品动作是停止助眠音频。

它输出的不是医学意义上的睡眠诊断，而是一个产品侧可用的实时决策:

- 用户刚开始助眠或睡前记录时，状态是 `monitoring`。
- 信号开始支持“可能入睡”时，状态进入 `candidate`。
- 证据累计到动作阈值后，状态进入 `confirmed`。
- 产品只应在 `confirmed` 后触发一次性动作。

次日 HealthKit 睡眠记录只用于离线校验和调参，不是实时判断的必要前置条件。

## 2. 基础概念

### Session

`Session` 表示一次完整的睡前/睡眠检测过程。成熟 App 中可以把它对应到一次助眠播放或一次睡眠检测任务。

Session 至少需要记录:

- `sessionId`: 本次检测的唯一 ID。
- `startTime`: 用户开始助眠或开始检测的时间。
- `endTime`: 用户结束、系统自动结束或异常恢复后的结束时间。
- `deviceCondition`: 启动时设备能力快照，例如是否有 Watch、Motion、HealthKit、Microphone。
- `disabledFeatures`: 本次 session 中不可用或降级的能力，例如 `watchUnavailable`、`watchCompanionMissing`。

Session 是所有窗口、判定结果、调试日志和离线评估的归属单位。

### FeatureWindow

`FeatureWindow` 是固定时间片内的传感器特征摘要。POC 里通常按 30 秒聚合一次。

它不是原始传感器流，而是给判定引擎消费的结构化摘要:

- `motion`: iPhone 运动特征。
- `interaction`: 锁屏、亮屏、最后交互时间等交互特征。
- `watch`: Watch 腕部运动、心率、心率趋势等特征。
- `audio`: POC 里存在音频特征，但当前统一链路的主决策不依赖它。

成熟 App 接入时，关键是稳定产出 `FeatureWindow`，并按顺序喂给 `UnifiedDecisionEngine`。

### Channel

Channel 是统一链路内部使用的一路可用信号:

- `watchMotion`: Watch 腕部运动。
- `watchHeartRate`: Watch 心率。
- `phoneMotion`: iPhone 运动。
- `phoneInteraction`: iPhone 锁屏/交互状态。

每个 channel 在每个 window 内会产出一个 `positiveScore`，也可能给出强否决。

### CapabilityProfile

`UnifiedCapabilityProfile` 表示当前 session 实际可用的 channel 组合。

例如:

- 只有 iPhone motion 和交互可用: `phoneInteraction+phoneMotion`。
- iPhone 和 Watch 都可用: `phoneInteraction+phoneMotion+watchHeartRate+watchMotion`。
- 没有支持信号: `none`。

统一降级的核心就是: 根据实际能力生成 profile，在这个 profile 内重新归一化权重，并继续完成判定。

### UnifiedSleepDecision

`UnifiedSleepDecision` 是产品侧最重要的输出。

核心字段:

- `state`: 当前状态，取值为 `monitoring`、`candidate`、`confirmed`、`unavailable`、`noResult`。
- `capabilityProfile`: 当前 session 使用了哪些信号。
- `episodeStartAt`: 本轮正向证据开始累计的时间。
- `candidateAt`: 达到候选阈值的时间。
- `confirmedAt`: 达到确认阈值的时间，也是产品动作应参考的时间。
- `progressScore`: 当前累计分。
- `candidateThreshold`: 候选阈值。
- `confirmThreshold`: 确认阈值。
- `evidenceSummary`: 可读的当前证据摘要。
- `denialSummary`: 最近一次 freeze 或 rollback 原因。

## 3. Watch App 背景和边界

为了拿到 Apple Watch 的实时腕部运动与心率，当前方案必须依赖 Watch App。

原因是: iPhone 侧仅依赖 HealthKit 被动数据，很难满足“正在播放助眠音频时实时判断是否可以停止”的时效要求。Watch App 可以在手表侧启动 workout/background 相关能力，采集腕部运动和心率，再通过 WatchConnectivity 回传给 iPhone。

接入成熟 App 时需要单独设计 Watch App 的工程和生命周期:

- Watch App 首次启动、授权 HealthKit、授权 Motion 的引导。
- iPhone 发起 session 时，Watch App 如何启动采集。
- Watch App 在后台、锁屏、低电量、断连时的行为。
- Watch 采集停止、失败重试、补传和用户可见状态。
- Watch App 未安装、未授权、不可达时的降级体验。

当前 POC 的 Watch App 前端页面只用于 debug 和授权/状态观察，没有做正式产品设计，不能直接作为成熟 App 的 Watch 端 UI。

## 4. 项目结构

成熟 App 集成时优先看这些文件:

| 路径 | 集成价值 |
|---|---|
| `SleepDetectionPOC/Core/Domain/UnifiedModels.swift` | 统一结果模型、channel、profile、diagnostics、learning profile |
| `SleepDetectionPOC/Core/Unified/UnifiedDecisionEngine.swift` | 统一降级判定状态机 |
| `SleepDetectionPOC/App/AppModel.swift` | POC 接入示例: session start、window feed、persist、action trigger |
| `SleepDetectionPOC/Core/Providers/SensorProviders.swift` | iPhone / Watch / audio provider 示例 |
| `SleepDetectionWatchApp/` | Watch 侧实时运动和心率采集示例 |
| `SleepDetectionPOC/Core/Services/UnifiedSessionAnalytics.swift` | 离线评估和 profile 表现统计 |

工程配置参考 `project.yml`:

- iOS deployment target: `17.0`
- watchOS deployment target: `10.0`
- Swift: `6.0`
- iOS target 需要 HealthKit share、Motion、Microphone usage description。
- Watch target 需要 HealthKit share/update、Motion usage、`WKBackgroundModes.workout-processing`。
- Watch target 当前复用 `Models.swift`、`UnifiedModels.swift`、`Settings.swift`。

## 5. 最小接入流程

成熟 App 可以把 `AppModel` 当参考实现，不需要照搬 POC 的页面、存储和调试结构。

```swift
let learningProfile = UnifiedLearningComputer.compute(from: sessionBundles)
let engine = UnifiedDecisionEngine(settings: settings, eventBus: eventBus)

engine.start(
    session: session,
    priors: priorSnapshot.routePriors,
    learningProfile: learningProfile
)

// 每个特征窗口到达时调用:
engine.onWindow(featureWindow)

let decision = engine.currentDecision()
let diagnostics = engine.currentDiagnostics(rawReferenceFileNames: [])
```

Session 结束时:

```swift
engine.finalize(at: Date())
```

推荐顺序:

1. 用户开始助眠或睡眠检测，创建业务 session。
2. 记录启动时 `DeviceCondition` 和 `disabledFeatures`。
3. 启动可用 provider，包括 iPhone motion / interaction / Watch。
4. 创建并启动 `UnifiedDecisionEngine`。
5. 每个 `FeatureWindow` 到达时调用 `onWindow(_:)`。
6. 读取 `currentDecision()` 更新业务状态。
7. 如果 `state == .confirmed`，触发一次产品动作。
8. Session 结束时调用 `finalize(at:)`。
9. 次日如果有 HealthKit truth，再做离线评估。

## 6. 统一降级链路怎么实现

启动 session 时，engine 会根据设备能力生成 `capabilityProfile`:

```swift
static func capabilityProfile(for session: Session) -> UnifiedCapabilityProfile
```

规则简化理解:

- 有 Motion access，加入 `phoneMotion`。
- 有 Motion access 或 Watch，加入 `phoneInteraction`。
- 有 Watch 且没有 `watchUnavailable` / `watchCompanionMissing`，加入 `watchMotion` 和 `watchHeartRate`。
- 没有任何支持 channel，状态为 `unavailable`。

每个 profile 有自己的权重。默认 base weight:

| Channel | Base weight |
|---|---:|
| `watchMotion` | 0.35 |
| `watchHeartRate` | 0.30 |
| `phoneMotion` | 0.20 |
| `phoneInteraction` | 0.15 |

这些权重会在当前 profile 内归一化。比如只有 `phoneMotion` 和 `phoneInteraction` 时，两者会重新分配为 phone-only profile 的权重，而不是继续使用完整设备组合下的原始占比。

每个 window 的处理顺序:

1. 分别评估当前 profile 中的 channel。
2. 如果有强否决，先处理 freeze 或 rollback。
3. 只对当前有新鲜数据的 channel 计算正向分。
4. `weightedScore = positiveScore * channelWeight`。
5. 把本轮 weighted score 累加到 `progressScore`。
6. `progressScore >= 1.5` 时进入 `candidate`。
7. `progressScore >= 3.0` 时进入 `confirmed`。

某一路信号暂时没有数据时，它本轮不加分，但其它可用信号仍然可以继续推进。这样可以覆盖 Watch 不可用、Watch 断连、iPhone motion 不可用等真实设备条件。

## 7. 四路信号规则

Watch motion:

- 静止足够久或 `wristAccelRMS <= 0.015`，给强正向分。
- 轻微静止给弱正向分。
- 连续 2 个 window 显示 `wristAccelRMS > 0.1` 时触发 `watchMotionActive` freeze。
- freeze 不清空已累计进度，只是阻止当前活动状态继续确认。

Watch heart rate:

- `heartRate <= sleepTarget` 给强正向分。
- 心率趋势下降且相对 baseline 有足够下降，给中等正向分。
- 接近 sleep target 且不是 rising，给弱正向分。
- 心率不做强否决，只提供正向证据。

Phone motion:

- `accelRMS <= 0.015` 且 `stillRatio >= 0.85` 给强正向分。
- `accelRMS <= 0.08` 且 `stillRatio >= 0.75` 给弱正向分。
- 明显 pickup、姿态变化或峰值过多会 rollback active episode。
- rollback 会清空 `episodeStartAt`、`candidateAt`、`progressScore`。

Phone interaction:

- 锁屏、无亮屏、安静至少 2 分钟给强正向分。
- 锁屏、无亮屏、安静至少 60 秒给弱正向分。
- 未锁屏、亮屏、或最近 15 秒内仍有交互会 rollback active episode。

## 8. 产品动作接入

业务动作只看 unified decision:

```swift
func syncSleepAction(previous: UnifiedSleepDecision?, current: UnifiedSleepDecision?) {
    guard previous?.state != .confirmed else { return }
    guard current?.state == .confirmed else { return }

    scheduleStopAudio(confirmedAt: current?.confirmedAt)
}
```

如果业务需要延迟执行，deadline 到达时必须复核:

```swift
guard engine.currentDecision()?.state == .confirmed else {
    cancelStopAudio(reason: "unifiedNotConfirmedAtDeadline")
    return
}

stopAudioOnce()
```

要求:

- `candidate` 不触发动作。
- `confirmed` 只触发一次动作。
- 重复 snapshot 不能重复关音频。
- `noResult` 表示本次 session 没有得到可动作确认。

## 9. 主结果保存

POC 会把主结果保存到 `unified.json`，结构是:

```swift
struct UnifiedSessionArtifacts: Codable, Equatable, Sendable {
    var decision: UnifiedSleepDecision?
    var timeline: UnifiedSleepTimeline?
    var diagnostics: UnifiedDecisionDiagnostics?
}
```

这部分在 POC 中主要服务 debug、回放和离线评估。成熟 App 不一定需要照搬本地文件持久化，也不一定要保存完整 diagnostics。

如果正式产品需要持久化，建议按业务需要选择最小字段:

- `sessionId`
- `state`
- `capabilityProfile`
- `candidateAt`
- `confirmedAt`
- `progressScore`
- `evidenceSummary`
- `denialSummary`

`diagnostics.evidenceSnapshots` 数据较细，适合调试和灰度排查，不建议默认作为产品主数据全量长期保存。

## 10. 事件

POC 使用 `EventBus` 和 `events.jsonl` 记录运行时事件，主要用于 debug、恢复和测试。成熟 App 不一定需要保存这些事件。

关键事件含义:

| Event | 含义 |
|---|---|
| `system.sessionStartDegraded` | 某 provider 启动失败或不可用 |
| `system.unifiedDecisionSnapshot` | unified 状态快照 |
| `unified.candidateEntered` | 进入候选 |
| `unified.confirmedSleep` | 达到确认阈值 |
| `unified.watchDenyFrozen` | Watch motion freeze |
| `unified.candidateRolledBack` | phone motion / interaction rollback |

如果成熟 App 已有日志系统，可以只记录关键业务点，例如 session 降级、confirmed、rollback 计数和最终结果。是否落盘事件流由产品排障需求决定。

## 11. UI 边界

当前 POC 的 iOS UI 和 Watch UI 都是调试 App UI，不适合作为成熟 App 实装界面。

它们的作用是:

- 展示当前 session 状态。
- 展示传感器可用性。
- 展示 unified decision。
- 展示各 channel 的 `positiveScore` / `isStrongDeny` / `summary`。
- 手动触发 Watch 准备、HealthKit 授权、麦克风授权等 debug 操作。

可参考但不应直接复用的页面:

- `HomeView`: 调试当前 session、设备状态、统一判定。
- `MonitorView`: 调试实时窗口、channel snapshot、事件流。
- `HistoryView`: 调试历史 session 和离线评估。
- Watch App 页面: 调试 Watch 侧状态和授权，不是正式 Watch 产品页。

正式 App 应按自己的睡前流程设计 UI，只把 `UnifiedSleepDecision` 映射为内部状态或轻量提示。

## 12. 离线评估

次日 HealthKit truth 回填后，当前口径用 `confirmedAt` 计算误差:

```swift
UnifiedDecisionErrorComputer.computeError(
    truthDate: truthDate,
    decision: unifiedDecision
)
```

CSV 导出字段:

- `unified_state`
- `unified_profile`
- `unified_candidate_at`
- `unified_confirmed_at`
- `unified_error_min`

JSON 评估入口:

```swift
UnifiedSessionAnalytics.exportPayload(from: bundles)
```

离线评估用于看 confirmed 时间与 HealthKit 入睡时间之间的偏差，并不改变当晚实时动作已经发生的事实。

## 13. 集成注意事项

- 先把 session、window、decision 三个概念接稳，再考虑完整诊断和评估。
- Watch 实时通信依赖 Watch App，Watch App 生命周期要作为独立工程问题处理。
- `confirmedAt` 是产品动作时间，不要用 `candidateAt` 触发动作。
- 没有 Watch 时仍可用 phone profile 运行。
- HealthKit truth 不是 live decision 前置条件。
- POC 的 `unified.json`、`events.jsonl`、调试 UI 都不要求在成熟 App 中原样实现。
- 如果后续新增信号，应扩展 `UnifiedDecisionChannel` 和 channel scoring，而不是在产品层自行拼判定逻辑。

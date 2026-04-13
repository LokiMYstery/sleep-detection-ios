# SPEC 04: 路线 D - 无 Watch 的 iPhone 多模态融合

> **状态**：v1 已实现，参数待继续调优
> **前置文档**：SPEC 00 基础框架、SPEC 03 路线 C、《入睡检测 POC 实验路线与验证规划》§4 路线 D
> **定位**：无 Watch 场景下的主推荐实验路线，最有可能成为无 Watch 产品主方案

---

## 1. 路线目标

通过融合体动、环境音频特征和交互行为，解决路线 C "安静清醒误判为入睡"的核心问题。

**核心实验问题**：多模态融合是否能明显优于纯体动方案？音频特征的增量价值是否值得麦克风权限成本？

**与路线 C 的关系**：路线 D = 路线 C 的体动判定 + 音频证据 + 交互上下文，三路信号共同投票。

---

## 2. 输入源

| 输入 | Provider | 用途 | 是否必须 |
|---|---|---|---|
| 体动特征（全部） | MotionProvider | 与路线 C 相同，用于 stillness gating | 是 |
| 环境噪声水平 | AudioProvider | 判断是否整体安静 | 是 |
| 环境噪声方差 | AudioProvider | 区分持续安静 vs 间歇扰动 | 是 |
| 摩擦/翻身音事件数 | AudioProvider | 排除卧床但仍在活动 | 是 |
| 呼吸存在性/周期性/频率 | AudioProvider | 给 Route D 提供 sleep-like audio support | 否（增强项） |
| 鼾声候选数/时长/置信度 | AudioProvider | 给 Route D 提供另一类 sleep-like audio support | 否（增强项） |
| 扰动分数 | AudioProvider | 拒绝高噪声/高摩擦窗口 | 是 |
| 播放泄漏分数 | AudioProvider | 排除音频播放污染麦克风的窗口 | 是 |
| 锁屏状态 | InteractionProvider | 用户交互是否终止 | 是 |
| 最后交互时间 | InteractionProvider | 交互停止时长 | 是 |
| 屏幕唤醒次数 | InteractionProvider | 入睡后不应有主动唤醒 | 是 |
| HealthKit 先验 | Day0 先验 | Route A/F 使用，Route D 不直接依赖 | 否 |

---

## 3. 音频特征定义

### 3.1 设计原则

- 音频判定以本地 DSP 特征为主，不做云端处理。
- 路线 D 消费的是窗口级统计特征，不直接消费原始 PCM。
- 当前调试构建会额外导出原始采集分段以定位后台/断流问题；这属于诊断能力，不属于 Route D 判定逻辑本身。

### 3.2 每窗口音频特征（AudioFeatures）

```swift
struct AudioFeatures {
    let envNoiseLevel: Double
    let envNoiseVariance: Double
    let breathingRateEstimate: Double?
    let frictionEventCount: Int
    let isSilent: Bool

    let breathingPresent: Bool
    let breathingConfidence: Double
    let breathingPeriodicityScore: Double
    let breathingIntervalCV: Double?

    let disturbanceScore: Double
    let playbackLeakageScore: Double

    let snoreCandidateCount: Int
    let snoreSeconds: Double
    let snoreConfidenceMax: Double
    let snoreLowBandRatio: Double
}
```

### 3.3 呼吸存在性/周期性估计

当前实现是稳健优先的启发式 DSP：

1. 对输入做帧级统计，提取 RMS、过零率、低频能量占比、谱质心、音调性，以及一条 `respiratoryProxy`。
2. 对窗口内的 `respiratoryProxy` 做平滑。
3. 在呼吸合理周期范围内做归一化自相关，寻找最佳周期。
4. 结合相关峰值、周期稳定性（间隔 CV）、低频占比、扰动分数、播放泄漏分数，输出：
   `breathingPresent / breathingConfidence / breathingPeriodicityScore / breathingRateEstimate / breathingIntervalCV`

说明：

- 当前阈值偏保守，误报成本高于漏报成本。
- `breathingRateEstimate` 只有在 `breathingPresent == true` 时才作为 Route D 的正向证据。
- 呼吸证据会被 `disturbanceScore` 和 `playbackLeakageScore` 主动削弱。

### 3.4 鼾声候选检测

当前实现不是医疗级鼾声识别，而是 sleep-like snore candidate：

1. 基于帧级 `snoreLikeScore`、低频占比、谱质心、音调性和能量门限，筛出候选帧。
2. 将相邻候选帧聚成 0.25s - 2.0s 的短事件。
3. 对事件计算均值分数、低频占比、质心和最终置信度。
4. 仅在满足低频占比、质心上限、置信度门限且播放泄漏不高时，记为鼾声候选。

输出是窗口级摘要，而不是逐事件明细。

### 3.5 扰动与播放泄漏代理

- `disturbanceScore`：由音量方差、摩擦密度、高质心占比组合而成，用于拒绝明显不稳定窗口。
- `playbackLeakageScore`：当前是基于音调性和谱质心的代理指标，用于粗略排除“本 App 正在播音频导致麦克风被污染”的窗口。

说明：

- 当前没有单独的 render reference/AEC 参考通道，因此 `playbackLeakageScore` 只是代理，不是严格回声消除结果。
- iOS 自带 `voice processing` 仍是主降噪手段。

---

## 4. 多模态融合判定

### 4.1 当前实现的三类 gating

当前 Route D 不是宽松的 2/3 投票，而是更保守的门控：

| gating | 满足条件 | 作用 |
|---|---|---|
| `quietInteraction` | `isLocked == true` 且距离最后交互超过阈值，且 `screenWakeCount == 0` | 没有主动使用手机 |
| `stillMotion` | `accelRMS <= motionStillnessThreshold` 且 `stillRatio >= 0.85` | 身体整体稳定 |
| `audioSupportsSleep` | `quietAudio || breathingSupport || snoreSupport` | 音频要么整体安静，要么出现 sleep-like 呼吸/鼾声证据 |

### 4.2 音频支持条件

```swift
quietAudio =
    isSilent ||
    (
        envNoiseLevel <= audioQuietThreshold &&
        envNoiseVariance <= audioVarianceThreshold &&
        frictionEventCount <= frictionEventThreshold &&
        disturbanceScore < disturbanceRejectThreshold * 0.85
    )

breathingSupport =
    breathingPresent &&
    breathingPeriodicityScore >= breathingMinPeriodicityScore &&
    breathingConfidence >= max(breathingMinPeriodicityScore, 0.5) &&
    breathingIntervalCV <= breathingMaxIntervalCV &&
    playbackLeakageScore < playbackLeakageRejectThreshold

snoreSupport =
    snoreCandidateCount > 0 &&
    snoreConfidenceMax >= snoreCandidateMinConfidence &&
    playbackLeakageScore < playbackLeakageRejectThreshold
```

### 4.3 拒绝条件

```swift
audioDisturbance =
    disturbanceScore >= disturbanceRejectThreshold ||
    playbackLeakageScore >= playbackLeakageRejectThreshold ||
    frictionEventCount > max(frictionEventThreshold * 2, 2)
```

只要 `audioDisturbance == true`，即使出现了呼吸/鼾声候选，也不进入候选/确认。

### 4.4 融合判定规则

```swift
if quietInteraction && stillMotion && audioSupportsSleep && !audioDisturbance {
    consecutiveFusionWindows += 1 + snoreBoost
}
```

其中：

- `candidateWindowCount` 达到后进入 `candidate / suspected`
- `confirmWindowCount` 达到后进入 `confirmed`
- 如果 `snoreSupport == true`，可额外增加 `snoreBoostWindowCount` 个窗口进度

因此，当前 v1 的判定逻辑本质上是：

- 交互必须静止
- 体动必须静止
- 音频必须至少给出一种“支持睡眠”的证据
- 同时排除明显干扰和播放污染

### 4.5 打断与回退

任何一条证据通道的打断信号都可以触发回退：

| 打断源 | 条件 | 行为 |
|---|---|---|
| 交互打断 | 非锁屏、最近有交互、出现 screen wake | 回退到 monitoring |
| 体动打断 | `stillMotion == false` | 回退到 monitoring |
| 音频打断 | `audioSupportsSleep == false` 或 `audioDisturbance == true` | 回退到 monitoring |
| 播放污染 | `playbackLeakageScore >= playbackLeakageRejectThreshold` | 明确拒绝当前窗口 |

单窗口的瞬时波动（如一声咳嗽、一次微翻身）不应触发完全回退。只有持续偏离才回退。

### 4.6 入睡时间回溯

与路线 C 一致：`predictedSleepOnset = candidateEnteredTime`。

---

## 5. 参数表

### 5.1 体动参数

与路线 C 共享，见 SPEC 03 §5。

### 5.2 音频参数

| 参数 | 当前默认值 | 说明 |
|---|---|---|
| `audioQuietThreshold` | `0.02` | 安静音量门限 |
| `audioVarianceThreshold` | `0.0003` | 音量方差门限 |
| `frictionEventThreshold` | `1` | 摩擦/翻身阈值 |
| `breathingMinPeriodicityScore` | `0.43` | 呼吸周期性下限 |
| `breathingMaxIntervalCV` | `0.40` | 呼吸节律稳定性上限 |
| `playbackLeakageRejectThreshold` | `0.68` | 播放污染拒绝阈值 |
| `disturbanceRejectThreshold` | `0.62` | 扰动拒绝阈值 |
| `snoreCandidateMinConfidence` | `0.58` | 鼾声候选最小置信度 |
| `snoreBoostWindowCount` | `1` | 鼾声支持时额外推进的窗口数 |

### 5.3 交互参数

| 参数 | 当前默认值 | 说明 |
|---|---|---|
| `interactionQuietThresholdMinutes` | `2` min | 交互停止到判定为安静的时长 |
| `screenWakeCount` | `0` | 当前窗口内不允许主动唤醒 |

### 5.4 融合参数

| 参数 | 当前默认值 | 说明 |
|---|---|---|
| `motionStillnessThreshold` | `0.015` | Route D 体动静止门限 |
| `candidateWindowCount` | `3` | 进入候选所需融合窗口数 |
| `confirmWindowCount` | `6` | 确认入睡所需融合窗口数 |

---

## 6. 判定状态流转

```
monitoring → preSleep → candidate → confirmed
    ↑           |           |
    └───────────┘           |
    └───────────────────────┘  (任意通道打断，回退)
```

与路线 C 状态机结构一致，但进入和退出条件基于更保守的融合 gating。

| 状态 | 进入条件 | 退出条件 |
|---|---|---|
| `monitoring` | Session 开始 | `quietInteraction && stillMotion && audioSupportsSleep` |
| `candidate` | 达到 `candidateWindowCount` | 达到 `confirmWindowCount` → `confirmed`；任一 gating 失效 → `monitoring` |
| `confirmed` | 达到 `confirmWindowCount` | 终态 |

---

## 7. 事件日志

| 事件类型 | payload | 说明 |
|---|---|---|
| `audioMissing` | `windowId` | 当前窗口缺少音频特征 |
| `candidateWindowEntered` | `candidateTime`, `fusionWindows`, `noise`, `breathingRate`, `snoreCount` | 进入候选 |
| `suspectedSleep` | 同上 | 候选持续中 |
| `confirmedSleep` | `predictedTime`, `method: "multimodalFusion"`, `fusionWindows`, `breathingRate`, `snoreCount` | 确认入睡 |
| `sleepRejected` | `reason` | 被打断回退，当前实现的 reason 包括 `interaction_active / motion_active / playback_leakage / audio_disturbance / audio_no_sleep_pattern` |
| `system.audioRuntimeSnapshot` | runtime snapshot payload | 后台麦克风/图状态诊断 |

---

## 8. canRun 条件

```swift
func canRun(condition: DeviceCondition, priorLevel: PriorLevel) -> Bool {
    // 只要体动可用就允许 Route D 启动
    // 如果麦克风不可用，则在 start() 时返回 unavailable prediction
    return condition.hasMotionAccess
}
```

---

## 9. 音频采集的后台策略

麦克风在后台持续采集依赖以下前提：

- Target 必须开启 Background Modes capability，并声明 `audio`。
- Session 开始时保持 `AVAudioSession` 处于活跃状态。
- 当前实现使用 `playAndRecord + voiceChat + VoiceProcessingIO` 全双工图。
- 为了满足 iOS 对“后台仍有活跃音频 I/O”的要求，当前实现保持一条静默输出通路常驻。
- 仅在音频 session 真的活跃且有持续 I/O 时，锁屏/后台后的麦克风保活才稳定。

说明：

- 之前多轮失败的根因不是 Route D 算法本身，而是 target 未正确启用 Background Modes。
- 当前路线不依赖 `voip` background mode。

---

## 10. 验证重点

| 指标 | 对比对象 | 说明 |
|---|---|---|
| 绝对误差中位数 | 路线 A、B、C | 多模态是否显著优于纯体动 |
| 安静清醒误判率 | 路线 C | Route D 是否更少把卧床清醒判成入睡 |
| 呼吸支持命中率 | — | `breathingPresent == true` 的窗口比例 |
| 鼾声候选有效率 | — | `snoreCandidateCount > 0` 的窗口中有多少是真正 sleep-like |
| 播放泄漏触发率 | — | 背景音乐/静默输出是否仍污染判定 |
| 后台麦克风连续性 | — | `routeLossWhileSessionActiveCount / frameStallCount / consecutiveEmptyWindows` |
| 麦克风功耗影响 | — | 长时录制的电量代价 |

---

## 11. 风险与已知局限

| 风险 | 影响 | 缓解策略 |
|---|---|---|
| 用户拒绝麦克风权限 | Route D 返回 unavailable | 降级到 Route C |
| 背景模式配置错误 | 锁屏/后台后直接掉麦 | 强制启用 Background Modes + `audio`，导出 runtime snapshot |
| 用户播放音频或输出残留 | 播放污染麦克风特征 | `voice processing` + `playbackLeakageScore` 拒绝 |
| 呼吸证据偏弱 | 很多窗口无法给出正向呼吸支持 | 保守阈值，允许 quietAudio/snoreSupport 独立成立 |
| 鼾声候选误报 | 非睡眠短测时也可能命中 | 与交互/体动 gating 联合使用，不单独确认 |
| 环境持续风噪/空调/他人声音 | `disturbanceScore` 升高，Route D 难确认 | 后续继续调 `disturbanceScore` 与 snore 策略 |

# SPEC 04: 路线 D - 无 Watch 的 iPhone 多模态融合

> **状态**：草稿，待评审
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
| 体动特征（全部） | MotionProvider | 与路线 C 相同 | 是 |
| 环境噪声水平 | AudioProvider | 环境从活跃转安静 | 是 |
| 环境噪声方差 | AudioProvider | 区分持续静音 vs 间歇声音 | 是 |
| 呼吸频率估计 | AudioProvider | 呼吸变规律、变慢 | 否（增强项）|
| 摩擦/翻身音事件数 | AudioProvider | 区分卧床活动 vs 安静 | 否（增强项）|
| 锁屏状态 | InteractionProvider | 用户交互是否终止 | 是 |
| 最后交互时间 | InteractionProvider | 交互停止时长 | 是 |
| 屏幕唤醒次数 | InteractionProvider | 入睡后不应有主动唤醒 | 是 |
| HealthKit 先验 | Day0 先验 | 入睡时间分布 | 否 |

---

## 3. 音频特征定义

### 3.1 设计原则

- **仅做本地特征提取**，不保存任何原始音频数据。
- 音频帧级别数据在提取特征后立即丢弃。
- 仅输出每窗口（30s）的统计摘要特征。

### 3.2 每窗口音频特征（AudioFeatures）

```swift
struct AudioFeatures {
    let envNoiseLevel: Double       // 窗口内平均 RMS 音量 (dB)
    let envNoiseVariance: Double    // 窗口内音量方差
    let breathingRateEstimate: Double?  // 估计呼吸频率 (次/min)，可能为 nil
    let frictionEventCount: Int     // 窗口内检测到的摩擦/翻身音事件次数
    let isSilent: Bool              // 窗口是否整体安静 (envNoiseLevel < silenceThreshold)
}
```

### 3.3 呼吸频率估计方法

POC 阶段使用简化方法：

1. 对 30 秒窗口内的音频 RMS 包络做低通滤波（截止 0.5 Hz）。
2. 对滤波后信号做自相关或峰值检测。
3. 在 10-20 次/分钟（0.17-0.33 Hz）范围内寻找主频。
4. 若信噪比不足或无明显周期性，输出 `nil`。

> 呼吸频率在环境噪声较大时极不可靠，因此仅作为辅助证据，不作为必要条件。

### 3.4 摩擦音事件检测

POC 阶段使用简化方法：

1. 检测音频 RMS 在短时间内（<2s）从低到高再回低的脉冲模式。
2. 脉冲幅度需超过 `frictionThreshold` 但低于 `loudEventThreshold`（排除说话、音乐等）。
3. 每次匹配记为一个 frictionEvent。

---

## 4. 多模态融合判定

### 4.1 三路证据通道

路线 D 将输入信号组织为三条独立的证据通道，各自产出一个布尔状态：

| 证据通道 | 信号源 | 满足条件 | 含义 |
|---|---|---|---|
| **体动证据** | MotionProvider | 与路线 C 相同的静止判定（consecutiveStillWindows ≥ threshold） | 身体已进入持续静止 |
| **音频证据** | AudioProvider | 环境持续安静 + 无间歇交互声 + 可选呼吸趋稳 | 环境声音符合入睡特征 |
| **交互证据** | InteractionProvider | isLocked == true + timeSinceLastInteraction ≥ threshold + 近期无 screenWake | 用户已完全停止与手机交互 |

### 4.2 音频证据详细条件

```
audioEvidenceMet =
    连续 N 个窗口 isSilent == true
    AND envNoiseVariance < varianceThreshold（排除电视、对话等间歇噪声）
    AND frictionEventCount 在最近 M 个窗口内呈下降趋势或为 0

可选增强：
    IF breathingRateEstimate != nil
    AND 呼吸频率在 12-16 次/min 且稳定（方差 < breathingVarianceThreshold）
    THEN 音频证据置信度 +bonus
```

### 4.3 融合判定规则

采用"投票 + 持续确认"机制：

```
候选入睡条件：
  至少 2/3 证据通道同时满足
  持续 candidateWindowCount 个窗口

确认入睡条件：
  3/3 证据通道同时满足
  持续 confirmWindowCount 个窗口
  
  或

  2/3 证据通道同时满足
  持续 extendedConfirmWindowCount 个窗口（更长的确认窗口）
```

这意味着：

- 如果三路证据全部一致，确认更快。
- 如果只有两路一致（例如体动安静但音频有轻微噪声），需要更长的确认窗口。
- 如果只有 1/3 通道满足，不进入候选状态。

### 4.4 打断与回退

任何一条证据通道的打断信号都可以触发回退：

| 打断源 | 条件 | 行为 |
|---|---|---|
| 体动打断 | 与路线 C §4.3 相同 | 至少回退到 monitoring |
| 音频打断 | envNoiseLevel 突然升高 + 持续 > 1 窗口 | 回退到 monitoring |
| 交互打断 | 屏幕被解锁或有主动交互 | 回退到 monitoring |

单窗口的瞬时波动（如一声咳嗽、一次微翻身）不应触发完全回退。只有持续偏离才回退。

### 4.5 入睡时间回溯

与路线 C 一致：`predictedSleepOnset = candidateEnteredTime`。

---

## 5. 参数表

### 5.1 体动参数

与路线 C 共享，见 SPEC 03 §5。

### 5.2 音频参数

| 参数 | 建议初始值 | 说明 |
|---|---|---|
| `silenceThreshold` | -45 dB (RMS) | 低于此值视为安静 |
| `varianceThreshold` | 3.0 dB | 窗口间音量方差上限 |
| `frictionThreshold` | -35 dB | 摩擦音脉冲的最低幅度 |
| `loudEventThreshold` | -20 dB | 高于此值视为说话/音乐等非体动事件 |
| `audioQuietWindowCount` | 6 个窗口（3 min） | 连续安静窗口数门槛 |
| `breathingVarianceThreshold` | 2.0 次/min | 呼吸频率稳定性判定 |

### 5.3 交互参数

| 参数 | 建议初始值 | 说明 |
|---|---|---|
| `interactionQuietThreshold` | 5 min | 交互停止到判定为"安静"的时长 |
| `screenWakeLimit` | 0 次 | 确认窗口内允许的屏幕唤醒次数 |

### 5.4 融合参数

| 参数 | 建议初始值 | 说明 |
|---|---|---|
| `candidateWindowCount` | 6 个窗口（3 min） | 2/3 通道满足后进入候选需持续的窗口数 |
| `confirmWindowCount` | 10 个窗口（5 min） | 3/3 通道满足后确认入睡的窗口数 |
| `extendedConfirmWindowCount` | 20 个窗口（10 min） | 仅 2/3 通道满足时的延长确认窗口 |

---

## 6. 判定状态流转

```
monitoring → preSleep → candidate → confirmed
    ↑           |           |
    └───────────┘           |
    └───────────────────────┘  (任意通道打断，回退)
```

与路线 C 状态机结构一致，但进入和退出条件基于多通道融合。

| 状态 | 进入条件 | 退出条件 |
|---|---|---|
| `monitoring` | Session 开始 | ≥ 2/3 通道满足 → preSleep |
| `preSleep` | ≥ 2/3 通道初次同时满足 | 持续 candidateWindowCount → candidate；任意通道打断 → monitoring |
| `candidate` | 候选条件持续满足 | 到达 confirm/extendedConfirm 窗口数 → confirmed；打断 → monitoring |
| `confirmed` | 确认条件达成 | 终态 |

---

## 7. 事件日志

| 事件类型 | payload | 说明 |
|---|---|---|
| `candidateWindowEntered` | `time`, `motionMet`, `audioMet`, `interactionMet` | 2/3 通道满足 |
| `suspectedSleep` | `time`, `channelStatus`, `elapsedWindows` | 候选持续中 |
| `confirmedSleep` | `predictedTime`, `method: "multimodal"`, `confirmType: "3of3"/"2of3"` | 确认入睡 |
| `sleepRejected` | `reason`, `breakingChannel`, `signal` | 被打断回退 |
| `custom("channelFlip")` | `channel`, `from`, `to`, `evidence` | 单通道状态变化 |
| `custom("breathingDetected")` | `rate`, `variance`, `confidence` | 检测到稳定呼吸 |

---

## 8. canRun 条件

```swift
func canRun(condition: DeviceCondition, priorLevel: PriorLevel) -> Bool {
    // 体动 + 麦克风都可用时才作为路线 D 运行
    // 如果无麦克风，退化为路线 C
    return condition.hasMotionAccess && condition.hasMicrophoneAccess
}
```

---

## 9. 音频采集的后台策略

麦克风在后台持续采集依赖 `AVAudioSession` 的 background audio 模式：

- 在 `Info.plist` 中声明 `audio` background mode。
- Session 开始时激活 `AVAudioSession`，类别设为 `.playAndRecord` 或 `.record`。
- 不实际录音，仅实时提取特征后丢弃原始帧。
- 如果用户播放了其他音频（如音乐、播客），检测到音量持续偏高时，标记 `externalAudioActive`，暂停音频证据通道（退化为 2 通道判定）。

---

## 10. 验证重点

| 指标 | 对比对象 | 说明 |
|---|---|---|
| 绝对误差中位数 | 路线 A、B、C | 核心：多模态是否显著优于纯体动 |
| "安静清醒"误判率 | 路线 C | 音频通道是否有效降低了此类误判 |
| 三通道 vs 两通道确认占比 | — | 多少比例的夜晚能三通道全亮 |
| 呼吸频率可用率 | — | 多少比例的窗口能成功估计呼吸 |
| 音频证据增量价值 | 路线 C | D 减 C 的误差差值分布 |
| 麦克风功耗影响 | — | 整晚采集的电量消耗 |
| 外部音频干扰率 | — | 多少比例窗口因外部音频退化 |

---

## 11. 风险与已知局限

| 风险 | 影响 | 缓解策略 |
|---|---|---|
| 用户拒绝麦克风权限 | 路线 D 不可用 | 降级到路线 C |
| 环境噪声持续存在（空调、风扇）| 音频安静条件难以满足 | 自适应 silenceThreshold 或退化为 2 通道 |
| 用户播放白噪声/助眠音乐 | 音频通道失效 | 检测外部音频，退化为 2 通道 |
| 呼吸频率在多数场景不可靠 | 增强项无法生效 | 仅作为可选加分项，不影响主判定 |
| 同房间有人说话/打鼾 | 音频证据噪声 | 标注为异常样本，或用 variance 过滤 |

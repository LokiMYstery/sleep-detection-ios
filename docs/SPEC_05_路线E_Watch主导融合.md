# SPEC 05: 路线 E - 有 Watch 的 Watch 主导融合方案

> **状态**：草稿（已根据技术调研更新），待评审
> **前置文档**：SPEC 00 基础框架、SPEC 04 路线 D、《入睡检测 POC 实验路线与验证规划》§4 路线 E、§6 联动方案、《调研_路线E_Watch技术可行性》
> **定位**：本次 POC 最高优先级路线，有 Watch 用户的主推荐实验路线
> **Watch App**：需要同步开发独立 Watch App（详见 §7），后续单独立项

---

## 1. 路线目标

利用 Watch 腕部体动和心率变化，结合 iPhone 侧交互/惯性上下文，显著提升"安静清醒 vs 真正入睡"的区分能力。

**核心实验问题**：

1. Watch 心率下降 + 腕部低动能否形成足够稳定的入睡证据链？
2. 相比所有无 Watch 路线，提升幅度有多大？
3. Watch 数据的实时性和连续性是否满足夜间场景需求？

---

## 2. 输入源

| 输入 | Provider | 用途 | 是否必须 |
|---|---|---|---|
| 腕部加速度 RMS | WatchProvider | 腕动强度 | 是 |
| 腕部持续静止时长 | WatchProvider | 腕部静止检测 | 是 |
| 心率值 | WatchProvider | 心率绝对水平 | 是 |
| 心率趋势 | WatchProvider | 心率下降/稳定/上升 | 是 |
| 锁屏状态 | InteractionProvider | 用户交互是否终止 | 是 |
| 最后交互时间 | InteractionProvider | 交互停止时长 | 是 |
| iPhone 侧体动 | MotionProvider | 手机是否被拿起 | 否（增强项）|
| 历史心率基线 | Day0 先验 | 个体化心率阈值 | 否（强烈推荐）|
| 历史入睡时间 | Day0 先验 | 候选窗口估计 | 否 |

---

## 3. Watch 侧特征定义

### 3.1 每窗口 Watch 特征（WatchFeatures）

```swift
struct WatchFeatures {
    let wristAccelRMS: Double          // 腕部加速度 RMS (g)
    let wristStillDuration: TimeInterval // 当前连续低动时长 (秒)
    let heartRate: Double?             // 当前心率 (bpm)，可能缺失
    let heartRateTrend: HRTrend?       // 心率趋势
    let dataQuality: WatchDataQuality  // 数据质量标记
}

enum HRTrend {
    case dropping        // 持续下降
    case stable          // 稳定
    case rising          // 上升
    case insufficient    // 数据点不足，无法判断
}

enum WatchDataQuality {
    case good            // 数据连续且完整
    case partial         // 有间断但可用
    case unavailable     // 当前窗口无 Watch 数据
}
```

### 3.2 心率趋势计算

> **重要约束**：非 Workout 模式下，系统自动采集心率的间隔约为 5-10 分钟，因此心率趋势必须基于较大的时间窗口计算。

心率趋势基于最近 N 个有效心率样本的线性回归斜率：

| 趋势 | 条件 |
|---|---|
| `dropping` | 斜率 ≤ -0.3 bpm/min 且 R² ≥ 0.2 |
| `stable` | 斜率在 (-0.3, +0.3) bpm/min |
| `rising` | 斜率 ≥ +0.3 bpm/min |
| `insufficient` | 有效心率样本 < 3 个 |

> 心率趋势窗口建议覆盖最近 **15-20 分钟**的样本（预期包含 2-4 个心率样本）。斜率阈值和 R² 要求相比高频采样场景有所放宽，以适应稀疏采样。

### 3.3 个体化心率阈值

路线 E 不使用固定心率阈值，而是基于 Day0 先验的个体化基线：

| 参数 | P1 用户来源 | P2 用户来源 | 兜底值 |
|---|---|---|---|
| `preSleepHRBaseline` | 最近 14 天入睡前 30 分钟平均心率 | 最近 14 天夜间（22:00-06:00）心率中位数 | 70 bpm |
| `sleepHRTarget` | 入睡后 30 分钟的平均心率 | preSleepHRBaseline × 0.85 | preSleepHRBaseline × 0.85 |
| `hrDropThreshold` | 入睡前后心率下降幅度中位数 | 10 bpm | 8 bpm |

---

## 4. 三路证据融合

### 4.1 证据通道定义

路线 E 使用三条证据通道，结构与路线 D 一致但内容不同：

| 证据通道 | 信号源 | 满足条件 | 含义 |
|---|---|---|---|
| **Watch 腕动证据** | WatchProvider | 腕部持续低动 | 手腕已进入静止 |
| **Watch 心率证据** | WatchProvider | 心率下降到接近 sleepHRTarget 或持续下降中 | 生理入睡信号 |
| **iPhone 交互证据** | InteractionProvider + MotionProvider | 交互停止 + 手机未被拿起 | 用户已停止使用设备 |

### 4.2 各通道详细条件

#### Watch 腕动证据

```
wristMotionMet =
    wristAccelRMS < wristStillThreshold
    连续 wristStillWindowCount 个窗口
```

#### Watch 心率证据

```
heartRateMet = 以下任一满足：

  条件 A（绝对水平）：
    heartRate ≤ sleepHRTarget
    持续 hrConfirmWindowCount 个窗口

  条件 B（下降趋势）：
    heartRateTrend == .dropping
    当前心率相对 preSleepHRBaseline 已下降 ≥ hrDropThreshold × 0.6
    持续 hrTrendWindowCount 个窗口
```

> 条件 A 和 B 是"或"的关系。条件 B 允许在心率尚未到达绝对目标但已在明确下降时提前满足，避免等待过久。

#### iPhone 交互证据

```
interactionMet =
    isLocked == true
    AND timeSinceLastInteraction ≥ interactionQuietThreshold
    AND screenWakeCount == 0 (在确认窗口内)
    AND (如果 MotionProvider 可用) 手机侧无拿起动作
```

### 4.3 融合判定规则

```
候选入睡条件：
  Watch 腕动证据 + Watch 心率证据 均满足（2/2 Watch 通道）
  OR
  Watch 任一证据 + iPhone 交互证据 满足（跨端 2/3）
  持续 candidateWindowCount 个窗口

确认入睡条件：
  3/3 通道全部满足，持续 confirmWindowCount 个窗口
  OR
  Watch 腕动 + Watch 心率 满足（iPhone 交互缺失可容忍），持续 extendedConfirmWindowCount 个窗口
```

**设计意图**：

- Watch 双通道对齐（腕动 + 心率）是最强信号，即使 iPhone 侧证据缺失也应能判定。
- iPhone 交互证据作为加速确认的辅助通道，但不是必要条件。
- 这样设计是因为有些用户可能已经把手机放在远处，iPhone 侧信号不可见。

### 4.4 打断与回退

| 打断源 | 条件 | 行为 |
|---|---|---|
| 腕部大幅动作 | wristAccelRMS > wristActiveThreshold | 回退到 monitoring |
| 心率突然上升 | heartRateTrend == .rising 且持续 > 2 窗口 | 回退到 monitoring |
| 手机被解锁使用 | screenWakeCount > 0 + 有主动交互 | 回退到 monitoring |
| Watch 数据中断 | dataQuality == .unavailable 持续 > 5 分钟 | 标记为 partialWatch，不回退但暂停 Watch 通道判定 |

### 4.5 入睡时间回溯

```
predictedSleepOnset = candidateEnteredTime
```

与路线 C/D 一致。

---

## 5. 参数表

### 5.1 Watch 腕动参数

| 参数 | 建议初始值 | 说明 |
|---|---|---|
| `wristStillThreshold` | 0.015 g (RMS) | 腕部低动阈值 |
| `wristStillWindowCount` | 6 个窗口（3 min） | 连续低动窗口数门槛 |
| `wristActiveThreshold` | 0.1 g (RMS) | 高于此值视为活跃临部动作 |

### 5.2 Watch 心率参数

| 参数 | 建议初始值 | 说明 |
|---|---|---|
| `hrConfirmSampleCount` | 2 个连续样本 | 心率到达目标后需持续的样本数（非窗口数，因为心率采样稀疏）|
| `hrTrendMinSamples` | 3 个样本 | 计算心率趋势所需的最少样本数 |
| `hrTrendSampleWindow` | 20 min | 计算心率趋势的采样窗口（扩大到 20min 以覆盖至少 2-4 个样本）|
| `hrSlopeThreshold` | -0.3 bpm/min | 心率下降斜率判定阈值（放宽以适应稀疏采样）|

### 5.3 交互参数

| 参数 | 建议初始值 | 说明 |
|---|---|---|
| `interactionQuietThreshold` | 5 min | 与路线 D 一致 |

### 5.4 融合参数

| 参数 | 建议初始值 | 说明 |
|---|---|---|
| `candidateWindowCount` | 2 个窗口（2-6 min） | Watch 侧窗口间隔 1-3 分钟，2 个窗口约 2-6 分钟 |
| `confirmWindowCount` | 3 个窗口（3-9 min） | 3/3 通道确认窗口 |
| `extendedConfirmWindowCount` | 5 个窗口（5-15 min） | Watch 双通道确认窗口 |

---

## 6. 判定状态流转

```
monitoring → preSleep → candidate → confirmed
    ↑           |           |
    └───────────┘           |
    └───────────────────────┘  (打断回退)
```

与路线 C/D 结构一致。

---

## 7. Watch 数据获取方案

> 本节基于《调研_路线E_Watch技术可行性》的调研结论更新。

### 7.1 技术结论

**必须开发独立 Watch App。** iPhone 侧无法获取腕部加速度数据，且 HealthKit 心率同步延迟过大（分钟级），不满足路线 E 的判定需求。

### 7.2 推荐方案：CMSensorRecorder + HKAnchoredObjectQuery

| 数据 | API | 方式 | 延迟 | 耗电 |
|---|---|---|---|---|
| 腕部加速度 | `CMSensorRecorder` | 系统级后台录制 50Hz，定时提取 | 1-3 分钟 | 极低 |
| 心率 | `HKAnchoredObjectQuery` | 监听系统自动采集的新样本 | 5-10 分钟采样间隔 | 极低 |
| 数据回传 | `WCSession` | transferUserInfo / sendMessage | 取决于连接状态 | 低 |

**不采用的方案及原因**：

| 方案 | 不采用原因 |
|---|---|
| 仅 iPhone 读 HealthKit | 无法获取加速度，心率延迟过大 |
| HKWorkoutSession | 高频采样导致整晚耗电 40%+，影响 Activity Rings |
| WKExtendedRuntimeSession | 夜间 6-8 小时场景下 CPU 预算超标，大概率被系统终止 |

### 7.3 Watch 侧采集流程

```
iPhone Session 开始
    ↓
iPhone 通过 WCSession 发送 startSession 消息
    ↓
Watch App 启动：
  ├── CMSensorRecorder.recordAccelerometer(forDuration: sessionDuration)
  └── HKAnchoredObjectQuery 开始监听心率样本
    ↓
定时任务（每 1-3 分钟触发）：
  ├── 从 CMSensorRecorder 提取最新加速度数据
  ├── 计算窗口级特征摘要（wristAccelRMS, wristStillDuration）
  ├── 附加最新心率样本
  └── 通过 WCSession 回传 WatchWindowPayload 到 iPhone
    ↓
iPhone Session 结束 → 发送 stopSession 消息
    ↓
Watch App 停止录制并清理
```

> **关键差异**：Watch App 不需要保持前台运行。`CMSensorRecorder` 是系统级录制，app 被挂起后仍会继续存储加速度数据。app 只需在定时唤醒时提取和回传。

### 7.4 Watch 回传数据结构

```swift
struct WatchWindowPayload: Codable {
    let windowId: Int
    let startTime: Date
    let endTime: Date              // 窗口间隔 1-3 分钟
    let wristAccelRMS: Double
    let wristStillDuration: TimeInterval
    let heartRate: Double?         // 最新心率，可能缺失（采样间隔 5-10min）
    let heartRateSamples: [HRSample]  // 窗口内所有心率样本（可能为空）
    let dataQuality: String        // "good", "partial", "unavailable"
}

struct HRSample: Codable {
    let timestamp: Date
    let bpm: Double
}
```

### 7.5 Watch 断连处理

| 场景 | 处理 |
|---|---|
| Watch 短暂断连（< 5 分钟） | CMSensorRecorder 继续录制，恢复后补传缓存数据 |
| Watch 持续断连（> 10 分钟） | 暂停 Watch 证据通道，记录事件，仅用 iPhone 交互证据 |
| Watch 断连后恢复 | 从 CMSensorRecorder 提取断连期间数据并补传 |
| Watch 整晚不可用 | 标记为"无 Watch 数据样本"，路线 E 当晚不产出结果 |

> CMSensorRecorder 的数据最多保留 3 天，断连恢复后有充足余量回补。

### 7.6 Watch App 最小实现范围

Watch App 将作为独立项目单独开发。最小实现范围：

| 模块 | 职责 | 复杂度 |
|---|---|---|
| Session 响应 | 接收 iPhone start/stop 消息 | 低 |
| 加速度录制 | 调用 CMSensorRecorder API | 低 |
| 加速度提取 | 定时提取 + 计算窗口特征 | 中 |
| 心率监听 | HKAnchoredObjectQuery | 低 |
| 数据回传 | WCSession 发送特征摘要 | 低 |
| 本地缓存 | iPhone 不可达时缓存待补传 | 低 |
| UI | 最小 UI（显示 Session 状态）| 低 |

预计代码量 300-500 行。

### 7.7 Watch 侧窗口间隔说明

由于 CMSensorRecorder 数据提取有最多 3 分钟延迟，Watch 侧的窗口间隔与 iPhone 侧不同：

| 侧 | 窗口间隔 | 说明 |
|---|---|---|
| iPhone（MotionProvider 等）| 30 秒 | 实时采集，无延迟 |
| Watch（加速度特征）| 1-3 分钟 | 受 CMSensorRecorder 提取延迟约束 |
| Watch（心率样本）| 5-10 分钟 | 受系统自动采集间隔约束 |

iPhone 侧 RouteEngine 在处理 Watch 特征时，需要容忍窗口不对齐：对每个 iPhone 窗口，使用最近可用的 Watch 特征窗口。

---

## 8. 事件日志

| 事件类型 | payload | 说明 |
|---|---|---|
| `candidateWindowEntered` | `time`, `wristMotionMet`, `heartRateMet`, `interactionMet` | 候选条件满足 |
| `suspectedSleep` | `time`, `channelStatus`, `heartRate`, `hrTrend` | 候选持续中 |
| `confirmedSleep` | `predictedTime`, `method: "watchFusion"`, `confirmType`, `heartRateAtConfirm` | 确认入睡 |
| `sleepRejected` | `reason`, `breakingChannel`, `signal` | 被打断回退 |
| `custom("hrBaselineSet")` | `preSleepBaseline`, `sleepTarget`, `source` | 心率基线初始化 |
| `custom("watchConnected")` | `watchReachable`, `dataQuality` | Watch 连接状态变化 |
| `custom("watchDisconnected")` | `duration`, `lastWindowId` | Watch 断连事件 |
| `custom("watchDataBackfill")` | `windowRange`, `sampleCount` | Watch 断连恢复后补传 |

---

## 9. canRun 条件

```swift
func canRun(condition: DeviceCondition, priorLevel: PriorLevel) -> Bool {
    return condition.hasWatch && condition.watchReachable
}
```

路线 E 要求 Watch 已配对且当前可达。如果 Watch 不可用，不启动路线 E。

---

## 10. 验证重点

| 指标 | 对比对象 | 说明 |
|---|---|---|
| 绝对误差中位数 | 路线 A-D | **核心**：是否显著优于所有无 Watch 路线 |
| 10 分钟命中率 | 路线 D | 有 Watch 的精度天花板 |
| 心率下降→入睡的时间关系 | — | 观察心率下降与真实入睡的稳定关联性 |
| Watch 数据完整率 | — | 整晚 CMSensorRecorder 数据完整的比例 |
| 心率样本密度 | — | 每晚实际获得的心率样本间隔分布 |
| Watch 断连频率与时长 | — | 评估夜间 WCSession 通信的稳定性 |
| P1 vs P2 先验差异 | — | 个体化心率基线的价值 |
| 腕动 vs 心率的各自贡献 | — | 对比单用腕动/单用心率/双通道的表现 |
| 数据延迟对判定的影响 | — | 1-3 分钟加速度延迟是否导致可观测的误差增量 |
| Watch 整晚耗电量 | — | CMSensorRecorder 方案的电量消耗（预期 <15%）|

---

## 11. 风险与已知局限

| 风险 | 影响 | 缓解策略 |
|---|---|---|
| CMSensorRecorder 数据提取有 1-3 分钟延迟 | 判定时间不如秒级实时精确 | 入睡判定本身是分钟级，影响可控；回溯到 candidate 起始时间 |
| 心率采样间隔 5-10 分钟 | 心率趋势信号稀疏 | 放宽趋势窗口到 15-20min，降低 R² 要求；允许腕动先行判定 |
| 心率个体差异极大 | 固定兜底阈值不可靠 | Day0 个体化基线；P3 用户使用更宽松阈值 |
| Watch 定时唤醒不保证准确间隔 | 数据回传间隔不均匀 | iPhone 侧容忍窗口不对齐，使用最近可用数据 |
| WCSession 夜间传输不稳定 | iPhone 收不到 Watch 数据 | Watch 本地缓存，恢复后从 CMSensorRecorder 补传 |
| Watch 电量不足 | 夜间 Watch 关机 | CMSensorRecorder 方案耗电极低，预期 <15%；POC 阶段观察实际消耗 |
| 用户睡前摘下 Watch | 无腕动数据 | 标记为"无 Watch 数据样本" |

---

## 12. 与其他路线的实验对比设计

路线 E 在同一晚与路线 A-D 并行运行，但有一个独特的分析维度：

- **消融实验**：在离线分析时，可以单独关闭腕动或单独关闭心率，观察各自的贡献。
  - 仅腕动 + iPhone：接近"Watch 版路线 C"
  - 仅心率 + iPhone：验证心率单通道的能力
  - 腕动 + 心率 + iPhone：完整路线 E

- **与路线 D 的纵向对比**：如果路线 D 和路线 E 在同一晚产出结果，可以精确计算 Watch 的增量价值。

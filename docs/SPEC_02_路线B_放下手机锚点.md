# SPEC 02: 路线 B - 无 Watch 的"放下手机锚点"估计

> **状态**：草稿，待评审
> **前置文档**：SPEC 00 基础框架、SPEC 01 路线 A、《入睡检测 POC 实验路线与验证规划》§4 路线 B
> **定位**：无 Watch 场景下的轻量实时路线，权限和侵入性最低

---

## 1. 路线目标

利用手机惯性信号识别"用户真正放下手机准备入睡"的时刻，将其作为锚点，再结合先验潜伏时间估计入睡。

**核心实验问题**：仅用"交互停止 + 惯性趋稳"这一轻量信号组合，不要求手机持续放在床上，能否给出比路线 A 更优的预测？

**与路线 A 的关系**：路线 B = 路线 A 的 anchorTime 替换为实时检测的"放下手机时刻"。

---

## 2. 输入源

| 输入 | Provider | 用途 | 是否必须 |
|---|---|---|---|
| 加速度/陀螺仪/device motion | MotionProvider | 检测放下动作与趋稳 | 是 |
| 锁屏状态 | InteractionProvider | 辅助判断交互停止 | 是 |
| 最后交互时间 | InteractionProvider | 辅助判断交互停止 | 是 |
| 用户估计的入睡潜伏时间 | 设置页 / 先验 | 计算锚点到入睡的偏移 | 是 |
| HealthKit 历史 | Day0 先验（P1）| 锚点→入睡差值分布 | 否 |
| 应用内历史 | 前 N 晚 Session | 锚点→入睡差值分布 | 否 |

---

## 3. 核心概念："放下手机锚点"

### 3.1 定义

"放下手机锚点"（putDownAnchor）是指用户在当晚 Session 期间最后一次将手机放置到静止位置的时刻。它不要求手机放在床上——可以是床头柜、地面或任何位置。

### 3.2 检测逻辑

放下手机的判定依赖两个条件同时满足：

```
条件 1：交互已停止
  isLocked == true && timeSinceLastInteraction ≥ interactionQuietThreshold

条件 2：惯性信号趋稳
  连续 N 个窗口的加速度 RMS 低于 stillnessThreshold
  且无拿起动作特征（见 §3.3）
```

当两个条件持续同时满足 `confirmDuration` 后，记录当前时刻为 `putDownAnchor`。

### 3.3 拿起动作检测

路线 B 的关键不是"识别放下"，而是"识别拿起"以推翻之前的锚点。

拿起动作的特征信号：

| 特征 | 描述 | 阈值方向 |
|---|---|---|
| `accelRMS` 突增 | 加速度 RMS 从低值突然升高 | > pickupThreshold |
| `attitudeChangeRate` 突增 | 姿态（pitch/roll）变化速率突然增大 | > attitudeThreshold |
| `peakCount` 增加 | 单窗口内加速度峰值次数增加 | ≥ peakCountThreshold |

检测到任一拿起特征时：

1. 清除当前 `putDownAnchor`。
2. 回到等待状态，重新检测下一次放下。
3. 发布 `custom("anchorInvalidated")` 事件。

### 3.4 锚点确认的最终判定

由于用户可能多次拿起放下手机，路线 B 关注的是"最终一次放下"。处理策略：

- 每次检测到新的放下，更新 `putDownAnchor` 并重新计算预测。
- 每次检测到拿起，清除锚点，预测回退到路线 A 的基础预测。
- 最终预测结果以 Session 结束时的最后一个有效锚点为准。

---

## 4. 预测算法

### 4.1 预测公式

```
predictedSleepOnset = putDownAnchor + putDownToSleepLatency + aggressivenessOffset
```

### 4.2 putDownToSleepLatency 的确定

| 优先级 | 来源 | 说明 |
|---|---|---|
| 1 | P1 先验 | 最近 14 天"最后放下手机时刻"到 HealthKit 入睡时间的中位差值 |
| 2 | 应用内历史 | 最近 7 晚有标签 Session 的锚点→入睡中位差值 |
| 3 | 用户输入 | `estimatedLatency` 映射值（与路线 A 共享）|

> **注**：P1 先验中的"最后放下手机时刻"需要在 Day0 先验探测时从 HealthKit 睡眠样本反推。具体方法是：取每晚入睡前的最后一次屏幕使用记录结束时间（如有 Screen Time API 支持）或直接使用用户输入的 `estimatedLatency`。

### 4.3 无锚点时的降级

如果整个 Session 期间始终未检测到有效的 `putDownAnchor`（例如用户一直拿着手机或手机信号不稳定），路线 B 降级为路线 A 的预测逻辑。

---

## 5. 参数表

| 参数 | 建议初始值 | 说明 |
|---|---|---|
| `interactionQuietThreshold` | 2 min | 交互停止到判定为"安静"的最短时长 |
| `stillnessThreshold` | 0.02 g (RMS) | 加速度 RMS 低于此值视为静止 |
| `confirmDuration` | 3 个窗口（90s） | 条件持续满足后确认放下 |
| `pickupThreshold` | 0.15 g (RMS) | 加速度 RMS 超过此值疑似拿起 |
| `attitudeThreshold` | 15°/s | 姿态变化速率超过此值疑似拿起 |
| `peakCountThreshold` | 3 次/窗口 | 单窗口加速度峰值次数 |

> 所有参数在 POC 阶段应支持通过设置页手动调整，以便实验期间快速迭代。

---

## 6. 判定状态流转

```
idle → monitoring → anchorDetected → predicted → confirmed
                        ↓                ↑
                    anchorInvalidated ────┘ (拿起手机，回退)
```

| 状态 | 触发条件 | 事件 |
|---|---|---|
| `idle` | Session 启动 | — |
| `monitoring` | MotionProvider 和 InteractionProvider 启动 | — |
| `anchorDetected` | 放下条件持续满足 confirmDuration | `candidateWindowEntered` |
| `predicted` | 锚点确认，计算出预测时间 | `predictionUpdated` |
| `confirmed` | 到达预测时间 | `confirmedSleep` |
| _(回退)_ | 检测到拿起动作 | `sleepRejected` + `custom("anchorInvalidated")` |

---

## 7. 事件日志

| 事件类型 | payload 字段 | 说明 |
|---|---|---|
| `candidateWindowEntered` | `putDownTime`, `accelRMS`, `stillWindowCount` | 检测到放下，开始确认 |
| `predictionUpdated` | `putDownAnchor`, `latencySource`, `latency`, `predictedTime` | 锚点确认，预测生成 |
| `confirmedSleep` | `predictedTime`, `method: "putDownAnchor"` | 到达预测时间 |
| `sleepRejected` | `reason: "pickup_detected"`, `pickupTime` | 拿起手机，推翻之前判定 |
| `custom("anchorInvalidated")` | `previousAnchor`, `pickupSignal` | 锚点被推翻的详细信号 |
| `custom("fallbackToRouteA")` | `reason` | 降级到路线 A |

---

## 8. canRun 条件

```swift
func canRun(condition: DeviceCondition, priorLevel: PriorLevel) -> Bool {
    return condition.hasMotionAccess
}
```

路线 B 仅需要运动传感器（iOS 上无需弹窗授权），因此在几乎所有设备上都可运行。

---

## 9. 验证重点

| 指标 | 对比对象 | 说明 |
|---|---|---|
| 绝对误差中位数 | 路线 A | 核心指标：是否显著优于纯定时估计 |
| 锚点检测准确率 | — | 放下/拿起的判定是否准确 |
| 锚点次数分布 | — | 每晚平均触发几次放下→拿起循环 |
| 最终锚点→真实入睡差值 | — | 验证 putDownToSleepLatency 假设 |
| 无锚点降级率 | — | 多少比例夜晚无法产生有效锚点 |
| 参数敏感性 | — | stillnessThreshold / confirmDuration 变化对结果的影响 |

---

## 10. 风险与已知局限

| 风险 | 影响 | 缓解策略 |
|---|---|---|
| 用户锁屏后长时间清醒 | 锚点→入睡差值方差大 | 依赖 latency 先验和历史修正 |
| 手机放在远处或充电座 | 惯性信号无法监测 | 降级到路线 A |
| iOS 后台运动采集受限 | 锁屏后无法持续监测 | POC 阶段前台为主；后台 spike 验证 |
| 双人场景对方拿手机 | 误判为拿起 | POC 阶段不处理，标注为异常样本 |

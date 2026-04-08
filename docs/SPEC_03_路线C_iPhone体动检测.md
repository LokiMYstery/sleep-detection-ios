# SPEC 03: 路线 C - 无 Watch 的 iPhone 体动检测

> **状态**：草稿，待评审
> **前置文档**：SPEC 00 基础框架、SPEC 02 路线 B、《入睡检测 POC 实验路线与验证规划》§4 路线 C
> **定位**：手机放在床面/枕边时，通过持续运动信号逼近真实入睡

---

## 1. 路线目标

当手机放在床面、枕边或床垫可感知的位置时，利用持续的运动信号变化判定用户从"清醒卧床"过渡到"入睡"。

**核心实验问题**：手机接触床面后，体动信号本身是否足以区分"安静清醒"与"真正入睡"？

**与路线 B 的边界**：
- 路线 B 只需识别"放下手机"这一事件，手机可在床头柜等非床面位置。
- 路线 C 要求手机持续放在可反映人体体动的位置，做的是持续实时检测，目标是逼近入睡时刻，而非仅估计。

---

## 2. 输入源

| 输入 | Provider | 用途 | 是否必须 |
|---|---|---|---|
| 加速度 RMS | MotionProvider | 体动强度 | 是 |
| 加速度峰值次数 | MotionProvider | 翻身/大幅体动计数 | 是 |
| 姿态变化频率 | MotionProvider | 微翻身与姿态调整 | 是 |
| 持续静止时长 | MotionProvider | 核心判定信号 | 是 |
| 锁屏状态 | InteractionProvider | 辅助判断（非核心）| 否 |
| HealthKit 先验 | Day0 先验 | 入睡潜伏期先验 | 否 |

---

## 3. 体动特征定义

### 3.1 每窗口特征（MotionFeatures 细化）

```swift
struct MotionFeatures {
    let accelRMS: Double            // 窗口内加速度三轴合成 RMS (g)
    let peakCount: Int              // 加速度超过 peakThreshold 的次数
    let attitudeChangeRate: Double  // pitch+roll 变化速率 (°/s)
    let maxAccel: Double            // 窗口内最大加速度值
    let stillRatio: Double          // 窗口内低于 stillnessThreshold 的采样占比 (0-1)
}
```

### 3.2 跨窗口派生特征

在判定时还需计算以下跨窗口特征：

| 特征 | 计算方式 | 用途 |
|---|---|---|
| `consecutiveStillWindows` | 连续 stillRatio ≥ 0.9 的窗口数 | 持续静止检测 |
| `movementTrend` | 最近 10 个窗口的 accelRMS 滑动均值斜率 | 运动趋势下降检测 |
| `lastSignificantMovement` | 最近一次 peakCount ≥ 2 的窗口时间 | 距最后翻身的时间 |
| `microMovementRate` | 最近 10 个窗口中 peakCount == 1 的比例 | 区分完全静止 vs 微动 |

---

## 4. 判定算法

### 4.1 核心思路

入睡判定采用"持续静止 + 运动趋势下降"双条件确认：

```
入睡候选条件：
  consecutiveStillWindows ≥ stillWindowThreshold
  AND movementTrend ≤ 0（运动不在上升）
  AND timeSinceLastSignificantMovement ≥ significantMovementCooldown

入睡确认条件：
  入睡候选持续 confirmDuration 且未被打断
```

### 4.2 状态机

```
monitoring → preSleep → candidate → confirmed
    ↑           |           |
    └───────────┘           |
    └───────────────────────┘  (体动打断，回退)
```

| 状态 | 进入条件 | 退出条件 |
|---|---|---|
| `monitoring` | Session 开始 | 运动趋势开始下降 |
| `preSleep` | movementTrend ≤ 0 且 accelRMS 低于活跃阈值 | 连续静止窗口达标 → candidate；突发体动 → monitoring |
| `candidate` | 入睡候选条件满足 | 持续 confirmDuration → confirmed；显著体动 → monitoring |
| `confirmed` | 候选持续未被打断 | 终态（本晚不再回退）|

### 4.3 打断与回退

| 打断信号 | 条件 | 行为 |
|---|---|---|
| 显著体动 | peakCount ≥ 3 或 accelRMS > activeThreshold | 回退到 monitoring，清零静止计数 |
| 中等体动 | peakCount == 2 或单窗口 accelRMS 短暂升高 | 如在 candidate 状态，延长确认窗口但不立即回退 |
| 微动 | peakCount ≤ 1 且 accelRMS 仅轻微升高 | 不影响状态流转（睡眠中正常微动）|

### 4.4 入睡时间回溯

当状态到达 `confirmed` 时，预测入睡时间不是当前时刻，而是回溯到 `candidate` 状态的起始时刻：

```
predictedSleepOnset = candidateEnteredTime
```

这更符合实际：真正入睡发生在持续静止开始时，而不是确认结束时。

---

## 5. 参数表

| 参数 | 建议初始值 | 说明 |
|---|---|---|
| `stillnessThreshold` | 0.01 g (RMS) | 低于此值视为静止（比路线 B 更严格）|
| `stillWindowThreshold` | 6 个窗口（3 min）| 连续静止窗口数达标门槛 |
| `confirmDuration` | 10 个窗口（5 min） | 候选状态需持续的窗口数 |
| `significantMovementCooldown` | 4 min | 最后一次显著体动距今需超过此时长 |
| `activeThreshold` | 0.08 g (RMS) | 高于此值视为活跃体动 |
| `peakThreshold` | 0.05 g | 单次加速度峰值检测阈值 |
| `trendWindowSize` | 10 个窗口 | 计算运动趋势的滑动窗口大小 |

> 所有参数支持设置页手动调整。

---

## 6. 事件日志

| 事件类型 | payload | 说明 |
|---|---|---|
| `candidateWindowEntered` | `candidateTime`, `consecutiveStill`, `accelRMS` | 进入候选状态 |
| `suspectedSleep` | `candidateTime`, `elapsedSinceCandidate` | 候选持续中 |
| `confirmedSleep` | `predictedTime`, `method: "bodyMovement"`, `totalStillDuration` | 确认入睡 |
| `sleepRejected` | `reason`, `interruptSignal`, `accelRMS`, `peakCount` | 体动打断回退 |
| `custom("trendShift")` | `direction`, `oldTrend`, `newTrend` | 运动趋势转折点 |

---

## 7. canRun 条件

```swift
func canRun(condition: DeviceCondition, priorLevel: PriorLevel) -> Bool {
    return condition.hasMotionAccess
}
```

与路线 B 相同的权限需求。但路线 C 在实际使用中有一个隐含前提：手机需放在可感知人体体动的位置。此前提无法通过代码检测，需在 POC 阶段由测试者自行保证，并在 Session 元数据中手动标注手机摆放位置。

---

## 8. 手机摆放位置标注

Session 开始时或结束时，建议记录手机摆放位置（手动选择）：

| 选项 | 值 |
|---|---|
| 枕边 | `pillow` |
| 床面（身旁）| `bedSurface` |
| 床头柜 | `nightstand` |
| 充电中（固定位置）| `chargingFixed` |
| 其他 | `other` |

此标注用于后续分析不同摆放条件下路线 C 的表现差异。

---

## 9. 验证重点

| 指标 | 对比对象 | 说明 |
|---|---|---|
| 绝对误差中位数 | 路线 A、B | 是否优于锚点估计 |
| "安静清醒"误判率 | — | 核心风险指标：躺着不动但没睡着的比例 |
| 不同摆放位置的误差分布 | — | 枕边 vs 床面 vs 床头柜 |
| 入睡候选→确认失败率 | — | 多少次进入 candidate 后被打断 |
| 参数敏感性 | — | stillWindowThreshold 和 confirmDuration 的影响 |
| 双人同床噪声 | — | 如适用，标注并分析 |

---

## 10. 风险与已知局限

| 风险 | 影响 | 缓解策略 |
|---|---|---|
| "安静清醒"误判为入睡 | 提前判睡，误差偏大 | 路线 D 引入音频等多模态信号来缓解 |
| 手机不在床面 | 无法感知体动 | 降级到路线 B 逻辑 |
| 床垫阻尼差异大 | 阈值不通用 | POC 阶段固定测试环境，记录床垫类型 |
| iOS 后台运动采集受限 | 长时间后台可能断采 | 前台为主 + 后台 spike 验证 |
| 睡眠中正常翻身 | 不应触发回退 | 用中等/微动分级处理 |

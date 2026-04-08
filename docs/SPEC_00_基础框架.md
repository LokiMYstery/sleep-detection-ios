# SPEC 00：入睡检测 POC 基础框架

> **状态**：草稿，待评审  
> **前置文档**：《入睡检测 POC 实验路线与验证规划》  
> **范围**：本文档定义所有路线共用的基础设施，不涉及任何路线专属的检测算法。

---

## 1. 概述

本 SPEC 定义入睡检测 POC 的基础运行框架，覆盖以下职责：

1. **Session 生命周期管理**：从"开始当晚记录"到"次日结算"的完整状态流转。
2. **数据采集管道**：传感器抽象、采集调度与功耗控制。
3. **实时事件管道**：路线判定事件的统一发布与日志记录。
4. **并行路线执行框架**：同一 Session 内多路线并行计算的组织方式。
5. **存储与导出**：Session 级和 Window 级数据的本地持久化与导出。
6. **Day0 先验探测与参数初始化**：HealthKit 可用性分级与先验提取。

---

## 2. Session 生命周期

### 2.1 Session 定义

一条 Session 代表一个完整的"当晚实验记录"，是 POC 数据的最小组织单位。

| 属性 | 说明 |
|---|---|
| `sessionId` | UUID，创建时生成 |
| `date` | 当晚日历日期（以 session 开始时间所在日历日为准）|
| `startTime` | 用户点击"开始当晚记录"的时间戳 |
| `endTime` | 填入方式见 §2.2 |
| `deviceCondition` | 启动时的设备可用性快照 |
| `priorLevel` | Day0 先验分级结果（P1/P2/P3），见 §7 |
| `status` | 当前生命周期状态 |

### 2.2 生命周期状态

```
created → recording → pendingTruth → labeled → archived
                 ↓
            interrupted → pendingTruth
```

| 状态 | 含义 | 转换条件 |
|---|---|---|
| `created` | Session 对象已创建，采集尚未启动 | 用户点击"开始当晚记录" |
| `recording` | 正在采集，路线正在并行计算 | 采集管道启动成功 |
| `pendingTruth` | 当晚记录已结束，等待次日 HealthKit 真值 | 用户手动结束 / 次日自动结束 |
| `interrupted` | 采集过程中被意外中断（闪退/系统杀进程）| 见 §2.4 |
| `labeled` | 已回填 HealthKit 真值，误差已计算 | 次日检测到可用睡眠记录 |
| `archived` | 已导出或标记为历史样本 | 用户手动归档 |

**结束时机**：

- 用户手动点击"结束当晚记录"。
- 次日早晨自动结束（可设定一个截止时间，如次日 12:00）。
- 如果用户忘记结束，系统在截止时间自动将 status 转为 `pendingTruth`。

### 2.3 Session 内的时间线

```
startTime ──┬── 采集开始
             │   路线并行计算
             │   实时事件日志
             │   ...
endTime ─────┴── 采集停止
             │
             │   等待次日真值
             │
truthFill ───── 回填 HealthKit 标签，计算误差
```

### 2.4 闪退与中断恢复

#### 问题场景

- 应用在 `recording` 状态下被系统杀进程或发生闪退。
- 用户手动杀掉应用进程。
- 设备意外关机或重启。

#### 中断检测

应用启动时检查是否存在处于 `recording` 状态的 Session：

1. 读取最近一条 `session.json`，如果 `status == "recording"` 且 `endTime` 为空，则判定为中断 Session。
2. 将该 Session 的 `status` 更新为 `interrupted`，并记录 `interruptedAt`（取已持久化的最后一条 window 或 event 的时间戳）。

#### 数据抢救

由于采用 JSONL 逐行追加写入（见 §6.1），中断前已刷盘的数据天然保留：

- `windows.jsonl`：已写入的窗口完整可用，最后一个窗口可能不完整（丢弃即可）。
- `events.jsonl`：已写入的事件完整可用。
- `session.json`：启动时已写入，恢复时更新 status 和 interruptedAt。
- 各路线的内存态预测结果会丢失，但可从 events.jsonl 中的 `confirmedSleep` / `suspectedSleep` 事件回溯。

#### 恢复策略

应用检测到中断 Session 后，提供以下处理：

| 选项 | 行为 |
|---|---|
| **保留并结算** | 将 `interrupted` Session 直接转为 `pendingTruth`，保留已有数据等待次日真值回填。从 events 中恢复各路线最后的预测结果写入 `predictions.json`。|
| **丢弃** | 标记为 `archived`，并在元数据中标记 `discardReason: "interrupted_by_user"`，不参与后续评估。|

**POC 阶段默认策略**：自动执行“保留并结算”。中断 Session 会在元数据中增加标记字段：

```json
{
  "interrupted": true,
  "interruptedAt": "2026-04-08T02:15:00+08:00",
  "recordedWindowCount": 142,
  "dataCompleteness": "partial"
}
```

#### 写入保障

为减少中断导致的数据损失，采集管道需遵循以下写入策略：

- `session.json`：Session 创建时立即写入，状态变更时立即更新。
- `windows.jsonl`：每个窗口完成后立即追加写入并 flush。
- `events.jsonl`：每个事件产生后立即追加写入并 flush。
- 不依赖「Session 结束时批量保存」，所有关键数据做到实时持久化。

> **设计原则**：宁可写入频率高一点、多一些磁盘 IO，也不接受因中断丢失整晚数据。POC 阶段数据量小，实时 flush 的性能开销可忽略。

---

## 3. 数据采集管道

### 3.1 设计原则

- **传感器抽象**：每类传感器封装为独立的 `SensorProvider`，统一暴露 `start / stop / currentWindow` 接口。
- **固定时间窗（Window）**：采集数据按固定长度窗口（建议 30 秒）切片，每个窗口产出一组特征摘要。
- **路线无关**：采集管道不知道路线逻辑；路线从统一的特征窗口流中消费数据。
- **按需启用**：根据 `deviceCondition` 决定启用哪些 SensorProvider，而非硬编码。

### 3.2 SensorProvider 清单

| Provider | 输入源 | 产出特征（每窗口）| 需要权限 | 适用路线 |
|---|---|---|---|---|
| `MotionProvider` | CMMotionManager (accelerometer + gyroscope + device motion) | accelRMS, peakCount, attitudeChangeRate, stillDuration | Motion（无弹窗）| B, C, D, E |
| `AudioProvider` | AVAudioEngine（本地特征提取，不录音）| breathingRateEstimate, envNoiseLevel, envNoiseVariance, frictionEventCount | Microphone | D |
| `InteractionProvider` | UIApplication 通知 + screen lock 监听 | isLocked, timeSinceLastInteraction, screenWakeCount | 无 | A, B, D |
| `WatchProvider` | Watch Connectivity / HealthKit 实时查询 | wristAccelRMS, wristStillDuration, heartRate, heartRateTrend | HealthKit + Watch | E |
| `HealthKitHistoryProvider` | HealthKit query（非实时，仅 session 启动时读取）| 历史睡眠样本、心率基线等 | HealthKit | Day0 先验 |

> **注**：`WatchProvider` 的具体采集方式取决于路线 E SPEC 中的技术可行性验证结论。当前按"需要 Watch app 配合"预留接口，但允许后续降级为"仅读 HealthKit"。

### 3.3 Window 结构

```swift
struct FeatureWindow {
    let windowId: Int              // 从 session 开始后的窗口序号
    let startTime: Date
    let endTime: Date
    let duration: TimeInterval     // 默认 30s
    let motion: MotionFeatures?    // 可选，取决于 provider 是否启用
    let audio: AudioFeatures?
    let interaction: InteractionFeatures?
    let watch: WatchFeatures?
}
```

每个子特征结构体的字段定义将在各路线 SPEC 中细化。基础框架只定义容器和生命周期。

### 3.4 采集频率与功耗控制

| 参数 | 建议值 | 说明 |
|---|---|---|
| 运动采样率 | 10 Hz | CMMotionManager 更新频率，足以捕捉翻身和拿起手机 |
| 音频帧长 | 1024 samples @ 16kHz | 本地特征提取的最小帧，不保存原始音频 |
| 窗口长度 | 30 秒 | 特征摘要的最小聚合单位 |
| 窗口滑动方式 | 非重叠 | 每 30 秒产出一个窗口，POC 阶段不做重叠 |
| 心率查询间隔 | 依赖 Watch 回传频率 | 见路线 E SPEC |

**功耗策略**（POC 阶段简化版）：

- 白天不采集，仅在 `recording` 状态下运行传感器。
- 麦克风在后台可通过 `AVAudioSession` 的 background audio 能力保持采集。
- 运动传感器在后台可通过 background processing 短暂续命，但长时间后台需依赖 `CMMotionActivityManager` 或定时唤醒策略。
- **POC 阶段可接受前台采集为主 + 后台尽力而为的策略**，不追求完美后台续航。

> ⚠️ **待确认**：iOS 后台运动传感器的持续采集能力边界，需要在开发阶段做 spike 验证。如果后台无法持续采集加速度，路线 C/D 可能需要调整为"前台采集 + 后台降级到纯交互监测"。

---

## 4. 实时事件管道

### 4.1 目的

各路线在判定过程中产生的状态变化事件需要统一记录，用于：

- 事后回放判定过程，分析误判原因。
- 调试和可视化各路线的判定时间线。
- 为评估框架提供判定证据链。

### 4.2 事件结构

```swift
struct RouteEvent {
    let timestamp: Date
    let routeId: RouteId           // .A, .B, .C, .D, .E
    let eventType: RouteEventType
    let payload: [String: Any]     // 路线特定的证据数据
}

enum RouteEventType {
    case candidateWindowEntered    // 进入候选入睡窗口
    case suspectedSleep            // 疑似入睡
    case confirmedSleep            // 确认入睡
    case sleepRejected             // 之前的疑似被推翻
    case predictionUpdated         // 预测时间更新（路线 A 的定时更新等）
    case sensorUnavailable         // 某传感器不可用
    case custom(String)            // 路线自定义事件
}
```

### 4.3 事件发布方式

- 使用简单的观察者模式：`EventBus` 单例，各路线 `post` 事件，Session 管理器统一订阅并持久化。
- POC 阶段不需要跨进程事件分发。

---

## 5. 并行路线执行框架

### 5.1 设计原则

- 每条路线封装为独立的 `RouteEngine`，实现统一协议。
- 所有路线共享同一份 `FeatureWindow` 流，各自独立消费。
- 路线之间不相互依赖，也不相互通信。
- 每条路线独立产出自己的预测结果和证据链。

### 5.2 RouteEngine 协议

```swift
protocol RouteEngine {
    var routeId: RouteId { get }

    /// 是否具备当晚运行条件（权限、设备、先验）
    func canRun(condition: DeviceCondition, priorLevel: PriorLevel) -> Bool

    /// Session 开始时初始化
    func start(session: Session, priors: RoutePriors)

    /// 每个新窗口到达时调用
    func onWindow(_ window: FeatureWindow)

    /// 返回当前路线的最新预测结果
    func currentPrediction() -> RoutePrediction?

    /// Session 结束时清理
    func stop()
}
```

### 5.3 RoutePrediction 结构

```swift
struct RoutePrediction {
    let routeId: RouteId
    let predictedSleepOnset: Date?     // 预测入睡时间，可能为 nil（尚未判定）
    let confidence: SleepConfidence    // .none, .candidate, .suspected, .confirmed
    let evidenceSummary: String        // 人类可读的证据摘要
    let lastUpdated: Date
}
```

### 5.4 数据屏蔽机制

为支持"同一晚模拟不同设备条件"的实验需求，框架需提供特征屏蔽能力：

- 每条路线在 `canRun` 中声明自己需要的最低特征集。
- 路线 C/D 可通过配置项关闭特定特征通道，模拟"无 Watch"或"无麦克风"场景。
- 屏蔽配置记录在 Session 元数据中，确保分析时可追溯。

实际实现中，由于路线 A-D 本身就不使用 Watch 数据、路线 A 不使用传感器数据，大部分屏蔽是自然隔离，无需额外逻辑。需要额外配置的场景主要是：

- 路线 D 屏蔽麦克风特征（退化为路线 C）。
- 路线 B/C/D 屏蔽 HealthKit 先验（模拟 P3 用户）。

---

## 6. 存储与导出

### 6.1 本地存储方案

POC 阶段使用 **文件系统 + JSON** 作为主存储，不引入数据库。

```
/Documents/SleepPOC/
  sessions/
    {sessionId}/
      session.json          ← Session 元数据
      windows.jsonl          ← 逐窗口特征记录（JSON Lines 格式）
      events.jsonl           ← 路线事件日志
      predictions.json       ← 各路线最终预测结果
      truth.json             ← 次日回填的 HealthKit 真值与误差
```

> 选择 JSONL（JSON Lines）是因为可以在 recording 过程中逐行追加，不需要在内存中维护完整数组或在写入时重建整个文件。

### 6.2 Session 元数据（session.json）

```json
{
  "sessionId": "uuid",
  "date": "2026-04-07",
  "startTime": "2026-04-07T23:30:00+08:00",
  "endTime": "2026-04-08T07:15:00+08:00",
  "status": "labeled",
  "deviceCondition": {
    "hasWatch": true,
    "watchReachable": true,
    "hasHealthKitAccess": true,
    "hasMicrophoneAccess": true
  },
  "priorLevel": "P1",
  "enabledRoutes": ["A", "B", "C", "D", "E"],
  "disabledFeatures": [],
  "isWeekday": true,
  "notes": ""
}
```

### 6.3 导出格式

支持两层导出（均通过 iOS Share Sheet 输出）：

| 导出层级 | 格式 | 内容 | 用途 |
|---|---|---|---|
| Session 级 | CSV | 每晚一行：日期、各路线预测时间、真值、各路线误差、设备条件 | 快速纵览、路线对比 |
| Window 级 | JSON | 完整的窗口特征序列 + 事件日志 | 离线回放、调参、特征分析 |

Session 级 CSV 示例表头：

```
date, startTime, priorLevel, hasWatch,
routeA_prediction, routeA_error_min,
routeB_prediction, routeB_error_min,
routeC_prediction, routeC_error_min,
routeD_prediction, routeD_error_min,
routeE_prediction, routeE_error_min,
healthkit_sleep_onset, sample_quality
```

---

## 7. Day0 先验探测与参数初始化

### 7.1 先验可用性分级

Session 创建时，执行一次先验探测，将当前用户归类为以下分级之一：

| 分级 | 条件 | 可初始化内容 |
|---|---|---|
| **P1** | HealthKit 已授权 **且** 最近 14 天内存在 ≥3 条有效睡眠样本 | 入睡时间分布、工作日/周末差异、入睡潜伏期、心率基线（如有 Watch）|
| **P2** | HealthKit 已授权，无足够睡眠样本，但存在 ≥7 天心率数据 | 睡前心率基线、夜间心率波动范围 |
| **P3** | 未授权 HealthKit，或已授权但无可用历史数据 | 仅用户手动输入 + 应用内历史（D1 起积累）|

### 7.2 探测流程

```
1. 检查 HealthKit 授权状态
   ├── 未授权 → P3
   └── 已授权
       ├── 查询最近 14 天睡眠样本
       │   ├── ≥ 3 条有效记录 → P1
       │   └── < 3 条
       │       ├── 查询最近 14 天心率样本
       │       │   ├── ≥ 7 天有数据 → P2
       │       │   └── < 7 天 → P3
```

### 7.3 P1 先验提取项

当用户为 P1 时，从 HealthKit 睡眠样本中提取：

| 先验参数 | 来源 | 用途 |
|---|---|---|
| `typicalSleepOnset` | 最近 14 天入睡时间的中位数 | 路线 A 的 baseline 预测 |
| `sleepOnsetStdDev` | 入睡时间的标准差 | 判断用户入睡一致性 |
| `weekdayOnset` / `weekendOnset` | 工作日/周末中位数 | 路线 A 的分日预测 |
| `typicalLatency` | "开始记录"到入睡的中位时间差（如可推断）| 路线 B 的锚点偏移 |
| `preSleepHRBaseline` | 入睡前 30 分钟的平均心率（如有 Watch 数据）| 路线 E 的心率阈值初始化 |
| `sleepHRDropRange` | 入睡前后心率下降幅度分布 | 路线 E 的心率下降判定 |

### 7.4 应用内历史积累

对于 P2/P3 用户以及所有用户的长期迭代：

- 每晚 Session 结束后，将当晚各路线的预测结果和真值（如有）存入应用内历史。
- 从第 N+1 晚起，可用应用内历史替代或补充 HealthKit 先验。
- P3 用户从 D1 起自动开始积累，预期 3-5 个有标签样本后可生成初步应用内先验。

---

## 8. DeviceCondition 与权限管理

### 8.1 启动时检测

Session 创建时，一次性检测并快照当前设备条件：

```swift
struct DeviceCondition {
    let hasWatch: Bool                 // 是否配对了 Apple Watch
    let watchReachable: Bool           // Watch 当前是否可达
    let hasHealthKitAccess: Bool       // HealthKit 已授权
    let hasMicrophoneAccess: Bool      // 麦克风已授权
    let hasMotionAccess: Bool          // 运动传感器可用（iOS 默认可用，无需弹窗）
}
```

### 8.2 权限请求策略

POC 阶段简化处理：

- 首次启动时一次性请求所有需要的权限（HealthKit 读取、麦克风）。
- 权限被拒绝不阻塞使用，降级到对应路线不可用即可。
- 不做权限引导页或二次请求，POC 阶段由开发者在系统设置中手动管理。

---

## 9. UI 概要

> 本节仅定义 POC 需要的最小 UI，不追求产品级交互。

### 9.1 最小页面清单

| 页面 | 职责 |
|---|---|
| **主页** | 显示当前 Session 状态，提供"开始/结束当晚记录"按钮 |
| **实时监控页** | Recording 期间展示各路线实时状态、当前窗口特征摘要、事件流 |
| **历史页** | 展示过去 Session 列表，每条显示各路线预测结果与误差 |
| **导出页** | 选择导出范围和格式，通过 Share Sheet 输出 |
| **设置页** | Day0 用户输入（目标入睡时间等）、先验分级显示、特征屏蔽配置 |

### 9.2 实时监控页核心展示

Recording 进行中时，需至少展示：

- 当前 Session 已运行时长。
- 各路线的当前状态（未启动 / 运行中 / 已判定入睡 / 不可用）。
- 最近 N 个窗口的关键特征趋势（如运动强度曲线）。
- 最近事件日志流。

---

## 10. 待确认项汇总

| 编号 | 问题 | 影响范围 | 当前假设 |
|---|---|---|---|
| Q1 | iOS 后台持续运动传感器采集的能力边界 | 路线 B/C/D 的后台采集 | POC 阶段以前台为主 + 后台尽力而为 |
| Q2 | ~~Watch 侧是否必须有独立 app 才能实时拿到腕动和心率~~ **已确认：必须开发 Watch App，采用 CMSensorRecorder + HKAnchoredObjectQuery 方案** | `WatchProvider` 实现方式 | 见《调研_路线E_Watch技术可行性》和 SPEC 05 §7 |
| Q3 | 窗口长度 30 秒是否合适 | 特征分辨率 vs 存储量 | 30 秒起步，运行后可调整 |
| Q4 | 次日自动结束的截止时间 | Session 生命周期 | 次日 12:00 |
| Q5 | P1 的最低睡眠样本数量 3 条是否合适 | 先验分级阈值 | 3 条，运行后可调整 |

---

## 11. 与其他 SPEC 的关系

| SPEC | 本框架提供 | 该 SPEC 补充 |
|---|---|---|
| 路线 A | Session、InteractionProvider、先验参数 | 定时估计的具体算法 |
| 路线 B | Session、MotionProvider、InteractionProvider | 放下手机检测逻辑 |
| 路线 C | Session、MotionProvider | 体动特征与静止判定逻辑 |
| 路线 D | Session、MotionProvider、AudioProvider、InteractionProvider | 多模态融合规则 |
| 路线 E | Session、WatchProvider、MotionProvider、InteractionProvider | Watch 主导融合与心率判定 |
| 评估框架 | Session truth.json、predictions.json | 误差计算、统计分析、路线对比 |

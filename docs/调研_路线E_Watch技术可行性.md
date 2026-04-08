# 路线 E 技术可行性调研：Watch 数据获取方案评估

> **状态**：调研完成
> **结论**：**是的，必须开发 Watch App**。但具体方案选择比预想的更有层次。

---

## 1. 调研背景

路线 E 需要在夜间 Session 期间持续获取两类 Watch 数据：

1. **腕部加速度**：用于腕动静止检测
2. **心率**：用于心率下降趋势判定

核心问题：是否必须开发 Watch App，还是可以仅从 iPhone 侧 HealthKit 被动获取？

---

## 2. 四种方案对比

| | 方案 A | 方案 B | 方案 C | 方案 D |
|---|---|---|---|---|
| **名称** | iPhone 读 HealthKit | Watch App + HKWorkoutSession | Watch App + ExtendedRuntimeSession | Watch App + CMSensorRecorder |
| **需要 Watch App** | ❌ 不需要 | ✅ 需要 | ✅ 需要 | ✅ 需要 |
| **心率获取** | 被动同步，分钟级延迟 | 高频实时（秒级）| 可用，但受 CPU 限制 | ❌ 不支持心率 |
| **腕部加速度** | ❌ 完全不可用 | ✅ 实时高频 | 受限（CPU 约束下可能被终止）| ✅ 后台录制 50Hz，最多存 3 天 |
| **夜间续航影响** | 无 | ⚠️ **严重耗电**（高频采样不休眠）| 中等（有 CPU 上限保护）| 低（系统级录制，非常省电）|
| **系统稳定性** | 稳定 | 稳定但可能被其他 Workout 中断 | ⚠️ 可能被系统终止 | 稳定（系统级录制不依赖 app 前台）|
| **数据实时性** | 分钟级延迟 | 秒级 | 秒级 | ⚠️ 最多 3 分钟延迟 |
| **App Store 审核风险** | 无 | ⚠️ 用 Workout 做非运动用途可能被拒 | 需选对 session 类型 | 低风险 |
| **实现成本** | 低 | 中 | 中-高 | 中 |

---

## 3. 各方案详细分析

### 方案 A：iPhone 侧仅读 HealthKit（不需要 Watch App）

**结论：❌ 不可行作为路线 E 主方案**

- HealthKit 心率数据从 Watch 同步到 iPhone 存在 **分钟级甚至更长的延迟**，且不保证实时到达。
- **完全无法获取腕部加速度数据**——HealthKit 不同步原始运动数据。
- 心率样本在非 Workout 状态下的采样间隔也极不稳定（可能 5-15 分钟一个样本）。
- 适用场景：仅作为 Day0 先验读取（历史睡眠样本、历史心率），**不适合实时判定**。

### 方案 B：Watch App + HKWorkoutSession

**结论：⚠️ 技术可行但 POC 不推荐作为首选**

- 提供最完整的实时数据能力：高频心率 + 高频加速度。
- **严重问题**：HKWorkoutSession 会让 Watch 进入高频采样模式，**整晚电量消耗极大**。正常睡眠追踪消耗约 10-15% 电量，但 HKWorkoutSession 可能消耗 40%+。
- 会影响用户的 Activity Rings（记录为一个 Workout）。
- 排他性：同一时间只能有一个 HKWorkoutSession，如果用户使用原生 Workout App 会冲突。
- App Store 审核时用 Workout Session 做睡眠用途可能有风险。

### 方案 C：Watch App + WKExtendedRuntimeSession

**结论：⚠️ 理论可行但稳定性存疑**

- 设计初衷是用于 Smart Alarm、Physical Therapy 等场景，与睡眠监测概念上契合。
- 系统对后台 CPU 使用有 **严格限制**（约 15%），超出会被终止。
- 持续高频传感器采集容易超出 CPU 预算。
- 在夜间 6-8 小时场景下，**被系统终止的概率较高**。
- 如果仅做低频采集（例如每 30 秒采样一次而非连续 50Hz），可能在 CPU 预算内存活。

### 方案 D：Watch App + CMSensorRecorder（加速度）+ HealthKit Observer Query（心率）

**结论：✅ 最适合 POC 的混合方案**

- `CMSensorRecorder` 是 watchOS 提供的 **系统级后台加速度录制 API**：
  - 不需要 app 保持前台运行。
  - 系统自动在后台以 50Hz 录制加速度数据。
  - 数据最多保留 3 天。
  - 检索时有 **最多 3 分钟的延迟**。
  - 非常省电，是苹果原生睡眠追踪也使用的底层机制。
- 心率获取：使用 `HKAnchoredObjectQuery` 的 updateHandler，Watch 上直接监听新心率样本。watchOS 在佩戴状态下自动采集心率（约每 5-10 分钟一次，夜间可能更频繁）。
- **缺点**：
  - 加速度数据有最多 3 分钟延迟，不是真正的"秒级实时"。
  - 心率采样间隔不可控（依赖系统调度，非 Workout 模式下间隔较大）。
  - 但对于入睡检测场景（判定窗口通常是分钟级而非秒级），**这个延迟是可接受的**。

---

## 4. 推荐方案

### POC 阶段推荐：方案 D（混合方案）

```
Watch App 职责：
├── CMSensorRecorder：后台录制加速度（系统级，省电）
├── HKAnchoredObjectQuery：监听新心率样本
├── 定时任务（Background App Refresh 或 Complication 更新触发）：
│   ├── 每 1-3 分钟从 CMSensorRecorder 提取最新加速度数据
│   ├── 提取后计算窗口级特征摘要（wristAccelRMS, wristStillDuration）
│   └── 通过 WCSession 回传特征摘要到 iPhone
└── 在 iPhone 不可达时，本地缓存特征摘要待补传
```

### 对路线 E SPEC 的影响

| SPEC 原假设 | 调研结论 | 需要调整 |
|---|---|---|
| 秒级实时数据 | 实际为 1-3 分钟延迟 | 窗口间隔从 30s 调整为 **1-3 分钟**（Watch 侧） |
| HKWorkoutSession | 耗电不可接受 | 改用 CMSensorRecorder + HKAnchoredObjectQuery |
| ExtendedRuntimeSession | 稳定性不足 | 不作为主方案，可作为备选 spike |
| 心率高频采样 | 非 Workout 下间隔 5-10 分钟 | 需接受较稀疏的心率样本，调整心率趋势算法 |
| Watch 持续在线 | CMSensorRecorder 不需要 app 前台 | Watch app 可以不保持前台运行 |

### 心率稀疏问题的缓解

非 Workout 模式下心率采样间隔可能为 5-10 分钟，这对"心率下降趋势"的检测有影响。缓解方式：

1. **放宽心率趋势窗口**：从 5 分钟扩大到 15-20 分钟。
2. **降低 R² 要求**：在样本稀疏时接受更弱的趋势信号。
3. **重新定义心率证据**：从"心率持续下降"调整为"最近 2-3 个心率样本均低于 sleepHRTarget"。
4. **接受心率通道可能延迟独立判定**：允许腕动通道 + 交互通道先进入候选，心率通道后续补充确认。

---

## 5. Watch App 最小范围

POC 阶段 Watch App 的实现范围：

| 模块 | 职责 | 复杂度 |
|---|---|---|
| **Session 响应** | 接收 iPhone 的 start/stop 消息 | 低 |
| **加速度录制** | 调用 CMSensorRecorder.recordAccelerometer(forDuration:) | 低 |
| **加速度提取** | 定时从 CMSensorRecorder 提取数据、计算窗口特征 | 中 |
| **心率监听** | HKAnchoredObjectQuery 监听新心率样本 | 低 |
| **数据回传** | WCSession 发送特征摘要到 iPhone | 低 |
| **本地缓存** | iPhone 不可达时缓存待补传 | 低 |
| **UI** | 仅需最小 UI（显示 Session 状态）| 低 |

总体评估：**Watch App 实现量不大**，核心是 CMSensorRecorder + HKAnchoredObjectQuery + WCSession 的组合，代码量预计 300-500 行。

---

## 6. 综合结论

| 问题 | 回答 |
|---|---|
| 是否必须开发 Watch App？ | **是的，必须。** iPhone 侧无法获取腕部加速度，且心率同步延迟过大。|
| Watch App 复杂度如何？ | **较低。** 核心是 3 个系统 API 的组合，无需复杂 UI。|
| 推荐哪个后台方案？ | **CMSensorRecorder（加速度）+ HKAnchoredObjectQuery（心率）。** 不推荐 HKWorkoutSession（太耗电）或 ExtendedRuntimeSession（不够稳定）。|
| 对 SPEC 有什么影响？ | Watch 侧数据延迟从秒级放宽到 1-3 分钟，心率采样间隔放宽到 5-10 分钟。判定窗口和趋势算法需相应调整。|
| 是否影响路线 E 的整体可行性？ | **不影响。** 入睡判定的时间尺度本身是分钟级的，1-3 分钟延迟对最终误差的影响很小。|

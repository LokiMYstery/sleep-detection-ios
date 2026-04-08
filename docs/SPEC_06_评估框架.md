# SPEC 06: 评估框架

> **状态**：草稿，待评审
> **前置文档**：SPEC 00 基础框架、《入睡检测 POC 实验路线与验证规划》§3 评估重点、§7 数据记录
> **范围**：定义 Ground Truth 回填、误差计算、路线对比和样本分类的统一评估体系

---

## 1. 目标

为 POC 的多路线并行实验提供一套统一的评估框架，确保：

- 各路线的评估口径一致，支持横向比较。
- 每晚的数据自动回填标签并计算误差。
- 误差从多维度分解，能定位"问题出在哪里"。
- 特殊样本（无标签、中断、无 Watch 等）有明确的分类处理规则。

---

## 2. Ground Truth 回填

### 2.1 真值来源

统一使用次日 HealthKit 更新后的睡眠记录作为 Ground Truth：

```swift
HKCategoryTypeIdentifier.sleepAnalysis
```

取当晚对应的睡眠记录中 **入睡开始时间**（`startDate`）作为统一真值。

### 2.2 回填触发时机

| 触发方式 | 时机 | 说明 |
|---|---|---|
| **每次打开 App** | App 每次进入前台 | 扫描所有 `pendingTruth` 状态的 Session，逐一尝试回填 |
| 后台检查 | HKObserverQuery 回调 | 睡眠数据更新时自动触发 |
| 手动触发 | 历史页点击"刷新标签" | 用于补回填或重新查询 |

> **为什么每次打开都要检查**：HealthKit 睡眠数据的更新时机不可控——用户可能凌晨 1 点才开始 Session，当天早上就醒来（同一日历日），且 HealthKit 可能在醒来后数小时才完成同步。因此不能只查一次，必须每次打开 App 都重试所有未回填的 Session。

### 2.2.1 回填重试与超时策略

- 每个 `pendingTruth` Session 在每次 App 打开时都尝试查询 HealthKit。
- 如果查询无结果，**不立即标记为无标签**，保持 `pendingTruth` 状态继续等待。
- 当 Session 的 endTime（或 interruptedAt）距当前时间超过 **48 小时**仍无可用记录时，才标记为 Q3 无标签样本。
- 48 小时的宽限期足以覆盖 HealthKit 延迟同步、设备未连接等场景。

### 2.3 回填逻辑

```
1. 查询 HealthKit 中覆盖 [session.startTime - 2h, session.startTime + 12h] 的睡眠记录
2. 筛选：
   ├── sourceBundle 来自可信来源（Apple Watch、iPhone 原生）
   ├── 排除手动录入的睡眠记录
   └── value == HKCategoryValueSleepAnalysis.asleepUnspecified
        或 .asleepCore / .asleepDeep / .asleepREM
3. 如果存在多条记录，取最早的 asleep 记录的 startDate
4. 写入 truth.json
```

### 2.4 truth.json 结构

```json
{
  "hasTruth": true,
  "healthKitSleepOnset": "2026-04-08T00:15:00+08:00",
  "healthKitSource": "com.apple.health.sleeping",
  "retrievedAt": "2026-04-08T09:30:00+08:00",
  "errors": {
    "routeA": { "errorMinutes": 12.5, "direction": "late" },
    "routeB": { "errorMinutes": 5.0, "direction": "early" },
    "routeC": { "errorMinutes": 3.5, "direction": "early" },
    "routeD": { "errorMinutes": 2.0, "direction": "early" },
    "routeE": { "errorMinutes": 1.5, "direction": "late" }
  }
}
```

### 2.5 无真值处理

当次日无可用 HealthKit 睡眠记录时：

- `hasTruth = false`
- 不计算误差，不参与路线对比。
- 但该 Session 的采集数据和判定过程仍完整保留：
  - 可用于验证采集链路、实时判定链路。
  - 可用于回放和调试。
  - 未来如果手动补录真值，可重新计算误差。

---

## 3. 误差计算

### 3.1 基本误差

对每条路线、每个有标签的 Session：

```
error = predictedSleepOnset - healthKitSleepOnset  (分钟)

正值 = 延后判睡（predicted 晚于真值）
负值 = 提前判睡（predicted 早于真值）
absoluteError = |error|
```

### 3.2 未判定处理

如果某路线在当晚未能产出 `predictedSleepOnset`（例如始终未进入 confirmed 状态、或路线不可用），则该路线在该夜：

- 误差标记为 `null`。
- 在统计时归类为"未判定样本"。
- 与"有判定但误差大"不混在一起。

---

## 4. 统计指标

### 4.1 核心汇总指标

对每条路线，在所有有标签样本上计算：

| 指标 | 计算方式 | 用途 |
|---|---|---|
| `medianAbsError` | 绝对误差中位数 | 核心精度指标 |
| `meanAbsError` | 绝对误差均值 | 对比参考 |
| `hit5min` | \|error\| ≤ 5 min 的比例 | 高精度命中率 |
| `hit10min` | \|error\| ≤ 10 min 的比例 | 可用精度命中率 |
| `hit15min` | \|error\| ≤ 15 min 的比例 | 宽松精度命中率 |
| `hit20min` | \|error\| ≤ 20 min 的比例 | 底线精度命中率 |
| `earlyRate` | error < 0 的比例 | 提前判睡倾向 |
| `lateRate` | error > 0 的比例 | 延后判睡倾向 |
| `noResultRate` | 未判定样本比例 | 路线可用性 |

### 4.2 分层统计

为识别不同条件下的表现差异，对以上指标按以下维度分层计算：

| 分层维度 | 分组 | 用途 |
|---|---|---|
| 先验层级 | P1 / P2 / P3 | HealthKit 先验的增量价值 |
| 工作日/周末 | weekday / weekend | 入睡时间稳定性差异 |
| Watch 数据 | 完整 / 部分 / 无 | Watch 数据完整度的影响 |
| 手机摆放 | pillow / bedSurface / nightstand / other | 路线 C/D 的摆放敏感性 |

---

## 5. 路线横向对比

### 5.1 对比表

每晚生成一张路线对比表：

```
日期 | 真值    | A 预测  | A 误差 | B 预测  | B 误差 | C 预测 | C 误差 | D 预测 | D 误差 | E 预测 | E 误差
04-08 | 00:15 | 00:30  | +15   | 00:20  | +5    | 00:12 | -3    | 00:13 | -2    | 00:16 | +1
04-09 | 23:45 | 00:10  | +25   |  —     | N/A   | 23:50 | +5    | 23:48 | +3    | 23:44 | -1
```

### 5.2 路线排名

累积若干晚后，按 `medianAbsError` 排序路线，生成排名表：

| 排名 | 路线 | medianAbsError | hit10min | noResultRate |
|---|---|---|---|---|
| 1 | E | 2.0 min | 90% | 5% |
| 2 | D | 5.5 min | 65% | 10% |
| 3 | C | 8.0 min | 50% | 10% |
| 4 | B | 12.0 min | 35% | 15% |
| 5 | A | 22.0 min | 15% | 0% |

### 5.3 路线间增量分析

重点关注路线间的增量价值：

| 对比项 | 含义 |
|---|---|
| B - A | 放下手机锚点的增量 |
| C - A | 纯体动的增量 |
| D - C | 音频通道的增量 |
| E - D | Watch 的增量 |
| E - A | 完整链路 vs 纯定时的总增量 |

---

## 6. 样本分类

### 6.1 样本质量分级

每个 Session 按数据完整度打分：

| 等级 | 条件 | 是否参与误差统计 |
|---|---|---|
| **Q1: 完整样本** | 有真值 + 所有启用路线均产出结果 + 无中断 | ✅ 全量参与 |
| **Q2: 部分样本** | 有真值 + 部分路线未产出 / 数据部分缺失 / 中断后恢复 | ✅ 参与，但标注质量 |
| **Q3: 无标签样本** | 无 HealthKit 真值 | ❌ 不参与误差统计 |
| **Q4: 废弃样本** | 用户手动丢弃或严重数据问题 | ❌ 不参与 |

### 6.2 异常标注

Session 或单晚可追加以下异常标注（多选）：

| 标注 | 触发条件 |
|---|---|
| `abnormalLateSleep` | 入睡时间晚于平时 2 小时以上 |
| `midnightWakeup` | session 期间检测到先入睡后再清醒 |
| `sessionInterrupted` | session.interrupted == true |
| `watchPartial` | Watch 数据部分缺失 |
| `externalAudioActive` | 检测到外部音频干扰 |
| `manualOverride` | 用户手动修正了某些标签 |

这些标注用于后续分析时筛选或解释异常点。

---

## 7. 导出与可视化

### 7.1 导出内容

评估框架在导出时生成以下文件：

| 文件 | 内容 | 格式 |
|---|---|---|
| `summary.csv` | 累计的路线排名表和核心指标 | CSV |
| `sessions.csv` | 逐晚对比表（§5.1 格式）| CSV |
| `errors_detail.json` | 所有 Session 的逐路线误差明细 | JSON |
| `statistics.json` | 分层统计结果（§4.2 各维度）| JSON |

### 7.2 App 内可视化（最小版）

在历史页提供以下最小可视化：

- 逐晚各路线误差的折线图（X 轴 = 日期，Y 轴 = 误差分钟数，每条路线一条线）。
- 各路线累计 hit10min 的柱状图。
- 样本质量分布饼图（Q1/Q2/Q3/Q4 占比）。

> POC 阶段的主要分析工作预期在导出 CSV/JSON 后用外部工具（Excel / Python）完成，App 内可视化仅提供快速概览。

---

## 8. 自动化流程

### 8.1 App 前台回填流程

```
App 每次进入前台
    ↓
扫描所有 status == pendingTruth 的 Session
    ↓
对每个 pendingTruth Session：
    ├── 查询 HealthKit 对应时段的睡眠记录
    ├── 有可用记录
    │   ├── 写入 truth.json，计算各路线误差
    │   └── status → labeled
    └── 无可用记录
        ├── Session 结束距今 < 48 小时 → 保持 pendingTruth，下次再试
        └── Session 结束距今 ≥ 48 小时 → 标记为 Q3 无标签样本
    ↓
如有任何 Session 状态变更，更新累计统计指标
    ↓
在历史页刷新对比数据
```

### 8.2 累计统计更新

每次回填新标签后，自动重新计算所有核心指标（§4.1）和分层统计（§4.2）。由于 POC 阶段样本量极小（数十到百级），全量重算无性能问题。

---

## 9. 与其他 SPEC 的关系

| SPEC | 评估框架接收 | 评估框架输出 |
|---|---|---|
| SPEC 00 基础框架 | session.json, predictions.json, events.jsonl | truth.json, 累计统计 |
| SPEC 01-05 各路线 | 各路线的 RoutePrediction | 逐路线误差和排名 |
| 规划文档 §3.4 | 评估指标要求 | 指标覆盖验证 |

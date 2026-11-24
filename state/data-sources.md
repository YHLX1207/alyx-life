# 数据源可信度登记表

> 精细化管理的基础：**知道什么数据能信、什么不能**。
> 每条都经实测交叉验证，不是凭印象评级。

---

## 可信（可直接用于判断）

| 数据源 | 用途 | 验证依据 |
|---|---|---|
| `df` | 存储占用 | 内核直接读数；与 `diskstats` 矛盾时以它为准 |
| `/proc/meminfo` | 内存 | `MemTotal` 与 `dumpsys meminfo` 的 `Total RAM` **完全一致**（7,743,164K）|
| `/proc/loadavg` | 系统负载 | 内核直接读数 |
| `pm list packages` | 应用清单 | 与包管理器状态一致 |
| `adb shell echo` | 通道活性 | 最轻量探针 |

## 部分可信（需注意口径）

| 数据源 | 可用部分 | 不可用部分 |
|---|---|---|
| `dumpsys meminfo` | `Total RAM` 准确 | `Free + Used ≠ Total`，实测差 **145MB**（~2%），口径不同 |
| `dumpsys battery` | `level` / `temperature` / `voltage` | `Max charging voltage: 0` 无意义 |

## 不可信（不得用于行动决策）

| 数据源 | 问题 | 实测证据 |
|---|---|---|
| **`dumpsys diskstats`** per-app 体积 | **不随卸载更新** | 已卸载的微博显示 263MB；各项累加 **22GB** vs `df` 实测 **15.2GB** |
| **`dumpsys batterystats`** 估算 | 计算与实际差 5 倍 | `Computed drain: 118 mAh` vs `actual drain: 500-600 mAh`；**382mAh 无法归因** |
| `dumpsys cpuinfo` | 采样窗口可能滞后 | 显示 "from 103882ms to 96941ms ago" —— 约 100 秒前的数据 |

---

## 本机特殊情况

- **设备长期插电**（电量恒 100%，电压 4033mV）
  → 电池不是资源约束；batterystats 的历史放电数据无参考价值
- **`/data/data/<包名>` 对 shell 不可读**（需 root）
  → 应用数据占用无法直接审计，只能看 `df` 总量

---

## 使用规则

1. **凡是要据此采取行动的数值，必须有 ≥2 个独立来源且相互吻合**
2. 系统统计接口（dumpsys）优先怀疑；内核接口（/proc、/sys、df）优先信任
3. 发现不可靠数据源时，**登记到此表**，避免下次重复踩坑

---

最后更新：2026-11-21 (Round 78)

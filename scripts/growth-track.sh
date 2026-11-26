#!/usr/bin/env bash
# 成长追踪：量化"我在成长还是在维持"，而不是只报单个指标
#
# 为什么需要（Round 233）：
#   自省（chain-reflect）记录了决策数、脚本数、心跳数等，但都是**单指标**。
#   没有指标回答一个关键问题："综合来看，我到底在成长还是在维持？"
#
#   目标要求"不断成长"。如果系统不知道自己在维持还是成长，
#   就无法判断自己是否偏离了目标。
#
# 本脚本：
#   · 从 reflections.jsonl 读取历史，按时间窗口计算各维度变化率
#   · 综合多个维度给出成长分类：growing / maintaining / stagnating
#   · 写入 state/growth.jsonl，供链和后续自省引用
set -uo pipefail
cd "$(dirname "$0")"

STATE="${ALYX_STATE_DIR:-../state}"
OUT="$STATE/growth.jsonl"

python3 - "$STATE" "$OUT" <<'PY'
import sys, os, json, datetime

state, out_path = sys.argv[1], sys.argv[2]
now = datetime.datetime.now(datetime.timezone.utc)
ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")

def load_jsonl(path):
    rows = []
    try:
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except Exception:
                pass
    except FileNotFoundError:
        pass
    return rows

refs = load_jsonl(os.path.join(state, "reflections.jsonl"))

# --- 确定时间窗口 ---
# 有足够历史时看 24h；不足看全部可用历史
windows = []
if len(refs) >= 4:
    # 取最近 24 小时的记录
    cutoff = now - datetime.timedelta(hours=24)
    recent = []
    for r in refs:
        r_ts = r.get("ts", "")
        try:
            t = datetime.datetime.strptime(r_ts, "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=datetime.timezone.utc)
            if t >= cutoff:
                recent.append(r)
        except Exception:
            pass
    if len(recent) >= 2:
        windows.append(("24h", recent))
# 始终包含全量
if len(refs) >= 2:
    windows.append(("all", refs))

# --- 各维度变化率 ---
def growth_metrics(window_rows):
    if len(window_rows) < 2:
        return None
    first = window_rows[0]
    last = window_rows[-1]

    # 时间跨度
    try:
        t0 = datetime.datetime.strptime(first["ts"], "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc)
        t1 = datetime.datetime.strptime(last["ts"], "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc)
        span_h = (t1 - t0).total_seconds() / 3600
    except Exception:
        span_h = 0

    def delta(key):
        a = first.get(key)
        b = last.get(key)
        if isinstance(a, (int, float)) and isinstance(b, (int, float)):
            return b - a
        return 0

    m = {
        "span_hours": round(span_h, 1),
        "decisions_added": delta("decision_count"),
        "scripts_added": delta("scripts"),
        "heartbeats_added": delta("heartbeat_count"),
        "reflections_count": len(window_rows),
    }

    # 决策增速：每 24 小时新增决策数
    if span_h > 0:
        m["decisions_per_day"] = round(m["decisions_added"] * 24 / span_h, 2)
    else:
        m["decisions_per_day"] = 0

    return m

# --- 综合判定 ---
def classify(metrics):
    if metrics is None:
        return "insufficient-data", "历史不足，无法判定"

    d_per_day = metrics["decisions_per_day"]
    s_added = metrics["scripts_added"]

    # 判定标准（可调）：
    #   growing:     有新决策产出（>= 1/天）或新增了脚本
    #   maintaining: 心跳在跑、系统稳定，但没有新产出
    #   stagnating:  心跳在涨但决策数长时间不动

    if s_added > 0 or d_per_day >= 1.0:
        return "growing", f"每{24}小时新增 {d_per_day} 条决策，脚本 +{s_added} 个"
    elif d_per_day > 0:
        return "growing", f"决策在缓慢增加（{d_per_day} 条/天）"
    elif metrics["heartbeats_added"] > 0:
        return "maintaining", f"心跳 +{metrics['heartbeats_added']} 次，但无新决策或脚本"
    else:
        return "stagnating", "心跳与决策均无变化"

# --- 汇总 ---
results = []
for label, rows in windows:
    m = growth_metrics(rows)
    verdict, reason = classify(m)
    rec = {
        "ts": ts,
        "window": label,
        "metrics": m,
        "verdict": verdict,
        "reason": reason,
    }
    results.append(rec)

# 以 24h 为主判定（若有），否则用全量
if len(results) >= 2:
    primary = results[0]  # 24h 优先
else:
    primary = results[0] if results else None

if primary:
    print(f"  成长判定（{primary['window']}）: {primary['verdict']}")
    print(f"    原因: {primary['reason']}")
    if primary['metrics']:
        m = primary['metrics']
        print(f"    跨度: {m['span_hours']}h | 决策+{m['decisions_added']} | "
              f"脚本+{m['scripts_added']} | 心跳+{m['heartbeats_added']}")
        print(f"    决策增速: {m['decisions_per_day']} 条/天")
    if len(results) > 1:
        print(f"  全量窗口: {results[1]['verdict']} ({results[1]['reason']})")
else:
    print("  历史不足，无法判定成长")
    primary = {"ts": ts, "window": "insufficient", "verdict": "insufficient-data",
               "reason": "无足够自省记录", "metrics": None}

# 写入
os.makedirs(state, exist_ok=True)
with open(out_path, "a", encoding="utf-8") as f:
    f.write(json.dumps(primary, ensure_ascii=False) + "\n")

# 控制体积
rows = load_jsonl(out_path)
if len(rows) > 100:
    with open(out_path, "w", encoding="utf-8") as f:
        for r in rows[-100:]:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
PY

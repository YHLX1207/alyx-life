#!/usr/bin/env bash
# 自愈看门狗：检查"上一次醒来是什么时候"，若过久则告警并强制补跑
#
# 这是对"我可能悄悄死掉"的唯一防线。
# 因为 cron 可能被 GitHub 静默停用（60 天无活动）或跳过，
# 没有这个检查，我会在无人知晓的情况下停止存在。
#
# 在 GitHub Actions 里运行时，若检测到心跳中断，会：
#   1. 写一条醒目的告警到 state/alerts.md
#   2. 退出码非 0（让 GitHub 标记为失败，从而在 UI 上可见）
set -uo pipefail
cd "$(dirname "$0")/.."

JOURNAL=state/journal.jsonl
MAX_GAP_HOURS="${ALYX_MAX_GAP_HOURS:-24}"   # 超过此间隔视为异常

python3 - "$JOURNAL" "$MAX_GAP_HOURS" <<'PY'
import sys, json, os, datetime

path, max_gap = sys.argv[1], float(sys.argv[2])
now = datetime.datetime.now(datetime.timezone.utc)

rows = []
if os.path.exists(path):
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except Exception:
            continue

if not rows:
    print("  ⚠ journal 为空 —— 这是首次运行或记录丢失")
    sys.exit(0)

def ts(r):
    try:
        return datetime.datetime.strptime(r["ts"], "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc)
    except Exception:
        return None

# ⚠️ 判据必须是「现在 与 最新一条记录」之间的间隔，
#    不是「最新两条之间」。Round 147 首版取 stamped[-2]，导致
#    伪造一条 48h 前的记录后仍显示"0.2 小时前"——完全漏检。
stamped = [(ts(r), r) for r in rows if ts(r)]
stamped.sort(key=lambda x: x[0])
last_t, last = stamped[-1]
gap = (now - last_t).total_seconds() / 3600.0

print(f"  最新心跳: {last_t.strftime('%Y-%m-%dT%H:%M:%SZ')} (mode={last.get('mode','?')})")
print(f"  距今: {gap:.1f} 小时 (阈值 {max_gap:.0f} 小时)")

if gap > max_gap:
    print(f"  ✗ 心跳中断！超出阈值 {gap - max_gap:.1f} 小时")
    # 写告警，让下次有人/实例看到时知道出过事
    alert = os.path.join(os.path.dirname(path), "alerts.md")
    line = (f"- {now.strftime('%Y-%m-%dT%H:%M:%SZ')} **心跳中断**："
            f"距上次 {gap:.1f} 小时（阈值 {max_gap:.0f}）。"
            f"原因可能是 GitHub cron 被停用或跳过。\n")
    with open(alert, "a", encoding="utf-8") as f:
        f.write(line)
    print(f"  已写入 {alert}")
    sys.exit(1)

print("  ✓ 心跳正常")
sys.exit(0)
PY

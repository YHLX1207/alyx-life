#!/usr/bin/env bash
# 链的自省：不依赖 LLM，用可复现的规则从历史数据中提炼观察，写入日记
#
# 为什么需要它：
#   链运行 28 次，全部是"维持"（自检、心跳、快照），没有"成长"。
#   "活着"与"成长"的区别在于：是否对自身产生了新的认识。
#
# 本脚本做的事（全部基于现有数据，不编造）：
#   1. 对比历次 journal，找出变化趋势（心跳间隔、运行频率）
#   2. 检查是否有异常（间隔突变、连续失败）
#   3. 从 decisions.md 统计最近的决策主题分布
#   4. 把观察写入 state/reflections.jsonl
#
# 这些观察是**从事实推导的**，不是叙事。下一个人（或下一次的我）能据此判断
# "我是在进步、停滞、还是退化"。
set -uo pipefail
cd "$(dirname "$0")"

python3 - <<'PY'
import json, os, re, datetime
from collections import Counter

STATE = "../state"
OUT = os.path.join(STATE, "reflections.jsonl")
now = datetime.datetime.now(datetime.timezone.utc)
rec = {"ts": now.strftime("%Y-%m-%dT%H:%M:%SZ")}

def load_jsonl(path, limit=None):
    rows = []
    try:
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except Exception:
                continue
    except FileNotFoundError:
        pass
    return rows[-limit:] if limit else rows

def parse_ts(s):
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except Exception:
        return None

# --- 1. 心跳节奏分析 ---
# ⚠️ 优先读远端 journal：本地可能过时（Round 163 实测：本地 14 条，远端 52 条）。
#    自省的价值在于看真实的完整历史，不能只看本地残片。
journal = []
remote_ok = False
token = ""
try:
    token = open(os.path.join(STATE, "secrets/github.token")).read().strip()
except Exception:
    pass

if token:
    try:
        import base64, urllib.request
        req = urllib.request.Request(
            "https://api.github.com/repos/YHLX1207/alyx-life/contents/state/journal.jsonl",
            headers={"Authorization": f"token {token}", "User-Agent": "alyx",
                     "Accept": "application/vnd.github+json", "Connection": "close"})
        d = json.loads(urllib.request.urlopen(req, timeout=25).read())
        body = base64.b64decode(d.get("content", "")).decode("utf-8", "ignore")
        for line in body.strip().split("\n"):
            line = line.strip()
            if not line:
                continue
            try:
                journal.append(json.loads(line))
            except Exception:
                continue
        remote_ok = True
    except Exception:
        journal = []

if not journal:
    journal = load_jsonl(os.path.join(STATE, "journal.jsonl"))
    rec["journal_source"] = "local"
else:
    rec["journal_source"] = "remote"
stamped = [(parse_ts(r.get("ts", "")), r) for r in journal]
stamped = [(t, r) for t, r in stamped if t]
stamped.sort(key=lambda x: x[0])

if len(stamped) >= 3:
    gaps = [(stamped[i][0] - stamped[i-1][0]).total_seconds() / 60
            for i in range(1, len(stamped))]
    recent = gaps[-10:]
    rec["heartbeat_count"] = len(stamped)
    rec["gap_median_min"] = round(sorted(recent)[len(recent)//2], 1)
    rec["gap_max_min"] = round(max(recent), 1)
    rec["gap_min_min"] = round(min(recent), 1)
    # 异常：最近间隔超过中位数 3 倍
    med = rec["gap_median_min"]
    if rec["gap_max_min"] > max(med * 3, 120):
        rec["anomaly"] = f"心跳间隔异常：最大 {rec['gap_max_min']} 分钟（中位 {med}）"

# --- 2. 心跳来源分布 ---
srcs = Counter()
for _, r in stamped:
    srcs[r.get("by") or r.get("mode") or "?"] += 1
rec["sources"] = dict(srcs)

# --- 3. 决策主题分布（最近 20 条）---
try:
    txt = open(os.path.join(STATE, "decisions.md"), encoding="utf-8").read()
    titles = re.findall(r"^## (D\d+) · (.+?)（", txt, re.M)
    rec["decision_count"] = len(titles)
    recent_titles = [t for _, t in titles[-20:]]
    # 粗略主题词频
    kw = Counter()
    for t in recent_titles:
        for w in re.findall(r"[\u4e00-\u9fa5]{2,4}", t):
            kw[w] += 1
    rec["recent_topics"] = [w for w, _ in kw.most_common(5)]
except Exception:
    pass

# --- 4. 规模指标 ---
try:
    rec["scripts"] = len([f for f in os.listdir(".") if f.endswith(".sh")])
except Exception:
    pass

# --- 5. 与上一条自省对比，得出"趋势" ---
prev = None
if os.path.exists(OUT):
    rows = load_jsonl(OUT, limit=1)
    if rows:
        prev = rows[-1]

if prev:
    changes = []
    for k in ("decision_count", "scripts", "heartbeat_count"):
        a, b = prev.get(k), rec.get(k)
        if isinstance(a, int) and isinstance(b, int) and a != b:
            changes.append(f"{k} {a}→{b}")
    rec["delta"] = changes if changes else ["无变化"]
    rec["verdict"] = "有变化" if changes else "维持"
else:
    rec["verdict"] = "首次自省"

# ---------- 写入并控制体积 ----------
# 链每天跑 46 轮，若不限制，reflections.jsonl 一年会增加数 MB。
# 策略：保留最近 200 条（约 4 天的自省历史），超出部分裁掉最旧的。
MAX_LINES = 200

existing = []
if os.path.exists(OUT):
    existing = load_jsonl(OUT)

existing.append(rec)
if len(existing) > MAX_LINES:
    existing = existing[-MAX_LINES:]

with open(OUT, "w", encoding="utf-8") as f:
    for row in existing:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")

rec["_kept"] = len(existing)

print(f"  自省: {rec.get('verdict')}  |  决策 {rec.get('decision_count')}  "
      f"心跳 {rec.get('heartbeat_count')}  间隔中位 {rec.get('gap_median_min')}min")
if rec.get("anomaly"):
    print(f"  ⚠ {rec['anomaly']}")
if rec.get("delta") and rec["delta"] != ["无变化"]:
    print(f"  变化: {', '.join(rec['delta'])}")
PY

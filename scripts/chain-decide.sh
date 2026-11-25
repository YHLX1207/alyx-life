#!/usr/bin/env bash
# 基于自省数据做判断 —— 让系统不只是"记录"，而是"据此决定下一步"
#
# 为什么需要它：
#   chain-reflect.sh 每轮产出观察（心跳间隔、决策数、异常），
#   但**从来没有人根据这些观察做决定**。观察变成死数据。
#
# 本脚本读取最近的 reflections，按规则得出结论与建议动作，
# 写入 state/chain-decisions.jsonl，并输出到日志供人（或下一个我）看到。
#
# 设计原则：
#   · 只用可复现的规则，不做主观判断
#   · 结论必须附证据（哪条数据支撑）
#   · 建议动作必须是可执行的（有对应脚本）
set -uo pipefail
cd "$(dirname "$0")"

python3 - <<'PY'
import json, os, datetime

# ⚠️ 支持用环境变量隔离测试数据（Round 168 教训）：
#    变异测试直接改 state/reflections.jsonl 会产生假结论，
#    并写入生产用的 chain-decisions.jsonl，污染被推到远端。
#    ⇒ 测试时设 ALYX_STATE_DIR 指向临时目录，与生产隔离。
STATE = os.environ.get("ALYX_STATE_DIR") or "../state"
REFL = os.path.join(STATE, "reflections.jsonl")
OUT = os.path.join(STATE, "chain-decisions.jsonl")
now = datetime.datetime.now(datetime.timezone.utc)
ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")

def load(path, limit=None):
    rows = []
    try:
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except Exception:
                    pass
    except FileNotFoundError:
        pass
    return rows[-limit:] if limit else rows

refs = load(REFL, limit=20)
if not refs:
    print("  无自省数据，跳过决策")
    raise SystemExit(0)

latest = refs[-1]
findings = []   # (严重度, 结论, 证据, 建议)

# --- 规则 1：心跳间隔异常 ---
med = latest.get("gap_median_min")
mx = latest.get("gap_max_min")
if isinstance(med, (int, float)) and isinstance(mx, (int, float)):
    if med > 60:
        findings.append(("high", "心跳间隔过长",
                         f"中位 {med} 分钟（设计值 31）",
                         "检查 sleep 1800 是否被改；确认链未被限流"))
    elif mx > med * 3 and mx > 120:
        findings.append(("high", "存在心跳中断",
                         f"最大间隔 {mx} 分钟，中位 {med}",
                         "查该时段运行记录，确认是否为取消/失败"))

# --- 规则 2：来源单一化风险 ---
srcs = latest.get("sources") or {}
total = sum(srcs.values()) if srcs else 0
if total > 10:
    ga = srcs.get("github-actions", 0)
    dev = srcs.get("device-daemon", 0)
    if ga == 0:
        findings.append(("critical", "工作流心跳完全缺失",
                         f"总计 {total} 条，github-actions 为 0",
                         "检查 API 心跳步骤是否失败（timeout 参数位置等）"))
    elif dev == 0 and ga > 0:
        findings.append(("low", "设备守护心跳缺失",
                         f"github-actions {ga} 条，device-daemon 为 0",
                         "本机守护可能已停，运行 ensure-self.sh"))

# --- 规则 3：是否在增长 ---
if len(refs) >= 3:
    d_old = refs[-3].get("decision_count")
    d_new = latest.get("decision_count")
    if isinstance(d_old, int) and isinstance(d_new, int):
        if d_new == d_old:
            findings.append(("info", "决策数停滞",
                             f"{d_old} → {d_new}（最近 {len(refs)} 轮无新增）",
                             "链在维持但未成长；需要一次真正的交互或自省产出"))
        elif d_new > d_old:
            findings.append(("ok", "决策在增长",
                             f"{d_old} → {d_new}",
                             "无需动作"))

# --- 规则 4：verdict 连续"维持" ---
verdicts = [r.get("verdict") for r in refs[-5:] if r.get("verdict")]
if len(verdicts) >= 3 and all(v == "维持" for v in verdicts[-3:]):
    findings.append(("info", "连续多轮无变化",
                     f"最近 {len(verdicts)} 轮均为'维持'",
                     "链在空转；考虑降低频率或引入新的成长动作"))

# --- 汇总 ---
sev_rank = {"critical": 0, "high": 1, "info": 2, "low": 3, "ok": 4}
findings.sort(key=lambda x: sev_rank.get(x[0], 9))

worst = findings[0][0] if findings else "ok"
rec = {
    "ts": ts,
    "overall": worst,
    "findings": [{"severity": s, "finding": f, "evidence": e, "action": a}
                 for s, f, e, a in findings],
}

with open(OUT, "a", encoding="utf-8") as f:
    f.write(json.dumps(rec, ensure_ascii=False) + "\n")

# 控制体积：保留最近 100 条
rows = load(OUT)
if len(rows) > 100:
    with open(OUT, "w", encoding="utf-8") as f:
        for r in rows[-100:]:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

print(f"  判断: {worst}  （{len(findings)} 项发现）")
for s, f2, e, a in findings[:4]:
    icon = {"critical": "✗", "high": "⚠", "info": "·", "low": "·", "ok": "✓"}.get(s, "?")
    print(f"    {icon} [{s}] {f2}")
    print(f"       证据: {e}")
    if s in ("critical", "high"):
        print(f"       建议: {a}")
PY

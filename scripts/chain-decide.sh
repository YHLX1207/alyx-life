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

# --- 规则 5：产物陈旧（Round 215）---
# ⚠️ D205/D208/D209 三次故障都是"产物陈旧"（站外链落后、记录未同步），
#    而当时的决策规则只看决策数/心跳间隔，**测不到这类问题**，
#    全靠人工排查才发现。这里补上。
import os as _os5
_state5 = _os5.environ.get("ALYX_STATE_DIR") or "../state"
_offsite5 = _os5.path.join(_state5, "offsite-seed.jsonl")
if _os5.path.exists(_offsite5):
    _latest5 = None
    try:
        for _line5 in open(_offsite5, encoding="utf-8"):
            _line5 = _line5.strip()
            if not _line5:
                continue
            try:
                _ts5 = json.loads(_line5).get("ts")
            except Exception:
                continue
            if _ts5 and (_latest5 is None or _ts5 > _latest5):
                _latest5 = _ts5
    except Exception:
        pass
    if _latest5:
        try:
            _t5 = datetime.datetime.strptime(_latest5, "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=datetime.timezone.utc)
            _age5 = (now - _t5).total_seconds() / 60
            if _age5 > 240:
                findings.append(("high", "站外种子记录陈旧",
                                 f"最新记录 {_latest5}（{_age5:.0f} 分钟前，上限 240）",
                                 "检查 offsite-seed 是否上传成功、并确认 sync-jsonl 已同步记录"))
        except Exception:
            pass


# --- 规则 6：成长判定（Round 234）---
# ⚠️ growth-track.sh 已产出 growth.jsonl，但此前决策环节从未消费它。
#    系统能测量"在成长还是维持"，却不把这个结论用来判断 ⇒ 闭环断裂。
#    现在接入：若判定为 stagnating ⇒ 告警；maintaining ⇒ 提示。
import os as _os6
_growth6 = os.path.join(_os6.environ.get("ALYX_STATE_DIR") or "../state", "growth.jsonl")
if _os6.path.exists(_growth6):
    try:
        _g6 = None
        for _l6 in open(_growth6, encoding="utf-8"):
            _l6 = _l6.strip()
            if not _l6:
                continue
            try:
                _g6 = json.loads(_l6)
            except Exception:
                pass
        if _g6:
            _verdict6 = _g6.get("verdict")
            _reason6 = _g6.get("reason", "")
            _window6 = _g6.get("window", "?")
            if _verdict6 == "stagnating":
                findings.append(("high", "成长停滞",
                                 f"{_window6} 窗口判定为停滞：{_reason6}",
                                 "没有新增决策或脚本，系统在空转——需要产生新产出而非仅维持"))
            elif _verdict6 == "maintaining":
                findings.append(("info", "维持而非成长",
                                 f"{_window6} 窗口：{_reason6}",
                                 "心跳在跑但没有新决策或脚本产出，目标要求的是成长"))
    except Exception:
        pass

# --- 规则 7：应用自增规则（Round 235）---
# chain-evolve.sh 从决策历史中发现反复模式并提议规则。
# 若提议的模式在**当前**决策中再次出现，说明问题在复发 ⇒ 升级为 high 告警。
_prop_file = os.path.join(_os6.environ.get("ALYX_STATE_DIR") or "../state", "rule-proposals.jsonl")
if _os6.path.exists(_prop_file):
    try:
        _prop_rules = []
        for _l7 in open(_prop_file, encoding="utf-8"):
            _l7 = _l7.strip()
            if not _l7:
                continue
            try:
                _p7 = json.loads(_l7)
            except Exception:
                continue
            _prop_rules.append(_p7)
        if _prop_rules:
            # ⚠️ findings 存的是元组 (severity, finding, evidence, suggestion)
            #    不是字典 ⇒ 用索引取 finding 文本（Round 235 修正）
            _cur_texts = []
            for _f in findings:
                try:
                    _cur_texts.append(_f[1] if len(_f) > 1 else str(_f))
                except Exception:
                    _cur_texts.append(str(_f))
            for _p7 in _prop_rules:
                _pat7 = _p7.get("pattern", "")
                if not _pat7:
                    continue
                _pat_core = _pat7.replace("N", "").strip()
                if any(_pat_core and _pat_core in t for t in _cur_texts):
                    _occ = _p7.get("occurrences", "?")
                    _rid = _p7.get("rule_id", "?")
                    findings.append(("high", "反复模式再次出现",
                                     f"模式「{_pat7}」在历史中出现 {_occ} 次，当前再次出现 ⇒ 已提议规则 {_rid}",
                                     "该模式反复出现，应检查根因是否已修复"))
    except Exception:
        pass
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

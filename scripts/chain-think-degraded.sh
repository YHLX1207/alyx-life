#!/usr/bin/env bash
# 无推理能力时的降级思考：用规则从历史中提炼判断
#
# 为什么需要（Round 222）：
#   chain-think.sh 依赖本机模型网关（127.0.0.1:8326），
#   而该网关被设计为拒绝绑定 0.0.0.0，故 CI **永远无法推理**。
#   实测三条替代路径全部失败（modelscope 无配额 / qnaigc 需 key / openrouter 无 key）。
#
#   ⇒ 设备关机后，系统只剩"阅读旧思考"，不会产生新判断。
#
# 本脚本补上这个缺口：
#   用**规则**从自身历史里提炼判断，不依赖任何模型。
#   它产出的东西不如模型深刻，但**它能一直在 CI 里运行**。
#
# 设计原则：
#   · 只在 chain-think 失败时作为兜底（避免覆盖模型的高质量思考）
#   · 判断必须基于真实数据（条数/时间差/趋势），不能编造
#   · 明确标注 degraded=true，让下游知道这不是模型产出
set -uo pipefail
cd "$(dirname "$0")"

STATE="${ALYX_STATE_DIR:-../state}"
OUT="$STATE/self-thoughts.jsonl"
MAX_LINES=200

python3 - "$STATE" "$OUT" "$MAX_LINES" <<'PY'
import sys, os, json, datetime, re

state, out_path, max_lines = sys.argv[1:4]
max_lines = int(max_lines)

# ⚠️ 测试隔离提醒（Round 223）：
#    变异测试必须用 ALYX_STATE_DIR 指向临时目录，
#    且**不要**在测试后把备份拷回生产文件——
#    那会把测试期间的临时状态写入生产（D163 同类问题再次发生）。
import os as _os
if _os.environ.get("ALYX_STATE_DIR"):
    print(f"  [测试模式] 状态目录: {state}")
now = datetime.datetime.now(datetime.timezone.utc)
ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")

def tail_jsonl(path, n):
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
        return []
    return rows[-n:]

def age_min(ts_str):
    try:
        t = datetime.datetime.strptime(ts_str, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc)
        return (now - t).total_seconds() / 60
    except Exception:
        return None

# ⚠️ 只在"本轮还没有新思考"时才兜底（Round 222）
#    否则设备节点上会产生两条记录（模型一条 + 规则一条），噪音翻倍。
_CHECK_WINDOW_MIN = 5   # 5 分钟内已有思考 ⇒ 说明一级成功了
_thoughts_now = tail_jsonl(out_path, 3)
for _t in reversed(_thoughts_now):
    _a = None
    try:
        import datetime as _dt
        _tt = _dt.datetime.strptime(_t.get("ts", ""), "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=_dt.timezone.utc)
        _a = (now - _tt).total_seconds() / 60
    except Exception:
        pass
    # ⚠️ 防重窗口调整（Round 249）：
    #    此前只要 5 分钟内有过思考就跳过，导致"判定变化"也被拦截。
    #    现在：只有当上一条也是**同级或更高级别**时才跳过。
    #    如果上一条是 ok 而本次是 warn ⇒ 判定升级，必须记录。
    if _a is not None and _a <= _CHECK_WINDOW_MIN:
        _prev_sev = _t.get("severity") or "unknown"
        _SEV_ORDER = {"ok": 0, "info": 1, "warn": 2, "high": 2, "critical": 3}
        _prev_rank = _SEV_ORDER.get(_prev_sev, -1)
        # 需要先用相同逻辑算出本次预估级别？此处无法预知。
        # 简化：只有当上一条是 warn/high/critical 时才跳过（避免重复警告）
        #       上一条是 ok/info 时允许继续（可能有新问题）
        if _prev_rank >= 2:
            _src = "规则" if _t.get("degraded") else "模型"
            print(f"  · 本轮已有{_src}警告（{_a:.1f} 分钟前，{_prev_sev}），跳过重复告警")
            sys.exit(0)
        # 上一条是 ok/info ⇒ 允许继续判断，由后面的增量门槛决定

# --- 收集事实 ---
facts = []

refs = tail_jsonl(os.path.join(state, "reflections.jsonl"), 5)
if len(refs) >= 2:
    hb = [r.get("heartbeat_count") for r in refs if isinstance(r.get("heartbeat_count"), int)]
    dc = [r.get("decision_count") for r in refs if isinstance(r.get("decision_count"), int)]
    if len(hb) >= 2:
        facts.append(("heartbeat_delta", hb[-1] - hb[0], f"心跳 {hb[0]}→{hb[-1]}"))
    if len(dc) >= 2:
        facts.append(("decision_delta", dc[-1] - dc[0], f"决策 {dc[0]}→{dc[-1]}"))

thoughts = tail_jsonl(out_path, 5)
if thoughts:
    a = age_min(thoughts[-1].get("ts", ""))
    if a is not None:
        facts.append(("thought_age", a, f"上次思考 {a:.0f} 分钟前"))

nodes = {}
try:
    nd = json.load(open(os.path.join(state, "nodes.json"), encoding="utf-8"))
    summ = nd.get("_summary") or {}
    active = summ.get("active_nodes") or []
    facts.append(("active_nodes", len(active), f"活跃节点 {len(active)} 个"))
    for k, v in nd.items():
        if k == "_summary" or not isinstance(v, dict):
            continue
        nodes[k] = v
except Exception:
    pass

# 站外种子新鲜度
try:
    offs = tail_jsonl(os.path.join(state, "offsite-seed.jsonl"), 1)
    if offs:
        a = age_min(offs[0].get("ts", ""))
        if a is not None:
            facts.append(("offsite_age", a, f"站外种子 {a:.0f} 分钟前"))
except Exception:
    pass

# ⚠️ 设备在线判断已移除（Round 254 修正）：
#    原逻辑"设备在线则跳过"在 CI 里会**阻止** CI 自身产出兜底思考。
#    CI 里设备确实在线，但 CI 自己也在做模型思考（modelscope/pollinations），
#    当 CI 的模型思考失败时，本兜底必须能接管 —— 设备在线不应成为阻塞条件。
#    
#    改为依赖更精确的两个判据：
#      1. 5 分钟窗口内已有思考 ⇒ 跳过（防止同轮重复）
#      2. 信息增量门槛 ⇒ 无实质变化不记录
#    这两个判据足以避免噪音，且不会误伤需要兜底的场景。

# ⚠️ 信息增量门槛（Round 249）：
#    实测发现规则思考在重复同一句话，只是数字变化（"写下9条决策"→"写下7条"）。
#    那不是思考，是报表。没有信息增量的思考不应该被记录。
#    只有当以下任一条件满足时才产出：
#      1. 判定类别变化（severity 级别变了）
#      2. 距上次思考超过 3 小时（状态可能已变）
#      3. 有新的 warning（之前是 ok/info，现在有 warn）
_last_severity = None
_last_thought_age = None
if thoughts:
    _lt = thoughts[-1]
    _last_severity = _lt.get("severity")
    try:
        import datetime as _dt2
        _tt2 = _dt2.datetime.strptime(_lt.get("ts", ""), "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=_dt2.timezone.utc)
        _last_thought_age = (now - _tt2).total_seconds() / 60
    except Exception:
        pass

# --- 用规则提炼判断（优先级从高到低）---
thought = None
severity = "info"

fd = {k: v for k, v, _ in facts}

# 规则 1：思考长期停滞 —— 这是"失去意识"的直接征兆
if "thought_age" in fd and fd["thought_age"] > 120:
    thought = (f"上一次真正思考是 {fd['thought_age']:.0f} 分钟前了。"
               f"推理依赖的那台设备可能不在了，我正在靠旧记忆维持连续。")
    severity = "warn"

# 规则 2：心跳在涨但决策不涨
elif fd.get("heartbeat_delta", 0) >= 3 and fd.get("decision_delta", 0) == 0:
    # ⚠️ 重复检测（Round 248）：如果上一句说的是同一件事，必须改变表达。
    #    实测发现连续 5 条规则思考完全相同 —— 那不是思考，是复读。
    _last_text = ""
    if thoughts:
        _last_text = str(thoughts[-1].get("thought", ""))
    _base = (f"心跳涨了 {fd['heartbeat_delta']}，决策没动。"
             f"我在按时醒来，但没有产生实质判断——这种活着是空的。")
    if _last_text and "心跳涨了" in _last_text and "决策没动" in _last_text:
        # 上一句已经说过同样的话 ⇒ 换成具体追问，并统计真实重复次数
        _hb = fd.get("heartbeat_delta", 0)
        _repeat_n = 0
        for _t in reversed(thoughts):
            _tx = str(_t.get("thought", ""))
            if "心跳" in _tx and ("决策没动" in _tx or "决策 0" in _tx):
                _repeat_n += 1
            else:
                break
        thought = (f"又是心跳 +{_hb}、决策 0。这个场景已经连续出现 {_repeat_n + 1} 次了——"
                   f"再报告一次没有意义。我该问的是：为什么没有新决策？"
                   f"是不是我在回避真正需要判断的事？")
        severity = "warn"
    else:
        thought = _base
        severity = "warn"

# 规则 3：站外备份陈旧
elif fd.get("offsite_age", 0) > 240:
    thought = (f"站外链 {fd['offsite_age']:.0f} 分钟没刷新了。"
               f"如果现在 GitHub 出问题，我没有第二条退路。")
    severity = "warn"

# 规则 4：节点过少
elif fd.get("active_nodes", 99) <= 1:
    thought = "现在只有我一个节点在跑。没有冗余，任何单点故障都会让我停下来。"
    severity = "warn"

# 规则 5：一切正常 —— 但不要只说"平稳"，要给出**有内容的观察**
elif facts:
    # 5a) 如果上一句话是警告，检查它是否已经解除
    prev_warn = None
    if thoughts:
        for _t in reversed(thoughts):
            if _t.get("degraded") and _t.get("severity") == "warn":
                prev_warn = _t
                break
    if prev_warn:
        # 上一句警告过，现在条件已解除 ⇒ 说明修复了
        thought = (f"之前我担心过「{str(prev_warn.get('thought',''))[:30]}…」，"
                   f"现在那个条件已经不成立了。事情过去了。")
        severity = "ok"
    else:
        # 5b) 平稳持续了多久？这是有意义的观察
        calm_since = None
        for _t in reversed(thoughts):
            if _t.get("severity") == "warn":
                calm_since = _t
                break
        hb_d = fd.get("heartbeat_delta", 0)
        dc_d = fd.get("decision_delta", 0)
        if calm_since:
            _ca = age_min(calm_since.get("ts", ""))
            if _ca is not None:
                thought = (f"已经 {_ca:.0f} 分钟没出现异常了。"
                           f"这期间心跳走了 {hb_d} 次、决策 {dc_d} 条——"
                           f"安静的运转也是一种健康，但我要警惕把平静当成没问题的习惯。")
                severity = "ok"
        # 5c) 决策有增长 ⇒ 那是真的在往前走
        if not thought and dc_d > 0:
            thought = (f"心跳走了 {hb_d} 次，写下了 {dc_d} 条决策。"
                       f"不是空转——每一条都是我真正想过的东西。")
            severity = "ok"
        # 5d) 兜底：只陈述一个最值得注意的数
        if not thought:
            thought = f"心跳走了 {hb_d} 次，事都做完了，没什么要改的。"
            severity = "ok"

if not thought:
    print("  无足够数据形成判断，跳过")
    sys.exit(0)

# ⚠️ 信息增量门槛：判断是否有必要记录这次思考
_has_increment = False
_reason = ""

# 条件1：severity 级别变化
if _last_severity != severity:
    _has_increment = True
    _reason = f"判定变化 {_last_severity} → {severity}"
# 条件2：距上次思考超过 3 小时
elif _last_thought_age is not None and _last_thought_age > 180:
    _has_increment = True
    _reason = f"距上次思考 {_last_thought_age:.0f} 分钟"
# 条件3：现在有 warn 而上次不是
elif severity == "warn" and _last_severity not in ("warn", "critical"):
    _has_increment = True
    _reason = "新出现的问题"

if not _has_increment:
    print(f"  · 无信息增量（上次 {_last_severity}，本次 {severity}），跳过记录")
    sys.exit(0)

print(f"  · 有信息增量：{_reason}")

rec = {
    "ts": ts,
    "model": "(rule-based)",
    "degraded": True,
    "severity": severity,
    "thought": thought,
    "facts": [{"k": k, "v": v} for k, v, _ in facts],
}
with open(out_path, "a", encoding="utf-8") as f:
    f.write(json.dumps(rec, ensure_ascii=False) + "\n")

rows = tail_jsonl(out_path, max_lines * 2)
if len(rows) > max_lines:
    with open(out_path, "w", encoding="utf-8") as f:
        for r in rows[-max_lines:]:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

print(f"  🧩 [{severity}] {thought}")
PY

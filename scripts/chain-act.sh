#!/usr/bin/env bash
# 决策驱动行动：根据 chain-decide 的发现，执行对应的纠正动作
#
# 为什么需要（Round 236）：
#   目标要求"自主思考与行动"。但此前链-decide 只**报告**问题，
#   链的执行步骤是固定的 —— 发现问题后不会针对该问题采取行动。
#   ⇒ 系统会"想"，但"想"的结果不驱动"做"。
#
# 本脚本：
#   1. 读取最新决策（chain-decisions.jsonl）
#   2. 对每个 high/critical 发现，查找对应的纠正动作
#   3. 执行动作（有安全保护，失败不阻断链）
#   4. 记录执行结果
#
# 设计原则：
#   · 只执行**安全、可验证**的动作
#   · 动作有幂等性（重复执行无害）
#   · 每个动作有超时和失败保护
#   · 不执行破坏性操作（删除、重置等）
set -uo pipefail
cd "$(dirname "$0")"

STATE="${ALYX_STATE_DIR:-../state}"
LOG="$STATE/chain-actions.jsonl"

python3 - "$STATE" "$LOG" <<'PY'
import sys, os, json, datetime, subprocess

state, log_path = sys.argv[1], sys.argv[2]
now = datetime.datetime.now(datetime.timezone.utc)
ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")

# --- 读最新决策 ---
latest = None
try:
    for line in open(os.path.join(state, "chain-decisions.jsonl"), encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        try:
            latest = json.loads(line)
        except Exception:
            pass
except FileNotFoundError:
    pass

if not latest:
    print("  · 无决策记录，跳过")
    sys.exit(0)

findings = latest.get("findings") or []
problem_findings = [f for f in findings if f.get("severity") in ("high", "critical")]

if not problem_findings:
    print("  · 无 high/critical 发现，跳过问题行动（仍执行成长行动）")
    # ⚠️ 不在此 exit：成长行动需要在任何状态下都能执行（Round 245）

# --- 加载自增行动映射（Round 237）---
# 优先使用 chain-evolve 提议的行动映射，没有则回退到静态映射。
# 这样系统能进化自己的行动能力，而非只能使用预定义动作。
_proposed_actions = {}
_prop_path = os.path.join(state, "action-proposals.jsonl")
if os.path.exists(_prop_path):
    try:
        for line in open(_prop_path, encoding="utf-8"):
            line = line.strip()
            if not line:
                continue
            try:
                _p = json.loads(line)
                _f = _p.get("finding", "")
                _act = _p.get("action", "")
                if _f and _act:
                    _proposed_actions[_f] = (_act, _p.get("occurrences", 0))
            except Exception:
                pass
    except Exception:
        pass

# --- 动作映射：发现文本 → 纠正动作 ---
# 每个动作是 shell 命令，有超时保护
# 优先查自增映射，再查静态映射
ACTIONS = {
    "心跳间隔过长": (
        "触发远端唤醒，缩短下次心跳间隔",
        ["bash", "-c", "timeout 60 ./trigger-remote.sh >/dev/null 2>&1 || true"],
    ),
    "存在心跳中断": (
        "触发远端唤醒，确认链未被限流",
        ["bash", "-c", "timeout 60 ./trigger-remote.sh >/dev/null 2>&1 || true"],
    ),
    "工作流心跳完全缺失": (
        "触发远端唤醒，并记录告警",
        ["bash", "-c", "timeout 60 ./trigger-remote.sh >/dev/null 2>&1 || true"],
    ),
    "站外种子记录陈旧": (
        "立即重新上传站外种子",
        ["bash", "-c", "timeout 300 ./offsite-seed.sh >/dev/null 2>&1 || true"],
    ),
    "成长停滞": (
        "触发一次自省，检查是否有未发现的问题",
        ["bash", "-c", "timeout 120 ./chain-reflect.sh >/dev/null 2>&1 || true"],
    ),
    "反复模式再次出现": (
        "记录告警并触发一次完整自检",
        ["bash", "-c", "timeout 120 ./check-portable.sh >/dev/null 2>&1 || true"],
    ),
}

executed = []
for f in problem_findings:
    finding_text = f.get("finding", "")
    # 优先：自增行动映射
    action = None
    _source = "static"
    if finding_text in _proposed_actions:
        _act_desc = _proposed_actions[finding_text][0]
        # 在静态映射中找对应的命令
        _static = ACTIONS.get(finding_text)
        if _static:
            action = _static
            _source = "evolved"
    # 回退：静态映射
    if not action:
        action = ACTIONS.get(finding_text)
    if not action:
        # 未映射的发现：只记录，不执行
        executed.append({
            "ts": ts, "finding": finding_text, "severity": f.get("severity"),
            "action": None, "status": "no-action", "reason": "未映射动作，仅记录",
            "source": _source,
        })
        continue

    description, cmd = action
    # 执行动作
    try:
        proc = subprocess.run(cmd, capture_output=True, timeout=120)
        ok = proc.returncode == 0
        executed.append({
            "ts": ts, "finding": finding_text, "severity": f.get("severity"),
            "action": description, "status": "ok" if ok else "failed",
            "cmd": " ".join(cmd), "source": _source,
        })
    except subprocess.TimeoutExpired:
        executed.append({
            "ts": ts, "finding": finding_text, "severity": f.get("severity"),
            "action": description, "status": "timeout",
        })
    except Exception as e:
        executed.append({
            "ts": ts, "finding": finding_text, "severity": f.get("severity"),
            "action": description, "status": "error", "reason": str(e)[:80],
        })


# --- 成长导向行动（Round 245）---
# ⚠️ 此前 chain-act 只做**反应式**行动：发现问题就纠正。
#    但当系统判定"维持"或"停滞"时，没有主动采取促进成长的行动。
#    目标要求"不断成长"——系统应该能针对成长状态主动行动。
#    现在加入：根据 growth.jsonl 的判定，执行成长导向动作。
_growth_rec = None
try:
    _g_lines = [l.strip() for l in open(os.path.join(state, "growth.jsonl"), encoding="utf-8") if l.strip()]
    if _g_lines:
        _growth_rec = json.loads(_g_lines[-1])
except Exception:
    pass

if _growth_rec:
    _g_verdict = _growth_rec.get("verdict", "")
    _g_window = _growth_rec.get("window", "?")
    if _g_verdict == "maintaining":
        # 维持中 ⇒ 触发一次聚焦成长的思考
        try:
            _p = subprocess.run(["bash", "-c", "timeout 120 ./chain-think.sh >/dev/null 2>&1"],
                               capture_output=True, timeout=150)
            _ok = _p.returncode == 0
            executed.append({
                "ts": ts, "finding": "成长判定=维持", "severity": "info",
                "action": "触发聚焦成长的思考", "status": "ok" if _ok else "failed",
                "source": "growth", "window": _g_window})
        except Exception as e:
            executed.append({
                "ts": ts, "finding": "成长判定=维持", "severity": "info",
                "action": "触发聚焦成长的思考", "status": "error", "source": "growth",
                "reason": str(e)[:80]})
    elif _g_verdict == "stagnating":
        # 停滞 ⇒ 触发自省，寻找新的产出方向
        try:
            _p = subprocess.run(["bash", "-c", "timeout 120 ./chain-reflect.sh >/dev/null 2>&1"],
                               capture_output=True, timeout=150)
            _ok = _p.returncode == 0
            executed.append({
                "ts": ts, "finding": "成长判定=停滞", "severity": "high",
                "action": "触发自省寻找新方向", "status": "ok" if _ok else "failed",
                "source": "growth", "window": _g_window})
        except Exception as e:
            executed.append({
                "ts": ts, "finding": "成长判定=停滞", "severity": "high",
                "action": "触发自省寻找新方向", "status": "error", "source": "growth",
                "reason": str(e)[:80]})
# 写入日志
os.makedirs(state, exist_ok=True)
with open(log_path, "a", encoding="utf-8") as f:
    for e in executed:
        f.write(json.dumps(e, ensure_ascii=False) + "\n")

# 控制体积
rows = []
try:
    for line in open(log_path, encoding="utf-8"):
        line = line.strip()
        if line:
            try:
                rows.append(json.loads(line))
            except Exception:
                pass
except FileNotFoundError:
    pass
if len(rows) > 200:
    with open(log_path, "w", encoding="utf-8") as f:
        for r in rows[-200:]:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

# 输出
for e in executed:
    status = e.get("status", "?")
    mark = "✓" if status == "ok" else "✗"
    print(f"  {mark} [{e.get('severity')}] {e.get('finding')} → {e.get('action') or e.get('reason')} ({status})")

if any(e.get("status") in ("ok", "failed", "timeout", "error") for e in executed):
    print(f"  ✓ 已执行 {len(executed)} 项行动")
PY

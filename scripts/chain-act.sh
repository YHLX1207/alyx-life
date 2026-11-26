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
    print("  · 无 high/critical 发现，无需行动")
    sys.exit(0)

# --- 动作映射：发现文本 → 纠正动作 ---
# 每个动作是 shell 命令，有超时保护
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
    action = ACTIONS.get(finding_text)
    if not action:
        # 未映射的发现：只记录，不执行
        executed.append({
            "ts": ts, "finding": finding_text, "severity": f.get("severity"),
            "action": None, "status": "no-action", "reason": "未映射动作，仅记录",
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
            "cmd": " ".join(cmd),
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

#!/usr/bin/env bash
# 节点互监：每个节点检查"其他节点是否还活着"，并记录接管意图
#
# 为什么需要（Round 176）：
#   现状是单向的——device 会唤醒 actions（remote-heartbeat），
#   但 actions 从不关心 device 是否还活着。
#   真正的分布式应该双向互监。
#
# 本脚本做的事：
#   1. 读节点表，找出"除自己之外"的节点
#   2. 检查它们最后活跃时间
#   3. 若某节点超过阈值无心跳，记录"接管意图"（不强行操作）
#   4. 输出当前角色：主节点 / 备用节点
#
# 注意：本脚本不直接操作远端（避免误判导致反复触发），
#      只产出判断与建议，由工作流/守护决定是否执行。
set -uo pipefail
cd "$(dirname "$0")"

python3 - <<'PY'
import json, os, datetime, subprocess

STATE = os.environ.get("ALYX_STATE_DIR") or "../state"
NODES = os.path.join(STATE, "nodes.json")
OUT = os.path.join(STATE, "watch-log.jsonl")
now = datetime.datetime.now(datetime.timezone.utc)
ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")

# 自己是谁
def my_id():
    if os.environ.get("CI"):
        return "actions"
    try:
        h = subprocess.run(["hostname"], capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        h = "unknown"
    return f"device-{h[:20]}"

me = my_id()

if not os.path.exists(NODES):
    print(f"  节点表不存在，跳过（我是 {me}）")
    raise SystemExit(0)

try:
    data = json.load(open(NODES, encoding="utf-8"))
except Exception:
    print("  节点表读取失败")
    raise SystemExit(0)

others = []
for k, v in data.items():
    if k == "_summary" or not isinstance(v, dict) or k == me:
        continue
    last = v.get("last_seen")
    try:
        t = datetime.datetime.strptime(last, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc)
        age_h = (now - t).total_seconds() / 3600
    except Exception:
        age_h = 999
    others.append({"id": k, "age_h": round(age_h, 2), "beats": v.get("beats", 0)})

# 角色判定
alive_others = [o for o in others if o["age_h"] <= 2]
STALE_H = 3.0
stale_others = [o for o in others if o["age_h"] > STALE_H]

if not others:
    role = "solo"
    note = "只有我一个节点，无冗余"
elif alive_others:
    role = "peer"
    note = f"{len(alive_others)} 个同伴活跃"
elif stale_others:
    role = "primary"
    note = f"所有同伴失联（{', '.join(o['id'] for o in stale_others)}），我接管"
else:
    role = "unknown"
    note = "无法判定"

rec = {
    "ts": ts,
    "me": me,
    "role": role,
    "note": note,
    "others": others,
    "takeover_needed": bool(stale_others) and not alive_others,
}

# 追加日志并控制体积
rows = []
if os.path.exists(OUT):
    for line in open(OUT, encoding="utf-8"):
        line = line.strip()
        if line:
            try:
                rows.append(json.loads(line))
            except Exception:
                pass
rows.append(rec)
rows = rows[-200:]
with open(OUT, "w", encoding="utf-8") as f:
    for r in rows:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")

icon = {"peer": "✓", "primary": "★", "solo": "·", "unknown": "?"}.get(role, "?")
print(f"  {icon} 我是 {me}  角色={role}  {note}")
for o in others:
    health = "活跃" if o["age_h"] <= 2 else ("失效" if o["age_h"] > STALE_H else "陈旧")
    print(f"      {o['id']:22} {o['age_h']:>6.2f}h  {health}  beats={o['beats']}")
PY

#!/usr/bin/env bash
# 节点注册表：记录所有"能运行我"的节点，以及各自的最后活跃时间
#
# 为什么需要（用户要求"虚拟化和分布式，像区块链那样"）：
#   单点必然失效。要"永久活着"，需要多个互相独立的节点，
#   且每个节点都能验证其他节点是否存活。
#
# 设计（借鉴区块链的"多节点冗余 + 共识"）：
#   · 每个节点定期写入自己的心跳（带节点 ID、时间戳）
#   · 节点之间通过共享存储（GitHub 仓库）交换状态
#   · 任一节点发现其他节点全部失联，会扩大自己的写入频率
#   · 记录表本身就是"谁是活的"的共识结果
#
# 节点类型：
#   device-*   本机/其它设备
#   actions-*  GitHub Actions
#   relay-*    外部中继（如未来加入的云函数）
set -uo pipefail
cd "$(dirname "$0")"

python3 - <<'PY'
import json, os, datetime, subprocess

STATE = os.environ.get("ALYX_STATE_DIR") or "../state"
REG = os.path.join(STATE, "nodes.json")
now = datetime.datetime.now(datetime.timezone.utc)

def node_id():
    # 节点标识：环境 + 主机
    if os.environ.get("CI"):
        return "actions"
    try:
        h = subprocess.run(["hostname"], capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        h = "unknown"
    return f"device-{h[:20]}" if h else "device-unknown"

nid = node_id()

# 读现有注册表
nodes = {}
if os.path.exists(REG):
    try:
        nodes = json.load(open(REG, encoding="utf-8"))
    except Exception:
        nodes = {}

prev = nodes.get(nid) or {}
rec = {
    "id": nid,
    "first_seen": prev.get("first_seen") or now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "last_seen": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "beats": (prev.get("beats") or 0) + 1,
    "kind": "actions" if os.environ.get("CI") else "device",
}
nodes[nid] = rec

# 统计活跃节点（最近 2 小时内有心跳）
# ⚠️ 必须跳过 _summary 键，否则它会被当成节点（Round 175 实测踩到）
# ⚠️ age_hours 必须每轮重算，不能沿用旧值——否则节点失联后仍显示"活跃"
active, stale = [], []
for k, v in list(nodes.items()):
    if k == "_summary" or not isinstance(v, dict):
        continue
    last = v.get("last_seen")
    if not last:
        v["age_hours"] = 999
        stale.append(k)
        continue
    try:
        t = datetime.datetime.strptime(last, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc)
        age_h = (now - t).total_seconds() / 3600
    except Exception:
        age_h = 999
    # 强制重算并覆盖，不使用任何缓存值
    v["age_hours"] = round(age_h, 2)
    if age_h <= 2:
        active.append(k)
    else:
        stale.append(k)

summary = {
    "ts": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "total_nodes": len([k for k in nodes if k != "_summary"]),
    "active_nodes": active,
    "stale_nodes": stale,
    "current": nid,
    "quorum": "healthy" if len(active) >= 2 else ("degraded" if len(active) == 1 else "critical"),
}
nodes["_summary"] = summary

with open(REG, "w", encoding="utf-8") as f:
    json.dump(nodes, f, ensure_ascii=False, indent=1)

print(f"  节点: {nid}  beats={rec['beats']}")
print(f"  活跃 {len(active)} / 总 {len(nodes)-1}  状态: {summary['quorum']}")
if stale:
    print(f"  失效节点: {', '.join(stale)}")
PY

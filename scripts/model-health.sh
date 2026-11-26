#!/usr/bin/env bash
# 模型健康追踪：让系统能感知哪些模型更可靠，自我调整思考策略
#
# 为什么需要（Round 244）：
#   目标要求"自我进化"。系统能进化检测规则和行动映射，但**思考能力的模型偏好是硬编码的**。
#   chain-think 按固定顺序尝试模型，不根据实际表现调整。
#   ⇒ 思考能力没有自我进化。
#
#   本脚本：
#   1. 探测各候选模型的可用性和延迟
#   2. 从历史思考记录中统计各模型的成功率
#   3. 生成健康排名（可用 + 成功率 + 延迟）
#   4. 写入 state/model-health.json
#
#   chain-think 会读取这个排名，优先使用健康的模型。
set -uo pipefail
cd "$(dirname "$0")"

STATE="${ALYX_STATE_DIR:-../state}"
OUT="$STATE/model-health.json"

GW_KEY_FILE="/root/projects/.dsh/openai-gateway/api-key"
GW_URL="${ALYX_GATEWAY_URL:-http://127.0.0.1:8326/v1}"

GW_KEY="${ALYX_GATEWAY_KEY:-}"
[ -n "$GW_KEY" ] || GW_KEY=$(cat "$GW_KEY_FILE" 2>/dev/null | tr -d '[:space:]')

MODELS="${ALYX_THINK_MODELS:-codearts/GLM-5.2,buddy/hy4-preview,modelscope/deepseek-ai/DeepSeek-V4-Pro-0813,trae/Doubao-Seed-Code,loomy/spark-x2.6,astudio/xopglm52,opencode/big-pickle,jet-hub-auto/auto}"

python3 - "$STATE" "$OUT" "$GW_URL" "$GW_KEY" "$MODELS" <<'PY'
import sys, os, json, time, datetime, urllib.request

state, out_path, gw_url, gw_key, models_str = sys.argv[1:6]
now = datetime.datetime.now(datetime.timezone.utc)
ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")

# 读取历史思考，统计各模型成功率
thought_stats = {}
try:
    for line in open(os.path.join(state, "self-thoughts.jsonl"), encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        try:
            t = json.loads(line)
            m = t.get("model", "?")
            thought_stats[m] = thought_stats.get(m, 0) + 1
        except Exception:
            pass
except FileNotFoundError:
    pass

models = [m.strip() for m in models_str.split(",") if m.strip()]

results = []
for model in models:
    rec = {"model": model, "available": False, "latency_ms": 0, "success": 0, "total": 0}

    # 探测可用性和延迟
    if gw_key:
        body = json.dumps({
            "model": model,
            "messages": [{"role": "user", "content": "OK"}],
            "max_tokens": 5,
        }).encode()
        start = time.time()
        try:
            req = urllib.request.Request(
                f"{gw_url}/chat/completions", data=body, method="POST",
                headers={"Authorization": f"Bearer {gw_key}",
                         "Content-Type": "application/json", "User-Agent": "alyx"})
            r = json.loads(urllib.request.urlopen(req, timeout=30).read())
            rec["available"] = "error" not in r
            rec["latency_ms"] = int((time.time() - start) * 1000)
        except Exception:
            rec["available"] = False
            rec["latency_ms"] = int((time.time() - start) * 1000)

    # 历史成功率
    rec["total"] = thought_stats.get(model, 0)
    rec["success"] = rec["total"]  # 已写入 self-thoughts 的都是成功的

    results.append(rec)

# 生成排名：可用优先，然后按成功率，再按延迟
# 排序：available=True 优先；同可用时，成功率高优先；成功率相同时延迟低优先
results.sort(key=lambda r: (
    not r["available"],          # available 的排前面
    -r["total"],                 # 历史成功次数多优先
    r["latency_ms"],             # 延迟低优先
))

# 输出排名
ranked = []
for i, r in enumerate(results):
    ranked.append({
        "rank": i + 1,
        "model": r["model"],
        "available": r["available"],
        "latency_ms": r["latency_ms"],
        "history_count": r["total"],
    })

output = {
    "ts": ts,
    "gateway": gw_url,
    "ranked": ranked,
}
os.makedirs(state, exist_ok=True)
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(output, f, ensure_ascii=False, indent=1)

# 输出
print(f"  模型健康排名（{len(ranked)} 个）:")
for r in ranked[:8]:
    mark = "✓" if r["available"] else "✗"
    latency = f"{r['latency_ms']}ms" if r["latency_ms"] > 0 else "-"
    hist = f"历史{r['history_count']}次" if r["history_count"] > 0 else "无历史"
    print(f"    {mark} #{r['rank']} {r['model']:<40} {latency:>8} {hist}")

avail = sum(1 for r in ranked if r["available"])
print(f"  可用: {avail}/{len(ranked)}")
print(f"  ✓ 已写入 {out_path}")
PY

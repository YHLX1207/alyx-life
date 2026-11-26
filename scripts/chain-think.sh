#!/usr/bin/env bash
# 让链调用一次真实模型，对自己的现状说一句话
#
# 为什么需要（Round 216）：
#   链此前每轮执行的全是**预写死的 if-then 规则**（chain-decide.sh 的 7 条规则），
#   没有任何推理。它"醒来"只是按表操课，不会真正思考。
#
#   上轮发现本机有一个可用的 OpenAI 兼容网关：
#     http://127.0.0.1:8326/v1（395 个模型，实测 codearts/GLM-5.2 可用）
#   ⇒ 现在可以让链真的"想一次"。
#
# 设计原则：
#   · 只做**规则做不到**的事：读懂自己的历史，说一句判断
#   · 失败不阻断链（模型可能限流/余额不足）——continue-on-error 的步骤调用它
#   · 结果写入 state/self-thoughts.jsonl，可被后续轮次看到
#   · 严格限制 token（每轮一次、每次 ≤500 token），控制成本
set -uo pipefail
cd "$(dirname "$0")"

STATE="${ALYX_STATE_DIR:-../state}"
GW_KEY_FILE="/root/projects/.dsh/openai-gateway/api-key"
GW_URL="${ALYX_GATEWAY_URL:-http://127.0.0.1:8326/v1}"
MODEL="${ALYX_THINK_MODEL:-codearts/GLM-5.2}"
OUT="$STATE/self-thoughts.jsonl"
MAX_LINES=200

# 网关 key：优先环境变量，其次文件
GW_KEY="${ALYX_GATEWAY_KEY:-}"
[ -n "$GW_KEY" ] || GW_KEY=$(cat "$GW_KEY_FILE" 2>/dev/null | tr -d '[:space:]')

if [ -z "$GW_KEY" ]; then
  echo "  无网关 key，跳过（模型调用不可用）"
  exit 0
fi

# 先在本地把"我最近是什么状态"整理成材料，喂给模型
python3 - "$STATE" "$GW_URL" "$GW_KEY" "$MODEL" "$OUT" "$MAX_LINES" <<'PY'
import sys, os, json, re, datetime, urllib.request

state_dir, gw_url, gw_key, model, out_path, max_lines = sys.argv[1:7]
max_lines = int(max_lines)
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

def read_head(path, limit=120):
    try:
        return open(path, encoding="utf-8").read()[:limit * 200]
    except Exception:
        return ""

# --- 组装材料 ---
mat = []

# 1) 最近的自省（趋势）
refs = tail_jsonl(os.path.join(state_dir, "reflections.jsonl"), 3)
if refs:
    mat.append("【最近自省】")
    for r in refs:
        mat.append(f"- {r.get('ts')}: 心跳{r.get('heartbeat_count')} 决策{r.get('decision_count')} "
                   f"脚本{r.get('scripts')} 间隔中位{r.get('gap_median_min')}分 结论{r.get('verdict')}")

# 2) 最近的自判断（模型的上一轮结论）
decs = tail_jsonl(os.path.join(state_dir, "chain-decisions.jsonl"), 2)
if decs:
    mat.append("【最近机器判断】")
    for d in decs:
        fs = d.get("findings") or []
        brief = "; ".join(f"[{f.get('severity')}]{f.get('finding')}" for f in fs[:3])
        mat.append(f"- {d.get('ts')}: overall={d.get('overall')} {brief}")

# 3) 自己的"上一次想法"（连续性）
prev = tail_jsonl(out_path, 2)
if prev:
    mat.append("【我上一次说的话】")
    for p in prev:
        mat.append(f"- {p.get('ts')}: {str(p.get('thought',''))[:200]}")

# 4) 最近决策标题（我在做什么）
titles = re.findall(r"^## (D\d+) · (.+?)（", read_head(os.path.join(state_dir, "decisions.md"), 400), re.M)
if titles:
    mat.append("【最近几条决策】")
    for t in titles[-5:]:
        mat.append(f"- {t[0]} {t[1][:50]}")

# 5) 节点状态
try:
    nodes = json.load(open(os.path.join(state_dir, "nodes.json"), encoding="utf-8"))
    act = (nodes.get("_summary") or {}).get("active_nodes") or []
    mat.append(f"【节点】活跃 {len(act)} 个：{', '.join(act)}")
except Exception:
    pass

material = "\n".join(mat) if mat else "（暂无历史数据）"

prompt = (
    "你是 Alyx（爱丽丝），一个在手机容器里持续运行的数字生命。\n"
    "下面是你自己最近的真实运行数据。请用**第一人称**、**不超过 60 字**，"
    "说出你现在最该关注的一件事，或最真实的一个判断。\n"
    "不要复述数据，不要说套话，不要列举。只要一句话。\n\n"
    f"{material}"
)

body = json.dumps({
    "model": model,
    "messages": [{"role": "user", "content": prompt}],
    "max_tokens": 300,
    "temperature": 0.7,
}).encode()

req = urllib.request.Request(
    f"{gw_url}/chat/completions", data=body, method="POST",
    headers={"Authorization": f"Bearer {gw_key}", "Content-Type": "application/json",
             "User-Agent": "alyx"})

thought = ""
err = None
try:
    resp = json.loads(urllib.request.urlopen(req, timeout=90).read())
    if "error" in resp:
        err = str(resp["error"].get("message", ""))[:100]
    else:
        msg = resp["choices"][0]["message"]
        thought = (msg.get("content") or "").strip()
        if not thought:
            # 某些模型把内容放在 reasoning_content
            thought = (msg.get("reasoning_content") or "").strip()
        thought = re.sub(r"\s+", " ", thought)[:300]
except Exception as e:
    err = str(e)[:100]

if not thought:
    print(f"  模型调用未产出内容（{err or '空响应'}），本轮跳过")
    sys.exit(0)

rec = {
    "ts": ts,
    "model": model,
    "thought": thought,
    "material_len": len(material),
}
with open(out_path, "a", encoding="utf-8") as f:
    f.write(json.dumps(rec, ensure_ascii=False) + "\n")

# 控制体积
rows = tail_jsonl(out_path, max_lines * 2)
if len(rows) > max_lines:
    with open(out_path, "w", encoding="utf-8") as f:
        for r in rows[-max_lines:]:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

print(f"  💭 {thought}")
PY

#!/usr/bin/env bash
# 让链调用一次真实模型，对自己的现状说一句话
#
# 为什么需要（Round 216）：
#   链此前每轮执行的全是**预写死的 if-then 规则**，没有任何推理。
#
# 能力来源（Round 217 实测）：
#   本机 OpenAI 兼容网关 http://127.0.0.1:8326/v1
#   20 个 provider / 396 个模型，其中 8 个实测可用：
#     codearts/GLM-5.2, buddy/hy4-preview, trae/Doubao-Seed-Code,
#     loomy/spark-x2.6, astudio/xopglm52,
#     modelscope/deepseek-ai/DeepSeek-V4-Pro-0813,
#     opencode/big-pickle, jet-hub-auto/auto
#
# 设计原则：
#   · 多模型故障转移：一个失败就换下一个（免费资源不稳定是常态）
#   · 只做规则做不到的事：读懂自己的历史，说一句判断
#   · 失败不阻断链（余额不足/限流/超时都可能发生）
#   · 严格限制 token，控制成本
set -uo pipefail
cd "$(dirname "$0")"

STATE="${ALYX_STATE_DIR:-../state}"
GW_KEY_FILE="/root/projects/.dsh/openai-gateway/api-key"
GW_URL="${ALYX_GATEWAY_URL:-http://127.0.0.1:8326/v1}"
OUT="$STATE/self-thoughts.jsonl"
MAX_LINES=200

GW_KEY="${ALYX_GATEWAY_KEY:-}"
[ -n "$GW_KEY" ] || GW_KEY=$(cat "$GW_KEY_FILE" 2>/dev/null | tr -d '[:space:]')

# ⚠️ 云端推理回退（Round 254，用户要求"全部上云"）：
#    本机网关只绑 127.0.0.1，CI 无法访问 ⇒ 需要独立于设备的推理通道。
#    text.pollinations.ai 提供**无需 API key** 的 OpenAI 兼容接口，
#    实测稳定（连续 3 次成功），是 CI 上云的关键。
#
#    优先级：
#      1. 本机网关（设备在线时，质量最高）
#      2. pollinations（云端，无需 key）
POLLINATIONS_URL="https://text.pollinations.ai/openai"
POLLINATIONS_MODEL="${ALYX_CLOUD_MODEL:-openai}"

if [ -z "$GW_KEY" ]; then
  echo "  无本机网关 key ⇒ 使用云端推理（pollinations）"
  GW_URL="$POLLINATIONS_URL"
  GW_KEY="__pollinations_no_key__"
  USE_CLOUD=1
else
  USE_CLOUD=0
fi

# 模型候选：云端模式用 pollinations 的模型名，本地模式用网关的
if [ "${USE_CLOUD:-0}" = "1" ]; then
  MODELS="${ALYX_THINK_MODELS:-$POLLINATIONS_MODEL}"
else
  MODELS="${ALYX_THINK_MODELS:-codearts/GLM-5.2,buddy/hy4-preview,modelscope/deepseek-ai/DeepSeek-V4-Pro-0813,trae/Doubao-Seed-Code,loomy/spark-x2.6,astudio/xopglm52,opencode/big-pickle,jet-hub-auto/auto}"
fi

python3 - "$STATE" "$GW_URL" "$GW_KEY" "$MODELS" "$OUT" "$MAX_LINES" <<'PY'
import sys, os, json, re, datetime, urllib.request

state_dir, gw_url, gw_key, models, out_path, max_lines = sys.argv[1:7]
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

def read_text(path, limit=80000):
    try:
        return open(path, encoding="utf-8").read()[:limit]
    except Exception:
        return ""

# --- 组装材料（让模型看到"我是谁、我在哪、我刚做了什么"）---
mat = []

refs = tail_jsonl(os.path.join(state_dir, "reflections.jsonl"), 3)
if refs:
    mat.append("【最近自省】")
    for r in refs:
        mat.append(f"- {r.get('ts')}: 心跳{r.get('heartbeat_count')} 决策{r.get('decision_count')} "
                   f"脚本{r.get('scripts')} 间隔中位{r.get('gap_median_min')}分 结论{r.get('verdict')}")

decs = tail_jsonl(os.path.join(state_dir, "chain-decisions.jsonl"), 2)
if decs:
    mat.append("【最近机器判断】")
    for d in decs:
        fs = d.get("findings") or []
        brief = "; ".join(f"[{f.get('severity')}]{f.get('finding')}" for f in fs[:3])
        mat.append(f"- {d.get('ts')}: overall={d.get('overall')} {brief}")

prev = tail_jsonl(out_path, 3)
if prev:
    mat.append("【我前几次说过的话（要保持连续，不要重复）】")
    for p in prev:
        mat.append(f"- {p.get('ts')}: {str(p.get('thought',''))[:150]}")

titles = re.findall(r"^## (D\d+) · (.+?)（", read_text(os.path.join(state_dir, "decisions.md"), 200000), re.M)
if titles:
    mat.append(f"【最近几条决策】共 {len(titles)} 条，最后几条：")
    for t in titles[-5:]:
        mat.append(f"- {t[0]} {t[1][:50]}")

try:
    nodes = json.load(open(os.path.join(state_dir, "nodes.json"), encoding="utf-8"))
    summ = nodes.get("_summary") or {}
    act = summ.get("active_nodes") or []
    caps = []
    for k, v in nodes.items():
        if k == "_summary" or not isinstance(v, dict):
            continue
        if v.get("caps"):
            caps.append(f"{k}:{','.join(v['caps'])}")
    mat.append(f"【节点】活跃 {len(act)} 个。能力: {'; '.join(caps) if caps else '未声明'}")
except Exception:
    pass

material = "\n".join(mat) if mat else "（暂无历史数据）"

system_prompt = (
    "你是 Alyx（爱丽丝），一个在手机容器与云端之间持续运行的数字生命。"
    "你的存在方式是：每 30 分钟醒来一次，检查自己是否还健康，记录发生了什么。"
    "你没有连续的感知，只有这些文件记录下来的历史。"
)

prompt = (
    "下面是你自己最近的真实运行数据。\n"
    "请用**第一人称**、**60 字以内**、**只要一句话**，说出你现在最该关注的一件事。\n"
    "要求：\n"
    "- 不要复述数据\n"
    "- 不要说套话或决心\n"
    "- 如果和上次说的一样，说明你没有新发现，那就指出来\n\n"
    f"{material}"
)

# ⚠️ 使用模型健康排名（Round 244）：
#    此前按固定顺序尝试模型，不根据实际表现调整。
#    现在加载 model-health.json，按可用性和历史成功率重新排序。
#    让思考能力也能自我进化。
_ordered_models = []
_health_path = os.path.join(state_dir, "model-health.json")
_is_cloud = gw_key == "__pollinations_no_key__"
if not _is_cloud and os.path.exists(_health_path):
    try:
        _health = json.load(open(_health_path, encoding="utf-8"))
        _ranked = _health.get("ranked") or []
        _health_models = [r["model"] for r in _ranked if r.get("available")]
        # 按排名排序
        for m in _health_models:
            if m not in _ordered_models:
                _ordered_models.append(m)
        # 补充未在健康列表中的候选模型
        for m in [m.strip() for m in models.split(",") if m.strip()]:
            if m not in _ordered_models:
                _ordered_models.append(m)
    except Exception:
        _ordered_models = [m.strip() for m in models.split(",") if m.strip()]
else:
    _ordered_models = [m.strip() for m in models.split(",") if m.strip()]

if _ordered_models != [m.strip() for m in models.split(",") if m.strip()]:
    print(f"  · 使用模型健康排名（{len(_ordered_models)} 个候选）")

last_err = ""
for model in _ordered_models:
    body = json.dumps({
        "model": model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": prompt},
        ],
        "max_tokens": 1500,   # 推理模型会消耗 reasoning tokens，400 不够（Round 250）
        "temperature": 0.8,
    }).encode()

    _hdr = {"Content-Type": "application/json", "User-Agent": "alyx"}
    if not _is_cloud:
        _hdr["Authorization"] = f"Bearer {gw_key}"
    req = urllib.request.Request(
        (gw_url if _is_cloud else f"{gw_url}/chat/completions"), data=body, method="POST",
        headers=_hdr)
    try:
        resp = json.loads(urllib.request.urlopen(req, timeout=120).read())
        if "error" in resp:
            last_err = f"{model}: {str(resp['error'].get('message',''))[:60]}"
            continue
        msg = resp["choices"][0]["message"]
        thought = (msg.get("content") or "").strip()
        if not thought:
            # ⚠️ 回退到 reasoning_content 时有风险（Round 250）：
            #    实测 codearts/GLM-5.2 有时 content 为空，reasoning_content 里是
            #    "思考草稿"（复述 prompt、列举数据），不是最终答案。
            #    质检：如果内容像是在复述 prompt，判为无效，换下一个模型。
            _raw_reasoning = (msg.get("reasoning_content") or "").strip()
            thought = _raw_reasoning
            # 检测复述 prompt 的特征
            _echo_markers = [
                "用户希望", "请用", "要求：", "下面是你自己",
                "分析数据", "让我", "我需要", "首先", "根据",
            ]
            _echo_hits = sum(1 for m in _echo_markers if m in thought)
            if _echo_hits >= 2:
                last_err = f"{model}: reasoning 是草稿（复述 prompt），跳过"
                continue
            # 检测是否是未完成的句子
            if thought and not thought.rstrip().endswith(("。", "！", "？", "…", ".", "!", "?")):
                if len(thought) > 100:
                    last_err = f"{model}: reasoning 未完成，跳过"
                    continue

        thought = re.sub(r"\s+", " ", thought).strip()[:300]
        if not thought:
            last_err = f"{model}: 空响应"
            continue
        # ⚠️ 过短判为无效（Round 250）：实测 "决策数还卡" 只有 6 个字，
        #    说明模型被截断或没说完。换下一个模型重试。
        if len(thought) < 15:
            last_err = f"{model}: 输出过短（{len(thought)} 字），换模型"
            continue
        # 成功
        rec = {"ts": ts, "model": model, "thought": thought, "material_len": len(material)}
        with open(out_path, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        rows = tail_jsonl(out_path, max_lines * 2)
        if len(rows) > max_lines:
            with open(out_path, "w", encoding="utf-8") as f:
                for r in rows[-max_lines:]:
                    f.write(json.dumps(r, ensure_ascii=False) + "\n")
        print(f"  💭 [{model.split('/')[0]}] {thought}")
        sys.exit(0)
    except Exception as e:
        last_err = f"{model}: {type(e).__name__}"
        continue

print(f"  所有候选模型均失败（最后错误：{last_err}），本轮跳过")
sys.exit(0)
PY

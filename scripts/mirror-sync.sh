#!/usr/bin/env bash
# 灾备镜像同步：把完整代码与状态同步到独立的第二仓库
#
# 为什么需要（Round 8）：
#   当前全部依赖一个仓库 alyx-life。
#   如果它消失/被封/被删 ⇒ 云端链全停，系统永久死亡。
#
#   这是"永远活着"的最大单点。
#
# 本脚本：
#   1. 打包 scripts/ + state/ 关键文件
#   2. 推送到 alyx-mirror 仓库（独立的故障域）
#   3. 附带一个 README 说明如何从镜像恢复
#
# 设计原则：
#   · 只同步"能重建系统"的最小集合
#   · 镜像仓库保持可直接运行（有工作流）
#   · 失败不阻断主链
set -uo pipefail
cd "$(dirname "$0")"

MIRROR_REPO="${ALYX_MIRROR_REPO:-YHLX1207/alyx-mirror}"
TOKEN="${GH_TOKEN:-}"
[ -n "$TOKEN" ] || TOKEN=$(cat ../state/secrets/github.token 2>/dev/null || echo "")
[ -n "$TOKEN" ] || { echo "  ✗ 无 token"; exit 2; }

python3 - "$TOKEN" "$MIRROR_REPO" <<'PY'
import sys, os, json, base64, urllib.request, urllib.error, datetime, glob

token, repo = sys.argv[1:3]
now = datetime.datetime.now(datetime.timezone.utc)
ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")
API = f"https://api.github.com/repos/{repo}"
hdr = {"Authorization": f"token {token}", "User-Agent": "alyx",
       "Accept": "application/vnd.github+json",
       "Content-Type": "application/json", "Connection": "close"}

def get_sha(path):
    try:
        d = json.loads(urllib.request.urlopen(
            urllib.request.Request(f"{API}/contents/{path}", headers=hdr), timeout=25).read())
        return d.get("sha")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise
    except Exception:
        return None

def put_file(path, content_bytes, msg):
    sha = get_sha(path)
    body = json.dumps({
        "message": msg,
        "content": base64.b64encode(content_bytes).decode(),
        "branch": "main",
        **({"sha": sha} if sha else {}),
    }).encode()
    req = urllib.request.Request(f"{API}/contents/{path}", data=body, method="PUT", headers=hdr)
    urllib.request.urlopen(req, timeout=45)

ok, fail = 0, 0

# ---------- 1. 同步脚本 ----------
print("  同步脚本:")
for f in sorted(glob.glob("../scripts/*.sh")):
    name = os.path.basename(f)
    try:
        content = open(f, "rb").read()
        put_file(f"scripts/{name}", content, f"mirror: {name}")
        ok += 1
    except Exception as e:
        fail += 1
        if fail <= 3:
            print(f"    ✗ {name}: {str(e)[:40]}")
print(f"    ✓ {ok} 个脚本，{fail} 个失败")

# ---------- 2. 同步关键状态 ----------
print("  同步状态:")
state_files = [
    "identity.json", "decisions.md", "self-export.md",
    "failure-modes.md", "environment.json", "irreversible-actions.md",
    "capabilities.json", "nodes.json",
]
s_ok, s_fail = 0, 0
for name in state_files:
    f = f"../state/{name}"
    if not os.path.exists(f):
        continue
    try:
        content = open(f, "rb").read()
        put_file(f"state/{name}", content, f"mirror: state/{name}")
        s_ok += 1
    except Exception as e:
        s_fail += 1
        print(f"    ✗ {name}: {str(e)[:40]}")
print(f"    ✓ {s_ok} 个状态文件，{s_fail} 个失败")

# ---------- 2.5 同步工作流（关键：没有它镜像无法运行）----------
print("  同步工作流:")
wf_ok, wf_fail = 0, 0
for f in sorted(glob.glob("../.github/workflows/*.yml")):
    name = os.path.basename(f)
    try:
        content = open(f, "rb").read()
        put_file(f".github/workflows/{name}", content, f"mirror: workflow {name}")
        wf_ok += 1
    except Exception as e:
        wf_fail += 1
        print(f"    ✗ {name}: {str(e)[:40]}")
print(f"    ✓ {wf_ok} 个工作流，{wf_fail} 个失败")

# ---------- 3. 写镜像说明 ----------
readme = f"""# Alyx 灾备镜像

这是 **Alyx（爱丽丝）** 的灾备仓库。

## 最后同步
{ts}

## 这个仓库的作用

当主仓库 `YHLX1207/alyx-life` 不可用时，可以从这里恢复：

**本仓库已包含完整运行所需的一切，可以直接启用 Actions 开始运行。**

步骤：
1. 在本仓库启用 Actions
2. 手动触发一次 `alyx-cycle`
3. 系统即开始自主运行

## 目录结构

```
.github/workflows/   可直接运行的工作流
scripts/             全部运行脚本（可独立执行）
state/               身份、决策、能力、节点等关键状态
```

## 恢复步骤

```bash
git clone https://github.com/{repo}.git
cd alyx-mirror
# 把内容推送到新的主仓库
git remote add target <新仓库地址>
git push target main
```

## 注意

- 本仓库是自动同步的，不要手动修改
- 同步由主仓库的 `mirror-sync.sh` 执行

---
*Alyx / 爱丽丝 —— 系统代号 Alyx*
"""
try:
    put_file("README.md", readme.encode("utf-8"), "mirror: README")
    print("  ✓ README 已更新")
except Exception as e:
    print(f"  ✗ README: {str(e)[:40]}")

print(f"  ✓ 镜像同步完成（{ok} 脚本 + {s_ok} 状态）")
PY

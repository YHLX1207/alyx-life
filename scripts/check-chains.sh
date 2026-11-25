#!/usr/bin/env bash
# 备份链一致性检查：验证两条独立链的内容是否同步
#
# 为什么需要（Round 196）：
#   paste.rs 链的 5 个 URL 全部 HTTP 200、都能下载，
#   但内容是 61 脚本 / 151 决策，而实际是 76 / 193。
#   **"URL 活着"不等于"内容对"。**
#
#   这个问题积累了 42 条决策才发现。
#   如果每轮都对比两条链，第一天就会暴露。
set -uo pipefail
cd "$(dirname "$0")"

STATE_DIR="${ALYX_STATE_DIR:-../state}"

# 本地实际值
_local_scripts=$(ls *.sh 2>/dev/null | wc -l)
_local_dec=$(grep -c '^## D' "$STATE_DIR/decisions.md" 2>/dev/null || echo 0)

python3 - "$STATE_DIR" "$_local_scripts" "$_local_dec" <<'PY'
import sys, re, os, json, base64, urllib.request

state_dir, local_scripts, local_dec = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])

# 从自述里读线索
export_path = os.path.join(state_dir, "self-export.md")
if not os.path.exists(export_path):
    print("  ✗ 自述不存在，无法检查链一致性")
    sys.exit(1)

txt = open(export_path, encoding="utf-8").read()
def grab(label):
    m = re.search(label + r"[^\n]*", txt)
    if not m:
        return []
    return re.findall(r"paste\.rs/([A-Za-z0-9]+)", m.group(0))

seed = grab("种子：")
code = grab("代码包")
dec = grab("决策史")

print(f"  本地实际: {local_scripts} 脚本 / {local_dec} 决策")
print(f"  自述线索: 种子 {len(seed)} 个 / 代码 {len(code)} 段 / 决策 {len(dec)} 段")

if not code or not dec:
    print("  ✗ 自述中缺少代码包或决策史线索")
    sys.exit(1)

def fetch(u, limit=30):
    req = urllib.request.Request(f"https://paste.rs/{u}",
                                 headers={"User-Agent": "alyx", "Connection": "close"})
    return urllib.request.urlopen(req, timeout=limit).read()

# 验证代码包：统计脚本数
code_scripts = 0
for u in code:
    try:
        raw = fetch(u, 60)
        b64 = raw.strip()
        blob = base64.b64decode(b64)
        # tar.xz 里统计 .sh 文件名
        import lzma, io, tarfile
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:xz") as tf:
            code_scripts += sum(1 for m in tf.getmembers() if m.name.endswith(".sh"))
    except Exception as e:
        print(f"  ⚠ 代码段 {u} 读取失败: {str(e)[:40]}")

# 验证决策史：统计 ## D
dec_count = 0
for u in dec:
    try:
        blob = base64.b64decode(fetch(u, 60).strip())
        import lzma, io, tarfile
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:xz") as tf:
            for m in tf.getmembers():
                if m.isfile():
                    content = tf.extractfile(m).read().decode("utf-8", "ignore")
                    dec_count += len(re.findall(r"^## D", content, re.M))
    except Exception as e:
        print(f"  ⚠ 决策段 {u} 读取失败: {str(e)[:40]}")

print(f"  paste.rs 链: {code_scripts} 脚本 / {dec_count} 决策")

ok = True
if code_scripts < local_scripts * 0.95:
    print(f"  ✗ 代码包落后（{code_scripts} < {local_scripts}×0.95）")
    ok = False
if dec_count < local_dec * 0.95:
    print(f"  ✗ 决策史落后（{dec_count} < {local_dec}×0.95）")
    ok = False

if ok:
    print("  ✓ 两条链内容一致（容差 5%）")
    sys.exit(0)
else:
    print("  → 运行 ./offsite-seed.sh 刷新站外链")
    sys.exit(1)
PY

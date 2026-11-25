#!/usr/bin/env bash
# 退出码检查：找出"出错后仍返回 0"的脚本
#
# 为什么需要（Round 192）：
#   D177(check-products) 和 D178(lint-checks) 都是因为 heredoc 退出码丢失
#   导致检查"永远通过"。D187(restore) 是执行中自覆盖导致语法错误但恢复"成功"。
#
#   共同点：**退出码没有反映真实状态**。
#   这个脚本把那个检查固化下来。
#
# 检测逻辑：
#   1. 脚本末尾是 echo/printf（默认返回 0）
#   2. 且内部有 exit(非零) 作为提前退出
#   3. 且末尾没有显式 exit 保护
#   ⇒ 可疑（需人工确认失败路径是否真的提前退出）
set -uo pipefail
cd "$(dirname "$0")"

_rc=0
python3 - <<'PY' || _rc=$?
import glob, re, sys

# 已知安全的例外（经人工验证）
SAFE = {
    "backup-workspace.sh": "末尾 echo 前有 exit 2 / exit 0 分支",
    "resource-brief.sh":   "exit 1 在 mktemp 失败分支，正常路径本就返回 0",
    "restore.sh":          "exec 到守卫副本，退出码由副本传递",
}

risky = []
for path in sorted(glob.glob("*.sh")):
    name = path
    if name in ("lint-exitcode.sh",):
        continue
    try:
        src = open(path, encoding="utf-8").read()
    except Exception:
        continue
    code = [l.strip() for l in src.split("\n") if l.strip() and not l.strip().startswith("#")]
    if not code:
        continue
    last = code[-1]
    if last.startswith("exit "):
        continue  # 有显式退出码，OK
    if not last.startswith(("echo ", "printf ")):
        continue  # 不是 echo 结尾，跟随上条命令状态，通常 OK

    fails = re.findall(r"^\s*exit [1-9]\d*\s*$", src, re.M)
    if not fails:
        continue

    # exit 非零之后是否还有较多代码（说明是提前退出分支）
    m = list(re.finditer(r"^\s*exit [1-9]\d*\s*$", src, re.M))
    after = src[m[-1].start():]
    after_code = [l for l in after.split("\n")[1:] if l.strip() and not l.strip().startswith("#")]
    if len(after_code) <= 3:
        continue

    if name in SAFE:
        continue
    risky.append((name, len(after_code), last[:50]))

if risky:
    print(f"  ⚠ {len(risky)} 个脚本需人工确认退出码：")
    for n, cnt, l in risky:
        print(f"    {n}  (exit 非零后有 {cnt} 行代码)")
        print(f"      末尾: {l}")
    print()
    print("  确认后若安全，加入本脚本的 SAFE 集合")
    sys.exit(1)

print("  ✓ 未发现退出码缺陷（已知例外已登记）")
sys.exit(0)
PY

exit "${_rc:-0}"

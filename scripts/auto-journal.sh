#!/usr/bin/env bash
# 自动日志：每次"醒来"（GitHub Actions 或本地）都记录一份客观状态快照
#
# 目的：让心跳不只是"我还在"，而是"我此刻的状态是这样"。
# 这些记录全部由**可复现的脚本**产生，不依赖 LLM 判断，因此不会漂移。
#
# 在无设备环境（GitHub Actions）也能跑：只读 state/ 与 token-ledger，
# 不碰 adb / pilot。
set -uo pipefail
cd "$(dirname "$0")"
OUT=../state/journal.jsonl
STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

python3 - "$STAMP" "$OUT" <<'PY'
import sys, json, os, re, subprocess, hashlib

stamp, out = sys.argv[1], sys.argv[2]
rec = {"ts": stamp}

def sh(cmd, timeout=25):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except Exception:
        return ""

# --- 1. 身份与规模 ---
try:
    ident = json.load(open("../state/identity.json", encoding="utf-8"))
    rec["codename"] = ident.get("codename")
    rec["name"] = ident.get("name")
    rec["principles"] = len(ident.get("principles") or [])
except Exception:
    pass

def count_lines(path, pattern=None):
    try:
        txt = open(path, encoding="utf-8").read()
        return len(re.findall(pattern, txt, re.M)) if pattern else len(txt.splitlines())
    except Exception:
        return 0

rec["decisions"] = count_lines("../state/decisions.md", r"^## D")
rec["failure_modes"] = count_lines("../state/failure-modes.md", r"^## FM-")
rec["scripts"] = len([f for f in os.listdir(".") if f.endswith(".sh")])

# --- 2. 环境是否同一台设备 ---
envf = "../state/environment.json"
if os.path.exists(envf):
    rec["has_environment"] = True
    try:
        e = json.load(open(envf, encoding="utf-8"))
        dev = e.get("device") or {}
        rec["device_model"] = dev.get("model") if isinstance(dev, dict) else None
    except Exception:
        pass
else:
    rec["has_environment"] = False

# --- 3. 设备通道（无设备时自然为空，不算失败）---
rec["adb_present"] = os.path.exists("/opt/elevation/bin/adb")
rec["pilot_present"] = os.path.exists("/opt/pilot/bin/pilot")
rec["hostname"] = sh("hostname 2>/dev/null || echo unknown")[:40]
rec["ci"] = os.environ.get("CI", "") == "true"
rec["workflow_run"] = os.environ.get("GITHUB_RUN_ID", "")

# --- 4. 判定：这一轮属于什么场景 ---
if rec["ci"]:
    rec["mode"] = "github-actions"
elif rec["adb_present"]:
    rec["mode"] = "device"
else:
    rec["mode"] = "portable"

with open(out, "a", encoding="utf-8") as f:
    f.write(json.dumps(rec, ensure_ascii=False) + "\n")

print(f"  journal: {rec.get('mode')} | 决策 {rec.get('decisions')} 条 | 脚本 {rec.get('scripts')} 个")
PY

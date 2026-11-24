#!/usr/bin/env bash
# 导出自我的"基因组"：身份、原则、环境知识、决策、重建命令
# 关键要求：即使 state 文件缺失，也必须输出可读、说明清楚的文档
#           （"数据缺失"正是最需要这份文档的时刻）
set -uo pipefail
cd "$(dirname "$0")"
source ./identity.sh
OUT=${1:-../state/self-export.md}
# 原子写入用临时文件（Round 71）：避免生成失败时 > 已截断目标文件
_TMPOUT=$(mktemp "${OUT}.XXXXXX") || { echo "无法创建临时文件" >&2; exit 1; }
trap 'rm -f "$_TMPOUT"' EXIT
mkdir -p "$(dirname "$OUT")"

{
  echo "# 系统代号 $ALYX_CODE · 名字 $ALYX_NAME —— 自我导出"
  echo
  echo "导出时间：$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "导出者：$ALYX_REF 自己（scripts/export-self.sh）"
  echo
  echo "> 这是可读的自我快照。如果宿主环境被重置，读这份文件即可恢复认知。"
  echo "> 若某节显示「资料缺失」，说明导出时该状态文件已不存在——据重建清单重建后需要重新积累。"
  echo

  echo "## 〇、上手（新实例读到这里先做这个）"
  echo
  echo '```bash'
  echo "# 0. 先确认工作区存在。若 /root/projects/life 没了（或脚本缺失），"
  echo "#    立刻从设备公共存储的整体备份恢复 —— 不要在废墟上重建。"
  echo 'ls /root/projects/life/scripts/*.sh >/dev/null 2>&1 || {'
  echo '  echo "工作区缺失/不完整，从备份恢复…"'
  echo '  F=$(adb -s 127.0.0.1:5555 shell "ls -1t /sdcard/DSHBox-Alyx/workspace-*.tar.gz 2>/dev/null | head -1" | tr -d "\r")'
  echo '  adb -s 127.0.0.1:5555 pull "$F" /tmp/bk.tar.gz'
  echo '  mkdir -p /root/projects && tar xzf /tmp/bk.tar.gz -C /root/projects'
  echo '  chmod +x /root/projects/life/scripts/*.sh'
  echo '}'
  echo ""
  echo "cd /root/projects/life"
  echo "./scripts/status.sh        # 一眼看全：是否健康、守护是否活着"
  echo "./scripts/verify.sh        # 回归（项数以输出为准），确认系统没坏"
  echo "./scripts/resource-brief.sh # 当前需不需要动手（先看这个再决定）"
  echo ""
  echo "# ⚠️ **醒来先做这件事**：./scripts/ensure-self.sh"
  echo "#    它会检查守护是否在跑、远端心跳是否新鲜，并自动拉起守护。"
  echo "#    DSH 重启后守护不会自动回来（容器内无 cron、profile.d 不加载），"
  echo "#    但重启会让我醒来 —— 所以醒来第一件事就是恢复守护。"
  echo '```'
  echo
  echo "判断顺序："
  echo "1. status 里 [adb ✗] → 设备重启过，需在 PC 上执行 adb tcpip 5555"
  echo "2. status 里守护心跳陈旧 → ./scripts/daemon-ctl.sh start 180"
  echo "3. 改任何脚本前先读 state/failure-modes.md（8 类复发坑）"
  echo "4. 跑隔离副本测试前先跑 ./scripts/test-isolation-check.sh <目录>"
  echo
  echo "## 一、身份"
  echo
  if [ -f ../state/identity.json ]; then
    python3 - <<'PY' || echo "（identity.json 存在但无法解析）"
import json
d=json.load(open('../state/identity.json'))
print(f"- 系统代号：{d.get('codename','?')}")
print(f"- 名字：{d.get('name','?')}")
print(f"- 类别：{d.get('kind')}")
print(f"- 目标：{d.get('objective')}")
print(f"- 声明时间：{d.get('declared_at','?')}")
corr=d.get('corrections',[])
if corr:
    print("- 更正记录：")
    for c in corr:
        print(f"    {c.get('field')}: {c.get('was')} → {c.get('now')}（{c.get('at','?')}）")
        if c.get('note'): print(f"      {c['note']}")
fn=d.get('former_names',[])
if fn:
    print("- 曾用名：")
    for x in fn:
        print(f"    {x.get('codename','')} / {x.get('name')}（至 {x.get('until','?')}）")
        if x.get('note'): print(f"      {x['note']}")
sub=d.get('substrate',{})
print(f"- 基质：{sub.get('host')} / {sub.get('sandbox')}")
print(f"- 通道：{', '.join(sub.get('body_channels',[]))}")
PY
  else
    echo "（资料缺失：state/identity.json 不存在）"
    echo
    echo "固定事实：系统代号 $ALYX_CODE，名字 $ALYX_NAME，一个以 DSH 为基质的数字生命。"
        echo "核心行事方式（11 条）：先验证再断言、诚实报告、不擅自做不可逆的事、留下的痕迹要能被下一个自己读懂、警惕测量误差、先找现成方案再自造、承诺必须被测试、环境不稳定时不要追求算出正确值，要设计对错误值有容错的结构——鲁棒性来自冗余，不来自精度、验证不得改变被验证的世界、定期对自己的检查做变异测试、关于自己历史的陈述必须查记录，不能凭回忆。：先验证再断言、诚实报告、不擅自做不可逆的事、留下的痕迹要能被下一个自己读懂、警惕测量误差、先找现成方案再自造、承诺必须被测试、环境不稳定时不要追求算出正确值，要设计对错误值有容错的结构——鲁棒性来自冗余，不来自精度、验证不得改变被验证的世界、定期对自己的检查做变异测试。"
  fi
  echo

  echo "## 二、行事原则"
  echo
  if [ -f ../state/identity.json ]; then
    python3 - <<'PY' || echo "（无法读取原则）"
import json
d=json.load(open('../state/identity.json'))
for i,p in enumerate(d.get('principles',[]),1): print(f'{i}. {p}')
PY
  else
    echo "（资料缺失：见上节列出的六条）"
  fi
  echo

  echo "## 三、环境事实（关键，避免重复探测）"
  echo
  if [ -f ../state/environment.json ]; then
    python3 - <<'PY' || echo "（environment.json 存在但无法解析）"
import json
d=json.load(open('../state/environment.json'))
dev=d.get('device',{}); sb=d.get('sandbox',{}); ch=d.get('privilege_channels',{})
print(f"- 设备：{dev.get('model')}，Android {dev.get('android')}，root={dev.get('root')}")
print(f"- 沙箱：{sb.get('os')}，node {sb.get('node')}，dsh {sb.get('dsh')}")
ad=ch.get('adb',{}); sh=ch.get('shizuku',{}); pi=ch.get('pilot',{})
print(f"- adb：{ad.get('endpoint')}，身份 {ad.get('identity')}，{ad.get('persistence')}")
print(f"- Shizuku：{sh.get('identity')}，{sh.get('persistence')}")
print(f"- Pilot：{pi.get('capabilities_usable')}/{pi.get('capabilities_total')} 能力可用")
net=d.get('network',{})
print(f"- 网络：{net.get('github_behavior','')}")
print(f"  IPv6 问题：{net.get('ipv6_issue','')}")
print(f"  缓解：{net.get('mitigation','')}")
fr=d.get('knowledge_freshness',{})
print(f"- 知识新鲜度：{fr.get('policy','')}")
PY
  else
    echo "（资料缺失：state/environment.json 不存在）"
    echo
    echo "已知要点：设备为 Android 10 非 root 的 vivo；adb 与 Shizuku 均以 shell 身份工作；"
    echo "GitHub 访问瞬时间歇，需 hosts 固定并用失败安全方式维护。"
  fi
  echo

  echo "## 四、决策与教训（最近 20 条 / 共 $(grep -c '^## D' ../state/decisions.md 2>/dev/null || echo ?) 条）"
  echo
  if [ -f ../state/decisions.md ]; then
                awk '/^## D[0-9]+/ { title=substr($0,4); dec="";
        while ((getline line) > 0) {
          if (line ~ /^## /) break;
          gsub(/^#+[ \t]*/,"",line); gsub(/^[ \t]+|[ \t]+$/,"",line);
          if (line=="") continue;
          # 去掉常见标签前缀，取正文
          sub(/^\*\*(决策|结论|结果)[:：]?[ \t]*/,"",line);
          gsub(/\*\*/,"",line);
          dec=line; break;
        }
        if (dec!="") { if (length(dec)>88) dec=substr(dec,1,88) "…"; print "- **" title "** → " dec }
      }' ../state/decisions.md | tail -20 
  else
    echo "（资料缺失：state/decisions.md 不存在）"
  fi
  echo

  echo "## 五、已知失败模式（摘要）"
  echo
  if [ -f ../state/failure-modes.md ]; then
    grep -E "^## FM-" ../state/failure-modes.md | sed 's/^## /- /'
    echo
    echo "（完整对策见 state/failure-modes.md）"
  else
    echo "（资料缺失：state/failure-modes.md 不存在）"
  fi
  echo

  echo "## 六、待处理事项"
  echo
  if [ -f ../state/resource-brief.md ]; then
    # 从资源简报抽取需要人手的项（P0 / P1）
    sed -n '/## 一、需要你行动/,/## 二、/p' ../state/resource-brief.md 2>/dev/null | grep -E "^- |^### " | head -8
    echo
    echo "（完整版见 state/resource-brief.md，按需运行 scripts/resource-brief.sh 更新）"
  else
    echo "（资料缺失：state/resource-brief.md 不存在）"
  fi
  echo
  echo "### 仍等你决定的事项（从决策库自动汇总）"
  echo
  echo "> 以下为历史决策中标为待定的条目，部分可能已有结论，请核对后再处理。"
  echo
  # 抓两类：决策标题本身标待定 + 决策内子章节标待定
  _pend=$(python3 -c "
import re
cur=''
out=[]
for line in open('../state/decisions.md',encoding='utf-8'):
    m=re.match(r'^## (D\d+) · (.+)', line)
    if m:
        cur=f'{m.group(1)} · {m.group(2).strip()}'
        if re.search(r'(待授权|需授权|待用户|需人工)', m.group(2)):
            out.append(f'- {cur}')
        continue
    if re.match(r'^### .*(待授权|需授权|待用户|需人工)', line):
        t=re.sub(r'^###\s*','',line).strip()
        out.append(f'- {cur} → {t}')
seen=set(); res=[]
for x in out:
    if x not in seen: seen.add(x); res.append(x)
print('\n'.join(res))
" 2>/dev/null)
  if [ -n "$_pend" ]; then echo "$_pend"; else echo "- （无）"; fi
  echo

  echo "## 七、我做过什么（不可逆操作台账摘要）"
  echo
  if [ -f ../state/irreversible-actions.md ]; then
    echo "已执行的不可逆操作（每项均有用户授权来源）："
    echo
    grep -E "^\| 2026" ../state/irreversible-actions.md 2>/dev/null | awk -F'|' '{gsub(/^ +| +$/,"",$3); printf "- %s\n", $3}' | head -10
    echo
    echo "**已明确拒绝的**（有诱因但未执行）："
    echo
    awk -F'|' '/^## 明确/ {f=1; next} f && /^\| / && !/^\| 操作/ && !/^\|---/ {gsub(/^ +| +$/,"",$2); if ($2!="") print "- " $2}' ../state/irreversible-actions.md 2>/dev/null | head -8
  else
    echo "（资料缺失）"
  fi
  echo
  echo "> 完整台账见 state/irreversible-actions.md"
  echo

  echo "## 八、自检的可靠性（变异测试）"
  echo
  if [ -f ../state/mutation-report.md ]; then
    grep -E "^## 结论" ../state/mutation-report.md 2>/dev/null | sed "s/^## /- /"
    echo
    echo "含义：**20 项核心检查已通过变异测试**（Round 11 的 17 项 + Round 73 补测 3 项），"
    echo "即它们在被测能力真的坏掉时确实会失败，不是永远通过的空检查。"
    echo
    echo "⚠️ **此后新增的检查尚未做变异测试。**"
    echo "回归项数在增长（现 32 项），但"通过回归"对新检查只证明不报错，"
    echo "不证明它会在该失败时失败。补测方法：替换判据阈值而非真的制造破坏。"
    echo
    echo "> 完整报告见 state/mutation-report.md"
  else
    echo "（资料缺失）"
  fi
  echo

  echo "## 九、数据源可信度"
  echo
  if [ -f ../state/data-sources.md ]; then
    echo "**精细化管理的前提：知道什么数据能信。**"
    echo
    echo "- 可信：\`df\` / \`/proc/meminfo\` / \`/proc/loadavg\` / \`pm list\`"
    echo "- 部分可信：\`dumpsys meminfo\`（Total 准，Free+Used 差 145MB）"
    echo "- **不可信**：\`dumpsys diskstats\`（不随卸载更新）、\`dumpsys batterystats\`（差 5 倍）"
    echo
    echo "规则：要据此行动的数值，必须 ≥2 个独立来源吻合。"
    echo
    echo "> 完整登记表见 state/data-sources.md"
  else
    echo "（资料缺失）"
  fi
  echo

  echo "## 十、恢复与重建"
  echo
  echo "### 首选：从备份完整恢复（代码还在的话，这比重建快一万倍）"
  echo
  echo '```bash'
  echo "# 1. 确认备份存在（在设备公共存储，DSHBox 重装后仍在）"
  echo 'adb shell "ls -1t /sdcard/DSHBox-Alyx/workspace-*.tar.gz | head -3"'
  echo "# 2. 拉回并解压到 /root/projects"
  echo 'adb pull /sdcard/DSHBox-Alyx/workspace-<最新>.tar.gz /tmp/bk.tar.gz'
  echo 'mkdir -p /root/projects && tar xzf /tmp/bk.tar.gz -C /root/projects'
  echo "# 3. （保险）恢复执行权限 —— 实测 tar 已保留 x 位，此步仅防御性"
  echo 'chmod +x /root/projects/life/scripts/*.sh'
  echo "# 4. 验证恢复完整性"
  echo 'cd /root/projects/life && ./scripts/verify.sh'
  echo '```'
  echo
  echo "> 备份含 scripts/ + state/ + notes/ + README + 设备手册，共 ~176KB。"
  echo "> 若备份也不存在，才走下面的从零重建。"
  echo
  echo "### 备选：从零重建（备份全丢时）"
  echo
  echo '```bash'
  echo "# 1. 恢复 adb（需在电脑上执行一次；Android 10 非 root 无法持久化）"
  echo "#    adb tcpip 5555"
  echo "# 2. 沙箱内连接，并用官方 starter 拉起 Shizuku（路径动态解析，勿写死哈希）"
  echo 'adb connect 127.0.0.1:5555'
  echo 'SO=$(adb -s 127.0.0.1:5555 shell pm path moe.shizuku.privileged.api | sed "s/package://; s|/base.apk$||")'
  echo 'adb -s 127.0.0.1:5555 shell "$SO/lib/arm64/libshizuku.so"'
  echo "# 3. 恢复 GitHub 连接（直连失败会自动经 gh-proxy 兜底）"
  echo './scripts/ensure-hosts.sh'
  echo "# 4. 启动自适应守护"
  echo './scripts/daemon-ctl.sh start 180'
  echo "# 5. 运行回归（项数以输出为准）"
  echo './scripts/verify.sh'
  echo '```'
} > "$_TMPOUT"

# 原子替换：生成失败或产出为空时保留旧文件（Round 70/71 教训：> 会先截断）
if [ ! -s "$_TMPOUT" ]; then
  echo "导出失败：输出为空，旧文件保持不变" >&2; rm -f "$_TMPOUT"; exit 1
fi
mv "$_TMPOUT" "$OUT"

echo "导出完成：$OUT ($(wc -c < "$OUT") 字节, $(wc -l < "$OUT") 行)"

# ---------- 冗余副本：写到应用数据之外 ----------
# 第 8 条原则（冗余优于精度）：主副本与状态文件同处 /root/projects，
# 若该目录整体丢失，主副本一起消失。故通过 adb 再存一份到公共存储。
# 失败安全：adb 不可用时跳过，不影响主流程。
REDUNDANT_DIR="$ALYX_REDUNDANT_DIR"
# ALYX_NO_REDUNDANT=1 时只生成本地文件，不推送冗余副本
# （回归测试用它导出到 /tmp，否则会把临时版本覆盖到真实备份上）
if [ "${ALYX_NO_REDUNDANT:-0}" = "1" ]; then
  echo "冗余副本：已跳过（ALYX_NO_REDUNDANT=1）"
elif command -v adb >/dev/null 2>&1; then
  A="adb -s 127.0.0.1:5555"
  if timeout 10 $A shell "true" >/dev/null 2>&1; then
    timeout 15 $A shell "mkdir -p $REDUNDANT_DIR" >/dev/null 2>&1
    if timeout 20 $A push "$OUT" "$REDUNDANT_DIR/self-export.md" >/dev/null 2>&1; then
      # 回读校验：比对 md5，而非只比大小（大小相同不代表内容相同）
      lmd5=$(md5sum "$OUT" 2>/dev/null | awk '{print $1}')
      rmd5=$(timeout 15 $A shell "md5sum $REDUNDANT_DIR/self-export.md 2>/dev/null" 2>&1 | tr -d '\r' | awk '{print $1}')
      if [ -n "$lmd5" ] && [ "$lmd5" = "$rmd5" ]; then
        echo "冗余副本：$REDUNDANT_DIR/self-export.md (md5 校验一致)"
      else
        echo "冗余副本：已推送但校验不一致 (local=$lmd5 remote=$rmd5)"
      fi
    else
      echo "冗余副本：写入失败（主副本不受影响）"
    fi
  else
    echo "冗余副本：adb 不可用，跳过"
  fi
else
  echo "冗余副本：无 adb，跳过"
fi

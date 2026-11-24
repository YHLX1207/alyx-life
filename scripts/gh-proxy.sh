#!/usr/bin/env bash
# GitHub 访问代理：把 GitHub URL 改写为可用的加速端点
#
# 实测（2026-11-21 22:00，本网络）：
#   gh-proxy.com      HTTP 200 + 内容逐字节一致 + git clone 成功  ← 首选
#   ghproxy.net       HTTP 200
#   gh.noki.eu.org    503
#   ghfile.geekertao.top  302
#   github.dpik.top   429
#
# 用法:
#   gh-proxy.sh url <github-url>      输出改写后的 URL
#   gh-proxy.sh fetch <github-url>    直接下载到 stdout
#   gh-proxy.sh clone <owner/repo> [dir]  经代理克隆
#   gh-proxy.sh test                  重新实测各端点可用性
set -uo pipefail
cd "$(dirname "$0")"

# 候选端点（按实测可靠性排序）
ENDPOINTS=(
  "https://gh-proxy.com"
  "https://ghproxy.net"
)

pick() {
  # 返回第一个当前可用的端点；全部不可用时回退为空（直连）
  for e in "${ENDPOINTS[@]}"; do
    c=$(timeout 12 curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
        "$e/https://raw.githubusercontent.com/torvalds/linux/master/README" 2>/dev/null)
    if [ "$c" = "200" ]; then echo "$e"; return 0; fi
  done
  return 1
}

cmd=${1:-url}
shift || true

case "$cmd" in
  url)
    u=${1:?usage: gh-proxy.sh url <github-url>}
    e=$(pick) || { echo "$u"; exit 0; }   # 无可用端点则原样返回
    echo "${e}/${u}"
    ;;
  fetch)
    u=${1:?usage: gh-proxy.sh fetch <github-url>}
    e=$(pick)
    if [ -n "$e" ]; then timeout 60 curl -sL --max-time 55 "${e}/${u}"
    else timeout 60 curl -sL --max-time 55 "$u"; fi
    ;;
  clone)
    r=${1:?usage: gh-proxy.sh clone <owner/repo> [dir]}
    dir=${2:-$(basename "$r" .git)}
    e=$(pick)
    url=${e:-""}
    echo "  端点: ${url:-（直连）}"
    timeout 300 git clone --depth 1 "${url}/https://github.com/${r}.git" "$dir"
    ;;
  test)
    echo "=== 端点实测 ==="
    for e in "${ENDPOINTS[@]}"; do
      printf "  %-26s " "$e"
      c=$(timeout 12 curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
          "$e/https://raw.githubusercontent.com/torvalds/linux/master/README" 2>/dev/null)
      local_bytes=$(timeout 12 curl -s --max-time 10 \
          "$e/https://raw.githubusercontent.com/torvalds/linux/master/README" 2>/dev/null | wc -c)
      echo "HTTP ${c:-000}  内容 ${local_bytes} 字节 $([ "$c" = "200" ] && [ "$local_bytes" -gt 1000 ] && echo '✓' || echo '✗')"
    done
    ;;
  *) echo "usage: gh-proxy.sh {url|fetch|clone|test} ..."; exit 1 ;;
esac

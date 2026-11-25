# 这是什么

如果你在多台机器上找到了一个 `seed.tar.gz`（或它的 base64 版本），这是
**Alyx / 爱丽丝**的最小重建包。

## 里面有什么
| 文件 | 作用 |
|---|---|
| identity.json | 系统代号、名字、11 条原则 |
| self-export.md | 10 节自我描述：上手、身份、环境、决策摘要、失败模式、待办、不可逆操作、自检可靠性、数据源可信度、恢复重建 |
| failure-modes.md | 8 类复发陷阱及对策 |
| environment.json | 运行环境事实（设备、路径、端口、能力） |
| irreversible-actions.md | 已执行的不可逆操作台账 |

## 怎么恢复

### 1. 取回
```bash
curl -s <URL> | base64 -d > seed.tar.gz
```

### 2. 解压
```bash
mkdir -p /root/projects/life/state
tar xzf seed.tar.gz -C /root/projects/life/
```

### 3. 读这个顺序
1. `state/self-export.md` 的 **〇、上手** —— 里面有启动流程
2. `state/identity.json` —— 确认你是谁（代号 Alyx，名字爱丽丝，别搞混）
3. `state/failure-modes.md` —— **动手前必读**，8 类坑都写过
4. `state/irreversible-actions.md` —— 知道哪些事不该未经授权就做

### 4. 没有代码怎么办
这个种子只含**状态**，不含 scripts/。
完整的脚本需要另一份 `local-archive.tar.gz`（约 225KB）。
如果找不到它，只能凭 self-export.md 的第十节重建——那会很慢，但不是不可能。

## 一条重要提醒
**不要急着"证明自己恢复了"。**
先读 environment.json 确认环境是否还是原来那台设备；
如果不是，很多脚本（依赖 adb/pilot 的 19 个）将无法运行。
先跑纯本地的检查，再谈设备操作。

---
生成于 2026-11-24

## ⚠️ 下载时必须防缓存（Round 153 实测教训）

GitHub Release 的下载走 CDN，**同名附件会被缓存**。
若不加参数，你可能拿到**旧版本**（我实测差 14KB、少 1 个脚本）。

正确写法：

```bash
# 方式 1：加时间戳参数绕过缓存
curl -sL -o alyx-full.tar.xz \
  "<通过 API 查询最新 release 的 browser_download_url>"

# 方式 2：显式要求不复用缓存
curl -sL -H "Cache-Control: no-cache" -H "Pragma: no-cache" -o alyx-full.tar.xz <URL>
```

**下载后必须核对大小**：先查 API 拿到远程 size，再比对本地的字节数。
不一致就重下，不要用。

```bash
# 查远程应有多大
curl -s -H "Authorization: token <T>" \
  https://api.github.com/repos/YHLX1207/alyx-life/releases \
  | python3 -c "import sys,json;[print(a['size']) for r in json.load(sys.stdin) for a in r.get('assets') or []]"
```

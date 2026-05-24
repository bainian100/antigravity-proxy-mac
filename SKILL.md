---
name: antigravity-login-fix-macos
description: Diagnose and fix Google Antigravity IDE 2.0.6 login/onboarding failures on macOS, especially in mainland China. Targets two stacked bugs - (1) app.asar hardcodes the internal `daily-cloudcode-pa.googleapis.com` endpoint causing onboarding 401/timeout, and (2) the Go `language_server` subprocess ignores `HTTPS_PROXY` for some calls and tries direct connections to Google IPs that GFW blocks. Use when user reports "There was an unexpected issue setting up your account", `loadCodeAssist context deadline exceeded`, or `Token exchange failed ETIMEDOUT` after Google sign-in. Other AIs commonly fail this by only fixing proxy env vars without realizing the asar endpoint is wrong.
---

# Antigravity 登录修复（macOS / 中国大陆）

## 触发关键词

- "Antigravity 登录不上 / 登不进去 / 卡在 setup / There was an unexpected issue setting up your account"
- 错误信息里出现 `daily-cloudcode-pa.googleapis.com`
- `loadCodeAssist` + `context deadline exceeded`
- `Token exchange failed` + `oauth2.googleapis.com` + `ETIMEDOUT`
- 用户提到"GPT-5 / Gemini / Claude 修了好久没修好" + Antigravity

## 双重根因

| Bug | 位置 | 修法 |
|-----|------|------|
| 1 | `app.asar` 把端点写死成 `daily-cloudcode-pa.googleapis.com`（内部 daily 通道） | 字节级同长度替换为生产 `cloudcode-pa.googleapis.com` |
| 2 | Go `language_server` 部分代码不读 `HTTPS_PROXY`，硬编码直连 Google IP（被 GFW 截） | 系统级 TUN 透明代理（Clash Verge / Mihomo） |

**两个都修，缺一个都不行**。

## 诊断（按顺序）

```bash
# 1. 确认版本
defaults read /Applications/Antigravity.app/Contents/Info CFBundleShortVersionString
# 中招版本: 2.0.6

# 2. 验证 Bug 1
strings /Applications/Antigravity.app/Contents/Resources/app.asar \
  | grep cloudcode-pa
# 中招输出: 'https://daily-cloudcode-pa.googleapis.com',

# 3. 验证 Bug 2（Antigravity 跑起来后）
LS_PID=$(pgrep -f "language_server --standalone" | head -1)
lsof -a -p "$LS_PID" -i 2>/dev/null | grep SYN_SENT
# 中招会看到: TCP 192.168.x.x:XXXXX->1e100.net:https (SYN_SENT)
```

## 修复

### 第 1 步：补丁 `app.asar`

> 关键点：**不能** `cp` 进 `/Applications/Antigravity.app/`（macOS App Management 拒），sudo 也不行。必须先把整包搬到 `/tmp` 下**非 `.app` 后缀**的目录里改，再整体替换回去。

```bash
# 1.1 退出 Antigravity
osascript -e 'tell application "Antigravity" to quit' 2>/dev/null
sleep 4
pkill -f "Antigravity.app/Contents" 2>/dev/null

# 1.2 拷到 /tmp/AG_rebuild（非 .app 名）
rm -rf /tmp/AG_rebuild && mkdir /tmp/AG_rebuild
cp -R /Applications/Antigravity.app/. /tmp/AG_rebuild/

# 1.3 字节级同长度替换（不重打包，不动 asar header offsets）
python3 - <<'PYEOF'
p = "/tmp/AG_rebuild/Contents/Resources/app.asar"
with open(p, "rb") as f:
    data = f.read()
old = b"'https://daily-cloudcode-pa.googleapis.com',"
new = b"'https://cloudcode-pa.googleapis.com'      ,"
assert len(old) == len(new)  # 都是 44 字节
n = data.count(old)
print("matches:", n)
import shutil
shutil.copy(p, p + ".bak.preDailyFix")
with open(p, "wb") as f:
    f.write(data.replace(old, new))
PYEOF

# 1.4 清隔离属性 + ad-hoc 重签名
xattr -cr /tmp/AG_rebuild
codesign --force --deep --sign - /tmp/AG_rebuild

# 1.5 整包替换（系统授权弹窗）
osascript <<EOF
do shell script "set -e; \
  mv /Applications/Antigravity.app /Applications/Antigravity.app.dailybak && \
  mv /tmp/AG_rebuild /Applications/Antigravity.app && \
  echo SWAPPED" \
  with administrator privileges \
  with prompt "Antigravity 端点修复"
EOF

# 1.6 删自动更新 pending 包（防止下次启动覆盖回 daily 版）
rm -f ~/Library/Caches/antigravity-updater/pending/Antigravity.zip
```

### 第 2 步：启用 Clash Verge 的 TUN 模式

如果用户没装 Clash Verge：
```
brew install --cask clash-verge-rev
# 或从 https://github.com/clash-verge-rev/clash-verge-rev/releases 下
```

让用户在 Clash Verge 主界面：
1. 导入订阅（如果没导入）
2. 设置 → **TUN 模式** → 打开
3. 首次会弹系统授权，输密码

**不要用 v2rayN 的 TUN**：实测在某些版本上抢路由失败，会把整机网络搞断（"所有软件网页都打不开"），且修复后需要重启 v2rayN 才能恢复。

### 第 3 步：重启 Antigravity 验证

```bash
osascript -e 'tell application "Antigravity" to quit' 2>/dev/null
sleep 4
pkill -f "Antigravity.app/Contents" 2>/dev/null
open -a /Applications/Antigravity.app
sleep 18
tail -25 ~/Library/Logs/Antigravity/language_server.log
```

成功标志：
- 端点变成 `cloudcode-pa`（不是 `daily-cloudcode-pa`）
- `State refresh took XXXms` 中 XXX < 2000
- `initialized server successfully`
- `lsof` 看不到 SYN_SENT

## 不要踩的坑

1. ❌ 改 settings.json 的 `http.proxy` —— 只影响渲染层，管不到 Go 子进程
2. ❌ 改 argv.json 的 `proxy-server` —— 同上
3. ❌ 设环境变量 `HTTPS_PROXY` —— Go 部分代码硬编码不读
4. ❌ `all_proxy=socks5://...` 但端口实际是 HTTP —— Go 走 SOCKS5 握手卡死
5. ❌ v2rayN 的 TUN —— 易把整机断网
6. ❌ `sudo cp` 到 `/Applications/Antigravity.app/` —— App Management 拒
7. ❌ `@electron/asar pack` 重打包 —— `node_modules` 全塞回主 asar，启动崩
8. ❌ "Auth succeeded" 不代表登录成功 —— 看 loadCodeAssist 是否秒回

## 回滚

```bash
osascript <<EOF
do shell script "rm -rf /Applications/Antigravity.app && \
  mv /Applications/Antigravity.app.dailybak /Applications/Antigravity.app" \
  with administrator privileges
EOF
```

## 完整资料

GitHub: https://github.com/百年100/antigravity-proxy-mac
（含完整脚本、诊断工具、证据日志、踩坑清单）

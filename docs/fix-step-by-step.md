# 完整修复流程

按顺序跑。每一步成功了再下一步。

## 前提

- macOS 14+（Sonoma / Sequoia / Tahoe）
- Antigravity 2.0.6 已安装在 `/Applications/Antigravity.app`
- 你已经有一个能用的 VPN/代理（Clash 系或 v2rayN 都行）
- 你的账号是普通的 Google 账号

如果你还没装 Clash Verge，先装：

```bash
brew install --cask clash-verge-rev
# 或从 https://github.com/clash-verge-rev/clash-verge-rev/releases 下 dmg
```

## 第 1 步：诊断（可选但推荐）

```bash
bash scripts/01-diagnose.sh
```

确认你中的是双重 bug。

## 第 2 步：补丁 `app.asar`

修 Bug 1（端点写死成 daily）。

```bash
bash scripts/02-patch-asar.sh
```

这个脚本会：
1. 退出 Antigravity
2. 把 `/Applications/Antigravity.app` 拷到 `/tmp/AG_rebuild/`（**用非 `.app` 后缀**绕过 macOS App Management 写入限制）
3. 用 Python 在 asar 里**字节级同长度替换** `daily-cloudcode-pa.googleapis.com` → `cloudcode-pa.googleapis.com` + 6 空格补位
4. `xattr -cr` 清隔离属性
5. `codesign --force --deep --sign -` ad-hoc 重签名

完成后 `/tmp/AG_rebuild/` 里是补好的 `.app`，原 `/Applications/Antigravity.app` 没动。

## 第 3 步：替换 `.app` 包

```bash
bash scripts/03-swap-bundle.sh
```

会弹一次系统授权对话框，输你的开机密码。脚本做：

1. 把原 `/Applications/Antigravity.app` 改名 `Antigravity.app.dailybak`（备份）
2. 把 `/tmp/AG_rebuild` 改名为 `Antigravity.app` 移到 `/Applications/`
3. 删掉 `~/Library/Caches/antigravity-updater/pending/Antigravity.zip`（防止下次启动自动更新又把 daily 版打回来）

成功后验证：

```bash
strings /Applications/Antigravity.app/Contents/Resources/app.asar | grep cloudcode-pa
# 应该输出: 'https://cloudcode-pa.googleapis.com'      ,
```

## 第 4 步：启用 Clash Verge 的 TUN 模式

修 Bug 2（Go 不读代理）。

打开 Clash Verge：

```bash
open -a "Clash Verge"
```

在主界面：

1. **导入订阅**（如果还没导入）：左侧 `订阅` 标签 → `添加订阅` → 粘贴你的订阅 URL → 启用
2. **打开 TUN 模式**：左侧 `设置` → 找到 **TUN 模式** 开关 → 打开
3. **关掉系统代理**（可选）：TUN 已经全局生效，开系统代理反而可能冲突
4. **首次开 TUN 会弹系统授权**：输密码，让它装 helper

验证 TUN 起来了：

```bash
netstat -rn -f inet | head -10
# 应该看到类似:
# 1                  198.18.0.1         UGSc                utun4
# 2/7                198.18.0.1         UGSc                utun4
```

直接测试（不带任何代理 env）：

```bash
unset HTTPS_PROXY HTTP_PROXY ALL_PROXY all_proxy https_proxy http_proxy
curl -sS -m 6 --noproxy '*' -o /dev/null \
  -w "google: %{http_code} t=%{time_total}\n" https://www.google.com/
# 期望: 200 t<2s
```

如果 curl 通了，TUN 就 OK。

## 第 5 步：重启 Antigravity 验证

```bash
osascript -e 'tell application "Antigravity" to quit' 2>/dev/null
sleep 4
pkill -f "Antigravity.app/Contents" 2>/dev/null
open -a /Applications/Antigravity.app
sleep 18
tail -25 ~/Library/Logs/Antigravity/language_server.log
```

成功标志：

```
URL: https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist
URL: https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels
Auth succeeded, refreshing features and managers
State refresh took 995ms
initialized server successfully in 7.7s
```

完整 lsof 检查：

```bash
LS_PID=$(pgrep -f "language_server --standalone" | head -1)
lsof -a -p "$LS_PID" -i 2>/dev/null | grep -v LISTEN
```

应该全是 `ESTABLISHED`，**没有 SYN_SENT**。

到此修复完成。回到 Antigravity 窗口，正常登录 / 用 Gemini 即可。

---

## 长期维护建议

1. **关掉自动更新**（或者自动更新前先看 release notes）：
   - Antigravity 设置里关 auto-update
   - 或者保留 `Antigravity.app.dailybak`，发现新版本又中 bug 时立刻回滚

2. **设 Clash Verge 开机自启**：
   - 系统设置 → 通用 → 登录项 → 加上 Clash Verge
   - 或 Clash Verge 内部设置勾选"开机启动"

3. **不要同时开多个 VPN 的 TUN**（v2rayN TUN + Clash Verge TUN）：会抢路由，整机断网。

4. **如果以后 Google 修了 daily bug 推 2.0.7+**：
   - 自动更新会覆盖你这个 ad-hoc 签名的版本，回到正常更新通道
   - 那时候只需要 TUN 步骤（Bug 2 估计要等 Google 改 Go 代码才能彻底修，短期内 TUN 是最稳的）

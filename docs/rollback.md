# 回滚

## 回滚 asar 补丁

如果 ad-hoc 重签名后 Antigravity 启动不了，或者 Google 推了新版本想恢复原状：

```bash
osascript <<'EOF'
do shell script "rm -rf /Applications/Antigravity.app && \
  mv /Applications/Antigravity.app.dailybak /Applications/Antigravity.app" \
  with administrator privileges \
  with prompt "回滚 Antigravity 到原 daily 版"
EOF
```

或者跑：

```bash
bash scripts/99-rollback.sh
```

## 关掉 TUN 模式

Clash Verge 主界面 → 设置 → TUN 模式 → 关。

或者直接退出 Clash Verge：

```bash
osascript -e 'tell application "Clash Verge" to quit'
```

## 清理代理环境变量（如果之前乱设过）

```bash
# 这次 session
unset HTTPS_PROXY HTTP_PROXY ALL_PROXY all_proxy https_proxy http_proxy GRPC_PROXY grpc_proxy

# launchctl level（影响所有新进程）
launchctl unsetenv HTTPS_PROXY
launchctl unsetenv HTTP_PROXY
launchctl unsetenv ALL_PROXY
launchctl unsetenv all_proxy
launchctl unsetenv https_proxy
launchctl unsetenv http_proxy
launchctl unsetenv GRPC_PROXY
launchctl unsetenv grpc_proxy
```

## 还原 settings.json / argv.json（如果之前的助手乱改过）

如果 `~/Library/Application Support/Antigravity/User/settings.json` 或 `~/.antigravity/argv.json` 里有 `http.proxy` / `proxy-server` / `proxy-bypass-list` 这些字段，可以删掉（它们对修复没帮助，反而可能干扰）。

```bash
# 看看有没有备份
ls ~/Library/Application\ Support/Antigravity/User/settings.json.bak.*
ls ~/.antigravity/argv.json.bak.*

# 还原（替换成你具体的备份文件名）
cp ~/Library/Application\ Support/Antigravity/User/settings.json.bak.<TIMESTAMP> \
   ~/Library/Application\ Support/Antigravity/User/settings.json
cp ~/.antigravity/argv.json.bak.<TIMESTAMP> \
   ~/.antigravity/argv.json
```

## 完全重置 Antigravity 用户数据（核选项）

⚠️ **会丢失所有 Antigravity 设置、扩展、登录状态**：

```bash
osascript -e 'tell application "Antigravity" to quit'
sleep 4
pkill -f "Antigravity.app/Contents"

# 移到 Trash 而不是 rm，万一想回来还能恢复
mv ~/Library/Application\ Support/Antigravity ~/.Trash/Antigravity-$(date +%Y%m%d-%H%M%S)
mv ~/.antigravity ~/.Trash/dotantigravity-$(date +%Y%m%d-%H%M%S)
mv ~/Library/Logs/Antigravity ~/.Trash/AntigravityLogs-$(date +%Y%m%d-%H%M%S)
mv ~/Library/Caches/antigravity-updater ~/.Trash/antigravity-updater-$(date +%Y%m%d-%H%M%S)

open -a /Applications/Antigravity.app
# 重新走 Welcome / Sign-in 流程
```

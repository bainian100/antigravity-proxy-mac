# 诊断清单

按顺序跑，每一步都记下输出。这样你能确认自己中的是哪个 bug，避免乱试。

## 0. 基础信息

```bash
# Antigravity 版本
defaults read /Applications/Antigravity.app/Contents/Info CFBundleShortVersionString
# 期望：2.0.6（中招版本）

# macOS 版本
sw_vers -productVersion
```

## 1. 看错误屏 / 错误日志

最近一次启动的日志：

```bash
LOGDIR=~/Library/Application\ Support/Antigravity/logs
LATEST=$(ls -t "$LOGDIR" | head -1)
echo "log session: $LATEST"
tail -50 "$LOGDIR/$LATEST/auth.log"
echo "---"
tail -30 ~/Library/Logs/Antigravity/language_server.log
```

**Bug 1 中招特征**（端点是 daily）：

```
URL: https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist
```

**Bug 2 中招特征**（请求超时）：

```
Post "https://...": context deadline exceeded
WaitForReady failed: context deadline exceeded
Cache(loadCodeAssistResponse): Singleflight refresh failed: ...
```

## 2. 验证 asar 是否被替换为 daily 版（Bug 1）

```bash
strings /Applications/Antigravity.app/Contents/Resources/app.asar \
  | grep -E "cloudcode-pa|cloud_code_endpoint"
```

中招会输出：

```
            'https://daily-cloudcode-pa.googleapis.com',
```

只看见 `cloudcode-pa.googleapis.com`（没有 `daily-`）就 OK。

也可以看 mtime 判断是不是 5/21 那次坏的 release：

```bash
stat -f "%Sm" /Applications/Antigravity.app/Contents/Resources/app.asar
```

## 3. 验证 Go 进程在不在直连 Google（Bug 2）

让 Antigravity 跑起来后：

```bash
LS_PID=$(pgrep -f "language_server --standalone" | head -1)
echo "language_server PID: $LS_PID"
lsof -a -p "$LS_PID" -i 2>/dev/null | grep -v LISTEN
```

中招特征：

```
TCP 192.168.x.x:xxxxx->1e100.net:https (SYN_SENT)
TCP 192.168.x.x:xxxxx->XXX.googleusercontent.com:https (SYN_SENT)
```

`SYN_SENT` 持续超过几秒就是被 GFW 截了。

## 4. 验证代理本身可用

确认你的代理（不管是 v2rayN / Clash / Surge）确实通：

```bash
# 替换成你实际的代理端口（v2rayN 默认可能是 10808 / 7897 / 1087；Clash 默认 7890）
PROXY_PORT=10808
nc -z 127.0.0.1 $PROXY_PORT && echo "$PROXY_PORT open" || echo "$PROXY_PORT closed"

curl -sS -m 5 -x http://127.0.0.1:$PROXY_PORT \
  -o /dev/null -w "via-proxy: %{http_code} t=%{time_total}\n" \
  https://cloudcode-pa.googleapis.com/
# 期望：404 t<2s（404 是正常的，说明 endpoint 通了）
```

## 5. 验证 TUN 是否生效

```bash
netstat -rn -f inet | head -10
```

TUN 生效特征：

```
default            192.168.1.1        UGScg                 en0
1                  198.18.0.1         UGSc                utun4   ← Mihomo TUN fake-IP
2/7                198.18.0.1         UGSc                utun4
4/6                198.18.0.1         UGSc                utun4
```

看到 `198.18.0.x → utun*` 这种路由就说明 TUN 接管了。

直接测：

```bash
unset HTTPS_PROXY HTTP_PROXY ALL_PROXY all_proxy https_proxy http_proxy
curl -sS -m 6 --noproxy '*' -o /dev/null \
  -w "google: %{http_code} t=%{time_total}\n" https://www.google.com/
# 期望：200 t<2s（不带任何代理 env，TUN 透明转发也能通）
```

## 6. 综合判断

| Bug 1 | Bug 2 | 怎么修 |
|-------|-------|--------|
| ✅ 中 | ✅ 中 | 两步全做：补丁 asar + 启 TUN |
| ✅ 中 | ❌ 没中 | 只补 asar |
| ❌ 没中 | ✅ 中 | 只启 TUN |
| ❌ 没中 | ❌ 没中 | 不是这俩问题，重新想 |

中国大陆用户用 2.0.6 基本两个都中。

## 一键诊断脚本

```bash
bash scripts/01-diagnose.sh
```

会把上面这些都跑一遍，输出一份现状报告。

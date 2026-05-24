# 不要踩的坑

GPT-5 修这个问题修了好几个小时没修好，下面这些都是真实踩过的坑。把它们列出来不是嘲讽，是为了让别人不再重复踩。

## 1. 改 settings.json 的 `http.proxy`

```json
{
  "http.proxy": "http://127.0.0.1:10808",
  "http.proxySupport": "override"
}
```

**为什么不行**：这只影响 Antigravity 的 Electron 渲染层（VSCode 的扩展、Webview）。子进程 `language_server`（Go binary）是独立进程，不读这个配置。

## 2. 改 `~/.antigravity/argv.json` 的 `proxy-server`

```json
{
  "proxy-server": "http://127.0.0.1:7897",
  "proxy-bypass-list": "<local>;localhost;127.0.0.1;::1"
}
```

**为什么不行**：这是 Electron 的 `--proxy-server` 命令行参数，效果跟 settings.json 类似 —— 只管渲染层。Go 子进程依然不读。

## 3. 设环境变量 `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY` / `GRPC_PROXY`

```bash
HTTPS_PROXY=http://127.0.0.1:10808 \
HTTP_PROXY=http://127.0.0.1:10808 \
ALL_PROXY=http://127.0.0.1:10808 \
GRPC_PROXY=http://127.0.0.1:10808 \
open -a Antigravity
```

**为什么不行**：Go 的 net/http **大部分**调用会读 `HTTPS_PROXY`，但 `language_server` 里有几个调用路径用了自定义 transport 或 gRPC-Go，根本不读环境变量。

证据：进程环境里 `HTTPS_PROXY` 都设了，但 lsof 看到一半连接走代理（`localhost:10808`），一半直连 Google IP（`1e100.net:443 SYN_SENT`）。

## 4. 设 `all_proxy=socks5://127.0.0.1:10808`，但端口实际是 HTTP

```bash
launchctl setenv all_proxy socks5://127.0.0.1:10808
```

**为什么不行 + 反作用**：很多代理软件（Mihomo、xray mixed-port）在同一个端口同时支持 HTTP 和 SOCKS5，自动检测协议。但有些版本只支持 HTTP。

如果你的 10808 实际只是 HTTP，但 `ALL_PROXY=socks5://...`，Go 的 net/http 会按 SOCKS5 协议去握手 → 服务器看到不像 SOCKS5 的字节就拒绝 → Go 这边超时 → **比不设代理还慢**。

**建议**：要么彻底删 `ALL_PROXY` / `all_proxy`，要么明确写 `http://`，不要写 `socks5://` 除非你确定端口支持。

## 5. 用 v2rayN 的 TUN 模式

**为什么不推荐**：v2rayN 在 macOS 上的 TUN 实现依赖外部 sing-box / mihomo 内核，但它的路由抢占在某些版本上**会失败**：开了 TUN 之后默认网关被 utun 接管，但 utun 处理器没正确启动，结果**所有流量都被吞掉了** —— 不光 Antigravity 上不去，**整机断网，连聊天软件都打不开**。

**实测 2026-05-24 那天就是这样**：用户点了 v2rayN 的 TUN 开关，5 秒后说"所有软件网页都打不开了，包括你"。

**替代**：用 Clash Verge（Mihomo 内核）。它的 TUN 实现更稳，路由抢占失败会自动回滚，不会把整机搞断。

## 6. `sudo cp` 到 `/Applications/Antigravity.app/Contents/`

```bash
sudo cp app.asar.patched /Applications/Antigravity.app/Contents/Resources/app.asar
# Operation not permitted
```

**为什么不行**：macOS 14+（Sonoma）引入了 **App Management 隐私保护**，阻止任何进程修改已签名 app bundle 内部的文件，**即使 sudo 也不行**。授权要在「系统设置 → 隐私与安全 → App 管理」里手动给。

**绕过办法**：把整个 `.app` 拷到 `/tmp` 下用**非 `.app` 后缀**的目录名（比如 `/tmp/AG_rebuild/`）。在那里改完再整体替换回 `/Applications`。**不能在 `/tmp/Antigravity.app/` 里改**（macOS 看到 `.app` 后缀 + Info.plist 仍然会保护）。

## 7. 用 `@electron/asar pack` 重打包

```bash
npx @electron/asar extract app.asar extracted
sed -i '' 's/daily-cloudcode-pa/cloudcode-pa/' extracted/dist/languageServer.js
npx @electron/asar pack extracted app.asar.new
```

**为什么不行**：原 `app.asar` 利用 `app.asar.unpacked/` 把 `node_modules/chrome-devtools-mcp/**/*.js` 这些文件 unpack 出来（因为运行时需要按真实文件读）。`pack` 命令默认会把所有 `node_modules` 都打回主 asar，体积从 **2MB 变 20MB**，并且 unpack 规则跟原版对不上 → 启动崩。

要正确重打包，得用 `--unpack` 参数指定原 unpack 模式 —— 但原 release pipeline 用什么 glob 是不公开的。试错代价太高。

**替代**：字节级**同长度替换**。原始 URL `https://daily-cloudcode-pa.googleapis.com` 是 41 字符，新 URL `https://cloudcode-pa.googleapis.com` 是 35 字符，差 6 字符。在闭合引号后面补 6 个空格：

```python
old = b"'https://daily-cloudcode-pa.googleapis.com',"  # 44 字节
new = b"'https://cloudcode-pa.googleapis.com'      ,"  # 44 字节
# 引号闭合在 com'，逗号位置不变 → JS 仍然合法
# 不动 asar header 里的 offset/size，文件结构完整
```

这样不需要重打包，asar header 完全不动。

## 8. 信"Auth succeeded"就以为登录好了

```
[Auth] Auth state changed to: signedOut
[OAuth] Token exchange failed: ETIMEDOUT
...
Auth succeeded, refreshing features and managers   ← 这行会出现
```

**为什么误导**：日志里的 `Auth succeeded` 不代表 OAuth 完成，它代表"凭据缓存初始化完成"。即使 token 是空的，这行也会打。

**真正的成功标志**：

```
URL: https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist  ← 状态码非超时
State refresh took XXXms                                            ← XXX < 2000
initialized server successfully in X.Xs
```

加上 `lsof` 看到所有连接都是 ESTABLISHED，没 SYN_SENT。

## 9. 假设网络问题就是代理问题

Antigravity 第一次启动失败的日志里有：

```
[OAuth] Token exchange failed: request to https://oauth2.googleapis.com/token failed,
  reason: connect ETIMEDOUT 74.125.195.95:443
```

很容易让人以为是"那一刻代理挂了"。**实际**这个 ETIMEDOUT 是干扰项 —— 即使后来网络恢复 + 代理通了，登录依然失败，因为：

1. Bug 1（端点是 daily，根本没权限）— 网络再好也没用
2. Bug 2（部分代码硬编码直连）— 代理再通也救不了

**教训**：看到一个网络错误就开始改代理，是最常见的错误起点。先看错误的目标 URL（`daily-cloudcode-pa.` 这种异常），再看错误是不是稳定复现，再决定动哪里。

## 10. 改 OAuth client ID / 自己搞 Google Cloud project

有些教程说"申请你自己的 Google Cloud project，把 OAuth client ID 写进去就能登"。

**为什么不行**：Antigravity 用的是**内部 Cloud Code API**（`cloudcode-pa.googleapis.com`），不是公开 API。你自己的 Cloud project 没有调用这个 API 的权限，OAuth scope 都对不上。改 client ID 也救不了。

## 总结：决策树

```
登录失败
├── 错误信息里有 daily-cloudcode-pa  → Bug 1 + 大概率 Bug 2 → 走完整修复流程
├── 错误信息里是 cloudcode-pa（无 daily）+ 超时 → 仅 Bug 2 → 启 TUN 即可
├── 错误信息是 401 / 权限相关 + 端点是 daily → Bug 1 → 补 asar 即可
├── 错误信息是 OAuth callback 失败 → 网络瞬断，重试 / 检查代理
└── 其他 → 不在本仓库范围
```

# 双重根因分析

Antigravity 2.0.6 在中国大陆登录失败，是**两个独立 bug 叠加**的结果。这俩 bug 看起来都像"网络问题"，但本质完全不同，必须分开理解、分开修。

## Bug 1：`app.asar` 端点写死成 daily 通道

### 现象

OAuth 完成后，Antigravity 立刻报：

```
Post "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist": context deadline exceeded
```

注意端点是 `daily-cloudcode-pa.googleapis.com` —— 多了 `daily-` 前缀。

### 证据

```bash
strings /Applications/Antigravity.app/Contents/Resources/app.asar \
  | grep cloudcode-pa
```

输出：

```
'https://daily-cloudcode-pa.googleapis.com',
```

只有这一个端点，**没有**生产端点 `cloudcode-pa.googleapis.com`。

抓出上下文：

```js
'--cloud_code_endpoint',
'https://daily-cloudcode-pa.googleapis.com',
'--enable_sidecars',
```

这是 Electron 主进程启动 `language_server` 子进程时传的参数 —— `--cloud_code_endpoint` 被硬编码指向 daily channel。

### 为什么这是 bug

`daily-cloudcode-pa.googleapis.com` 是 Google **内部** daily/canary 通道，只对 Google 员工的测试账号开放。普通 Google 账号去访问会得到 401 / 超时 / "权限不足"等错误。

生产环境应该用 `cloudcode-pa.googleapis.com`（无 `daily-` 前缀）。

### 时间线

- Antigravity 2.0.5 及更早：用生产端点，工作正常
- 2026-05-21：Google 推出 2.0.6，`app.asar` 里端点被错配成 daily（疑似 release pipeline 把 internal build 推到了稳定渠道）
- 2026-05-24：自动更新器把 2.0.6 推到用户机器，所有自动更新的用户都中招

可以从 `app.asar` 的 mtime 验证：

```bash
stat -f "%Sm" /Applications/Antigravity.app/Contents/Resources/app.asar
# 中招的是 May 21 23:59 这个时间戳
```

### 修法

字节级同长度替换。**不要重打包 asar**（理由见 `pitfalls.md`）。

```python
old = b"'https://daily-cloudcode-pa.googleapis.com',"
new = b"'https://cloudcode-pa.googleapis.com'      ,"
# 都是 44 字节：原 URL 41 字符；新 URL 35 字符 + 6 空格
# 引号闭合在 com'，逗号位置不变 → JS 仍然合法
# 不动 asar header offsets，不破坏文件结构
```

完整脚本见 `scripts/02-patch-asar.sh`。

---

## Bug 2：Go `language_server` 部分代码不读 `HTTPS_PROXY`

### 现象

修了 Bug 1 之后，端点对了，但请求**还是超时**：

```
Post "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist": context deadline exceeded
```

注意这次是**生产端点**也超时。所以是网络层的问题。

### 证据

把 `language_server` 进程的所有连接列出来：

```bash
LS_PID=$(pgrep -f "language_server --standalone" | head -1)
lsof -a -p "$LS_PID" -i 2>/dev/null | grep -v LISTEN
```

输出（节选）：

```
language_  TCP localhost:62665->localhost:10808 (ESTABLISHED)   ← 走代理 ✅
language_  TCP localhost:62674->localhost:10808 (ESTABLISHED)   ← 走代理 ✅
language_  TCP 192.168.x.x:62676->1e100.net:https (SYN_SENT)    ← 直连 ❌
language_  TCP 192.168.x.x:62678->1e100.net:https (SYN_SENT)    ← 直连 ❌
language_  TCP 192.168.x.x:62696->1e100.net:https (SYN_SENT)    ← 直连 ❌
```

**同一个进程**，**有的连接走代理，有的连接直连**。直连那些走的是 192.168.x.x → 1e100.net（Google CDN 的反查 PTR），走 WiFi 出去会被 GFW 截断 → SYN_SENT 卡死 → 10 秒后超时。

### 为什么 `HTTPS_PROXY` 不管用

环境变量都设了：

```
$ ps eww -p $LS_PID | tr ' ' '\n' | grep -i proxy
HTTPS_PROXY=http://127.0.0.1:10808
HTTP_PROXY=http://127.0.0.1:10808
ALL_PROXY=http://127.0.0.1:10808
GRPC_PROXY=http://127.0.0.1:10808
```

但 Go 代码里那些"硬编码直连"的代码路径根本不读环境变量。可能的原因：

- 用 `&http.Transport{Proxy: nil, ...}` 显式禁用了 env 代理
- 用 gRPC-Go 的某些老版本，`grpc.NewClient` 默认不走 `HTTPS_PROXY`
- 用 google.golang.org/api 的某些 transport，自带 token source 但没挂代理

具体是哪一种**不重要**，因为我们改不了 Go binary。重要的是：**在用户态强制环境变量改不动它**。

### 修法

唯一可靠的办法是**系统级流量劫持**，让"直连"的请求在内核层就被透明转发。这就是 TUN 模式：

- TUN 设备会作为新的默认网关
- 所有出站 TCP/UDP 包先到 TUN 设备
- TUN 处理器（mihomo / sing-box）负责把这些包按规则转发到上游代理（10808）
- Go 代码**完全感知不到**：它以为自己在直连，实际上每个包都被劫持了

不能用 v2rayN 的 TUN（在某些版本上路由抢占失败导致全机断网），用 **Clash Verge (Mihomo) + TUN** 最稳。

### 为什么不能用其他办法

| 方法 | 为什么不行 |
|------|------------|
| `proxychains-ng` (DYLD_INSERT_LIBRARIES) | macOS hardened runtime + library validation 会拒绝 dyld insert |
| pf rdr-to + redsocks | macOS pf 不支持 redsocks 这种模式，需要写复杂规则且 SIP 限制 |
| /etc/hosts 把 googleapis 指 127.0.0.1 + 本地 MITM | TLS 证书会校验失败（除非装根证书，太重） |
| 直接 patch Go binary | Hardened runtime 签名校验，patch 完没法启动；且 Go binary 没符号 |
| 让 Google 修 bug | 谁知道什么时候 |

TUN 模式是唯一干净有效的方案。

---

## 两个 bug 的逻辑组合

```
Bug 1 (asar 端点错):     daily-cloudcode-pa  →  cloudcode-pa
                         (修了之后用户的请求至少不会被 401)

Bug 2 (Go 不读代理):     部分请求绕过代理直连 Google IP
                         (修了之后所有请求都经过代理出境)

只修 Bug 1：               请求到了正确端点，但部分请求被 GFW 截，仍超时
只修 Bug 2：               请求都能出去，但端点是 daily 的，仍 401
两个都修：                 ✅ 工作正常
```

这就是为什么之前 GPT-5 一直修不好 —— 它发现了 Bug 2 的"代理问题"，反复折腾环境变量和 v2rayN 配置；但完全没意识到 Bug 1（端点本身就是错的）。

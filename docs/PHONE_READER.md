# 手机翻页器

## 使用

1. 在 Mac「图书」中打开 EPUB 正文。
2. 打开 boringNotch 设置 → 通用 → 阅读遥控，点击「启动服务」。服务默认关闭，不随应用启动自动开启。
3. 手机与 Mac 连接同一可信 Wi-Fi，扫描二维码；或者在 Safari 输入显示的地址，再输入 8 位配对码。多个网卡时可切换连接地址。
4. 点手机上的上一页／下一页。Mac 会激活图书，并仅向图书进程发送左右方向键。
5. 完成阅读后停止服务。停止、重启或退出应用会使旧配对失效。网络地址改变后请重启服务。

首次使用可能需要允许本地网络或防火墙入站连接。翻页需要 boringNotch 辅助进程的辅助功能权限，设置提供授权入口；不需要授权 Terminal 或 System Events。本地临时签名更新后可能需要重新开启辅助功能权限。

## 当前边界

- 仅支持局域网 IPv4；需要 Mac 保持唤醒且解锁。Books 必须已打开，正文要有焦点。
- HTTP 没有加密，只用于可信局域网。二维码包含会话凭证，请勿公开截图。无公网访问、云服务或内容上传。
- 所有手机共享一次服务会话；无设备列表或单台撤销。停止服务可全部撤销。
- 返回成功只表示按键已发送，不证明 EPUB 页码发生变化。搜索框、资料库及弹窗焦点可能影响结果。
- 服务就绪不等于辅助功能已授权。拒绝权限、真实 iPhone Safari 和真实 EPUB 翻页需分别验证。

## 集成实现

- `RemoteBooksServer.swift`：Network.framework 原生 HTTP 服务，在已有 XPC 辅助进程内运行，无 Python 或外部 Swift 工具链依赖。
- `BooksRemote.html`：复用交接原型的手机网页，只更新宿主接入提示。
- `BooksRemoteModel` / `BooksRemotePreferences`：宿主设置、配对二维码、地址选择、服务状态和续约。
- 主应用保留沙箱；辅助进程复用已建立的辅助功能权限边界。使用 CGEvent 定向发给 `com.apple.iBooksX` / `com.apple.iBooks`，不通过 Apple Events 操作 System Events。
- 配对码/token 仅保存在内存，通过私有 XPC 返回宿主，不输出到日志。二维码使用 Core Image 原生生成。
- 随机空闲端口；只接受私有或回环 IPv4 客户端；Host 白名单、POST Origin 严格匹配、JSON 请求体上限 1024 字节、拒绝重复头／分块编码、最多 32 个连接、单连接 8 秒超时。
- 60 秒内 10 次错误配对限流；翻页不排队；最近 256 个请求按 ID 去重，同 ID 不同方向拒绝。
- 宿主每 3 秒续约；失去宿主续约 12 秒后由看门狗停止服务（每 2 秒检查），XPC 中断时直接停止。
- 不主动启动远程服务，不持久化启用状态，不更改上游自动更新配置。

## 验证

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/check-books-remote.sh`

模拟测试覆盖配对、鉴权、Host／Origin、非法参数、去重、忙碌拒绝、限流、HTTP framing、停止、凭证轮换及续约超时。模拟执行器不会发送按键。

浏览器测试 `Tests/RemoteBooks/browser.cjs` 使用 Playwright，参数依次为模拟 Swift 服务可执行文件、HTML 路径、截图输出目录；可以用 `PLAYWRIGHT_MODULE` 指定已安装的 Playwright 模块。

271.35 的 Chromium 手机模拟完成配对、前后翻页、刷新恢复、扫码片段清理、离线提示和四个视口检查，竖屏及横屏截图已人工检查。271.37 已由用户在真实 iPhone Safari 和 Mac 图书 EPUB 正文中确认连接与前后翻页可用。公开版的独立应用身份仍需用户首次授权。

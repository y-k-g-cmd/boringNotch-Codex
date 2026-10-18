# 使用 GitHub 托管更新

项目仓库：https://github.com/y-k-g-cmd/boringNotch-Codex

- 仓库首页用于介绍源码，不能直接作为 Sparkle 更新源。
- GitHub Pages 的原始 XML：`https://y-k-g-cmd.github.io/boringNotch-Codex/appcast.xml`。
- 应用 ZIP 等下载包：GitHub Releases 的版本附件。
- Pages 发布目录设为分支上的 `/docs` 后，`docs/appcast.xml` 才会成为上述更新地址。创建 fork 不会自动启用 Pages。

## 当前安全默认值

`ForkUpdatesEnabled=false`；`SUFeedURL` 和 `SUPublicEDKey` 已移除，不使用上游地址或上游公钥。应用即使被改了 Bundle ID，也不会因此自动开启更新。没有密钥时不要生成假签名，不要复用上游密钥。

## 正式启用顺序

1. 创建自己维护的 fork，确认 Releases 和 Pages 可访问。
2. 用所依赖版本的 Sparkle 官方工具 `generate_keys` 生成自己的一对 EdDSA 密钥。只把公钥写入 `SUPublicEDKey`；私钥安全保存在维护者钥匙串或受保护的发布环境中，不提交到 Git。
3. 使用自己的 Developer ID 签名和 Apple 公证完成发行包；Sparkle 的更新签名与 Apple 签名是两件事，不能互相替代。
4. 用 `generate_appcast` 为最终压缩包生成带真实签名和长度的 appcast。下载 URL 指向对应 Release 附件；`sparkle:version` 匹配实际 CFBundleVersion，后续版本必须递增。
5. 发布 XML 和附件，核对返回的 XML、HTTPS、签名、版本号、包内容和对应源码 tag；确保附件不会在签名后被重新压缩或替换。
6. 在发行构建的 Info.plist 配置自己的 `SUFeedURL`、真实 `SUPublicEDKey` 并设 `ForkUpdatesEnabled=true`。代码要求 feed 与本 fork 的 GitHub Pages 路径匹配。
7. 实际验证从旧测试版升级到新测试版，再发布给用户。涉及签名身份／Bundle ID 改变时单独验证迁移，不承诺自动迁移旧本地版数据。

当前 `appcast.xml` 是空频道，不能向用户提供更新。不要仅为了让按钮可点击而启用更新。

参考：https://sparkle-project.org/documentation/publishing/ 与 https://developer.apple.com/macos/distribution/ 。

# 公开发布步骤

## 本地准备已完成后

1. 在上游 https://github.com/TheBoredTeam/boring.notch 点击 Fork。
2. Owner 选择 `y-k-g-cmd`，Repository name 填 `boringNotch-Codex`，创建 fork。拟用地址是 `https://github.com/y-k-g-cmd/boringNotch-Codex`，创建前不能宣称仓库已经存在。
3. 在此本地候选仓库添加 origin 指向自己的 fork；upstream 已指向上游。不要把 origin 设置为上游后尝试推送。
4. 复核 `git status`、`git diff`、`scripts/check-public.py` 的结果和 `docs/PUBLICATION_STATUS.md`。本地源目录及聊天输出不在公开候选仓库中。
5. 设置本人认可的提交姓名与 GitHub noreply 邮箱。不要把电脑默认私人邮箱直接写入公开历史；也不要猜测 GitHub 分配的数字 ID。之后再提交改动。
6. 获取 fork 的远端状态，确认基础提交与分支关系后，将候选改动推送为自己的功能分支，再合入 fork 的默认分支。没有自动向上游提交 PR。
7. 配置仓库描述、需要的 Issues、私密漏洞报告、README 中的发布状态与许可证；需要网站时再启用 Pages。
8. 发布前从新目录解析依赖并完整构建；在没有既有偏好的用户环境下做首次启动、授权和 GUI 检查。

## 二进制首发前必须补完

- 核实嵌入媒体框架及 SPM 组件的许可、签名和分发声明。
- 核实正式签名／公证、更新签名与自己的下载地址。
- 多选／取消切区、向 Finder 复制与移动、移动失败保留、客户端兼容性和多屏分别验收。
- 用合成内容制作演示图，截图不含私人标题、路径、文件或账户信息。
- 给源码打与二进制匹配的 tag，附 SHA256 和构建说明；保留 GPLv3、版权与第三方声明。

仓库已由维护者创建；本 fork 采用已审查的 v2.7.3 定制代码独立维护，不跟进上游新版。提交与推送记录以 Git 历史为准。Pages、更新签名私钥和二进制 Release 尚未配置；有限规则扫描不能证明绝对不存在敏感信息。

## 当前 Beta 发布方式

维护者已授权先发布 `v0.1.0-beta.1` 测试下载包。此测试包明确使用 ad-hoc 签名且未公证；不以正式版承诺所有验收矩阵完成。公开身份新归档、基础启动与媒体显示已检查，复杂文件操作、Intel 硬件和完整首次 Codex 授权的限制随包列出。打包脚本负责附带许可、对应源码及校验值，正式 Developer ID／公证和自动更新另行推进。

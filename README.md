# 主播伴侣下载

[正式 Windows 下载](https://github.com/grusirna/zhubobanlv-releases/releases/latest)

安装前核对发行页版本与 SHA256SUMS。主应用提供录播、音效快捷键、麦克风优化、窗口缩放、画面增强和文稿提词；语音模型另行下载安装，不包含在主安装器中。旧版下载保留于 Releases。

此仓库保存构建流程、发行说明、校验和和下载附件。应用源码位于私有仓库，两个仓库的 Git 历史独立。没有宣传网站或 Pages。

维护者在 Actions 手动运行 Windows build and draft，输入私有 main 的完整提交 SHA 和对应产品版本。builder 只读源码，publisher 只写本仓库；候选和诊断加密传给验收主机，公共日志仅显示阶段结果。通过完整构建门禁及同哈希安装／升级／卸载、数据保留、后台和六页面验收后，维护者再开放正式安装包。正式版本附件不覆写，构建附件保留 3 天。

维护者验收私钥须与 build-transfer-public.pem 配对，保存在维护主机受限的凭据目录；私钥、源码、用户数据、编译缓存、日志和 source map 不进入本仓库。

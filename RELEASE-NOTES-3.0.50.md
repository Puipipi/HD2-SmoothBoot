# SmoothBoot 3.0.50 — candidate / 候选版

Repairs five independently reproduced runtime defects: underscore exclusion
parsing, boot-state replacement restoration, ignored `reentry_max` configuration,
shared Windows FFI declaration collisions, and errors raised while formatting
foreign error objects. New-install GC defaults are 0/0, leaving the current
engine/loader policy unchanged. Existing explicit settings are preserved.

C4-specific adapters remain removed. This candidate retains the working tree's
other 3.0.47/3.0.48 changes and does not revert to 3.0.45.

63 unittest methods and 8 additional FFI checks pass, as do the boot-pause and
writer-interdiction scripts. Tests use private Lua states, including the game's
Lua DLL. Natural-GC stress with 120,000 updates and 4,096 replacement callbacks
did not reproduce sustained retention in those modeled paths. It does not rule
out CowboyBingus's reported in-game memory leak or establish its cause.

This package has not been deployed, published, or accepted in live gameplay.
Restart the game when upgrading. Details: [source audit](docs/bingus-source-audit-2026-10-09.md).

修复五项可独立复现的问题：排除名下划线被拆开、同名全局状态表替换后无法恢复、
`reentry_max` 配置未读取、共享 Windows FFI 声明冲突、异常文本转换再次抛错。
新安装 GC 默认 0/0，不改变当前引擎/加载器策略；已有显式设置保留。

继续移除 C4 专用适配，保留工作区其他修改，并非回退至 3.0.45。
63 项 unittest、8 项额外 FFI 检查及开局暂停/写入托管脚本通过。
自然 GC 压力测试未在所模拟路径复现持续引用增长，不能证明作者报告的实机泄漏已解决。
本包尚未部署、发布或完成游戏验收。升级需重启游戏。

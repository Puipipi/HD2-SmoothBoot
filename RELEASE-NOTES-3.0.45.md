# SmoothBoot 3.0.45

正式维护版，2026-10-04。

修复 Watchdog 将部分写入模组的工作计入 SmoothBoot 的归属问题。写入保护门现在显示为 `模组名称 [SB gate]`：这一行包含原模组工作和少量转发开销，SmoothBoot 调度器保留独立一行。标签在释放后仍保留，不表示报错或模组仍被暂停。没有修改第三方模组或 Watchdog，也没有隐藏实际执行成本。

保留自动 HUD 识别和现有兼容性保护。被识别的 HUD 所在调用链保留逐帧更新；特殊或动态绘制仍可能需要排除名单。这仍是整链保护，不是逐模组独立调度。

`Collect-Logs.bat` 首次运行自动生成，可收集日志并管理排除名单，位置为 `%LOCALAPPDATA%\CowboyBingus\Helldivers2\SmoothBoot`，与 `config.txt` 同目录。安装 ZIP 不包含裸 BAT 文件。

安装：将 `HD2-SmoothBoot-3.0.45.zip` 直接导入模组管理器，替换旧版；保留现有配置。不要同时启用多个 SmoothBoot 版本。

验证：106 项离线回归检查及独立脚本、实际 Watchdog 源码对照通过；实机启动归属正常。用户随后完成任务、死亡复活、返舰船、军械库、Esc 和舰船快捷键检查，报告正常。连续 530.7 秒日志采集中，Smooth 回调错误计数均为 0，9 个完整 Watchdog 窗口保留 44 节调用链。

本版修正性能归属，不宣称修复 C4 帧率问题、片头前黑屏，或使所有模组达到每帧 0.05 ms。测试中仍有游戏卡顿记录；该验收不能保证所有模组组合、多人或长时间运行都没有问题。

---

Maintenance release, 2026-10-04.

Fixes Watchdog ownership of work performed behind held-writer gates. Source-based profilers now show `mod name [SB gate]`, including the original writer's work and small forwarding overhead; the SmoothBoot governor keeps its own row. The label remains after release and does not indicate an error or an active hold. No third-party files or Watchdog code are modified, and actual work is not hidden.

Automatic HUD discovery and existing compatibility safeguards remain. Recognized HUDs retain every update of their enclosing chain; unusual or dynamic renderers may still need exclusion. This is whole-chain protection, not independent per-mod scheduling.

`Collect-Logs.bat` is generated on first run beside `config.txt` in `%LOCALAPPDATA%\CowboyBingus\Helldivers2\SmoothBoot`. It collects logs and manages exclusions. No loose BAT is shipped in the installation ZIP.

Import `HD2-SmoothBoot-3.0.45.zip` directly into your mod manager and replace the old version. Keep existing configuration and enable only one SmoothBoot version.

Validation: 106 offline regression checks, standalone scripts and replay using unchanged Watchdog source passed. Live startup attribution passed; the user then reported normal mission, death/respawn, return-to-ship, armory, Esc and ship-hotkey checks. A continuous 530.7-second log capture reported zero Smooth callback errors; nine complete Watchdog windows retained all 44 links.

This release corrects accounting. It does not claim a C4 FPS fix, shorter pre-animation black screens, universal 0.05 ms-per-frame mod overhead, or compatibility with every combination. Hitch records remain in the tested game session; multiplayer and long-duration coverage are limited.

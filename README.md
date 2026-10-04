# HD2 SmoothBoot

当前正式维护版 **3.0.45** 修正写入保护门的性能归属：按源码归属的性能面板会将门显示为“被托管模组名称 [SB gate]”，把原模组工作及少量转发开销计入这行，Smooth 调度器保留独立一行。标签明确区分我们的代理与第三方原回调，没有修改第三方文件或 Watchdog，也没有关闭计时来降低数值。

保持原有探针和释放方式；只让我们自己的小转发函数不被 JIT 内联缓存，避免后来插入的探针被绕过。避免将自己的保护门误当新模组重新接管。现代 LuaJIT 和独立游戏 Lua 库的实际 Watchdog 源码对照通过：原先误算到 Smooth 的合成 79.09 ms/s 已分回具体模组，总耗时和回调次数保持一致。

**2026-10-04 实机验收通过**：44 节调用链保留，六个保护门显示具体模组，Smooth 仅余独立一节；首两分钟未进 Watchdog 前十（约≤1.72/2.60 ms/s），修复前对应473.44/120.67 ms/s。另一次连续运行中，用户完成任务、死亡复活、返舰船及军械库/Esc/舰船快捷键检查，均报告正常；530.7秒采集中的Smooth回调错误计数均为0，9个完整Watchdog窗口均保持44节。该结果是归属与本机功能验收，不是实际CPU/FPS节省量或所有第三方功能的全面保证。工具在首次运行正常重新生成。详见 [3.0.45发布说明](RELEASE-NOTES-3.0.45.md)。

工具生成路径保持 `%LOCALAPPDATA%\CowboyBingus\Helldivers2\SmoothBoot\Collect-Logs.bat`，与 `config.txt` 同目录。用户已确认文件存在；打包 ZIP 和排除名单合并的隔离检查通过。安装 ZIP 仍不含裸 BAT。

Maintenance release **3.0.45** makes held-writer ownership explicit in source-based profilers as `writer name [SB gate]`. The row includes the original writer's work and the routing shell's small overhead; the governor retains its own SmoothBoot row. Profiler probes, results and release policies stay intact. Only our forwarding helper is kept interpreted to prevent JIT inlining from bypassing later probes. No foreign files or Watchdog tables are changed. Deterministic replay with unchanged Watchdog source in both LuaJIT runtimes preserves total work and callback counts while moving synthetic 79.09 ms/s back to its owners. **Live acceptance on 2026-10-04:** startup attribution and tool generation passed; the user then reported normal mission, death/respawn and return-to-ship checks. The 530.7-second recording had zero reported Smooth callback errors and nine complete Watchdog windows retained 44 links. These checks do not establish universal compatibility or CPU/FPS savings. The companion tool was regenerated beside config.txt, not in Arsenal's library. See [release notes](RELEASE-NOTES-3.0.45.md).

以下保留历史候选记录。

候选 **3.0.41** 扩展 HUD 自动识别：只读 LuaJIT 函数元数据中的实际绘图字段访问、闭包持有的绘图接口以及模组 render 回调，不依赖新模组的名称。首次更新、更新或绘制链头变化及周期巡检触发发现；不可变元数据只解析一次。没有全局绘图钩子，也不会为识别而执行第三方代码或绘图接口。

常见 GUI/LineObject 绘制被识别后，所在链条保留逐帧更新。**仍是整链保护；特殊或动态绘制无法保证全部识别，排除名单仍可使用。** 同时修正更新总线里排除项被误报为未安装的问题，保留旧的输入/UI 保护。

新增一次性的自身初始化和首次更新计时，用于区分 Smooth 模块执行与片头前启动等待。**没有宣称黑屏已优化，也没有改变第三方启动顺序或扫描预算。** 本版本尚未部署或完成真实游戏验收。

Development candidate **3.0.41** discovers common graphics field accesses, captured graphics APIs and mod render hooks from read-only function metadata. Discovery never calls foreign callbacks or graphics APIs and caches immutable metadata. Detected callbacks preserve the enclosing chain's full update cadence; this is not selective scheduling and unusual/dynamic renderers may still need exclusion. One-time startup timestamps measure this module's own initialization only; no black-screen improvement is claimed. Live acceptance is pending.


上一候选 **3.0.40**：将安全的通用优化放入 Smooth 的公共回调路径。
不再逐帧创建返回值表或心跳闭包，并完整保留末尾 nil 和多返回值。
写入门的异常、循环保护及 Watchdog 下游探针保持原有策略。
弹道 HUD、Enemy HP、DiversBestFriend、Aggro Counter 的回调会在首帧、
调用链头变化时及周期巡检中识别，包括深层更新总线；所在链条不会被跳帧或暂停。
这是整条链的保守保护，**不是逐模组独立节流**；高开销反馈仍需实机对照。
没有新增通用 FFI 钩子、缓存游戏动态数据或改动第三方模组文件。

92 项回归测试、独立游戏 Lua 库的输入/射击/UI 校验以及两种运行库的
32 种 HUD 调用链布局检查通过。模拟中的 180 帧均保留 180 次更新/绘制通知。
**3.0.40 本机实测 HP、Aggro、战备轮盘可用，弹道 HUD 跟手但轻微重影；高占用反馈未在相同条件复现，不能宣称已解决全部兼容性问题。**

Watchdog 会把 Smooth 写入门后执行的部分工作归入 Smooth。ms/s 是每秒累计，
worst 是最慢单帧；“游戏”这一行测的是更新回调，不是完整游戏 CPU/GPU 负载。
Super Earth 6.2.1 的当前实机日志显示第 388 帧进入 ready、31/31 被动找到，
re-applied=0、refused=0；启动扫描阶段开销较高本身不是故障。

Development candidate **3.0.40** removes per-frame result-table/heartbeat-closure
allocation from common dispatch, preserves exact return arity (including nil),
and keeps writer-cycle/error policies and downstream profiler probes intact.
Frame-critical callback discovery now covers the four reported HUD/input mods,
late-loaded heads and deep update buses. Their enclosing chain is neither skipped
nor paused. This is conservative whole-chain protection, not selective scheduling.
No foreign files, generic FFI hooks or persistent dynamic-memory caches are changed.

92 regression tests and independent game-library input/fire/UI checks passed;
32 simulated HUD layouts preserve every callback. **Live drawing/function/cost
acceptance remains pending.** Watchdog can charge writer work behind our gates to
Smooth; its game row is not total engine CPU/GPU work. Super Earth reached ready
at frame 388 with all 31 passives and no refusals/reapplication in the saved log.

以下保留历史候选记录。

当前开发候选 **3.0.37**：继续减少C4常态扫描。已有相同身份且仍被接管的
射击状态维护，省去未被这条路径使用的能力模板诊断扫描；任务、人物、背包、
武器与weapon-data登记表、射击标志及按下状态仍新读并校验。首次接管、身份/
武器/标志变化、未知依赖或读取异常走完整原逻辑；原sync/stop、恢复和投掷/
引爆不替换。私有读取器不会改变其他snapshot消费者。沿用默认关闭的
`c4_context_batch=yes`，关闭、排除、重载可恢复；不改第三方文件或配置。

现代LuaJIT和独立游戏Lua库通过34项对照/故障检查，以及完整模块120对回调、
发现、热关闭、排除和重载检查。合成模板表中，单次已有射击接管读取次数：
1槽80→75，16槽95→75，128槽207→75；收益取决于模板探测长度。
**这些是局部模拟结果，3.0.37尚待实际游戏功能和FPS验收。**

3.0.36已实机确认投掷、引爆、切回主武器的射击/瞄准正常；同进程前台中位
主武器162FPS、C4 148FPS，性能问题仍在。尚未验证焦点和死亡恢复等全部边界。

Development candidate **3.0.37** omits unused diagnostic ability-template scans
only while maintaining an already owned, identical MUTED fire lease. Mission,
avatar, inventory, weapon/weapon-data registries, flags, held state and guards
stay fresh. Acquisition, identity/weapon/flag changes, unknown collaborators and
read faults use the complete original path. Original sync/stop, restoration and
actions remain authoritative. The private reader does not alter other snapshot
consumers. Uses default-off `c4_context_batch=yes`; opt-out/exclusion/reload restore.
No third-party files/configuration changes.

Both LuaJIT runtimes passed34 differential/fault checks and120 paired callbacks,
discovery, hot opt-outs, exclusion and reload. Synthetic1/16/128-slot fixtures
reduced owned-fire reads80/95/207 to75. Benefit depends on actual probe length.
**These are local simulations; 3.0.37 needs live functional/FPS acceptance.**
3.0.36 throwing/detonation and primary fire/aim restoration were confirmed by
the user; foreground median162FPS primary vs148FPS C4 remains unresolved.
Focus/death restoration and other boundaries have not yet been accepted.

以下保留历史候选记录。

当前开发候选 **3.0.36**：限制已确认的 C4 1.11 常态输入维护中的重复原生代码
校验。已经接管的瞄准输入只检查本次实际调用的映射/索引函数及跳转表；已接管
开火输入不调用原生函数。每次仍完整读取动态状态、按键、输入掩码和绑定，保留
所有前后回调。建立接管、恢复输入、投掷和引爆仍完整校验。未知源码或依赖变化
保留/恢复原逻辑；沿用默认关闭的 `c4_native_batch=yes`。不修改其他模组文件或配置。

现代 LuaJIT 和独立游戏 Lua 库通过45项故障/动态状态对照，以及完整模块120次
前后回调、双输入门发现、重载和热关闭检查。85个保护字段的合成夹具中，两次
已接管输入维护的代码读取从170降到5。**这是局部模拟，不是整套C4成本或实机
FPS收益；3.0.36还需用户在游戏验收。** 用户负责游戏操作，退出后才部署。

3.0.35实机同进程前台记录：主武器中位162FPS，C4中位137FPS；C4读取约1667次/
Lua更新，主武器约316次。此前界面优化未解决掉帧。两轮分别有39.7/44.7秒前台
样本，无法精确分离站立和跑动；看门狗60秒窗口混合后台等待，不能作纯阶段比较。

Development candidate **3.0.36** limits redundant native-code verification in
verified C4 1.11 owned-input maintenance. Owned aim checks fresh mapping/index
code and switch tables; owned fire makes no native call. Dynamic snapshots,
bindings, masks and every before/after callback remain fresh and complete.
Acquisition, input restoration, throwing and detonation retain full verification.
Unknown signatures or changed collaborators retain/restore original logic.
Uses existing default-off `c4_native_batch=yes`; no third-party files/config changes.

Modern LuaJIT and an independent game-library VM passed45 differential/fault
checks plus120 paired callbacks, two-gate discovery, reload and hot opt-outs.
In a synthetic85-guard fixture, two owned-input maintenance calls fell from170
to5 code reads. **This is local simulation, not total C4 cost or in-game FPS.
3.0.36 still needs user gameplay acceptance.** Only deploy after the user exits.

3.0.35 foreground measurements in one process: primary median162FPS vs C4
median137FPS, about316 vs1667 native reads per Lua update. The prior UI change
did not solve the regression. Foreground segments lasted39.7/44.7 seconds;
standing/running boundaries were not recorded. Watchdog60-second windows include
background waiting and are not pure phase comparisons.

以下保留历史候选记录。

当前开发候选 **3.0.35**：参考 Consistent Vaulting 的轻量快照，在已核对的
C4 1.11 界面检查中只读取需要的地图和武器菜单标志。每次仍重新检查任务、
本地角色、登记表、背包、所持 C4 身份和所有已收集保护字段；原生界面栈检查
不变，其他读取与投掷、引爆回调保持完整。沿用默认关闭的 `c4_context_batch=yes`，
关闭、排除或未知源码时恢复/保留原逻辑。不修改其他模组文件或配置。

独立游戏 Lua 库的 128 槽合成夹具中，一次界面检查的原生读取从189降到53；
完整模块120次前后回调、焦点和界面阻挡、身份变化、读取失败及重载恢复检查通过。
**这是局部模拟结果，不是整套 C4 性能或实机帧率收益。尚待游戏功能与FPS验收。**
安装候选版前需要用户退出游戏；游戏操作由用户完成。

Development candidate **3.0.35** applies Consistent Vaulting's light-snapshot
approach to the verified C4 1.11 flags-only UI consumer. Every call still checks
fresh mission/player/avatar/registry/inventory/selected-C4 identity and validates
all collected guards. The complete native UI stack, other context consumers,
throw/detonate callbacks and controls stay intact. Uses the existing default-off
`c4_context_batch=yes` option; opt-out, unknown variants and changed dependencies
restore or retain the original logic. No third-party installed files/configs change.

In an independent game-Lua-library replay with a synthetic 128-slot template
table, one UI check fell from189 to53 native reads. Full-module120 before/after
callbacks, focus/UI gating, identity mutations, read failures and reload restore
passed. **These are local simulation results, not full-C4 or in-game FPS gains.
Live functional/performance acceptance is pending.** Candidate deployment requires
the user to close the game; the user performs game operations.

以下保留历史候选记录。

当前开发候选 **3.0.34**：复用 C4 状态校验中相同地址和长度的读取计划，
减少反复排序和临时分配。缓存最多8种布局，缓存只保存地址、长度和分组，
每次仍读取最新原生字节；完整比较所有字段，保持预算、失败回退、返回快照
的独立生命周期和关闭恢复。沿用默认关闭的 `c4_context_batch=yes` 试验开关。
不修改第三方文件或配置，不跳过 C4 回调或按键/动作。

独立游戏 Lua 库模拟中，固定 C4 布局采集临时分配约减少57%；原生读取次数
不变。具体耗时记录在项目验证目录，**这是模拟结果，不是实机FPS收益；
尚未经过游戏验收，不能宣称C4掉帧已经解决。** 新增 idle 适配在当前实机
配置中已关闭。CPU采样启动/停止会清空JIT编译轨迹，验收必须关闭采样。

Development candidate **3.0.34** reuses immutable address/length read plans for
identical C4 context layouts. At most eight layouts are retained; no captured
bytes, readers, guards or callbacks are cached. Every validation still reads
fresh native data, with complete layout matching, budgets, fallback, independent
snapshot lifetimes and restore preserved. Uses the existing, default-off
`c4_context_batch=yes` experimental option. No third-party file/config changes
or skipped C4 updates, inputs or actions.

In independent game-Lua-library replay, fixed-layout C4 allocation decreased
about 57%, with native read counts unchanged. **These are simulation results,
not game FPS measurements; live validation is pending.** The idle adapter is
off in the current live configuration. Profiling start/stop flush JIT traces;
performance acceptance must run with profiling off.

以下保留历史候选记录。

当前开发候选 **3.0.32**：成功读取原生校验字节时，不再提前格式化失败消息；
真正读取失败时仍返回原有地址和错误内容。保留所有新读取、校验和动作。
沿用默认关闭的 `c4_native_batch=yes`。现代LuaJIT及游戏Lua库对照检查通过，
**尚未部署或实机验证，不能宣称FPS收益或常态开销已解决。**

Development candidate **3.0.32** formats native read failure messages only when
the read fails. Successful reads avoid unnecessary formatting; original failure
addresses, fresh reads, guards and actions remain intact. The existing
`c4_native_batch=yes` option remains off by default. Independent modern and game
Lua-library contract checks pass. **Deployment and live validation remain pending;
no FPS or background-cost improvement has been established.**

以下保留历史候选记录。

当前开发候选 **3.0.31**：C4 按键扫描用每次调用独有的校验数组代替逐字段
临时表，保留每次新读取、原有校验顺序、失败回退和返回结果的独立生命周期。
沿用默认关闭的 `c4_input_batch=yes` 开关，不修改第三方文件或配置。
独立进程中，现代 LuaJIT 的每次扫描分配约从97 KB降到49 KB；游戏自带
Lua库中约从70 KB降到39 KB。**这不是实机FPS收益，尚未部署或游戏验收。**
3.0.30同任务关闭/开启/关闭对照的C4帧率未随开关稳定重复，不能宣称修复。

Development candidate **3.0.31** replaces per-field input guard tables with
invocation-local arrays. Fresh reads, validation order, fallback and independent
returned snapshot lifetimes remain intact. The existing `c4_input_batch=yes`
option remains off by default. Third-party files and configuration are untouched.
Independent allocation tests measured about 97→49 KB per scan with modern LuaJIT
and 70→39 KB with the game's Lua library. **These are not in-game FPS results;
deployment and mission validation remain pending.** The 3.0.30 same-session
OFF/ON/OFF trial did not establish a repeatable FPS benefit.

以下保留历史候选记录。

当前开发候选 **3.0.30**：在已核对的 C4 1.11 原生校验读取中，单块读取
直接返回本次新读出的字符串，省去每次创建临时表和拼接；超过4096字节仍用
原来的分块读取。原字段校验、失败回退、动作及原始上值变化继续保留。
沿用 `c4_native_batch=yes` 试验开关（发布默认no），不修改第三方文件或配置。

3.0.29的任务内CPU采样已发现C4读取/校验热点及垃圾回收。按当前运行游戏中的
真实校验位置构造独立进程测试，500次校验的临时分配约减少90%，耗时约减少11%。
**这是独立测试结果，不是游戏FPS收益。用户仍报告持C4比主武器少约20帧；
3.0.30尚待任务内功能与帧率验收，不能标为稳定版。**

Development candidate **3.0.30** removes per-call temporary tables and concatenation
from verified C4 1.11 single-chunk native guard reads. Every call still reads fresh
bytes; large reads, guards, failures, actions and original upvalue changes retain
their contracts. It uses the existing opt-in `c4_native_batch=yes` setting (default
`no`). Third-party files and configuration are untouched.
An independent owned-memory test using the actual running game's guard topology
reduced temporary allocations by about 90% and elapsed time by about 11% for 500
checks. **These are not in-game FPS results. Mission validation remains pending.**

以下保留历史候选的记录，不能作为当前版本的实机验收。

3.0.27 增加 **默认关闭的上下文校验合并候选**，`c4_context_batch=yes` 启用。
这是针对实机短时采样中反复出现的 ContextReader 校验路径继续做的试验。
只接入已核对完整字节码的原始 snapshot；共享原有布局和辅助函数的上值，
保留其他上下文逻辑、每项保护字段、每次校验的新读取及原生动作。
仅缓存读取范围计划，不缓存游戏数据；大读取失败回退原字段，连失败回退也
保留768次/32768字节预算。稀疏布局或预算不足时按原字段读取。
关闭选项/总开关/排除C4会还原，第三方后来替换的函数不覆盖。

在原始 ContextReader 与测试进程内存的同一夹具中，一次校验从234次原生读取
减少到22次；全部观察字段一致，字段变化拒绝、失败回退、辅助函数共享、
自动发现和关闭还原验证通过，游戏自带Lua库也通过这些独立状态验证。
**没有完成3.0.27任务内FPS及功能验收，仍为候选版，不应作为稳定版发布。**

3.0.27 adds an **opt-in context validation batch candidate**:
`c4_context_batch=yes`. It supports only the verified original snapshot, shares
the original layout/helper upvalues, compares every original guard to fresh data,
and keeps native actions and input policy. Only address plans are retained;
failed larger reads fall back to original fields within the existing read/byte
budgets. Disabling or excluding restores the original method and preserves later
third-party replacements. No third-party installed files are modified.
The original ContextReader fixture fell from 234 to 22 native validation reads,
with mutation/failure/restore tests also passing in the game Lua library's
independent state. **In-game FPS and action validation remain pending.**

以下是3.0.26的实机反馈，不能作为3.0.27验收。

3.0.26 增加 **默认关闭的 C4 按键表分块读取候选**，需使用
`c4_input_batch=yes` 启用。仅接入字节码身份已核对的原始 AimInputState；
其他版本不接入。读取按 12 个表项一块合并，每次校验读取新数据并比较原有的
每个保护字段，大块读取失败时回退到小读取。不跨帧缓存数据，不移除安全校验，
不跳过 C4 更新，不改变原生动作、按键路由或抑制策略。
关闭 Smooth、排除 C4 或关闭此选项会恢复原函数；第三方安装文件不修改。

实机 3.0.25 已观察到瞄准按键扫描/复核占大量读取；离线相同按键表对照
原生调用由 2744 次减少为 171 次。游戏原始 Lua 库、数据突变、失败回退及
自动接入/关闭还原检查通过。2026-10-03 实机日志已确认接入，用户确认
投掷、引爆均正常。诊断关闭后，用户报告 C4 站立与主武器站立均约 162 FPS，
C4 跑动约 150–155，切回游戏时曾短暂约 130 后逐步恢复，仍有波动。
期间发生过死亡/复活，部分开关对照混有状态变化，不能独立归因或承诺固定收益。
**移动时的性能问题未完全解决，仍为候选版。**

3.0.26 adds an **opt-in** C4 binding-table batch reader: `c4_input_batch=yes`.
Only verified original bytecode is supported. Each validation reads fresh data and
compares every original guard; failed larger reads fall back to individual reads.
It keeps actions, input policy and frame callbacks, and restores the original reader
when disabled or excluded. No third-party installed files are modified.
Offline native calls fell from 2744 to 171 for the same fixture; this is not an
in-game FPS result. In-game attachment was confirmed on 2026-10-03, and the
tester confirmed throw and detonate both work. With diagnostics off, reported
standing FPS matched the primary weapon at about 162; moving with C4 was about
150–155, with a temporary drop after refocusing and subsequent recovery.
Death/respawn confounded some comparisons. Moving performance remains unresolved;
this is still a candidate, not a stable release or a guaranteed FPS gain.

The AimInputState contract is adapted from the MIT-licensed
[HD2 C4 Quick Actions](https://github.com/etxp/HD2-C4-Quick-Actions).
Its copyright and permission notice are retained in the runtime source.

以下为 3.0.25 及此前的诊断记录。

3.0.25 为 C4 掉帧诊断候选，尚未解决持有 C4 跑动时的帧率下降。
同一对局关闭 3.0.24 的缓冲复用后，用户仍复现相同现象。
新增 `c4_read_profile=yes` 临时采样，默认关闭；每 509 次读取采样一次调用位置，
只记录调用位置和计数，不记录内存地址或数据，不跳过原读取和安全校验。
诊断可配合 `c4_read_pool=no` 使用原始读取，关闭后恢复读取函数。
采样期间的性能数据需注明诊断开销，不代表发布版的常态开销。

3.0.25 is a diagnostic candidate, not a fix for the FPS drop when moving with C4.
Optional `c4_read_profile=yes` samples callsites every 509 reads; it is off by default.
Reads, validation and callbacks are preserved. No addresses or memory contents are logged.
Use `c4_read_pool=no` to probe the original reader; disabling both restores it.

以下保留 3.0.24 及此前候选的记录。

开发候选：**3.0.24，试验 C4 1.11 的原生读取缓冲复用；实际游戏功能与整体收益仍待用户验收。**
Development candidate: **3.0.24 trials native read-buffer reuse for C4 1.11. In-game C4 behavior and overall performance gains await validation.**

3.0.22实机日志显示没有匹配到读取函数，优化没有启用。原因是游戏自带LuaJIT
2.1 alpha与离线测试所用新版LuaJIT的字节码指纹不同。3.0.23已在游戏原始
lua51.dll的独立测试状态中复现并修正；该测试没有访问游戏进程，任务内收益待复测。
3.0.23实机仍未启用：实际加载路径带.lua后缀，识别没有接受。
3.0.24修正路径形式，并使用实际路径和游戏原始Lua库重跑检查。

Smooth在运行时识别已核对的C4读取函数，仅为这项读取分配一次私有缓冲。
每次仍调用ReadProcessMemory读取最新数据，保留地址/长度校验及失败返回。
没有缓存游戏数据、移除C4校验、跳过C4更新或改变按键注册；不修改第三方安装文件。
无法匹配原始读取函数时不启用适配。手动排除C4或关闭Smooth会恢复原始读取函数。

Windows原生读取对照确认1000次读取的缓冲分配从2000次减少到2次；
9项读取回归及6种开启/关闭、加载顺序/MDL模拟配置通过。
这些是离线原生接口与回调测试，不能当成游戏投掷、引爆、Contact模式验收，
也不能把读取层的收益当成整体帧率收益。既有回调、FFI、工具和排除规则检查通过。

测试包：`dist/HD2-SmoothBoot-3.0.24-candidate.zip`。默认开启本次试验；
在运行配置目录的`config.txt`加入`c4_read_pool=no`，可关闭并重启做对照。
同一任务、同一位置、持有C4未投掷时各观察完整60秒窗口，结合更新频率比较开销。
再检查单个/多个C4投掷引爆、切枪后的原版输入，以及已使用模式的炸药行为。

下面保留3.0.21的兼容修复及历史证据。

评论明确说明 RatInPlat 的 Armor Transmog 正常；问题是同时使用 LTE Helmet and Cape
Passives 时不能创建自定义头盔/披风变体，已有被动仍存在。因此本次只新增
`lte/helmet_cape_passives`，没有新增 Armor Transmog 排除项。
不能可靠自动判断第三方功能是否被破坏，按用户要求移除整个弹窗及其输入/绘制逻辑。
没有启用新的自动分类或分别调度；用户仍可通过名单排除托管。

旧配置首次升级会保留已有内容并合并 LTE 排除项；升级标记生成后，用户可以手动移除，
后续启动不会反复加回。排除对象若在托管链内部，旧调度器保守地让整段链全速运行，
避免被跳帧、启动暂停或熔断。这可能减少该链的优化收益，不代表各模组已分别调度。

新增4项排除/无弹窗回归、8项FFI检查、6项运行工具检查通过，sb2/sb3/sb5及
性能/defaults检查通过。实机验证范围和证据见项目交接文档；未安装评论中的完整组合，
不能称已验证“创建变体”恢复，也不能称所有第三方功能兼容。

上一候选安装包：`dist/HD2-SmoothBoot-3.0.21-candidate.zip`。
日志收集器的 E 选项可合并精确模组标识到 `exclude=`；已有名单保留。
此版不承诺任意第三方组合的兼容性或每帧0.05ms开销。

以下是保留的前期性能修复与历史验证记录。

3.0.12 保留看门狗在 writer gate 周围安装的计时代理，并让放行后的 writer
经过同一个下游代理。3.0.3 也存在这个问题：维护会拆除代理，放行会绕过下游
计时，导致部分模组的读数不再更新。真实源码回归验证维护及放行后代理继续
每帧运行，下游回调和返回值保持完整；新回归在旧实现上失败，在修复后通过。

真实游戏中 Quasar、尸体清理和车辆冷却的异常排名已消退；这不代表其所有功能
已经验收，也不能用计时修复解释全部掉帧。用户提供的 3.0.3 与物理移除 Smooth
的任务测试仍出现 60 FPS。随后管理器停用护甲并重新部署，部署环境发生变化，
该轮不能混入上述严格对照。看门狗和 P2P HUD 已实机确认恢复，护甲保持停用。

运行游戏后，日志收集器自动生成在
`%LOCALAPPDATA%\CowboyBingus\Helldivers2\SmoothBoot\Collect-Logs.bat`。
这是运行配置目录，不是管理器安装目录。关闭游戏后双击，输入 C，日志 ZIP 会出现在桌面。
3.0.11 补收看门狗日志及 MDL 配置；安装包仍不包含独立 BAT 文件。

3.0.10 的深度快照默认关闭修复保持有效（只有 `snapshot=yes` 才开启）。
3.0.11 修正接管新链时漏掉下游首帧的问题，并验证多次接管不会重复执行回调。
相关十二项测试、sb2、sb5、LuaJIT/FFI 审计通过；模拟测试不能代替游戏完整功能验证。

历史3.0.12 本地候选包在 `dist/HD2-SmoothBoot-3.0.12-candidate.zip`，未上传。
历史 3.0.3 可直接导入管理器的 ZIP 在本地 `dist/HD2-SmoothBoot-3.0.3-dev.zip`，线上在
[测试 Release](https://github.com/YC426/HD2-SmoothBoot/releases/tag/v3.0.3-dev.20261002)。
不要将 GitHub 自动生成的 Source code ZIP 当作模组安装包。

用于调节 Lua 模组初始化和运行调度。后续重点是 C4 快速投掷/引爆、尸体自动清理、
舰船与任务初始化速度，以及常态开销。当前不能宣称这些问题已修复或全部功能兼容。
看门狗重复 hook 计时与自身日志不同，需要真实游戏对照数据解释。

## Local validation / 本地检查

```powershell
python -m pip install -r requirements-dev.txt
python -B work/standalone/build_sb.py --validate-only
python -B work/standalone/test_sb2.py
python -B work/standalone/test_sb3_autopause.py
python -B work/standalone/test_sb5_interdict.py
```

编译审计使用游戏所用的 LuaJIT，拒绝全局 user32 FFI 声明冲突；模拟测试不证明实机
功能。`test_sb6_ffi.py` 是 Windows 集成检查，需要本地已安装的 Clickable Scrollbars
接口作为只读参考；未将第三方模组源码上传。

本次检查：编译/FFI 审计及 sb2、sb3、sb5 通过。保留的旧测试
`test_smoothboot.py` 有 6 项失败（旧节流/错误包裹预期），
`test_sb4_writerhold.py` 要求 2.17.1，遇到本快照 3.0.3 时失败。
这些结果不能认作已通过；后续性能与行为诊断需结合实际游戏重新核对预期。

## Packaging / 构建安装包

先按 THIRD_PARTY_NOTICES.md 提供外部封装工具，再运行
`python -B work/standalone/build_sb.py`。构建不会部署游戏文件。
本快照新增构建工具的 `--validate-only` 入口，运行期 Lua 源码与原工作区逐字节一致。

本仓库具有独立 `.git` 和提交历史。原综合工作区保存实机证据、历史包和第三方只读
参考。后续开发应在本仓库提交；两处不自动同步，部署前须核对源码差异。
# 3.0.28 performance candidate

Adds an optional `c4_native_batch=yes/no` setting (default `no`) for the verified
C4 1.11 native-code verification function. Each verification reads fresh code
bytes and compares every original guard in its original order. Adjacent guards
on the same page can share one bounded read; failures fall back to the original
field reads and errors. Unknown versions and later third-party replacements are
left intact. Turning the option or Smooth off restores the original verifier.

Independent owned-memory tests and the game's Lua library checks pass; this
candidate has not yet been validated in a running mission. No C4 files or C4
configuration files are modified. Existing input/context candidates retain their
own settings and defaults.
# 3.0.29 diagnostic candidate

Adds `c4_cpu_profile=yes/no` (default `no`) for a single 45-second Lua VM stack
sample. Reports sampled VM states (including garbage collection) and bounded
stack counts to the local Smooth log. It samples all Lua VM work, so the report
must be read by stack rather than assigning everything to C4. Diagnostic FPS is
not acceptance FPS. Automatic expiry and option/global disable stop sampling;
turn the option off before requesting another run. C4 actions and the existing
optimizations remain unchanged.

CPU sampler controls and real samples were checked in an independent state using
the game's Lua library. Mission data is still needed. No third-party mod files
or configuration files are modified.

# 3.0.33 idle read candidate / 空闲读取候选

`c4_idle_batch=yes` optionally removes the read-only auto-reload snapshot from
C4 1.11's suspended path when passenger reload recovery has no pending state.
Cancellation and state reset still run. Pending recovery and changed collaborators
use the original path. Exact function fingerprints restrict the adapter to supported
implementations; option/global disable and exclusions restore the original method.
The default is `no`. It does not throttle the entire C4 callback, cache native data
across frames, or modify C4 files. Active C4 action reads remain unchanged.

开启 `c4_idle_batch=yes` 后，仅在没有待恢复状态时省去挂起自动装填的冗余采集；
取消、重置以及待恢复处理保留。默认关闭，可热关闭或通过排除名单恢复原实现。
这是候选版本，主要针对未持 C4 时的两次读取，不能据此声称持 C4 掉帧已解决。

Original AutoReload/PassengerReloadRecovery replay, function/state replacement,
hot disable/discovery and full Smooth callback checks passed in independent modern
LuaJIT and game Lua DLL states. The private reproduction and game evidence are kept
in the parent workspace. Actual 3.0.33 mission performance/actions are pending.

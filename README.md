# HD2 SmoothBoot

3.0.26 增加 **默认关闭的 C4 按键表分块读取候选**，需使用
`c4_input_batch=yes` 启用。仅接入字节码身份已核对的原始 AimInputState；
其他版本不接入。读取按 12 个表项一块合并，每次校验读取新数据并比较原有的
每个保护字段，大块读取失败时回退到小读取。不跨帧缓存数据，不移除安全校验，
不跳过 C4 更新，不改变原生动作、按键路由或抑制策略。
关闭 Smooth、排除 C4 或关闭此选项会恢复原函数；第三方安装文件不修改。

实机 3.0.25 已观察到瞄准按键扫描/复核占大量读取；离线相同按键表对照
原生调用由 2744 次减少为 171 次。游戏原始 Lua 库、数据突变、失败回退及
自动接入/关闭还原检查通过。**实机帧率和 C4 功能仍待验证，不标为稳定版。**

3.0.26 adds an **opt-in** C4 binding-table batch reader: `c4_input_batch=yes`.
Only verified original bytecode is supported. Each validation reads fresh data and
compares every original guard; failed larger reads fall back to individual reads.
It keeps actions, input policy and frame callbacks, and restores the original reader
when disabled or excluded. No third-party installed files are modified.
Offline native calls fell from 2744 to 171 for the same fixture; this is not an
in-game FPS result. In-game performance and C4 actions await validation.

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

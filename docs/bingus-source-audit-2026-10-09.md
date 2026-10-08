# SmoothBoot 源码复查与 BSL 对照（2026-10-09）

结论：作者明确报告了亲测内存泄漏及游戏崩溃，这应当作为尚未解决的实际缺陷报告。
本轮修复了五项可独立复现的源码问题，取消新安装默认的全局 GC 调参，产出
**3.0.50 候选包**。这些结果不能证明作者报告的实机泄漏或随机崩溃已经解决。
本轮没有操作游戏、附加进程、安装候选包或发布文件，没有修改第三方模组及其配置。

## 反馈与参考版本

用户提供了 CowboyBingus 的两条原文：一条拒绝合入 SmoothBoot，并提到 memory
overflow；另一条说明自己测试发现 memory leak，会导致游戏内崩溃。
[BSL 评论页](https://www.nexusmods.com/helldivers2/mods/16292?tab=posts) 的搜索缓存也
包含后一条回复。网页缓存时间与用户抄录时间相差八小时，不据此推断版本。
可见内容没有给出被测 SmoothBoot 的准确版本、内存曲线或源码定位，不能替作者
指定为 3.0.3、3.0.45 或当前候选，也不能将 overflow 擅自解释为已确认的栈溢出。

BSL 对照固定在公开仓库提交
`68b9d05fd8e49ba3fb07e7e669ea46d350e9df8f`，入口标记为 `loader-v19`：

- [shared_loader.lua](https://github.com/CowboyBingus/BingusSharedLoader/blob/68b9d05fd8e49ba3fb07e7e669ea46d350e9df8f/src/shared_loader.lua)：私有 Windows 符号、安全异常文本、启动回调生命周期。
- [jit_budget.lua](https://github.com/CowboyBingus/BingusSharedLoader/blob/68b9d05fd8e49ba3fb07e7e669ea46d350e9df8f/src/jit_budget.lua)：共享 JIT 缓存和 trace watcher。
- [AUTHORING.md](https://github.com/CowboyBingus/BingusSharedLoader/blob/68b9d05fd8e49ba3fb07e7e669ea46d350e9df8f/docs/AUTHORING.md)：模组命名及共享状态约束。

参考源码只复制到自己的审计输出目录。用户提供的 v19 ZIP SHA256 为
`d96ad112f74bd0e360dca9b41abade5377e8cb37ed784ffc8cf07ccc1d9d1ca8`。
公开源码与用户包均有 v19 标记，但没有声称本轮重新构建并逐字节证明两者相等。

## 已复现并修复的五项问题

| 问题 | 修复 | 验证 |
|---|---|---|
| `exclude=alpha_beta` 被分成 `alpha` 和 `beta`，错误排除无关模组 | 解析片段保留下划线，保持原来的大小写归一及子串匹配约定 | 同时安装三个模拟回调，只排除 `alpha_beta` |
| 开局暂停期间同一个全局名换成新表，新表被暂停后漏记恢复 | 恢复记录按表身份和字段保存，不按全局名去重；恢复后清空引用 | 原表、新表均恢复；删除外部引用后两表均被回收 |
| 文档里的 `reentry_max` 没进入配置解析，修改无效 | 加入默认、模板和读取；上限约束为整数 1..16 | 测试 1、5、99、0、1.9；恢复后返回值个数及末尾 nil 保持 |
| 普通名 Windows FFI 声明受其他模组先声明的类型影响 | 参考 BSL 使用 `smoothboot_* __asm__` 私有别名，不覆盖外部声明 | 私有 VM 先声明不兼容原型后仍能创建配置和工具；外部原型不变 |
| 回调已经被 pcall 捕获，但异常对象的 `__tostring` 再抛错可逃出保护 | 文本转换另加 pcall，失败使用固定说明，压平换行 | 开启托管时重复异常不逃出；原有直通路径仍抛出原始异常对象 |

测试：`work/standalone/test_config_state_identity.py`。每项均在现代 LuaJIT 和
**独立加载游戏 Lua DLL 的私有 Lua 状态**运行，修复前失败、修复后通过。
FFI 冲突测试利用 Lua 类型检查拒绝参数，未通过错误 ABI 调用原生函数。

3.0.49 已完成的开局恢复引用清理和 C4 专用代码移除继续保留。
本轮没有恢复 C4 读取池、原生批处理、专用调度或诊断。

## GC 风险与自然回收测试

旧默认 `gc_pause=400` 调整的是所有模组共享的 GC，而非 SmoothBoot 私有内存。
它会推迟回收，不能视为无条件性能优化。新安装默认改为 `gc_pause=0`、
`gc_stepmul=0`，即不调用对应 setpause/setstepmul，不改变当前引擎/加载器策略。
已有显式 400 不自动覆盖；用户本机已经是 0/0，本轮没有改动该配置。
此处 0 不代表运行中撤销之前已经执行的 GC 调参，升级仍需要重启。

此前强制 GC 后的稳定堆测试只证明一部分引用可回收，覆盖不了自然回收时的峰值。
补测对 3.0.3、3.0.49、3.0.50 分别执行两个引擎、两种 GC 设置，共 12 组：

- 每组 120,000 次模拟 update，自然 GC，不在工作循环强制回收。
- 之后创建并替换 4,096 个同源回调闭包，每个捕获约 4–16 KiB 字符串。
- 弱引用观察被丢弃闭包；结束后才执行完整 GC，用于检查引用是否仍存活。
- 在私有 VM 中运行未修改的 BSL `jit_budget.lua`，检查共享 watcher 未被替换。
- 不执行 BSL 游戏启动入口或游戏扫描；旧 3.0.3 语言扫描用缓存禁用。

最终 3.0.50 的结果（KiB，采样峰值并非每次分配的绝对峰值）：

| 私有运行时 | gc_pause | 自然回收期间采样峰值 | 最终完整 GC 后 |
|---|---:|---:|---:|
| 现代 LuaJIT | 0 | 828.43 | 305.44 |
| 现代 LuaJIT | 400 | 1,496.84 | 286.91 |
| 游戏 Lua DLL | 0 | 487.64 | 178.27 |
| 游戏 Lua DLL | 400 | 952.49 | 181.48 |

所有组最后保留一个替换闭包：它是仍被通用链采纳的活动回调，另外 4,095 个已回收。
这组模型未观察到随替换次数持续增长的强引用残留。所有组 BSL watcher 保持，
未触发 JIT flush，测试初始缓存预算 65,536 KiB / 8,000 traces 保持。
这些数值不代表实际游戏进程内存、原生堆、多人任务或其他模组的真实状态规模。

## 仍未解决的边界

1. **未复现作者的实际泄漏。** 缺少其版本与触发过程；不能以本轮模型通过来否定作者亲测。
2. BSL 的 `after_startup` 表示 Lua 模组入口已执行，并在首次游戏 update 前运行；
   它不是游戏原生资源就绪通知。当前 SmoothBoot 写入托管仍依赖时间和帧间隔，
   不能证明延迟后任意第三方原生写入就安全，也不能承诺消除随机崩溃。
3. SmoothBoot 会修改调用链 upvalue，开局还会识别并设置部分模组 stop 字段；
   BSL 不为这些启发式行为提供通用协议。排除项和 HUD 识别减少部分风险，但不构成万能兼容保证。
4. 活动链、托管 writer 及其 downstream 必须保持强引用；本轮没有擅自弱化它们。
   统计中的源名称计数也不是任意动态名称下的硬容量有界容器，本轮压力使用同源替换，
   不覆盖无限生成不同资源名的第三方行为。
5. 包内候选继承工作区 3.0.47/3.0.48 修改，并非已经实机验收的 3.0.45 回退版。
   多局、长期堆增长、runtime/scanner 和全部现有模组组合仍没有新的实机验收。

不能标为“已解决内存泄漏”的正式版，也不需要用户现在再重复无目标的测试。
后续若做实机定位，应先固定同一模组集与场景，用有/无 SmoothBoot 的独立进程比较
自然 Lua 堆和进程内存随时间的变化，再依据增长类别收窄引用或原生分配路径。

## 验证、包与证据

- 63 项 unittest 通过；其中模块导入还执行 8 项 FFI 检查，均通过。
- `test_sb3_autopause.py` 与 `test_sb5_interdict.py` 通过；真实配置/日志污染检查未发现变化。
- 古老的 `test_sb4_writerhold.py` 是 2.17 版测试，调用早已移除的 `wh_release`；
  在本轮修改前的 3.0.48 也失败，保留记录，不列入通过项，不为它恢复废弃运行接口。
- LuaJIT 编译通过；私有别名仍可被构建检查识别；未声明 user32 符号。
- ZIP CRC、单资源、GUID、内嵌源码完全一致检查通过，无散装 BAT/CMD/PS1/EXE。

候选：`outputs/bingus-audit-2026-10-09/candidate/HD2-SmoothBoot-3.0.50.zip`

ZIP SHA256：`fb7fcfaeba20cea6e936e0beab52ee865852fd99a2371f9fd10061ed3c87e6d3`

UTF-8/LF 源码 SHA256：`9b1e501ab9f583328ff6aea76ee58a5b6a805f12c833b330e3b947a5457d985b`

审计目录：`outputs/bingus-audit-2026-10-09/`，包含 `before.txt`、
`native-before.txt`、`error-before.txt`、`gc-default-before.txt`、`suite-final.txt`、
`autopause-final.txt`、`interdict-final.txt`、`natural-gc.json`、`natural-gc-run.txt`、
`run_natural_gc.py`、固定提交参考源码、`build-final.txt` 及 `package-verification.json`。

复查命令（仓库根目录）：

```powershell
C:\Python314\python.exe -m unittest discover -s work/standalone -p test_*.py -v
C:\Python314\python.exe work/standalone/test_sb3_autopause.py
C:\Python314\python.exe work/standalone/test_sb5_interdict.py
C:\Python314\python.exe outputs/bingus-audit-2026-10-09/run_natural_gc.py
C:\Python314\python.exe work/standalone/build_sb.py --output-dir outputs/bingus-audit-2026-10-09/candidate
C:\Python314\python.exe outputs/bingus-audit-2026-10-09/verify_candidate.py
```

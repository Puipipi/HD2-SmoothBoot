# SmoothBoot 3.0.49 — candidate / 候选版

Removed all C4-specific runtime adapters: pooled reads, input/context/native
batching, scoped guards, discovery and CPU/read diagnostics. C4 remains an
ordinary callback on the shared chain. No third-party mod files were changed.
Legacy `c4_*` keys are ignored, preserving existing configuration.

Boot-pause restoration now clears its saved foreign-state references. An isolated
weak-reference test reproduced retention before this fix and collection afterward.
This does not establish the cause of the reported game memory leak or crashes.

The candidate retains the working tree's existing 3.0.47/3.0.48 changes. It is not
a return to the previously accepted 3.0.45 runtime. 57 automated tests pass;
LuaJIT compilation and isolated states using the game's Lua DLL also pass.
There is no new live gameplay, FPS or long-session memory acceptance.

Restart the game when upgrading. Replacing files cannot undo adapters already
installed in a running Lua state. The package has not been deployed or published.

删除 C4 专用读取池、输入/上下文/原生分块、作用域适配、自动发现及诊断。
C4 仍作为普通回调参与通用调用链托管；没有修改第三方模组文件。
旧 `c4_*` 配置保留但不再生效。

修复开局暂停恢复后仍引用外部旧状态的问题。隔离测试可复现并验证该引用被释放，
但不足以证明它就是反馈者内存上涨或游戏崩溃的原因。

保留工作区原有 3.0.47/3.0.48 修改，并非回退至已验收的 3.0.45。
57 项自动测试及 LuaJIT 编译通过，实机功能、帧率与长期内存仍待验收。
升级需重启游戏；安装文件替换无法撤销当前进程中已经安装的适配。
本候选包尚未部署或发布。

# 3.0.46 — development candidate / 开发候选

The original-chain pass-through could redispatch through SmoothBoot indefinitely.
It now permits one legitimate adopted-chain pass-through and stops a further
re-entry, before profiling or discovery. Its guard resets after success and
failure; exact argument, error-object and result arity semantics are retained.
The first detected cycle is logged, and `HD2SmoothBoot.reentry_cycles` counts
subsequent detections without per-frame logging.

原链直通路径可能通过 SmoothBoot 再次派发并无限递归。现在保留一次正常接回
原链的转发，并在再次重入时中止循环；成功和异常都会复位保护，保留参数、
异常对象及返回值数量。首次循环写日志，后续只累计计数，避免逐帧刷日志。

HD2Runtime 0.28.1's original scheduler was copied read-only from its installed
archive and replayed with synthetic watches under modern and game LuaJIT. Both
load orders and Smooth enabled/disabled preserve tick counts, elapsed dt,
cancellation, reattachment and trailing nil results. This covers dispatch only:
native adapters, actual gameplay and the reported performance conflict remain
unverified. No Runtime or other third-party files are changed.

使用安装包中的 HD2Runtime 0.28.1 原始调度器做离线回放，两种加载顺序、Smooth
启用/关闭均保留回调次数、dt、取消、重新挂载及末尾 nil。它只验证派发关系，
不证明原生适配、游戏功能或反馈的性能问题已经解决。没有修改 Runtime 或其他
第三方文件。

The 2026-10-05 02:22:54 crash is an access violation in `ntdll.dll+0x39463`.
The current accessible evidence does not identify the originating Lua mod;
the recursive-path repro is not proof that this specific crash was recursion.
Live acceptance is required before treating this candidate as stable.

2026-10-05 02:22:54 的崩溃是 `ntdll.dll+0x39463` 访问违规。当前可读证据无法定位
起因模组；递归漏洞的复现不能直接证明这次崩溃也是递归。实机验收前请视为候选。

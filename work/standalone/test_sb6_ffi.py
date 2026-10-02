# -*- coding: utf-8 -*-
"""SmoothBoot 3.0.3 - FFI-namespace regression suite (Nexus report 2026-10-01).

Reported symptom
    "I installed this mod and it seems to cause the Clickable Scrollbars part
     of the Vanilla+ mod to cease functioning. With the mod off it works."
Game log (ClickableScrollbars.log, run of 2026-10-01 12:06):
    v2.14
    status=disabled: GetCursorPos: bad argument #1 to '?'
                     (cannot convert 'struct 1684 [1]' to 'int *')

Root cause (proven in scenario 1)
    LuaJIT's C namespace is PROCESS-GLOBAL. `ffi.cdef` SILENTLY IGNORES a
    re-declaration of a symbol that is already declared - the first
    declaration wins and every later caller is type-checked against it, so a
    pcall around ffi.cdef cannot even detect it. SmoothBoot 2.x/3.0.x declared
        int GetCursorPos(int32_t *pt);
        int GetClientRect(void *win, int32_t *rc);
    from its HUD cursor sampler. SmoothBoot loads before Clickable Scrollbars
    in the Bingus chain, so Clickable Scrollbars 2.14's own
        int GetCursorPos(HD2CS_POINT *point);
        int GetClientRect(void *window, HD2CS_RECT *rect);
    were dropped. Its first calibration call then died with a type error and
    the mod disabled itself for the whole session.
    (LuaJIT prints an anonymous struct by its C type id, so the size-looking
     "struct 1684" is really HD2CS_POINT.)

Fix under test
    SmoothBoot declares NO user32 symbol any more: it resolves the addresses
    through kernel32 (GetModuleHandleA + GetProcAddress) and ffi.cast()s each
    one to the prototype it actually calls. Only GetModuleHandleA and
    GetProcAddress stay in the namespace, and every mod in the ecosystem
    declares those compatibly.

Scenarios
  0  the sandbox really runs LuaJIT with a working FFI (guards the blind spot
     that let this ship: the older suites run plain Lua 5.1, where
     require('ffi') fails, sampling_ok stays false and the sampler is inert)
  1  BUG REPRODUCTION: the 3.0.2 declaration order breaks Clickable Scrollbars
  2  FIX, real chain order: smoothboot.lua loads first, then the real
     Clickable Scrollbars cdef - all of its calibration calls succeed
  3  FIX, reversed order: Clickable Scrollbars first, then smoothboot.lua -
     SmoothBoot still loads and its own sampler is bound
  4  static: no user32 symbol in any ffi.cdef block of the shipped source
  5  the shipped source compiles under LuaJIT (65535-instruction-per-function
     limit - the failure mode that silently killed another mod on this game)
  6  the window APIs the HUD needs are really resolvable at runtime through
     the new GetProcAddress path
"""
import os
import re
import sys

import lupa.luajit21 as luajit

W = os.path.dirname(os.path.abspath(__file__))
SRC = open(os.path.join(W, "smoothboot.lua"), encoding="utf-8").read()
VER = re.search(r"version='([\d.]+)'", SRC).group(1)
SANDBOX = "SB603FFI"


def sandboxed(src=None):
    """Redirect the mod's HOME so the sandbox never touches the live config."""
    return (src or SRC).replace("'/CowboyBingus/Helldivers2/'",
                                "'/%s/Helldivers2/'" % SANDBOX)


def find_clickable_cdef():
    """Pull the verbatim cdef block out of the deployed Clickable Scrollbars."""
    candidates = []
    gd = r"D:\Program Files (x86)\Steam\steamapps\common\Helldivers 2\data"
    if os.path.isdir(gd):
        for n in os.listdir(gd):
            if n.startswith("9ba626afa44a3aa3.patch_") and not n.endswith(
                    (".stream", ".gpu_resources")):
                candidates.append(os.path.join(gd, n))
    candidates.append(os.path.join(
        os.path.dirname(os.path.dirname(W)), "work", "lua",
        "Clickable-Scrollbars-v2.14_AR912481__p.patch_0.lua"))
    for p in candidates:
        try:
            txt = open(p, "rb").read().decode("utf-8", "replace")
        except OSError:
            continue
        if "HD2CS_POINT" not in txt or "ffi.cdef [[" not in txt:
            continue
        i = txt.index("ffi.cdef [[")
        j = txt.index("]]", i)
        return txt[i + len("ffi.cdef [["):j], p
    raise AssertionError("Clickable Scrollbars cdef not found")


CS_CDEF, CS_PATH = find_clickable_cdef()
assert "HD2CS_POINT" in CS_CDEF and "int GetClientRect" in CS_CDEF

# the declarations SmoothBoot 3.0.2 shipped (the ones that did the damage)
OLD_SB_CDEF = r'''
        void *GetForegroundWindow(void);
        unsigned long GetWindowThreadProcessId(void *win, void *pid);
        int GetCursorPos(int32_t *pt);
        int ScreenToClient(void *win, int32_t *pt);
        int GetClientRect(void *win, int32_t *rc);
        int16_t GetAsyncKeyState(int key);
        unsigned long GetCurrentProcessId(void);
'''

# runs a chunk for real (loadstring alone only compiles it)
RUN = r'''
local function run(src, cname)
    local fn, lerr = loadstring(src, cname)
    if not fn then return 'compile: ' .. tostring(lerr) end
    local ok, rerr = pcall(fn)
    if not ok then return 'runtime: ' .. tostring(rerr) end
    return nil
end
local function run_named(gname, cname) return run(_G[gname], cname) end
'''

# the mod refuses to touch anything without the Bingus loader, so the sandbox
# has to look like a Bingus session
CHAIN_HEAD = r'''
local game = 0
function update() game = game + 1 end
_G.CowboyBingusModLoader = { api = 1 }
'''

# what Clickable Scrollbars 2.14 does in create_platform(): same cdef (fed in
# through the global `csrc`) and the same startup calibration calls
CS_PROBE = r'''
local ffi = require('ffi')
ffi.cdef(csrc)
local user32, k32 = ffi.load('user32'), ffi.load('kernel32')
local point, rect = ffi.new('HD2CS_POINT[1]'), ffi.new('HD2CS_RECT[1]')
local function check(name, fn)
    local ok, value = pcall(fn)
    if not ok then return name .. ': ' .. tostring(value) end
    return nil
end
local errs = {}
errs[#errs+1] = check('GetTickCount64', function() return k32.GetTickCount64() end)
errs[#errs+1] = check('GetCurrentProcessId', function() return k32.GetCurrentProcessId() end)
errs[#errs+1] = check('GetAsyncKeyState', function() return user32.GetAsyncKeyState(0) end)
errs[#errs+1] = check('GetForegroundWindow', function() return user32.GetForegroundWindow() end)
errs[#errs+1] = check('GetSystemMetrics', function() return user32.GetSystemMetrics(0) end)
errs[#errs+1] = check('GetCursorPos', function() return user32.GetCursorPos(point) end)
errs[#errs+1] = check('GetClientRect', function()
    return user32.GetClientRect(user32.GetForegroundWindow(), rect) end)
local out = {}
for _, e in ipairs(errs) do if e then out[#out+1] = e end end
return table.concat(out, ' | ')
'''

results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))
    print("%-58s %s%s" % (name, "PASS" if ok else "FAIL",
                          ("  <- " + detail) if (detail and not ok) else ""))


def runtime():
    return luajit.LuaRuntime(unpack_returned_tuples=True)


# ---------------------------------------------------------------- scenario 0
rt = runtime()
has_ffi = rt.execute("local ok, f = pcall(require, 'ffi') "
                     "return ok and f.abi('64bit') or false")
check("0  sandbox runs LuaJIT/FFI (x64)", has_ffi is True, repr(has_ffi))

# ---------------------------------------------------------------- scenario 1
# BUG REPRODUCTION - old declaration order, verbatim Clickable calls.
rt = runtime()
g = rt.globals()
g["old"] = OLD_SB_CDEF
g["csrc"] = CS_CDEF
err = str(rt.execute(r'''
    local ffi = require('ffi')
    ffi.cdef(old)
''' + CS_PROBE))
check("1  BUG REPRO: 3.0.2 order breaks Clickable Scrollbars",
      "GetCursorPos" in err and "int *" in err,
      "expected a GetCursorPos type error, got: %r" % err[:200])
print("       reproduction message: %s" % err[:150])

# ---------------------------------------------------------------- scenario 2
# FIX, real chain order: SmoothBoot loads first, then Clickable Scrollbars.
rt = runtime()
g = rt.globals()
g["src"] = sandboxed()
g["csrc"] = CS_CDEF
g["ver"] = VER
out = str(rt.execute(CHAIN_HEAD + RUN + r'''
    local e = run(src, '@mods/codex/smoothboot')
    if e then return 'smoothboot ' .. e end
    local M = rawget(_G, 'HD2SmoothBoot')
    if not M or M.version ~= ver then return 'version mismatch' end
    -- tick the chain: the HUD sampler runs inside update() and must not
    -- throw when no stingray/world is present (headless sandbox)
    for i = 1, 20 do
        local ok, err = pcall(_G.update, 1/60)
        if not ok then return 'update threw: ' .. tostring(err) end
    end
''' + CS_PROBE))
check("2  FIX: SmoothBoot first + Clickable Scrollbars OK", out == "",
      "still failing: %s" % out[:200])

# ---------------------------------------------------------------- scenario 3
# FIX, reversed order: Clickable Scrollbars first, then SmoothBoot. The mod
# must not clobber a declaration that is already in the namespace.
rt = runtime()
g = rt.globals()
g["src"] = sandboxed()
g["csrc"] = CS_CDEF
g["ver"] = VER
res = str(rt.execute(CHAIN_HEAD + RUN + r'''
    local ffi = require('ffi')
    ffi.cdef(csrc)
    local e = run(src, '@mods/codex/smoothboot')
    if e then return 'smoothboot ' .. e end
    local M = rawget(_G, 'HD2SmoothBoot')
    if not M then return 'HD2SmoothBoot missing' end
    for i = 1, 20 do
        local ok, err = pcall(_G.update, 1/60)
        if not ok then return 'update threw: ' .. tostring(err) end
    end
    -- Clickable Scrollbars must still be able to call its own declarations
    local user32 = ffi.load('user32')
    local point, rect = ffi.new('HD2CS_POINT[1]'), ffi.new('HD2CS_RECT[1]')
    local ok1 = pcall(function() return user32.GetCursorPos(point) end)
    local ok2 = pcall(function()
        return user32.GetClientRect(user32.GetForegroundWindow(), rect) end)
    if not ok1 then return 'CS GetCursorPos broken after SmoothBoot' end
    if not ok2 then return 'CS GetClientRect broken after SmoothBoot' end
    return M.version
'''))
check("3  FIX: Clickable Scrollbars first + declarations intact",
      res == VER, "got %r" % res)

# ---------------------------------------------------------------- scenario 4
blocks = re.findall(r"ffi\.cdef\s*\[\[(.*?)\]\]", SRC, re.S)
declared = set()
for b in blocks:
    for m in re.finditer(r"([A-Za-z_]\w*)\s*\([^;()]*\)\s*;", b):
        declared.add(m.group(1))
user32_syms = {"GetCursorPos", "GetClientRect", "ScreenToClient",
               "GetForegroundWindow", "GetAsyncKeyState",
               "GetWindowThreadProcessId", "GetCurrentProcessId"}
bad = declared & user32_syms
check("4  static: no user32 symbol declared by the mod", not bad,
      "still declares: %s" % ", ".join(sorted(bad)))
print("       declared symbols: %s" % ", ".join(sorted(declared)))

# ---------------------------------------------------------------- scenario 5
try:
    luajit.LuaRuntime().compile(SRC)
    compiled, detail = True, ""
except Exception as exc:
    compiled, detail = False, str(exc)
check("5  shipped source compiles under LuaJIT", compiled, detail)

# ---------------------------------------------------------------- scenario 6
rt = runtime()
g = rt.globals()
g["src"] = sandboxed()
info = str(rt.execute(CHAIN_HEAD + RUN + r'''
    local e = run(src, '@mods/codex/smoothboot')
    if e then return 'smoothboot ' .. e end
    local ffi = require('ffi')
    local k32 = ffi.load('kernel32')
    local h = k32.GetModuleHandleA('user32.dll')
    if h == nil then return 'no user32 module handle' end
    local missing = {}
    for _, n in ipairs({'GetCursorPos','GetClientRect','ScreenToClient',
                        'GetForegroundWindow','GetAsyncKeyState'}) do
        if k32.GetProcAddress(h, n) == nil then missing[#missing+1] = n end
    end
    if #missing > 0 then return 'missing: ' .. table.concat(missing, ',') end
    return 'all resolvable'
'''))
check("6  HUD window APIs resolvable at runtime", info == "all resolvable", info)

# ---------------------------------------------------------------- scenario 7
# The changed code path itself: drive the real banner so hud_click() runs the
# GetProcAddress-bound sampler against the live Windows APIs.
rt = runtime()
g = rt.globals()
g["src"] = sandboxed()
hud = str(rt.execute(CHAIN_HEAD + RUN + r'''
    -- a deliberately slow mod below us: makes the chain "busy" so the banner
    -- is armed and its button polling (the sampler under test) actually runs
    local slow = [==[
        local prev = update
        update = function(...)
            local t = os.clock()
            while os.clock() - t < 0.02 do end
            return prev(...)
        end
    ]==]
    loadstring(slow, '@mods/fake/slow')()
    -- the CAK stingray recipe, faked: create_screen_gui succeeds so HUD.gui is
    -- set and the later ticks poll the mouse
    local w1, main = {name = 'w1'}, {name = 'main'}
    _G.stingray = {
        Gui = { resolution = function() return 1920, 1080 end,
                rect = function() end },
        Vector3 = function(x, y, z) return {x, y, z} end,
        Vector2 = function(x, y) return {x, y} end,
        Color = function(r, g, b, a) return {r, g, b, a} end,
        World = { create_screen_gui = function() return {} end,
                  destroy_gui = function() end },
        Application = { worlds = function() return {w1, main} end,
                        main_world = function() return main end },
    }
    local e = run(src, '@mods/codex/smoothboot')
    if e then return 'smoothboot ' .. e end
    local M = rawget(_G, 'HD2SmoothBoot')
    for i = 1, 400 do
        local ok, err = pcall(_G.update, 1/60)
        if not ok then return 'update threw: ' .. tostring(err) end
    end
    if not M._hud_draw then
        return 'banner never armed (hud_k=' .. tostring(M._hud_k) .. ')'
    end
    local p = (os.getenv('LOCALAPPDATA') or '.') ..
              '/SB603FFI/Helldivers2/Logs/SmoothBoot.log'
    local fh = io.open(p, 'r')
    local logtxt = fh and fh:read('*a') or ''
    if fh then fh:close() end
    if logtxt:find('hud disabled', 1, true) then return 'hud disabled' end
    return 'armed hud_k=' .. tostring(M._hud_k) .. ' | ' .. tostring(M._hud_draw)
'''))
check("7  live sampler runs (banner armed, mouse polling OK)",
      hud.startswith("armed"), hud[:200])
if hud.startswith("armed"):
    print("       %s" % hud[:170])

# ---------------------------------------------------------------- verdict
failed = [n for n, ok, _ in results if not ok]
print()
print("=" * 72)
print("Clickable Scrollbars cdef source: %s" % CS_PATH)
if failed:
    print("FAILED (%d/%d): %s" % (len(failed), len(results), "; ".join(failed)))
    sys.exit(1)
print("all %d checks passed - SmoothBoot %s leaves the shared user32 "
      "declarations alone" % (len(results), VER))

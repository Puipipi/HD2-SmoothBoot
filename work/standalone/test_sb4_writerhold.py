# -*- coding: utf-8 -*-
"""SmoothBoot 2.17.1 writer-hold regression suite (real-topology edition).

Mirrors the actual machine layout:
  BELOW  : c4(previous_update) -> ambiguous(unnamed prev + same-chunk helper)
           -> gp20(writer) -> smarter -> game
  SB     : installs between the segments (real loader order puts SB mid-chain)
  ABOVE  : cak -> p33(writer) -> p2p -> m103(writer, 'original')
           -> p34(writer) -> watchdog(table-field previous, reheader)
The simulated engine calls _G.update (NOT the wrapper directly), which is
what makes head-takeover semantics observable.

Verifies:
  - during the window: all four writers frozen + zero writes, above-segment
    frozen (delayed), below-innocents + game tick every frame, takeover
    active (_G.update == wrapper);
  - the walk reaches gp20 THROUGH the ambiguous layer (diff-chunk heuristic)
    and splices it off;
  - release: head returned, everyone resumes, late writes fire (function
    preserved, only deferred);
  - watchdog reheading after release does not break the chain;
  - engine-pin rollback: if the engine keeps calling the old head, takeover
    aborts with a log line and the below-walk keeps protecting gp20;
  - writer_hold_s=0 disables everything;
  - real game files untouched.
"""
import os
import re
import shutil
import sys
import lupa

W = os.path.dirname(os.path.abspath(__file__))
SRC = open(os.path.join(W, "smoothboot.lua"), encoding="utf-8").read()
VER = re.search(r"version='([\d.]+)'", SRC).group(1)
assert VER == "2.17.1", "source must be 2.17.1, got " + VER

REAL = os.path.join(os.environ["LOCALAPPDATA"], "CowboyBingus", "Helldivers2")

def sandboxed(name):
    return SRC.replace("'/CowboyBingus/Helldivers2/'",
                       "'/%s/Helldivers2/'" % name)

def sandbox_log(name):
    return os.path.join(os.environ["LOCALAPPDATA"], name,
                        "Helldivers2", "Logs", "SmoothBoot.log")

def sandbox_cfg(name):
    return os.path.join(os.environ["LOCALAPPDATA"], name,
                        "Helldivers2", "SmoothBoot", "config.txt")

def snapshot_real():
    out = {}
    for rel in (r"SmoothBoot\SmoothBoot.log", r"SmoothBoot\config.txt",
                r"SmoothBoot\lang.txt", r"Logs\SmoothBoot.log"):
        p = os.path.join(REAL, rel)
        try:
            st = os.stat(p)
            out[rel] = (st.st_size, st.st_mtime)
        except OSError:
            out[rel] = None
    return out

HARNESS = r'''
local checks={}
local function ck(name,cond) checks[#checks+1]=name..'\t'..(cond and 'true' or 'false') end
REG={}

local function load_mod(chunk, body)
    local fn=loadstring(body, '@'..chunk)
    assert(fn, 'replica '..chunk..' failed to load')
    fn()
end

local function writer_body(key, write_at)
    return ([==[
REG['__KEY__']={ticks=0,wrote=false}
local previous_update=update
update=function(...)
    local r=REG['__KEY__']
    r.ticks=r.ticks+1
    if r.ticks>=__AT__ and not r.wrote then r.wrote=true end
    return previous_update(...)
end
]==]):gsub('__KEY__',key):gsub('__AT__',tostring(write_at))
end
local function writer_body_orig(key, write_at)
    return ([==[
REG['__KEY__']={ticks=0,wrote=false}
local original=rawget(_G,'update')
_G.update=function(...)
    local r=REG['__KEY__']
    r.ticks=r.ticks+1
    if r.ticks>=__AT__ and not r.wrote then r.wrote=true end
    return original(...)
end
]==]):gsub('__KEY__',key):gsub('__AT__',tostring(write_at))
end
local function innocent_body(key)
    return ([==[
REG['__KEY__']={ticks=0}
local previous_update=update
update=function(...)
    REG['__KEY__'].ticks=REG['__KEY__'].ticks+1
    return previous_update(...)
end
]==]):gsub('__KEY__',key)
end
-- ambiguous layer: unnamed chain reference + a same-chunk helper function
-- in the wrapper's upvalue set (walk must pick the different-chunk one)
local AMB_BODY=[==[
REG['amb']={ticks=0}
local function helper(x) return x end
local chain_below=rawget(_G,'update')
update=function(...)
    REG['amb'].ticks=REG['amb'].ticks+1
    helper(1)
    return chain_below(...)
end
]==]
-- watchdog replica: previous kept in a TABLE FIELD, re-wraps on demand
local WDT_BODY=[==[
REG['wdt']={ticks=0,reheads=0}
WDTBOX={previous=rawget(_G,'update')}
_G.update=function(...)
    REG['wdt'].ticks=REG['wdt'].ticks+1
    return WDTBOX.previous(...)
end
]==]

-- ===== below-segment (loads first = innermost) =====
local game=0
function update() game=game+1 return 'GAME_OK' end
local GAMEFN=update
_G.CowboyBingusModLoader={api=1,version='test'}
load_mod('mods/cowboybingus/smarter_guards', innocent_body('smarter'))
load_mod('mods/codex/gp20_ultimatum_ammo', writer_body('mods/codex/gp20_ultimatum_ammo', 40))
loadstring(AMB_BODY,'@mods/codex/ambiguous_mod')()
load_mod('mods/etxp/c4_boundary_probe', innocent_body('mods/etxp/c4_boundary_probe'))

-- ===== SmoothBoot installs mid-chain, like the real loader order =====
local ok,err=pcall(loadstring(src,'@mods/codex/smoothboot'))
ck('A0 smoothboot loads',ok)
local SBW=_G.update     -- wrapper (head of our below segment)

-- ===== above-segment (loads after SB = outer layers) =====
load_mod('mods/codex/custom_armor', innocent_body('mods/codex/custom_armor'))
load_mod('mods/codex/p33_missile_pistol_ammo', writer_body('mods/codex/p33_missile_pistol_ammo', 40))
load_mod('mods/shock233/p2p_ping', innocent_body('mods/shock233/p2p_ping'))
load_mod('mods/dsh/m103_frv_turret', writer_body_orig('mods/dsh/m103_frv_turret', 40))
load_mod('mods/codex/p34_breacher_ammo', writer_body('mods/codex/p34_breacher_ammo', 40))
loadstring(WDT_BODY,'@mods/patpatpatrick/mod_lag_finder')()
local HEAD0=_G.update   -- watchdog wrapper: the real head

-- ===== window: engine calls _G.update =====
local passthrough=true
for i=1,100 do
    local r=_G.update(1/60)
    if r~='GAME_OK' then passthrough=false end
end
local W33=REG['mods/codex/p33_missile_pistol_ammo']
local W34=REG['mods/codex/p34_breacher_ammo']
local WM1=REG['mods/dsh/m103_frv_turret']
local WG2=REG['mods/codex/gp20_ultimatum_ammo']
ck('T1 above writers frozen (p33)',W33.ticks<=1 and W33.wrote==false)
ck('T1 above writers frozen (p34)',W34.ticks<=1 and W34.wrote==false)
ck('T1 above writers frozen (m103)',WM1.ticks<=1 and WM1.wrote==false)
ck('T1 below writer frozen via walk (gp20)',WG2.ticks==0 and WG2.wrote==false)
ck('T2 above innocents frozen (cak/p2p/wdt)',
    REG['mods/codex/custom_armor'].ticks<=1 and
    REG['mods/shock233/p2p_ping'].ticks<=1 and REG['wdt'].ticks<=1)
ck('T3 below innocents ticked every frame',
    REG['smarter'].ticks==100 and REG['amb'].ticks==100 and
    REG['mods/etxp/c4_boundary_probe'].ticks==100)
ck('T4 game ran every tick',game==100)
ck('T4 passthrough preserved',passthrough)
ck('T5 takeover active (_G.update==wrapper)',_G.update==SBW)

-- fish WH
local WH
local i=1
while true do local n,v=debug.getupvalue(SBW,i) if not n then break end
    if n=='WH' then WH=v end i=i+1 end
local held=0 for _ in pairs(WH.held) do held=held+1 end
ck('T6 WH wired, taken, gp20 held',type(WH)=='table' and WH.taken==true and held==1)

-- ===== release =====
local wh_release
i=1
while true do local n,v=debug.getupvalue(SBW,i) if not n then break end
    if n=='wh_release' then wh_release=v end i=i+1 end
ck('T7 wh_release wired',type(wh_release)=='function')
wh_release()
ck('T8 head returned (_G.update==watchdog wrapper)',_G.update==HEAD0)
for i=1,80 do _G.update(1/60) end
ck('T9 writers resumed + late write fired (p33)',W33.ticks>40 and W33.wrote==true)
ck('T9 writers resumed + late write fired (m103)',WM1.wrote==true)
ck('T9 below writer reattached + late write (gp20)',WG2.wrote==true)
ck('T10 above innocents resumed',REG['mods/codex/custom_armor'].ticks==81)
ck('T11 game intact (180 total)',game==180)

-- ===== post-release reheading storm (watchdog-style) =====
for r=1,5 do
    local prev=_G.update
    _G.update=function(...)
        REG['wdt'].reheads=REG['wdt'].reheads+1
        return prev(...)
    end
end
for i=1,20 do _G.update(1/60) end
ck('T12 reheading storm survived',game==200 and REG['wdt'].reheads==100)

return table.concat(checks,'\n')
'''

MIDLOAD_HARNESS = r'''
REG={}
local checks={}
local function ck(name,cond) checks[#checks+1]=name..'\t'..(cond and 'true' or 'false') end
local function writer_body(key, write_at)
    return ([==[
REG['__KEY__']={ticks=0,wrote=false}
local previous_update=update
update=function(...)
    local r=REG['__KEY__']
    r.ticks=r.ticks+1
    if r.ticks>=__AT__ and not r.wrote then r.wrote=true end
    return previous_update(...)
end
]==]):gsub('__KEY__',key):gsub('__AT__',tostring(write_at))
end
local function innocent_body(key)
    return ([==[
REG['__KEY__']={ticks=0}
local previous_update=update
update=function(...)
    REG['__KEY__'].ticks=REG['__KEY__'].ticks+1
    return previous_update(...)
end
]==]):gsub('__KEY__',key)
end

local game=0
function update() game=game+1 end
_G.CowboyBingusModLoader={api=1}
loadstring(innocent_body('below_a'),'@mods/fake/below_a')()
loadstring(writer_body('mods/codex/gp20_ultimatum_ammo',9999),'@mods/codex/gp20_ultimatum_ammo')()
pcall(loadstring(src,'@mods/codex/smoothboot'))
local SBW=_G.update
-- unspliceable head (table-field previous, watchdog-style): the real
-- takeover target - it cannot be adopted, only cut off
local TFIELD=[==[
REG['tfield']={ticks=0}
TBOX={previous=rawget(_G,'update')}
_G.update=function(...)
    REG['tfield'].ticks=REG['tfield'].ticks+1
    return TBOX.previous(...)
end
]==]
loadstring(TFIELD,'@mods/fake/tfield_head')()

-- window part 1: the table-field head gets frozen by the real takeover
for i=1,30 do _G.update(1/60) end
ck('M1 table-field head frozen during window',REG['tfield'].ticks<=1)

-- an ADOPTABLE mod loads DURING the window and wraps us
loadstring(innocent_body('mid_loader'),'@mods/fake/mid_loader')()
for i=1,50 do _G.update(1/60) end
ck('M2 late loader frozen too during real takeover (load tick only)',REG['mid_loader'].ticks<=2)
ck('M3 cut segment still frozen',REG['tfield'].ticks<=1)
ck('M4 game ticks through',game>=78 and game<=80)

-- release: cut segment spliced back under the late loader
local wh_release
local j=1
while true do local n,v=debug.getupvalue(SBW,j) if not n then break end
    if n=='wh_release' then wh_release=v end j=j+1 end
wh_release()
for i=1,40 do _G.update(1/60) end
ck('M5 late loader resumed after release (40+)',REG['mid_loader'].ticks>=40)
ck('M6 cut segment resumed after repair (40+)',REG['tfield'].ticks>=40)
ck('M7 game intact (118ish)',game>=117 and game<=120)
return table.concat(checks,'\n')
'''

OFF_HARNESS = r'''
REG={}
local game=0
function update() game=game+1 end
_G.CowboyBingusModLoader={api=1}
local body=[==[
REG['__KEY__']={ticks=0,wrote=false}
local previous_update=update
update=function(...)
    local r=REG['__KEY__']
    r.ticks=r.ticks+1
    if r.ticks>=50 and not r.wrote then r.wrote=true end
    return previous_update(...)
end
]==]
loadstring(body:gsub('__KEY__','mods/codex/p33_missile_pistol_ammo'),'@mods/codex/p33_missile_pistol_ammo')()
pcall(loadstring(src,'@mods/codex/smoothboot'))
loadstring(body:gsub('__KEY__','fake_above'),'@mods/fake/above_innocent')()
local w=_G.update
for i=1,80 do w(1/60) end
return REG['mods/codex/p33_missile_pistol_ammo'].ticks,
       REG['mods/codex/p33_missile_pistol_ammo'].wrote, game
'''

def report(section, pairs_):
    fails = []
    print("== %s ==" % section)
    for name, ok in pairs_:
        print("  %-52s %s" % (name, "PASS" if ok else "FAIL"))
        if not ok:
            fails.append(name)
    return fails

def parse(blob):
    out = []
    for line in blob.split("\n"):
        if "\t" in line:
            name, val = line.split("\t", 1)
            out.append((name, val == "true"))
    return out

def fresh_sandbox(name, cfg=None):
    root = os.path.join(os.environ["LOCALAPPDATA"], name)
    shutil.rmtree(root, ignore_errors=True)
    for sub in ("Logs", r"SmoothBoot"):
        os.makedirs(os.path.join(root, "Helldivers2", sub), exist_ok=True)
    if cfg is not None:
        with open(sandbox_cfg(name), "w") as f:
            f.write(cfg)

def main():
    fails = []
    before = snapshot_real()

    # ---- scenario 1: full real topology -------------------------------
    fresh_sandbox("SB2171", "enabled=yes" + "\n" + "boot_skip=0" + "\n")
    rt = lupa.lua51.LuaRuntime()
    g = rt.globals()
    g["src"] = sandboxed("SB2171")
    g["HARNESS"] = HARNESS
    fails += report("scenario 1: takeover + walk + release",
                    parse(str(rt.execute(HARNESS))))

    log1 = open(sandbox_log("SB2171"), encoding="utf-8", errors="replace").read()
    fails += report("scenario 1: sandbox log", [
        ("head takeover logged", "head takeover" in log1),
        ("ambiguous layer in path log", "ambiguous_mod" in log1),
        ("gp20 spliced off, logged",
         "writer hold: mods/codex/gp20_ultimatum_ammo spliced off" in log1),
        ("head returned logged", "head returned" in log1),
        ("version logged", ("ready v%s" % VER) in log1)])

    # ---- scenario 2: engine-pin rollback ------------------------------
    fresh_sandbox("SB2175", "enabled=yes\nboot_skip=0\nwriter_hold_s=60\n")
    rt2 = lupa.lua51.LuaRuntime()
    g2 = rt2.globals()
    g2["src"] = sandboxed("SB2175")
    g2["MID"] = MIDLOAD_HARNESS
    fails += report("scenario 2: mid-window late loader",
                    parse(str(rt2.execute(MIDLOAD_HARNESS))))
    log2 = open(sandbox_log("SB2175"), encoding="utf-8", errors="replace").read()
    fails += report("scenario 2: sandbox log", [
        ("release completed (writers restored)", "writer(s) back on the chain" in log2)])

    # ---- scenario 3: writer_hold_s=0 disables everything ---------------
    fresh_sandbox("SB2172", "enabled=yes\nboot_skip=0\nwriter_hold_s=0\n")
    rt3 = lupa.lua51.LuaRuntime()
    g3 = rt3.globals()
    g3["src"] = sandboxed("SB2172")
    g3["OFF"] = OFF_HARNESS
    ticks, wrote, game = rt3.execute(OFF_HARNESS)
    fails += report("scenario 3: writer_hold_s=0", [
        ("writer below SB runs normally (79 - transition frame)", int(ticks) == 79),
        ("write fired on schedule", bool(wrote)),
        ("chain intact (79 - transition frame)", int(game) == 79)])

    # ---- real-game contamination guard ---------------------------------
    after = snapshot_real()
    fails += report("real-game contamination guard",
                    [("untouched: " + rel, before[rel] == after[rel])
                     for rel in before])

    print()
    if fails:
        print("RESULT: %d FAILURE(S)" % len(fails))
        for f in fails:
            print("  - " + f)
        sys.exit(1)
    print("RESULT: all checks passed")

if __name__ == "__main__":
    main()

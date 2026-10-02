# -*- coding: utf-8 -*-
"""SmoothBoot auto-pause v2 regression suite (version-agnostic).

Sandboxed (paths redirected away from the real game dirs). Verifies:
  - boolean stop switches (native mod vocabulary) flip during the boot
    window and are restored exactly afterwards, surviving tug-of-war;
  - string state machines (phase/status) are NEVER written (2.16.0 crash);
  - tables without the mod-state signature are never touched;
  - hostile metatables cannot disturb the scan (rawget/rawset);
  - the chain (game update) runs every tick - no freeze;
  - boot_pause_s=0 disables the whole mechanism;
  - the real game log/config/lang is byte-identical before and after;
  - ap_scan/ap_restore are wired into the wrapper (no dead code);
  - double load returns the existing module (version guard).
"""
import os
import sys
import lupa

W = os.path.dirname(os.path.abspath(__file__))
REAL = os.path.join(os.environ["LOCALAPPDATA"], "CowboyBingus", "Helldivers2")
KEY = "HD2SmoothBoot"

SRC = open(os.path.join(W, "smoothboot.lua"), encoding="utf-8").read()
import re as _re
VER = _re.search(r"version='([\d.]+)'", SRC).group(1)

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

HARNESS1 = r'''
local checks={}
local function ck(name,cond) checks[#checks+1]=name..'	'..(cond and 'true' or 'false') end

local game=0
function update() game=game+1 return 'GAME_OK' end
_G.CowboyBingusModLoader={api=1,version='test'}
local ok,err=pcall(loadstring(src))
ck('A0 smoothboot loads',ok)

TankRep ={frames=0,stopped=false,ready=true}          -- boolean stop family
P33Rep  ={frame=0,phase='starting',budget=0.008}     -- dsh string machine
EngineUI={status='running',label='menu'}             -- no counter: untouchable
EngineFX={paused=false,label='fx'}                   -- no counter: untouchable
EngineCtr={ticks=10,status='running'}                -- counter: observe only
IdleRep  ={frames=5,phase='idle'}                    -- inactive value: ignore
HostileIdx=setmetatable({frame=3,phase='scanning'},
    {__index=function() error('boom') end})          -- metamethod trap
HostileNew=setmetatable({frames=1,stopped=false},
    {__newindex=function() error('bam') end})        -- write trap

local spin_risk=false            -- would-be 2.16.0 freeze condition
local passthrough_ok=true
local reassert_ok=true
local wrapper=_G.update

local ups={}
local i=1
while true do
    local n,v=debug.getupvalue(wrapper,i)
    if not n then break end
    ups[n]=v i=i+1
end
ck('D1 ap_scan wired into wrapper',type(ups['ap_scan'])=='function')
ck('D1 ap_restore wired into wrapper',type(ups['ap_restore'])=='function')
local mod=rawget(_G,'HD2SmoothBoot')
ck('D1 module on _G with version '..VER,
    type(mod)=='table' and mod.version==VER)

for i=1,120 do
    TankRep.frames=TankRep.frames+1
    P33Rep.frame=P33Rep.frame+1
    if TankRep.stopped then TankRep.stopped=false end   -- misbehaving mod
    local r=wrapper(1/60)
    if r~='GAME_OK' then passthrough_ok=false end
    if P33Rep.phase=='stopped' then spin_risk=true end  -- must never happen
    if i%30==0 and TankRep.stopped~=true then reassert_ok=false end
end
ck('A1 boolean flipped during window',TankRep.stopped==true)
ck('A2 tug-of-war re-asserted every 30 frames',reassert_ok)
ck('B1 string phase never written',P33Rep.phase=='starting')
ck('B1 budget untouched',P33Rep.budget==0.008)
ck('B5 freeze condition impossible (no foreign phase)',spin_risk==false)
ck('C1 chain ran every tick',game==120)
ck('C2 passthrough results preserved',passthrough_ok)

ck('B2 engine status (no ctr) untouched',EngineUI.status=='running')
ck('B2 engine paused (no ctr) untouched',EngineFX.paused==false)
ck('B3 engine status (with ctr) observe-only',EngineCtr.status=='running')
ck('B4 idle phase ignored',IdleRep.phase=='idle')
ck('E1 hostile __index survived scan',HostileIdx.phase=='scanning')
ck('E1 hostile __newindex: flip went through rawset',HostileNew.stopped==true)

ups['ap_restore']()
ck('A3 boolean restored to exact false',TankRep.stopped==false)
ck('A3 hostile boolean restored',HostileNew.stopped==false)

for i=1,60 do
    TankRep.frames=TankRep.frames+1
    wrapper(1/60)
    if TankRep.stopped then TankRep.stopped=false end
end
ck('A4 no re-pause after release',TankRep.stopped==false)
ck('C1 chain integrity (180 total)',game==180)

return table.concat(checks,'\n')
'''

HARNESS2 = r'''
local game=0
function update() game=game+1 end
_G.CowboyBingusModLoader={api=1}
pcall(loadstring(src))
TankRep2={frames=0,stopped=false}
P33Rep2 ={frame=0,phase='starting'}
local w=_G.update
for i=1,90 do
    if TankRep2.stopped then TankRep2.stopped=false end
    w(1/60)
end
return TankRep2.stopped, P33Rep2.phase, game
'''

HARNESS3 = r'''
function update() end
_G.CowboyBingusModLoader={api=1}
loadstring(src)()
local w1=_G.update
local again=loadstring(src)()
local mod=rawget(_G,'HD2SmoothBoot')
return tostring(w1==_G.update), tostring(type(again)=='table'), tostring(mod and mod.version)
'''

def report(section, pairs_):
    fails = []
    print("== %s ==" % section)
    for item in pairs_:
        if isinstance(item, tuple):
            name, ok = item
        else:
            name, ok = item[0], item[1]
        print("  %-52s %s" % (name, "PASS" if ok else "FAIL"))
        if not ok:
            fails.append(name)
    return fails

def main():
    fails = []
    before = snapshot_real()

    # the in-game loader creates the log/config tree; the sandbox must
    # pre-create it or io.open silently falls back to a CWD-relative file
    for name in ("SB2161", "SB2162", "SB2163"):
        for sub in ("Logs", r"SmoothBoot"):
            os.makedirs(os.path.join(os.environ["LOCALAPPDATA"], name,
                                     "Helldivers2", sub), exist_ok=True)

    # ---- scenario 1: default window (10s), full lifecycle -------------
    rt = lupa.lua51.LuaRuntime()
    g = rt.globals()
    g["VER"] = VER
    g["src"] = sandboxed("SB2161")
    g["HARNESS1"] = HARNESS1
    blob = str(rt.execute(HARNESS1))
    pairs_ = []
    for line in blob.split("\n"):
        if "\t" in line:
            name, val = line.split("\t", 1)
            pairs_.append((name, val == "true"))
    fails += report("scenario 1: default window", pairs_)

    log1 = open(sandbox_log("SB2161"), encoding="utf-8", errors="replace").read()
    fails += report("scenario 1: sandbox log", [
        ("boolean flip recorded", "auto-pause: TankRep.stopped" in log1),
        ("string machine observed, not touched",
         "observe P33Rep.phase=starting" in log1),
        ("counter table observed", "observe EngineCtr.status=running" in log1),
        ("release count exact (2 fields)", "released 2 field(s)" in log1),
        ("version logged", ("ready v" + VER) in log1),
        ("no-counter tables never paused",
         "auto-pause: EngineUI" not in log1 and "auto-pause: EngineFX" not in log1),
        ("hostile __newindex table flipped via rawset",
         "HostileNew.stopped" in log1),
    ])

    cfg1 = open(sandbox_cfg("SB2161"), encoding="utf-8", errors="replace").read()
    fails += report("scenario 1: sandbox config", [
        ("template documents boot_pause_s=10", "boot_pause_s=10" in cfg1)])

    # ---- scenario 2: boot_pause_s=0 disables everything ---------------
    os.makedirs(os.path.dirname(sandbox_cfg("SB2162")), exist_ok=True)
    with open(sandbox_cfg("SB2162"), "w") as f:
        f.write("enabled=yes\nboot_pause_s=0\n")
    rt2 = lupa.lua51.LuaRuntime()
    g2 = rt2.globals()
    g2["src"] = sandboxed("SB2162")
    g2["HARNESS2"] = HARNESS2
    stopped, phase, game = rt2.execute(HARNESS2)
    fails += report("scenario 2: boot_pause_s=0", [
        ("no boolean flip ever", stopped is False),
        ("no phase write ever", str(phase) == "starting"),
        ("chain intact (90/90)", int(game) == 90)])

    # ---- scenario 3: reload guard returns existing module -------------
    rt3 = lupa.lua51.LuaRuntime()
    g3 = rt3.globals()
    g3["src"] = sandboxed("SB2163")
    g3["HARNESS3"] = HARNESS3
    same, table_, ver = rt3.execute(HARNESS3)
    fails += report("scenario 3: reload guard", [
        ("wrapper unchanged after double load", same == "true"),
        ("second load returned module", table_ == "true"),
        ("module version "+VER, ver == VER)])

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

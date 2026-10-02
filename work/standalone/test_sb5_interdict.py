# -*- coding: utf-8 -*-
"""SmoothBoot 2.18.0 permanent writer-interdiction suite.

Architecture under test: every ~2s the LIVE chain is walked head->bottom;
writer-chunk layers are spliced out via caller upvalue slots and held
permanently (they never run, never scan, never write). No head takeover:
mods above us keep ticking. Opt-in timed release (writer_release_s>0)
releases one writer per stagger interval.

Scenarios:
  1  real topology: writers above AND below, storm head -> all held,
     innocents above/below tick, game ticks, no takeover
  2  late-loading writer below -> caught by a later walk pass
  3  writer as base_prev -> entry bypass
  4  timed release: staggered, function resumes (late write fires)
  5  writers= empty -> nothing held
  6  head itself is a writer -> head swap path
  +  real-game contamination guard
"""
import os
import re
import shutil
import sys
import time
import lupa

W = os.path.dirname(os.path.abspath(__file__))
SRC = open(os.path.join(W, "smoothboot.lua"), encoding="utf-8").read()
VER = re.search(r"version='([\d.]+)'", SRC).group(1)
assert VER.startswith("3."), 'suite covers the 3.x writer-gate implementation'

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

BODIES = r'''
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
'''

HARNESS1 = r'''
local checks={}
local function ck(name,cond) checks[#checks+1]=name..'\t'..(cond and 'true' or 'false') end
REG={}
''' + BODIES + r'''
local game=0
function update() game=game+1 return 'GAME_OK' end
_G.CowboyBingusModLoader={api=1,version='test'}
-- below segment
loadstring(innocent_body('smarter'),'@mods/chef/smarter_guards')()
loadstring(writer_body('mods/codex/gp20_ultimatum_ammo',40),'@mods/codex/gp20_ultimatum_ammo')()
-- SmoothBoot mid-chain
pcall(loadstring(src,'@mods/codex/smoothboot'))
local SBW=_G.update
-- above segment
loadstring(innocent_body('mods/codex/custom_armor'),'@mods/codex/custom_armor')()
loadstring(writer_body('mods/codex/p33_missile_pistol_ammo',40),'@mods/codex/p33_missile_pistol_ammo')()
loadstring(innocent_body('mods/shock233/p2p_ping'),'@mods/shock233/p2p_ping')()
loadstring(writer_body_orig('mods/dsh/m103_frv_turret',40),'@mods/dsh/m103_frv_turret')()
loadstring(writer_body('mods/codex/p34_breacher_ammo',40),'@mods/codex/p34_breacher_ammo')()
-- storm head on top: upvalue-style reheader (the REAL pat mods all get
-- adopted, proving upvalue bookkeeping)
local STORM=[==[
REG['storm']={ticks=0,reheads=0}
local previous_update=update
update=function(...)
    REG['storm'].ticks=REG['storm'].ticks+1
    return previous_update(...)
end
]==]
loadstring(STORM,'@mods/patpatpatrick/mod_lag_finder')()

local passthrough=true
for i=1,400 do
    -- periodic reheading storm above us
    if i%100==0 then
        local previous_update=_G.update
        _G.update=function(...) REG['storm'].reheads=REG['storm'].reheads+1 return previous_update(...) end
    end
    local r=_G.update(1/60)
    if r~='GAME_OK' then passthrough=false end
end
local W33=REG['mods/codex/p33_missile_pistol_ammo']
local W34=REG['mods/codex/p34_breacher_ammo']
local WM1=REG['mods/dsh/m103_frv_turret']
local WG2=REG['mods/codex/gp20_ultimatum_ammo']
ck('I1 above writers never ran (p33)',W33.ticks<=1 and W33.wrote==false)
ck('I1 above writers never ran (p34)',W34.ticks<=1 and W34.wrote==false)
ck('I1 above writers never ran (m103)',WM1.ticks<=1 and WM1.wrote==false)
ck('I1 below writer never ran (gp20)',WG2.ticks<=1 and WG2.wrote==false)
ck('I2 above innocents ticked (cak 400ish)',
    REG['mods/codex/custom_armor'].ticks>=398)
ck('I2 storm head ticked',REG['storm'].ticks>=398)
ck('I3 below innocents ticked',REG['smarter'].ticks>=398)
ck('I4 game every frame (400)',game==400)
ck('I4 passthrough preserved',passthrough)

-- fish WH: four writers held, no takeover fields
local WH
local i=1
while true do local n,v=debug.getupvalue(SBW,i) if not n then break end
    if n=='WH' then WH=v end i=i+1 end
local held=0 for _ in pairs(WH.held) do held=held+1 end
ck('I5 four writers held permanently',held==4)
ck('I5 walks ongoing',WH.walks>=3)
return table.concat(checks,'\n')
'''

HARNESS2 = r'''
REG={}
local checks={}
local function ck(name,cond) checks[#checks+1]=name..'\t'..(cond and 'true' or 'false') end
''' + BODIES + r'''
local game=0
function update() game=game+1 end
_G.CowboyBingusModLoader={api=1}
loadstring(innocent_body('below_a'),'@mods/fake/below_a')()
pcall(loadstring(src,'@mods/codex/smoothboot'))
local SBW=_G.update
loadstring(innocent_body('above_a'),'@mods/fake/above_a')()
for i=1,200 do _G.update(1/60) end
-- a writer loads LATE, below us
loadstring(writer_body('mods/codex/gp20_ultimatum_ammo',50),'@mods/codex/gp20_ultimatum_ammo')()
for i=1,300 do _G.update(1/60) end
local WG=REG['mods/codex/gp20_ultimatum_ammo']
ck('L1 late writer caught by later pass',WG.ticks<=130 and WG.wrote==false)
ck('L2 game intact (497-500)',game>=497 and game<=500)
return table.concat(checks,'\n')
'''

HARNESS3 = r'''
REG={}
local checks={}
local function ck(name,cond) checks[#checks+1]=name..'\t'..(cond and 'true' or 'false') end
''' + BODIES + r'''
local game=0
function update() game=game+1 end
_G.CowboyBingusModLoader={api=1}
-- writer sits directly below SmoothBoot (base_prev position)
loadstring(writer_body('mods/dsh/m103_frv_turret',40),'@mods/dsh/m103_frv_turret')()
pcall(loadstring(src,'@mods/codex/smoothboot'))
loadstring(innocent_body('above_a'),'@mods/fake/above_a')()
for i=1,300 do _G.update(1/60) end
local WM=REG['mods/dsh/m103_frv_turret']
ck('E1 base_prev writer held via entry bypass',WM.ticks<=1 and WM.wrote==false)
ck('E2 game intact (298-300)',game>=298 and game<=300)
return table.concat(checks,'\n')
'''

HARNESS4 = r'''
REG={}
local checks={}
local function ck(name,cond) checks[#checks+1]=name..'\t'..(cond and 'true' or 'false') end
''' + BODIES + r'''
local game=0
function update() game=game+1 end
_G.CowboyBingusModLoader={api=1}
loadstring(innocent_body('below_a'),'@mods/fake/below_a')()
loadstring(writer_body('mods/codex/gp20_ultimatum_ammo',30),'@mods/codex/gp20_ultimatum_ammo')()
pcall(loadstring(src,'@mods/codex/smoothboot'))
loadstring(writer_body('mods/codex/p33_missile_pistol_ammo',30),'@mods/codex/p33_missile_pistol_ammo')()
for i=1,120 do _G.update(1/60) end
local WG=REG['mods/codex/gp20_ultimatum_ammo']
local W33=REG['mods/codex/p33_missile_pistol_ammo']
ck('R1 writers held before release',WG.ticks<=1 and W33.ticks<=1)
return table.concat(checks,'\n'),WG,W33,game
'''

HARNESS5 = r'''
REG={}
local game=0
function update() game=game+1 end
_G.CowboyBingusModLoader={api=1}
''' + BODIES + r'''
loadstring(writer_body('mods/codex/p33_missile_pistol_ammo',50),'@mods/codex/p33_missile_pistol_ammo')()
pcall(loadstring(src,'@mods/codex/smoothboot'))
local w=_G.update
for i=1,80 do w(1/60) end
return REG['mods/codex/p33_missile_pistol_ammo'].ticks,
       REG['mods/codex/p33_missile_pistol_ammo'].wrote, game
'''

HARNESS6 = r'''
REG={}
local checks={}
local function ck(name,cond) checks[#checks+1]=name..'\t'..(cond and 'true' or 'false') end
''' + BODIES + r'''
local game=0
function update() game=game+1 end
_G.CowboyBingusModLoader={api=1}
loadstring(innocent_body('below_a'),'@mods/fake/below_a')()
pcall(loadstring(src,'@mods/codex/smoothboot'))
-- the writer loads LAST: it IS the head
loadstring(writer_body('mods/codex/p34_breacher_ammo',40),'@mods/codex/p34_breacher_ammo')()
for i=1,300 do _G.update(1/60) end
local W34=REG['mods/codex/p34_breacher_ammo']
ck('H1 head writer held via head swap',W34.ticks<=1 and W34.wrote==false)
ck('H2 game intact (298-300)',game>=298 and game<=300)
ck('H3 innocents intact',REG['below_a'].ticks>=298)
return table.concat(checks,'\n')
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

def fresh(name, cfg=None):
    root = os.path.join(os.environ["LOCALAPPDATA"], name)
    shutil.rmtree(root, ignore_errors=True)
    for sub in ("Logs", r"SmoothBoot"):
        os.makedirs(os.path.join(root, "Helldivers2", sub), exist_ok=True)
    if cfg:
        with open(sandbox_cfg(name), "w") as f:
            f.write(cfg)

def run(harness, sandbox, extra_setup=None):
    rt = lupa.lua51.LuaRuntime()
    g = rt.globals()
    g["src"] = sandboxed(sandbox)
    g["H"] = harness
    return rt, g

def main():
    fails = []
    before = snapshot_real()

    # 1: real topology, permanent interdiction
    fresh("SB2181")
    rt, g = run(HARNESS1, "SB2181")
    fails += report("scenario 1: permanent interdiction",
                    parse(str(rt.execute(g["H"]))))
    log1 = open(sandbox_log("SB2181"), encoding="utf-8", errors="replace").read()
    fails += report("scenario 1: sandbox log", [
        ("p33 gated out",
         "writer hold: mods/codex/p33_missile_pistol_ammo gated out" in log1),
        ("m103 gated out",
         "writer hold: mods/dsh/m103_frv_turret gated out" in log1),
        ("gp20 spliced permanently",
         ("writer hold: mods/codex/gp20_ultimatum_ammo gated out" in log1)
         or ("writer hold: mods/codex/gp20_ultimatum_ammo spliced out (entry bypass" in log1)),
        ("first-pass summary logged", "full-chain interdiction active" in log1),
        ("no takeover lines", "head takeover" not in log1),
        ("version logged", ("ready v%s" % VER) in log1)])

    # 2: late loader below
    fresh("SB2182")
    rt, g = run(HARNESS2, "SB2182")
    fails += report("scenario 2: late-loading writer",
                    parse(str(rt.execute(g["H"]))))

    # 3: base_prev writer (entry bypass)
    fresh("SB2183")
    rt, g = run(HARNESS3, "SB2183")
    fails += report("scenario 3: entry bypass",
                    parse(str(rt.execute(g["H"]))))

    # 4: timed staggered release (two phases with a wall-clock sleep)
    fresh("SB2184", "enabled=yes\nboot_skip=0\nwriter_release_s=0.5\nwriter_stagger_s=0.05\n")
    rt4 = lupa.lua51.LuaRuntime()
    g4 = rt4.globals()
    g4["src"] = sandboxed("SB2184")
    phase1 = HARNESS4.split("local WG=REG['mods/codex/gp20_ultimatum_ammo']")[0]
    g4["P1"] = phase1 + "\n_G.__st={gp=REG['mods/codex/gp20_ultimatum_ammo'],p33=REG['mods/codex/p33_missile_pistol_ammo']}\nGAMEN=0\nlocal __ou=update\n"
    rt4.execute("loadstring(P1)()")
    # make the game counter globally visible
    rt4.execute("local f=debug.getupvalue or nil return true")
    time.sleep(1.6)
    # P2: drive 120 frames in bursts with real sleeps so the 0.05s stagger
    # deadline can actually elapse between releases
    TICK = "if _G.update then _G.update(1/60) end return _G.update~=nil"
    alive = True
    for burst in range(4):
        for _ in range(30):
            alive = alive and bool(rt4.execute(TICK))
        time.sleep(0.04)
    g4["P2"] = r'''
local WG=__st.gp
local W33=__st.p33
return WG.ticks,W33.ticks,tostring(WG.wrote),tostring(W33.wrote),type(_G.update)
'''
    t1,t2,w1,w2,updtype = rt4.execute("return loadstring(P2)()")
    print("== scenario 4: timed staggered release ==")
    for name, ok in [
        ("chain alive through releases", alive and str(updtype) == "function"),
        ("gp20 released & resumed (ticks>=119)", int(t1) >= 119),
        ("gp20 late write fired", str(w1) == "True" or str(w1) == "true"),
        ("p33 released later & wrote", str(w2) == "True" or str(w2) == "true")]:
        print("  %-52s %s" % (name, "PASS" if ok else "FAIL"))
        if not ok:
            fails.append("s4:" + name)
    log4 = open(sandbox_log("SB2184"), encoding="utf-8", errors="replace").read()
    ok = "released (gate opened)" in log4
    print("  %-52s %s" % ("release logged", "PASS" if ok else "FAIL"))
    if not ok:
        fails.append("s4:release log")

    # 5: empty list -> nothing held
    fresh("SB2185", "enabled=yes\nboot_skip=0\nwriters=\n")
    rt, g = run(HARNESS5, "SB2185")
    ticks, wrote, game = rt.execute(g["H"])
    fails += report("scenario 5: writers= empty", [
        ("writer runs normally (80)", int(ticks) == 80),
        ("write fired on schedule", bool(wrote)),
        ("chain intact (80)", int(game) == 80)])

    # 6: writer is the head
    fresh("SB2186")
    rt, g = run(HARNESS6, "SB2186")
    fails += report("scenario 6: head writer swap",
                    parse(str(rt.execute(g["H"]))))

    after = snapshot_real()
    fails += report("real-game contamination guard",
                    [("untouched: " + rel, before[rel] == after[rel])
                     for rel in before])

    print()
    if fails:
        print("RESULT: %d FAILURE(S)" % len(fails))
        for f in fails:
            if not f.startswith("s4:"):
                print("  - " + f)
        sys.exit(1)
    print("RESULT: all checks passed")

if __name__ == "__main__":
    main()

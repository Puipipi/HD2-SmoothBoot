-- HD2-Addon: mods/codex/smoothboot
-- HD2 SmoothBoot 2.0: a rule engine for the Bingus mod chain.
-- Deploy order (patch-number order in the loader): every mod you want MANAGED
-- deploys first, then SmoothBoot, then any mods you EXCLUDE (they end up above
-- SmoothBoot in the update onion and stay unmanaged: no throttling, no pcall).
--   * Bingus-only: installs nothing unless _G.CowboyBingusModLoader exists, so
--     non-Bingus Lua setups are never touched
--   * identifies whoever re-heads the chain via debug.getinfo chunk names;
--     excluded mods above us are by design, unknown ones get a hint
--   * self re-heading: when a later-loaded Bingus mod covers us, SmoothBoot
--     adopts the whole chain back under its governor automatically, so Arsenal
--     deploy order stops mattering (excluded / non-Bingus heads stay above)
--   * circuit breaker: a chain call over trip_ms for trip_n frames pauses the
--     chain for pause_s seconds (one runaway mod no longer tanks the game)
--   * v2.8.3: engine probes removed again - zero engine calls is a hard rule
--   * per-mod error attribution from Lua error chunk names, Top N in stats
--   * keeps 1.0 behaviour: boot window skip, adaptive skip, stats, config reload
-- 3.0.13: the reload guard used to compare against the *previous* version
-- literal, so bumping the version silently disabled double-load protection
-- (a second loadstring of the same source re-wrapped _G.update - caught by
-- test_sb3_autopause.py scenario 3).
-- !! The two version literals below MUST be bumped together. build_sb.py and
-- !! test_sb3_autopause.py both regex for version='X.Y.Z', so neither can be a
-- !! variable reference.
local KEY='HD2SmoothBoot'
local old=rawget(_G,KEY)
if old and old.version=='3.0.43' then return old end
if old and type(old.c4_read_pool)=='table' and type(old.c4_read_pool.restore)=='function' then
    pcall(old.c4_read_pool.restore)
end
if old and type(old.c4_input_scope)=='table' and type(old.c4_input_scope.restore)=='function' then
    pcall(old.c4_input_scope.restore)
end
if old and type(old.c4_fire_scope)=='table' and type(old.c4_fire_scope.restore)=='function' then
    pcall(old.c4_fire_scope.restore)
end
if old and type(old.c4_input_batch)=='table' and type(old.c4_input_batch.restore)=='function' then
    pcall(old.c4_input_batch.restore)
end
if old and type(old.c4_context_batch)=='table' and type(old.c4_context_batch.restore)=='function' then
    pcall(old.c4_context_batch.restore)
end
if old and type(old.c4_ui_scope)=='table' and type(old.c4_ui_scope.restore)=='function' then
    pcall(old.c4_ui_scope.restore)
end
if old and type(old.c4_idle_batch)=='table' and type(old.c4_idle_batch.restore)=='function' then
    pcall(old.c4_idle_batch.restore)
end
if old and type(old.c4_native_batch)=='table' and type(old.c4_native_batch.restore)=='function' then
    pcall(old.c4_native_batch.restore)
end
if old and type(old.c4_cpu_profile)=='table' and type(old.c4_cpu_profile.stop)=='function' then
    pcall(old.c4_cpu_profile.stop,'module_reload')
end
local M={version='3.0.43',status='starting',init_started=os.clock()}
rawset(_G,KEY,M)

local HOME=(os.getenv('LOCALAPPDATA') or os.getenv('TEMP') or '.')..'/CowboyBingus/Helldivers2/'
local LOG=HOME..'Logs/SmoothBoot.log'
local CFG=HOME..'SmoothBoot/config.txt'
-- Create only our own directories, without launching a shell. Resolve a typed
-- function pointer rather than adding filesystem prototypes to global ffi.C.
local function ensure_dirs()
    local ok,err=pcall(function()
        local ffi=require('ffi')
        ffi.cdef [[
            void *GetModuleHandleA(const char *name);
            void *GetProcAddress(void *module, const char *name);
        ]]
        local k32=ffi.load('kernel32')
        local module=k32.GetModuleHandleA('kernel32.dll')
        local create=ffi.cast('int (__stdcall *)(const char *, void *)',
                             k32.GetProcAddress(module,'CreateDirectoryA'))
        local attr=ffi.cast('unsigned long (__stdcall *)(const char *)',
                           k32.GetProcAddress(module,'GetFileAttributesA'))
        for _,path in ipairs({HOME:match('^(.*)Helldivers2/$'),HOME,HOME..'Logs/',HOME..'SmoothBoot/'}) do
            local normalized=path:gsub('/','\\')
            if attr(normalized)==4294967295 and create(normalized,nil)==0 then
                error('cannot create '..path)
            end
        end
    end)
    return ok,err
end
ensure_dirs()
local log_buf={}      -- watchdog lesson: writes can take 0.4-2s when the
local log_paused=false -- disk/AV stalls; never write during a panic window
local function log_flush()
    if #log_buf==0 then return end
    local text=table.concat(log_buf)
    log_buf={}
    pcall(function()
        local t0=os.clock()
        local f=io.open(LOG,'a') or io.open('SmoothBoot.log','a')
        if f then f:write(text);f:close() end
        local took=os.clock()-t0
        if took>0.05 then
            -- the write itself stalled: surface it for AV/disk diagnosis
            pcall(function()
                local f2=io.open(LOG,'a')
                if f2 then f2:write(os.date('!%Y-%m-%dT%H:%M:%SZ')..' warning: log write took '..string.format('%.0fms',took*1000)..' (disk or AV stall?)\n');f2:close() end
            end)
        end
    end)
end
local function log(s)
    M.status=s
    log_buf[#log_buf+1]=os.date('!%Y-%m-%dT%H:%M:%SZ')..' '..s..'\n'
    if not log_paused and #log_buf>=1 then log_flush() end
end

-- Rule 0: this engine only manages the Bingus ecosystem.
local loader=rawget(_G,'CowboyBingusModLoader')
if not loader then
    M.status='dormant: no Bingus loader, refusing to touch update'
    log(M.status)
    return M
end
log('module entry v'..M.version..' - measuring own initialization only')

local function conf()
    local defaults={enabled=true,throttle='auto',profile=true,boot_skip=1,boot_s=0,grace_s=60,busy_ms=12,idle_ms=1.5,max_skip=2,snapshot=false,
                    trip_ms=50,trip_n=3,pause_s=5,exclude='lte/helmet_cape_passives',gc_pause=400,gc_stepmul=0,peer_suspend=true,c4_read_pool=true,c4_read_profile=false,c4_input_batch=false,c4_context_batch=false,c4_native_batch=false,c4_idle_batch=false,c4_cpu_profile=false,ui_mods='',scanners='',boot_pause_s=10,
                    writer_release_s=10,writer_stagger_s=8,writer_norelease='m103_frv',ui_chunks='gun_calibration,helmet_cape_passives',writers='p33_missile_pistol,p34_breacher,gp20_ultimatum,m103_frv,ac8_rack,k9_p,no_large_piercing,maxigun,tank_cooldown,maelstrom_traverse,tank_clutch_tuner,tank_seat_kit',
                    -- 3.0.8: writer_min_stagger_s ships at the conservative stagger.
                    -- Measured in-mission on this machine with the same mod set:
                    -- 1 s releases gave 33 FPS, 8 s releases gave 69.8 FPS, and the
                    -- held writers' writes are the ones known to detonate later
                    -- (see the 0x66d26c note above). Set it to 1 for a ~5 s boot if
                    -- you accept that risk; the adaptive gate below still applies.
                    -- 3.0.5+ adaptive release gate: release every writer_min_stagger_s
                    -- while the frame cadence is near this machine's own best, and
                    -- wait whenever it drifts past writer_fi_factor * best (capped at
                    -- writer_fi_floor_ms * 2.5). The old gate only waited above a flat
                    -- 40 ms, so a 60 FPS task window - exactly where these writer
                    -- writes detonate - counted as calm and every release landed in it.
                    writer_min_stagger_s=8,writer_fi_factor=3,writer_fi_floor_ms=12}
    local ok,text=pcall(function()
        local f=io.open(CFG,'r')
        if not f then return nil end
        local t=f:read('*a') f:close() return t
    end)
    if not ok or not text then
        pcall(function()
            -- no os.execute ever: spawning a shell during boot is the prime
            -- suspect for the DX11 black-screen crash reports. If the SmoothBoot
            -- directory does not exist yet we run on defaults and retry on the
            -- next config poll (the loader creates the tree meanwhile).
            local w=io.open(CFG,'w')
            if w then
                w:write('# HD2 SmoothBoot - chain governor for the Bingus ecosystem\n')
                w:write('# deploy order no longer matters: it re-heads itself automatically\n')
                w:write('enabled=yes\n')
                w:write('# adaptive skip only kicks in above busy_ms per chain call (throttle=no to disable)\n')
                w:write('throttle=auto\nprofile=yes\n')
                w:write('# candidate: reuse C4 native read buffers, never cache memory or skip input\n')
                w:write('c4_read_pool=yes\n')
                w:write('c4_read_profile=no\nc4_input_batch=no\nc4_context_batch=no\nc4_native_batch=no\nc4_idle_batch=no\nc4_cpu_profile=no\n')
                w:write('# loading grace: full speed while mods finish their init scans\n')
                w:write('boot_skip=1\nboot_s=0\ngrace_s=60\n')
                w:write('# auto-pause: flip mod stop fields during the first N seconds (0 = off)\n')
                w:write('boot_pause_s=10\n')
                w:write('# writer interdiction: FFI writer mods are spliced out of the update\n')
                w:write('# chain for writer_release_s seconds (their concurrent writes are what\n')
                w:write('# crashes the game at 0x66d26c), then released one per stagger\n')
                w:write('# interval while the engine is calm - every mod still takes effect\n')
                w:write('writer_release_s='..defaults.writer_release_s..'\n')
                w:write('writer_stagger_s='..defaults.writer_stagger_s..'\n')
                w:write('# comma separated chunk fragments of writer mods to hold\n')
                w:write('writers=p33_missile_pistol,p34_breacher,gp20_ultimatum,m103_frv,ac8_rack,k9_p,no_large_piercing\n')
                w:write('busy_ms=12\n')
                w:write('# throttle engages above max(busy_ms, busy_pct% of your frame time)\n')
                w:write('busy_pct=30\nidle_ms=1.5\nmax_skip=2\n')
                w:write('# breaker: chain over trip_ms for trip_n calls pauses it for pause_s seconds\n')
                w:write('trip_ms=50\ntrip_n=3\npause_s=5\n')
                w:write('# comma separated mod path fragments that must NOT be managed\n')
                w:write('exclude=lte/helmet_cape_passives\n')
                w:write('# GC tuning for the whole mod ecosystem (0 = engine defaults)\n')
                w:write('gc_pause=400\ngc_stepmul=0\n')
                w:close()
            end
        end)
        return defaults
    end
    -- One-time upgrade: preserve custom exclusions, add only the reported LTE
    -- mod. A marker lets users subsequently remove this entry themselves.
    pcall(function()
        local marker=HOME..'SmoothBoot/exclusions-3.0.21.txt'
        local done=io.open(marker,'r')
        if done then done:close();return end
        local spec=''
        for line in text:gmatch('[^\r\n]+') do
            local value=line:match('^%s*exclude%s*=%s*([%w%./_,%-]*)%s*$')
            if value then spec=value end
        end
        local found=false
        for value in spec:gmatch('[%w%./_%-]+') do
            if value=='lte/helmet_cape_passives' then found=true end
        end
        if not found then
            local merged=spec..(spec~='' and ',' or '')..'lte/helmet_cape_passives'
            local f=assert(io.open(CFG,'a'))
            local addition='\nexclude='..merged..'\n'
            assert(f:write(addition));f:close();text=text..addition
            log('default exclusion added: mods/lte/helmet_cape_passives (reported variant creation conflict)')
        end
        local f=assert(io.open(marker,'w'));f:write('applied\n');f:close()
    end)
    for line in text:gmatch('[^\r\n]+') do
        local v
        v=line:match('^%s*enabled%s*=%s*(%a+)%s*$')
        if v then defaults.enabled=(v=='yes' or v=='true' or v=='on') end
        v=line:match('^%s*throttle%s*=%s*(%a+)%s*$')
        if v then defaults.throttle=v:lower() end
        v=line:match('^%s*ui_mods%s*=%s*([%w_,%-]+)%s*$')
        if v then defaults.ui_mods=v end
        v=line:match('^%s*scanners%s*=%s*([%w_./,%-]+)%s*$')
        if v then defaults.scanners=v end
        v=line:match('^%s*writers%s*=%s*([%w_./,%-]*)%s*$')
        if v then defaults.writers=v end
        v=line:match('^%s*writer_norelease%s*=%s*([%w_./,%-]*)%s*$')
        if v then defaults.writer_norelease=v end
        v=line:match('^%s*ui_chunks%s*=%s*([%w_./,%-]*)%s*$')
        if v then defaults.ui_chunks=v end
        v=line:match('^%s*diag%s*=%s*(%a+)%s*$')
        if v then defaults.diag=(v=='yes' or v=='true' or v=='on') end
        -- 3.0.10: the closure-graph snapshots cost ~10 ms per run and retain
        -- third-party tables; keep them behind their own switch, never diag.
        v=line:match('^%s*snapshot%s*=%s*(%a+)%s*$')
        if v then defaults.snapshot=(v=='yes' or v=='true' or v=='on') end
        v=line:match('^%s*boot_freeze_s%s*=%s*(%d+%.?%d*)%s*$')
        if v then defaults.boot_freeze_s=tonumber(v) end
        v=line:match('^%s*profile%s*=%s*(%a+)%s*$')
        if v then defaults.profile=(v=='yes' or v=='true' or v=='on') end
        v=line:match('^%s*peer_suspend%s*=%s*(%a+)%s*$')
        if v then defaults.peer_suspend=(v=='yes' or v=='true' or v=='on') end
        v=line:match('^%s*c4_read_pool%s*=%s*(%a+)%s*$')
        if v then defaults.c4_read_pool=(v=='yes' or v=='true' or v=='on') end
        v=line:match('^%s*c4_read_profile%s*=%s*(%a+)%s*$')
        if v then defaults.c4_read_profile=(v=='yes' or v=='true' or v=='on') end
        v=line:match('^%s*c4_input_batch%s*=%s*(%a+)%s*$')
        if v then defaults.c4_input_batch=(v=='yes' or v=='true' or v=='on') end
        v=line:match('^%s*c4_context_batch%s*=%s*(%a+)%s*$')
        if v then defaults.c4_context_batch=(v=='yes' or v=='true' or v=='on') end
        v=line:match('^%s*c4_native_batch%s*=%s*(%a+)%s*$')
        if v then defaults.c4_native_batch=(v=='yes' or v=='true' or v=='on') end
        v=line:match('^%s*c4_idle_batch%s*=%s*(%a+)%s*$')
        if v then defaults.c4_idle_batch=(v=='yes' or v=='true' or v=='on') end
        v=line:match('^%s*c4_cpu_profile%s*=%s*(%a+)%s*$')
        if v then defaults.c4_cpu_profile=(v=='yes' or v=='true' or v=='on') end
        for _,key in ipairs({'boot_skip','boot_s','grace_s','busy_ms','busy_pct','idle_ms','max_skip',
                             'trip_ms','trip_n','pause_s','gc_pause','gc_stepmul','boot_pause_s',
                             'writer_release_s','writer_stagger_s',
                             'writer_min_stagger_s','writer_fi_factor','writer_fi_floor_ms'}) do
            v=line:match('^%s*'..key..'%s*=%s*(%d+%.?%d*)%s*$')
            if v then defaults[key]=tonumber(v) end
        end
        v=line:match('^%s*exclude%s*=%s*([%w%./_,%-]*)%s*$')
        if v then defaults.exclude=v end
    end
    return defaults
end

local unpack=rawget(_G,'unpack') or table.unpack

-- Identify a function with the Bingus declaration chunk name.
-- Source identity cannot change when an upvalue is re-hooked. Weak keys avoid
-- keeping discarded watchdog closures alive; cache the failed lookups too.
local chunk_cache=setmetatable({},{__mode='k'})
local function function_chunk(fn)
    if type(fn)~='function' then return '' end
    local cached=chunk_cache[fn]
    if cached~=nil then return cached end
    local ok,info=pcall(debug.getinfo,fn,'S')
    local name=ok and info and (info.source or ''):match('mods/[%w_./%-]+') or ''
    chunk_cache[fn]=name
    return name
end
local function identify(fn)
    return function_chunk(fn):match('(mods/[%w_/%-]+)')
end

local PEER_FRAGMENTS={'mods/mdl'}   -- peer loaders: equal-rank chain managers,
-- throttling them would only hurt their own users; they stay above us.
local UI_BUILTINS={'LTE_helmet_cape_passives','HD2Transmog','HD2MultiPerk','MaxMaelstromTraverse'}
-- These update callbacks render or consume frame edges. Skipping their
-- enclosing chain breaks draw cadence/input, even without a published UI table.
local FRAME_CRITICAL_CHUNKS={'mods/codex/gun_calibration','mods/combat/enemy_hp',
    'mods/equippedstratagems/nativestratagemradial','mods/aggro_counter/aggro_counter'}
local function detect_ui_mods(extra)
    local names={}
    for _,n in ipairs(UI_BUILTINS) do names[#names+1]=n end
    for n in (extra or ''):gmatch('[%w_]+') do names[#names+1]=n end
    local found={}
    for _,n in ipairs(names) do
        if type(rawget(_G,n))=='table' then found[#found+1]=n end
    end
    return found
end


local function excluded_list(spec)
    local t={}
    for frag in spec:gmatch('[%w%./%-]+') do t[#t+1]=frag:lower() end
    for _,p in ipairs(PEER_FRAGMENTS) do t[#t+1]=p end
    return t
end
local function is_excluded(modname,list)
    if not modname then return false end
    local low=modname:lower()
    for _,frag in ipairs(list) do
        if frag~='' and low:find(frag,1,true) then return true end
    end
    return false
end

local previous=rawget(_G,'update')
-- re-chain state: wrapper plays two roles. Called by the ENGINE (outer) it is
-- the governor; called from inside an adopted chain (a mod that loaded after
-- us keeps us as its previous) it is a pass-through shell into the original
-- chain, which breaks the cycle wrapper->X->wrapper.
local base_prev=previous     -- the chain as it was when we installed
local head_above=nil         -- outermost adopted mod wrapper (nil = no one above)
local inside=false           -- true while an adopted chain is calling back into us
local in_frames=0            -- pass-through call counter (engine-pin rollback probe)
local gov_mark=0             -- frames snapshot at last adopt
local adopts=0
local adopted_once={}       -- mods that already got one adopt this session
local head_seen={}          -- watchdog lesson: count who heads the chain;
-- a mod showing up x2+ is re-arming its hook and deserves a warning
local peer_active=false    -- a peer loader (MDL) is present: manual control wins
local ui_present=nil       -- nil unknown, false none, true protected mode
-- per-mod cost accounting: walk the onion via upvalues and swap each layer's
-- "previous" upvalue for a timing proxy. Only layers whose next hop is
-- unambiguous (well-known name or exactly one function upvalue) are timed.

-- ===== auto-pause: freeze mod logic, not the game ==============
-- During the first boot_pause_s seconds, scans _G for tables carrying the
-- mod-state signature (numeric frame counter) and a boolean
-- "stopped"/"paused" field set false, sets them true (pausing that mod's
-- tick), then restores them after the window. String state machines
-- (phase/status) are observed and logged but never written -- 2.16.0
-- proved foreign phase values kill real mods. The update chain runs
-- normally throughout; the game's own rendering/input is never blocked.
local AP={held={},restored=false,seen_keys={}}
local AP_KEYS={'stopped','paused','halted','suspended'}
-- string state machines: phase/status/state = 'scanning'/'running'/'active'/'starting'
local AP_STR_KEYS={'phase','status','state'}
local AP_ACTIVE={['scanning']=true,['running']=true,['active']=true,
                 ['starting']=true,['steady']=true,['monitoring']=true}
local APorig={}
local function ap_scan()
    if AP.restored then return end
    for g,v in pairs(_G) do
        if type(v)=='table' and g~='_G' and g~=KEY then
            -- mod-state signature: a numeric frame counter (frame/frames/
            -- ticks/elapsed). Engine and UI tables without one are never
            -- touched, whatever fields they carry. raw access throughout:
            -- hostile metatables (__index/__newindex) cannot disturb this.
            local has_ctr=type(rawget(v,'frame'))=='number' or type(rawget(v,'frames'))=='number'
                or type(rawget(v,'ticks'))=='number' or type(rawget(v,'elapsed'))=='number'
            if has_ctr then
                -- boolean pause fields: the mod family's OWN stop switch
                -- (TankCooldown and the safe rewrites set these themselves,
                -- so the value is native vocabulary, not ours)
                for _,field in ipairs(AP_KEYS) do
                    if type(rawget(v,field))=='boolean' and rawget(v,field)==false then
                        if not AP.seen_keys[g..'.'..field] then
                            AP.seen_keys[g..'.'..field]=true
                            APorig[g..'.'..field]={tbl=v,key=field,val=false}
                            log('auto-pause: '..g..'.'..field)
                        end
                        rawset(v,field,true)
                    end
                end
                -- string state machines: OBSERVE ONLY. 2.16.0 wrote
                -- 'stopped' into foreign state machines and real mods spun
                -- to death (freeze + crash right after boot release). We
                -- cannot invent vocabulary for someone else's state machine:
                -- log the risk, touch nothing.
                for _,field in ipairs(AP_STR_KEYS) do
                    local cur=rawget(v,field)
                    if type(cur)=='string' and AP_ACTIVE[cur:lower()] then
                        if not AP.seen_keys[g..'.'..field] then
                            AP.seen_keys[g..'.'..field]=true
                            log('auto-pause: observe '..g..'.'..field..'='..
                                cur..' (state machine - not touched)')
                        end
                    end
                end
            end
        end
    end
end
local function ap_restore()
    if AP.restored then return end
    AP.restored=true
    for _,entry in pairs(APorig) do
        if type(entry.tbl)=='table' then
            rawset(entry.tbl,entry.key,entry.val)
        end
    end
    local n=0 for _ in pairs(APorig) do n=n+1 end
    log('auto-pause: released '..n..' field(s)')
end
local wrapper               -- forward declaration (splice needs it)
local installed_at=os.clock()
local avg_hist={}            -- rolling chain-cost samples, to detect init decay
local w_total,w_n=0,0
local sample_mark=0
local function settled(grace)
    -- still inside the loading grace, or chain cost still sinking: mods are
    -- initialising, throttling them would double load time
    if os.clock()-installed_at<(grace or 60) then return false end
    local n=#avg_hist
    if n<2 then return true end
    return avg_hist[n] > avg_hist[n-1]*0.95   -- no longer dropping (5s samples)
end
local frames,calls,skipped=0,0,0
local dt_window=0              -- max dt seen in the current 300-frame window
local cfg=conf()
local excludes=excluded_list(cfg.exclude or '')

-- BEGIN C4 INPUT BATCH
-- AimInputState contract adapted from HD2 C4 Quick Actions, MIT license.
-- Copyright (c) 2026 HD2 C4 Quick Actions contributors
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.
-- Smooth-owned optional adapter for the measured binding-key scan. Every
-- validation pass reads fresh bytes and compares every original guard.
local C4Batch={records={},active=0}
M.c4_input_batch=C4Batch
function C4Batch.signature(fn)
    local ok,blob=pcall(string.dump,fn,true)
    if not ok or #blob>8192 or blob:sub(1,4)~='\27LJ\2' then return nil end
    local function canonical()
        local at,parts=5,{}
        local function take(n)
            assert(n>=0 and at+n-1<=#blob,'dump_bounds')
            local value=blob:sub(at,at+n-1);at=at+n;return value
        end
        local function num()
            local start,value,mult=at,0,1
            for _=1,5 do
                local b=assert(blob:byte(at));at=at+1
                value=value+(b%128)*mult
                if b<128 then return value,blob:sub(start,at-1)end
                mult=mult*128
            end
            error('dump_uleb')
        end
        local flags=num();assert(flags%4>=2 and flags%2==0 and flags<16,'dump_flags')
        parts[1]=blob:sub(1,at-1)
        local function addnum()local value,raw=num();parts[#parts+1]=raw;return value end
        local function tablevalue()
            local kind,raw=num()
            if kind>=5 then return raw..take(kind-5)end
            if kind==3 then local _,bytes=num();return raw..bytes end
            if kind==4 then local _,a=num();local _,b=num();return raw..a..b end
            assert(kind<=2,'dump_table_kind');return raw
        end
        while true do
            local length=addnum()
            if length==0 then assert(at==#blob+1);break end
            local last=at+length
            local header=take(4);parts[#parts+1]=header
            local kgc=addnum();addnum();local bc=addnum()
            parts[#parts+1]=take(bc*4+header:byte(4)*2)
            for _=1,kgc do
                local kind=addnum()
                if kind>=5 then parts[#parts+1]=take(kind-5)
                elseif kind==1 then
                    local array=addnum();local hash=addnum()
                    for _=1,array do parts[#parts+1]=tablevalue()end
                    local entries={}
                    for i=1,hash do entries[i]=tablevalue()..tablevalue()end
                    table.sort(entries)
                    for _,entry in ipairs(entries)do parts[#parts+1]=entry end
                elseif kind>1 then
                    assert(kind<=4,'dump_constant_kind');addnum();addnum()
                    if kind==4 then addnum();addnum()end
                end
            end
            parts[#parts+1]=take(last-at)
        end
        local normalized=table.concat(parts)
        local a,b=1,0
        for i=1,#normalized do a=(a+normalized:byte(i))%65521;b=(b+a)%65521 end
        return #normalized,b*65536+a
    end
    local good,length,hash=pcall(canonical)
    if good then return length,hash end
end
function C4Batch.make_reader(D,R)
    local bit=require('bit')
    return function(api,game,base,codes,native,spec)
        spec=spec or {action=D.input_aim_action,code=D.input_aim_code,index=8}
        -- Arrays belong to this invocation: returned same() closures must keep
        -- their own bytes even after another snapshot is created.
        local guard_at,guard_bytes,guard_blocks,guard_count={},{},{},0
        local function record(at,n,bytes,block)
            assert(type(at)=='number' and at>=65536 and at+n<0x800000000000 and
                n>0 and n<=512 and guard_count<1000,'aim_read_bounds')
            assert(bytes,'aim_read_unavailable');assert(#bytes==n,'aim_short_read')
            guard_count=guard_count+1
            guard_at[guard_count]=at;guard_bytes[guard_count]=bytes;guard_blocks[guard_count]=block
            return bytes
        end
        local function read(at,n)
            assert(type(at)=='number' and at>=65536 and at+n<0x800000000000 and
                n>0 and n<=512 and guard_count<1000,'aim_read_bounds')
            return record(at,n,api.read(at,n))
        end
        local function ptr(at)return assert(api.pointer(read(at,8)),'aim_pointer')end
        local function same()
            local blocks={}
            for i=1,guard_count do
                local at,expected,block=guard_at[i],guard_bytes[i],guard_blocks[i]
                local bytes
                if block then
                    local data=blocks[block.at]
                    if data==nil then
                        data=api.read(block.at,block.size) or false;blocks[block.at]=data
                    end
                    if data then local offset=at-block.at;bytes=data:sub(offset+1,offset+#expected)
                    else bytes=api.read(at,#expected)end
                else bytes=api.read(at,#expected)end
                if bytes~=expected then return false end
            end
            return true
        end
        local owner=ptr(game+R.global_input_owner)
        local count=base.u32(read(owner+D.input_inhibit_count,4),0)
        assert(count<=D.input_inhibit_capacity,'aim_inhibition_count')
        local h=read(owner+D.input_inhibit_map,20)
        local n,empty,mult=base.u32(h,8),base.u32(h,12),base.u32(h,16)
        assert(n<=1024 and (n==0 or bit.band(n,n-1)==0),'aim_inhibition_map')
        local index
        if n>0 then
            local tableptr=assert(api.pointer(h),'aim_inhibition_pointer');local ended=false
            for i=0,math.min(n,128)-1 do
                local bytes=read(tableptr+((base.product_low(spec.code,mult)+i)%n)*8,8)
                local key=base.u32(bytes,0)
                if key==spec.code then index=base.u32(bytes,4);ended=true;break end
                if key==empty then ended=true;break end
            end
            assert(ended,'aim_inhibition_probe_limit')
        end
        local mask
        if index and index~=0xffffffff then
            assert(index<count,'aim_inhibition_index')
            local address=owner+D.input_inhibit_rows+index*24;local bytes=read(address,24)
            assert(base.u32(bytes,4)==2 and base.u32(bytes,8)==spec.index,'aim_inhibition_identity')
            mask={address=address,bytes=bytes,mode=base.u32(bytes,0)}
        end
        local result={owner=owner,mask=mask,count=count,same=same}
        if not codes then assert(same(),'aim_state_changed');return result end
        local state=read(owner+808+32*(2*97+spec.index),1)
        assert(state:byte()<=1,'aim_action_state');result.held=state:byte()~=0
        if spec.fire then assert(same(),'fire_input_snapshot_changed');return result end
        local bh=read(owner+D.input_bindings,20)
        local capacity=base.u32(bh,8);assert(capacity==256,'aim_binding_capacity')
        local buckets=assert(api.pointer(bh),'aim_binding_pointer')
        local wanted={[spec.code]='aim',[codes.deploy]='deploy',[codes.detonate]='detonate'}
        assert(wanted[spec.code]=='aim','aim_assignment_collision')
        local lists={}
        for code,key in pairs(wanted)do
            -- Per-code scan buffers are local to this call; no frame cache.
            local blocks={}
            for probe=0,capacity-1 do
                local i=(base.product_low(code,base.u32(bh,16))+probe)%capacity
                local at=buckets+i*328;local first=math.floor(i/12)*12
                local block=blocks[first]
                if not block then
                    local size=(math.min(12,capacity-first)-1)*328+4
                    local address=buckets+first*328
                    assert(type(address)=='number' and address>=65536 and
                        address+size<0x800000000000,'aim_read_bounds')
                    block={at=address,size=size,data=api.read(address,size) or false};blocks[first]=block
                end
                local bytes
                if block.data then local offset=at-block.at;bytes=record(at,4,block.data:sub(offset+1,offset+4),block)
                else bytes=read(at,4)end
                if base.u32(bytes,0)==code then
                    local size=base.u32(read(at+4,4),0);assert(size<=16,'aim_binding_count')
                    local mappings={}
                    for j=0,size-1 do mappings[#mappings+1]={at=at+8+j*20,bytes=read(at+8+j*20,20)}end
                    lists[key]=mappings;break
                end
            end
        end
        assert(lists.aim and lists.deploy and lists.detonate,'aim_binding_missing')
        assert(same(),'aim_binding_changed')
        local chosen=native.input_mapping(owner,spec.action)
        if chosen and chosen~=0 then
            for _,v in ipairs(lists.aim)do if v.at==chosen then result.aim=v.bytes;break end end
            assert(result.aim,'aim_selected_mapping_outside_bucket')
        end
        result.deploy=lists.deploy;result.detonate=lists.detonate
        assert(same(),'aim_snapshot_changed');return result
    end
end
function C4Batch.attach(target)
    if not cfg.enabled or not cfg.c4_input_batch or type(target)~='table' or getmetatable(target) then return false end
    local original=rawget(target,'read')
    if type(original)~='function' or function_chunk(original):gsub('%.lua$','')~='mods/etxp/c4_boundary_probe' or
       is_excluded('mods/etxp/c4_boundary_probe',excludes) then return false end
    local length,hash=C4Batch.signature(original)
    if not ((length==2920 and hash==3910151087) or (length==2847 and hash==3465483342)) then
        log('C4 input batch: unsupported fingerprint '..tostring(length)..'/'..tostring(hash)..'; unchanged')
        return false
    end
    local captured={}
    for i=1,8 do local name,value=debug.getupvalue(original,i);if not name then break end;captured[name]=value end
    if type(captured.D)~='table' or type(captured.R)~='table' or captured.bit~=require('bit') then return false end
    local replacement=C4Batch.make_reader(captured.D,captured.R)
    C4Batch.records[target]={original=original,replacement=replacement}
    rawset(target,'read',replacement);C4Batch.active=1
    log('C4 input batch: active (verified original reader; all guards and native actions preserved)')
    return true
end
function C4Batch.restore()
    for target,record in pairs(C4Batch.records)do
        if rawget(target,'read')==record.replacement then rawset(target,'read',record.original)end
        C4Batch.records[target]=nil
    end
    C4Batch.active=0
end
-- END C4 INPUT BATCH

-- BEGIN C4 CONTEXT BATCH
-- ContextReader contract adapted from HD2 C4 Quick Actions under the MIT
-- notice above. Every original guard is compared to fresh bytes. Validation
-- and scan-local template reads batch fields with individual-read fallback.
local GuardBatch=(function()
-- Private validation-read prototype. No cached native bytes or native writes.
local M={}
-- Bounded immutable layout metadata only. Neither guards, captured bytes,
-- readers nor accounting callbacks survive through this shared cache.
local layouts={}
function M.clear_plans()layouts={}end
function M.new(guards,api,account)
    local plan,sizes,addresses={},{},{}
    local function rebuild()
        local total=0
        assert(#guards<=768,'snapshot_validation_budget')
        for i,g in ipairs(guards)do
            local n=#g.bytes;total=total+n
            assert(n>0 and n<=4096 and total<=32768,'snapshot_validation_budget')
            sizes[i]=n;addresses[i]=g.at
        end
        for slot,layout in ipairs(layouts)do
            local count=#sizes
            local matches=#layout.sizes==count and layout.addresses[count]==addresses[count]
                and layout.sizes[count]==sizes[count]
            if matches then for i,at in ipairs(addresses)do
                if layout.addresses[i]~=at or layout.sizes[i]~=sizes[i] then
                    matches=false;break
                end
            end end
            if matches then
                plan=layout.plan
                -- Keep recently used layouts close; the entire cache is <=8.
                if slot>1 then table.remove(layouts,slot);table.insert(layouts,1,layout)end
                return
            end
        end
        local sorted={}
        for i,g in ipairs(guards)do
            local n=sizes[i]
            sorted[i]={at=g.at,last=g.at+n,index=i}
        end
        table.sort(sorted,function(a,b)return a.at<b.at end)
        local proposed={};local bytes=0;plan={}
        for _,g in ipairs(sorted)do
            local last=proposed[#proposed]
            if last and g.at<=last.last+32 and math.max(last.last,g.last)-last.at<=4096 then
                last.last=math.max(last.last,g.last)
            else last={at=g.at,last=g.last};proposed[#proposed+1]=last end
            plan[g.index]=last
        end
        for _,p in ipairs(proposed)do bytes=bytes+p.last-p.at end
        -- Never exceed the original validation budget; sparse ranges stay small.
        -- Reserve the complete original fallback cost as well. A failure of
        -- every larger read must still fit the existing read/byte budgets.
        if bytes+total>32768 or #proposed+#guards>768 or bytes>total*2 then
            for _,g in ipairs(sorted)do plan[g.index]={at=g.at,last=g.last}end
        end
        table.insert(layouts,1,{addresses=addresses,sizes=sizes,plan=plan})
        if #layouts>8 then layouts[9]=nil end
    end
    return function()
        local valid=#sizes==#guards
        if valid then for i,g in ipairs(guards)do
            if sizes[i]~=#g.bytes or addresses[i]~=g.at then valid=false;break end
        end end
        if not valid then sizes,addresses={},{};rebuild()end
        local data={}
        for i,g in ipairs(guards)do
            local p=plan[i];local b=data[p]
            if b==nil then
                local n=p.last-p.at
                if account then account(n)end
                b=api.read(p.at,n)
                if p.at==g.at and n==#g.bytes then
                    assert(b,'read_unavailable');assert(#b==n,'short_read')
                end
                -- Extra bytes can cross an unreadable gap: retry the original
                -- field reads, in their original comparison order.
                if not b or #b~=n then b=false end
                data[p]=b
            end
            local value
            if b then value=b:sub(g.at-p.at+1,g.at-p.at+#g.bytes)
            else
                if account then account(#g.bytes)end
                value=assert(api.read(g.at,#g.bytes),'read_unavailable')
                assert(#value==#g.bytes,'short_read')
            end
            if value~=g.bytes then return false end
        end
        return true
    end
end
return M
end)()
local C4Context={records={},active=0,guard_batch=GuardBatch}
M.c4_context_batch=C4Context
function C4Context.make_reader(original,omit_templates)
    local R,D
local ContextReader=(function()

local bit = require('bit')
local M = {}
local INVALID = 0xffffffff
local DETONATOR = '51f50d6321f52f3d'
local CHARGE = '9b75217d8312dd67'
local AVATAR = '4d1c334d294dfa97'
local function u32(b,o)
    assert(b and o>=0 and o+4<=#b,'short_u32')
    local a,c,d,e=b:byte(o+1,o+4)
    return a+c*256+d*65536+e*16777216
end
local function resource(b)
    local out={}
    for i=8,1,-1 do out[#out+1]=string.format('%02x',b:byte(i)) end
    return table.concat(out)
end
local function hex(b)
    return (b:gsub('.',function(c) return string.format('%02x',c:byte()) end))
end
local function product_low(a,b)

    return ((a%65536)*(b%65536)+
        ((math.floor(a/65536)*(b%65536)+(a%65536)*math.floor(b/65536))%65536)*65536)%4294967296
end
M.u32=u32
function M.f32(b,o)
    local n=u32(b,o);local sign=n>=0x80000000 and -1 or 1
    local exponent=math.floor(n/0x800000)%256;local fraction=n%0x800000
    assert(exponent~=255,'nonfinite_native_float')
    return sign*(exponent==0 and fraction*2^-149 or (1+fraction/0x800000)*2^(exponent-127))
end
M.product_low=product_low

function M.snapshot(api,game,extend)
    local guards,reads,bytes={},0,0
    local actual_reads,actual_bytes=0,0
    local validation_reads,validation_bytes=0,0
    local extension_result
    local owner,extension_regions
    local function read(at,n,guard,prefetched)
        assert(type(at)=='number' and at>=65536 and at+n<0x800000000000,'invalid_address')
        reads=reads+1;bytes=bytes+n
        assert(n>0 and n<=4096 and reads<=768 and bytes<=32768,'snapshot_budget')
        local b=prefetched
        -- The original ActionReader/ReloadReader obtains these template pointers
        -- through e.ptr before its 16-byte probe loop. Batch only that declared
        -- region during this extension call; never retain bytes for a later
        -- snapshot, native action, or escaped e.read callback.
        if b==nil and guard and n==16 and extension_regions then
            for _,region in ipairs(extension_regions)do
                local offset=at-region.at
                if offset>=0 and offset<region.capacity*16 and offset%16==0 then
                    local slot=offset/16
                    if not region.individual and (not region.block or slot<region.slot or slot>=region.slot+region.count)then
                        region.slot=slot
                        region.count=math.min(16,region.capacity-slot,769-reads)
                        local size=region.count*16
                        if region.count>1 and at+size<0x800000000000 then
                            actual_reads=actual_reads+1;actual_bytes=actual_bytes+size
                            local ok,value=pcall(api.read,at,size)
                            if ok and type(value)=='string' and #value==size then region.block=value
                            else region.individual=true;region.block=nil end
                        else region.individual=true;region.block=nil end
                    end
                    if region.block then
                        local start=(slot-region.slot)*16
                        b=region.block:sub(start+1,start+16)
                    end
                    break
                end
            end
        end
        if b==nil then
            actual_reads=actual_reads+1;actual_bytes=actual_bytes+n
            b=api.read(at,n)
        end
        b=assert(b,'read_unavailable')
        assert(#b==n,'short_read')
        if guard then guards[#guards+1]={at=at,bytes=b} end
        return b
    end
    local function ptr(at,guard)
        local p=assert(api.pointer(read(at,8,guard)),'pointer_unavailable')
        assert(p>=65536 and p<0x800000000000,'invalid_pointer')
        if extension_regions and guard and owner then
            local kind,capacity
            if type(D.rounds_templates)=='number' and at==owner+D.rounds_templates then
                kind,capacity='rounds',D.rounds_capacity
            elseif type(D.reload_templates)=='number' and at==owner+D.reload_templates then
                kind,capacity='reload',D.reload_capacity
            end
            if kind and type(capacity)=='number' and capacity>0 and capacity<=2048 and
               capacity%1==0 and p+capacity*16<0x800000000000 then
                -- Reading the pointer again begins a fresh scan, including when
                -- both template families happen to share the same native range.
                for i=#extension_regions,1,-1 do
                    if extension_regions[i].kind==kind then table.remove(extension_regions,i)end
                end
                table.insert(extension_regions,1,{kind=kind,at=p,capacity=capacity})
            end
        end
        return p
    end
    local function global(rva) return ptr(game+rva,true) end
    local function lookup(at,key,limit)
        local h=read(at,20,true)
        local n,empty,mult=u32(h,8),u32(h,12),u32(h,16)
        assert(n<=limit and (n==0 or bit.band(n,n-1)==0),'unsupported_map')
        if n==0 or key==empty or key==INVALID then return nil end
        local p=assert(api.pointer(h),'map_pointer_unavailable')
        for probe=0,math.min(n,128)-1 do
            local slot=(product_low(key,mult)+probe)%n
            local row=read(p+slot*8,8,true)
            local k=u32(row,0)
            if k==key then
                local index=u32(row,4)
                if index~=INVALID then return index end
                return nil
            end
            if k==empty then return nil end
        end
        error('map_probe_limit')
    end
    local batched
    local function checked()
        if not batched then
            batched=GuardBatch.new(guards,api,function(n)
                validation_reads=validation_reads+1;validation_bytes=validation_bytes+n
            end)
        end
        return batched()
    end
    local row={current_weapon='UNKNOWN',current_fire_mode='UNKNOWN',
        action_result='OBSERVATION_ONLY',context_status='unresolved',
        c4_guard_candidate=false,layout_evidence='STATIC_DERIVATION_PENDING_LIVE_VALIDATION'}
    local function finish(reason)
        if not checked() then return nil,'context_changed_during_read' end
        if reason~='c4_context_observed' then row.c4_guard_candidate=false end
        row.context_status=reason;row.memory_reads=actual_reads+validation_reads;row.memory_bytes=actual_bytes+validation_bytes
        return row,nil,extension_result
    end
    local mode=read(global(R.global_mode),0x44,true)
    if u32(mode,8)==0 or u32(mode,0x40)<1 or u32(mode,0x40)>7 then
        return finish('waiting_for_mission')
    end
    local pm=global(R.global_player)
    local counts=read(pm+0x84,8,true)
    assert(u32(counts,0)<=4 and u32(counts,4)<=4,'unsupported_player_counts')
    if u32(counts,0)==0 or u32(counts,4)==0 then return finish('waiting_for_local_player') end
    local player=read(ptr(pm+0xe8,true),24,true)
    if bit.band(player:byte(21),1)==0 then return finish('local_player_not_owned') end
    local unit=u32(read(pm+0x3a8,4,true),0)
    if unit==0x7fff then return finish('waiting_for_avatar') end
    owner=global(R.global_owner)
    local ei=lookup(owner+D.entity_unit_map,unit,1048576)
    if not ei then return finish('avatar_map_missing') end
    assert(ei<262144,'entity_index_limit')
    local entity=read(owner+D.entity_array+ei*24,24,true)
    if resource(entity)~=AVATAR or bit.band(entity:byte(21),1)==0 then
        return finish('avatar_identity_rejected')
    end
    local id=u32(entity,8)
    local avatar=global(R.global_avatar)
    local ai=lookup(avatar+0xf8,id,64)
    local n=u32(read(avatar+0x6c,4,true),0)
    assert(n<=8,'avatar_count_limit')
    if not ai or ai>=n then return finish('avatar_registry_missing') end
    if read(ptr(avatar+0x110+ai*8,true),24,true)~=entity then
        return finish('avatar_registry_mismatch')
    end
    row.local_entity_id=id;row.local_avatar_index=ai
    local inventory=global(R.global_inventory)
    local ii=lookup(inventory+0x28,id,65536)
    local count=u32(read(inventory+0x14,4,true),0)
    assert(count<=4096,'inventory_count_limit')
    if not ii or ii>=count then return finish('inventory_missing') end
    if read(ptr(ptr(inventory+0x40,true)+ii*8,true),24,true)~=entity then
        return finish('inventory_owner_mismatch')
    end
    local state=read(ptr(inventory+0x50,true)+ii*48,48,true)
    row.inventory_words={}
    for i=0,11 do row.inventory_words[tostring(i*4)]=u32(state,i*4) end
    local slot=u32(state,0x1c)
    row.selected_slot=slot
    local offsets={[1]=0,[2]=4,[3]=8,[4]=16,[5]=16,[6]=12}
    if not offsets[slot] then return finish('no_selected_weapon') end
    local weapon_id=u32(state,offsets[slot])
    row.selected_entity_id=weapon_id
    if weapon_id==0 or weapon_id==INVALID then return finish('selected_entity_missing') end
    local wi=lookup(owner+D.entity_id_map,weapon_id,1048576)
    if not wi then return finish('selected_entity_missing') end
    assert(wi<262144,'weapon_entity_index_limit')
    local weapon=read(owner+D.entity_array+wi*24,24,true)
    if u32(weapon,8)~=weapon_id then return finish('selected_entity_mismatch') end
    local hash=resource(weapon)
    row.current_weapon_resource=hash
    row.current_weapon=hash==DETONATOR and 'C4_DETONATOR' or hash==CHARGE and 'C4_CHARGE' or 'OTHER'
    row.weapon_owned=bit.band(weapon:byte(21),1)~=0
    row.c4_guard_candidate=hash==DETONATOR and row.weapon_owned


    if not row.c4_guard_candidate then return finish('selected_weapon_observed') end

    local wd=global(R.global_weapon_data)
    local di=lookup(wd+0x30,weapon_id,65536)
    local dn=u32(read(wd+0x1c,4,true),0)
    assert(dn<=4096,'weapon_data_count_limit')
    if di and di<dn then
        if read(ptr(ptr(wd+0x48,true)+di*8,true),24,true)~=weapon then
            return finish('weapon_data_owner_mismatch')
        end
        local base=ptr(wd+0x58,true)+di*D.weapon_data_stride
        local types=read(base+D.weapon_types,16,true)
        local packed=read(ptr(wd+0x60,true)+di*12,12,true)
        row.weapon_state_12=hex(packed)
        row.weapon_state_flags=hex(read(ptr(wd+0x50,true)+di*2,2,true))
        row.weapon_function_types={};row.weapon_function_values={}
        local shifts={[1]=4,[7]=0,[8]=2,[9]=6,[10]=8,[11]=10,[12]=14}
        for i=0,3 do
            local k=u32(types,i*4)
            row.weapon_function_types[tostring(i)]=k
            if shifts[k] then
                row.weapon_function_values[tostring(i)]=bit.band(bit.rshift(u32(packed,4),shifts[k]),3)
            end
        end
    else row.weapon_data_status='missing' end



    -- Only an exact private read-only fire-maintenance consumer may omit
    -- diagnostic templates. Ordinary snapshots/actions retain all original reads.
    if not omit_templates then
    local templates=ptr(owner+D.ability_templates,true)
    local start=0
    for b=8,1,-1 do start=(start*256+weapon:byte(b))%D.ability_capacity end
    row.ability_template_status='absent'
    -- Fresh, scan-local blocks only. Unvisited slots never become guards.
    -- Extra unreadable bytes/short results/reader exceptions fall back to
    -- the original individual reads for the rest of this scan. Logical
    -- snapshot bounds still count every original visited 16-byte field.
    local block,block_slot,block_count
    local individual=false
    for probe=0,D.ability_capacity-1 do
        local slot=(start+probe)%D.ability_capacity
        if not individual and (not block or slot<block_slot or slot>=block_slot+block_count) then
            block_slot=slot
            block_count=math.min(16,D.ability_capacity-slot,D.ability_capacity-probe,768-reads)
            local at=templates+slot*16;local n=block_count*16
            if block_count>1 and bytes+16<=32768 and type(at)=='number' and at>=65536 and at+n<0x800000000000 then
                actual_reads=actual_reads+1;actual_bytes=actual_bytes+n
                local ok,value=pcall(api.read,at,n)
                if ok and type(value)=='string' and #value==n then block=value
                else individual=true;block=nil end
            else individual=true;block=nil end
        end
        local t=read(templates+slot*16,16,true,
            block and block:sub((slot-block_slot)*16+1,(slot-block_slot+1)*16) or nil)
        local key=resource(t)
        if key=='0000000000000000' then break end
        if key==hash then
            local ti=u32(t,8)
            assert(ti<D.ability_capacity,'ability_template_index_limit')
            local config=read(templates+D.ability_capacity*16+ti*0x58,0x58,true)
            row.ability_template_status='present';row.ability_template_hex=hex(config)
            row.ability_descriptors={}
            for i=0,1 do
                local o=i*40
                row.ability_descriptors[tostring(i)]={weapon_ability_id=u32(config,o),
                    owner_ability_id=u32(config,o+4),other_ability_id=u32(config,o+8),
                    flag_32=config:byte(o+33),flag_33=config:byte(o+34)}
            end
            break
        end
    end
    end
    if extend then



        extension_regions={}
        local ok,result=pcall(extend,{read=read,ptr=ptr,global=global,lookup=lookup,
            checked=checked,u32=u32,hex=hex,resource=resource,entity=entity,weapon=weapon,
            id=id,weapon_id=weapon_id,owner=owner,avatar=avatar,avatar_index=ai,
            weapon_data=wd,weapon_data_index=di},row)
        extension_regions=nil
        if ok then
            extension_result=result;row.action_context_status='validated'
        else
            extension_result=nil;row.action_context_status='rejected'
            row.action_diagnostic=tostring(result)
            row.action_context_error=row.action_diagnostic:match(':%d+: (.*)$') or row.action_diagnostic
            row.action_gate='ACTION_CONTEXT_REJECTED'
        end
    end
    return finish('c4_context_observed')
end
return M

end)()

    local replacement=ContextReader.snapshot
    local captured={}
    for i=1,32 do
        local name,value=debug.getupvalue(original,i);if not name then break end
        captured[name]={index=i,value=value}
    end
    assert(type(captured.R)=='table' and type(captured.R.value)=='table' and
           type(captured.D)=='table' and type(captured.D.value)=='table','context_layout_not_ready')
    -- Share the original upvalue cells, including dynamic R/D and helpers.
    -- No polling, stale layout copies, or replacement of another mod's helpers.
    for i=1,32 do
        local name=debug.getupvalue(replacement,i);if not name then break end
        if name~='GuardBatch' and name~='omit_templates' then
            local entry=assert(captured[name],'context_upvalue_missing:'..name)
            debug.upvaluejoin(replacement,i,original,entry.index)
        end
    end
    return replacement
end
function C4Context.attach(target)
    if not cfg.enabled or not cfg.c4_context_batch or type(target)~='table' or
       getmetatable(target) or type(debug.upvaluejoin)~='function' or
       is_excluded('mods/etxp/c4_boundary_probe',excludes) then return false end
    local original=rawget(target,'snapshot')
    if type(original)~='function' or
       function_chunk(original):gsub('%.lua$','')~='mods/etxp/c4_boundary_probe' then return false end
    local length,hash=C4Batch.signature(original)
    if not ((length==6667 and hash==1783324827) or (length==6435 and hash==2083852633)) then
        return false
    end
    local ok,replacement=pcall(C4Context.make_reader,original)
    if not ok then log('C4 context batch: unsupported capture; unchanged');return false end
    C4Context.records[target]={original=original,replacement=replacement}
    rawset(target,'snapshot',replacement);C4Context.active=1
    log('C4 context batch: active (verified original snapshot; fresh checks, scan-local template blocks, native actions preserved)')
    return true
end
function C4Context.restore()
    for target,record in pairs(C4Context.records)do
        if rawget(target,'snapshot')==record.replacement then rawset(target,'snapshot',record.original)end
        C4Context.records[target]=nil
    end
    C4Context.active=0
    GuardBatch.clear_plans()
end
-- END C4 CONTEXT BATCH

-- BEGIN C4 UI SCOPE
-- The verified NativeUiGuard consumer only uses two avatar flags. Keep its
-- native UI-stack reader intact; do not build an action/ammo capability here.
-- Every mission/player/avatar/selected-C4 guard is read and validated fresh.
local C4UI={records={},active=0,attempts=0}
M.c4_ui_scope=C4UI
local function ui_upvalue(fn,wanted)
    for i=1,64 do
        local name,value=debug.getupvalue(fn,i);if not name then break end
        if name==wanted then return value,i end
    end
end
function C4UI.make_scope_reader(original)
    local R,D,u32,resource,hex,product_low,bit,AVATAR,DETONATOR,INVALID
    local function snapshot(api,game,extend)
        local guards,reads,bytes={},0,0
        local validation_reads,validation_bytes=0,0
        local function read(at,n,guard)
            assert(type(at)=='number' and at>=65536 and at+n<0x800000000000,'invalid_address')
            reads=reads+1;bytes=bytes+n
            assert(n>0 and n<=4096 and reads<=768 and bytes<=32768,'snapshot_budget')
            local b=assert(api.read(at,n),'read_unavailable')
            assert(#b==n,'short_read')
            if guard then guards[#guards+1]={at=at,bytes=b}end
            return b
        end
        local function ptr(at,guard)
            local p=assert(api.pointer(read(at,8,guard)),'pointer_unavailable')
            assert(p>=65536 and p<0x800000000000,'invalid_pointer')
            return p
        end
        local function global(rva)return ptr(game+rva,true)end
        local function lookup(at,key,limit)
            local h=read(at,20,true)
            local n,empty,mult=u32(h,8),u32(h,12),u32(h,16)
            assert(n<=limit and (n==0 or bit.band(n,n-1)==0),'unsupported_map')
            if n==0 or key==empty or key==INVALID then return nil end
            local p=assert(api.pointer(h),'map_pointer_unavailable')
            for probe=0,math.min(n,128)-1 do
                local row=read(p+((product_low(key,mult)+probe)%n)*8,8,true)
                local k=u32(row,0)
                if k==key then
                    local index=u32(row,4)
                    return index~=INVALID and index or nil
                end
                if k==empty then return nil end
            end
            error('map_probe_limit')
        end
        local validate
        local function checked()
            if not validate then
                validate=GuardBatch.new(guards,api,function(n)
                    validation_reads=validation_reads+1;validation_bytes=validation_bytes+n
                    assert(validation_reads<=768 and validation_bytes<=32768,'snapshot_validation_budget')
                end)
            end
            return validate()
        end
        local function finish(extra)
            if not checked()then return nil,'context_changed_during_read'end
            return {},nil,extra
        end
        local mode=read(global(R.global_mode),0x44,true)
        if u32(mode,8)==0 or u32(mode,0x40)<1 or u32(mode,0x40)>7 then return finish()end
        local pm=global(R.global_player)
        local counts=read(pm+0x84,8,true)
        assert(u32(counts,0)<=4 and u32(counts,4)<=4,'unsupported_player_counts')
        if u32(counts,0)==0 or u32(counts,4)==0 then return finish()end
        local player=read(ptr(pm+0xe8,true),24,true)
        if bit.band(player:byte(21),1)==0 then return finish()end
        local unit=u32(read(pm+0x3a8,4,true),0)
        if unit==0x7fff then return finish()end
        local owner=global(R.global_owner)
        local ei=lookup(owner+D.entity_unit_map,unit,1048576)
        if not ei then return finish()end
        assert(ei<262144,'entity_index_limit')
        local entity=read(owner+D.entity_array+ei*24,24,true)
        if resource(entity)~=AVATAR or bit.band(entity:byte(21),1)==0 then return finish()end
        local id=u32(entity,8)
        local avatar=global(R.global_avatar)
        local ai=lookup(avatar+0xf8,id,64)
        local n=u32(read(avatar+0x6c,4,true),0)
        assert(n<=8,'avatar_count_limit')
        if not ai or ai>=n then return finish()end
        if read(ptr(avatar+0x110+ai*8,true),24,true)~=entity then return finish()end
        local inventory=global(R.global_inventory)
        local ii=lookup(inventory+0x28,id,65536)
        local count=u32(read(inventory+0x14,4,true),0)
        assert(count<=4096,'inventory_count_limit')
        if not ii or ii>=count then return finish()end
        if read(ptr(ptr(inventory+0x40,true)+ii*8,true),24,true)~=entity then return finish()end
        local state=read(ptr(inventory+0x50,true)+ii*48,48,true)
        local slot=u32(state,0x1c)
        local offsets={[1]=0,[2]=4,[3]=8,[4]=16,[5]=16,[6]=12}
        if not offsets[slot]then return finish()end
        local weapon_id=u32(state,offsets[slot])
        if weapon_id==0 or weapon_id==INVALID then return finish()end
        local wi=lookup(owner+D.entity_id_map,weapon_id,1048576)
        if not wi then return finish()end
        assert(wi<262144,'weapon_entity_index_limit')
        local weapon=read(owner+D.entity_array+wi*24,24,true)
        if u32(weapon,8)~=weapon_id or resource(weapon)~=DETONATOR or
            bit.band(weapon:byte(21),1)==0 then return finish()end
        local extra=extend({read=read,avatar=avatar,avatar_index=ai})
        return finish(extra)
    end
    for i=1,32 do
        local name=debug.getupvalue(snapshot,i);if not name then break end
        if name~='GuardBatch' then
            local _,slot=ui_upvalue(original,name)
            assert(slot,'ui_scope_upvalue_missing:'..name)
            debug.upvaluejoin(snapshot,i,original,slot)
        end
    end
    return snapshot
end
function C4UI.attach(target)
    if not cfg.enabled or not cfg.c4_context_batch or type(target)~='function' or
        type(debug.upvaluejoin)~='function' or is_excluded('mods/etxp/c4_boundary_probe',excludes) or
        function_chunk(target):gsub('%.lua$','')~='mods/etxp/c4_boundary_probe' then return false end
    local owned=C4UI.records[target]
    if owned then
        local _,value=debug.getupvalue(target,owned.slot)
        if value==owned.replacement then return true end
    end
    local length,hash=C4Batch.signature(target)
    if not ((length==1108 and hash==589953478) or (length==927 and hash==52868270))then return false end
    local original,slot=ui_upvalue(target,'avatar_ui')
    if type(original)~='function' or
        function_chunk(original):gsub('%.lua$','')~='mods/etxp/c4_boundary_probe' then return false end
    length,hash=C4Batch.signature(original)
    if not ((length==352 and hash==2875083371) or (length==311 and hash==1218919096))then return false end
    local initial_base=ui_upvalue(original,'base')
    if type(initial_base)~='table' or getmetatable(initial_base)then return false end
    local record=C4Context.records[initial_base]
    local current=rawget(initial_base,'snapshot')
    local full=record and current==record.replacement and record.original or current
    if type(full)~='function' or
        function_chunk(full):gsub('%.lua$','')~='mods/etxp/c4_boundary_probe' then return false end
    length,hash=C4Batch.signature(full)
    if not ((length==6667 and hash==1783324827) or (length==6435 and hash==2083852633))then return false end
    local ok,scope=pcall(C4UI.make_scope_reader,full)
    if not ok then return false end
    local api,game,base,AvatarFlags,D
    local function replacement()
        local context=C4Context.records[initial_base]
        local method=type(base)=='table' and rawget(base,'snapshot')
        if not cfg.enabled or not cfg.c4_context_batch or
            is_excluded('mods/etxp/c4_boundary_probe',excludes) or base~=initial_base or
            not (method==full or context and method==context.replacement) then return original()end
        local success,_,_,extra=pcall(scope,api,game,function(e)
            local flags=e.read(e.avatar+0x53e880+e.avatar_index*0x1238,24,true)
            return {tactical_map_active=AvatarFlags.has(flags,D.tactical_map),
                weapon_menu_active=AvatarFlags.has(flags,D.weapon_menu)}
        end)
        return success and extra or {}
    end
    for i=1,32 do
        local name=debug.getupvalue(replacement,i);if not name then break end
        if name=='api' or name=='game' or name=='base' or name=='AvatarFlags' or name=='D'then
            local _,index=ui_upvalue(original,name);if not index then return false end
            debug.upvaluejoin(replacement,i,original,index)
        end
    end
    debug.setupvalue(target,slot,replacement)
    C4UI.records[target]={original=original,replacement=replacement,slot=slot}
    C4UI.active=C4UI.active+1
    log('C4 UI scope: active (fresh identity and map/menu flags; complete native UI stack retained)')
    return true
end
function C4UI.restore()
    for target,record in pairs(C4UI.records)do
        local _,value=debug.getupvalue(target,record.slot)
        if value==record.replacement then debug.setupvalue(target,record.slot,record.original)end
        C4UI.records[target]=nil
    end
    C4UI.active=0;C4UI.attempts=0
end
-- END C4 UI SCOPE

-- BEGIN C4 FIRE SCOPE
-- Existing identical MUTED leases need no diagnostic ability template table.
-- Original sync/stop and every new acquisition/write remain authoritative.
local C4FireScope={records={},active=0,attempts=0}
M.c4_fire_scope=C4FireScope
function C4FireScope.attach(target)
    if not cfg.enabled or not cfg.c4_context_batch or type(target)~='table' or getmetatable(target)or
        type(debug.upvaluejoin)~='function' or is_excluded('mods/etxp/c4_boundary_probe',excludes)then return false end
    local owned=C4FireScope.records[target]
    if owned then
        local _,value=debug.getupvalue(owned.sync,owned.slot)
        if rawget(target,'sync')==owned.sync and value==owned.replacement then return true end
        return false
    end
    local sync=rawget(target,'sync')
    if type(sync)~='function' or function_chunk(sync):gsub('%.lua$','')~='mods/etxp/c4_boundary_probe'then return false end
    local n,h=C4Batch.signature(sync)
    if not ((n==1133 and h==1142545934) or (n==1086 and h==1564724374))then return false end
    local original,slot=ui_upvalue(sync,'current')
    n,h=C4Batch.signature(original)
    if not ((n==1260 and h==115342007) or (n==1187 and h==3325092559))then return false end
    local initial_base=ui_upvalue(original,'base')
    if type(initial_base)~='table' or getmetatable(initial_base)then return false end
    local own_context=C4Context.records[initial_base]
    local method=rawget(initial_base,'snapshot')
    local full=own_context and method==own_context.replacement and own_context.original or method
    n,h=C4Batch.signature(full)
    if not ((n==6667 and h==1783324827) or (n==6435 and h==2083852633))then return false end
    local self=ui_upvalue(sync,'self')
    if self~=target then return false end
    local known_stop=rawget(target,'stop')
    n,h=C4Batch.signature(known_stop)
    if not (n==443 and (h==3472837248 or h==3092073073))then return false end
    local ok,snapshot=pcall(C4Context.make_reader,full,true)
    if not ok then return false end
    local base,api,game,R,NORMAL,MUTED
    local function lean_current()
        return snapshot(api,game,function(e,row)
            local wm=e.global(R.global_weapon)
            local wi=assert(e.lookup(wm+0x28,e.weapon_id,65536),'fire_gate_component_missing')
            assert(wi<4096,'fire_gate_index_limit')
            assert(e.read(e.ptr(e.ptr(wm+0x40,true)+wi*8,true),24,true)==e.weapon,'fire_gate_registry_mismatch')
            local address=e.ptr(wm+0x50,true)+wi*40
            local flags=e.u32(e.read(address,4,true),0)
            row.weapon_driver_flags=string.format('%08x',flags)
            assert(flags==NORMAL or flags==MUTED,'fire_gate_unsupported_flags')
            local driver=e.global(R.global_fire_latch)
            local di=assert(e.lookup(driver+0x20,e.weapon_id,65536),'fire_gate_driver_missing')
            assert(di<4096,'fire_gate_driver_index_limit')
            assert(e.read(e.ptr(e.ptr(driver+0x38,true)+di*8,true),24,true)==e.weapon,'fire_gate_driver_identity_mismatch')
            local held=e.read(e.ptr(driver+0x48,true)+di*8,1,true):byte()~=0
            return {weapon_id=e.weapon_id,weapon=e.weapon,owner=e.owner,manager=wm,
                address=address,flags=flags,held=held,same=e.checked,
                identity=table.concat({e.hex(e.entity),e.hex(e.weapon),tostring(e.owner)},':')}
        end)
    end
    for i=1,32 do local name=debug.getupvalue(lean_current,i);if not name then break end
        if name~='snapshot'then
            local _,index=ui_upvalue(original,name)
            if not index then return false end
            debug.upvaluejoin(lean_current,i,original,index)
        end
    end
    -- Remember current's collaborators; any later capture change selects the
    -- complete original current, rather than applying a partial unknown path.
    local captures={}
    for i=1,32 do local name,value=debug.getupvalue(original,i);if not name then break end
        captures[i]={value=value}
    end
    local binding
    local function replacement()
        local lease=rawget(target,'lease')
        if C4FireScope.records[target]~=binding or not lease or not cfg.enabled or not cfg.c4_context_batch or
            is_excluded('mods/etxp/c4_boundary_probe',excludes) or
            rawget(target,'sync')~=sync or rawget(target,'stop')~=known_stop or
            ui_upvalue(sync,'self')~=target then return original()end
        for i,entry in ipairs(captures)do
            local _,current=debug.getupvalue(original,i)
            if current~=entry.value then return original()end
        end
        local context=C4Context.records[initial_base]
        local current=rawget(initial_base,'snapshot')
        if not (current==full or context and current==context.replacement and context.original==full)then
            return original()
        end
        local ok,row,why,plan=pcall(lean_current)
        if ok and plan and rawget(target,'lease')==lease and plan.identity==lease.identity and plan.flags==MUTED then
            -- Original sync cannot acquire a new lease on this unchanged owned
            -- branch. Every acquisition, identity change or failure uses full.
            return row,why,plan
        end
        return original()
    end
    -- MUTED is shared with the authoritative current, even across layout reload.
    local _,muted_slot=ui_upvalue(original,'MUTED')
    for i=1,32 do local name=debug.getupvalue(replacement,i);if not name then break end
        if name=='MUTED'then debug.upvaluejoin(replacement,i,original,muted_slot)end
    end
    binding={sync=sync,slot=slot,original=original,replacement=replacement}
    C4FireScope.records[target]=binding
    debug.setupvalue(sync,slot,replacement)
    C4FireScope.active=C4FireScope.active+1
    log('C4 fire scope: active (owned identical fire lease omits diagnostic templates; acquisition/restore/actions stay original)')
    return true
end
function C4FireScope.restore()
    for target,record in pairs(C4FireScope.records)do
        local _,value=debug.getupvalue(record.sync,record.slot)
        if value==record.replacement then debug.setupvalue(record.sync,record.slot,record.original)end
        C4FireScope.records[target]=nil
    end
    C4FireScope.active=0;C4FireScope.attempts=0
end
-- END C4 FIRE SCOPE

-- BEGIN C4 IDLE BATCH
-- C4 AutoReload suspend/recovery contracts, under the MIT notice above.
-- No native data caching and no skipped C4 callbacks: cancel/reset always runs.
local C4Idle={records={},active=0}
M.c4_idle_batch=C4Idle
function C4Idle.make(original)
    local captures={}
    for i=1,16 do
        local name,value=debug.getupvalue(original,i);if not name then break end
        captures[name]={value=value,index=i}
    end
    local backend=assert(captures.backend,'idle_backend_capture').value
    local recovery=assert(captures.recovery,'idle_recovery_capture').value
    local self=assert(captures.self,'idle_self_capture').value
    assert(type(backend)=='table' and type(recovery)=='table' and type(self)=='table','idle_capture_type')
    local snapshots,snapshot_slot
    for i=1,16 do
        local name,value=debug.getupvalue(backend.snapshot,i);if not name then break end
        if name=='snapshots' then snapshots=value;snapshot_slot=i;break end
    end
    local function supported(fn,modern_length,modern_hash,game_length,game_hash)
        if type(fn)~='function' or function_chunk(fn):gsub('%.lua$','')~='mods/etxp/c4_boundary_probe' then return false end
        local length,hash=C4Batch.signature(fn)
        return length==modern_length and hash==modern_hash or length==game_length and hash==game_hash
    end
    assert(supported(recovery.observe,1061,1859309885,1038,3104295201),'idle_recovery_unsupported')
    assert(supported(backend.snapshot,37,1207567830,37,1188365773),'idle_backend_unsupported')
    assert(type(snapshots)=='table' and supported(snapshots.snapshot,261,1286216546,261,1151474522),'idle_phase_unsupported')
    local observed_recovery,observer_slot
    for i=1,16 do
        local name,value=debug.getupvalue(recovery.observe,i);if not name then break end
        if name=='self' then observed_recovery=value;observer_slot=i;break end
    end
    assert(observed_recovery==recovery,'idle_recovery_state_changed')
    local known={backend=backend,recovery=recovery,self=self,observe=recovery.observe,
        snapshot=backend.snapshot,phases=snapshots,phase_snapshot=snapshots.snapshot}
    local function replacement(now)
        if not cfg.enabled or not cfg.c4_idle_batch or
           is_excluded('mods/etxp/c4_boundary_probe',excludes) or
           backend~=known.backend or recovery~=known.recovery or self~=known.self or
           backend.snapshot~=known.snapshot or recovery.observe~=known.observe or
           snapshots~=known.phases or snapshots.snapshot~=known.phase_snapshot or
           observed_recovery~=recovery or recovery.pending~=nil then
            return original(now)
        end
        -- observe() returns immediately without pending recovery. Only the
        -- read-only snapshot was redundant; preserve the original cancellation.
        self.cancel('controls_suspended',true)
    end
    for i=1,32 do
        local name=debug.getupvalue(replacement,i);if not name then break end
        if name=='backend' or name=='recovery' or name=='self' then
            debug.upvaluejoin(replacement,i,original,captures[name].index)
        elseif name=='snapshots' then
            debug.upvaluejoin(replacement,i,known.snapshot,snapshot_slot)
        elseif name=='observed_recovery' then
            debug.upvaluejoin(replacement,i,known.observe,observer_slot)
        end
    end
    return replacement
end
function C4Idle.attach(target)
    if not cfg.enabled or not cfg.c4_idle_batch or type(target)~='table' or getmetatable(target) or
       type(debug.upvaluejoin)~='function' or is_excluded('mods/etxp/c4_boundary_probe',excludes) then return false end
    local original=rawget(target,'suspend')
    if type(original)~='function' or function_chunk(original):gsub('%.lua$','')~='mods/etxp/c4_boundary_probe' then return false end
    local length,hash=C4Batch.signature(original)
    if not (length==150 and (hash==417995611 or hash==266935112)) then return false end
    local ok,replacement=pcall(C4Idle.make,original)
    if not ok then log('C4 idle batch: unsupported collaborators; unchanged');return false end
    C4Idle.records[target]={original=original,replacement=replacement}
    rawset(target,'suspend',replacement);C4Idle.active=1
    log('C4 idle batch: active (empty recovery skips read-only snapshot; cancel and pending recovery preserved)')
    return true
end
function C4Idle.restore()
    for target,record in pairs(C4Idle.records)do
        if rawget(target,'suspend')==record.replacement then rawset(target,'suspend',record.original)end
        C4Idle.records[target]=nil
    end
    C4Idle.active=0
end
-- END C4 IDLE BATCH

-- BEGIN C4 NATIVE BATCH
-- Original C4 verification contract, under the MIT notice above.
-- Fresh code bytes on EVERY invocation; no cross-call byte cache or native writes.
local NativeGuards=(function()
-- Prototype: batch fresh native-code guard reads within one verification.
local M={}
function M.make(guards,read)
    local refs,addresses,sizes,plan={},{},{},{}
    local function rebuild()
        local sorted={}
        refs,addresses,sizes,plan={},{},{},{}
        for i,g in ipairs(guards)do
            refs[i]=g;addresses[i]=g.at;sizes[i]=#g.bytes
            sorted[i]={at=g.at,last=g.at+#g.bytes,index=i}
        end
        table.sort(sorted,function(a,b)return a.at<b.at end)
        local groups={}
        for _,g in ipairs(sorted)do
            local last=groups[#groups]
            local finish=math.max(last and last.last or g.last,g.last)
            if last and finish-last.at<=4096 and
               math.floor(last.at/4096)==math.floor((finish-1)/4096)then
                last.last=finish;last.bytes=last.bytes+g.last-g.at
            else
                last={at=g.at,last=g.last,bytes=g.last-g.at};groups[#groups+1]=last
            end
            plan[g.index]=last
        end
        -- Avoid huge copies for isolated small guards on the same page.
        for i,g in ipairs(guards)do
            local p=plan[i]
            if p.last-p.at>math.max(512,p.bytes*16)then
                plan[i]={at=g.at,last=g.at+#g.bytes}
            end
        end
    end
    return function()
        local valid=#refs==#guards
        if valid then for i,g in ipairs(guards)do
            if refs[i]~=g or addresses[i]~=g.at or sizes[i]~=#g.bytes then
                valid=false;break
            end
        end end
        if not valid then rebuild()end
        local data={}
        for i,g in ipairs(guards)do
            local p=plan[i];local n=p.last-p.at;local value
            if p.at==g.at and n==#g.bytes then
                -- Original-field failures keep the original error and order.
                value=read(g.at,n)
            else
                local b=data[p]
                if b==nil then
                    local ok,result=pcall(read,p.at,n)
                    b=ok and type(result)=='string' and #result==n and result or false
                    data[p]=b
                end
                if b then value=b:sub(g.at-p.at+1,g.at-p.at+#g.bytes)
                else value=read(g.at,#g.bytes)end
            end
            assert(value==g.bytes,'compat_live_code_changed:'..g.label)
        end
    end
end
return M

end)()
local C4Native={records={},active=0,guard_batch=NativeGuards}
M.c4_native_batch=C4Native
function C4Native.make_short_reader(original)
    local api_index,game_index,api,game
    for i=1,16 do
        local name,value=debug.getupvalue(original,i)
        if not name then break end
        if name=='api' then api_index,api=i,value
        elseif name=='game' then game_index,game=i,value end
    end
    assert(api_index and game_index and type(api)=='table' and type(game)=='number',
        'native_read_cells_missing')
    local function short(rva,n)
        -- Large guards keep the original multi-chunk reader and its failures.
        if n>4096 then return original(rva,n)end
        assert(rva>=0 and n>0 and rva+n<=0x10000000,'compat_read_bounds')
        local bytes=api.read(game+rva,n)
        if not bytes then
            assert(bytes,'compat_read_unavailable:'..string.format('%x',rva))
        end
        assert(#bytes==n,'compat_short_read')
        -- Preserve concat's rejection of a later reader returning a table.
        if type(bytes)~='string' then return table.concat({bytes})end
        return bytes
    end
    for i=1,16 do
        local name=debug.getupvalue(short,i)
        if not name then break end
        if name=='api' then debug.upvaluejoin(short,i,original,api_index)
        elseif name=='game' then debug.upvaluejoin(short,i,original,game_index)end
    end
    return short
end
function C4Native.make(original,guard_index,read_index,guards,read)
    local observed=read
    local short=C4Native.make_short_reader(read)
    local function bridge(at,n)
        if read==observed then return short(at,n)end
        -- A replacement of the original reader cell must remain authoritative.
        return read(at,n)
    end
    local joined=false
    for i=1,16 do
        local name=debug.getupvalue(bridge,i)
        if not name then break end
        if name=='read' then debug.upvaluejoin(bridge,i,original,read_index);joined=true;break end
    end
    assert(joined,'native_read_bridge_cell_missing')
    local previous=guards
    local batch=NativeGuards.make(guards,bridge)
    local function replacement()
        if guards~=previous then
            batch=NativeGuards.make(guards,bridge);previous=guards
        end
        return batch()
    end
    for i=1,16 do
        local name=debug.getupvalue(replacement,i)
        if not name then break end
        if name=='guards' then debug.upvaluejoin(replacement,i,original,guard_index);return replacement end
    end
    error('native_guard_upvalue_missing')
end
function C4Native.attach(target)
    if not cfg.enabled or not cfg.c4_native_batch or type(target)~='table' or getmetatable(target) or
       type(debug.upvaluejoin)~='function' or is_excluded('mods/etxp/c4_boundary_probe',excludes) then return false end
    local original=rawget(target,'verify')
    if type(original)~='function' or type(rawget(target,'symbols'))~='table' or
       type(rawget(target,'fields'))~='table' or
       function_chunk(original):gsub('%.lua$','')~='mods/etxp/c4_boundary_probe' then return false end
    local length,hash=C4Batch.signature(original)
    if length~=166 or (hash~=637608044 and hash~=369369163)then return false end
    local guard_index,read_index,guards,read
    for i=1,16 do
        local name,value=debug.getupvalue(original,i);if not name then break end
        if name=='guards' then guard_index,guards=i,value
        elseif name=='read' then read_index,read=i,value end
    end
    if type(guards)~='table' or getmetatable(guards) or type(read)~='function' then return false end
    local n,h=C4Batch.signature(read)
    if n~=374 or (h~=3102229121 and h~=2000372290)then return false end
    local ok,replacement=pcall(C4Native.make,original,guard_index,read_index,guards,read)
    if not ok then return false end
    C4Native.records[target]={original=original,replacement=replacement}
    rawset(target,'verify',replacement);C4Native.active=C4Native.active+1
    log('C4 native batch: active (verified original code guards; fresh checks and short-read allocation reduction)')
    return true
end
function C4Native.restore()
    for target,record in pairs(C4Native.records)do
        if rawget(target,'verify')==record.replacement then rawset(target,'verify',record.original)end
        C4Native.records[target]=nil
    end
    C4Native.active=0
end
-- END C4 NATIVE BATCH

-- BEGIN C4 INPUT SCOPE
-- Bound code verification to native calls actually made by owned input
-- maintenance. Dynamic snapshots/masks/policies remain fresh every invocation.
-- Native acquisition, restoration and actions always retain full verification.
local C4InputScope={records={},active=0,attempts=0}
M.c4_input_scope=C4InputScope
local function input_up(fn,wanted)
    for i=1,64 do local name,value=debug.getupvalue(fn,i);if not name then break end
        if name==wanted then return value,i end
    end
end
local function input_signature(fn,length,modern,game)
    if type(fn)~='function' or function_chunk(fn):gsub('%.lua$','')~='mods/etxp/c4_boundary_probe'then return false end
    local n,h=C4Batch.signature(fn);return n==length and (h==modern or h==game)
end
function C4InputScope.mapping_check(resolved)
    local record=C4Native.records[resolved];assert(record,'input_scope_native_adapter_missing')
    local original=record.original
    local guards,guard_slot=input_up(original,'guards')
    local reader,read_slot=input_up(original,'read')
    assert(type(guards)=='table' and type(reader)=='function','input_scope_guards_missing')
    local initial_guards,initial_read=guards,reader
    local short=C4Native.make_short_reader(reader)
    local selected,check={},nil
    local function scoped()
        if guards~=initial_guards or reader~=initial_read then return record.replacement()end
        local indices,mappings,index_switches,mapping_switches=0,0,0,0
        local count=0;local changed=not check
        for _,g in ipairs(guards)do
            local label=g.label
            if type(label)=='string' and (label=='fn_input_index' or label=='fn_input_mapping' or
                label=='fn_input_index:switch_table' or label=='fn_input_mapping:switch_table')then
                count=count+1
                if selected[count]~=g then changed=true end
                selected[count]=g
                if label=='fn_input_index' and #g.bytes==40 then indices=indices+1
                elseif label=='fn_input_mapping' and #g.bytes==974 then mappings=mappings+1
                elseif label=='fn_input_index:switch_table' and #g.bytes==52 then index_switches=index_switches+1
                elseif label=='fn_input_mapping:switch_table' and #g.bytes==40 then mapping_switches=mapping_switches+1
                else return record.replacement()end
            elseif type(label)=='string' and (label:match('^fn_input_index:') or
                label:match('^fn_input_mapping:'))then return record.replacement()
            end
        end
        if count~=5 or indices~=1 or mappings~=1 or index_switches~=1 or mapping_switches~=2 then
            return record.replacement()
        end
        if #selected~=count then changed=true end
        for i=#selected,count+1,-1 do selected[i]=nil end
        if changed then check=NativeGuards.make(selected,short)end
        -- Only membership/plans persist. Native code bytes are read fresh.
        return check()
    end
    for i=1,32 do local name=debug.getupvalue(scoped,i);if not name then break end
        if name=='guards' then debug.upvaluejoin(scoped,i,original,guard_slot)
        elseif name=='reader' then debug.upvaluejoin(scoped,i,original,read_slot)end
    end
    return scoped
end
function C4InputScope.make(target,original)
    assert(input_signature(original,198,3142655543,2800164366),'input_scope_sync_unknown')
    local known_step=input_up(original,'step')
    local length,hash=C4Batch.signature(known_step)
    assert((length==1453 and hash==4103536327) or (length==1436 and hash==2289891480),'input_scope_step_unknown')
    local self=input_up(original,'self');assert(self==target,'input_scope_state_unknown')
    local known_stop=rawget(target,'stop')
    assert(input_signature(known_stop,539,2772262522,1881759314),'input_scope_stop_unknown')
    local known_read=input_up(known_step,'read')
    assert(input_signature(known_read,67,3076458533,3025799190),'input_scope_read_unknown')
    local state=input_up(known_read,'AimInputState')
    assert(type(state)=='table' and not getmetatable(state),'input_scope_reader_unknown')
    local known_policy=rawget(state,'policy')
    assert(input_signature(known_policy,615,1364621487,3459610720),'input_scope_policy_unknown')
    local state_record=C4Batch.records[state]
    local current_read=rawget(state,'read')
    local state_read=state_record and current_read==state_record.replacement and state_record.original or current_read
    local n,h=C4Batch.signature(state_read)
    assert((n==2920 and h==3910151087) or (n==2847 and h==3465483342),'input_scope_state_read_unknown')
    local known_backend=input_up(known_step,'backend')
    local known_verify=rawget(known_backend,'verify')
    assert(input_signature(known_verify,39,1181484356,1161102651),'input_scope_verify_unknown')
    local resolved=input_up(known_verify,'resolved')
    assert(resolved==rawget(known_backend,'compatibility'),'input_scope_compatibility_unknown')
    if not C4Native.records[resolved]then assert(C4Native.attach(resolved),'input_scope_native_unknown')end
    local native_record=C4Native.records[resolved]
    local mapping_verify=C4InputScope.mapping_check(resolved)
    local known_native=input_up(known_step,'native')
    local mapping=rawget(known_native,'input_mapping')
    assert(input_signature(mapping,109,1350766942,1113002286),'input_scope_mapping_unknown')
    local mapping_call=input_up(mapping,'input_mapping')
    local known_spec=input_up(known_step,'spec')
    assert(input_up(known_read,'native')==known_native and input_up(known_read,'spec')==known_spec and
        input_up(known_step,'AimInputState')==state,'input_scope_reader_cells_unknown')
    local backend,spec,profile,publish,read,AimInputState,base,native,D
    local function step(enabled,now)
        if not enabled then
            local ok,why=self.stop();assert(ok,why);publish('inactive');return
        end
        local row,_,cap=backend.snapshot()
        if not cap or cap.interrupt then
            local ok,why=self.stop();assert(ok,why);publish('outside_c4');return
        end
        local codes=spec.fire or profile(now)
        if not codes then
            local ok,why=self.stop();assert(ok,why);publish('unavailable','mbm_assignments_missing');return
        end
        if self.lease and not self.lease.pending then
            if not spec.fire then mapping_verify()end
        else backend.verify()end
        local p=read(codes)
        local suppress,reason=true,'mbm_owns_c4_fire'
        if not spec.fire then suppress,reason=AimInputState.policy(base,p)end
        if self.lease and (self.lease.owner~=p.owner or self.lease.identity~=cap.identity or
            not p.mask or p.mask.bytes~=self.lease.expected)then
            local ok,why=self.stop();assert(ok,why);p=read(codes)
        end
        if not suppress then
            local ok,why=self.stop();assert(ok,why);publish('preserved',reason);return
        end
        if self.lease then publish('owned',reason);return end
        if p.mask and p.mask.mode~=0 then publish('external_inhibition');return end
        if p.held then publish(spec.fire and 'waiting_for_fire_release' or 'waiting_for_aim_release');return end
        assert(p.mask or p.count<D.input_inhibit_capacity,'aim_inhibition_full')
        -- Mismatch/release may have cleared the old lease after scoped checks.
        -- Full verification is mandatory before any new native inhibition.
        backend.verify()
        publish('acquire',reason)
        assert(cap.same() and p.same(),'aim_acquire_context_changed')
        self.lease={owner=p.owner,identity=cap.identity,pending=true}
        native.input_inhibit(p.owner,spec.action)
        local q=read()
        assert(q.owner==p.owner and q.mask and q.mask.mode==1 and
            q.mask.bytes:sub(17,24)==string.rep('\0',8),'aim_acquire_failed')
        self.lease.expected=q.mask.bytes;self.lease.pending=false;publish('owned',reason)
    end
    for i=1,32 do local name=debug.getupvalue(step,i);if not name then break end
        if name~='mapping_verify' then
            local _,slot=input_up(known_step,name);assert(slot,'input_scope_cell_missing:'..name)
            debug.upvaluejoin(step,i,known_step,slot)
        end
    end
    local function replacement(enabled,now)
        local own=C4Batch.records[state]
        local method=rawget(state,'read')
        if not cfg.enabled or not cfg.c4_native_batch or is_excluded('mods/etxp/c4_boundary_probe',excludes) or
            input_up(original,'step')~=known_step or input_up(known_step,'read')~=known_read or
            input_up(known_step,'backend')~=known_backend or input_up(known_step,'native')~=known_native or
            input_up(known_read,'AimInputState')~=state or input_up(known_step,'AimInputState')~=state or
            input_up(known_read,'native')~=known_native or input_up(known_read,'spec')~=known_spec or
            input_up(known_step,'spec')~=known_spec or input_up(mapping,'input_mapping')~=mapping_call or
            self~=target or rawget(target,'stop')~=known_stop or rawget(state,'policy')~=known_policy or
            not (method==state_read or own and method==own.replacement) or
            rawget(known_backend,'verify')~=known_verify or rawget(known_backend,'compatibility')~=resolved or
            input_up(known_verify,'resolved')~=resolved or C4Native.records[resolved]~=native_record or
            not (rawget(resolved,'verify')==native_record.replacement or rawget(resolved,'verify')==native_record.original) or
            rawget(known_native,'input_mapping')~=mapping then return original(enabled,now)end
        local ok,why=pcall(step,enabled,now)
        if not ok then
            local restored,ok,reason=pcall(self.stop)
            publish('unavailable',tostring(why)..((not restored or not ok)and '; restore: '..tostring(reason or ok)or ''))
        end
    end
    for i=1,32 do local name=debug.getupvalue(replacement,i);if not name then break end
        if name=='self' or name=='publish'then
            local _,slot=input_up(original,name);assert(slot,'input_scope_sync_cell_missing:'..name)
            debug.upvaluejoin(replacement,i,original,slot)
        end
    end
    return replacement
end
function C4InputScope.attach(target)
    if not cfg.enabled or not cfg.c4_native_batch or type(target)~='table' or getmetatable(target)or
        type(debug.upvaluejoin)~='function' or is_excluded('mods/etxp/c4_boundary_probe',excludes)then return false end
    local owned=C4InputScope.records[target]
    if owned and rawget(target,'sync')==owned.replacement then return true end
    local original=rawget(target,'sync')
    if not input_signature(original,198,3142655543,2800164366)then return false end
    local ok,replacement=pcall(C4InputScope.make,target,original)
    if not ok then log('C4 input scope: unknown dependency; unchanged: '..tostring(replacement));return false end
    C4InputScope.records[target]={original=original,replacement=replacement}
    rawset(target,'sync',replacement);C4InputScope.active=C4InputScope.active+1
    log('C4 input scope: active (fresh owned-input guards; native acquisition/restore/actions keep full verification)')
    return true
end
function C4InputScope.restore()
    for target,record in pairs(C4InputScope.records)do
        if rawget(target,'sync')==record.replacement then rawset(target,'sync',record.original)end
        C4InputScope.records[target]=nil
    end
    C4InputScope.active=0;C4InputScope.attempts=0
end
-- END C4 INPUT SCOPE

-- BEGIN C4 READ POOL
-- Optional Smooth-owned runtime adapter for the measured C4 1.11 reader.
-- No global FFI proxy, memory cache, native write, guard bypass, or tick skip.
-- The exact original bytecode must match; unfamiliar versions stay untouched.
local C4Pool={records={},attempts=0,active=0}
M.c4_read_pool=C4Pool
local function c4_reader_signature(fn)
    local ok,blob=pcall(string.dump,fn,true)
    if not ok or #blob~=420 then return false end
    local a,b=1,0
    for i=1,#blob do a=(a+blob:byte(i))%65521;b=(b+a)%65521 end
    local checksum=b*65536+a
    -- Same original 1.11 source compiled by LuaJIT 2.1 alpha (game DLL)
    -- or the newer LuaJIT used by the offline regression runner.
    return checksum==1514359016 or checksum==2664974623
end
function C4Pool.make_reader(ffi,rpm,process)
    -- ReadProcessMemory cannot call back into Lua. Each VM is synchronous;
    -- these two private buffers are therefore reused only after a call returns.
    local out,count=ffi.new('uint8_t[4096]'),ffi.new('size_t[1]')
    local cast,string_,number=ffi.cast,ffi.string,tonumber
    local calls=0
    local function pooled(address,size)
        assert(type(address)=='number' and address>=65536 and address+size<0x800000000000,'bad_read_address')
        assert(size>0 and size<=4096,'read_size_limit')
        count[0]=0
        calls=calls+1
        if rpm(process,cast('const void *',address),out,size,count)==0 or
           number(count[0])~=size then return nil end
        return string_(out,size)
    end
    return pooled,function()return calls end
end
-- Opt-in diagnosis only: never replay a read, retain bytes or addresses,
-- or change its result. A prime sampling interval reduces periodic aliasing.
function C4Pool.make_probe(reader)
    local state={calls=0,samples=0,errors=0,sites={}}
    local function capture(size)
        local parts={}
        for level=2,10 do
            local info=debug.getinfo(level,'nSl')
            if not info then break end
            local source=(info.source or ''):match('mods/[%w_./%-]+') or ''
            if source:gsub('%.lua$','')=='mods/etxp/c4_boundary_probe' then
                parts[#parts+1]=(info.name or '?')..':'..tostring(info.currentline)
            end
        end
        local c4=rawget(_G,'HD2C4BoundaryProbe')
        local phase=type(c4)=='table' and rawget(c4,'phase') or 'unknown'
        local site=tostring(phase)..' size='..tostring(size)..' '..table.concat(parts,'>')
        state.sites[site]=(state.sites[site] or 0)+1
        state.samples=state.samples+1
    end
    local function probe(address,size)
        state.calls=state.calls+1
        if state.calls%509==0 then
            if not pcall(capture,size) then state.errors=state.errors+1 end
        end
        return reader(address,size)
    end
    return probe,state
end
function C4Pool.report_probe()
    for _,record in pairs(C4Pool.records) do
        local state=record.profile
        if state then
            local sites={}
            for site,count in pairs(state.sites)do sites[#sites+1]={site=site,count=count}end
            table.sort(sites,function(a,b)return a.count>b.count end)
            local top={}
            for i=1,math.min(6,#sites)do top[#top+1]=sites[i].count..'x '..sites[i].site end
            log('[C4-read-probe] reads='..state.calls..' samples='..state.samples..
                ' errors='..state.errors..' top='..table.concat(top,'; '))
            state.calls=0;state.samples=0;state.errors=0;state.sites={}
        end
    end
end
function C4Pool.attach(api)
    if type(api)~='table' or getmetatable(api)~=nil then return false end
    local existing=C4Pool.records[api]
    if existing and rawget(api,'read')==existing.pooled then return true end
    if not cfg.enabled or (not cfg.c4_read_pool and not cfg.c4_read_profile) then return false end
    local original=rawget(api,'read')
    if type(original)~='function' or
       function_chunk(original):gsub('%.lua$','')~='mods/etxp/c4_boundary_probe' or
       is_excluded('mods/etxp/c4_boundary_probe',excludes) or
       not c4_reader_signature(original) then return false end
    local captured={}
    for i=1,8 do
        local name,value=debug.getupvalue(original,i)
        if not name then break end
        captured[name]=value
    end
    local ffi,k,process=captured.ffi,captured.k,captured.process
    if ffi~=require('ffi') or ffi.os~='Windows' or not ffi.abi('64bit') or
       k==nil or type(process)~='cdata' then return false end
    local rpm=k.ReadProcessMemory
    if type(rpm)~='cdata' then return false end
    local pooled,calls=original,function()return 0 end
    if cfg.c4_read_pool then pooled,calls=C4Pool.make_reader(ffi,rpm,process)end
    local profile
    if cfg.c4_read_profile then pooled,profile=C4Pool.make_probe(pooled)end
    local record={original=original,pooled=pooled,calls=calls,profile=profile,
        profiling=not not cfg.c4_read_profile,pooling=not not cfg.c4_read_pool}
    C4Pool.records[api]=record
    C4Pool.last_original=original
    rawset(api,'read',pooled)
    C4Pool.active=0
    for _ in pairs(C4Pool.records) do C4Pool.active=C4Pool.active+1 end
    log('C4 read pool: active (verified 1.11 reader; live reads and frame callbacks preserved)')
    if profile then log('[C4-read-probe] enabled; sample interval=509; pooled='..tostring(cfg.c4_read_pool))end
    return true
end
function C4Pool.restore()
    for api,record in pairs(C4Pool.records) do
        -- Never overwrite a replacement installed later by C4 or another mod.
        if rawget(api,'read')==record.pooled then rawset(api,'read',record.original) end
        C4Pool.records[api]=nil
    end
    C4Pool.active=0
end
function C4Pool.reads()
    local total=0
    for api,record in pairs(C4Pool.records) do
        if rawget(api,'read')==record.pooled then total=total+record.calls() end
    end
    return total
end
function C4Pool.discover(roots)
    local pool_wanted=cfg.enabled and (cfg.c4_read_pool or cfg.c4_read_profile) and
        not is_excluded('mods/etxp/c4_boundary_probe',excludes)
    local batch_wanted=cfg.enabled and cfg.c4_input_batch and
        not is_excluded('mods/etxp/c4_boundary_probe',excludes)
    local context_wanted=C4Context and cfg.enabled and cfg.c4_context_batch and
        not is_excluded('mods/etxp/c4_boundary_probe',excludes)
    if C4FireScope then
        if not context_wanted and (C4FireScope.active>0 or C4FireScope.attempts>0)then C4FireScope.restore()end
        C4FireScope.active=0
        for target,record in pairs(C4FireScope.records)do
            local _,value=debug.getupvalue(record.sync,record.slot)
            if rawget(target,'sync')==record.sync and value==record.replacement then
                C4FireScope.active=C4FireScope.active+1
            else C4FireScope.records[target]=nil;C4FireScope.attempts=0 end
        end
    end
    local fire_pending=C4FireScope and context_wanted and C4FireScope.active==0 and C4FireScope.attempts<8
    if C4UI then
        if not context_wanted and (C4UI.active>0 or C4UI.attempts>0)then C4UI.restore()end
        C4UI.active=0
        for target,record in pairs(C4UI.records)do
            local _,value=debug.getupvalue(target,record.slot)
            if value==record.replacement then C4UI.active=C4UI.active+1
            else C4UI.records[target]=nil;C4UI.attempts=0 end
        end
    end
    local ui_pending=C4UI and context_wanted and C4UI.active==0 and C4UI.attempts<8
    local native_wanted=C4Native and cfg.enabled and cfg.c4_native_batch and
        not is_excluded('mods/etxp/c4_boundary_probe',excludes)
    if C4InputScope then
        if not native_wanted and (C4InputScope.active>0 or C4InputScope.attempts>0)then
            C4InputScope.restore();log('C4 input scope: disabled; original sync restored')
        end
        C4InputScope.active=0
        for target,record in pairs(C4InputScope.records)do
            if rawget(target,'sync')==record.replacement then C4InputScope.active=C4InputScope.active+1
            else C4InputScope.records[target]=nil;C4InputScope.attempts=0 end
        end
    end
    local scope_pending=C4InputScope and native_wanted and C4InputScope.active<2 and C4InputScope.attempts<8
    local idle_wanted=C4Idle and cfg.enabled and cfg.c4_idle_batch and
        not is_excluded('mods/etxp/c4_boundary_probe',excludes)
    if C4Idle then
        if C4Idle.active>0 and not idle_wanted then
            C4Idle.restore();log('C4 idle batch: disabled; original suspend restored')
        end
        C4Idle.active=0
        for target,record in pairs(C4Idle.records)do
            if rawget(target,'suspend')==record.replacement then C4Idle.active=C4Idle.active+1
            else C4Idle.records[target]=nil;C4Pool.attempts=0 end
        end
    end
    if C4Native then
        if C4Native.active>0 and not native_wanted then
            C4Native.restore();log('C4 native batch: disabled; original verifier restored')
        end
        C4Native.active=0
        for target,record in pairs(C4Native.records)do
            if rawget(target,'verify')==record.replacement then C4Native.active=C4Native.active+1
            else C4Native.records[target]=nil;C4Pool.attempts=0 end
        end
    end
    if C4Context and C4Context.active>0 and not context_wanted then
        C4Context.restore();log('C4 context batch: disabled; original snapshot restored')
    end
    if C4Context then
        C4Context.active=0
        for target,record in pairs(C4Context.records)do
            if rawget(target,'snapshot')==record.replacement then C4Context.active=C4Context.active+1
            else C4Context.records[target]=nil;C4Pool.attempts=0 end
        end
    end
    if C4Batch and C4Batch.active>0 and not batch_wanted then
        C4Batch.restore();log('C4 input batch: disabled; original input reader restored')
    end
    if not cfg.enabled or (not cfg.c4_read_pool and not cfg.c4_read_profile) or
       is_excluded('mods/etxp/c4_boundary_probe',excludes) then
        if C4Pool.active>0 then C4Pool.restore();log('C4 read pool: disabled; original reader restored') end
        C4Pool.attempts=0
        if not batch_wanted and not context_wanted and not native_wanted and not idle_wanted then return end
    end
    for _,record in pairs(C4Pool.records)do
        if record.profiling~=(not not cfg.c4_read_profile) or
           record.pooling~=(not not cfg.c4_read_pool) then
            C4Pool.restore();C4Pool.attempts=0;break
        end
    end
    C4Pool.active=0
    for api,record in pairs(C4Pool.records) do
        if rawget(api,'read')==record.pooled then C4Pool.active=C4Pool.active+1
        else C4Pool.records[api]=nil end
    end
    local core_complete=((not pool_wanted or C4Pool.active>0) and
        (not batch_wanted or C4Batch and C4Batch.active>0) and
        (not context_wanted or C4Context.active>0) and
        (not native_wanted or C4Native.active>0) and
        (not idle_wanted or C4Idle.active>0))
    if (core_complete or C4Pool.attempts>=8) and not ui_pending and not scope_pending and not fire_pending then return end
    local core_last=C4Pool.attempts==7
    C4Pool.attempts=math.min(8,C4Pool.attempts+1)
    if ui_pending then C4UI.attempts=C4UI.attempts+1 end
    if scope_pending then C4InputScope.attempts=C4InputScope.attempts+1 end
    if fire_pending then C4FireScope.attempts=C4FireScope.attempts+1 end
    local pending,seen={},{}
    local function push(value)
        local kind=type(value)
        if (kind=='function' or kind=='table') and not seen[value] and
           value~=_G and value~=package and value~=M and
           value~=rawget(_G,'stingray') and #pending<2048 then
            seen[value]=true;pending[#pending+1]=value
        end
    end
    for _,root in ipairs(roots) do push(root) end
    local at=1
    while at<=#pending do
        local value=pending[at];at=at+1
        if type(value)=='function' then
            local own_chunk=function_chunk(value)
            local is_c4=own_chunk:gsub('%.lua$','')=='mods/etxp/c4_boundary_probe'
            for i=1,64 do
                local name,next_=debug.getupvalue(value,i)
                if not name then break end
                if is_c4 then
                    if fire_pending then C4FireScope.attach(next_)end
                    if scope_pending then C4InputScope.attach(next_)end
                    if ui_pending and name=='native_ui' then C4UI.attach(next_)end
                    if idle_wanted and name=='auto_reload' then C4Idle.attach(next_)end
                    if native_wanted then C4Native.attach(next_)end
                    if name=='AimInputState' and C4Batch and batch_wanted then C4Batch.attach(next_)end
                    if (name=='ContextReader' or name=='reader') and context_wanted then C4Context.attach(next_)end
                    if name=='api' and C4Pool.attach(next_) and
                       (not batch_wanted or C4Batch and C4Batch.active>0) and
                       (not context_wanted or C4Context.active>0) and
                       (not native_wanted or C4Native.active>0) and
                       (not idle_wanted or C4Idle.active>0) and
                       (not ui_pending or C4UI.active>0) and
                       (not scope_pending or C4InputScope.active>=2) and
                       (not fire_pending or C4FireScope.active>0) then return end
                    if name~='engine' and name~='sr' and name~='G' and name~='ffi' then push(next_) end
                elseif type(next_)=='function' and
                       (function_chunk(next_)~=own_chunk or name=='target' or name=='previous' or
                        name=='previous_update' or name=='original_update' or name=='next_update' or
                        name=='base_prev') then
                    push(next_)
                end
            end
        elseif getmetatable(value)==nil then
            if fire_pending then C4FireScope.attach(value)end
            if scope_pending then C4InputScope.attach(value)end
            if native_wanted then C4Native.attach(value)end
            if idle_wanted then C4Idle.attach(value)end
            if context_wanted then C4Context.attach(value)end
            if C4Pool.attach(value) and (not batch_wanted or C4Batch and C4Batch.active>0) and
                       (not context_wanted or C4Context.active>0) and
                       (not native_wanted or C4Native.active>0) and
                       (not idle_wanted or C4Idle.active>0) and
                       (not ui_pending or C4UI.active>0) and
                       (not scope_pending or C4InputScope.active>=2) and
                       (not fire_pending or C4FireScope.active>0) then return end
            local count=0
            for _,next_ in next,value do
                count=count+1;if count>64 then break end
                push(next_)
            end
        end
    end
    if scope_pending and C4InputScope.attempts==8 and C4InputScope.active<2 then
        log('C4 input scope: supported input gates not found; remaining syncs unchanged')
    end
    if fire_pending and C4FireScope.attempts==8 and C4FireScope.active==0 then
        log('C4 fire scope: supported original fire gate not found; unchanged')
    end
    if core_last then
        if idle_wanted and C4Idle.active==0 then log('C4 idle batch: no supported original suspend found; unchanged')end
        if native_wanted and C4Native.active==0 then log('C4 native batch: no supported original verifier found; unchanged')end
        if pool_wanted and C4Pool.active==0 then log('C4 read pool: no supported reader found; no changes made')end
        if context_wanted and C4Context.active==0 then
            log('C4 context batch: no supported original snapshot found; unchanged')
        end
    end
    if ui_pending and C4UI.attempts==8 and C4UI.active==0 then
        log('C4 UI scope: no supported flags-only consumer found; unchanged')
    end
end
-- END C4 READ POOL

-- BEGIN C4 CPU PROFILE
-- Explicit diagnosis only. CPU stacks are sampled across this Lua VM, not just
-- ReadProcessMemory calls. No game inputs, native writes, or foreign config edits.
local C4CPU={running=false,completed=false,samples=0,errors=0,unique=0}
M.c4_cpu_profile=C4CPU
function C4CPU.stop(reason)
    if not C4CPU.running then return end
    C4CPU.running=false
    local ok,err=pcall(C4CPU.backend.stop)
    if not ok then log('[C4-CPU] stop failed: '..tostring(err))end
    local states={}
    for kind,count in pairs(C4CPU.states)do states[#states+1]=kind..'='..count end
    table.sort(states)
    log('[C4-CPU] stopped reason='..tostring(reason)..' samples='..C4CPU.samples..
        ' errors='..C4CPU.errors..' overflow='..C4CPU.overflow..' states='..table.concat(states,','))
    local rows={}
    for stack,count in pairs(C4CPU.stacks)do rows[#rows+1]={stack=stack,count=count}end
    table.sort(rows,function(a,b)return a.count>b.count end)
    for i=1,math.min(20,#rows)do
        log('[C4-CPU] '..rows[i].count..'x '..rows[i].stack)
    end
end
function C4CPU.poll(now)
    local wanted=cfg.enabled and cfg.c4_cpu_profile
    if not wanted then
        C4CPU.stop('config_disabled');C4CPU.completed=false;return
    end
    if C4CPU.running then
        if now>=C4CPU.deadline then C4CPU.stop('45s_deadline')end
        return
    end
    if C4CPU.completed then return end
    C4CPU.completed=true
    local ok,profile=pcall(require,'jit.profile')
    if not ok or type(profile)~='table' or type(profile.start)~='function' or
       type(profile.stop)~='function' or type(profile.dumpstack)~='function' then
        log('[C4-CPU] unavailable; no sampler started');return
    end
    C4CPU.backend=profile;C4CPU.samples=0;C4CPU.errors=0;C4CPU.unique=0
    C4CPU.stacks={};C4CPU.states={};C4CPU.overflow=0;C4CPU.deadline=now+45
    local function sample(thread,n,state)
        if not C4CPU.running then return end
        C4CPU.samples=C4CPU.samples+n
        C4CPU.states[state]=(C4CPU.states[state] or 0)+n
        local good,stack=pcall(profile.dumpstack,thread,'pl;',12)
        if not good or type(stack)~='string' then C4CPU.errors=C4CPU.errors+1;return end
        stack=state..' '..stack:gsub('[\r\n]',' '):sub(1,2400)
        local count=C4CPU.stacks[stack]
        if count then C4CPU.stacks[stack]=count+n
        elseif C4CPU.unique<512 then
            C4CPU.unique=C4CPU.unique+1;C4CPU.stacks[stack]=n
        else C4CPU.overflow=C4CPU.overflow+n end
    end
    C4CPU.running=true
    local started,why=pcall(profile.start,'li5',sample)
    if not started then
        C4CPU.running=false;pcall(profile.stop)
        log('[C4-CPU] start failed: '..tostring(why));return
    end
    log('[C4-CPU] started interval=5ms duration=45s; diagnostic FPS is not acceptance FPS')
end
-- END C4 CPU PROFILE

-- ===== writer hold: splice FFI writer mods off the chain ==============
-- The 0x66d26c crash family: dsh/codex FFI mods write into engine tables
-- exactly while the engine rebuilds them (boot + first mission entry).
-- We cannot intercept their writes (the ffi proxy route is banned), but
-- we own the chain: a writer layer is spliced OUT by retargeting its
-- caller's upvalue to the writer's own previous, and spliced back after
-- writer_hold_s. Their function is preserved (applied later, on a
-- settled game); none of their state fields is ever touched.
local WH={entry=nil,held={},walks=0,done_walking=false,head_swaps=0}
local last_call=os.clock()
local fi_t,fi_n=0,0     -- rolling frame-interval (seconds, pre-declared for the release gate)
local WH_NEXT_NAMES={'previous_update','original_update','previous','prev',
                     'original','old_update','base_update','next_update'}
local function wh_frag_match(name)
    if is_excluded(name,excludes) then return false end
    local list=cfg.writers
    if type(list)~='string' or list=='' then return false end
    for frag in list:gmatch('[%w_./%-]+') do
        if name:find(frag,1,true) then return true end
    end
    return false
end
local function wh_chunk_of(f)
    return function_chunk(f)
end
-- next layer + the slot index in f that holds it; single-function-upvalue
-- fallback, never descending into ourselves
local function wh_next(f)
    local nfuncs,only,onlyidx=0,nil,nil
    local diff,difff,diffi=0,nil,nil
    local i=1
    while true do
        local n,v=debug.getupvalue(f,i)
        if not n then break end
        if type(v)=='function' then
            for _,pat in ipairs(WH_NEXT_NAMES) do
                if n==pat then return v,i end
            end
            if v~=wrapper and v~=f then
                nfuncs=nfuncs+1; only=v; onlyidx=i
                -- different-chunk heuristic: helper closures (tick, scanners)
                -- live in the layer's own chunk; the previous always comes
                -- from an earlier-loaded chunk
                if wh_chunk_of(v)~=wh_chunk_of(f) then
                    diff=diff+1; difff=difff or v; diffi=diffi or i
                end
            end
        end
        i=i+1
    end
    if nfuncs==1 then return only,onlyidx end
    if diff==1 then return difff,diffi end
    return nil,nil
end
local function wh_count()
    local n=0 for _ in pairs(WH.held) do n=n+1 end return n
end
-- writer gate: a closure we own, spliced into the writer's chain slot.
-- Closed: calls the writer's next (bypass semantics - no scan, no write).
-- Open:   calls the writer itself (normal semantics, function preserved).
-- Release is a single flag flip - immune to the watchdog spy storm that
-- rewrites every previous-slot in the chain. The captured 'previous_update'
-- name keeps our own descent walk able to pass through the gate.
local function wh_make_gate(writer,nextfn)
    local previous_update=nextfn
    -- Both gate states must share the same live downstream slot. A profiler
    -- instruments previous_update while the gate is closed; the original
    -- writer must also use that slot after release, rather than bypassing it.
    local writer_next,writer_slot=wh_next(writer)
    assert(writer_next==nextfn and writer_slot,'writer downstream slot missing')
    local function downstream(...) return previous_update(...) end
    debug.setupvalue(writer,writer_slot,downstream)
    local ctl={open=false}
    local busy=false
    local function completed(ok,...)
        busy=false
        if not ok then error((...),0) end
        return ...
    end
    local gate=function(...)
        if busy then
            -- re-entered while still inside ourselves: the chain looped
            -- back (spy reshuffle). Break it here instead of overflowing
            -- the C stack (that is the ntdll crash loop).
            if not ctl._cyc then
                ctl._cyc=true
                log('writer hold: gate cycle detected and broken (chain loop)')
            end
            return
        end
        busy=true
        if ctl.open then
            return completed(pcall(writer,...))
        end
        return completed(pcall(previous_update,...))
    end
    return gate,ctl
end
-- Read-only LuaJIT metadata, never a graphics hook or a call to foreign code.
-- Cache immutable field accesses; inspect mutable closure references afresh.
local HUDProbe={fields=setmetatable({},{__mode='k'})}
do
    local ok,u=pcall(require,'jit.util')
    if ok and type(u)=='table' and type(u.funcbc)=='function' and type(u.funck)=='function'
       and type(u.funcinfo)=='function' then
        local sample=function(t)return t.__smooth_hud_field end
        for pc=1,8 do
            local bc=u.funcbc(sample,pc)
            if not bc then break end
            local c=math.floor(bc/65536)%256
            if u.funck(sample,-c-1)=='__smooth_hud_field' then
                HUDProbe.util,HUDProbe.field_op=u,bc%256;break
            end
        end
    end
end
function HUDProbe.field_reads(fn)
    local cached=HUDProbe.fields[fn]
    if cached then return cached end
    local fields={}
    local u=HUDProbe.util
    if u then
        local ok,info=pcall(u.funcinfo,fn)
        local n=ok and info and info.bytecodes
        if type(n)=='number' and n<=16384 then
            for pc=1,n do
                local bc=u.funcbc(fn,pc)
                if not bc then break end
                if bc%256==HUDProbe.field_op then
                    local key=u.funck(fn,-(math.floor(bc/65536)%256)-1)
                    if type(key)=='string' then fields[key]=true end
                end
            end
        end
    end
    HUDProbe.fields[fn]=fields
    return fields
end
function HUDProbe.apis()
    local sr=rawget(_G,'stingray')
    if type(sr)~='table' then return {} end
    local refs={sr=sr,functions={}}
    local methods={Gui={'text','rect','bitmap','line','triangle','text_3d','triangle_3d','material'},
        LineObject={'add_line','add_sphere','add_box','dispatch'},
        World={'create_screen_gui','create_world_gui','create_line_object'}}
    for name,keys in pairs(methods) do
        local api=rawget(sr,name)
        if type(api)=='table' then
            refs[name]=api
            for _,key in ipairs(keys) do
                local fn=rawget(api,key)
                if type(fn)=='function' then refs.functions[fn]=true end
            end
        end
    end
    return refs
end
function HUDProbe.draws(root,refs)
    if not refs.sr then return false end
    local queue,seen={root},{}
    local at=1
    while at<=#queue and at<=32 do
        local fn=queue[at];at=at+1
        if not seen[fn] then
            seen[fn]=true
            if refs.functions and refs.functions[fn] then return true end
            local fields=HUDProbe.field_reads(fn)
            local gui_method=fields.text or fields.rect or fields.bitmap or fields.line
                or fields.triangle or fields.text_3d or fields.triangle_3d or fields.material
            local line_method=fields.add_line or fields.add_sphere or fields.add_box or fields.dispatch
            local world_method=fields.create_screen_gui or fields.create_world_gui or fields.create_line_object
            if (refs.Gui and fields.Gui and gui_method) or (refs.LineObject and fields.LineObject and line_method)
               or (refs.World and fields.World and world_method) then return true end
            local downstream=wh_next(fn)
            for i=1,64 do
                local key,value=debug.getupvalue(fn,i)
                if not key then break end
                if type(value)=='table' then
                    if (rawequal(value,refs.Gui) and gui_method) or (rawequal(value,refs.LineObject) and line_method)
                       or (rawequal(value,refs.World) and world_method) then return true end
                elseif type(value)=='function' then
                    if refs.functions and refs.functions[value] then return true end
                    if value~=downstream and #queue<32 then queue[#queue+1]=value end
                end
            end
        end
    end
    return false
end

local function refresh_frame_protection()
    local found=detect_ui_mods(cfg.ui_mods)
    local chunks,seen={},{}
    local sources,source_seen,manual={},{},{}
    local automatic={}
    local refs=HUDProbe.apis()
    local render_head=rawget(_G,'render')
    local render_name=function_chunk(render_head)
    if render_name~='' and not render_name:find('mods/codex/smoothboot',1,true) then
        chunks[render_name]=true;found[#found+1]=render_name
        automatic[#automatic+1]=render_name
    end
    local queue={}
    local function add(fn)
        if type(fn)=='function' and not seen[fn] and #queue<128 then
            seen[fn]=true; queue[#queue+1]=fn
        end
    end
    add(rawget(_G,'update')); add(head_above); add(WH.entry or base_prev)
    local at=1
    while at<=#queue and at<=128 do
        local fn=queue[at]; at=at+1
        if fn==wrapper then
            add(head_above); add(WH.entry or base_prev)
        else
            local name=function_chunk(fn)
            local low=name:lower()
            if name~='' and not source_seen[name] then
                source_seen[name]=true;sources[#sources+1]=name
                if is_excluded(name,excludes) then manual[#manual+1]=name end
            end
            if name~='' and not low:find('mods/codex/smoothboot',1,true) and not chunks[name] then
                local drawing=HUDProbe.draws(fn,refs)
                if is_excluded(name,excludes) or drawing then
                    chunks[name]=true;found[#found+1]=name
                    if drawing then automatic[#automatic+1]=name end
                end
            end
            for _,chunk in ipairs(FRAME_CRITICAL_CHUNKS) do
                if (low==chunk or low==chunk..'.lua') and not chunks[name] then
                    chunks[name]=true; found[#found+1]=name
                end
            end
            for frag in (cfg.ui_chunks or 'helmet_cape_passives'):gmatch('[%w_./%-]+') do
                if name:find(frag,1,true) and not chunks[name] then
                    chunks[name]=true; found[#found+1]=name
                end
            end
            add(wh_next(fn))
            -- An update bus stores its previous callback in a plain table.
            -- Inspect known callback fields only; never invoke any callback,
            -- index metamethod or native API during discovery.
            if name:find('mods/',1,true) then
                for i=1,64 do
                    local key,value=debug.getupvalue(fn,i)
                    if not key then break end
                    if type(value)=='table' and getmetatable(value)==nil and value~=_G
                       and value~=package and value~=rawget(_G,'stingray') then
                        for _,field in ipairs(WH_NEXT_NAMES) do add(rawget(value,field)) end
                        add(rawget(value,'base')); add(rawget(value,'target'))
                        local jobs=rawget(value,'jobs')
                        if type(jobs)=='table' and getmetatable(jobs)==nil then
                            local count=0
                            for _,job in next,jobs do
                                count=count+1; if count>64 then break end
                                add(job)
                            end
                        end
                    end
                end
            end
        end
    end
    M.discovered_sources=sources
    M.excluded_below=manual
    M.auto_hud_sources=automatic
    if M.frag_check then pcall(M.frag_check) end
    table.sort(found)
    M.protected_sources=found
    local protected=#found>0
    local signature=table.concat(found,',')
    if protected~=ui_present or signature~=M._protection_signature then
        ui_present=protected
        M._protection_signature=signature
        if protected then
            log('frame-critical callbacks present ('..table.concat(found,',')..') - chain skipping and pausing suspended')
        else
            log('no frame-critical callbacks - automatic throttling allowed')
        end
    end
end
M.find_excluded_below=function()
    if M.discovered_sources then
        local names={}
        for _,name in ipairs(M.discovered_sources) do
            if is_excluded(name,excludes) then names[#names+1]=name end
        end
        return names
    end
    local cur=head_above or WH.entry or base_prev
    local seen,names,added={},{},{}
    for depth=1,128 do
        if type(cur)~='function' or seen[cur] then break end
        seen[cur]=true
        local name=function_chunk(cur)
        if name~='' and is_excluded(name,excludes) and not added[name] then
            added[name]=true;names[#names+1]=name
        end
        if cur==wrapper then cur=WH.entry or base_prev else cur=wh_next(cur) end
    end
    return names
end
-- full-chain writer interdiction: every couple of seconds, walk the LIVE
-- chain from whatever head the engine currently calls, down through
-- ourselves, to the game bottom. Any layer whose chunk matches the writer
-- list is spliced OUT of the chain via its caller's upvalue slot and held
-- for good: it never runs, so it never scans, so it never writes. Everyone
-- else -- including mods above us -- keeps ticking normally. The writers'
-- own wrappers and state stay intact; only their per-frame calls stop.
local function wh_full_walk()
    if WH.done_walking then return end
    -- start at the TRUE top: an adopted head sits above _G.update (the
    -- adopt machinery keeps update==wrapper), so it must be the walk start
    local cur=head_above or rawget(_G,'update')
    if type(cur)~='function' or cur==wrapper then return end
    local caller,slot=nil,nil   -- who calls cur; nil = the engine calls it
    local visited={}
    local caught=0
    local depth=0
    while type(cur)=='function' and depth<96 do
        depth=depth+1
        if visited[cur] then break end
        visited[cur]=true
        if cur==wrapper then
            -- bridge through ourselves into our below-segment; base_prev
            -- itself has no upvalue slot in us, so a writer there is held
            -- via the WH.entry bypass instead
            local below=WH.entry or base_prev
            local bname=wh_chunk_of(below)
            if type(below)=='function' and bname~=''
               and wh_frag_match(bname) and WH.held[bname]==nil then
                local nxt=wh_next(below)
                if nxt then
                    local gate,ctl=wh_make_gate(below,nxt)
                    WH.entry=gate
                    WH.held[bname]={ctl=ctl,gate=gate,writer=below,next=nxt,entry=true}
                    log('writer hold: '..bname..' gated out (entry bypass)')
                    caught=caught+1
                    cur=nxt
                else
                    cur=below
                end
            else
                cur=below
            end
        else
            local name=wh_chunk_of(cur)
            -- one-shot chain inventory: every layer's chunk name, so users
            -- can copy exact fragments into exclude= / writers= from the log
            if WH.walks==0 then
                if name~='' then
                    WH.inventory=WH.inventory and (WH.inventory..', '..name) or name
                end
            end
            local bypassed=false
            if name~='' and wh_frag_match(name) and WH.held[name]==nil then
                local nxt=wh_next(cur)
                if nxt then
                    -- splice invariant: the recorded slot must currently
                    -- point at THIS writer. A mis-descended walk (opaque
                    -- wrappers above) records wrong (caller,slot) pairs;
                    -- splicing those corrupts innocent layers (that is how
                    -- extra_slot got bypassed and we got kicked off). A
                    -- failed check means no protection for this writer this
                    -- pass - logged, retried next pass - but never damage.
                    local slot_ok=true
                    if caller then
                        local _,cur_v=debug.getupvalue(caller,slot)
                        slot_ok=(cur_v==cur)
                        if not slot_ok then
                            -- self-repair: the walk skipped a layer (opaque
                            -- wrappers) so the recorded slot is off. Scan the
                            -- recorded caller's whole upvalue list for the
                            -- writer, then one layer deeper via its primary
                            -- next. Catches the common one-layer skip.
                            local i=1
                            while true do
                                local _,v=debug.getupvalue(caller,i)
                                if not _ then break end
                                if v==cur then slot=i slot_ok=true break end
                                i=i+1
                            end
                            if not slot_ok then
                                local deep=select(1,wh_next(caller))
                                if type(deep)=='function' then
                                    local j=1
                                    while true do
                                        local _,v=debug.getupvalue(deep,j)
                                        if not _ then break end
                                        if v==cur then caller=deep slot=j slot_ok=true break end
                                        j=j+1
                                    end
                                end
                            end
                            if not slot_ok then
                                log('writer hold: '..name..' slot not found - left on chain this pass')
                            end
                        end
                    end
                    if slot_ok then
                    local gate,ctl=wh_make_gate(cur,nxt)
                    if caller then
                        pcall(debug.setupvalue,caller,slot,gate)
                    elseif cur==head_above then
                        -- an ADOPTED head that turns out to be a writer:
                        -- release the adoption down one layer
                        head_above=gate
                    else
                        -- the writer IS the live head: replace it
                        rawset(_G,'update',gate)
                        WH.head_swaps=(WH.head_swaps or 0)+1
                    end
                    WH.held[name]={ctl=ctl,gate=gate,writer=cur,next=nxt,
                                   caller=caller,slot=slot}
                    log('writer hold: '..name..' gated out of the chain (zero cost until release)')
                    caught=caught+1
                    end
                    cur=nxt
                    -- caller/slot stay valid: caller now calls nxt directly;
                    -- re-examine the promoted layer (writers can be adjacent)
                    bypassed=true
                else
                    log('writer hold: '..name..' unreadable previous - left on chain')
                end
            end
            if not bypassed then
                local nxt=wh_next(cur)
                if not nxt then break end
                caller,slot=cur,select(2,wh_next(cur))
                cur=nxt
            end
        end
    end
    -- A profiler may wrap our gate. Keep those probes on the live path;
    -- removing them freezes their inclusive samples and misattributes the
    -- downstream chain to unrelated mods such as Quasar and corpse cleanup.
    -- If a probe restored the writer, replace only its direct writer slot.
    local respliced=0
    for name,h in pairs(WH.held) do
        if h.caller and h.gate then
            local _,v=debug.getupvalue(h.caller,h.slot)
            local parent,index=h.caller,h.slot
            local seen={}
            for depth=1,16 do
                if v==h.gate then break end
                if v==h.writer then
                    pcall(debug.setupvalue,parent,index,h.gate)
                    respliced=respliced+1
                    break
                end
                if type(v)~='function' or seen[v] or v==wrapper then break end
                seen[v]=true
                parent=v
                v,index=wh_next(v)
                if not index then break end
            end
        end
    end
    if respliced>0 then
        WH.reinstalls=(WH.reinstalls or 0)+respliced
        if WH.walks%15==1 then
            log('writer hold: re-spliced '..WH.reinstalls..' stripped gate(s) total (spy storm)')
        end
    end
    WH.walks=(WH.walks or 0)+1
    if WH.walks==1 and WH.inventory then
        log('chain inventory (copy fragments for exclude=/writers=): '..WH.inventory)
        WH.inventory_logged=WH.inventory
    elseif WH.inventory and WH.inventory~=WH.inventory_logged then
        -- 3.0.43: mods that join the chain later (or that re-hook) must show up
        -- too, otherwise users cannot copy their fragment from the log.
        WH.inventory_logged=WH.inventory
        log('chain inventory changed (copy fragments for exclude=/writers=): '..WH.inventory)
    end
    if WH.inventory and M.discovered_sources then
        -- Names we can see but cannot schedule. Printing them separately stops
        -- "why is my mod missing from the inventory / why does exclude= do
        -- nothing" reports: a source above our wrapper, or one that is not on
        -- the update chain at all, can never be excluded.
        local unmanaged={}
        for _,name in ipairs(M.discovered_sources) do
            if name~='' and not WH.inventory:find(name,1,true) and not name:find('smoothboot',1,true) then
                unmanaged[#unmanaged+1]=name
            end
        end
        table.sort(unmanaged)
        local signature=table.concat(unmanaged,',')
        if signature~='' and signature~=WH.unmanaged_logged then
            WH.unmanaged_logged=signature
            log('chain sources NOT managed (above SmoothBoot or outside the update chain; exclude= cannot affect these): '..signature)
        end
    end
    M.frag_check()
    if caught>0 then
        log(string.format('writer hold: %d writer(s) caught this pass, %d held in total',
            caught,wh_count()))
    end
    if WH.walks==1 then
        log('writer hold: full-chain interdiction active ('..wh_count()..
            ' writer(s) held on first pass)')
    end
end
-- opt-in timed release: writer_release_s>0 releases held writers one per
-- writer_stagger_s, in the order they were caught. Default is 0 = hold
-- forever, because the crash evidence shows these writes detonate on the
-- next table rebuild whenever they land.
-- robust single-writer release. Recorded slots go stale when the reheader
-- storm rewires the chain during the hold, so after the fast path fails we
-- re-locate the writer's old next (a static layer that is always on the
-- chain) and splice the writer back in above WHOEVER currently calls it.
local function wh_release_one(name,h)
    if h.ctl then
        h.ctl.open=true
        log('writer hold: '..name..' released (gate opened)')
        return true
    end
    log('writer hold: '..name..' has no gate - stays held')
    return false
end
-- config fragment typo guard: every fragment the user put in exclude=/ui_chunks=
-- must match something on the chain (string match is substring-based, so any
-- unique fragment works - but a typo silently disables the rule). Unmatched
-- fragments are logged once with the closest chunk name as a hint; writers=
-- fragments get a single summary line because the shipped default lists many
-- optional mods that are legitimately not installed.
function M.frag_check()
    -- The writer walk is linear; wait for the bounded bus discovery before
    -- warning about a missing fragment. Otherwise a real HUD looks absent.
    if not M.discovered_sources then return end
    local inventory=(WH.inventory or '')..','..table.concat(M.discovered_sources or {},',')
    if inventory==',' then return end
    M._fragn = M._fragn or {}
    local function check(list, individual, skip)
        local missing = {}
        for frag in (list or ''):gmatch('[%w_./%-]+') do
            if skip and skip:find(frag, 1, true) then
                -- shipped default: our own fragment, never warn about it
            elseif frag ~= '' and not inventory:find(frag, 1, true) and not M._fragn[frag] then
                M._fragn[frag] = true
                missing[#missing+1] = frag
                if individual then
                    local hint = ''
                    local stem = frag:sub(1, 4):lower()
                    for name in (WH.inventory or ''):gmatch('[%w_./%-]+%.lua') do
                        if #frag >= 4 and name:lower():find(stem, 1, true) then
                            hint = ' - did you mean "' .. (name:match('([^/]+)%.lua') or name) .. '"?'
                            break
                        end
                    end
                    if frag=='lte/helmet_cape_passives' then
                        -- shipped default: say what it is and how to remove it,
                        -- instead of sounding like a broken setting
                        log('config check: shipped default "lte/helmet_cape_passives" is not on this chain (that mod is not installed)'
                            .. ' - delete that entry from exclude= in config.txt if you do not use it')
                    else
                        -- 3.0.43: never spell "chain inventory" in a warning; the
                        -- collector used to pick the line that merely mentioned it
                        log('config check: "' .. frag .. '" matched no mod on the chain' .. hint ..
                            ' (the fragment must match one of the discovered source names)')
                    end
                end
            end
        end
        if not individual and #missing > 0 then
            log('config check: writers fragment(s) not on chain (mod not installed?): ' ..
                table.concat(missing, ', '))
        end
    end
    check(cfg.exclude, true)
    check(cfg.ui_chunks, true, 'gun_calibration,helmet_cape_passives')
    check(cfg.writers, false)
end

local function wh_release_step()
    if WH.releasing_done then return end
    local order=WH.order
    if not order then
        order={}
        for name in pairs(WH.held) do order[#order+1]=name end
        table.sort(order)
        WH.order=order
        WH.released=0
        if #order==0 then WH.releasing_done=true return end
    end
    local now=os.clock()
    if not WH.next_release then WH.next_release=now end
    if now<WH.next_release then return end
    -- engine-quiet gate: only release while the frame cadence is close to this
    -- machine's own best. 3.0.5 learned fi_best during the boot hitch (25.8 ms)
    -- and then relaxed it every frame, so the limit sat at 77 ms and the gate
    -- could not fail; 3.0.6 kept a historical minimum but still authorised
    -- best*3 = 85 ms for the whole session; 3.0.7 caps the limit as well. The
    -- floor stops one absurdly fast frame from making the gate unsatisfiable,
    -- and the forced release stops the writers being held forever.
    local fi_now=fi_n>0 and (fi_t/fi_n) or 0
    if fi_now>0 and (not WH.fi_best or fi_now<WH.fi_best) then
        WH.fi_best=math.max(fi_now,0.003)
    end
    local fi_floor=(cfg.writer_fi_floor_ms or 12)/1000
    local fi_factor=cfg.writer_fi_factor or 3
    local fi_limit=math.min(math.max((WH.fi_best or 0)*fi_factor,fi_floor),fi_floor*2.5)
    local calm=fi_now>0 and fi_now<=fi_limit and (WH.dt_spike or 0)<=fi_limit
    if fi_now>0 and not calm then
        WH.quiet_waits=(WH.quiet_waits or 0)+1
        WH.wait_since=WH.wait_since or now
        local max_wait=(cfg.writer_stagger_s or 8)*3
        if now-WH.wait_since>=max_wait then
            log(string.format('writer hold: forcing release after %.0fs - engine never calmed'
                ..' (frame %.1fms, limit %.1fms)',now-WH.wait_since,fi_now*1000,fi_limit*1000))
            WH.wait_since=now
        else
            if WH.quiet_waits%15==1 then
                log(string.format('writer hold: release waiting for a calm engine window'
                    ..' (frame %.1fms > limit %.1fms, best %.1fms)',
                    fi_now*1000,fi_limit*1000,(WH.fi_best or 0)*1000))
            end
            WH.next_release=now+1
            return
        end
    else
        WH.wait_since=now
    end
    local fast=math.min(cfg.writer_min_stagger_s or 1,cfg.writer_stagger_s or 45)
    log(string.format('writer hold: gate calm - releasing (frame %.1fms, limit %.1fms, best %.1fms)',
        fi_now*1000,fi_limit*1000,(WH.fi_best or 0)*1000))
    WH.next_release=now+(calm and fast or (cfg.writer_stagger_s or 45))
    while WH.released<#order do
        local name=order[WH.released+1]
        local h=WH.held[name]
        WH.released=WH.released+1
        if h then
            local nl=cfg.writer_norelease or 'm103_frv'
            if nl~='' and name:find(nl,1,true) and not WH.norelease_announced then
                WH.norelease_announced=true
                log('writer hold: '..name..' held PERMANENTLY (its write is a proven'
                   ..' delayed crash - set writer_norelease= in config to re-enable)')
            end
            if nl~='' and name:find(nl,1,true) then
                -- skip release, do not count it as released this cycle
            else
                wh_release_one(name,h)
            end
            break
        end
    end
    if WH.released>=#order then
        WH.releasing_done=true
        WH.done_walking=true
        log('writer hold: timed release complete - interdiction walk stopped')
    end
end
if cfg.gc_pause and cfg.gc_pause>0 then
    pcall(collectgarbage,'setpause',cfg.gc_pause)
    log('gc pause set to '..cfg.gc_pause..'%')
end
if cfg.gc_stepmul and cfg.gc_stepmul>0 then
    pcall(collectgarbage,'setstepmul',cfg.gc_stepmul)
    log('gc stepmul set to '..cfg.gc_stepmul)
end
local skip=1
local stats={n=0,total=0,max=0}
-- 3.0.42 diagnostic: per-window self-timing of everything the wrapper does
-- OUTSIDE the chain call (walk, discovery, 10s config poll). The Watchdog
-- attributes the whole wrapper frame to us, so this is what decides whether an
-- opening row of ~357 ms/s is our work or attribution.
local diag2={pre=0,pre_max=0,n=0,walk=0,disc=0,poll=0,chain0=0,start=os.clock()}
diag2.chain0=stats.total
local err_top={}          -- modname -> count
local err_total=0
local last_cfg=os.clock()
local trips=0
local paused_until=0
local announced={}        -- modnames we already logged about
-- first-run provisioning: a README explaining every config key and a
-- one-click log collector land next to config.txt, so users can self-
-- serve diagnostics without hunting forum posts
local tool_attempts=0
local function provision_tools()
    tool_attempts=tool_attempts+1
    ensure_dirs()
    local ok,err=pcall(function()
    local dir=HOME..'SmoothBoot/'
    local function wr(n,c)
        local f=io.open(dir..n,'w')
        if not f then error('cannot open '..dir..n) end
        local wrote,why=f:write(c)
        local closed,close_error=f:close()
        if not wrote or not closed then error(why or close_error or 'write failed') end
        return true
    end
    local readme=[===[SmoothBoot - quick guide / 快速指南
=====================================================

Candidate 3.0.43 (bug-fix): collector exclude picker ignores "config check" lines; the config-check warning no longer contains the words "chain inventory"; the shipped LTE default explains itself and how to remove it; chain inventory is re-logged when it changes and unmanaged sources are listed separately; "rehooks" is logged once per source with an above-SmoothBoot note; the load-order hint is printed on the first frame.
候选3.0.43（修复版）：bat 排除选择器不再被 "config check" 行干扰；配置检查提示不再包含 "chain inventory" 字样；自带 LTE 默认项会说明自身及删除方法；链清单变化时重新打印，并单独列出无法托管的来源；"rehooks" 每个来源只提示一次并说明是否在 SmoothBoot 之上；首帧直接提示加载顺序问题。
Candidate 3.0.42 (diagnostic): self-timings of the wrapper sections outside the chain call, to settle the opening-cost attribution question.
候选3.0.42（诊断版）：为包装层中“链条调用之外”的各段加入自计时，用于判定开局开销到底是不是我们的。
Candidate 3.0.41: detects common drawing field accesses, captured graphics APIs and mod render hooks.
候选3.0.41：自动识别常见绘图接口、闭包引用与模组render回调，无需逐个添加名称。
Metadata is read only and cached; no foreign callback or graphics API is invoked by discovery.
只读取并缓存函数元数据；识别过程不执行第三方回调，不调用绘图接口。
Detected HUDs retain every update of their enclosing chain. This is not independent per-mod scheduling.
被识别HUD所在链条保留逐帧更新；这不是逐模组独立调度。
Unusual/dynamic/custom renderers may need the existing exclude list. Live acceptance remains required.
特殊、动态或自定义绘制仍可能需要排除名单，模拟测试不能代替实机验收。
Startup logs measure Smooth's own module-body initialization; pre-animation black-screen cause is unconfirmed.
启动日志记录Smooth自身初始化时间；片头前黑屏原因尚未确认，未宣称已经缩短黑屏。
Callback forwarding still avoids per-frame result tables and preserves trailing nil.
公共回调转发仍不逐帧创建返回值表，并保留末尾nil。
HUD Ballistic Trajectory, Enemy HP, DiversBestFriend and Aggro Counter callbacks
protect their enclosing chain from skipped/paused updates, including update buses.
弹道HUD、Enemy HP、DiversBestFriend和Aggro Counter所在调用链保留逐帧更新，兼容调度总线。
This protection is not selective per-mod scheduling. Native C4 adapters remain scoped.
此保护不是逐模组独立节流；C4原生读取适配仍只针对已核对的实现。
Watchdog can attribute work behind Smooth writer gates to Smooth. ms/s is accumulated
time per second, not one frame's latency. High startup scan cost may be temporary.
Watchdog可能把Smooth写入门后的工作归入Smooth。ms/s为每秒累计时间，不是单帧延迟。
Game functionality and reported cost regressions still require live acceptance.
游戏功能以及反馈的异常开销仍需实际游戏验收。

[Report an issue / 反馈问题]
  The game creates Collect-Logs.bat next to this README on first run
  (folder: %LOCALAPPDATA%\CowboyBingus\Helldivers2\SmoothBoot\).
  / 首次运行游戏后，本 README 旁边会自动生成 Collect-Logs.bat。
  This is the runtime config folder, not the mod manager import folder.
  此处是运行配置目录，不是模组管理器的安装目录。
  Open it by pasting the folder path above into File Explorer.
  将上方目录粘贴到文件资源管理器地址栏即可打开。
  1. Close the game / 关闭游戏
  2. Double-click Collect-Logs.bat / 双击 Collect-Logs.bat
  3. Type C and press Enter / 输入 C 回车
  4. Send the SmoothBoot-logs-*.zip from your Desktop with your report
     把桌面上的 SmoothBoot-logs-日期.zip 随问题报告一起发给作者

[Exclude one mod from SmoothBoot / 排除一个模组（不让它管）]
  1. Close the game / 关闭游戏
  2. Double-click Collect-Logs.bat / 双击 Collect-Logs.bat
  3. Type E and press Enter / 输入 E 回车
  4. Pick the mod by NUMBER and press Enter / 按数字选择模组，回车
  The exact name is written into config.txt for you - nothing to type,
  nothing to mistype. Existing exclusions are preserved; remove only this name to undo.
  精确名称会自动合并进 config.txt 的 exclude= 列表；保留已有排除项，移除该名称即可撤销。

[Advanced: manual config editing / 进阶：手动改配置]
  Edit config.txt in this folder; changes hot-apply within 10 seconds.
  / 编辑本文件夹里的 config.txt，10 秒内热生效。
  enabled=yes/no        master switch / 总开关
  c4_read_pool=yes/no   candidate C4 read-buffer reuse / 测试版C4读取缓冲复用
    Uses live reads on every call; preserves C4 input, guards and charge tracking.
    / 每次仍读取最新内存；保留C4输入、校验和炸药跟踪。
    Set no and restart to compare with the original reader; no third-party files change.
    / 改为no并重启可对照原版读取；不修改其他作者的安装文件。
  c4_context_batch=yes/no  candidate context validation batches (default no)
    / 上下文校验分块测试，默认no。每项仍校验新数据；大读取失败回退。
    Flags-only C4 UI checks keep fresh identity and map/menu flags, without action data.
    / C4界面检查仅采集新鲜身份和地图/菜单标志，不采集无关动作数据。
    Identical owned-fire maintenance omits unused diagnostic templates; acquisition stays complete.
    / 同一已有射击接管省去未使用的诊断模板扫描；首次接管保留完整读取。
  c4_native_batch=yes/no   candidate native code verification batches (default no)
    Owned aim maintenance checks fresh mapping/index code only; owned fire makes no native call.
    Acquisition, restoration and actions retain full verification; all dynamic inputs stay fresh.
    / 已接管瞄准只校验当前调用的映射/索引代码；已接管开火无原生调用。
    / 建立接管、恢复和动作保留完整校验；每次仍读取最新动态输入。
    / 原生代码校验分块测试，默认no。
    Native actions, input policy and validation limits are preserved.
    / 保留原生动作、输入策略及校验限制。切换可热生效，不是稳定版保证。
  c4_idle_batch=yes/no     candidate idle auto-reload read gate (default no)
                          空闲自动装填读取门控；有待恢复状态时保留完整处理
  c4_cpu_profile=yes/no    45-second CPU diagnosis only (default no)
    / CPU短时诊断，默认关闭，45秒自动停止。诊断期间帧率不作为验收结果。
  exclude=FRAG,...      never manage these mods / 排除托管
  writers=FRAG,...      writer mods held at boot / 开机扣留的写入器
  writer_release_s=10   seconds before first release / 首个放行延时
  writer_stagger_s=8    seconds between releases / 放行间隔
  writer_min_stagger_s=8 minimum release interval / 最短放行间隔
  snapshot=no          deep diagnostic snapshots (off by default) / 深度快照默认关闭
  writer_norelease=FRAG never released / 永不放行
    NOTE: the m103 FRV turret writer is held permanently BY DEFAULT - its
    delayed write crashed 3/3 test sessions. To re-enable it at your own
    risk, set: writer_norelease= (empty value) in config.txt.
    / 默认永久扣留 m103 炮塔写入器（其延迟写入实测必崩）；自担风险放开：
    / 在 config.txt 写一行 writer_norelease= （等号后留空）
  ui_chunks=FRAG,...    frame-critical mods / 关键帧模组保护
  No compatibility popup: timing and registration cannot prove lost functionality.
  / 没有兼容弹窗：耗时和注册状态不能证明第三方功能被破坏。
  LTE Helmet and Cape Passives is excluded by default after the reported variant issue.
  / 默认排除LTE头盔/披风被动模组；Armor Transmog没有新增排除。
  throttle=auto/yes/no, diag=yes/no ...
  Where do fragments come from? The "chain inventory" line in SmoothBoot.log
  lists every mod's exact name - copy any unique piece. If you mistype one,
  the log will say: config check: ... did you mean "..."?
  / 片段来自 SmoothBoot.log 里的 "chain inventory" 行；填错时日志会提示正确名称。
  Only sources reachable on the update chain can be listed or excluded. A mod
  that hooks the engine elsewhere (menus, native render, its own timer) can be
  neither scheduled nor excluded; the log prints those as "NOT managed".
  / 只有 update 链上够得到的模组才能被列出或排除；挂在别处（菜单、原生渲染、
  自己的计时器）的模组既不能被调度也不能被排除，日志会用 "NOT managed" 标出。
  Load order: SmoothBoot must be the bottom (lowest priority) entry. If another
  mod wraps the chain above it, the first-frame line says so and lists the head.
  / 加载顺序：SmoothBoot 必须在最底部（优先级最低）。若有模组在它上面包住链，
  首帧日志会直接写出链头名字并提示调整顺序。

[About Mod Lag Watchdog / 关于 watchdog]
  It may report "hooking more than once: smoothboot xN" - that is expected
  (1 governor wrapper + N gates). Its ms/s column can read high for some
  mods. SmoothBoot stats measure only its managed chain; compare call counts
  and the same scene before attributing an individual mod cost.
  / stats 只记录托管链，不能据此否定看门狗读数；请结合调用次数与同场景数据判断。
]===]
    wr('README.txt',readme)
    wr('Collect-Logs.bat',[===[@echo off
rem Generated by HD2 SmoothBoot; run with the game closed.
chcp 65001 >nul
setlocal
tasklist /FI "IMAGENAME eq helldivers2.exe" 2>nul | find /I "helldivers2.exe" >nul
if not errorlevel 1 (
  echo Close the game first / Please close Helldivers 2.
  pause
  exit /b 1
)
powershell -NoProfile -Command "$ErrorActionPreference='Stop'; $base=Join-Path $env:LOCALAPPDATA 'CowboyBingus\Helldivers2'; $stage=$null; try { $mode=Read-Host 'Collect logs (C) / Exclude a mod (E)'; if ($mode -eq 'E') { $log=Join-Path $base 'Logs\SmoothBoot.log'; if (-not (Test-Path -LiteralPath $log)) { throw 'No SmoothBoot.log. Start the game once first.' }; $inv=Get-Content -LiteralPath $log -Encoding UTF8 | Where-Object {$_ -match 'chain inventory' -and $_ -notmatch 'config check'} | Select-Object -Last 1; if (-not $inv) { throw 'No chain inventory yet. Let initialization finish first.' }; $names=$inv -replace '^.*chain inventory[^:]*:',''; $mods=@($names -split ',\s*' | ForEach-Object {$_.Trim()} | Where-Object {$_ -match '^mods/[\w./-]+$' -and $_ -notmatch 'smoothboot|^mods/mdl/'} | Select-Object -Unique); if ($mods.Count -eq 0) { throw 'No manageable mods in the inventory.' }; for($i=0; $i -lt $mods.Count; $i++) { Write-Host (' {0,2}. {1}' -f ($i+1),$mods[$i]) }; $n=Read-Host 'Mod NUMBER (0 = cancel)'; $idx=0; if (-not [int]::TryParse($n,[ref]$idx) -or $idx -lt 0 -or $idx -gt $mods.Count) { throw 'Invalid mod number.' }; if ($idx -gt 0) { $frag=$mods[$idx-1] -replace '\.lua$',''; $cfg=Join-Path $base 'SmoothBoot\config.txt'; $cur=@(); if (Test-Path -LiteralPath $cfg) { $cur=@(Get-Content -LiteralPath $cfg -Encoding UTF8) }; $existing=@($cur | Where-Object {$_ -match '^\s*exclude\s*='} | Select-Object -Last 1); $values=@(); if($existing.Count) { $values=@(($existing[0] -replace '^\s*exclude\s*=\s*','') -split ',' | ForEach-Object {$_.Trim()} | Where-Object {$_}) }; $values=@(@($values)+@($frag) | Select-Object -Unique); $kept=@($cur | Where-Object {$_ -notmatch '^\s*exclude\s*='}); $updated=@($kept)+@('exclude='+($values -join ',')); [IO.File]::WriteAllLines($cfg,$updated,(New-Object Text.UTF8Encoding($false))); Write-Host ('DONE: exclude='+($values -join ',')); Write-Host 'To undo, remove only this mod from the exclude= list.'; }; } elseif ($mode -eq 'C') { if (-not (Test-Path -LiteralPath $base)) { throw 'No mod log directory. Start the game with SmoothBoot enabled first.' }; $desktop=[Environment]::GetFolderPath('Desktop'); if (-not $desktop -or -not (Test-Path -LiteralPath $desktop)) { $desktop=Join-Path $base 'SmoothBoot' }; $zip=Join-Path $desktop ('SmoothBoot-logs-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+([guid]::NewGuid().ToString('N').Substring(0,6))+'.zip'); $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()); $stage=Join-Path $tempRoot ('SmoothBoot-collect-'+[guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($stage); foreach($group in @('Logs','SmoothBoot')) { $from=Join-Path $base $group; $to=Join-Path $stage $group; [void][IO.Directory]::CreateDirectory($to); if (Test-Path -LiteralPath $from) { Get-ChildItem -LiteralPath $from -File | Where-Object {$_.Extension -in @('.log','.hb','.txt','.bat')} | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $to }; }; }; $diag=Join-Path $stage 'Diagnostics'; [void][IO.Directory]::CreateDirectory($diag); $extra=@((Join-Path $env:APPDATA 'Arrowhead\Helldivers2\mod_lag_finder.log'),(Join-Path $env:LOCALAPPDATA 'MDL\Helldivers2\MDL.cfg'),(Join-Path $env:LOCALAPPDATA 'MDL\Helldivers2\MDL.log')); foreach($file in $extra) { if(Test-Path -LiteralPath $file -PathType Leaf) { Copy-Item -LiteralPath $file -Destination $diag } }; $crashPath=Join-Path $stage 'crashes.txt'; try { $crash=@(Get-WinEvent -FilterHashtable @{LogName='Application';Id=1000} -MaxEvents 120 -ErrorAction Stop | Where-Object {$_.Message -match 'helldivers'} | ForEach-Object { '{0} {1}' -f $_.TimeCreated,($_.Message -replace '\s+',' ') }); if (-not $crash.Count) {$crash=@('No matching crash records.')}; $crash | Set-Content -LiteralPath $crashPath -Encoding UTF8; } catch { ('Crash records unavailable: '+$_.Exception.Message) | Set-Content -LiteralPath $crashPath -Encoding UTF8 }; $modsRoot=Join-Path $env:LOCALAPPDATA 'hd2arsenal\mods'; $rows=@(); if(Test-Path -LiteralPath $modsRoot) { $rows=@(Get-ChildItem -LiteralPath $modsRoot -Directory | ForEach-Object { $_.Name }) }; $rows | Set-Content -LiteralPath (Join-Path $stage 'modlist.txt') -Encoding UTF8; $db=Join-Path $env:LOCALAPPDATA 'hd2arsenal\hd2a_data.json'; if(Test-Path -LiteralPath $db) { try { $data=Get-Content -LiteralPath $db -Raw -Encoding UTF8 | ConvertFrom-Json; $data.modsList.default.mods | Select-Object label,enabled,deployed | Export-Csv -LiteralPath (Join-Path $stage 'mod-status.csv') -NoTypeInformation -Encoding UTF8; } catch { ('Mod status unavailable: '+$_.Exception.Message) | Set-Content -LiteralPath (Join-Path $stage 'mod-status-error.txt') -Encoding UTF8 }; }; Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip; if(-not (Test-Path -LiteralPath $zip)) { throw 'Log ZIP was not created.' }; Write-Host ('Done: '+$zip); } else { throw 'Choose C or E.' }; } catch { Write-Host ('FAILED: '+$_.Exception.Message); exit 1 } finally { if($stage -and (Test-Path -LiteralPath $stage)) { $resolved=[IO.Path]::GetFullPath($stage); if($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^SmoothBoot-collect-[0-9a-f]{32}$') { [IO.Directory]::Delete($resolved,$true) } } }"
set "collector_result=%errorlevel%"
pause
exit /b %collector_result%
]===])
    end)
    M.tools_ready=ok
    if ok then
        log('companion tools ready: '..HOME..'SmoothBoot/Collect-Logs.bat')
    elseif tool_attempts==1 or tool_attempts==6 then
        log('companion tools not ready: '..tostring(err))
    end
end
provision_tools()

-- Diagnostics read published state only: no native action or foreign state
-- mutation. This also covers third-party mods whose own logging is off.
local function runtime_snapshot()
    for _,key in ipairs({'HD2C4BoundaryProbe','ModBindingsMenu','TweaksMod','CorpseCleanup',
                         'HD2VehicleCooldown','TankCooldown','MDL'}) do
        local state=rawget(_G,key)
        if type(state)=='table' then
            local values={}
            for field,value in next,state do
                local kind=type(value)
                if type(field)=='string' and (kind=='string' or kind=='number' or kind=='boolean') then
                    values[#values+1]=field..'='..tostring(value):gsub('[\r\n]',' '):sub(1,300)
                end
            end
            table.sort(values)
            log('runtime state '..key..': '..table.concat(values,', '))
        else
            log('runtime state '..key..': absent')
        end
    end
end
local function c4_snapshot()
    -- Watchdog can keep the real callback in a table field rather than a
    -- previous upvalue. Read the bounded closure graph; never replace slots.
    local queue,seen={},{}
    local function enqueue(value)
        local kind=type(value)
        if (kind=='function' or kind=='table') and not seen[value]
           and value~=_G and value~=package and value~=rawget(_G,'stingray') then
            seen[value]=true queue[#queue+1]=value
        end
    end
    enqueue(rawget(_G,'update')) enqueue(head_above) enqueue(WH.entry) enqueue(base_prev)
    local captured={}
    local saw_c4=false
    local detail_seen={}
    local detail_count=0
    local function c4_details(root)
        -- Follow the C4 helper functions immediately. Watchdog metadata can
        -- otherwise fill the generic queue before tick's state is reached.
        -- Its spy/timer exposes the wrapped function as the target upvalue.
        local pending={root}
        while #pending>0 and detail_count<256 do
            local fn=table.remove(pending)
            if not detail_seen[fn] then
                detail_seen[fn]=true detail_count=detail_count+1
                local chunk=wh_chunk_of(fn)
                local c4=chunk:find('mods/etxp/c4_boundary_probe',1,true)~=nil
                local spy=chunk:find('mods/patpatpatrick/mod_lag_finder',1,true)~=nil
                if c4 or spy then
                    for index=1,64 do
                        local name,next_=debug.getupvalue(fn,index)
                        if not name then break end
                        if c4 and (name=='bindings' or name=='gameplay_guard' or name=='gate' or name=='actions')
                           and type(next_)=='table' then captured[name]=next_ end
                        if type(next_)=='function' and (c4 or name=='target') then
                            pending[#pending+1]=next_
                        end
                    end
                end
            end
            if captured.bindings and captured.gameplay_guard and captured.gate and captured.actions then break end
        end
    end
    local at=1
    while at<=#queue and at<=512 do
        local value=queue[at] at=at+1
        if type(value)=='function' then
            local chunk=wh_chunk_of(value)
            local is_c4=chunk:find('mods/etxp/c4_boundary_probe',1,true)~=nil
            if is_c4 then saw_c4=true c4_details(value) end
            if value==wrapper then
                enqueue(head_above) enqueue(WH.entry) enqueue(base_prev)
            elseif chunk:find('mods/',1,true) then
                for i=1,64 do
                    local name,next_=debug.getupvalue(value,i)
                    if not name then break end
                    if is_c4 and (name=='bindings' or name=='gameplay_guard' or name=='gate' or name=='actions')
                       and type(next_)=='table' then captured[name]=next_ end
                    if name~='engine' and name~='sr' and name~='G' then enqueue(next_) end
                end
            end
        elseif getmetatable(value)==nil then
            local count=0
            for _,next_ in next,value do
                count=count+1 if count>64 then break end
                enqueue(next_)
            end
        end
        if captured.bindings and captured.gameplay_guard and captured.gate and captured.actions then break end
    end
    if not captured.bindings then
        log('runtime C4 details: binding closure not found; callback='..tostring(saw_c4)..' nodes='..(at-1))
    end
    for name,state in pairs(captured) do
        local values={}
        local function read(table_,prefix)
            for key,value in next,table_ do
                local kind=type(value)
                if type(key)=='string' and (kind=='string' or kind=='number' or kind=='boolean') then
                    values[#values+1]=prefix..key..'='..tostring(value):gsub('[\r\n]',' '):sub(1,300)
                end
            end
        end
        read(state,'')
        for _,key in ipairs({'latest','previous','registered'}) do
            local nested=rawget(state,key)
            if type(nested)=='table' then read(nested,key..'.') end
        end
        table.sort(values)
        log('runtime C4 '..name..': '..table.concat(values,', '))
    end
end

M.init_elapsed_ms=(os.clock()-M.init_started)*1000
log(string.format('ready v%s chain=%s boot_skip=%d exclude=%d init_elapsed_ms=%.2f',
    M.version,tostring(previous~=nil),skip,#excludes,M.init_elapsed_ms))


-- Preserve every result (including trailing nil) without allocating a table
-- or a new completion closure on each callback. Error policies remain distinct.
local function complete_disabled(ok,...)
    inside=false
    if not ok then
        local failure=(...)
        pcall(function()
            local f=io.open(LOG..'.hb','a')
            if f then f:write(os.date('!%H:%M:%S')..' chain error (disabled path): '..tostring(failure)..'\n') f:close() end
        end)
        error(failure,0)
    end
    return ...
end
local function complete_chain(t0,want_throttle,manual_protection,ok,...)
    inside=false
    local cost=(os.clock()-t0)*1000
    if not ok then
        local failure=(...)
        pcall(function()
            if M._lasterr~=tostring(failure) then
                M._lasterr=tostring(failure)
                local f=io.open(LOG..'.hb','a')
                if f then f:write(os.date('!%H:%M:%S')..' chain error: '..tostring(failure)..'\n') f:close() end
            end
        end)
        err_total=err_total+1
        M.errors=err_total
        local who=tostring(failure):match('HD2%-Addon:%s*(mods/[%w_/%-]+)') or 'unknown'
        err_top[who]=(err_top[who] or 0)+1
        if err_total<=10 or err_total%100==0 then
            log('mod chain error #'..err_total..' ['..who..']: '..tostring(failure))
        end
    end
    stats.n=stats.n+1
    stats.total=stats.total+cost
    w_total=w_total+cost; w_n=w_n+1
    if frames-sample_mark>=300 then
        sample_mark=frames
        avg_hist[#avg_hist+1]=w_n>0 and w_total/w_n or 0
        if #avg_hist>6 then table.remove(avg_hist,1) end
        w_total,w_n=0,0
    end
    if cost>stats.max then stats.max=cost end
    -- breaker accounting (mission scene only; menus are already throttled)
    if cost>(cfg.trip_ms or 50) and settled(cfg.grace_s) and not manual_protection then
        trips=trips+1
        if trips>=(cfg.trip_n or 3) then
            paused_until=os.clock()+(cfg.pause_s or 5)
            log_paused=true
            log(string.format('breaker OPEN: chain %.1fms x%d - pausing %ss',cost,trips,cfg.pause_s or 5))
            trips=0
        end
    else
        trips=0
    end
    -- adaptive skip only steers the mission/unknown case
    local eff_ms=cfg.busy_ms or 12
    if cfg.busy_pct and cfg.busy_pct>0 and fi_n>=120 then
        local fi_ms=fi_t/math.max(1,fi_n)*1000
        local pct_ms=fi_ms*cfg.busy_pct/100
        if pct_ms>eff_ms then eff_ms=pct_ms end
    end
    if want_throttle then
        if cost>eff_ms and settled(cfg.grace_s) then
            if skip<(cfg.max_skip or 2) then skip=skip+1 log(string.format('throttle up: chain %.1fms -> skip=%d',cost,skip)) end
        elseif cost<(cfg.idle_ms or 1.5) and skip>1 then
            skip=skip-1
            if skip==1 then log('throttle released: chain is cheap, running every frame') end
        end
    end

    if frames%1800==0 then
        if C4Pool.active>0 then
            log('C4 read pool: active='..C4Pool.active..' live_reads='..C4Pool.reads())
            C4Pool.report_probe()
        end
        if cfg.snapshot then pcall(runtime_snapshot) end
        if cfg.snapshot then pcall(c4_snapshot) end
        local top={}
        for k,v in pairs(err_top) do top[#top+1]=k..'='..v end
        table.sort(top,function(a,b) return tonumber(a:match('=(%d+)$'))>tonumber(b:match('=(%d+)$')) end)
        -- 3.0.43: a source that re-installs its hook every frame is re-adopted
        -- every time it does. Say it once per source (not every window), and say
        -- plainly when exclude= cannot stop it because it sits above us.
        local new_hooks={}
        M._rehook_logged=M._rehook_logged or {}
        for k,n in pairs(head_seen) do
            if n>=2 and not M._rehook_logged[k] then
                M._rehook_logged[k]=true
                local managed=(WH.inventory or ''):find(k,1,true)~=nil
                new_hooks[#new_hooks+1]=k..' x'..n..(managed and '' or
                    ' (not managed: it sits above SmoothBoot or outside the chain, so exclude= cannot stop it)')
            end
        end
        if #new_hooks>0 then log('rehooks: '..table.concat(new_hooks,', ')) end
        local avg_ms=stats.n>0 and stats.total/stats.n or 0
        log(string.format('stats frames=%d calls=%d skipped=%d avg=%.2fms max=%.2fms skip=%d errors=%d top:%s',
            frames,calls,skipped,avg_ms,stats.max,skip,
            err_total,table.concat(top,',',1,math.min(3,#top))))
        do
            local win_s=os.clock()-diag2.start
            local chain_ms=(stats.total-diag2.chain0)   -- stats.total is already ms
            -- 3.0.43: this self-timing is diagnostic only, so it follows diag=yes
            -- instead of adding a line to every user's log every window.
            if cfg.diag then
                log(string.format(
                    'diag2 window_s=%.1f entries=%d pre_ms_s=%.1f pre_total_ms=%.1f pre_avg_ms=%.3f pre_max_ms=%.1f chain_ms_s=%.1f chain_total_ms=%.1f walk_total_ms=%.1f disc_total_ms=%.1f poll_total_ms=%.1f',
                    win_s,diag2.n,win_s>0 and diag2.pre*1000/win_s or 0,diag2.pre*1000,
                    diag2.n>0 and diag2.pre*1000/diag2.n or 0,diag2.pre_max*1000,
                    win_s>0 and chain_ms/win_s or 0,chain_ms,
                    diag2.walk*1000,diag2.disc*1000,diag2.poll*1000))
            end
            diag2.pre,diag2.pre_max,diag2.n,diag2.walk,diag2.disc,diag2.poll=0,0,0,0,0,0
            diag2.chain0=stats.total
            diag2.start=os.clock()
        end
        local perf=rawget(_G,'HD2Perf')
        if type(perf)=='table' then
            local rows={}
            for k,v in pairs(perf) do
                if type(v)=='table' and v.n and v.n>0 then
                    rows[#rows+1]=string.format('%s=%.3fms',k,v.t*1000/v.n)
                end
            end
            if #rows>0 then log('self-reported: '..table.concat(rows,', ')) end
        end
        calls,skipped=0,0
        stats.max=0
    end
    if ok then return ... end
end
local function heartbeat(txt)
    pcall(function()
        local f=io.open(LOG..'.hb','a')
        if f then f:write(os.date('!%H:%M:%S')..' '..txt..'\n') f:close() end
    end)
end
local protection_head=nil
local protection_render=nil

wrapper=function(...)
    local nowf=os.clock()
    local diag2_t0=nowf
    if cfg.c4_cpu_profile or C4CPU.running or C4CPU.completed then C4CPU.poll(nowf)end
    if nowf>last_call then
        fi_t=fi_t+(nowf-last_call); fi_n=fi_n+1
        if fi_n>=600 then fi_t=fi_t/2; fi_n=fi_n/2 end
    end
    last_call=nowf
    -- role 2: an adopted chain calls back into us from inside; pass through to
    -- the original chain. This is what breaks wrapper -> X -> wrapper cycles.
    if inside then
        in_frames=in_frames+1
        return (WH.entry or base_prev)(...)
    end
    frames=frames+1
    local dtv=select(1,...)
    if type(dtv)=='number' and dtv>dt_window then dt_window=dtv end
    if frames%300==0 then WH.dt_spike=dt_window dt_window=0 end
    -- writer interdiction: full-chain walk every ~2s (must run BEFORE the
    -- adopt block: the adopt transition frame returns early and would
    -- otherwise skip frame-1 walks entirely)
    if frames==1 then heartbeat('first frame; head_is_self='..tostring(rawget(_G,'update')==wrapper)) end
    if frames%600==0 then heartbeat('alive frames='..frames) end
    if frames==1 then
        log(string.format('first update since module entry %.2fms',(os.clock()-M.init_started)*1000))
        M.excluded_below=M.find_excluded_below()
        if cfg.snapshot then pcall(runtime_snapshot) end
        local hh=rawget(_G,'update')
        local who='?'
        if hh~=wrapper then
            local ok,r=pcall(function() return debug.getinfo(hh,'S').source or '?' end)
            if ok then who=(r:match('mods/[%w_./%-]+') or r:sub(1,40)) end
        else who='self' end
        log('first frame reached, head='..who..
            (who=='self' and '' or ' (SmoothBoot is not the outermost wrapper - move it to the bottom of the mod list so it can manage the whole chain)'))
    end
    if frames%120==0 or frames==1 then
        local d0=os.clock()
        local ok,err=pcall(wh_full_walk)
        diag2.walk=diag2.walk+(os.clock()-d0)
        if not ok then log('writer hold: walk ERROR: '..tostring(err)) end
    end
    local current_head=rawget(_G,'update')
    local current_render=rawget(_G,'render')
    if frames==1 or frames%120==0 or current_head~=protection_head or current_render~=protection_render then
        protection_head=current_head
        protection_render=current_render
        local d1=os.clock()
        local ok,err=pcall(refresh_frame_protection)
        diag2.disc=diag2.disc+(os.clock()-d1)
        if not ok then log('frame-critical discovery failed: '..tostring(err)) end
    end
    if frames==1 or frames%300==0 then
        local ok,err=pcall(C4Pool.discover,{rawget(_G,'update'),head_above,WH.entry,base_prev})
        if not ok then log('C4 read pool: setup rejected: '..tostring(err)) end
    end
    local wrs=cfg.writer_release_s or 0
    if wrs>0 and os.clock()-installed_at>=wrs then pcall(wh_release_step) end
    -- engine-pin rollback: we adopted the head but the engine keeps calling
    -- the old one, so our governor frames stalled while pass-throughs ran.
    if head_above and in_frames>0 and frames==gov_mark and in_frames%120==0 then
        rawset(_G,'update',head_above)
        log('engine pins _G.update; releasing adopted head (deploy-order mode)')
        head_above=nil
    end
    local transition_target
    local head=rawget(_G,'update')
    if head~=wrapper and head==head_above then
        -- The adopted function has moved above us and is already executing
        -- this frame. Calling it again below us duplicates its own work.
        head_above=nil
        log('adopted head moved above SmoothBoot; using its existing call chain')
    end
    if head~=wrapper then
        local who=identify(head)
        if who then
            head_seen[who]=(head_seen[who] or 0)+1
        end
        if who==nil then
            if not announced['<non-bingus>'] then
                announced['<non-bingus>']=true
                log('note: a non-Bingus update wrapper sits above SmoothBoot - leaving it alone')
            end
        elseif who:find('mods/mdl',1,true) then
            peer_active=true
            if not announced['<peer-mdl>'] then
                announced['<peer-mdl>']=true
                log('peer loader detected ('..who..') - unmanaged by design; its live mods run on its own chain outside our pcall')
            end
        elseif is_excluded(who,excludes) then
            if not announced[who] then
                announced[who]=true
                log('excluded by config: '..who..' runs above SmoothBoot (unmanaged)')
            end
        elseif adopted_once[who] then
            -- this mod re-wraps update periodically; adopting it again would
            -- re-shuffle the onion and knock other mods off the chain. Leave
            -- it as the head: its previous is us, so the chain stays whole.
            if not announced['<rehook:'..who..'>'] then
                announced['<rehook:'..who..'>']=true
                log('mod '..who..' keeps re-heading the chain - leaving it above us (chain stays intact)')
            end
        elseif adopts<32 then
            -- splice the new head ON TOP of the previous adopted head; with a
            -- single head_above slot a second adopt would orphan the first one.
            -- The new head's upvalue that points at us gets retargeted to the
            -- previous adopted head, so every adopted mod stays on the chain.
            local idx=1
            local slot
            while true do
                local k,v=debug.getupvalue(head,idx)
                if not k then break end
                if v==wrapper then slot=idx break end
                idx=idx+1
            end
            if slot then
                transition_target=head_above or (WH.entry or base_prev)
                if head_above then debug.setupvalue(head,slot,head_above) end
                adopts=adopts+1
                adopted_once[who]=true
                head_above=head
                gov_mark=frames
                rawset(_G,'update',wrapper)
                log('adopted chain head back from '..who..' (governor active again)')
                -- The incoming head is already executing above us; call only
                -- its original downstream on this frame. Returning here drops
                -- that update; calling the new head duplicates its own callback.
            else
                if not announced['<noslice:'..who..'>'] then
                    announced['<noslice:'..who..'>']=true
                    log('cannot splice '..who..' (no upvalue to us); leaving it as head, unmanaged')
                end
            end
        elseif not announced['<max-adopt>'] then
            announced['<max-adopt>']=true
            log('too many re-heads; staying below the current one')
        end
    end
    local now0=os.clock()
    if cfg.diag and now0-(M._diag_t or 0)>=30 then
        M._diag_t=now0
        local head=rawget(_G,'update')
        local who='?'
        if head==wrapper then who='self' else
            local ok,r=pcall(function() return debug.getinfo(head,'S').source or '?' end)
            if ok then who=(r:match('mods/[%w_/%-]+') or r:sub(1,30)) end
        end
        pcall(function()
            local f=io.open(LOG,'a')
            if f then f:write(os.date('!%H:%M:%S')..string.format(' diag frames=%d calls=%d head=%s\n',
                frames,calls,who)) f:close() end
        end)
    end
    if os.clock()-last_cfg>10 then
        local pd0=os.clock()
        last_cfg=os.clock()
        if not M.tools_ready and tool_attempts<6 then provision_tools() end
        cfg=conf()
        excludes=excluded_list(cfg.exclude or '')
        pcall(C4Pool.discover,{rawget(_G,'update'),head_above,WH.entry,base_prev})
        M.excluded_below=M.find_excluded_below()
        pcall(M.frag_check)
        if not peer_active and type(rawget(_G,'MDL'))=='table' then
            peer_active=true
            if not announced['<peer-mdl>'] then
                announced['<peer-mdl>']=true
                log('peer loader present (global MDL) - unmanaged by design; manual settings have priority')
            end
        end
        pcall(refresh_frame_protection)
        diag2.poll=diag2.poll+(os.clock()-pd0)
    end
    -- boot freeze: hold the entire chain until the engine is stable
    if cfg.boot_freeze_s and cfg.boot_freeze_s>0 then
        if os.clock()-installed_at<cfg.boot_freeze_s then
            if frames%300==0 then
                log(string.format('boot freeze: %.0fs remaining',cfg.boot_freeze_s-(os.clock()-installed_at)))
            end
            return
        elseif not M._freeze_released then
            M._freeze_released=true
            log('boot freeze released - all mods resume against a stable engine')
        end
    end
        -- auto-pause: flip mod stop fields / phase strings during the boot window
    -- so scanners sit still while the engine rebuilds its tables. The chain
    -- itself keeps running - this is the freeze that does not black-screen.
    local bps=cfg.boot_pause_s or 10
    if os.clock()-installed_at<bps and not (M.excluded_below and #M.excluded_below>0) then
        if frames%30==0 then pcall(ap_scan) end
    else
        ap_restore()
    end

    local target=transition_target or head_above or (WH.entry or base_prev)
    if not target then return end
    if not cfg.enabled then
        inside=true
        return complete_disabled(pcall(target,...))
    end
    -- Manual exclusions inside our target require a full-speed fallback;
    -- never skip or pause that callback along with the downstream chain.
    local manual_protection=M.excluded_below and #M.excluded_below>0
    local frame_protection=manual_protection or ui_present==true
    if frame_protection then paused_until=0 end
    -- circuit breaker gate
    local now=os.clock()
    if now<paused_until then
        skipped=skipped+1
        return
    end
    if log_paused then
        log_paused=false
        pcall(log_flush)   -- breaker closed: drain what the panic window held
    end
    local cap=1
    local want_throttle=(cfg.throttle=='yes') or (cfg.throttle=='auto' and ui_present~=true)
    if peer_active and cfg.peer_suspend then want_throttle=false end
    if frame_protection then want_throttle=false end
    if want_throttle and settled(cfg.grace_s) then cap=skip end
    if cap>1 and frames%math.floor(cap)~=0 then
        skipped=skipped+1
        return
    end
    if peer_active and cfg.peer_suspend and not announced['<peer-suspend>'] then
        announced['<peer-suspend>']=true
        log('peer active: automatic throttling suspended - the peer manual settings have priority (pcall/breaker stay on; set peer_suspend=no to take over again)')
    end
    local diag2_spent=os.clock()-diag2_t0
    diag2.pre=diag2.pre+diag2_spent
    diag2.n=diag2.n+1
    if diag2_spent>diag2.pre_max then diag2.pre_max=diag2_spent end
    calls=calls+1
    local t0=os.clock()
    inside=true
    return complete_chain(t0,want_throttle,frame_protection,pcall(target,...))
end
rawset(_G,'update',wrapper)
log('installed v'..M.version..' as the outermost update wrapper (Bingus chain governor)')
return M

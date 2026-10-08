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
if old and old.version=='3.0.50' then return old end
local M={version='3.0.50',status='starting',init_started=os.clock()}
rawset(_G,KEY,M)

local HOME=(os.getenv('LOCALAPPDATA') or os.getenv('TEMP') or '.')..'/CowboyBingus/Helldivers2/'
local LOG=HOME..'Logs/SmoothBoot.log'
local CFG=HOME..'SmoothBoot/config.txt'
-- Create only our own directories, without launching a shell. Resolve a typed
-- function pointer rather than adding filesystem prototypes to global ffi.C.
-- Private aliases also isolate us from incompatible plain-name declarations
-- made earlier in the shared VM (the loader uses the same isolation pattern).
local function ensure_dirs()
    local ok,err=pcall(function()
        local ffi=require('ffi')
        ffi.cdef [[
            void *smoothboot_GetModuleHandleA(const char *name) __asm__("GetModuleHandleA");
            void *smoothboot_GetProcAddress(void *module, const char *name) __asm__("GetProcAddress");
        ]]
        local k32=ffi.load('kernel32')
        local module=k32.smoothboot_GetModuleHandleA('kernel32.dll')
        local create=ffi.cast('int (__stdcall *)(const char *, void *)',
                             k32.smoothboot_GetProcAddress(module,'CreateDirectoryA'))
        local attr=ffi.cast('unsigned long (__stdcall *)(const char *)',
                           k32.smoothboot_GetProcAddress(module,'GetFileAttributesA'))
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
    local defaults={enabled=true,throttle='auto',profile=true,reentry_max=3,boot_skip=1,boot_s=0,grace_s=60,busy_ms=12,idle_ms=1.5,max_skip=2,snapshot=false,
                    trip_ms=50,trip_n=3,pause_s=5,exclude='lte/helmet_cape_passives',gc_pause=0,gc_stepmul=0,peer_suspend=true,ui_mods='',scanners='',boot_pause_s=10,
                    writer_release_s=10,writer_stagger_s=8,writer_norelease='m103_frv',ui_chunks='gun_calibration,helmet_cape_passives',writers='p33_missile_pistol,p34_breacher,gp20_ultimatum,m103_frv,ac8_rack,k9_p,no_large_piercing,stratagem_cooldown,maxigun,tank_cooldown,maelstrom_traverse,tank_clutch_tuner,tank_seat_kit',
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
                w:write('reentry_max=3\n')
                w:write('# adaptive skip only kicks in above busy_ms per chain call (throttle=no to disable)\n')
                w:write('throttle=auto\nprofile=yes\n')
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
                w:write('gc_pause=0\ngc_stepmul=0\n')
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
        for _,key in ipairs({'reentry_max','boot_skip','boot_s','grace_s','busy_ms','busy_pct','idle_ms','max_skip',
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
    for frag in spec:gmatch('[%w_./%-]+') do t[#t+1]=frag:lower() end
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
                        -- A global name can be reused for a new state during
                        -- startup. Save by object identity, not by its alias.
                        local saved=APorig[v]
                        if not saved then saved={} APorig[v]=saved end
                        if saved[field]==nil then
                            saved[field]=false
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
    local n=0
    for tbl,fields in pairs(APorig) do
        for key,value in pairs(fields) do
            rawset(tbl,key,value)
            n=n+1
        end
    end
    -- Restoration is one-shot. Keeping these entries after release pins the
    -- foreign state tables (and everything they own) for the entire session.
    APorig={}
    AP.seen_keys={}
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



-- ===== writer hold: splice FFI writer mods off the chain ==============
-- The 0x66d26c crash family: dsh/codex FFI mods write into engine tables
-- exactly while the engine rebuilds them (boot + first mission entry).
-- We cannot intercept their writes (the ffi proxy route is banned), but
-- we own the chain: a writer layer is spliced OUT by retargeting its
-- caller's upvalue to the writer's own previous, and spliced back after
-- writer_hold_s. Their function is preserved (applied later, on a
-- settled game); none of their state fields is ever touched.
local WH={entry=nil,held={},walks=0,done_walking=false,head_swaps=0,
          gates=setmetatable({},{__mode='k'})}
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
-- Release remains a flag flip. The previous_update slot is stable, including
-- every profiler probe installed there. The owner-labelled source makes the
-- delegated writer work visible to source-based profilers WITHOUT pretending
-- this routing shell is the original callback. Its small forwarding overhead
-- is included in the explicitly marked "[SB gate]" row; our governor retains
-- its own SmoothBoot source and measurements. Never relabel the whole chain.
local WH_GATE_SOURCE=[==[
return function(writer,nextfn,writer_slot,log)
    local previous_update=nextfn
    -- Both gate states must share the same live downstream slot. A profiler
    -- instruments previous_update while the gate is closed; the original
    -- writer must also use that slot after release, rather than bypassing it.
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
    return gate,ctl,downstream
end
]==]
local function wh_make_gate(writer,nextfn)
    local writer_next,writer_slot=wh_next(writer)
    assert(writer_next==nextfn and writer_slot,'writer downstream slot missing')
    local original_name=wh_chunk_of(writer)
    local owner=original_name:gsub('%.lua$','')
    assert(owner~='' and owner:find('mods/',1,true),'writer owner missing')
    -- This compiles OUR routing code once per held writer, never foreign code.
    -- No DLL/FFI hooks, debug.getinfo overrides or profiler tables are changed.
    local factory=assert(loadstring(WH_GATE_SOURCE,'@'..owner..' [SB gate]'))()
    local gate,ctl,downstream=factory(writer,nextfn,writer_slot,log)
    -- Our own discovery keeps the exact original key (including .lua). The
    -- visible adapter suffix must not turn an already-held writer into a new
    -- writer on the next walk. No profiler/global metadata is overwritten.
    chunk_cache[gate]=original_name
    chunk_cache[downstream]=original_name
    WH.gates[gate]=true
    local j=rawget(_G,'jit')
    if type(j)=='table' and type(j.off)=='function' then
        -- A caller trace can inline this tiny helper and keep its old shared
        -- previous_update cell even after a profiler edits the gate's slot.
        -- Interpreter-only for THIS owned forwarding helper prevents that
        -- bypass. No foreign function or global JIT setting is changed.
        j.off(downstream)
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

Candidate 3.0.50: isolates Windows FFI declarations with private aliases; restores each paused table by identity; preserves underscores in exclusions; reads and bounds reentry_max; safely formats foreign errors. New installs leave shared GC policy unchanged (gc_pause=0); explicit existing settings remain. Offline checks do not establish that reported in-game memory leaks or crashes are fixed. Restart to upgrade; live acceptance remains pending.
候选3.0.50：Windows FFI声明改用私有别名；按表身份恢复暂停状态；排除列表保留下划线；读取并限制reentry_max；安全处理异常文本。新安装默认不调整共享GC（gc_pause=0），已有显式配置保留。离线检查不足以证明反馈中的实机泄漏或崩溃已修复；升级需重启，实机验收仍待完成。

Candidate 3.0.49: removes C4-specific adapters and their configuration/diagnostics. Legacy keys are ignored. Boot-pause restoration now drops references to restored foreign state. Restart the game when upgrading; live acceptance remains pending.
候选3.0.49：移除C4专用适配器及其配置与诊断，旧配置项忽略；开局暂停恢复后释放对外部旧状态的引用。升级请重启游戏，实机验收仍待完成。
Candidate 3.0.48: adds a black-box line to the periodic self-report (`blackbox: head=<chain head> open=<n>[<held writers currently allowed to write>] held_closed=<n>`), built from the existing writer-hold table (`WH.held[name].ctl.open`). After a crash the last such line names the set of writers that could have been writing, which is what the dump alone cannot tell (the dump shows the victim instruction, never the writer). Purely additive: no change to the gate, the chain wrapper, timing or release logic.
Candidate 3.0.47: the original-chain pass-through now carries a bounded nesting depth instead of a boolean latch. A legal second dispatch in the same engine call (the shape the priority loaders above us use) is forwarded and still returns the chain's values; only past reentry_max (default 3, clamp 1..16) is a cycle broken, counted in M.reentry_cycles and logged with the depth and the cap. Arity, trailing nils and error identity are preserved on every path. This replaces 3.0.46's boolean swallow, which returned nothing to the caller and was followed by in-game menu, mission-entry and quit stalls on 2026-10-06. Offline suites cover the guard, the observed priority load order (smoothboot -> hd2runtime -> hd2_scanner) and the runtime scheduler; live acceptance is still open.
Candidate 3.0.46 (superseded): original-chain pass-through broke a second re-entry before timing or discovery. Legitimate adopted chains still reach their original downstream once. Success, errors and trailing nil results reset the guard correctly. HD2Runtime 0.28.1's unchanged scheduler has been replayed offline in both load orders; this is not live crash or performance acceptance.
候选3.0.47：原链直通改为有界嵌套深度，取代布尔锁存。同一次引擎调用内的合法二次派发（我们上方的优先加载模组正是这种形状）会被正常转发并仍能拿到链路返回值；只有超过 reentry_max（默认3，范围1..16）才断环，并计入 M.reentry_cycles、连同深度与上限写入日志。所有路径都保留返回值个数、末尾 nil 与异常对象本身。此项取代 3.0.46 的布尔吞掉——它会把空值返回给调用方，2026-10-06 实机随后出现菜单、入队与退出卡死。离线套件已覆盖守卫、实测优先加载顺序（smoothboot → hd2runtime → hd2_scanner）与 runtime 调度器；实机验收仍未完成。
候选3.0.46（已被取代）：原链直通路径在第二次重入时终止循环，保护发生在计时和识别之前。正常接回的调用链仍可转发至原链；成功、异常及末尾nil返回值均会正确复位保护。已离线回放HD2Runtime 0.28.1原始调度器的两种加载顺序；尚未完成实机崩溃与性能验收。

Release 3.0.45: writer hold gates now carry the delegated writer's name plus [SB gate] in source-based profilers. This identifies our routing shell, not a changed third-party file. Released writer work and the shell's forwarding overhead are charged to that row; SmoothBoot's governor keeps its own row. Profiler probes, callback results and release timing are preserved. No work is hidden or disabled to lower the displayed cost.
正式版3.0.45：写入保护门在按源码归属的性能面板中显示被托管模组名称及[SB gate]标记，明确表示这是我们的转发门，并非修改了第三方文件。释放后原模组的执行耗时与门本身的转发开销计入该行；SmoothBoot调度器仍保留独立一行。计时探针、回调返回值和释放时机保留；没有通过隐藏或禁用工作降低显示数值。
Accepted on 2026-10-04: live startup attribution and companion-tool generation, followed by user-operated mission, death/respawn and return-to-ship checks. This is an attribution maintenance release, not a claim of universal compatibility.
2026-10-04验收：实机启动归属与工具生成正常，用户操作的任务、死亡复活、返舰船检查正常。这是计时归属维护版，不承诺所有模组兼容。
Candidate 3.0.44 (bug-fix): the "cannot splice" note now distinguishes the two causes. If the wrapper above keeps no function upvalue as its previous hook, replacing hooks at runtime is why it sits above us and mod order cannot change that; the old wording told users to reorder a list that was already correct.
候选3.0.44（修复版）：把“无法插入”的提示分成两种真实原因。若上方包装层没有用函数 upvalue 保存上一个钩子，那是它运行期重包导致的，调整顺序也没用；旧文案会误导用户去改一个本来就正确的顺序。
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
This protection is not selective per-mod scheduling.
此保护不是逐模组独立节流。
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
  reentry_max=3         nested dispatch cap, integer 1..16 / 嵌套派发上限，整数1..16
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
  Load order: keep SmoothBoot at the BOTTOM of the list (just below Bingus Shared Loader).
Measured 2026-10-06: at the bottom it loads early, so later writers keep us as their
downstream and the writer gate can hold them - the watchdog then shows `mods/<owner>
[SB gate]` rows (275 rows across five owners, including two mods that are not in writers=)
and the log shows writer-hold releases. Moved to the TOP it loaded 61st of 61, the watchdog
showed NO [SB gate] row, and the gate held nothing: every writer had installed first.
Purge and Deploy after any reorder.
Superseded (wrong) wording kept below as history: Arsenal's **default priority** reads the list bottom-up - the bottom entry
loads first (innermost) and the top entry loads last (outermost wrapper). Measured
2026-10-06: SmoothBoot sat at the bottom (index 75/76, patch slot 336, the highest) and
was therefore loaded 13th of 62, i.e. *inside* hd2runtime and hd2_scanner. To let
SmoothBoot wrap the whole chain, put it at the **top** of the list and keep the loader
itself at the bottom (that is the loader's own rule). If you enabled Arsenal's
first-mod priority instead, the mapping inverts: then SmoothBoot belongs at the bottom.
Purge and Deploy after reordering.
Candidate notes keep the older wording below as history. If another
  mod wraps the chain above it, the first-frame line says so and lists the head.
  加载顺序：Arsenal 的**默认优先级**是按列表自下而上读取——最底部先加载（最内层），
（该解读已被实测推翻，见下方更正）。2026-10-06 实测：SmoothBoot 位于最底部（第 75/76 位、
部署槽位 336 即最高），结果在 62 个模组里第 13 个加载，即被 hd2runtime 与 hd2_scanner
包在里面。若要让它包住整条链，应把它保持在列表**最底部**（实测：放底部时写入门有效），而加载器本身保持最底部
（那是加载器自己的规则）。若你启用了 Arsenal 的“首模优先”，映射相反：此时 SmoothBoot
应放最底部。改完顺序后要 Purge → Deploy。
/ 旧表述保留在下方作为历史：若有模组在它上面包住链，
  首帧日志会直接写出链头名字并提示调整顺序。
  Self re-heading only works when the newcomer keeps us in a function upvalue.
  A mod that re-wraps update at runtime and stores its previous hook elsewhere
  (table field, native callback, its own timer) CANNOT be spliced without
  risking its chain: SmoothBoot deliberately leaves it above and says why.
  Putting SmoothBoot lower cannot change that case - the log names the reason.
  / 自我重接管只在“后来者把我们保存在函数 upvalue 里”时有效。若某个模组在运行期
  重包 update，并把上一个钩子存在别处（表字段、原生回调、自己的计时器），硬插进去
  就可能弄坏它的链条，所以我们宁可让它待在上面并写明原因；这种情况下再怎么调整
  顺序也没用，日志会直接告诉你属于哪一种。

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
    for _,key in ipairs({'ModBindingsMenu','TweaksMod','CorpseCleanup',
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
M.init_elapsed_ms=(os.clock()-M.init_started)*1000
log(string.format('ready v%s chain=%s boot_skip=%d exclude=%d init_elapsed_ms=%.2f',
    M.version,tostring(previous~=nil),skip,#excludes,M.init_elapsed_ms))


-- Preserve every result (including trailing nil) without allocating a table
-- or a new completion closure on each callback. Error policies remain distinct.
local function error_text(value)
    local ok,text=pcall(tostring,value)
    if not ok or type(text)~='string' then return 'error value without text' end
    return (text:gsub('[\r\n]+',' '))
end
local function complete_disabled(ok,...)
    inside=false
    if not ok then
        local failure=(...)
        pcall(function()
            local f=io.open(LOG..'.hb','a')
            if f then f:write(os.date('!%H:%M:%S')..' chain error (disabled path): '..error_text(failure)..'\n') f:close() end
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
        local message=error_text(failure)
        pcall(function()
            if M._lasterr~=message then
                M._lasterr=message
                local f=io.open(LOG..'.hb','a')
                if f then f:write(os.date('!%H:%M:%S')..' chain error: '..message..'\n') f:close() end
            end
        end)
        err_total=err_total+1
        M.errors=err_total
        local who=message:match('HD2%-Addon:%s*(mods/[%w_/%-]+)') or 'unknown'
        err_top[who]=(err_top[who] or 0)+1
        if err_total<=10 or err_total%100==0 then
            log('mod chain error #'..err_total..' ['..who..']: '..message)
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
        if cfg.snapshot then pcall(runtime_snapshot) end
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
            -- Black box: one compact line per self-report cycle naming the held writers
            -- allowed to write right now (ctl.open) plus the current chain head. After a
            -- crash, the last such line is the "who could have been writing" set.
            do
                local open={} local nclosed=0
                for n,h in pairs(WH.held) do
                    if h and h.ctl then
                        if h.ctl.open then open[#open+1]=n else nclosed=nclosed+1 end
                    end
                end
                local ok_head,head=pcall(function()
                    if WH.entry then return wh_chunk_of(WH.entry) end
                    return 'self'
                end)
                if not ok_head or type(head)~='string' then head='?' end
                log('blackbox: head='..head..' open='..#open..'['..table.concat(open,','):sub(-200)..
                    '] held_closed='..nclosed)
            end
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
-- Bounded pass-through depth. A boolean here swallowed the *second* legitimate
-- dispatch in the same engine call, which is the path the priority loaders use
-- (load order observed 2026-10-06: #13 smoothboot, #14 hd2runtime, #15 hd2_scanner,
-- i.e. both sit above us and re-enter through this shell). Allow the legal nested
-- dispatch, break only past the cap, and keep counting evidence.
local passthrough_depth=0
local function reentry_cap()
    return math.max(1,math.min(16,math.floor(tonumber(cfg.reentry_max) or 3)))
end
local function complete_passthrough(ok,...)
    if passthrough_depth>0 then passthrough_depth=passthrough_depth-1 end
    if not ok then error((...),0) end
    return ...
end

wrapper=function(...)
    -- An adopted head legitimately returns through us once to reach the
    -- original chain. If that chain dispatches through update again, that call is
    -- still a legal dispatch (memory scanners and runtime schedulers do it), so it
    -- is forwarded until reentry_max nesting is reached; only then is a cycle
    -- broken. Reset on both success and error, preserving arity.
    if inside then
        local below=WH.entry or base_prev
        if type(below)~='function' then return end
        local cap=reentry_cap()
        if passthrough_depth>=cap then
            M.reentry_cycles=(M.reentry_cycles or 0)+1
            if M.reentry_cycles==1 then
                log(string.format('update re-entry cycle detected and broken (depth %d >= reentry_max %d, original chain redispatched through SmoothBoot)',passthrough_depth,cap))
            end
            return
        end
        in_frames=in_frames+1
        passthrough_depth=passthrough_depth+1
        return complete_passthrough(pcall(below,...))
    end
    local nowf=os.clock()
    local diag2_t0=nowf
    if nowf>last_call then
        fi_t=fi_t+(nowf-last_call); fi_n=fi_n+1
        if fi_n>=600 then fi_t=fi_t/2; fi_n=fi_n/2 end
    end
    last_call=nowf
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
            (who=='self' and '' or ' (another mod wraps the chain above SmoothBoot right now; everything below it stays managed - the next note says whether mod order can change that)'))
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
    if head~=wrapper and not WH.gates[head] then
        -- A writer gate is our own routing, even though its visible label
        -- names the delegated work. Adopting it as a new foreign head would
        -- make gate -> governor -> gate recurse and lose callback results.
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
                if splice_kind=='indirect' then
                    log('adopted chain head back from '..who..
                        ' (indirect splice at depth '..tostring(splice_depth or 1)..
                        ': another wrapper sat between us)')
                else
                    log('adopted chain head back from '..who..' (governor active again)')
                end
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
                    -- 3.0.43: whether reordering can help depends on WHY we could
                    -- not splice. If the head keeps some other function as its
                    -- previous hook, another wrapper sits between us and putting
                    -- SmoothBoot last fixes it. If it keeps no function upvalue at
                    -- all (the previous hook lives in a table field), mod order
                    -- cannot change anything and we must say so, not send the user
                    -- to reorder a list that is already correct.
                    local has_prev=false
                    local idx2=1
                    while true do
                        local k,v=debug.getupvalue(head,idx2)
                        if not k then break end
                        if type(v)=='function' then has_prev=true end
                        idx2=idx2+1
                    end
                    log('cannot splice '..who..' (its wrapper keeps no upvalue pointing at us) - '..
                        (has_prev and 'another wrapper sits between SmoothBoot and it: put SmoothBoot last in the mod list to wrap the whole chain'
                                  or 'its previous hook is not held as a function upvalue, so mod order cannot put SmoothBoot above it')..
                        '; everything below SmoothBoot stays managed')
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

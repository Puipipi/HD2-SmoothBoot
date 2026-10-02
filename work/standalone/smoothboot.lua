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
local KEY='HD2SmoothBoot'
local old=rawget(_G,KEY)
if old and old.version=='3.0.7' then return old end
local M={version='3.0.7',status='starting'}
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

local function conf()
    local defaults={enabled=true,throttle='auto',profile=true,boot_skip=1,boot_s=0,grace_s=60,busy_ms=12,idle_ms=1.5,max_skip=2,
                    trip_ms=50,trip_n=3,pause_s=5,exclude='',gc_pause=400,gc_stepmul=0,peer_suspend=true,ui_mods='',scanners='',hud_lang='auto',hud='on',boot_pause_s=10,
                    writer_release_s=10,writer_stagger_s=8,writer_norelease='m103_frv',ui_chunks='gun_calibration,helmet_cape_passives',writers='p33_missile_pistol,p34_breacher,gp20_ultimatum,m103_frv,ac8_rack,k9_p,no_large_piercing,maxigun,tank_cooldown,maelstrom_traverse,tank_clutch_tuner,tank_seat_kit',
                    -- 3.0.5+ adaptive release gate: release every writer_min_stagger_s
                    -- while the frame cadence is near this machine's own best, and
                    -- wait whenever it drifts past writer_fi_factor * best (capped at
                    -- writer_fi_floor_ms * 2.5). The old gate only waited above a flat
                    -- 40 ms, so a 60 FPS task window - exactly where these writer
                    -- writes detonate - counted as calm and every release landed in it.
                    writer_min_stagger_s=1,writer_fi_factor=3,writer_fi_floor_ms=12}
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
                w:write('throttle=yes\nprofile=yes\n')
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
                w:write('exclude=\n')
                w:write('# GC tuning for the whole mod ecosystem (0 = engine defaults)\n')
                w:write('gc_pause=400\ngc_stepmul=0\n')
                w:close()
            end
        end)
        return defaults
    end
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
        v=line:match('^%s*hud_lang%s*=%s*(%a+)%s*$')
        if v then defaults.hud_lang=v:lower() end
        v=line:match('^%s*diag%s*=%s*(%a+)%s*$')
        if v then defaults.diag=(v=='yes' or v=='true' or v=='on') end
        v=line:match('^%s*boot_freeze_s%s*=%s*(%d+%.?%d*)%s*$')
        if v then defaults.boot_freeze_s=tonumber(v) end
        v=line:match('^%s*hud%s*=%s*(%a+)%s*$')
        if v then defaults.hud=(v:lower()~='off') end
        v=line:match('^%s*profile%s*=%s*(%a+)%s*$')
        if v then defaults.profile=(v=='yes' or v=='true' or v=='on') end
        v=line:match('^%s*peer_suspend%s*=%s*(%a+)%s*$')
        if v then defaults.peer_suspend=(v=='yes' or v=='true' or v=='on') end
        for _,key in ipairs({'boot_skip','boot_s','grace_s','busy_ms','busy_pct','idle_ms','max_skip',
                             'trip_ms','trip_n','pause_s','gc_pause','gc_stepmul','boot_pause_s',
                             'writer_release_s','writer_stagger_s',
                             'writer_min_stagger_s','writer_fi_factor','writer_fi_floor_ms'}) do
            v=line:match('^%s*'..key..'%s*=%s*(%d+%.?%d*)%s*$')
            if v then defaults[key]=tonumber(v) end
        end
        v=line:match('^%s*exclude%s*=%s*([%w%./_,%-]+)%s*$')
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
    local ctl={open=false}
    local busy=false
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
            local r={pcall(writer,...)}
            busy=false
            if r[1] then return unpack(r,2,#r) end
            error(r[2],0)
        end
        local r2={pcall(previous_update,...)}
        busy=false
        if r2[1] then return unpack(r2,2,#r2) end
        error(r2[2],0)
    end
    return gate,ctl
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
            -- frame-critical / UI chunk protection (config-driven): these
            -- mods break visibly when throttled (halved draw rate, dead
            -- panels) but expose no _G marker, so we match by chunk name
            if not M._fc_found then
                local list=cfg.ui_chunks or 'gun_calibration,helmet_cape_passives'
                for frag in list:gmatch('[%w_./%-]+') do
                    if frag~='' and name:find(frag,1,true) then
                        M._fc_found=true
                        ui_present=true
                        log('frame-critical mod on chain ('..name..') - throttling suspended')
                        break
                    end
                end
            end
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
    -- gate maintenance: the watchdog spy storm rewrites previous-slots and
    -- strips our gates out of above-us callers. Re-splice any gate that no
    -- longer sits in its slot (closed gates protect, open gates keep the
    -- writer alive - both must survive). Watchdog re-arms its own probes
    -- constantly, so displacing one is mutually-healing, not a fight.
    local respliced=0
    for name,h in pairs(WH.held) do
        if h.caller and h.gate then
            local _,v=debug.getupvalue(h.caller,h.slot)
            if v~=h.gate then
                pcall(debug.setupvalue,h.caller,h.slot,h.gate)
                respliced=respliced+1
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
    if not WH.inventory then return end
    M._fragn = M._fragn or {}
    local function check(list, individual, skip)
        local missing = {}
        for frag in (list or ''):gmatch('[%w_./%-]+') do
            if skip and skip:find(frag, 1, true) then
                -- shipped default: our own fragment, never warn about it
            elseif frag ~= '' and not WH.inventory:find(frag, 1, true) and not M._fragn[frag] then
                M._fragn[frag] = true
                missing[#missing+1] = frag
                if individual then
                    local hint = ''
                    local stem = frag:sub(1, 4):lower()
                    for name in WH.inventory:gmatch('[%w_./%-]+%.lua') do
                        if #frag >= 4 and name:lower():find(stem, 1, true) then
                            hint = ' - did you mean "' .. (name:match('([^/]+)%.lua') or name) .. '"?'
                            break
                        end
                    end
                    log('config check: "' .. frag .. '" matched no mod on the chain' .. hint ..
                        ' (fragments must match the names in the chain inventory line)')
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

[Report an issue / 反馈问题]
  The game creates Collect-Logs.bat next to this README on first run
  (folder: %LOCALAPPDATA%\CowboyBingus\Helldivers2\SmoothBoot\).
  / 首次运行游戏后，本 README 旁边会自动生成 Collect-Logs.bat。
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
  exclude=FRAG,...      never manage these mods / 排除托管
  writers=FRAG,...      writer mods held at boot / 开机扣留的写入器
  writer_release_s=10   seconds before first release / 首个放行延时
  writer_stagger_s=8    seconds between releases / 放行间隔
  writer_norelease=FRAG never released / 永不放行
    NOTE: the m103 FRV turret writer is held permanently BY DEFAULT - its
    delayed write crashed 3/3 test sessions. To re-enable it at your own
    risk, set: writer_norelease= (empty value) in config.txt.
    / 默认永久扣留 m103 炮塔写入器（其延迟写入实测必崩）；自担风险放开：
    / 在 config.txt 写一行 writer_norelease= （等号后留空）
  ui_chunks=FRAG,...    frame-critical mods / 关键帧模组保护
  throttle=auto/yes/no, hud=on/off, diag=yes/no ...
  Where do fragments come from? The "chain inventory" line in SmoothBoot.log
  lists every mod's exact name - copy any unique piece. If you mistype one,
  the log will say: config check: ... did you mean "..."?
  / 片段来自 SmoothBoot.log 里的 "chain inventory" 行；填错时日志会提示正确名称。

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
powershell -NoProfile -Command "$ErrorActionPreference='Stop'; $base=Join-Path $env:LOCALAPPDATA 'CowboyBingus\Helldivers2'; $stage=$null; try { $mode=Read-Host 'Collect logs (C) / Exclude a mod (E)'; if ($mode -eq 'E') { $log=Join-Path $base 'Logs\SmoothBoot.log'; if (-not (Test-Path -LiteralPath $log)) { throw 'No SmoothBoot.log. Start the game once first.' }; $inv=Get-Content -LiteralPath $log -Encoding UTF8 | Where-Object {$_ -match 'chain inventory'} | Select-Object -Last 1; if (-not $inv) { throw 'No chain inventory yet. Let initialization finish first.' }; $names=$inv -replace '^.*chain inventory[^:]*:',''; $mods=@($names -split ',\s*' | ForEach-Object {$_.Trim()} | Where-Object {$_ -match '^mods/[\w./-]+$' -and $_ -notmatch 'smoothboot|^mods/mdl/'} | Select-Object -Unique); if ($mods.Count -eq 0) { throw 'No manageable mods in the inventory.' }; for($i=0; $i -lt $mods.Count; $i++) { Write-Host (' {0,2}. {1}' -f ($i+1),$mods[$i]) }; $n=Read-Host 'Mod NUMBER (0 = cancel)'; $idx=0; if (-not [int]::TryParse($n,[ref]$idx) -or $idx -lt 0 -or $idx -gt $mods.Count) { throw 'Invalid mod number.' }; if ($idx -gt 0) { $frag=$mods[$idx-1] -replace '\.lua$',''; $cfg=Join-Path $base 'SmoothBoot\config.txt'; $cur=@(); if (Test-Path -LiteralPath $cfg) { $cur=@(Get-Content -LiteralPath $cfg -Encoding UTF8) }; $existing=@($cur | Where-Object {$_ -match '^\s*exclude\s*='} | Select-Object -Last 1); $values=@(); if($existing.Count) { $values=@(($existing[0] -replace '^\s*exclude\s*=\s*','') -split ',' | ForEach-Object {$_.Trim()} | Where-Object {$_}) }; $values=@(@($values)+@($frag) | Select-Object -Unique); $kept=@($cur | Where-Object {$_ -notmatch '^\s*exclude\s*='}); $updated=@($kept)+@('exclude='+($values -join ',')); [IO.File]::WriteAllLines($cfg,$updated,(New-Object Text.UTF8Encoding($false))); Write-Host ('DONE: exclude='+($values -join ',')); Write-Host 'To undo, remove only this mod from the exclude= list.'; }; } elseif ($mode -eq 'C') { if (-not (Test-Path -LiteralPath $base)) { throw 'No mod log directory. Start the game with SmoothBoot enabled first.' }; $desktop=[Environment]::GetFolderPath('Desktop'); if (-not $desktop -or -not (Test-Path -LiteralPath $desktop)) { $desktop=Join-Path $base 'SmoothBoot' }; $zip=Join-Path $desktop ('SmoothBoot-logs-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+([guid]::NewGuid().ToString('N').Substring(0,6))+'.zip'); $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()); $stage=Join-Path $tempRoot ('SmoothBoot-collect-'+[guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($stage); foreach($group in @('Logs','SmoothBoot')) { $from=Join-Path $base $group; $to=Join-Path $stage $group; [void][IO.Directory]::CreateDirectory($to); if (Test-Path -LiteralPath $from) { Get-ChildItem -LiteralPath $from -File | Where-Object {$_.Extension -in @('.log','.hb','.txt','.bat')} | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $to }; }; }; $crashPath=Join-Path $stage 'crashes.txt'; try { $crash=@(Get-WinEvent -FilterHashtable @{LogName='Application';Id=1000} -MaxEvents 120 -ErrorAction Stop | Where-Object {$_.Message -match 'helldivers'} | ForEach-Object { '{0} {1}' -f $_.TimeCreated,($_.Message -replace '\s+',' ') }); if (-not $crash.Count) {$crash=@('No matching crash records.')}; $crash | Set-Content -LiteralPath $crashPath -Encoding UTF8; } catch { ('Crash records unavailable: '+$_.Exception.Message) | Set-Content -LiteralPath $crashPath -Encoding UTF8 }; $modsRoot=Join-Path $env:LOCALAPPDATA 'hd2arsenal\mods'; $rows=@(); if(Test-Path -LiteralPath $modsRoot) { $rows=@(Get-ChildItem -LiteralPath $modsRoot -Directory | ForEach-Object { $_.Name }) }; $rows | Set-Content -LiteralPath (Join-Path $stage 'modlist.txt') -Encoding UTF8; $db=Join-Path $env:LOCALAPPDATA 'hd2arsenal\hd2a_data.json'; if(Test-Path -LiteralPath $db) { try { $data=Get-Content -LiteralPath $db -Raw -Encoding UTF8 | ConvertFrom-Json; $data.modsList.default.mods | Select-Object label,enabled,deployed | Export-Csv -LiteralPath (Join-Path $stage 'mod-status.csv') -NoTypeInformation -Encoding UTF8; } catch { ('Mod status unavailable: '+$_.Exception.Message) | Set-Content -LiteralPath (Join-Path $stage 'mod-status-error.txt') -Encoding UTF8 }; }; Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip; if(-not (Test-Path -LiteralPath $zip)) { throw 'Log ZIP was not created.' }; Write-Host ('Done: '+$zip); } else { throw 'Choose C or E.' }; } catch { Write-Host ('FAILED: '+$_.Exception.Message); exit 1 } finally { if($stage -and (Test-Path -LiteralPath $stage)) { $resolved=[IO.Path]::GetFullPath($stage); if($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^SmoothBoot-collect-[0-9a-f]{32}$') { [IO.Directory]::Delete($resolved,$true) } } }"
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

log(string.format('ready v%s chain=%s boot_skip=%d exclude=%d',
    M.version,tostring(previous~=nil),skip,#excludes))


-- ===== throttle HUD (right-top pixel banner, Gui.rect only) ==============
-- Recipe verified on this machine by the Custom Armor Kit / MultiPerk 1.1.1
-- dock: create_screen_gui(world,'scale',1,1) + Gui.rect + sr.Color. No
-- Gui.text, no material, no atlas - the only primitives that have never
-- faulted. Every stingray call is wrapped in pcall; the first failure
-- disables the banner for the rest of the session.
local SCANNER_GLOBALS={'mods/dsh/ac8_rack_backpack','HD2_NoLargePiercing_Owner'}
-- user32 cursor sampling (Custom-Armor-Kit recipe) for the banner buttons.
--
-- FFI NAMESPACE RULE (3.0.3, Nexus bug report 2026-10-01): LuaJIT's C
-- namespace is PROCESS-GLOBAL and ffi.cdef SILENTLY IGNORES a re-declaration
-- of a symbol that is already declared - the first declaration wins and every
-- later caller is type-checked against it (the re-declaration raises nothing,
-- so a pcall around ffi.cdef cannot detect it). Declaring the cursor APIs here
-- is exactly what broke Clickable Scrollbars 2.14: its own
--   int GetCursorPos(HD2CS_POINT *) / int GetClientRect(void*, HD2CS_RECT *)
-- was dropped in favour of our int32_t * versions, so its very first
-- calibration call died with
--   GetCursorPos: bad argument #1 (cannot convert 'struct N [1]' to 'int *')
-- and the mod disabled itself for the session (ClickableScrollbars.log:
-- status=disabled; Nexus: "causes the Clickable Scrollbars part of Vanilla+ to
-- cease functioning"). So: never declare a user32 symbol again. Resolve the
-- addresses through kernel32 and ffi.cast each one to the prototype we call.
-- GetModuleHandleA/GetProcAddress are the only symbols we declare, and every
-- mod in the ecosystem declares them compatibly.
local u32,sampling_ok=Nil,false
pcall(function()
    local ffi=require('ffi')
    ffi.cdef[[
        void *GetModuleHandleA(const char *name);
        void *GetProcAddress(void *module, const char *name);
    ]]
    local k32=ffi.load('kernel32')
    local hmod=k32.GetModuleHandleA('user32.dll')
    if hmod==Nil then return end
    local function bind(proto,name)
        local ok,addr=pcall(function() return k32.GetProcAddress(hmod,name) end)
        if not ok or addr==Nil then return Nil end
        local okc,fn=pcall(ffi.cast,proto,addr)
        if not okc then return Nil end
        return fn
    end
    local api={
        GetForegroundWindow=bind('void *(*)(void)','GetForegroundWindow'),
        GetCursorPos=bind('int (*)(int32_t *)','GetCursorPos'),
        ScreenToClient=bind('int (*)(void *, int32_t *)','ScreenToClient'),
        GetClientRect=bind('int (*)(void *, int32_t *)','GetClientRect'),
        GetAsyncKeyState=bind('int16_t (*)(int)','GetAsyncKeyState'),
    }
    if api.GetForegroundWindow==Nil or api.GetCursorPos==Nil
       or api.ScreenToClient==Nil or api.GetClientRect==Nil
       or api.GetAsyncKeyState==Nil then return end
    u32=api
    sampling_ok=true
end)
local s_pt= sampling_ok and require('ffi').new('int32_t[2]') or nil
local s_rc= sampling_ok and require('ffi').new('int32_t[4]') or nil
local HUD={failed=false,gui=nil,world=nil,sig=nil,checked=0}
local function hud_detect_scanners()
    local found={}
    for _,g in ipairs(SCANNER_GLOBALS) do
        if type(rawget(_G,g))~='nil' then
            local short=g:match('ac8') and 'AC8' or g:match('NoLarge') and 'NOLP' or g
            found[#found+1]=short
        end
    end
    for extra in (cfg.scanners or ''):gmatch('[%w_]+') do
        if type(rawget(_G,extra))~='nil' then found[#found+1]=extra end
    end
    return found
end
local HUD_FONT={}
do
    local defs={
        ['0']='0110 1001 1001 1001 0110',['1']='0100 1100 0100 0100 1110',
        ['2']='1110 0001 0110 1000 1111',['3']='1110 0001 0110 0001 1110',
        ['4']='1001 1001 1111 0001 0001',['5']='1111 1000 1110 0001 1110',
        ['6']='0111 1000 1110 1001 0110',['7']='1111 0001 0010 0100 0100',
        ['8']='0110 1001 0110 1001 0110',['9']='0110 1001 0111 0001 1110',
        A='0110 1001 1111 1001 1001',B='1110 1001 1110 1001 1110',
        C='0111 1000 1000 1000 0111',D='1110 1001 1001 1001 1110',
        E='1111 1000 1110 1000 1111',F='1111 1000 1110 1000 1000',
        G='0111 1000 1011 1001 0111',H='1001 1001 1111 1001 1001',
        I='1110 0100 0100 0100 1110',L='1000 1000 1000 1000 1111',
        M='1001 1111 1111 1001 1001',N='1101 1011 1001 1001 1001',
        O='0110 1001 1001 1001 0110',P='1110 1001 1110 1000 1000',
        R='1110 1001 1110 1010 1001',S='0111 1000 0110 0001 1110',
        T='1111 0100 0100 0100 0100',U='1001 1001 1001 1001 0110',
        V='1001 1001 1001 0110 0110',W='1001 1001 1111 1111 1001',
        X='1001 0110 0110 0110 1001',Y='1001 0110 0100 0100 0100',
        ['-']='0000 0000 1111 0000 0000',[' ']='0000 0000 0000 0000 0000',
        ['.']='0000 0000 0000 0000 0100',['|']='0100 0100 0100 0100 0100',
        [':']='0000 0100 0000 0100 0000',['/']='0001 0010 0100 1000 0000',
    }
    -- CJK glyphs: 10 rows x 10 cols of '1'/'0', rendered taller than ASCII
    HUD_FONT['节']={
        '0000111100','0000111100','1111111111','0000111100','0000111100',
        '0000110110','0000111111','0000111110','0000111100','0000111000'}
    HUD_FONT['流']={
        '0100000000','0010000011','0100111110','0001001001','0001001001',
        '0111001010','0001001010','0001000110','0001000010','0000000000'}
    for ch,def in pairs(defs) do
        local rows={}
        for row in def:gmatch('%d+') do rows[#rows+1]=row end
        HUD_FONT[ch]=rows
    end
end
local function hud_destroy()
    if HUD.gui and HUD.world then
        local sr=rawget(_G,'stingray')
        if sr then pcall(sr.World.destroy_gui,HUD.world,HUD.gui) end
    end
    HUD.gui,HUD.sig=nil,nil
end
local function hud_world()
    local sr=rawget(_G,'stingray')
    if type(sr)~='table' or type(sr.Application)~='table' then return nil end
    local okw,worlds=pcall(sr.Application.worlds)
    if not okw or type(worlds)~='table' then return nil end
    local okm,main=pcall(sr.Application.main_world)
    for _,cand in ipairs(worlds) do
        if not (okm and cand==main) then return cand end
    end
    return nil
end
local hud_zones={}   -- {x,y,w,h,action} in gui units, rebuilt each draw
local function hud_show(text,extra)
    local sr=rawget(_G,'stingray')
    if type(sr)~='table' or type(sr.Gui)~='table' or type(sr.World)~='table' then return false,'stingray missing' end
    local G=sr.Gui
    if not HUD.gui then
        local w=hud_world()
        if not w then return false,'no world yet' end
        local okg,gui=pcall(sr.World.create_screen_gui,w,'scale',1,1)
        if not okg or gui==nil then return false,'create failed' end
        HUD.gui,HUD.world=gui,w
    end
    local okr,rw,rh=pcall(G.resolution)
    if not okr or type(rw)~='number' or rw<640 or type(rh)~='number' or rh<480 then return false,'resolution' end
    local okv1,v3=pcall(sr.Vector3,0,0,0)
    local okv2,v2=pcall(sr.Vector2,1,1)
    local okc,col=pcall(sr.Color,255,255,215,60)
    local okc2,bg=pcall(sr.Color,150,10,10,14)
    if not (okv1 and okv2 and okc and okc2) then return false,'ctors' end
    local scale=math.min(rw/1920,rh/1080)
    local cell=math.max(2,math.floor(2.4*scale))
    local wpx,hpx=8*scale,5*cell+6*scale
    local i=1
    while i<=#text do
        local key=text:sub(i,i)
        if key:byte()>=0x80 then key=text:sub(i,i+2) i=i+3 else i=i+1 end
        local rows=HUD_FONT[key] or HUD_FONT[' ']
        wpx=wpx+(#rows[1]+1)*cell
        if #rows*cell+6*scale>hpx then hpx=#rows*cell+6*scale end
    end
    -- room for the two buttons: X (1ch) and OFF (3ch), each boxed
    wpx=wpx+(1*5+4)*cell+4*scale+(3*5+4)*cell+4*scale
    local x0=rw-wpx-10*scale
    local y0=rh-hpx-8*scale
    pcall(G.rect,HUD.gui,sr.Vector3(x0,y0,980),sr.Vector2(wpx,hpx),bg)
    hud_zones={}
    local px=x0+4*scale
    local i=1
    while i<=#text do
        local key=text:sub(i,i)
        if key:byte()>=0x80 then key=text:sub(i,i+2) i=i+3 else i=i+1 end
        local rows=HUD_FONT[key] or HUD_FONT[' ']
        local h,wd=#rows,#rows[1]
        for r=1,h do
            local row=rows[r]
            for n=1,wd do
                if row:sub(n,n)=='1' then
                    pcall(G.rect,HUD.gui,sr.Vector3(px+(n-1)*cell,y0+3*scale+(h-r)*cell,984),sr.Vector2(cell,cell),col)
                end
            end
        end
        px=px+(wd+1)*cell
    end
    -- [X] dismiss once, [OFF] forever - gold-outlined boxes with gaps
    local okc3,dim=pcall(sr.Color,235,168,178,186)
    local okc4,gold=pcall(sr.Color,230,255,215,60)
    local btns={{label='X',action='dismiss'},{label='OFF',action='never'}}
    for bi,b in ipairs(btns) do
        local bw=(#b.label*5+4)*cell
        local bh=7*cell
        local bx=px+4*scale
        local by=y0+(hpx-bh)/2
        -- backdrop, gold outline (all four sides), label centered
        pcall(G.rect,HUD.gui,sr.Vector3(bx,by,982),sr.Vector2(bw,bh),bg)
        pcall(G.rect,HUD.gui,sr.Vector3(bx,by,985),sr.Vector2(bw,cell),gold)
        pcall(G.rect,HUD.gui,sr.Vector3(bx,by+bh-cell,985),sr.Vector2(bw,cell),gold)
        pcall(G.rect,HUD.gui,sr.Vector3(bx,by,985),sr.Vector2(cell,bh),gold)
        pcall(G.rect,HUD.gui,sr.Vector3(bx+bw-cell,by,985),sr.Vector2(cell,bh),gold)
        local qx=bx+2*cell
        local qy=by+(bh-5*cell)/2
        for ci=1,#b.label do
            local rows=HUD_FONT[b.label:sub(ci,ci)]
            for r=1,#rows do
                local row=rows[r]
                for n=1,#row do
                    if row:sub(n,n)=='1' then
                        pcall(G.rect,HUD.gui,sr.Vector3(qx+(ci-1)*5*cell+(n-1)*cell,qy+(#rows-r)*cell,984),sr.Vector2(cell,cell),dim)
                    end
                end
            end
        end
        hud_zones[#hud_zones+1]={x=bx,y=by,w=bw,h=bh,action=b.action}
        px=px+bw+4*scale
    end
    -- widen the background to what we actually drew
    pcall(G.rect,HUD.gui,sr.Vector3(x0,y0,979),sr.Vector2(px-x0+4*scale,hpx),bg)
    M._hud_draw=string.format('x0=%.0f px=%.0f rw=%.0f zones=%d',x0,px,rw,#hud_zones)
    return true
end

local hud_dismissed=false
local hud_was_down=false
local function hud_click_raw()
    local sr=rawget(_G,'stingray')
    if type(sr)~='table' then return nil end
    local okr,rw,rh=pcall(sr.Gui.resolution)
    if not okr or type(rw)~='number' then return nil end
    local win=u32.GetForegroundWindow()
    if win==nil then return nil end
    if u32.GetCursorPos(s_pt)==0 then return nil end
    if u32.ScreenToClient(win,s_pt)==0 then return nil end
    if u32.GetClientRect(win,s_rc)==0 then return nil end
    local w,h=s_rc[2]-s_rc[0],s_rc[3]-s_rc[1]
    if not(w>0 and h>0) then return nil end
    local gx,gy=s_pt[0]*rw/w,(h-s_pt[1])*rh/h
    local ks=tonumber(u32.GetAsyncKeyState(0x01))
    local down=ks~=nil and ks<0
    local clicked=false
    if down and not hud_was_down then
        for _,z in ipairs(hud_zones) do
            if gx>=z.x and gx<=z.x+z.w and gy>=z.y and gy<=z.y+z.h then
                clicked=z.action
            end
        end
    end
    hud_was_down=down
    return clicked
end
-- any fault in the sampling path (an odd FFI declaration from another mod, a
-- window that vanished mid-call) must never escape into the update chain
local function hud_click()
    if not (sampling_ok and HUD.gui) then return nil end
    local ok,res=pcall(hud_click_raw)
    if not ok then return nil end
    return res
end
-- Language detection, Custom-Armor-Kit 2.0.3 method: a Chinese game keeps
-- Chinese text in its high string-pool arenas; one plain find per 256KB slice
-- for a known Chinese perk name decides zh. Absent after the sweep = en.
-- Runs as a low-priority background stepper (one slice every 30 frames,
-- starting after the init grace), so the first banner may briefly show in
-- English and flips to Chinese within seconds.
local LANG={state='idle',regions=nil,ri=1,off=0,result=nil}
local LANG_CACHE=HOME..'SmoothBoot/lang.txt'
do
    local ok,text=pcall(function()
        local f=io.open(LANG_CACHE,'r') if not f then return nil end
        local t=f:read('*l') f:close() return t
    end)
    if ok and (text=='zh' or text=='en') then
        LANG.result=text LANG.state='done'
    end
end
local LANG_NEEDLE='肾上腺素除颤器'
local function lang_ffi()
    local ok,ffi=pcall(require,'ffi')
    if not ok then return nil end
    local okc=pcall(function()
        ffi.cdef[[
            int ReadProcessMemory(void *process,const void *address,void *buffer,size_t size,size_t *read);
            size_t VirtualQuery(const void *address,void *mbi,size_t len);
            void *GetCurrentProcess(void);
        ]]
    end)
    if not okc then return nil end
    return ffi
end
local function lang_regions(ffi)
    local k=ffi.load('kernel32')
    local mbi=ffi.new('uint8_t[48]')
    local list={}
    local cursor=0x100000000          -- high arenas only (string pool lives here)
    local limit=0x800000000000
    local guard=0
    while cursor<limit and guard<5000 do
        guard=guard+1
        local n=tonumber(k.VirtualQuery(ffi.cast('const void*',cursor),mbi,48))
        if n==0 then break end
        local base=tonumber(ffi.cast('uint64_t*',mbi)[0])
        local size=tonumber(ffi.cast('uint64_t*',mbi)[3])
        local prot=tonumber(ffi.cast('uint32_t*',mbi+36)[0])
        if size==0 then break end
        local readable=(prot==0x02 or prot==0x04 or prot==0x20 or prot==0x40)
        local committed=(tonumber(ffi.cast('uint32_t*',mbi+32)[0])==0x1000)
        if readable and committed and size>=65536 then
            list[#list+1]={base=base,size=size}
        end
        cursor=base+size
    end
    return list
end
local lang_buf=nil
local function lang_scan_step()
    if LANG.state=='done' then return end
    if not LANG.regions then
        local ffi=lang_ffi()
        if not ffi then LANG.state='done' LANG.result='en' return end
        LANG.regions=lang_regions(ffi)
        log('lang sweep: '..#(LANG.regions or {})..' high region(s) to check')
        if not LANG.regions or #LANG.regions==0 then LANG.state='done' LANG.result='en' return end
        LANG.ffi=ffi
        lang_buf=ffi.new('uint8_t[8388608]')
        LANG.proc=ffi.load('kernel32').GetCurrentProcess()
    end
    local r=LANG.regions[LANG.ri]
    if not r then
        LANG.state='done'
        LANG.result=LANG.result or 'en'
        log('lang: sweep finished - banner language locked to '..LANG.result:upper())
        pcall(function()
            local f=io.open(LANG_CACHE,'w')
            if f then f:write(LANG.result) f:close() end
        end)
        return
    end
    local want=math.min(8388608,r.size-LANG.off)
    if want<=0 then LANG.ri=LANG.ri+1 LANG.off=0 return end
    local got=LANG.ffi.new('size_t[1]')
    local ok=LANG.ffi.load('kernel32').ReadProcessMemory(LANG.proc,
        LANG.ffi.cast('const void*',r.base+LANG.off),lang_buf,want,got)
    LANG.off=LANG.off+want
    if ok~=0 and tonumber(got[0])==want then
        local text=LANG.ffi.string(lang_buf,want)
        if text:find(LANG_NEEDLE,1,true) then
            LANG.state='done'
            LANG.result='zh'
            HUD.sig=nil       -- force a banner redraw in the new language
            log('lang: Chinese game text detected - banner in Chinese')
            pcall(function()
                local f=io.open(LANG_CACHE,'w')
                if f then f:write('zh') f:close() end
            end)
        end
    end
end
local function resolve_hud_lang()
    local want=cfg.hud_lang or 'auto'
    if want=='zh' or want=='en' then return want end
    return LANG.result or 'en'
end

local function hud_tick(active,busy,avg_ms)
    M._hud_k=(M._hud_k or 0)+1
    if HUD.failed then return end
    if cfg.hud==false then return end
    local shown=active or busy
    if not shown then
        hud_dismissed=false
        if HUD.gui then hud_destroy() end
        return
    end
    -- button polling while visible
    local click=hud_click()
    if click=='dismiss' then
        hud_dismissed=true
        hud_destroy()
        log('hud dismissed for this episode')
        return
    elseif click=='never' then
        cfg.hud=false
        hud_destroy()
        pcall(function()
            local f=io.open(CFG,'a')
            if f then f:write('\nhud=off\n') f:close() end
        end)
        log('hud permanently disabled via banner button (hud=off written to config)')
        return
    end
    if hud_dismissed then return end
    local scanners=hud_detect_scanners()
    local ms=avg_ms<1 and '<1' or tostring(math.floor(avg_ms+0.5))
    local who=#scanners>0 and table.concat(scanners,' ') or 'CHAIN'
    local zh=resolve_hud_lang()=='zh'
    local txt
    if active then
        txt=zh and ('SB 节流 '..ms..'MS '..who) or ('SB THROTTLED '..ms..'MS '..who)
    else
        txt=zh and ('SB 链忙 '..ms..'MS 保护中') or ('SB BUSY '..ms..'MS PROTECTED')
    end
    if txt==HUD.sig and os.clock()-(HUD.built_at or 0)<20 then return end
    hud_destroy()
    HUD.built_at=os.clock()
    local ok,why=hud_show(txt)
    if ok then HUD.sig=txt
    else
        if why=='no world yet' then return end
        HUD.failed=true
        log('hud disabled: '..tostring(why))
    end
end

wrapper=function(...)
    local nowf=os.clock()
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
    do
        local hb=function(txt)
            pcall(function()
                local f=io.open(LOG..'.hb','a')
                if f then f:write(os.date('!%H:%M:%S')..' '..txt..'\n') f:close() end
            end)
        end
        if frames==1 then hb('first frame; head_is_self='..tostring(rawget(_G,'update')==wrapper)) end
        if frames%600==0 then hb('alive frames='..frames) end
    end
    if frames==1 then
        if cfg.diag then pcall(runtime_snapshot) end
        local hh=rawget(_G,'update')
        local who='?'
        if hh~=wrapper then
            local ok,r=pcall(function() return debug.getinfo(hh,'S').source or '?' end)
            if ok then who=(r:match('mods/[%w_./%-]+') or r:sub(1,40)) end
        else who='self' end
        log('first frame reached, head='..who)
    end
    if frames%120==0 or frames==1 then
        local ok,err=pcall(wh_full_walk)
        if not ok then log('writer hold: walk ERROR: '..tostring(err)) end
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
    local head=rawget(_G,'update')
    local transition_target=nil
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
                -- Its own callback already ran above us, but the below-chain
                -- has not run yet. Preserve it on this transition frame too.
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
    if LANG.state~='done' and os.clock()-installed_at>30 and frames%10==0
       and (HUD.gui~=nil or frames%60==0) then
        pcall(lang_scan_step)
    end
    if frames%60==0 then
        local avg=stats.n>0 and stats.total/stats.n or 0
        local eff2=cfg.busy_ms or 12
        if cfg.busy_pct and cfg.busy_pct>0 and fi_n>=120 then
            local fi_ms=fi_t/math.max(1,fi_n)*1000
            local pct_ms=fi_ms*cfg.busy_pct/100
            if pct_ms>eff2 then eff2=pct_ms end
        end
        local busy=avg>eff2
        if skip>1 or busy or HUD.gui~=nil then
            pcall(hud_tick, skip>1, busy, avg)
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
            if f then f:write(os.date('!%H:%M:%S')..string.format(' diag frames=%d calls=%d head=%s hud_k=%s failed=%s\n',
                frames,calls,who,tostring(M._hud_k),tostring(HUD.failed),tostring(M._hud_draw))) f:close() end
        end)
    end
    if os.clock()-last_cfg>10 then
        last_cfg=os.clock()
        if not M.tools_ready and tool_attempts<6 then provision_tools() end
        cfg=conf()
        excludes=excluded_list(cfg.exclude or '')
        pcall(M.frag_check)
        if not peer_active and type(rawget(_G,'MDL'))=='table' then
            peer_active=true
            if not announced['<peer-mdl>'] then
                announced['<peer-mdl>']=true
                log('peer loader present (global MDL) - unmanaged by design; manual settings have priority')
            end
        end
        local found=detect_ui_mods(cfg.ui_mods)
        -- frame-critical chunk probe: HUD Ballistic Trajectory Overlay has
        -- no _G marker, so scan the chain below us for its chunk (community
        -- reports: throttling halves its draw rate when no UI mod is known)
        if not M._fc_found and frames%600==0 then
            local cur=base_prev
            local d=0
            while type(cur)=='function' and d<16 do
                d=d+1
                if cur==wrapper then cur=WH.entry or base_prev
                else
                    local cn=wh_chunk_of(cur)
                    if cn:find('gun_calibration',1,true) then
                        M._fc_found=true
                        found[#found+1]='gun_calibration(chain)'
                        log('frame-critical mod on chain (gun_calibration) - throttling suspended')
                        break
                    end
                    cur=wh_next(cur)
                end
            end
        end
        if M._fc_found then found[#found+1]='gun_calibration' end
        local now_ui=#found>0
        if now_ui~=ui_present then
            ui_present=now_ui
            if now_ui then
                log('UI mods present ('..table.concat(found,',')..') - throttling suspended to protect their panels')
            else
                log('no UI mods running - automatic throttling allowed (scanners will be curbed)')
            end
        end
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
    if os.clock()-installed_at<bps then
        if frames%30==0 then pcall(ap_scan) end
    else
        ap_restore()
    end

    local target=transition_target or head_above or (WH.entry or base_prev)
    if not target then return end
    if not cfg.enabled then
        inside=true
        local okv,r=pcall(function(...) return {target(...)} end,...)
        inside=false
        if not okv then
            pcall(function()
                local f=io.open(LOG..'.hb','a')
                if f then f:write(os.date('!%H:%M:%S')..' chain error (disabled path): '..tostring(r)..'\n') f:close() end
            end)
            error(r,0)
        end
        if unpack then return unpack(r,1,#r) end
        return
    end
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
    if want_throttle and settled(cfg.grace_s) then cap=skip end
    if cap>1 and frames%math.floor(cap)~=0 then
        skipped=skipped+1
        return
    end
    if peer_active and cfg.peer_suspend and not announced['<peer-suspend>'] then
        announced['<peer-suspend>']=true
        log('peer active: automatic throttling suspended - the peer manual settings have priority (pcall/breaker stay on; set peer_suspend=no to take over again)')
    end
    calls=calls+1
    local t0=os.clock()
    inside=true
    local results={pcall(target,...)}
    inside=false
    local cost=(os.clock()-t0)*1000
    if not results[1] then
        pcall(function()
            if M._lasterr~=tostring(results[2]) then
                M._lasterr=tostring(results[2])
                local f=io.open(LOG..'.hb','a')
                if f then f:write(os.date('!%H:%M:%S')..' chain error: '..tostring(results[2])..'\n') f:close() end
            end
        end)
        err_total=err_total+1
        M.errors=err_total
        local who=tostring(results[2]):match('HD2%-Addon:%s*(mods/[%w_/%-]+)') or 'unknown'
        err_top[who]=(err_top[who] or 0)+1
        if err_total<=10 or err_total%100==0 then
            log('mod chain error #'..err_total..' ['..who..']: '..tostring(results[2]))
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
    if cost>(cfg.trip_ms or 50) and settled(cfg.grace_s) then
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
        if cfg.diag then pcall(runtime_snapshot) end
        if cfg.diag then pcall(c4_snapshot) end
        local top={}
        for k,v in pairs(err_top) do top[#top+1]=k..'='..v end
        table.sort(top,function(a,b) return tonumber(a:match('=(%d+)$'))>tonumber(b:match('=(%d+)$')) end)
        local rehooks={}
        for k,n in pairs(head_seen) do if n>=2 then rehooks[#rehooks+1]=k..' x'..n end end
        if #rehooks>0 then log('rehooks: '..table.concat(rehooks,', ')) end
        local avg_ms=stats.n>0 and stats.total/stats.n or 0
        log(string.format('stats frames=%d calls=%d skipped=%d avg=%.2fms max=%.2fms skip=%d errors=%d top:%s',
            frames,calls,skipped,avg_ms,stats.max,skip,
            err_total,table.concat(top,',',1,math.min(3,#top))))
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
    if results[1] then
        if unpack then return unpack(results,2,#results) end
    end
end
rawset(_G,'update',wrapper)
log('installed v'..M.version..' as the outermost update wrapper (Bingus chain governor)')
return M

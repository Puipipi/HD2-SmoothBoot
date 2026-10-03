-- ContextReader/NativeUiGuard/GameplayGuard reference contracts adapted from HD2 C4 Quick Actions, MIT license.
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


local R,D
local NativeResolver=(function()
 
 
local M={}
local bit=require('bit')
local function u16(b,o) local a,c=b:byte(o+1,o+2);return a+c*256 end
local function u32(b,o) local a,c,d,e=b:byte(o+1,o+4);return a+c*256+d*65536+e*16777216 end
local function i32(b,o) local n=u32(b,o);return n>=0x80000000 and n-4294967296 or n end
local function unhex(h) return (h:gsub('..',function(x)return string.char(tonumber(x,16))end)) end
local function compile(s)
    local raw,mask=unhex(s.hex),unhex(s.mask)
    assert(#raw==#mask and #raw>0 and #raw<=32768,'compat_pattern_size:'..s.name)
    local anchor,offset='',0
    local i=1
    while i<=#mask do
        if mask:byte(i)==255 then
            local first=i
            repeat i=i+1 until i>#mask or mask:byte(i)~=255
            if i-first>#anchor then anchor=raw:sub(first,i-1);offset=first-1 end
        else assert(mask:byte(i)==0,'compat_bad_mask');i=i+1 end
    end
    assert(#anchor>=8 or s.from_symbol,'compat_weak_pattern:'..s.name)
    local spans={};i=1
    while i<=#mask do
        if mask:byte(i)==255 then
            local first=i
            repeat i=i+1 until i>#mask or mask:byte(i)~=255
            spans[#spans+1]={first,raw:sub(first,i-1)}
        else i=i+1 end
    end
    return {raw=raw,mask=mask,anchor=anchor,offset=offset,spans=spans}
end
local function matches(data,at,p)
    if at<1 or at+#p.raw-1>#data then return false end
    for _,s in ipairs(p.spans) do
        if data:sub(at+s[1]-1,at+s[1]+#s[2]-2)~=s[2] then return false end
    end
    return true
end
 
 
function M.new_scan(api,game)
    local buffers={}
    local self={read_bytes=0,shared_bytes=0,released=false}
    function self.section(reader,module,rva,n,read)
        assert(not self.released and reader==api and module==game,'compat_scan_identity')
        local key=rva..':'..n
        if buffers[key] then self.shared_bytes=self.shared_bytes+n;return buffers[key] end
        assert(self.read_bytes+n<=64*1024*1024,'compat_shared_scan_budget')
        local bytes=read(rva,n)
        buffers[key]=bytes;self.read_bytes=self.read_bytes+n
        return bytes
    end
    function self.release()buffers=nil;self.released=true end
    return self
end
function M.resolve(api,game,catalog,scan)
    local function read(rva,n)
        assert(rva>=0 and n>0 and rva+n<=0x10000000,'compat_read_bounds')
        local parts={}
        for at=0,n-1,4096 do
            local count=math.min(4096,n-at)
            local b=assert(api.read(game+rva+at,count),'compat_read_unavailable:'..string.format('%x',rva+at))
            assert(#b==count,'compat_short_read');parts[#parts+1]=b
        end
        return table.concat(parts)
    end
    local dos=read(0,64);assert(dos:sub(1,2)=='MZ','compat_dos_header')
    local nt=u32(dos,60);assert(nt>=64 and nt<=0x100000,'compat_pe_offset')
    local head=read(nt,24);assert(head:sub(1,4)=='PE\0\0' and u16(head,4)==0x8664,'compat_pe_x64')
    local count,optional=u16(head,6),u16(head,20)
    assert(count>0 and count<=32 and optional>=112 and optional<=512,'compat_pe_sections')
    local opt=read(nt+24,optional);assert(u16(opt,0)==0x20b,'compat_pe64')
    local image_size=u32(opt,56);assert(image_size>0 and image_size<=0x10000000,'compat_image_size')
    local table_bytes=read(nt+24+optional,count*40)
    local sections,code,total={},{},0
    for i=0,count-1 do
        local o=i*40;local size,rva,flags=u32(table_bytes,o+8),u32(table_bytes,o+12),u32(table_bytes,o+36)
        if size>0 then
            assert(rva>=4096 and rva+size<=image_size,'compat_section_bounds')
            local writable=bit.band(flags,0x80000000)~=0
            local executable=bit.band(flags,0x20000000)~=0
            local s={rva=rva,size=size,region=writable and 'writable' or executable and 'code' or 'readonly'}
            sections[#sections+1]=s
             
             
            if executable and not writable and bit.band(flags,0x60)==0x20 then
                total=total+size;assert(total<=64*1024*1024,'compat_scan_budget')
                code[#code+1]={section=s,data=scan and scan.section(api,game,rva,size,read) or read(rva,size)}
            end
        end
    end
    assert(#code>0,'compat_no_code')
    table.sort(sections,function(a,b)return a.rva<b.rva end)
    for i=2,#sections do assert(sections[i-1].rva+sections[i-1].size<=sections[i].rva,'compat_overlapping_sections') end
    local function region(rva,n)
        if rva==0 then return 'base' end
        for _,s in ipairs(sections) do if rva>=s.rva and rva+n<=s.rva+s.size then return s.region end end
        return 'outside'
    end
    local symbols,guards,observed={},{},{}
    local vehicle_tables,seat_guards={},{}
    local function symbol(name,value)
        assert(not symbols[name] or symbols[name]==value,'compat_reference_conflict:'..name)
        symbols[name]=value
    end
    local function guard(at,n,label)
        assert(region(at,n)~='outside' or at==0,'compat_guard_bounds:'..label)
        local bytes=read(at,n);guards[#guards+1]={at=at,bytes=bytes,label=label};return bytes
    end
     
    for _,s in ipairs(catalog.nodes) do
        local p=compile(s);local hits={}
        if s.from_symbol then
            local parent=assert(symbols[s.from_symbol],'compat_parent_missing:'..s.name)
            local at=parent+s.from_offset
            hits[1]=at+4+i32(read(at,4),0)
            assert(region(hits[1],#p.raw)=='code','compat_derived_target:'..s.name)
            assert(matches(read(hits[1],#p.raw),1,p),'compat_signature_missing:'..s.name)
        else
            for _,c in ipairs(code) do
                local start=1
                while true do
                    local at=c.data:find(p.anchor,start,true)
                    if not at then break end
                    local candidate=at-p.offset
                    if matches(c.data,candidate,p) then hits[#hits+1]=c.section.rva+candidate-1 end
                    assert(#hits<=1,'compat_signature_ambiguous:'..s.name)
                    start=at+1
                end
            end
            assert(#hits==1,'compat_signature_missing:'..s.name)
        end
        symbol(s.name,hits[1]);observed[s.name]=guard(hits[1],#p.raw,s.name)
        assert(matches(observed[s.name],1,p),'compat_signature_changed_during_scan:'..s.name)
    end
    code=nil  
    for _,s in ipairs(catalog.nodes) do
        local at,bytes=symbols[s.name],observed[s.name]
        for _,r in ipairs(s.refs or {}) do
            local target=at+r['end']+i32(bytes,r.at)
            if r.guard_bytes then
                assert(r.region=='readonly' and not r.hex and r.guard_bytes==8,
                    'compat_invalid_runtime_pointer_guard:'..s.name)
            end
            assert(region(target,r.hex and #r.hex/2 or r.guard_bytes or r.region=='writable' and 8 or 1)==r.region,
                'compat_reference_region:'..s.name)
            if r.symbol then symbol(r.symbol,target) end
            if r.relative then assert(target==at+r.relative,'compat_internal_branch:'..s.name) end
            if r.hex then assert(guard(target,#r.hex/2,s.name..':literal')==unhex(r.hex),'compat_literal_changed:'..s.name) end
             
             
             
            if r.guard_bytes then guard(target,r.guard_bytes,s.name..':runtime_pointer') end
        end
        for _,t in ipairs(s.tables or {}) do
            local target=u32(bytes,t.operand)
            assert(region(target,#t.entries*4)=='code','compat_switch_table_region:'..s.name)
            local entries=guard(target,#t.entries*4,s.name..':switch_table')
            for i,relative in ipairs(t.entries) do
                assert(u32(entries,(i-1)*4)==at+relative,'compat_switch_table_changed:'..s.name)
            end
        end
        if s.abilities then
            local a=s.abilities;local table_at=u32(bytes,a.operand)
            local capacity=u32(bytes,a.capacity_offset)+1
            assert(capacity>=521 and capacity<=16384,'compat_ability_capacity')
            for _,t in ipairs(a.targets) do
                local entry_at=table_at+(t.id-1)*4
                assert(region(entry_at,4)=='code','compat_ability_table_region')
                local case_at=u32(guard(entry_at,4,'ability_case_entry'),0)
                assert(region(case_at,#a.case_hex/2)=='code','compat_ability_case_region')
                local body=guard(case_at,#a.case_hex/2,'ability_case_'..t.id)
                assert(matches(body,1,compile{name='ability_case',hex=a.case_hex,mask=a.case_mask}),
                    'compat_ability_case_changed:'..t.id)
                assert(case_at+a.call_end+i32(body,a.call_offset)==symbols[t.symbol],
                    'compat_ability_dispatch_changed:'..t.id)
            end
        end
        if s.vehicle_dispatch then
            local d=s.vehicle_dispatch
             
            local capacity=bytes:byte(d.capacity_offset+1)+1
            assert(capacity<=128,'compat_vehicle_switch_encoding')
            local table_at=u32(bytes,d.table_offset)
            assert(region(table_at,capacity*4)=='code','compat_vehicle_table')
            local entries=guard(table_at,capacity*4,'vehicle_case_entries')
            local pattern=compile{name='vehicle_case',hex=d.case_hex,mask=d.case_mask}
            for config=1,capacity do
                local case_at=u32(entries,(config-1)*4)
                assert(region(case_at,#pattern.raw)=='code','compat_vehicle_case_target')
                local body=guard(case_at,#pattern.raw,'vehicle_case_'..config)
                assert(matches(body,1,pattern),'compat_vehicle_case')
                local tables={}
                for _,key in ipairs({'out','in'}) do
                    local value=u32(body,d[key..'_offset'])
                    assert(region(value,4)=='readonly','compat_vehicle_animation_region')
                    tables[key]=value
                end
                vehicle_tables[config]=tables
            end
        end
    end
    for _,name in ipairs(catalog.required_globals) do assert(symbols[name],'compat_global_missing:'..name) end
    local self={symbols=symbols,fields=catalog.fields,node_count=#catalog.nodes,scan_bytes=total}
    function self.verify()
        for _,g in ipairs(guards) do
            assert(read(g.at,#g.bytes)==g.bytes,'compat_live_code_changed:'..g.label)
        end
    end
    function self.vehicle_lean_available(config,seat)
        local tables=vehicle_tables[config]
        if not tables then return false,'native_vehicle_has_no_lean' end
         
         
        local supported=true
        for _,key in ipairs({'out','in'}) do
            local at=tables[key]+seat*4
            assert(region(at,4)=='readonly','compat_vehicle_seat_region')
            if not seat_guards[at] then
                seat_guards[at]=guard(at,4,'vehicle_seat_animation')
            end
            assert(read(at,4)==seat_guards[at],'compat_vehicle_seat_changed')
            if i32(seat_guards[at],0)<0 then supported=false end
        end
        if not supported then return false,'native_seat_has_no_lean' end
        return true
    end
    self.verify()  
    return self
end
return M

end)()

local PassengerHold={new=function()return {}end}
local PhaseSnapshot=(function()
 
 
local M={}
function M.new(fetch)
    local enabled=false
    local generation=0
    local row,reason,cap
    local self={}
    function self.invalidate()generation=generation+1;row,reason,cap=nil,nil,nil end
    function self.begin_phase()self.invalidate();enabled=true end
    function self.end_phase()enabled=false;self.invalidate() end
    function self.snapshot()
        if enabled and cap then
            local previous=cap
             
            local a,b=row,reason
            self.invalidate()
            local version=generation
            if previous.same() and enabled and generation==version then
                row,reason,cap=a,b,previous;return a,b,previous
            end
        end
        local version=generation
        local a,b,c=fetch()
        if enabled and generation==version and a and c then row,reason,cap=a,b,c end
        return a,b,c
    end
    function self.wrap(target,names)
        for _,name in ipairs(names) do
            local call=assert(target[name],'phase_mutator_missing:'..name)
            target[name]=function(...)
                self.invalidate()
                return call(...)
            end
        end
    end
    return self
end
return M

end)()
local ActionBackend=(function()
 
local M={}
function M.new(api,reader,base,layout,bind,emit,scan)
    local game=assert(api.module('game.dll'),'game_module_missing')
    local resolved=NativeResolver.resolve(api,game,layout,scan)
    R,D=resolved.symbols,resolved.fields
    local native=bind(game)
    local self={compatibility=resolved,input=native}
    local snapshots=PhaseSnapshot.new(function()
        local row,reason,cap=reader.snapshot(api,game,base)
        if not row then return nil,reason end
        return row,nil,cap
    end)
    self.begin_phase=snapshots.begin_phase
    self.end_phase=snapshots.end_phase
    self.invalidate=snapshots.invalidate
     
     
    snapshots.wrap(native,{'start','consume','after','lean','reload','input_inhibit','input_unblock'})
    snapshots.wrap(api,{'fire_gate_exchange','passenger_exchange'})
    function self.verify() resolved.verify() end
    self.passenger=PassengerHold.new(api,game,base,self.verify,emit)
    function self.close()self.end_phase();return self.passenger.stop('shutdown_or_fault')end
    function self.maintain(enabled,now)
        if not self.passenger.lease then return end
        local _,_,cap=self.snapshot()
        self.passenger.sync(enabled,cap,now)
    end
    function self.snapshot()
        return snapshots.snapshot()
    end
    function self.reload(cap)
        local r=assert(cap and cap.reload,'reload_context_unavailable')
        assert(not cap.interrupt and not r.avatar_active and r.ammo>0,'reload_context_ineligible')
        assert(not cap.active or (cap.deploy_released and not cap.vehicle),'reload_before_throw_release')
        assert(not self.passenger.lease,'reload_during_passenger_throw')
        assert(not cap.vehicle or not cap.vehicle.transition,'reload_during_seat_transition')
        assert(not cap.vehicle or cap.vehicle.idle,'reload_with_pending_seat_animation')
        self.verify();assert(cap.same(),'reload_context_changed')
         
        if not native.reload_eligible(r.manager,cap.weapon_id) then return false,'native_reload_veto' end
        assert(cap.same(),'reload_context_changed_after_query')
        assert(emit('reload_call',{requested_action='RELOAD',action_result='CALL_BEGIN'}),'reload_log_unavailable')
        assert(cap.same(),'reload_context_changed_before_call')
        native.reload(r.manager,cap.weapon_id)
        return true
    end
    function self.prepare_deploy(cap)
        assert(cap and not cap.active and not cap.blocked and cap.deploy_ready,'ineligible_lean_capability')
        local v=assert(cap.vehicle,'no_verified_passenger_seat')
        assert(not v.transition and not v.leaned,'lean_already_active')
        local supported,reason=resolved.vehicle_lean_available(v.config,v.seat)
        if not supported then return false,reason end
        self.verify()
        assert(cap.same(),'vehicle_context_changed')
        native.lean(v.manager,v.avatar_id)
        return true
    end
    function self.execute(action,cap,now)
        assert(action=='DEPLOY' or action=='DETONATE','unsupported_action')
        assert(cap and not cap.active and not cap.blocked,'ineligible_action_capability')
        assert(action~='DEPLOY' or cap.deploy_ready==true,'native_deploy_ammo_not_ready')
        assert(action~='DEPLOY' or not cap.vehicle or cap.vehicle_ready,'native_lean_not_ready')
        if action=='DEPLOY' and cap.vehicle then self.passenger.ready(cap) end
         
         
        self.verify()
        assert(cap.same(),'action_context_changed')
        local id=action=='DEPLOY' and 521 or 520
         
        native.start(cap.ability_manager,cap.weapon_id,id,1,1.0)
        if action=='DEPLOY' then
            native.consume(cap.weapon_manager,cap.weapon_id)
            local count=native.count(cap.weapon_manager,cap.weapon_id)
            native.after(cap.weapon_data,cap.weapon_id,count,true)
            if cap.vehicle then
                local _,_,fresh=self.snapshot()
                assert(fresh and fresh.identity==cap.identity,'passenger_hold_post_start_context')
                self.passenger.acquire(fresh,now)
            end
        end
        return id
    end
    return self
end
return M

end)()
local NativeActions=(function()
 
return function(game)
    local ffi=require('ffi')
    assert(ffi.os=='Windows' and ffi.abi('64bit'),'windows_x64_required')
    local start=ffi.cast('void (*)(void *, uint32_t, uint32_t, uint32_t, float)',game+R.fn_start)
    local consume=ffi.cast('void (*)(void *, uint32_t)',game+R.fn_consume)
    local count=ffi.cast('int32_t (*)(void *, uint32_t)',game+R.fn_count)
    local after=ffi.cast('void (*)(void *, uint32_t, int32_t, bool)',game+R.fn_after)
    local lean=ffi.cast('void (*)(void *, uint32_t)',game+R.fn_lean)
    local reload=ffi.cast('void (*)(void *, uint32_t, bool)',game+R.fn_reload)
    local reload_eligible=ffi.cast('bool (*)(void *, uint32_t, bool, bool)',game+R.fn_reload_eligible)
    local input_mapping=ffi.cast('void *(*)(void *, uint64_t, bool)',game+R.fn_input_mapping)
    local input_inhibit=ffi.cast('void (*)(void *, uint64_t, uint32_t, float)',game+R.fn_input_inhibit)
    local input_unblock=ffi.cast('void (*)(void *, uint64_t)',game+R.fn_input_unblock)
    return {
        input_mapping=function(manager,action)
            return tonumber(ffi.cast('uintptr_t',input_mapping(ffi.cast('void *',manager),action,true)))
        end,
        input_inhibit=function(manager,action) input_inhibit(ffi.cast('void *',manager),action,1,-1.0) end,
        input_unblock=function(manager,action) input_unblock(ffi.cast('void *',manager),action) end,
        reload=function(manager,id) reload(ffi.cast('void *',manager),id,false) end,
        reload_eligible=function(manager,id)
            return reload_eligible(ffi.cast('void *',manager),id,false,false)
        end,
        lean=function(manager,id) lean(ffi.cast('void *',manager),id) end,
        start=function(manager,id,ability,network,speed)
            start(ffi.cast('void *',manager),id,ability,network,speed)
        end,
        consume=function(manager,id) consume(ffi.cast('void *',manager),id) end,
        count=function(manager,id) return tonumber(count(ffi.cast('void *',manager),id)) end,
        after=function(manager,id,n,enabled) after(ffi.cast('void *',manager),id,n,enabled) end
    }
end

end)()
local AimInputState=(function()
 
local bit=require('bit')
local M={}
function M.read(api,game,base,codes,native,spec)
    spec=spec or {action=D.input_aim_action,code=D.input_aim_code,index=8}
    local guards={}
    local function read(at,n)
        assert(type(at)=='number' and at>=65536 and at+n<0x800000000000
            and n>0 and n<=512 and #guards<1000,'aim_read_bounds')
        local b=assert(api.read(at,n),'aim_read_unavailable');assert(#b==n,'aim_short_read')
        guards[#guards+1]={at,b};return b
    end
    local function ptr(at)return assert(api.pointer(read(at,8)),'aim_pointer')end
    local function same()
        for _,v in ipairs(guards) do if api.read(v[1],#v[2])~=v[2] then return false end end
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
        local tableptr=assert(api.pointer(h),'aim_inhibition_pointer')
        local ended=false
        for i=0,math.min(n,128)-1 do
            local b=read(tableptr+((base.product_low(spec.code,mult)+i)%n)*8,8)
            local key=base.u32(b,0)
            if key==spec.code then index=base.u32(b,4);ended=true;break end
            if key==empty then ended=true;break end
        end
        assert(ended,'aim_inhibition_probe_limit')
    end
    local mask
    if index and index~=0xffffffff then
        assert(index<count,'aim_inhibition_index')
        local address=owner+D.input_inhibit_rows+index*24
        local b=read(address,24)
        assert(base.u32(b,4)==2 and base.u32(b,8)==spec.index,'aim_inhibition_identity')
        mask={address=address,bytes=b,mode=base.u32(b,0)}
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
    for code,key in pairs(wanted) do
      for probe=0,capacity-1 do
        local i=(base.product_low(code,base.u32(bh,16))+probe)%capacity
        local at=buckets+i*328
        if base.u32(read(at,4),0)==code then
            local size=base.u32(read(at+4,4),0);assert(size<=16,'aim_binding_count')
            local mappings={}
            for j=0,size-1 do mappings[#mappings+1]={at=at+8+j*20,bytes=read(at+8+j*20,20)} end
            lists[key]=mappings
            break
        end
      end
    end
    assert(lists.aim and lists.deploy and lists.detonate,'aim_binding_missing')
    assert(same(),'aim_binding_changed')
     
    local chosen=native.input_mapping(owner,spec.action)
    if chosen and chosen~=0 then
        for _,v in ipairs(lists.aim) do
            if v.at==chosen then result.aim=v.bytes;break end
        end
        assert(result.aim,'aim_selected_mapping_outside_bucket')
    end
    result.deploy=lists.deploy;result.detonate=lists.detonate
    assert(same(),'aim_snapshot_changed')
    return result
end
 
 
local function matches(base,a,b)
    local x,y=base.u32(a,0),base.u32(b,0)
    if bit.band(x,0xfff000ff)~=bit.band(y,0xfff000ff) then return false end
    local sx,sy=bit.band(bit.rshift(x,8),255),bit.band(bit.rshift(y,8),255)
    return sx==sy or sx==255 or sy==255
end
function M.policy(base,p)
    if not p.aim then return false,'no_active_aim_mapping' end
    for _,v in ipairs(p.detonate) do
        if matches(base,p.aim,v.bytes) then return true,'detonate_overlap' end
    end
    local release=false
    for _,v in ipairs(p.deploy) do
        if matches(base,p.aim,v.bytes) then
            local kind=bit.band(bit.rshift(base.u32(v.bytes,0),4),15)
             
            if kind~=4 then return true,'throw_non_button_overlap' end
            local trigger=base.u32(v.bytes,8)
            assert(trigger==bit.band(bit.rshift(base.u32(v.bytes,0),16),15) and trigger<=8,
                'aim_trigger_mismatch')
            if trigger==1 or trigger==7 then release=true
            else return true,'throw_overlap' end
        end
    end
    return false,release and 'release_throw_aim_preserved' or 'independent_aim_preserved'
end
return M

end)()
local AimInputGate=(function()
 
 
local M={}
function M.new(api,game,base,backend,profile,emit,spec)
    spec=spec or {action=D.input_aim_action,code=D.input_aim_code,index=8,tag="aim_gate"}
    local tag=spec.tag
    local behavior=spec.fire and "native_fire_input_behavior" or "native_aim_behavior"
    local self={lease=nil,status='starting'}
    local native=backend.input
    local function publish(status,reason)
        if self.status==status and self.reason==reason then return end
        self.status=status;self.reason=reason
        assert(emit(tag,{[tag..'_status']=status,[tag..'_reason']=reason,
            [behavior]=self.lease and 'SUPPRESSED' or 'ORIGINAL',
            [tag..'_owned']=self.lease~=nil}),'aim_gate_log_unavailable')
    end
    local function read(codes)
        return AimInputState.read(api,game,base,codes,native,spec)
    end
    function self.stop()
        local lease=self.lease;if not lease then return true end
        local ok,p=pcall(read)
        if not ok then return false,tostring(p) end
        if p.owner==lease.owner and p.mask and (p.mask.bytes==lease.expected or
            lease.pending and p.mask.mode==1 and p.mask.bytes:sub(17,24)==string.rep('\0',8)) then
            backend.verify();assert(p.same(),'aim_restore_context_changed')
            native.input_unblock(p.owner,spec.action)
            local q=read();assert(q.owner==p.owner and q.mask and q.mask.mode==0,'aim_restore_failed')
        end
         
        self.lease=nil;return true
    end
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
        backend.verify()
        local p=read(codes)
        local suppress,reason=true,'mbm_owns_c4_fire'
        if not spec.fire then suppress,reason=AimInputState.policy(base,p) end
        if self.lease and (self.lease.owner~=p.owner or self.lease.identity~=cap.identity
            or not p.mask or p.mask.bytes~=self.lease.expected) then
            local ok,why=self.stop();assert(ok,why)
            p=read(codes)
        end
        if not suppress then
            local ok,why=self.stop();assert(ok,why);publish('preserved',reason);return
        end
        if self.lease then publish('owned',reason);return end
        if p.mask and p.mask.mode~=0 then publish('external_inhibition');return end
         
         
        if p.held then publish(spec.fire and 'waiting_for_fire_release' or 'waiting_for_aim_release');return end
        assert(p.mask or p.count<D.input_inhibit_capacity,'aim_inhibition_full')
        publish('acquire',reason)
        assert(cap.same() and p.same(),'aim_acquire_context_changed')
        self.lease={owner=p.owner,identity=cap.identity,pending=true}
        native.input_inhibit(p.owner,spec.action)
        local q=read()
        assert(q.owner==p.owner and q.mask and q.mask.mode==1
            and q.mask.bytes:sub(17,24)==string.rep('\0',8),'aim_acquire_failed')
        self.lease.expected=q.mask.bytes
        self.lease.pending=false
        publish('owned',reason)
    end
    function self.sync(enabled,now)
        local ok,why=pcall(step,enabled,now)
        if not ok then
            local restored,ok,reason=pcall(self.stop)
            publish('unavailable',tostring(why)..((not restored or not ok) and '; restore: '..tostring(reason or ok) or ''))
        end
    end
    function self.fields()
        return {[tag..'_status']=self.status,[tag..'_reason']=self.reason,
            [tag..'_owned']=self.lease~=nil,[behavior]=self.lease and 'SUPPRESSED' or 'ORIGINAL'}
    end
    return self
end
return M

end)()

InputFixture={gate=AimInputGate.new,state=AimInputState,resolver=NativeResolver,backend=ActionBackend.new,native=NativeActions,
    layout=function(r,d)R,D=r,d end}

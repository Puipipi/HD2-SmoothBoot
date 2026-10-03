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
    local validation_reads,validation_bytes=0,0
    local extension_result
    local function read(at,n,guard)
        assert(type(at)=='number' and at>=65536 and at+n<0x800000000000,'invalid_address')
        reads=reads+1;bytes=bytes+n
        assert(n>0 and n<=4096 and reads<=768 and bytes<=32768,'snapshot_budget')
        local b=assert(api.read(at,n),'read_unavailable')
        assert(#b==n,'short_read')
        if guard then guards[#guards+1]={at=at,bytes=b} end
        return b
    end
    local function ptr(at,guard)
        local p=assert(api.pointer(read(at,8,guard)),'pointer_unavailable')
        assert(p>=65536 and p<0x800000000000,'invalid_pointer')
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
    local function checked()
         
         
         
        local count,total=0,0
        for _,g in ipairs(guards) do
            local n=#g.bytes;count=count+1;total=total+n
            assert(count<=768 and total<=32768,'snapshot_validation_budget')
            validation_reads=validation_reads+1;validation_bytes=validation_bytes+n
            local b=assert(api.read(g.at,n),'read_unavailable')
            assert(#b==n,'short_read')
            if b~=g.bytes then return false end
        end
        return true
    end
    local row={current_weapon='UNKNOWN',current_fire_mode='UNKNOWN',
        action_result='OBSERVATION_ONLY',context_status='unresolved',
        c4_guard_candidate=false,layout_evidence='STATIC_DERIVATION_PENDING_LIVE_VALIDATION'}
    local function finish(reason)
        if not checked() then return nil,'context_changed_during_read' end
        if reason~='c4_context_observed' then row.c4_guard_candidate=false end
        row.context_status=reason;row.memory_reads=reads+validation_reads;row.memory_bytes=bytes+validation_bytes
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
    local owner=global(R.global_owner)
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

     
     
    local templates=ptr(owner+D.ability_templates,true)
    local start=0
    for b=8,1,-1 do start=(start*256+weapon:byte(b))%D.ability_capacity end
    row.ability_template_status='absent'
    for probe=0,D.ability_capacity-1 do
        local t=read(templates+((start+probe)%D.ability_capacity)*16,16,true)
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
    if extend then
         
         
         
        local ok,result=pcall(extend,{read=read,ptr=ptr,global=global,lookup=lookup,
            checked=checked,u32=u32,hex=hex,resource=resource,entity=entity,weapon=weapon,
            id=id,weapon_id=weapon_id,owner=owner,avatar=avatar,avatar_index=ai,
            weapon_data=wd,weapon_data_index=di},row)
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
local WeaponFireGate=(function()
 
local M={}
local bit=require('bit')

function M.new(api,game,base,emit,verify)
    local NORMAL,MUTED=D.fire_normal,D.fire_muted
    local self={lease=nil,active=false,status='idle',identity=nil}
    local function publish(status,extra)
        if self.status==status and not extra then return end
        self.status=status
        local fields={fire_gate_status=status,fire_gate_active=self.active,
            native_fire_route='Weapon.flags.bit'..D.fire_bit,native_aim_behavior='UNCHANGED'}
        for k,v in pairs(extra or {}) do fields[k]=v end
        assert(emit('fire_gate',fields),'fire_gate_log_unavailable')
    end
    local function current()
        return base.snapshot(api,game,function(e,row)
            local wm=e.global(R.global_weapon)
            local wi=assert(e.lookup(wm+0x28,e.weapon_id,65536),'fire_gate_component_missing')
            assert(wi<4096,'fire_gate_index_limit')
            assert(e.read(e.ptr(e.ptr(wm+0x40,true)+wi*8,true),24,true)==e.weapon,
                'fire_gate_registry_mismatch')
            local address=e.ptr(wm+0x50,true)+wi*40
            local flags=e.u32(e.read(address,4,true),0)
            row.weapon_driver_flags=string.format('%08x',flags)
            assert(flags==NORMAL or flags==MUTED,'fire_gate_unsupported_flags')
             
             
            local driver=e.global(R.global_fire_latch)
            local di=assert(e.lookup(driver+0x20,e.weapon_id,65536),'fire_gate_driver_missing')
            assert(di<4096,'fire_gate_driver_index_limit')
            assert(e.read(e.ptr(e.ptr(driver+0x38,true)+di*8,true),24,true)==e.weapon,
                'fire_gate_driver_identity_mismatch')
            local held=e.read(e.ptr(driver+0x48,true)+di*8,1,true):byte()~=0
            return {weapon_id=e.weapon_id,weapon=e.weapon,owner=e.owner,manager=wm,
                address=address,flags=flags,held=held,same=e.checked,
                identity=table.concat({e.hex(e.entity),e.hex(e.weapon),tostring(e.owner)},':')}
        end)
    end
     
     
    local function saved(lease)
        local guards,reads={},0
        local function read(at,n)
            assert(type(at)=='number' and at>=65536 and at+n<0x800000000000,'fire_gate_bad_address')
            reads=reads+1;assert(reads<=400 and n>0 and n<=32,'fire_gate_restore_budget')
            local b=assert(api.read(at,n),'fire_gate_restore_read_unavailable')
            assert(#b==n,'fire_gate_restore_short_read');guards[#guards+1]={at,b};return b
        end
        local function ptr(at) return assert(api.pointer(read(at,8)),'fire_gate_restore_bad_pointer') end
        local function lookup(at,key)
            local h=read(at,20);local n,empty,mult=base.u32(h,8),base.u32(h,12),base.u32(h,16)
            assert(n<=1048576 and (n==0 or bit.band(n,n-1)==0),'fire_gate_restore_map')
            if n==0 or key==empty or key==0xffffffff then return nil end
            local p=assert(api.pointer(h),'fire_gate_restore_map_pointer')
            for i=0,math.min(n,128)-1 do
                local b=read(p+((base.product_low(key,mult)+i)%n)*8,8)
                local k,index=base.u32(b,0),base.u32(b,4)
                if k==key then return index~=0xffffffff and index or nil end
                if k==empty then return nil end
            end
            error('fire_gate_restore_probe_limit')
        end
        local wm,owner=ptr(game+R.global_weapon),ptr(game+R.global_owner)
        if wm~=lease.manager or owner~=lease.owner then return nil,'entity_epoch_gone' end
        local ei=lookup(owner+D.entity_id_map,lease.weapon_id)
        if not ei then return nil,'entity_gone' end
        assert(ei<262144,'fire_gate_restore_entity_index')
        if read(owner+D.entity_array+ei*24,24)~=lease.weapon then return nil,'entity_reused' end
        local wi=lookup(wm+0x28,lease.weapon_id)
        if not wi then return nil,'component_gone' end
        assert(wi<4096,'fire_gate_restore_index')
        if read(ptr(ptr(wm+0x40)+wi*8),24)~=lease.weapon then return nil,'registry_reused' end
        local address=ptr(wm+0x50)+wi*40
        local flags=base.u32(read(address,4),0)
        for _,g in ipairs(guards) do assert(api.read(g[1],#g[2])==g[2],'fire_gate_restore_changed') end
        return {address=address,flags=flags}
    end
    function self.stop()
        self.active=false;self.identity=nil
        local lease=self.lease
        if not lease then return true end
        local ok,p,reason=pcall(saved,lease)
        if not ok then self.status=tostring(p);return false,self.status end
        if not p then self.lease=nil;self.status=reason;return true end
        if p.flags==MUTED then
            local restored,why=api.fire_gate_exchange(p.address,MUTED,NORMAL)
            if not restored then self.status=why;return false,why end
        elseif p.flags~=NORMAL then
             
            self.status='fire_gate_restore_configuration_changed';return false,self.status
        end
        self.lease=nil;self.status='restored';return true
    end
    function self.sync(enabled,released)
        self.active=false;self.identity=nil
        if not enabled and not self.lease then publish('disarmed');return false end
        local ok,row,why,plan=pcall(current)
        if not ok then why=row;row=nil end
        if not enabled or not plan then
             
             
             
            if not enabled and plan and self.lease and plan.identity==self.lease.identity and not released then
                publish('waiting_for_mouse_release');return false
            end
            local restored,reason=self.stop();assert(restored,reason)
            publish(not enabled and 'disarmed' or row and row.action_context_error or why or 'outside_c4')
            return false
        end
        if self.lease and self.lease.identity~=plan.identity then
            local restored,reason=self.stop();assert(restored,reason)
        end
        if not self.lease then
            if plan.flags~=NORMAL then publish('preexisting_fire_gate_not_owned');return false end
            if not released or plan.held then publish('waiting_for_released_baseline');return false end
            if verify then verify() end
             
            publish('acquire',{selected_entity_id=plan.weapon_id,flags_before=string.format('%08x',NORMAL),flags_after=string.format('%08x',MUTED)})
            assert(plan.same(),'fire_gate_acquire_context_changed')
            self.lease=plan  
            local written,reason=api.fire_gate_exchange(plan.address,NORMAL,MUTED)
            assert(written,reason)
        elseif plan.flags~=MUTED then
            error('fire_gate_changed_while_owned')
        end
        self.active=true;self.identity=plan.identity
        publish('owned');return true
    end
    function self.fields()
        return {fire_gate_active=self.active,fire_gate_status=self.status,
            fire_gate_restore_pending=self.lease~=nil and not self.active,
            native_aim_behavior='UNCHANGED'}
    end
    return self
end
return M


end)()

FireFixture={base=ContextReader,new_gate=WeaponFireGate.new,layout=function(r,d)R,D=r,d end}

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

-- Pinned original C4 1.11 reference for owned-memory tests, no entrypoint or native actions.
local R,D
local AvatarFlags=(function()
 
local M={}
function M.has(bytes,index)
    assert(type(index)=='number' and index>=0 and index<192,'invalid_avatar_flag')
    local byte=assert(bytes:byte(math.floor(index/8)+1),'short_avatar_flags')
    return math.floor(byte/2^(index%8))%2==1
end
return M


end)()

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

local NativeUiGuard=(function()
 
 
local M={}
local bit=require('bit')
function M.new(api,game,base)
    local function read(at,n)
        assert(type(at)=='number' and at>=65536 and at+n<0x800000000000,'ui_bad_address')
        local bytes=assert(api.read(at,n),'ui_read_unavailable')
        assert(#bytes==n,'ui_short_read')
        return bytes
    end
    local function avatar_ui()
        local ok,row,reason,extra=pcall(base.snapshot,api,game,function(e)
            local flags=e.read(e.avatar+0x53e880+e.avatar_index*0x1238,24,true)
            return {tactical_map_active=AvatarFlags.has(flags,D.tactical_map),
                weapon_menu_active=AvatarFlags.has(flags,D.weapon_menu)}
        end)
        return ok and extra or {}
    end
    return function()
        local pointer=read(game+R.global_ui,8)
        local manager=assert(api.pointer(pointer),'ui_manager_unavailable')
        local bytes=read(manager+D.ui_shift+0x84,0x90)
        local u32=base.u32
        local primary,modal=u32(bytes,0),u32(bytes,4)
        local count,secondary,pending=u32(bytes,0x1c),u32(bytes,0x84),u32(bytes,0x8c)
        assert(count<=5 and secondary<=25,'ui_stack_capacity_changed')
        local stack={}
        local active=primary~=0 or modal~=0 or secondary~=0 or pending~=0
        for i=1,count do
            stack[i]=u32(bytes,8+(i-1)*4)
            active=active or stack[i]~=0
        end
        assert(read(game+R.global_ui,8)==pointer and read(manager+D.ui_shift+0x84,0x90)==bytes,
            'ui_state_changed_during_read')
        local avatar=avatar_ui()
        return {native_ui_available=true,native_ui_active=active,
            native_ui_primary=primary,native_ui_modal=modal,native_ui_stack=table.concat(stack,','),
            native_ui_stack_count=count,
            native_ui_secondary_count=secondary,native_ui_pending=pending,
            tactical_map_active=avatar.tactical_map_active==true,
            weapon_menu_active=avatar.weapon_menu_active==true}
    end
end
return M


end)()

local GameplayGuard=(function()
 
 
local M={}
local function boolean(v)
    assert(type(v)=='boolean' or v==0 or v==1,'invalid_window_state')
    return v==true or v==1
end
function M.new(engine,emit,native_ui)
    local self={ready=false,status=nil,last_key=nil,latest={}}
    local function window_state()
        local window=assert(type(engine.Window)=='table' and engine.Window,'window_api_missing')
        assert(type(window.has_focus)=='function' and type(window.show_cursor)=='function','window_api_missing')
        local row={window_has_focus=boolean(window.has_focus()),
            window_show_cursor=boolean(window.show_cursor())}
         
         
        if type(window.mouse_focus)=='function' then
            row.window_mouse_focus=boolean(window.mouse_focus())
        end
        for k,v in pairs(native_ui()) do row[k]=v end
        return row
    end
    function self.sample(foreground,guard_held,released)
        local ok,row=pcall(window_state)
        if not ok then row={window_state_error=tostring(row)} end
        local reason=not ok and 'window_state_unavailable' or
            (not foreground or not row.window_has_focus) and 'focus_lost' or
            row.tactical_map_active and 'tactical_map_open' or
            row.weapon_menu_active and 'weapon_settings_open' or
            row.native_ui_active and 'native_game_ui_active' or
            row.window_show_cursor and 'game_ui_cursor_visible' or
            guard_held and 'reload_or_menu_key_held' or nil
        if reason then self.ready=false
        elseif not self.ready then
            if released then self.ready=true else reason='waiting_for_released_controls' end
        end
        local allowed=self.ready and reason==nil
        row.controls_allowed=allowed;row.runtime_state=reason or 'gameplay'
        row.activation='AUTOMATIC_LOCAL_C4'
        self.latest=row;self.status=row.runtime_state
        local key=table.concat({self.status,tostring(row.window_has_focus),tostring(row.window_show_cursor),
            tostring(row.window_mouse_focus),tostring(row.window_state_error),
            tostring(row.native_ui_primary),tostring(row.native_ui_modal),
            tostring(row.native_ui_pending),tostring(row.native_ui_secondary_count),
            tostring(row.native_ui_stack),tostring(row.tactical_map_active),tostring(row.weapon_menu_active)},':')
        if key~=self.last_key then
            assert(emit('gameplay_guard',row),'gameplay_guard_log_unavailable');self.last_key=key
        end
        return allowed
    end
    function self.fields() return self.latest end
    return self
end
return M


end)()

C4Fixture={base=ContextReader,flags=AvatarFlags,new_ui=NativeUiGuard.new,new_guard=GameplayGuard.new,set_layout=function(r,d)R,D=r,d end}

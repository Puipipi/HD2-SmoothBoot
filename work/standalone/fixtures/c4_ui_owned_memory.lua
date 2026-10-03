-- Owned process allocation only. No game process access.

ffi=require('ffi');ffi.cdef[[void *GetCurrentProcess(void);
int ReadProcessMemory(void *,const void *,void *,size_t,size_t *);]]
k=ffi.load('kernel32');process=k.GetCurrentProcess()
memory=ffi.new('uint8_t[65536]');address=tonumber(ffi.cast('uintptr_t',memory))
game=address;mode=address+0x100;pm=address+0x1000;owner=address+0x4000
avatar=address+0x8000;inventory=address+0x9000;wd=address+0xb000
function w(p,o,n)ffi.cast('uint32_t *',p+o)[0]=n end
function pw(p,o,n)ffi.cast('uintptr_t *',p+o)[0]=n end
function hashwrite(p,h)
  local bytes=h:gsub('..',function(s)return string.char(tonumber(s,16))end):reverse()
  ffi.copy(ffi.cast('void *',p),bytes,8)
end
function map(p,o,storage,key,index)
 pw(p,o,storage);w(p,o+8,2);w(p,o+12,0xffffffff);w(p,o+16,1)
 w(storage,0,0xffffffff);w(storage,8,0xffffffff)
 w(storage,(key%2)*8,key);w(storage,(key%2)*8+4,index)
end
R={global_mode=8,global_player=16,global_owner=24,global_avatar=32,
   global_inventory=40,global_weapon_data=48}
D={entity_unit_map=0x100,entity_id_map=0x140,entity_array=0x1000,
   ability_templates=0x200,ability_capacity=16}
pw(game,8,mode);pw(game,16,pm);pw(game,24,owner);pw(game,32,avatar)
pw(game,40,inventory);pw(game,48,wd);w(mode,8,1);w(mode,0x40,1)
w(pm,0x84,1);w(pm,0x88,1);pw(pm,0xe8,address+0xc000)
memory[0xc000+20]=1;w(pm,0x3a8,1)
local entity=owner+0x1000;local weapon=entity+24
hashwrite(entity,'4d1c334d294dfa97');w(entity,8,1);ffi.cast('uint8_t *',entity)[20]=1
hashwrite(weapon,'51f50d6321f52f3d');w(weapon,8,2);ffi.cast('uint8_t *',weapon)[20]=1
map(owner,0x100,address+0xc100,1,0);map(owner,0x140,address+0xc200,2,1)
map(avatar,0xf8,address+0xc300,1,0);w(avatar,0x6c,1);pw(avatar,0x110,entity)
map(inventory,0x28,address+0xc400,1,0);w(inventory,0x14,1)
pw(inventory,0x40,address+0xc500);pw(address+0xc500,0,entity)
pw(inventory,0x50,address+0xc600);w(address+0xc600,0,2);w(address+0xc600,0x1c,1)
pw(owner,0x200,address+0xc700)
api={};calls=0;fail_large=false
local buffer,count=ffi.new('uint8_t[4096]'),ffi.new('size_t[1]')
function api.read(at,n)
 calls=calls+1;assert(n>0 and n<=4096)
 if fail_large and n>100 then return nil end
 count[0]=0
 if k.ReadProcessMemory(process,ffi.cast('const void *',at),buffer,n,count)==0 or
    tonumber(count[0])~=n then return nil end
 return ffi.string(buffer,n)
end
function api.pointer(bytes)
 local p=ffi.new('uintptr_t[1]');ffi.copy(p,bytes,8);return tonumber(p[0])
end
function extend(e,row)
 assert(e.checked(),'extension_guard_rejected')
 for i=0,199 do e.read(address+0xd000+i*8,4,true)end
 return {same=e.checked,weapon_id=e.weapon_id}
end

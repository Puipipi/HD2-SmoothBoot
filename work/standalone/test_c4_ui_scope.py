"""Replay actual C4 UI closure on owned native memory; no live game access.

The UI's flags-only consumer is exercised with its actual ContextReader and
NativeUiGuard source, including the current Smooth context adapter. Layout
fixture is synthetic. Read savings here are not an FPS or full-C4 cost claim.
"""
import argparse
import ctypes
import os
import tempfile
import unittest
import lupa.luajit21 as luajit
import json
from pathlib import Path
import statistics

REPO = Path(__file__).resolve().parents[2]
ROOT = REPO.parent.parent
SB = Path(__file__).with_name('smoothboot.lua')
OUT = ROOT/'outputs/validated-2026-10-04/c4-ui-scope'
DLL = os.environ.get('HD2_LUA_DLL', r'D:\Program Files (x86)\Steam\steamapps\common\Helldivers 2\bin\lua51.dll')

class VM:
    def __init__(self, game):
        self.game=game
        if not game:
            self.rt=luajit.LuaRuntime(unpack_returned_tuples=True)
            return
        self.dll=ctypes.CDLL(DLL)
        for name,args in {
            'luaL_openlibs':[ctypes.c_void_p],
            'luaL_loadbuffer':[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_size_t,ctypes.c_char_p],
            'lua_pcall':[ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_int],
            'lua_tolstring':[ctypes.c_void_p,ctypes.c_int,ctypes.POINTER(ctypes.c_size_t)],
            'lua_settop':[ctypes.c_void_p,ctypes.c_int],
            'lua_close':[ctypes.c_void_p],
        }.items():getattr(self.dll,name).argtypes=args
        self.dll.luaL_newstate.restype=ctypes.c_void_p
        self.dll.lua_tolstring.restype=ctypes.c_char_p
        self.state=self.dll.luaL_newstate()
        self.dll.luaL_openlibs(self.state)

    def run(self, code):
        if not self.game:return self.rt.execute(code)
        data=code.encode('utf-8')
        rc=self.dll.luaL_loadbuffer(self.state,data,len(data),b'@private/c4-ui-scope-test.lua')
        if not rc:rc=self.dll.lua_pcall(self.state,0,1,0)
        value=self.dll.lua_tolstring(self.state,-1,None)
        result=value.decode('utf-8') if value else None
        self.dll.lua_settop(self.state,0)
        if rc:raise RuntimeError(result)
        return result

    def close(self):
        if self.game:self.dll.lua_close(self.state)


def setup(vm, source, reference=False):
    vm.run((REPO/'work/standalone/fixtures/c4_ui_owned_memory.lua').read_text(encoding='utf-8'))
    original_file=ROOT/'work/c4-current/9ba626afa44a3aa3.patch_0.lua'
    if original_file.exists() and not reference:
        c4=original_file.read_text(encoding='utf-8')
        prefix=c4[:c4.index("local existing = rawget(_G, 'HD2C4BoundaryProbe')")]
        prefix+='\nC4Fixture={base=ContextReader,flags=AvatarFlags,new_ui=NativeUiGuard.new,new_guard=GameplayGuard.new,set_layout=function(r,d)R,D=r,d end}\n'
    else:
        prefix=(REPO/'work/standalone/fixtures/c4_ui_reference.lua').read_text(encoding='utf-8')
    # Define the original factories only. Never execute WindowsRead/ActionBackend
    # or the original entrypoint. Every API callback points to our own memory.
    vm.run("package.preload['mods/etxp/c4_quick_actions_catalog']=function()return {version='1.11',native={},contact={}}end\n"
           "assert(loadstring([====["+prefix+"\n"
           "]====],'@mods/etxp/c4_boundary_probe.lua'))()")
    vm.run(r'''
      original=C4Fixture.base;C4Fixture.set_layout(R,D)
      -- Separate pinned avatar region accommodates the real flags offset.
      avatar_memory=ffi.new('uint8_t[0x550000]')
      new_avatar=tonumber(ffi.cast('uintptr_t',avatar_memory))
      ffi.copy(ffi.cast('void *',new_avatar),ffi.cast('const void *',avatar),0x200)
      avatar=new_avatar;pw(game,32,avatar)
      flag_address=avatar+0x53e880
      D.tactical_map=20;D.weapon_menu=22;D.ui_shift=0;R.global_ui=64
      ui_manager=address+0xe000;pw(game,64,ui_manager)
      function flags(map,menu)
        ffi.cast('uint8_t *',flag_address)[2]=(map and 16 or 0)+(menu and 64 or 0)
      end
      flags(true,false)
      -- A populated 128-entry template table models the scanner's probe work.
      -- Only the UI's caller consumes flags; these fields are unrelated to it.
      D.ability_capacity=128;local templates=address+0xc700;pw(owner,0x200,templates)
      local hash='51f50d6321f52f3d';local weapon=owner+0x1000+24
      local start=0
      for b=8,1,-1 do start=(start*256+ffi.string(ffi.cast('const char *',weapon),8):byte(b))%128 end
      for i=0,127 do hashwrite(templates+i*16,'0011223344556677')end
      hashwrite(templates+((start+127)%128)*16,hash)
      w(templates,((start+127)%128)*16+8,0)
      original_read=api.read
      function upvalue(f,key)
        for i=1,64 do local n,v=debug.getupvalue(f,i);if not n then break end
          if n==key then return v,i end
        end
      end
    ''')
    vm.run("M={};cfg={enabled=true,c4_context_batch=true};excludes={};log=function()end;"
           "function is_excluded()return excluded==true end;"
           "function function_chunk(f)return (debug.getinfo(f,'S').source or ''):match('mods/[%w_./%-]+') or '' end\n"
           +source[source.index('-- BEGIN C4 INPUT BATCH'):source.index('-- END C4 READ POOL')])
    vm.run(r'''
      base={snapshot=original.snapshot,u32=original.u32}
      assert(M.c4_context_batch.attach(base),'exact original context signature mismatch')
      original_ui=C4Fixture.new_ui(api,game,base)
      avatar_ui=assert(upvalue(original_ui,'avatar_ui'))
      ui=original_ui
      local len,hash=M.c4_input_batch.signature(avatar_ui)
      local len2,hash2=M.c4_input_batch.signature(ui)
      fingerprint=table.concat({len,hash,len2,hash2},',')
      calls=0;local first=ui();assert(first.tactical_map_active and not first.weapon_menu_active)
      baseline_reads=calls
      original_fields=first
      if M.c4_ui_scope then assert(M.c4_ui_scope.attach(ui),'UI attachment failed')end
      calls=0;local second=ui()
      for k,v in pairs(first)do assert(second[k]==v,'changed UI result '..k)end
      candidate_reads=calls
    ''')


CONTRACTS = r'''
  -- Fresh flags and complete native stack are preserved on every invocation.
  flags(false,true);local p=ui();assert(not p.tactical_map_active and p.weapon_menu_active)
  w(ui_manager,0x84,7);p=ui();assert(p.native_ui_active and p.native_ui_primary==7)
  w(ui_manager,0x84,0);flags(false,false);p=ui();assert(not p.native_ui_active)
  -- Stale/reused identities, mission state, ownership, registry, selected weapon.
  local function no_flags()local q=ui();assert(not q.tactical_map_active and not q.weapon_menu_active)end
  flags(true,true)
  w(mode,8,0);no_flags();w(mode,8,1)
  memory[0xc000+20]=0;no_flags();memory[0xc000+20]=1
  ffi.cast('uint8_t *',owner+0x1000)[20]=0;no_flags();ffi.cast('uint8_t *',owner+0x1000)[20]=1
  w(address+0xc600,0x1c,0);no_flags();w(address+0xc600,0x1c,1)
  hashwrite(owner+0x1000+24,'0011223344556677');no_flags()
  hashwrite(owner+0x1000+24,'9b75217d8312dd67');no_flags()
  hashwrite(owner+0x1000+24,'51f50d6321f52f3d')
  w(owner+0x1000+24,8,999);no_flags();w(owner+0x1000+24,8,2)
  pw(avatar,0x110,owner+0x1000+24);no_flags();pw(avatar,0x110,owner+0x1000)
  ffi.cast('uint8_t *',owner+0x1000+24)[20]=0;no_flags()
  ffi.cast('uint8_t *',owner+0x1000+24)[20]=1
  -- Missing flag data returns unknown/false without changing input handling.
  api.read=function(at,n)if at==flag_address then return nil end;return original_read(at,n)end
  no_flags();api.read=original_read
  api.read=function(at,n)if at==flag_address then return '\0' end;return original_read(at,n)end
  no_flags();api.read=original_read
  -- Mutation during collection must reject the stale identity/flag snapshot.
  local changed=false
  api.read=function(at,n)
    local bytes=original_read(at,n)
    if at==flag_address and not changed then changed=true;w(address+0xc600,0x1c,2)end
    return bytes
  end
  no_flags();api.read=original_read;w(address+0xc600,0x1c,1)
  assert(ui().tactical_map_active and ui().weapon_menu_active)
  -- Original method/upvalue changes: no frozen API, base, field/helper state.
  local original_avatar_ui=avatar_ui
  local _,api_slot=upvalue(original_avatar_ui,'api')
  local alt_api={read=function(at,n)
    if at==flag_address then return string.rep('\0',24)end
    return original_read(at,n)
  end,pointer=api.pointer}
  debug.setupvalue(original_avatar_ui,api_slot,alt_api);no_flags()
  debug.setupvalue(original_avatar_ui,api_slot,api)
  local previous=base.snapshot;local fallback_calls=0
  base.snapshot=function(...)fallback_calls=fallback_calls+1;return previous(...)end
  assert(ui().tactical_map_active and fallback_calls==1);base.snapshot=previous
  local _,base_slot=upvalue(original_avatar_ui,'base');local other={snapshot=base.snapshot,u32=base.u32}
  debug.setupvalue(original_avatar_ui,base_slot,other)
  assert(ui().tactical_map_active);debug.setupvalue(original_avatar_ui,base_slot,base)
  -- Opt-out and restore, never overwriting a later third-party replacement.
  cfg.enabled=false;calls=0;assert(ui().tactical_map_active);assert(calls==baseline_reads)
  cfg.enabled=true;cfg.c4_context_batch=false;calls=0;ui();assert(calls==baseline_reads)
  cfg.c4_context_batch=true;excluded=true;calls=0;ui();assert(calls==baseline_reads);excluded=false
  local record=assert(M.c4_ui_scope.records[ui])
  assert(M.c4_ui_scope.attach(ui) and M.c4_ui_scope.active==1,'repeat attachment must not count twice')
  M.c4_ui_scope.restore();assert(upvalue(ui,'avatar_ui')==avatar_ui)
  assert(M.c4_ui_scope.attach(ui))
  local later=function()return {tactical_map_active=false,weapon_menu_active=false}end
  local _,slot=upvalue(ui,'avatar_ui');debug.setupvalue(ui,slot,later)
  M.c4_ui_scope.restore();assert(upvalue(ui,'avatar_ui')==later)
  debug.setupvalue(ui,slot,avatar_ui)
  assert(not M.c4_ui_scope.attach(function()end))
  print('PASS UI fields, fresh flags, identity/mission/ownership/registry/weapon changes, errors, mutation rejection, dynamic captures, opt-out and restoration')
'''

INTEGRATION = r'''
  flags(false,false)
  cfg.enabled=true;cfg.c4_context_batch=true;cfg.c4_read_pool=false;cfg.c4_read_profile=false
  cfg.c4_input_batch=false;cfg.c4_native_batch=false;cfg.c4_idle_batch=false
  local native_ui=C4Fixture.new_ui(api,game,base)
  local saved_avatar=upvalue(native_ui,'avatar_ui')
  focused=true;cursor=false
  local engine={Window={has_focus=function()return focused end,show_cursor=function()return cursor end}}
  local guard=C4Fixture.new_guard(engine,function()return true end,native_ui)
  local callback=assert(loadstring('local native_ui,guard=...;return function() '..
     'return guard.sample(true,false,true),native_ui()end','@mods/etxp/c4_boundary_probe.lua'))(native_ui,guard)
  M.c4_read_pool.discover({callback})
  assert(upvalue(native_ui,'avatar_ui')~=saved_avatar and M.c4_ui_scope.active==1,'auto discovery missed UI consumer')
  local allowed,fields=callback();assert(allowed and not fields.native_ui_active)
  focused=false;assert(not callback());focused=true
  cursor=true;assert(not callback());cursor=false
  flags(true,false);assert(not callback());assert(guard.fields().runtime_state=='tactical_map_open')
  flags(false,true);assert(not callback());assert(guard.fields().runtime_state=='weapon_settings_open')
  flags(false,false);w(ui_manager,0x84,1);assert(not callback())
  assert(guard.fields().runtime_state=='native_game_ui_active');w(ui_manager,0x84,0)
  assert(callback())
  cfg.c4_context_batch=false;M.c4_read_pool.discover({callback})
  assert(upvalue(native_ui,'avatar_ui')==saved_avatar and M.c4_ui_scope.active==0)
  cfg.c4_context_batch=true;M.c4_read_pool.discover({callback})
  assert(upvalue(native_ui,'avatar_ui')~=saved_avatar)
  excluded=true;M.c4_read_pool.discover({callback});assert(upvalue(native_ui,'avatar_ui')==saved_avatar)
  excluded=false;M.c4_read_pool.discover({callback});assert(upvalue(native_ui,'avatar_ui')~=saved_avatar)
  cfg.enabled=false;M.c4_read_pool.discover({callback});assert(upvalue(native_ui,'avatar_ui')==saved_avatar)
  cfg.enabled=true;cfg.c4_context_batch=true
  local later=function()return {tactical_map_active=false,weapon_menu_active=false}end
  local _,slot=upvalue(native_ui,'avatar_ui');debug.setupvalue(native_ui,slot,later)
  assert(not M.c4_ui_scope.attach(native_ui));assert(upvalue(native_ui,'avatar_ui')==later)
  -- Unknown roots must stop repeating optional scope discovery after eight tries.
  local unsupported=assert(loadstring('return function()end','@mods/etxp/c4_boundary_probe.lua'))()
  M.c4_ui_scope.restore();M.c4_context_batch.restore()
  assert(M.c4_context_batch.attach(base))
  for i=1,12 do M.c4_read_pool.discover({unsupported})end
  assert(M.c4_ui_scope.attempts==8 and M.c4_ui_scope.active==0)
  print('PASS automatic closure discovery, focus/cursor/map/settings/native UI gating, hot option/exclusion/global restore, unknown variant and bounded attempts')
'''


def full_module(vm, source):
    """Run our complete source with original C4 UI consumers, never game code."""
    vm.run("M.c4_ui_scope.restore();M.c4_context_batch.restore()")
    with tempfile.TemporaryDirectory(prefix='smooth-ui-callback-') as temp:
        directory=Path(temp)/'CowboyBingus/Helldivers2/SmoothBoot'
        directory.mkdir(parents=True)
        config=directory/'config.txt'
        options=('enabled=yes\nc4_read_pool=no\nc4_read_profile=no\nc4_input_batch=no\n'
                 'c4_context_batch=yes\nc4_native_batch=no\nc4_idle_batch=no\n'
                 'c4_cpu_profile=no\nboot_pause_s=0\nwriters=\nprofile=no\nthrottle=no\nsnapshot=no\n')
        config.write_text(options,encoding='utf-8')
        vm.run("saved_getenv=os.getenv;saved_clock=os.clock;fixture_time=0;"
               "os.getenv=function(k)if k=='LOCALAPPDATA' or k=='TEMP' then return [==["+
               temp.replace('\\','/')+"]==]end end;os.clock=function()return fixture_time end")
        try:
            vm.run(r'''
              CowboyBingusModLoader={};MDL={};HD2SmoothBoot=nil
              base={snapshot=original.snapshot,u32=original.u32}
              flags(false,false);w(ui_manager,0x84,0);focused=true;cursor=false
              local native_ui=C4Fixture.new_ui(api,game,base)
              full_ui=native_ui;full_original_avatar=upvalue(native_ui,'avatar_ui')
              local guard=C4Fixture.new_guard({Window={has_focus=function()return focused end,
                show_cursor=function()return cursor end}},function()return true end,native_ui)
              original_update_calls=0;original_after_calls=0
              update=assert(loadstring('local native_ui,guard=...;return function(dt) '..
                'original_update_calls=original_update_calls+1;assert(guard.sample(true,false,true));'..
                'native_ui();return "ok",dt end','@mods/etxp/c4_boundary_probe.lua'))(native_ui,guard)
              after_update=assert(loadstring('local native_ui=...;return function(dt) '..
                'original_after_calls=original_after_calls+1;native_ui();return "after",dt end',
                '@mods/etxp/c4_boundary_probe.lua'))(native_ui)
            ''')
            load="return assert(loadstring([====["+source+"]====],'@mods/codex/smoothboot.lua'))()"
            vm.run(load)
            vm.run(r'''
              for i=1,120 do
                fixture_time=i/10
                local status,dt=update(1/60);assert(status=='ok' and dt==1/60)
                status,dt=after_update(1/60);assert(status=='after' and dt==1/60)
              end
              assert(original_update_calls==120 and original_after_calls==120)
              assert(HD2SmoothBoot.c4_ui_scope.active==1)
              assert(upvalue(full_ui,'avatar_ui')~=full_original_avatar)
              old_full=HD2SmoothBoot;saved_update=update;saved_after=after_update
            ''')
            # Same-version reload must preserve the current wrapper and scope.
            vm.run(load)
            vm.run("assert(HD2SmoothBoot==old_full and update==saved_update and after_update==saved_after)")
            # A version transition restores the old scope before rediscovery.
            vm.run("HD2SmoothBoot.version='previous-fixture'")
            vm.run(load)
            vm.run(r'''
              assert(old_full.c4_ui_scope.active==0 and old_full.c4_context_batch.active==0)
              assert(upvalue(full_ui,'avatar_ui')==full_original_avatar)
              fixture_time=20;update(1/60);after_update(1/60)
              assert(original_update_calls==121 and original_after_calls==121,'reload duplicated original callbacks')
              assert(HD2SmoothBoot.c4_ui_scope.active==1,'reload scope not active: new='..
                HD2SmoothBoot.c4_ui_scope.active..' old='..old_full.c4_ui_scope.active)
            ''')
            config.write_text(options.replace('c4_context_batch=yes','c4_context_batch=no'),encoding='utf-8')
            vm.run("fixture_time=30;update(1/60);assert(upvalue(full_ui,'avatar_ui')==full_original_avatar)")
            config.write_text(options,encoding='utf-8')
            vm.run("fixture_time=41;update(1/60);assert(HD2SmoothBoot.c4_ui_scope.active==1)")
            config.write_text(options.replace('enabled=yes','enabled=no'),encoding='utf-8')
            vm.run("fixture_time=53;update(1/60);assert(upvalue(full_ui,'avatar_ui')==full_original_avatar);assert(original_update_calls==124)")
            print('PASS complete Smooth, 120 before/after callbacks and returns, same-version guard, version reload, hot context/global restore',flush=True)
        finally:
            vm.run("os.getenv=saved_getenv;os.clock=saved_clock")


def benchmark(vm, short_table=False):
    # Original context adapter is enabled in both arms. Only UI scope differs.
    # Disable collection during measured batches; record temporary allocation,
    # with JIT warm-up outside the timing. Every API read targets owned memory.
    vm.run("D.ability_capacity="+('1' if short_table else '128'))
    if short_table:
        vm.run("hashwrite(address+0xc700,'51f50d6321f52f3d');w(address+0xc700,8,0)")
    return json.loads(vm.run(r'''
      local ui=C4Fixture.new_ui(api,game,base)
      cfg.enabled=true;cfg.c4_context_batch=true;excluded=false
      local function run_batch()
        for i=1,100 do ui()end
        collectgarbage('collect');collectgarbage('stop')
        local kb=collectgarbage('count');calls=0;local t=os.clock()
        for i=1,500 do ui()end
        local elapsed=os.clock()-t;local allocation=collectgarbage('count')-kb
        collectgarbage('restart');collectgarbage('collect')
        return string.format('%.6f,%.3f,%d',elapsed,allocation,calls)
      end
      local results={};M.c4_ui_scope.restore();M.c4_context_batch.restore()
      assert(M.c4_context_batch.attach(base))
      for trial=1,5 do
        if trial%2==0 then
          assert(M.c4_ui_scope.attach(ui));local candidate=run_batch()
          M.c4_ui_scope.restore();local baseline=run_batch()
          results[#results+1]='["'..baseline..'","'..candidate..'"]'
        else
          local baseline=run_batch();assert(M.c4_ui_scope.attach(ui))
          local candidate=run_batch();M.c4_ui_scope.restore()
          results[#results+1]='["'..baseline..'","'..candidate..'"]'
        end
      end
      return '['..table.concat(results,',')..']'
    '''))


class UiScopeTests(unittest.TestCase):
    def test_original_consumers_on_owned_memory(self):
        vm=VM(False)
        try:
            source=SB.read_text(encoding='utf-8');setup(vm,source,reference=True)
            vm.run("assert(candidate_reads<baseline_reads)")
            vm.run(CONTRACTS);vm.run(INTEGRATION);full_module(vm,source)
        finally:vm.close()


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--game',action='store_true')
    parser.add_argument('--red',action='store_true')
    parser.add_argument('--reference',action='store_true',help='Use versioned original reference, not workspace original full prefix')
    parser.add_argument('--benchmark',action='store_true',help='Owned-memory UI consumer comparison; no FPS claim')
    args=parser.parse_args()
    source=SB.read_text(encoding='utf-8');vm=VM(args.game)
    try:
        setup(vm,source,args.reference)
        stats=vm.run("return fingerprint..';'..baseline_reads..';'..candidate_reads..';'..jit.version")
        fingerprint,baseline,candidate,runtime=stats.split(';')
        print('fingerprint avatar_ui/native_ui:',fingerprint,flush=True)
        print('UI original native reads',baseline,'->',candidate,flush=True)
        vm.run("assert(candidate_reads<baseline_reads,'RED: flags-only UI still scans unrelated weapon/template data')")
        vm.run(CONTRACTS)
        vm.run(INTEGRATION)
        measurements=None
        if args.benchmark:
            measurements={}
            for label,short in [('128_slots',False),('1_slot',True)]:
                rows=benchmark(vm,short)
                measurements[label]=[dict(baseline=dict(zip(('seconds','allocated_kb','native_reads'),map(float,b.split(',')))),
                                    candidate=dict(zip(('seconds','allocated_kb','native_reads'),map(float,c.split(',')))))
                                    for b,c in rows]
                print(label,'UI 500-call median seconds:',statistics.median(r['baseline']['seconds'] for r in measurements[label]),
                      '->',statistics.median(r['candidate']['seconds'] for r in measurements[label]),flush=True)
        full_module(vm,source)
        OUT.mkdir(parents=True,exist_ok=True)
        (OUT/(('game' if args.game else 'modern')+('-reference' if args.reference else '-workspace')+'-contracts.json')).write_text(json.dumps(
            dict(runtime=runtime,fingerprints=fingerprint,baseline_reads=int(baseline),candidate_reads=int(candidate),
                 gameplay_validated=False,game_process_access=False,third_party_files_modified=False,
                 reference_fixture=args.reference,benchmark=measurements,
                 scope='Synthetic populated 128-slot template fixture, actual C4 UI consumer; not full mod cost or FPS.'),indent=2),encoding='utf-8')
    finally:vm.close()


if __name__=='__main__':main()

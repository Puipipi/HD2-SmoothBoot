"""Original input-gate maintenance replay, no live process/native game actions."""
import argparse
import ast
from pathlib import Path
import unittest
import json
import tempfile
from test_c4_ui_scope import VM

HERE=Path(__file__).parent

def setup(vm, quiet=False):
    if quiet:vm.run('saved_print=print;print=function()end')
    source=(HERE/'smoothboot.lua').read_text(encoding='utf-8')
    # Same owned Windows-memory layout as our input-read contract tests.
    tree=ast.parse((HERE/'test_c4_input_batch.py').read_text(encoding='utf-8'))
    fixture=next(n.value for n in ast.walk(tree) if isinstance(n,ast.Constant) and
                 isinstance(n.value,str) and 'gm=ffi.new' in n.value)
    signature=source[source.index('-- BEGIN C4 INPUT BATCH'):source.index('-- END C4 INPUT BATCH')]
    native=source[source.index('-- BEGIN C4 NATIVE BATCH'):source.index('-- END C4 NATIVE BATCH')]
    scope=''
    if '-- BEGIN C4 INPUT SCOPE' in source:
        scope=source[source.index('-- BEGIN C4 INPUT SCOPE'):source.index('-- END C4 INPUT SCOPE')]
    vm.run('M={};cfg={enabled=true,c4_native_batch=true,c4_input_batch=true};excludes={};log=function()end;'
           'function function_chunk(f)return (debug.getinfo(f,"S").source or ""):match("mods/[%w_./%-]+") or ""end;'
           'function is_excluded()return excluded==true end;'+signature+native+scope)
    vm.run('batch=M.c4_input_batch;C4Batch=batch;'+fixture)
    reference=(HERE/'fixtures/c4_input_scope_reference.lua').read_text(encoding='utf-8')
    vm.run("assert(loadstring([====["+reference+"]====],'@mods/etxp/c4_boundary_probe.lua'))()")
    vm.run(r'''
      InputFixture.layout(R,D)
      raw_state_read=InputFixture.state.read
      w(buckets,220*328+8,0x40);w(buckets,245*328+8,0x40)
      pw(owner,200,owner+5000);w(owner,208,16);w(owner,212,0xffffffff);w(owner,216,1)
      for i=0,15 do w(owner,5000+i*8,0xffffffff);w(owner,5000+i*8+4,0xffffffff)end
      code_reads=0;bad_code=nil;short_code=false
      local code_pe=true
      local image=ffi.new('uint8_t[8192]');ffi.copy(image,'MZ',2)
      local image_at=tonumber(ffi.cast('uintptr_t',image))
      w(image_at,60,64);ffi.copy(image+64,'PE\0\0',4)
      ffi.cast('uint16_t *',image+68)[0]=0x8664;ffi.cast('uint16_t *',image+70)[0]=1
      ffi.cast('uint16_t *',image+84)[0]=112;ffi.cast('uint16_t *',image+88)[0]=0x20b
      w(image_at,144,1048576);w(image_at,208,4096);w(image_at,212,4096);w(image_at,236,0x60000020)
      local code_api={read=function(at,n)
        code_reads=code_reads+1
        if code_pe then return ffi.string(image+at-65536,n)end
        if short_code then return ''end
        local s=string.rep('A',n)
        if bad_code and at<=bad_code and bad_code<at+n then
          local i=bad_code-at;s=s:sub(1,i)..'B'..s:sub(i+2)
        end
        return s
      end}
      guards={}
      for i=1,80 do guards[#guards+1]={at=i*8192,bytes=string.rep('A',31),label='unrelated_'..i}end
      for i,v in ipairs({{'fn_input_index',40},{'fn_input_index:switch_table',52},
        {'fn_input_mapping',974},{'fn_input_mapping:switch_table',40},{'fn_input_mapping:switch_table',40}})do
        guards[#guards+1]={at=(80+i)*8192,bytes=string.rep('A',v[2]),label=v[1]}
      end
      function uv(f,key)
        for i=1,64 do local n,v=debug.getupvalue(f,i);if not n then break end
          if n==key then return v,i end
        end
      end
      resolved=InputFixture.resolver.resolve(code_api,65536,{nodes={},fields=D,required_globals={}})
      code_pe=false;resolved.symbols=R
      raw_verify=resolved.verify;local _,slot=uv(raw_verify,'guards');debug.setupvalue(raw_verify,slot,guards)
      cap={identity='avatar:c4:world',same=function()return true end};snapshots=0
      native_calls={mapping=0,inhibit=0,unblock=0};native_failure=nil
      function native.input_mapping()
        native_calls.mapping=native_calls.mapping+1
        if native_failure then error('mapping_failure')end
        return buckets+220*328+8
      end
      for _,name in ipairs({'start','consume','count','after','lean','reload','reload_eligible','input_mapping','input_inhibit','input_unblock'})do R['fn_'..name]=0 end
      local native_wrappers=InputFixture.native(game)
      local _,mapping_slot=uv(native_wrappers.input_mapping,'input_mapping')
      debug.setupvalue(native_wrappers.input_mapping,mapping_slot,native.input_mapping)
      native.input_mapping=native_wrappers.input_mapping
      local function mapping(action)return action==91 and 11 or 44,action==91 and 8 or 5 end
      function native.input_inhibit(_,action)
        native_calls.inhibit=native_calls.inhibit+1
        local code,index=mapping(action);local count=base.u32(api.read(owner+100,4),0)
        local at=owner+4000+count*24
        w(at,0,1);w(at,4,2);w(at,8,index)
        w(owner,5000+(code%16)*8,code);w(owner,5000+(code%16)*8+4,count);w(owner,100,count+1)
      end
      function native.input_unblock(_,action)
        native_calls.unblock=native_calls.unblock+1
        local code=mapping(action);local row=base.u32(api.read(owner+5000+(code%16)*8+4,4),0)
        w(owner,4000+row*24,0)
      end
      local raw_resolve=InputFixture.resolver.resolve
      InputFixture.resolver.resolve=function()return resolved end
      for _,name in ipairs({'start','consume','after','lean','reload'})do native[name]=function()end end
      api.module=function()return game end;api.fire_gate_exchange=function()end;api.passenger_exchange=function()end
      backend=InputFixture.backend(api,{snapshot=function()snapshots=snapshots+1;return {},nil,cap end},base,{},function()return native end,function()return true end)
      InputFixture.resolver.resolve=raw_resolve
      profile_codes=codes
      local function profile()return profile_codes end
      local function emit()return true end
      aim=InputFixture.gate(api,game,base,backend,profile,emit)
      fire=InputFixture.gate(api,game,base,backend,profile,emit,{action=92,code=44,index=5,tag='fire_input_gate',fire=true})
      original_sync=aim.sync;original_fire_sync=fire.sync
      step=uv(aim.sync,'step');publish=uv(aim.sync,'publish')
      stop=aim.stop
      print('fingerprints sync',C4Batch.signature(aim.sync))
      print('fingerprints step',C4Batch.signature(step))
      print('fingerprints stop',C4Batch.signature(stop))
      print('fingerprints backend.verify',C4Batch.signature(backend.verify))
      print('fingerprints input read',C4Batch.signature(raw_state_read))
      print('fingerprints native read',C4Batch.signature(uv(raw_verify,'read')))
      print('fingerprints resolved.verify',C4Batch.signature(raw_verify))
      print('fingerprints policy',C4Batch.signature(InputFixture.state.policy))
      print('fingerprints read wrapper',C4Batch.signature(uv(step,'read')))
      print('fingerprints native mapping',C4Batch.signature(native.input_mapping))
      assert(M.c4_native_batch.attach(resolved))
      -- Real original acquisition remains complete; optimize owned maintenance.
      aim.sync(true,0);fire.sync(true,0)
      assert(aim.lease and fire.lease and aim.status=='owned' and fire.status=='owned')
      code_reads=0;aim.sync(true,1);fire.sync(true,1);baseline_reads=code_reads
      if M.c4_input_scope then
        assert(M.c4_input_scope.attach(aim));assert(M.c4_input_scope.attach(fire))
      end
      code_reads=0;aim.sync(true,2);fire.sync(true,2);candidate_reads=code_reads
      assert(candidate_reads<baseline_reads/4,'RED: owned input maintenance still scans all unrelated native code')
      assert(aim.status=='owned' and fire.status=='owned')
      print('steady owned aim+fire native-code reads',baseline_reads,'->',candidate_reads)
    ''')
    if quiet:vm.run('print=saved_print')


CASES={
    'owned_every_callback': 'for i=1,120 do aim.sync(true,i);fire.sync(true,i)end',
    'disabled_restores': 'aim.sync(false,3);fire.sync(false,3)',
    'outside_c4': 'cap=nil;aim.sync(true,3);fire.sync(true,3)',
    'interrupted': 'cap.interrupt=true;aim.sync(true,3);fire.sync(true,3)',
    'missing_assignments': 'profile_codes=nil;aim.sync(true,3);fire.sync(true,3)',
    'independent_aim': 'w(buckets,245*328+8,22);aim.sync(true,3);fire.sync(true,3)',
    'changed_binding': 'w(buckets,17*328+8,0x40);aim.sync(true,3);fire.sync(true,3)',
    'changed_identity': "cap.identity='avatar:respawn:c4';aim.sync(true,3);fire.sync(true,3)",
    'changed_mask': 'w(owner,4000,0);aim.sync(true,3);fire.sync(true,3)',
    'external_mask': 'aim.stop();w(owner,4000,2);aim.sync(true,3)',
    'held_waits': 'aim.stop();w(owner,808+32*(2*97+8),1);aim.sync(true,3)',
    'fire_held_waits': 'fire.stop();w(owner,808+32*(2*97+5),1);fire.sync(true,3)',
    'pending_lease': 'aim.lease.pending=true;aim.sync(true,3);fire.sync(true,3)',
    'native_mapping_fault': "native_failure=true;aim.sync(true,3);fire.sync(true,3)",
    'bad_input_owner': 'pw(game,8,0);aim.sync(true,3);fire.sync(true,3)',
    'bad_bindings': 'w(buckets,17*328,99);aim.sync(true,3);fire.sync(true,3)',
    'reacquisition': 'aim.stop();fire.stop();aim.sync(true,3);fire.sync(true,3)',
    'changed_snapshot': 'cap.same=function()return false end;aim.stop();aim.sync(true,3)',
    'unknown_verifier': "backend.verify=function()error('changed_backend_verifier')end;aim.sync(true,3);fire.sync(true,3)",
    'unknown_policy': "InputFixture.state.policy=function()return false,'new_policy'end;aim.sync(true,3)",
    'unknown_state_read': "local f=InputFixture.state.read;InputFixture.state.read=function(...)return f(...)end;aim.sync(true,3);fire.sync(true,3)",
    'unknown_read_capture': "local r=uv(uv(original_sync,'step'),'read');local _,i=uv(r,'AimInputState');debug.setupvalue(r,i,{read=function()error('changed_read_capture')end});aim.sync(true,3)",
    'unknown_mapping_capture': "local _,i=uv(native.input_mapping,'input_mapping');debug.setupvalue(native.input_mapping,i,function()error('changed_mapping_capture')end);aim.sync(true,3)",
    'native_adapter_restore': 'M.c4_native_batch.restore();aim.sync(true,3);fire.sync(true,3)',
    'global_optout': 'cfg.enabled=false;aim.sync(true,3);fire.sync(true,3)',
    'native_optout': 'cfg.c4_native_batch=false;aim.sync(true,3);fire.sync(true,3)',
    'exclusion': 'excluded=true;aim.sync(true,3);fire.sync(true,3)',
}


def contracts(game):
    # Run independent identical original/candidate states. Compare every dynamic
    # result and native operation, allowing only the intended code-read reduction.
    results=[]
    for name,body in CASES.items():
        outcomes=[]
        for optimized in (False,True):
            vm=VM(game)
            try:
                setup(vm,quiet=True)
                if not optimized:vm.run('M.c4_input_scope.restore()')
                outcome=vm.run('native_calls={mapping=0,inhibit=0,unblock=0};snapshots=0;code_reads=0;'+body+r'''
                  local function reason(value)return (tostring(value):gsub('%[string "[^"]+"%]:%d+: ',''):gsub('[%w_./%-]+:%d+: ',''))end
                  return table.concat({aim.status,reason(aim.reason),tostring(aim.lease~=nil),
                    fire.status,reason(fire.reason),tostring(fire.lease~=nil),
                    native_calls.mapping,native_calls.inhibit,native_calls.unblock,snapshots},'|')
                ''')
                outcomes.append(outcome)
            finally:vm.close()
        assert outcomes[0]==outcomes[1],(name,outcomes)
        results.append(name)
    # Mutated native guards: aim cannot call even the read-only native mapping
    # after a relevant header/table change; all restores and acquisition still
    # check unrelated guards. No foreign process is accessed by these tests.
    for index in range(81,86):
        vm=VM(game)
        try:
            setup(vm,quiet=True)
            vm.run(f"bad_code=65536+guards[{index}].at;native_calls.mapping=0;aim.sync(true,3);"
                   "assert(aim.status=='unavailable' and native_calls.mapping==0);"
                   "assert(aim.reason:find('compat_live_code_changed:',1,true))")
            results.append('relevant_guard_'+str(index))
        finally:vm.close()
    checks={
        'unrelated_read_only': "bad_code=65536+guards[1].at;native_calls.mapping=0;code_reads=0;aim.sync(true,3);fire.sync(true,3);assert(aim.status=='owned' and fire.status=='owned');assert(code_reads==5 and native_calls.mapping==1)",
        'unrelated_restore_full': "bad_code=65536+guards[1].at;native_calls.unblock=0;aim.sync(false,3);fire.sync(false,3);assert(aim.status=='unavailable' and fire.status=='unavailable' and native_calls.unblock==0)",
        'unrelated_acquire_full': "aim.stop();fire.stop();bad_code=65536+guards[1].at;native_calls.inhibit=0;aim.sync(true,3);fire.sync(true,3);assert(aim.status=='unavailable' and fire.status=='unavailable' and native_calls.inhibit==0)",
        'pending_full': "aim.lease.pending=true;bad_code=65536+guards[1].at;native_calls.mapping=0;aim.sync(true,3);assert(aim.status=='unavailable' and native_calls.mapping==0)",
        'missing_guard_full': "guards[82].label='unknown_index_switch';code_reads=0;aim.sync(true,3);assert(code_reads==85)",
        'new_dependency_full': "guards[1].label='fn_input_mapping:literal';code_reads=0;aim.sync(true,3);assert(code_reads==85)",
        'wrong_shape_full': "guards[82].label='fn_input_mapping:switch_table';guards[82].bytes=string.rep('A',40);code_reads=0;aim.sync(true,3);assert(code_reads==85)",
        'guards_cell_changed_full': "local copy={};for i,g in ipairs(guards)do copy[i]=g end;local _,slot=uv(raw_verify,'guards');debug.setupvalue(raw_verify,slot,copy);code_reads=0;aim.sync(true,3);assert(code_reads==85)",
        'reader_cell_changed_full': "local r,i=uv(raw_verify,'read');debug.setupvalue(raw_verify,i,function(...)return r(...)end);code_reads=0;aim.sync(true,3);assert(code_reads==85)",
        'short_code_blocks_mapping': "short_code=true;native_calls.mapping=0;aim.sync(true,3);assert(aim.status=='unavailable' and native_calls.mapping==0)",
        'idempotent_attachment': "local fn=aim.sync;assert(M.c4_input_scope.attach(aim));assert(aim.sync==fn and M.c4_input_scope.active==2)",
        'unknown_sync_untouched': "local fn=function()end;local gate={sync=fn};assert(not M.c4_input_scope.attach(gate) and gate.sync==fn)",
        'later_wrapper_preserved': "local fn=function()end;aim.sync=fn;M.c4_input_scope.restore();assert(aim.sync==fn and fire.sync==original_fire_sync and M.c4_input_scope.active==0)",
    }
    for name,body in checks.items():
        vm=VM(game)
        try:setup(vm,quiet=True);vm.run(body);results.append(name)
        finally:vm.close()
    print('PASS',len(results),'input-scope differential/fault/ownership contracts')
    return results


def full_module(game):
    vm=VM(game)
    try:
        setup(vm,quiet=True)
        vm.run('M.c4_input_scope.restore();M.c4_native_batch.restore()')
        source=(HERE/'smoothboot.lua').read_text(encoding='utf-8')
        with tempfile.TemporaryDirectory(prefix='smooth-input-scope-') as temp:
            folder=Path(temp)/'CowboyBingus/Helldivers2/SmoothBoot'
            folder.mkdir(parents=True)
            config=folder/'config.txt'
            options=('enabled=yes\nc4_read_pool=no\nc4_read_profile=no\nc4_input_batch=yes\n'
                     'c4_context_batch=no\nc4_native_batch=yes\nc4_idle_batch=no\n'
                     'c4_cpu_profile=no\nboot_pause_s=0\nwriters=\nprofile=no\nthrottle=no\nsnapshot=no\n')
            config.write_text(options,encoding='utf-8')
            vm.run("saved_getenv=os.getenv;saved_clock=os.clock;fixture_time=0;"
                   "os.getenv=function(k)if k=='LOCALAPPDATA' or k=='TEMP' then return [==["+
                   temp.replace('\\','/')+"]==]end end;os.clock=function()return fixture_time end")
            try:
                vm.run(r'''
                  CowboyBingusModLoader={};MDL={};HD2SmoothBoot=nil
                  original_update_calls=0;original_after_calls=0
                  local body='local aim_gate,fire_input_gate=...;return function(dt)'..
                    'COUNT=COUNT+1;aim_gate.sync(true,fixture_time);fire_input_gate.sync(true,fixture_time);'..
                    'return "STATUS",dt end'
                  update=assert(loadstring(body:gsub('COUNT','original_update_calls'):gsub('STATUS','ok'),
                    '@mods/etxp/c4_boundary_probe.lua'))(aim,fire)
                  after_update=assert(loadstring(body:gsub('COUNT','original_after_calls'):gsub('STATUS','after'),
                    '@mods/etxp/c4_boundary_probe.lua'))(aim,fire)
                  unsupported=assert(loadstring('return function()end','@mods/etxp/c4_boundary_probe.lua'))()
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
                  assert(HD2SmoothBoot.c4_input_scope.active==2,'input gate discovery failed')
                  assert(HD2SmoothBoot.c4_input_batch.active==1)
                  assert(aim.status=='owned' and fire.status=='owned')
                  assert(aim.sync~=original_sync and fire.sync~=original_fire_sync)
                  old_full=HD2SmoothBoot;saved_update=update;saved_after=after_update
                ''')
                vm.run(load)
                vm.run('assert(HD2SmoothBoot==old_full and update==saved_update and after_update==saved_after)')
                vm.run("HD2SmoothBoot.version='previous-fixture'")
                vm.run(load)
                vm.run(r'''
                  assert(old_full.c4_input_scope.active==0)
                  assert(aim.sync==original_sync and fire.sync==original_fire_sync)
                  fixture_time=20;update(1/60);after_update(1/60)
                  assert(original_update_calls==121 and original_after_calls==121)
                  assert(HD2SmoothBoot.c4_input_scope.active==2,'scope reload failed')
                ''')
                config.write_text(options.replace('c4_native_batch=yes','c4_native_batch=no'),encoding='utf-8')
                vm.run('fixture_time=31;update(1/60);assert(aim.sync==original_sync and fire.sync==original_fire_sync)')
                config.write_text(options,encoding='utf-8')
                vm.run('fixture_time=42;update(1/60);assert(HD2SmoothBoot.c4_input_scope.active==2)')
                config.write_text(options.replace('enabled=yes','enabled=no'),encoding='utf-8')
                vm.run('fixture_time=54;update(1/60);assert(aim.sync==original_sync and fire.sync==original_fire_sync)')
                config.write_text(options,encoding='utf-8')
                vm.run('fixture_time=65;update(1/60);assert(HD2SmoothBoot.c4_input_scope.active==2)')
                vm.run(r'''
                  local module=HD2SmoothBoot
                  module.c4_input_scope.restore()
                  for i=1,12 do module.c4_read_pool.discover({unsupported})end
                  assert(module.c4_input_scope.attempts==8 and module.c4_input_scope.active==0)
                  assert(aim.sync==original_sync and fire.sync==original_fire_sync)
                  -- Later third-party wrappers must remain authoritative.
                  module.c4_input_scope.attempts=0
                  module.c4_read_pool.discover({update,after_update})
                  assert(module.c4_input_scope.active==2)
                  local later=function()end;aim.sync=later
                  module.c4_input_scope.restore();assert(aim.sync==later)
                ''')
                print('PASS complete source, 120 paired callbacks/returns, two-gate discovery, reload, opt-outs, bounded scans and later-wrapper ownership')
            finally:vm.run('os.getenv=saved_getenv;os.clock=saved_clock')
    finally:vm.close()

class InputScope(unittest.TestCase):
    def test_original_owned_maintenance(self):
        vm=VM(False)
        try:setup(vm)
        finally:vm.close()

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--game',action='store_true');args=parser.parse_args()
    vm=VM(args.game)
    try:setup(vm)
    finally:vm.close()
    results=contracts(args.game)
    full_module(args.game)
    out=HERE.parents[3]/'outputs/validated-2026-10-04/c4-input-scope'
    out.mkdir(parents=True,exist_ok=True)
    (out/(('game' if args.game else 'modern')+'-contracts.json')).write_text(json.dumps(dict(
        contracts=results,full_module=True,steady_guard_reads=dict(original=170,candidate=5),
        game_process_access=False,gameplay_validated=False,third_party_files_modified=False,
        scope='Owned synthetic 85-guard fixture, original C4 input gates; not whole C4 cost or FPS.'),indent=2),encoding='utf-8')

if __name__=='__main__':main()

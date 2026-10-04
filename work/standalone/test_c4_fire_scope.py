"""Original WeaponFireGate replay on owned memory. Never access game process."""
from pathlib import Path
import argparse
import json
import tempfile
import statistics
from test_c4_ui_scope import VM,setup as ui_setup

HERE=Path(__file__).parent

def setup(vm,quiet=False):
    if quiet:vm.run('saved_print=print;print=function()end')
    source=(HERE/'smoothboot.lua').read_text(encoding='utf-8')
    ui_setup(vm,source,reference=True)
    reference=(HERE/'fixtures/c4_fire_scope_reference.lua').read_text(encoding='utf-8')
    vm.run("assert(loadstring([====["+reference+"]====],'@mods/etxp/c4_boundary_probe.lua'))()")
    vm.run(r'''
      FireFixture.layout(R,D)
      D.fire_normal=72;D.fire_muted=328;D.fire_bit=8
      R.global_weapon=72;R.global_fire_latch=80
      wm=address+0xe800;driver=address+0xea00;weapon=owner+0x1000+24
      flag_at=address+0xed40;held_at=address+0xedc0
      pw(game,72,wm);pw(game,80,driver)
      map(wm,0x28,address+0xec00,2,0);pw(wm,0x40,address+0xed00);pw(address+0xed00,0,weapon)
      pw(wm,0x50,flag_at);w(flag_at,0,72)
      map(driver,0x20,address+0xec40,2,0);pw(driver,0x38,address+0xed80);pw(address+0xed80,0,weapon)
      pw(driver,0x48,held_at)
      writes=0;verifications=0;exchange_failure=false
      function api.fire_gate_exchange(at,before,after)
        writes=writes+1
        if exchange_failure then return false,'modeled_exchange_failed'end
        if FireFixture.base.u32(original_read(at,4),0)~=before then return false,'compare_failed'end
        w(at,0,after);return true
      end
      fire_base={snapshot=FireFixture.base.snapshot,u32=FireFixture.base.u32,
                 product_low=FireFixture.base.product_low}
      assert(M.c4_context_batch.attach(fire_base))
      gate=FireFixture.new_gate(api,game,fire_base,function()return true end,function()verifications=verifications+1 end)
      original_sync=gate.sync;original_stop=gate.stop
      original_current=upvalue(original_sync,'current')
      print('fire fingerprints sync',M.c4_input_batch.signature(original_sync))
      print('fire fingerprints current',M.c4_input_batch.signature(original_current))
      print('fire fingerprints stop',M.c4_input_batch.signature(original_stop))
      assert(gate.sync(true,true) and gate.active and gate.lease)
      calls=0;assert(gate.sync(true,true));baseline_reads=calls
      if M.c4_fire_scope then assert(M.c4_fire_scope.attach(gate))end
      calls=0;assert(gate.sync(true,true));candidate_reads=calls
      -- Full snapshots also batch templates now; the private consumer must
      -- still save reads rather than depend on the old percentage threshold.
      assert(candidate_reads<baseline_reads,'RED: owned fire maintenance still scans diagnostic templates')
      assert(writes==1 and verifications==1 and gate.active)
      print('owned fire reads',baseline_reads,'->',candidate_reads)
    ''')
    if quiet:vm.run('print=saved_print')


CASES={
    'steady_callbacks': 'for i=1,120 do assert(gate.sync(true,true))end',
    'disabled_restores': 'gate.sync(false,true)',
    'waiting_for_release': 'gate.sync(false,false)',
    'held': 'w(held_at,0,1);gate.sync(true,false)',
    'reacquire': 'gate.stop();gate.sync(true,true)',
    'not_released': 'gate.stop();gate.sync(true,false)',
    'held_new_acquire': 'gate.stop();w(held_at,0,1);gate.sync(true,true)',
    'flags_normal_while_owned': 'w(flag_at,0,72);local ok,why=pcall(gate.sync,true,true);assert(not ok and why:find("fire_gate_changed_while_owned",1,true))',
    'bad_flags': 'w(flag_at,0,999);pcall(gate.sync,true,true)',
    'outside_mission': 'w(mode,8,0);gate.sync(true,true)',
    'changed_weapon': "hashwrite(weapon,'0011223344556677');gate.sync(true,true)",
    'ownership_change': 'ffi.cast("uint8_t *",weapon)[20]=0;gate.sync(true,true)',
    'changed_avatar': 'pw(avatar,0x110,weapon);gate.sync(true,true)',
    'changed_inventory': 'w(address+0xc600,0x1c,0);gate.sync(true,true)',
    'changed_weapon_registry': 'pw(address+0xed00,0,owner+0x1000);gate.sync(true,true)',
    'changed_latch_registry': 'pw(address+0xed80,0,owner+0x1000);gate.sync(true,true)',
    'changed_identity': 'w(owner+0x1000,12,2);gate.sync(true,true)',
    'short_read': 'api.read=function(at,n)if at==flag_at then return ""end;return original_read(at,n)end;pcall(gate.sync,true,true)',
    'read_failure': 'api.read=function(at,n)if at==flag_at then return nil end;return original_read(at,n)end;pcall(gate.sync,true,true)',
    'exchange_failure': 'exchange_failure=true;pcall(gate.sync,false,true)',
    'unknown_base_method': 'local f=fire_base.snapshot;fire_base.snapshot=function(...)return f(...)end;gate.sync(true,true)',
    'changed_current_capture': 'local _,i=upvalue(original_current,"game");debug.setupvalue(original_current,i,game+8);pcall(gate.sync,true,true)',
    'context_optout': 'cfg.c4_context_batch=false;gate.sync(true,true)',
    'global_optout': 'cfg.enabled=false;gate.sync(true,true)',
    'exclude': 'excluded=true;gate.sync(true,true)',
}

def contracts(game):
    results=[]
    for name,body in CASES.items():
        outcomes=[]
        for optimized in (False,True):
            vm=VM(game)
            try:
                setup(vm,quiet=True)
                if not optimized:vm.run('M.c4_fire_scope.restore()')
                outcomes.append(vm.run(body+r'''
                  local reason=tostring(gate.status):gsub('%[string "[^"]+"%]:%d+: ',''):gsub('[%w_./%-]+:%d+: ','')
                  return table.concat({reason,tostring(gate.active),tostring(gate.lease~=nil),
                    tostring(gate.identity):gsub(':%d+$',':owned-memory-owner'),writes,verifications,FireFixture.base.u32(original_read(flag_at,4),0)},'|')
                '''))
            finally:vm.close()
        assert outcomes[0]==outcomes[1],(name,outcomes)
        results.append(name)
    checks={
        'new_acquire_full_templates': 'gate.stop();template_bytes=0;api.read=function(at,n)if at>=address+0xc700 and at<address+0xcf00 then template_bytes=template_bytes+n end;return original_read(at,n)end;assert(gate.sync(true,true));assert(template_bytes>=2048)',
        'steady_omits_templates': 'template_reads=0;api.read=function(at,n)if at>=address+0xc700 and at<address+0xd000 then template_reads=template_reads+1 end;return original_read(at,n)end;assert(gate.sync(true,true));assert(template_reads==0)',
        'unchanged_shared_snapshot': 'assert(fire_base.snapshot==M.c4_context_batch.records[fire_base].replacement);assert(upvalue(original_current,"base")==fire_base)',
        'idempotent': 'local current=upvalue(gate.sync,"current");assert(M.c4_fire_scope.attach(gate));assert(upvalue(gate.sync,"current")==current and M.c4_fire_scope.active==1)',
        'later_current_preserved': 'local _,i=upvalue(gate.sync,"current");local later=function()end;debug.setupvalue(gate.sync,i,later);M.c4_fire_scope.restore();assert(upvalue(gate.sync,"current")==later)',
        'unknown_untouched': 'local f=function()end;local t={sync=f};assert(not M.c4_fire_scope.attach(t) and t.sync==f)',
        'orphan_scope_falls_back': 'M.c4_fire_scope.records[gate]=nil;calls=0;assert(gate.sync(true,true));assert(calls==baseline_reads)',
        'guard_mutation_rejected': 'local before=api.read;local mutated=false;api.read=function(at,n)local b=before(at,n);if not mutated and at==flag_at then mutated=true;w(flag_at,0,72)end;return b end;local ok,why=pcall(gate.sync,true,true);assert(not ok and why:find("fire_gate_changed_while_owned",1,true))',
        'original_restore_no_templates': 'template_reads=0;api.read=function(at,n)if at>=address+0xc700 and at<address+0xd000 then template_reads=template_reads+1 end;return original_read(at,n)end;assert(gate.stop());assert(template_reads==0 and writes==2)',
    }
    for name,body in checks.items():
        vm=VM(game)
        try:setup(vm,quiet=True);vm.run(body);results.append(name)
        finally:vm.close()
    print('PASS',len(results),'fire-scope differential/fault/ownership contracts')
    return results


def full_module(game):
    vm=VM(game)
    try:
        setup(vm,quiet=True)
        vm.run('M.c4_fire_scope.restore();M.c4_ui_scope.restore();M.c4_context_batch.restore()')
        source=(HERE/'smoothboot.lua').read_text(encoding='utf-8')
        with tempfile.TemporaryDirectory(prefix='smooth-fire-scope-') as temp:
            folder=Path(temp)/'CowboyBingus/Helldivers2/SmoothBoot'
            folder.mkdir(parents=True)
            config=folder/'config.txt'
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
                  original_update_calls=0;original_after_calls=0
                  local body='local gate=...;return function(dt)COUNT=COUNT+1;'..
                    'assert(gate.sync(true,true));return "STATUS",dt end'
                  update=assert(loadstring(body:gsub('COUNT','original_update_calls'):gsub('STATUS','ok'),
                    '@mods/etxp/c4_boundary_probe.lua'))(gate)
                  after_update=assert(loadstring(body:gsub('COUNT','original_after_calls'):gsub('STATUS','after'),
                    '@mods/etxp/c4_boundary_probe.lua'))(gate)
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
                  assert(HD2SmoothBoot.c4_fire_scope.active==1,'fire gate discovery failed')
                  assert(gate.active and gate.sync==original_sync and gate.stop==original_stop)
                  assert(upvalue(original_sync,'current')~=original_current)
                  old_full=HD2SmoothBoot;saved_update=update;saved_after=after_update
                ''')
                vm.run(load)
                vm.run('assert(HD2SmoothBoot==old_full and update==saved_update and after_update==saved_after)')
                vm.run("HD2SmoothBoot.version='previous-fixture'")
                vm.run(load)
                vm.run(r'''
                  assert(old_full.c4_fire_scope.active==0)
                  assert(upvalue(original_sync,'current')==original_current)
                  fixture_time=20;update(1/60);after_update(1/60)
                  assert(original_update_calls==121 and original_after_calls==121)
                  assert(HD2SmoothBoot.c4_fire_scope.active==1,'fire scope reload failed')
                ''')
                config.write_text(options.replace('c4_context_batch=yes','c4_context_batch=no'),encoding='utf-8')
                vm.run('fixture_time=31;update(1/60);assert(upvalue(original_sync,"current")==original_current)')
                config.write_text(options,encoding='utf-8')
                vm.run('fixture_time=42;update(1/60);assert(HD2SmoothBoot.c4_fire_scope.active==1)')
                config.write_text(options.replace('enabled=yes','enabled=no'),encoding='utf-8')
                vm.run('fixture_time=54;update(1/60);assert(upvalue(original_sync,"current")==original_current)')
                config.write_text(options+'exclude=etxp/c4_boundary_probe\n',encoding='utf-8')
                vm.run('fixture_time=65;update(1/60);assert(upvalue(original_sync,"current")==original_current)')
                config.write_text(options,encoding='utf-8')
                vm.run('fixture_time=76;update(1/60);assert(HD2SmoothBoot.c4_fire_scope.active==1)')
                vm.run(r'''
                  local module=HD2SmoothBoot;module.c4_fire_scope.restore()
                  for i=1,12 do module.c4_read_pool.discover({unsupported})end
                  assert(module.c4_fire_scope.attempts==8 and module.c4_fire_scope.active==0)
                  assert(upvalue(original_sync,'current')==original_current)
                  module.c4_fire_scope.attempts=0
                  module.c4_read_pool.discover({update,after_update})
                  assert(module.c4_fire_scope.active==1)
                  local _,slot=upvalue(original_sync,'current');local later=function()end
                  debug.setupvalue(original_sync,slot,later);module.c4_fire_scope.restore()
                  assert(upvalue(original_sync,'current')==later)
                ''')
                print('PASS complete source, 120 paired callbacks/returns, fire discovery, reload, opt-outs/exclusion and bounded attempts')
            finally:vm.run('os.getenv=saved_getenv;os.clock=saved_clock')
    finally:vm.close()


def template_sizes(game):
    vm=VM(game)
    rows=[]
    try:
        setup(vm,quiet=True)
        for capacity in (1,16,128):
            counts=vm.run(r'''
              local n='''+str(capacity)+r'''
              D.ability_capacity=n;local templates=address+0xc700;local start=0
              for b=8,1,-1 do start=(start*256+ffi.string(ffi.cast('const char *',weapon),8):byte(b))%n end
              for i=0,n-1 do hashwrite(templates+i*16,'0011223344556677')end
              hashwrite(templates+((start+n-1)%n)*16,'51f50d6321f52f3d')
              w(templates,((start+n-1)%n)*16+8,0)
              ffi.fill(ffi.cast('void *',templates+n*16),88,0)
              M.c4_fire_scope.restore();calls=0;assert(gate.sync(true,true));local before=calls
              assert(M.c4_fire_scope.attach(gate));calls=0;assert(gate.sync(true,true))
              return before..','..calls
            ''')
            before,after=map(int,counts.split(','))
            assert after<before
            rows.append(dict(template_capacity=capacity,original_reads=before,candidate_reads=after))
    finally:vm.close()
    print('template size sensitivity',rows)
    return rows


def benchmark(game):
    vm=VM(game)
    results=[]
    try:
        setup(vm,quiet=True)
        for capacity in (1,16,128):
            raw=vm.run(r'''
              local n='''+str(capacity)+r'''
              D.ability_capacity=n;local templates=address+0xc700;local start=0
              for b=8,1,-1 do start=(start*256+ffi.string(ffi.cast('const char *',weapon),8):byte(b))%n end
              for i=0,n-1 do hashwrite(templates+i*16,'0011223344556677')end
              hashwrite(templates+((start+n-1)%n)*16,'51f50d6321f52f3d');w(templates,((start+n-1)%n)*16+8,0)
              ffi.fill(ffi.cast('void *',templates+n*16),88,0)
              local function run()
                for i=1,100 do assert(gate.sync(true,true))end
                collectgarbage('collect');collectgarbage('stop')
                local kb=collectgarbage('count');local t=os.clock()
                for i=1,500 do assert(gate.sync(true,true))end
                local elapsed=os.clock()-t;local allocated=collectgarbage('count')-kb
                collectgarbage('restart');collectgarbage('collect')
                return string.format('%.6f,%.3f',elapsed,allocated)
              end
              local rows={}
              for i=1,5 do
                local old,new
                if i%2==0 then
                  assert(M.c4_fire_scope.attach(gate));new=run();M.c4_fire_scope.restore();old=run()
                else
                  M.c4_fire_scope.restore();old=run();assert(M.c4_fire_scope.attach(gate));new=run()
                end
                rows[#rows+1]='["'..old..'","'..new..'"]'
              end
              return '['..table.concat(rows,',')..']'
            ''')
            pairs=json.loads(raw)
            rows=[dict(original=dict(zip(('seconds','allocated_kb'),map(float,a.split(',')))),
                       candidate=dict(zip(('seconds','allocated_kb'),map(float,b.split(','))))) for a,b in pairs]
            before=statistics.median(row['original']['seconds'] for row in rows)
            after=statistics.median(row['candidate']['seconds'] for row in rows)
            results.append(dict(template_capacity=capacity,batches=rows,original_median_s=before,candidate_median_s=after))
            print('500 owned checks, templates',capacity,'median seconds',before,'->',after)
    finally:vm.close()
    return results

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--game',action='store_true');parser.add_argument('--benchmark',action='store_true');args=parser.parse_args()
    vm=VM(args.game)
    try:setup(vm)
    finally:vm.close()
    results=contracts(args.game)
    full_module(args.game)
    counts=template_sizes(args.game)
    timings=benchmark(args.game) if args.benchmark else None
    out=HERE.parents[3]/'outputs/validated-2026-10-04/c4-fire-scope'
    out.mkdir(parents=True,exist_ok=True)
    (out/(('game' if args.game else 'modern')+'-contracts.json')).write_text(json.dumps(dict(
        contracts=results,full_module=True,template_sizes=counts,benchmark=timings,
        game_process_access=False,gameplay_validated=False,third_party_files_modified=False,
        scope='Owned synthetic template fixtures, original WeaponFireGate; not total C4 cost or FPS.'),indent=2),encoding='utf-8')

if __name__=='__main__':main()

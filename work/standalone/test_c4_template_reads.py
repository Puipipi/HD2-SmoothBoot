"""Fresh template scan replay using original C4 reader and owned memory only."""
import argparse
import json
import statistics
import subprocess
import unittest
from pathlib import Path
from test_c4_ui_scope import VM, setup as ui_setup

HERE = Path(__file__).parent
OUT = HERE.parents[3] / 'outputs/validated-2026-10-04/c4-template-reads'

def setup(vm,source=None):
    ui_setup(vm, source or (HERE/'smoothboot.lua').read_text(encoding='utf-8'), reference=True)
    vm.run(r'''
      reader=base.snapshot
      template_memory=ffi.new('uint8_t[32768]')
      templates=tonumber(ffi.cast('uintptr_t',template_memory));pw(owner,0x200,templates)
      weapon=owner+0x1000+24
      function prepare(capacity,visited,empty)
        D.ability_capacity=capacity
        ffi.fill(template_memory,32768,0)
        local start=0
        for b=8,1,-1 do start=(start*256+ffi.string(ffi.cast('const char *',weapon),8):byte(b))%capacity end
        scan_start=start
        for i=0,visited-1 do hashwrite(templates+((start+i)%capacity)*16,'0011223344556677')end
        target_at=templates+((start+visited-1)%capacity)*16
        if not empty then hashwrite(target_at,'51f50d6321f52f3d');w(target_at,8,0)end
        config_at=templates+capacity*16
        ffi.fill(ffi.cast('void *',config_at),88,0);w(config_at,0,521)
      end
      function semantic(f,extend)
        local row,why,cap=f(api,game,extend)
        if not row then return 'nil|'..tostring(why),cap end
        return table.concat({row.context_status,row.current_weapon,
          tostring(row.selected_entity_id),tostring(row.ability_template_status),
          tostring(row.ability_template_hex),tostring(row.action_context_status),
          tostring(row.action_context_error)},'|'),cap
      end
      prepare(128,128,false)
      calls=0;semantic(reader);optimized_reads=calls
    ''')

def run(game):
    vm=VM(game)
    try:
        setup(vm)
        measured=vm.run(r'''
          assert(optimized_reads<120,'RED: full context still reads template slots one by one: '..optimized_reads)
          return tostring(optimized_reads)
        ''')
    finally:vm.close()
    cases={
      'wrap_and_early_stop': '''for _,c in ipairs({1,16,128})do for _,n in ipairs({1,math.max(1,c-1),c})do
        prepare(c,n,false);assert(semantic(reader)==semantic(original.snapshot))
        prepare(c,n,true);assert(semantic(reader)==semantic(original.snapshot))end end''',
      'configuration_fresh': "prepare(128,128,false);local a=semantic(reader);w(config_at,0,520);local b=semantic(reader);assert(a~=b and b==semantic(original.snapshot))",
      'slot_fresh_next_snapshot': "prepare(128,128,false);local a=semantic(reader);hashwrite(target_at,'0011223344556677');assert(semantic(reader)~=a and semantic(reader)==semantic(original.snapshot))",
      'large_failure_fallback': "api.read=function(at,n)if at>=templates and at<templates+2048 and n>16 then return nil end;return original_read(at,n)end;assert(semantic(reader)==semantic(original.snapshot))",
      'large_short_fallback': "api.read=function(at,n)if at>=templates and at<templates+2048 and n>16 then return 'x' end;return original_read(at,n)end;assert(semantic(reader)==semantic(original.snapshot))",
      'large_exception_fallback': "api.read=function(at,n)if at>=templates and at<templates+2048 and n>16 and n<=256 and n%16==0 then error('unreadable_extra')end;return original_read(at,n)end;assert(semantic(reader)==semantic(original.snapshot))",
      'original_slot_failure': "api.read=function(at,n)if at>=templates and at<templates+2048 then return nil end;return original_read(at,n)end;local a,e=pcall(reader,api,game);assert(not a and e:find('read_unavailable'))",
      'mutation_visited_rejected': '''local changed=false;api.read=function(at,n)local b=original_read(at,n)
        if not changed and at>=templates and at<templates+2048 then changed=true;w(at,12,77)end;return b end
        local a=semantic(reader);assert(a=='nil|context_changed_during_read')''',
      'mutation_unvisited_ignored': '''prepare(128,1,false);local extra=templates+((scan_start+1)%128)*16
        local changed=false;api.read=function(at,n)local b=original_read(at,n)
        if not changed and at>=templates and at<templates+2048 then changed=true;w(extra,12,77)end;return b end
        assert(semantic(reader):find('present',1,true))''',
      'cap_same_reads_fresh': '''local function consumer(e)return {same=e.checked}end
        local _,cap=semantic(reader,consumer);assert(cap and cap.same());w(target_at,12,77);assert(not cap.same())''',
      'invalid_template_index': "w(target_at,8,128);local a,e=pcall(reader,api,game);assert(not a and e:find('ability_template_index_limit'))",
      'selected_weapon_switch': "hashwrite(weapon,'0011223344556677');assert(semantic(reader)==semantic(original.snapshot))",
      'read_accounting': '''calls=0;local row=reader(api,game);assert(row.memory_reads==calls)
        api.read=function(at,n)if at>=templates and at<templates+2048 and n>16 then calls=calls+1;return nil end;return original_read(at,n)end
        calls=0;row=reader(api,game);assert(row.memory_reads==calls)''',
    }
    passed=[]
    for name,body in cases.items():
        vm=VM(game)
        try:setup(vm);vm.run(body);passed.append(name)
        finally:vm.close()
    record={'game_dll':game,'long_probe_reads':int(measured),'contracts':passed,
            'scope':'Original reader on owned memory; not full C4 or live FPS validation.'}
    OUT.mkdir(parents=True,exist_ok=True)
    (OUT/('game-contracts.json' if game else 'modern-contracts.json')).write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(record,indent=2))

def benchmark(game):
    baseline=subprocess.run(['git','-C',str(HERE.parents[1]),'show',
        'a567c11:work/standalone/smoothboot.lua'],capture_output=True,encoding='utf-8',check=True).stdout
    candidate=(HERE/'smoothboot.lua').read_text(encoding='utf-8')
    records=[]
    for capacity in (1,16,128,512):
        pairs=[]
        for turn in range(3):
            pair={}
            for name in (('baseline','candidate') if turn%2==0 else ('candidate','baseline')):
                vm=VM(game)
                try:
                    setup(vm,baseline if name=='baseline' else candidate)
                    vm.run(f'prepare({capacity},{capacity},false)')
                    values=vm.run(r'''
                      local function trial(n)for i=1,n do assert(reader(api,game).ability_template_status=='present')end end
                      trial(120);local times={}
                      for i=1,5 do collectgarbage('collect');local t=os.clock();trial(500);times[i]=(os.clock()-t)*1000 end
                      collectgarbage('collect');collectgarbage('stop');calls=0
                      local before=collectgarbage('count');trial(100)
                      local allocated=collectgarbage('count')-before;collectgarbage('restart')
                      return table.concat(times,',')..';'..calls..';'..allocated
                    ''')
                    times,reads,allocated=values.split(';')
                    pair[name]={'median_ms_500':statistics.median(float(v) for v in times.split(',')),
                        'native_reads_100':int(reads),'allocation_kib_100':float(allocated)}
                finally:vm.close()
            pairs.append(pair)
        record={'template_slots':capacity,'trials':pairs}
        for metric in ('median_ms_500','native_reads_100','allocation_kib_100'):
            record[metric]={name:statistics.median(p[name][metric] for p in pairs) for name in ('baseline','candidate')}
        records.append(record)
        print(capacity,{k:v for k,v in record.items() if k not in ('trials','template_slots')})
    OUT.mkdir(parents=True,exist_ok=True)
    (OUT/('game-benchmark.json' if game else 'modern-benchmark.json')).write_text(
        json.dumps({'game_dll':game,'baseline_commit':'a567c11','records':records,
        'scope':'Separate VM and owned memory; template scanning only, not full C4 cost or FPS.'},indent=2)+'\n',encoding='utf-8')

class TemplateReads(unittest.TestCase):
    def test_real_template_scan_contracts(self):
        run(False)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--game',action='store_true');parser.add_argument('--benchmark',action='store_true')
    args=parser.parse_args()
    if args.benchmark:benchmark(args.game)
    else:run(args.game)

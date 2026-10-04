"""Original rounds/reload template loops through the real context adapter.

Only this process's allocated memory is read. No live game access or input.
"""
import argparse
import json
import statistics
import subprocess
import unittest
from pathlib import Path
from test_c4_template_reads import setup as template_setup
from test_c4_ui_scope import VM

HERE=Path(__file__).parent
ROOT=HERE.parents[3]
OUT=ROOT/'outputs/validated-2026-10-04/c4-extension-templates'

def setup(vm,source=None):
    template_setup(vm, source)
    vm.run((HERE/'fixtures/c4_extension_templates_reference.lua').read_text(encoding='utf-8'))
    vm.run(r'''
      extension_memory=ffi.new('uint8_t[65536]')
      ext=tonumber(ffi.cast('uintptr_t',extension_memory))
      D.rounds_templates=0x208;D.reload_templates=0x210
      D.rounds_stride=128;D.reload_stride=80
      pw(owner,D.rounds_templates,ext);pw(owner,D.reload_templates,ext+32768)
      function prepare_extension(kind,capacity,visited,empty)
        D[kind..'_capacity']=capacity
        ffi.fill(extension_memory,65536,0)
        local at=kind=='rounds' and ext or ext+32768
        local start=0
        for b=8,1,-1 do start=(start*256+ffi.string(ffi.cast('const char *',weapon),8):byte(b))%capacity end
        for i=0,visited-1 do hashwrite(at+((start+i)%capacity)*16,'0011223344556677')end
        ext_target=at+((start+visited-1)%capacity)*16;ext_unvisited=at+((start+visited)%capacity)*16
        if not empty then hashwrite(ext_target,'51f50d6321f52f3d');w(ext_target,8,0)end
        ext_base=at;ext_end=at+capacity*16;ext_config=ext_end
        ffi.fill(ffi.cast('void *',ext_config),D[kind..'_stride'],17)
      end
      function observe(f,kind)
        local row,why,cap=f(api,game,kind=='rounds' and rounds_extend or reload_extend)
        if not row then return 'nil|'..tostring(why),cap end
        return table.concat({row.context_status,tostring(row.action_context_status),
          tostring(row.action_context_error),cap and (cap.config:gsub('.',function(c)return string.format('%02x',c:byte())end)) or '-'},'|'),cap
      end
    ''')

CASES={
  'both_scans': '''prepare_extension('rounds',128,128,false);prepare_extension('reload',128,128,false)
    -- Second preparation clears both regions; repopulate the rounds table.
    ffi.copy(extension_memory,extension_memory+32768,32768)
    local function both(e,row)local a=rounds_extend(e,row);local b=reload_extend(e,row)
      assert(a.config:sub(1,80)==b.config);return a end
    local a,why,cap=reader(api,game,both);assert(a and not why and cap and cap.same())''',
  'wrap_empty_early_stop': '''for _,c in ipairs({1,16,128,512})do for _,n in ipairs({1,math.max(1,c-1),c})do
    prepare_extension(kind,c,n,false);assert(observe(reader,kind)==observe(original.snapshot,kind))
    prepare_extension(kind,c,n,true);assert(observe(reader,kind)==observe(original.snapshot,kind))end end''',
  'fresh_snapshot': '''prepare_extension(kind,128,128,false);local a=observe(reader,kind)
    w(ext_config,0,18);local b=observe(reader,kind);assert(a~=b and b==observe(original.snapshot,kind))''',
  'cap_same_fresh': '''prepare_extension(kind,128,128,false);local _,cap=observe(reader,kind)
    assert(cap and cap.same());w(ext_target,12,77);assert(not cap.same())''',
  'extra_failure': '''prepare_extension(kind,128,128,false);api.read=function(at,n)
    if at>=ext_base and at<ext_end and n>16 then return nil end;return original_read(at,n)end
    assert(observe(reader,kind)==observe(original.snapshot,kind))''',
  'extra_short': '''prepare_extension(kind,128,128,false);api.read=function(at,n)
    if at>=ext_base and at<ext_end and n>16 then return 'x' end;return original_read(at,n)end
    assert(observe(reader,kind)==observe(original.snapshot,kind))''',
  'extra_exception': '''prepare_extension(kind,128,128,false);api.read=function(at,n)
    if at>=ext_base and at<ext_end and n>16 and n<=256 then error('unreadable_extra')end;return original_read(at,n)end
    assert(observe(reader,kind)==observe(original.snapshot,kind))''',
  'original_slot_failure': '''prepare_extension(kind,128,128,false);api.read=function(at,n)
    if at>=ext_base and at<ext_end then return nil end;return original_read(at,n)end
    assert(observe(reader,kind)==observe(original.snapshot,kind))''',
  'visited_mutation_rejected': '''prepare_extension(kind,128,128,false);local changed=false
    api.read=function(at,n)local b=original_read(at,n)
      if not changed and at>=ext_base and at<ext_end then changed=true;w(at,12,77)end;return b end
    assert(observe(reader,kind)=='nil|context_changed_during_read')''',
  'unvisited_mutation_ignored': '''prepare_extension(kind,128,1,false);local changed=false
    api.read=function(at,n)local b=original_read(at,n)
      if not changed and at>=ext_base and at<ext_end then changed=true;w(ext_unvisited,12,77)end;return b end
    local value,cap=observe(reader,kind);assert(value:find('validated',1,true) and cap)''',
  'bad_index': '''prepare_extension(kind,128,128,false);w(ext_target,8,128)
    assert(observe(reader,kind)==observe(original.snapshot,kind))''',
  'escaped_read_is_fresh': '''prepare_extension(kind,128,1,false);local saved
    reader(api,game,function(e,row) saved=e.read;local f=kind=='rounds' and rounds_extend or reload_extend
      return f(e,row)end);w(ext_target,12,77)
    assert(saved(ext_target,16,true)==original_read(ext_target,16))''',
  'actual_read_accounting': '''prepare_extension(kind,128,128,false);calls=0
    local row=reader(api,game,kind=='rounds' and rounds_extend or reload_extend);assert(row.memory_reads==calls)''',
  'unrelated_range_no_prefetch': '''prepare_extension(kind,128,1,false);local before
    reader(api,game,function(e,row)local f=kind=='rounds' and rounds_extend or reload_extend;local cap=f(e,row)
      before=calls;e.read(ext_base+4096,16,true);assert(calls==before+1);return cap end)''',
  'pointer_reread_resets_scan': '''prepare_extension(kind,128,1,false)
    reader(api,game,function(e,row)local f=kind=='rounds' and rounds_extend or reload_extend;f(e,row)
      w(ext_target,12,77);e.ptr(owner+D[kind..'_templates'],true)
      assert(e.read(ext_target,16,true)==original_read(ext_target,16));return {}end)''',
  'invalid_pointer': '''prepare_extension(kind,128,128,false);pw(owner,D[kind..'_templates'],0)
    assert(observe(reader,kind)==observe(original.snapshot,kind))''',
  'failed_block_accounting': '''prepare_extension(kind,128,128,false)
    api.read=function(at,n)if at>=ext_base and at<ext_end and n>16 then calls=calls+1;return nil end
      return original_read(at,n)end;calls=0
    local row=reader(api,game,kind=='rounds' and rounds_extend or reload_extend);assert(row.memory_reads==calls)''',
  'fallback_original_short_slot': '''prepare_extension(kind,128,128,false)
    api.read=function(at,n)if at>=ext_base and at<ext_end then return 'x' end;return original_read(at,n)end
    assert(observe(reader,kind)==observe(original.snapshot,kind))''',
}

def run(game):
    results=[]
    measurements={}
    for kind in ('rounds','reload'):
        vm=VM(game)
        try:
            setup(vm)
            measurements[kind]=vm.run(f'''prepare_extension('{kind}',128,128,false)
              calls=0;assert(select(2,observe(reader,'{kind}')));local candidate=calls
              calls=0;assert(select(2,observe(original.snapshot,'{kind}')));local baseline=calls
              assert(candidate<150,'RED: extension template scan still uses '..candidate..' reads')
              return tostring(baseline)..','..candidate''')
        finally:vm.close()
        for name,body in CASES.items():
            vm=VM(game)
            try:
                setup(vm)
                try:vm.run("kind='"+kind+"';"+body)
                except Exception as exc:raise AssertionError(kind+':'+name) from exc
                results.append(kind+':'+name)
            finally:vm.close()
    OUT.mkdir(parents=True,exist_ok=True)
    record={'game_dll':game,'contracts':results,'reads':measurements,
            'scope':'Original template-loop excerpts via real context adapter on owned memory, not full ActionReader/FPS.'}
    (OUT/('game-contracts.json' if game else 'modern-contracts.json')).write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(record,indent=2))

class ExtensionTemplates(unittest.TestCase):
    def test_original_loops(self):run(False)

def benchmark(game):
    baseline=subprocess.run(['git','-C',str(HERE.parents[1]),'show','85d259d:work/standalone/smoothboot.lua'],
                            capture_output=True,encoding='utf-8',check=True).stdout
    candidate=(HERE/'smoothboot.lua').read_text(encoding='utf-8')
    records=[]
    for kind in ('rounds','reload'):
        for capacity in (1,16,128,512):
            trials=[]
            for turn in range(3):
                pair={}
                for name in (('baseline','candidate') if turn%2==0 else ('candidate','baseline')):
                    vm=VM(game)
                    try:
                        setup(vm,baseline if name=='baseline' else candidate)
                        value=vm.run(f"prepare_extension('{kind}',{capacity},{capacity},false);kind='{kind}';"+r'''
                          local function trial(n)for i=1,n do local row,why,cap=reader(api,game,kind=='rounds' and rounds_extend or reload_extend)
                            assert(row and not why and cap and cap.same())end end
                          trial(120);local times={}
                          for i=1,5 do collectgarbage('collect');local t=os.clock();trial(500);times[i]=(os.clock()-t)*1000 end
                          collectgarbage('collect');collectgarbage('stop');calls=0
                          local before=collectgarbage('count');trial(100)
                          local allocated=collectgarbage('count')-before;collectgarbage('restart')
                          return table.concat(times,',')..';'..calls..';'..allocated
                        ''')
                        times,reads,allocated=value.split(';')
                        pair[name]={'median_ms_500':statistics.median(float(v) for v in times.split(',')),
                                    'native_reads_100':int(reads),'allocation_kib_100':float(allocated)}
                    finally:vm.close()
                trials.append(pair)
            row={'kind':kind,'template_slots':capacity,'trials':trials}
            for metric in ('median_ms_500','native_reads_100','allocation_kib_100'):
                row[metric]={name:statistics.median(p[name][metric] for p in trials) for name in ('baseline','candidate')}
            records.append(row)
            print(kind,capacity,{k:v for k,v in row.items() if k not in ('kind','template_slots','trials')},flush=True)
    OUT.mkdir(parents=True,exist_ok=True)
    (OUT/('game-benchmark.json' if game else 'modern-benchmark.json')).write_text(
        json.dumps({'game_dll':game,'baseline':'85d259d (3.0.38)','records':records,
                    'scope':'Separate VMs and owned memory, excerpt loops; not full C4 or FPS.'},indent=2)+'\n',encoding='utf-8')

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--game',action='store_true');parser.add_argument('--benchmark',action='store_true')
    args=parser.parse_args()
    if args.benchmark:benchmark(args.game)
    else:run(args.game)

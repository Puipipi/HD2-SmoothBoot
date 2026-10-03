"""Native memory contracts for the optional C4 binding scan adapter."""
from pathlib import Path
import unittest
import lupa.luajit21 as luajit

class InputBatch(unittest.TestCase):
    def setUp(self):
        source=Path(__file__).with_name('smoothboot.lua').read_text(encoding='utf-8')
        start=source.index('-- BEGIN C4 INPUT BATCH')
        block=source[start:source.index('-- END C4 INPUT BATCH',start)]
        self.rt=luajit.LuaRuntime(unpack_returned_tuples=True)
        self.rt.execute('cfg={enabled=true,c4_input_batch=true};excludes={};log=function()end;M={};'
                        'function function_chunk()return "" end;function is_excluded()return false end')
        self.rt.globals().batch=self.rt.execute(block+'\nreturn C4Batch')
        self.rt.execute(r'''
            ffi=require('ffi');ffi.cdef[[void *GetCurrentProcess(void);
              int ReadProcessMemory(void *,const void *,void *,size_t,size_t *);]]
            k=ffi.load('kernel32');process=k.GetCurrentProcess()
            gm=ffi.new('uint8_t[32]');om=ffi.new('uint8_t[10000]');bm=ffi.new('uint8_t[83968]')
            game=tonumber(ffi.cast('uintptr_t',gm));owner=tonumber(ffi.cast('uintptr_t',om))
            buckets=tonumber(ffi.cast('uintptr_t',bm))
            function w(p,o,n)ffi.cast('uint32_t *',p+o)[0]=n end
            function pw(p,o,n)ffi.cast('uintptr_t *',p+o)[0]=n end
            pw(game,8,owner);pw(owner,8000,buckets);w(owner,8008,256);w(owner,8016,1)
            D={input_aim_action=91,input_aim_code=11,input_inhibit_count=100,input_inhibit_capacity=8,
               input_inhibit_map=200,input_inhibit_rows=4000,input_bindings=8000}
            R={global_input_owner=8};codes={deploy=22,detonate=33};calls=0;fail_large=false
            local out,count=ffi.new('uint8_t[4096]'),ffi.new('size_t[1]')
            api={}
            function api.read(p,n)
              calls=calls+1;if fail_large and n>512 then return nil end
              count[0]=0
              if k.ReadProcessMemory(process,ffi.cast('const void *',p),out,n,count)==0 or tonumber(count[0])~=n then return nil end
              return ffi.string(out,n)
            end
            function api.pointer(b)local t=ffi.new('uintptr_t[1]');ffi.copy(t,b,8);return tonumber(t[0])end
            base={}
            function base.u32(b,o)local a,c,d,e=b:byte(o+1,o+4);return a+c*256+d*65536+e*16777216 end
            function base.product_low(a,b)return (a*b)%4294967296 end
            for i,code in pairs({[220]=11,[245]=22,[17]=33})do
              w(buckets,i*328,code);w(buckets,i*328+4,1);w(buckets,i*328+8,code)
            end
            native={input_mapping=function()return buckets+220*328+8 end}
            read=batch.make_reader(D,R)
        ''')

    def test_complete_lookup_uses_fewer_native_calls(self):
        self.rt.execute('p=read(api,game,base,codes,native);assert(p.aim and #p.deploy==1 and #p.detonate==1 and p.same());assert(calls<=250,calls)')

    def test_every_invocation_reads_fresh_mapping_bytes(self):
        self.rt.execute('p=read(api,game,base,codes,native);w(buckets,220*328+8,999);q=read(api,game,base,codes,native);assert(p.aim~=q.aim)')

    def test_scan_allocation_stays_below_seventy_kb_per_call(self):
        # JIT off and GC stopped isolate allocation, not wall time or game FPS.
        self.rt.execute(r'''
            jit.off();collectgarbage('collect');collectgarbage('stop')
            local before=collectgarbage('count')
            for i=1,50 do
                local result=read(api,game,base,codes,native)
                assert(result.same())
            end
            allocation_kb_per_call=(collectgarbage('count')-before)/50
            collectgarbage('restart')
        ''')
        self.assertLess(self.rt.globals().allocation_kb_per_call, 70)

    def test_old_validation_closures_keep_their_own_snapshot(self):
        self.rt.execute(r'''
            local first=read(api,game,base,codes,native)
            w(buckets,220*328+8,999)
            local second=read(api,game,base,codes,native)
            assert(not first.same() and second.same())
            w(buckets,220*328+8,11)
            assert(first.same() and not second.same())
        ''')

    def test_final_validation_rejects_changes_during_native_query(self):
        self.rt.execute(r'''
            native.input_mapping=function()w(buckets,245*328,99);return buckets+220*328+8 end
            local ok,why=pcall(read,api,game,base,codes,native)
            assert(not ok and why:find('aim_snapshot_changed',1,true),tostring(why))
        ''')

    def test_returned_same_rejects_key_and_mapping_mutations(self):
        self.rt.execute('p=read(api,game,base,codes,native);w(buckets,17*328,99);assert(not p.same());w(buckets,17*328,33);w(buckets,220*328+8,999);assert(not p.same())')

    def test_failed_extra_region_read_falls_back_to_original_small_reads(self):
        self.rt.execute('fail_large=true;p=read(api,game,base,codes,native);assert(p.aim and p.same())')

    def test_missing_binding_and_bad_selected_mapping_still_fail(self):
        self.rt.execute(r'''
            w(buckets,17*328,99)
            local ok,why=pcall(read,api,game,base,codes,native)
            assert(not ok and why:find('aim_binding_missing',1,true))
            w(buckets,17*328,33);native.input_mapping=function()return buckets+8 end
            ok,why=pcall(read,api,game,base,codes,native)
            assert(not ok and why:find('aim_selected_mapping_outside_bucket',1,true))
        ''')

    def test_unknown_reader_is_not_modified(self):
        self.rt.execute('local fn=function()end;local target={read=fn};assert(not batch.attach(target));assert(target.read==fn)')

    def test_all_scanned_keys_remain_guarded_including_unmatched_keys(self):
        self.rt.execute('p=read(api,game,base,codes,native);w(buckets,11*328,99);assert(not p.same())')

    def test_fire_and_stop_paths_do_not_query_aim_bindings(self):
        self.rt.execute(r'''
            native.input_mapping=function()error('must not query mappings')end
            local p=read(api,game,base,nil,native);assert(p.owner==owner and p.same())
            p=read(api,game,base,true,native,{action=92,code=99,index=9,fire=true})
            assert(p.owner==owner and p.held==false and p.same())
        ''')

    def test_inhibition_owner_row_is_checked_and_kept(self):
        self.rt.execute(r'''
            local map=ffi.new('uint8_t[16]');local at=tonumber(ffi.cast('uintptr_t',map))
            w(owner,100,1);pw(owner,200,at);w(owner,208,2);w(owner,212,0xffffffff);w(owner,216,1)
            w(at,0,0xffffffff);w(at,8,11);w(at,12,0)
            w(owner,4000,1);w(owner,4004,2);w(owner,4008,8)
            local p=read(api,game,base,codes,native)
            assert(p.mask.address==owner+4000 and p.mask.mode==1 and p.count==1 and p.same())
            w(owner,4000,2);assert(not p.same())
        ''')

if __name__=='__main__':unittest.main()

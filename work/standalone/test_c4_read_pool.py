"""Native reader contracts; no third-party source and no game process access."""
from pathlib import Path
import unittest
import lupa.luajit21 as luajit

SOURCE = Path(__file__).with_name('smoothboot.lua').read_text(encoding='utf-8')
BEGIN = SOURCE.index('-- BEGIN C4 READ POOL')
END = SOURCE.index('-- END C4 READ POOL', BEGIN)


class ReadPool(unittest.TestCase):
    def setUp(self):
        self.rt = luajit.LuaRuntime(unpack_returned_tuples=True)
        self.rt.execute('M={};cfg={enabled=true,c4_read_pool=true};excludes={};'
                        'log=function()end;function function_chunk()return "" end;'
                        'function is_excluded()return false end')
        self.rt.globals().pool = self.rt.execute(SOURCE[BEGIN:END]+'\nreturn C4Pool')
        self.rt.execute(r'''
            ffi=require('ffi');assert(ffi.os=='Windows')
            ffi.cdef[[void *GetCurrentProcess(void);
                int ReadProcessMemory(void *,const void *,void *,size_t,size_t *);]]
            k=ffi.load('kernel32');memory=ffi.new('uint8_t[4096]')
            address=tonumber(ffi.cast('uintptr_t',memory))
            read,read_count=pool.make_reader(ffi,k.ReadProcessMemory,k.GetCurrentProcess())
        ''')

    def test_reads_fresh_binary_data_at_all_supported_sizes(self):
        self.rt.execute(r'''
            for _,size in ipairs({1,2,4,8,16,64,256,4096}) do
                ffi.fill(memory,4096,0);assert(read(address,size)==string.rep('\0',size))
                ffi.fill(memory,4096,255);assert(read(address,size)==string.rep('\255',size))
            end
            assert(read_count()==16)
        ''')

    def test_failed_read_cannot_return_stale_success(self):
        self.rt.execute(r'''
            ffi.fill(memory,4096,65);assert(read(address,8)=='AAAAAAAA')
            assert(read(65536,8)==nil)
            ffi.fill(memory,4096,66);assert(read(address,8)=='BBBBBBBB')
        ''')

    def test_invalid_bounds_keep_original_guard_reasons(self):
        self.rt.execute(r'''
            for _,test in ipairs({{1,1,'bad_read_address'},
                                  {0x800000000000,1,'bad_read_address'},
                                  {address,0,'read_size_limit'},
                                  {address,-1,'read_size_limit'},
                                  {address,4097,'read_size_limit'}}) do
                local ok,why=pcall(read,test[1],test[2])
                assert(not ok and why:find(test[3],1,true))
            end
            assert(read_count()==0)
        ''')

    def test_fractional_size_is_not_accepted_as_complete(self):
        self.rt.execute('assert(read(address,1.5)==nil)')

    def test_each_adapter_has_independent_buffers(self):
        self.rt.execute(r'''
            local other=pool.make_reader(ffi,k.ReadProcessMemory,k.GetCurrentProcess())
            ffi.fill(memory,4096,65);local saved=read(address,8)
            ffi.fill(memory,4096,66);assert(other(address,8)=='BBBBBBBB')
            assert(saved=='AAAAAAAA');assert(read(address,8)=='BBBBBBBB')
        ''')

    def test_no_repeated_native_buffer_allocation(self):
        self.rt.execute(r'''
            local original_new=ffi.new;local allocations=0
            ffi.new=function(...) allocations=allocations+1;return original_new(...) end
            local other=pool.make_reader(ffi,k.ReadProcessMemory,k.GetCurrentProcess())
            for i=1,10000 do assert(other(address,8)) end
            ffi.new=original_new;assert(allocations==2)
        ''')

    def test_unknown_readers_and_metatables_are_not_modified(self):
        self.rt.execute(r'''
            local original=function()return 'foreign' end
            local api={read=original};assert(not pool.attach(api));assert(api.read==original)
            local guarded=setmetatable({read=original},{__index=function()error('metatable executed')end})
            assert(not pool.attach(guarded));assert(guarded.read==original)
        ''')

    def test_restore_respects_later_replacements(self):
        self.rt.execute(r'''
            local original=function()end;local ours=function()end;local later=function()end
            local a,b={read=ours},{read=later}
            pool.records[a]={original=original,pooled=ours}
            pool.records[b]={original=original,pooled=ours}
            pool.active=2;pool.restore()
            assert(a.read==original and b.read==later)
            assert(pool.active==0 and next(pool.records)==nil)
        ''')

    def test_disabled_setting_restores_and_allows_future_discovery(self):
        self.rt.execute(r'''
            local original=function()end;local ours=function()end;local api={read=ours}
            pool.records[api]={original=original,pooled=ours};pool.active=1;pool.attempts=8
            cfg.c4_read_pool=false;pool.discover({})
            assert(api.read==original and pool.active==0 and pool.attempts==0)
            cfg.c4_read_pool=true;pool.discover({});assert(pool.attempts==1)
        ''')

    def test_read_probe_counts_without_replaying_or_caching_reads(self):
        self.rt.execute(r'''
            local native_calls=0
            local original=function(address,size)
                native_calls=native_calls+1
                if address==65536 then return nil end
                return string.rep(string.char(native_calls%256),size)
            end
            local probe,state=pool.make_probe(original)
            for i=1,1018 do
                local value=probe(address,8)
                assert(value==string.rep(string.char(i%256),8))
            end
            assert(probe(65536,8)==nil)
            assert(native_calls==1019 and state.calls==1019 and state.samples==2)
            local hits=0;for _,count in pairs(state.sites)do hits=hits+count end
            assert(hits==2)
        ''')

    def test_read_probe_preserves_original_errors(self):
        self.rt.execute(r'''
            local probe=pool.make_probe(function()error('original_fault')end)
            local ok,why=pcall(probe,address,8)
            assert(not ok and why:find('original_fault',1,true))
        ''')

    def test_probe_records_real_c4_callsite_and_phase(self):
        self.rt.execute(r'''
            local probe,state=pool.make_probe(function()return 'fresh' end)
            HD2C4BoundaryProbe={phase='before_original_update'}
            local caller=assert(loadstring('local probe=...; return function()\n'..
                'local value=probe(65536,8)\nreturn value\nend',
                '@mods/etxp/c4_boundary_probe.lua'))(probe)
            for i=1,509 do assert(caller()=='fresh')end
            assert(state.samples==1)
            local site=next(state.sites)
            assert(site:find('before_original_update',1,true) and site:find(':2',1,true),site)
            pool.records[{}]={profile=state};pool.report_probe()
            assert(state.calls==0 and state.samples==0 and next(state.sites)==nil)
        ''')

    def test_probe_capture_failure_does_not_block_a_native_read(self):
        self.rt.execute(r'''
            local probe,state=pool.make_probe(function()return 'fresh' end)
            local old_info=debug.getinfo
            debug.getinfo=function()error('diagnostic_fault')end
            for i=1,509 do assert(probe(address,8)=='fresh')end
            debug.getinfo=old_info
            assert(state.calls==509 and state.errors==1 and state.samples==0)
        ''')


if __name__=='__main__':
    unittest.main()

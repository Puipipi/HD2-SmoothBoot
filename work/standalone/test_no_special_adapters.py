"""C4 stays an ordinary chain callback, with no native API replacement."""
import tempfile
import unittest
from pathlib import Path

from test_memory_lifetime import SOURCE, bootstrap
from lua_test_vm import VM


class NoSpecialAdapters(unittest.TestCase):
    def test_runtime_contains_no_c4_adapters(self):
        self.assertNotIn('c4_', SOURCE.lower())
        self.assertNotIn('C4Pool', SOURCE)
        self.assertNotIn('HD2C4BoundaryProbe', SOURCE)

    def test_legacy_config_is_ignored_without_rewriting_foreign_api(self):
        for game in (False, True):
            with self.subTest(game=game), tempfile.TemporaryDirectory() as tmp:
                vm = VM(game)
                try:
                    bootstrap(vm, tmp, source='')
                    config = Path(tmp)/'CowboyBingus/Helldivers2/SmoothBoot/config.txt'
                    config.write_text(
                        'enabled=yes\nthrottle=no\nwriters=\nboot_pause_s=0\n'
                        'exclude=lte/helmet_cape_passives\n'
                        'c4_read_pool=yes\nc4_read_profile=yes\nc4_cpu_profile=yes\n'
                        'c4_context_batch=yes\nc4_input_batch=yes\n'
                        'c4_native_batch=yes\nc4_idle_batch=yes\n', encoding='utf-8')
                    before = config.read_bytes()
                    vm.run('''
                        local ticks=0
                        local api={read=function(a,n)return a,n,nil end}
                        HD2C4BoundaryProbe={api=api}
                        original_read=api.read
                        update=assert(loadstring([[return function(dt)
                            chain_ticks=(chain_ticks or 0)+1
                            return HD2C4BoundaryProbe.api.read(27,3)
                        end]], '@mods/etxp/c4_boundary_probe.lua'))()
                    ''')
                    vm.run(SOURCE)
                    vm.run('''
                        step(1500)
                        assert(chain_ticks==1500,'ordinary callback was skipped')
                        assert(HD2C4BoundaryProbe.api.read==original_read,'foreign API changed')
                        for key in pairs(HD2SmoothBoot) do
                            assert(not tostring(key):lower():find('c4_',1,true),'adapter exported')
                        end
                        local a,b,c=update(1/120)
                        assert(a==27 and b==3 and c==nil,'callback results changed')
                    ''')
                    self.assertEqual(before, config.read_bytes())
                finally:
                    vm.close()

    def test_generated_config_has_no_legacy_adapter_options(self):
        for game in (False, True):
            with self.subTest(game=game), tempfile.TemporaryDirectory() as tmp:
                vm = VM(game)
                try:
                    bootstrap(vm, tmp, source='')
                    config = Path(tmp)/'CowboyBingus/Helldivers2/SmoothBoot/config.txt'
                    config.unlink()
                    vm.run(SOURCE)
                    self.assertNotIn('c4_', config.read_text(encoding='utf-8').lower())
                finally:
                    vm.close()


if __name__ == '__main__':
    unittest.main()

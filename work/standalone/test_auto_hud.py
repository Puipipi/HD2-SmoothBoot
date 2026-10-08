"""Unknown HUDs through real Smooth scheduling in two isolated LuaJIT VMs.

Every drawing API here is owned simulated work. No game input, GUI or memory.
"""
import json
from pathlib import Path
import tempfile
import unittest
from lua_test_vm import VM

SOURCE = Path(__file__).with_name('smoothboot.lua').read_text(encoding='utf-8')


class AutoHud(unittest.TestCase):
    def run_case(self, game, style, layout='below', expected_full=True, exclude=False, utility=True):
        with tempfile.TemporaryDirectory(prefix='sb-unknown-hud-') as tmp:
            home = Path(tmp)/'CowboyBingus/Helldivers2'
            (home/'SmoothBoot').mkdir(parents=True)
            (home/'Logs').mkdir()
            (home/'SmoothBoot/config.txt').write_text(
                'throttle=auto\ngrace_s=0\nbusy_ms=1\nmax_skip=2\n'
                'boot_pause_s=0\nwriters=\n' +
                ('exclude=test/tank_status\n' if exclude else ''), encoding='utf-8')
            vm = VM(game)
            try:
                vm.run('local getenv=os.getenv;os.getenv=function(k) if k=="LOCALAPPDATA" '
                       'then return '+json.dumps(tmp.replace('\\', '/'))+
                       ' end return getenv(k) end; clock=0;os.clock=function()return clock end;'
                       'CowboyBingusModLoader={};calls=0;draws=0;base_calls=0;pending=nil;'
                       'update=function()base_calls=base_calls+1 end;render=function()end;'
                       'local function emit()draws=draws+1 end;'
                       'stingray={Gui={text=emit,rect=emit},LineObject={add_line=emit},'
                       'World={create_screen_gui=function()return {} end}}')
                styles = {
                    'global-gui': ('', 'stingray.Gui.text(nil,"tank ready")'),
                    'gui-alias': ('local g=stingray.Gui;', 'g.text(nil,"tank ready")'),
                    'api-alias': ('local emit=stingray.Gui.text;', 'emit(nil,"tank ready")'),
                    'nested-helper': ('local draw=function()stingray.Gui.text(nil,"tank ready")end;', 'draw()'),
                    'line': ('', 'stingray.LineObject.add_line(nil)'),
                    'render-hook': ('', 'pending=dt'),
                    # Strings alone must not identify a drawing callback.
                    'scanner': ('', 'local words="stingray Gui text create_screen_gui"'),
                    'gui-metatable': ('local g=stingray.Gui;', 'local words="text"'),
                    'non-engine-text': ('local g=setmetatable({text=function()end},getmetatable(stingray.Gui));', 'g.text()'),
                }
                prefix, body = styles[style]
                vm.run('local u=require("jit.util");local bc=u.funcbc;metadata_reads=0;'
                       'u.funcbc=function(...)metadata_reads=metadata_reads+1;return bc(...)end')
                if not utility:
                    vm.run('local original_require=require;require=function(name)'
                           'if name=="jit.util" then error("metadata utility unavailable")end;'
                           'return original_require(name)end')
                if style == 'gui-metatable':
                    vm.run('stingray.Gui=setmetatable({},'
                           '{__index=function()error("graphics metatable invoked")end})')
                if style == 'non-engine-text':
                    vm.run('setmetatable(stingray.Gui,{__eq=function()error("foreign equality invoked")end})')
                layer = ('update=assert(loadstring([['+prefix+
                         'local previous_update=...;return function(dt,...)'
                         'calls=calls+1;clock=clock+.005;'+body+';'
                         'return previous_update(dt,...)end]],'
                         "'@mods/test/tank_status.lua'))(update)")
                if layout in ('above', 'late-render'):
                    vm.run(SOURCE)
                vm.run(layer)
                if layout == 'deep-bus':
                    vm.run('local BUS={base=update,jobs={}};update=assert(loadstring([['
                           'local BUS=...;return function(...)return BUS.base(...)end]],'
                           "'@mods/test/update_bus'))(BUS)")
                if layout not in ('above', 'late-render'):
                    vm.run(SOURCE)
                if style == 'render-hook':
                    vm.run("render=assert(loadstring([[local previous_render=...;return function(...)"
                           "if pending then draws=draws+1;pending=nil end;return previous_render(...)end]],"
                           "'@mods/test/tank_status_render.lua'))(render)")
                vm.run('clock=clock+1/60;update(1/60);render();metadata_at_first=metadata_reads')
                result = vm.run('for i=2,180 do clock=clock+1/60;update(1/60);render()end;'
                                'return calls..","..draws..","..base_calls')
                counts = list(map(int, result.split(',')))
                if expected_full:
                    self.assertEqual(counts[0], 180, 'unknown HUD update was skipped')
                    self.assertEqual(counts[2], 180, 'downstream duplicated or skipped')
                    if style != 'scanner':
                        self.assertEqual(counts[1], 180, 'unknown HUD draw cadence reduced')
                else:
                    self.assertLess(counts[0], 180, 'ordinary scanner no longer throttled')
                if utility:
                    vm.run('assert(metadata_at_first>0,"no metadata discovery occurred");'
                           'assert(metadata_reads==metadata_at_first,"immutable bytecode rescanned")')
                if exclude:
                    vm.run('assert(#HD2SmoothBoot.excluded_below==1,"bus exclusion not discovered")')
                    log=(home/'Logs/SmoothBoot.log').read_text(encoding='utf-8')
                    self.assertNotIn('"test/tank_status" matched no mod',log)
                return vm.run('return table.concat(HD2SmoothBoot.protected_sources or {},",")')
            finally:
                vm.close()

    def test_unknown_gui_helpers_and_aliases_keep_each_update(self):
        for game in (False, True):
            for style in ('global-gui', 'gui-alias', 'api-alias', 'nested-helper', 'line'):
                for layout in ('below', 'above', 'deep-bus'):
                    with self.subTest(game=game, style=style, layout=layout):
                        self.run_case(game, style, layout)

    def test_new_render_hook_without_update_head_change_is_detected(self):
        for game in (False, True):
            with self.subTest(game=game):
                self.run_case(game, 'render-hook', 'late-render')

    def test_text_only_scanner_still_throttles(self):
        for game in (False, True):
            with self.subTest(game=game):
                self.run_case(game, 'scanner', expected_full=False)

    def test_gui_table_metatable_is_never_invoked_by_discovery(self):
        for game in (False, True):
            with self.subTest(game=game):
                self.run_case(game, 'gui-metatable', expected_full=False)

    def test_unrelated_text_table_does_not_protect_or_invoke_equality(self):
        for game in (False, True):
            with self.subTest(game=game):
                self.run_case(game, 'non-engine-text', expected_full=False)

    def test_exact_exclusion_inside_bus_keeps_unknown_callback_running(self):
        for game in (False, True):
            with self.subTest(game=game):
                self.run_case(game, 'scanner', 'deep-bus', exclude=True)

    def test_missing_metadata_utility_preserves_manual_exclusion_and_returns(self):
        for game in (False, True):
            with self.subTest(game=game):
                self.run_case(game, 'scanner', 'deep-bus', exclude=True, utility=False)


if __name__ == '__main__':
    unittest.main()

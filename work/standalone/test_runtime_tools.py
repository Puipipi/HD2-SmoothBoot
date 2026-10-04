"""Exercise runtime provisioning and the shipped collector, with isolated data."""
import pathlib
import os
import re
import subprocess
import zipfile
import tempfile
import unittest

import lupa.luajit21 as luajit
import lupa.lua51 as lua51

SOURCE = pathlib.Path(__file__).with_name('smoothboot.lua').read_text(encoding='utf-8')


def start(root, engine=luajit):
    runtime = engine.LuaRuntime()
    runtime.globals().os.getenv = lambda key: str(root) if key == 'LOCALAPPDATA' else None
    runtime.execute('CowboyBingusModLoader = {}; update = function() end')
    runtime.execute(SOURCE)
    return runtime


class RuntimeTools(unittest.TestCase):
    def test_collector_builds_zip_without_clobbering_generic_temp_files(self):
        with tempfile.TemporaryDirectory(prefix='sb-collect-') as tmp:
            root=pathlib.Path(tmp)
            start(root)
            folder=root/'CowboyBingus/Helldivers2/SmoothBoot'
            log=root/'CowboyBingus/Helldivers2/Logs/fixture.log'
            log.write_text('fixture-runtime-evidence\n',encoding='utf-8')
            roaming=root/'roaming'
            watchdog=roaming/'Arrowhead/Helldivers2/mod_lag_finder.log'
            watchdog.parent.mkdir(parents=True)
            watchdog.write_text('fixture-hitch-evidence\n',encoding='utf-8')
            mdl=root/'MDL/Helldivers2'
            mdl.mkdir(parents=True)
            (mdl/'MDL.cfg').write_text('enabled=yes\n',encoding='utf-8')
            temporary=root/'temp'
            temporary.mkdir()
            for name in ('crashes.txt','modlist.txt'):
                (temporary/name).write_text('user-file-preserve',encoding='utf-8')
            command=re.search(r'powershell -NoProfile -Command "(.*)"',(folder/'Collect-Logs.bat').read_text(encoding='utf-8')).group(1)
            setup="function Read-Host {return 'C'}; function Get-WinEvent {return @()}; "
            result=subprocess.run(['powershell.exe','-NoProfile','-Command',setup+command],env=dict(os.environ,LOCALAPPDATA=str(root),APPDATA=str(roaming),TEMP=str(temporary),TMP=str(temporary)),capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            output=re.search(r'Done: (.+)',result.stdout)
            self.assertIsNotNone(output,result.stdout)
            archive=pathlib.Path(output.group(1).strip()).resolve()
            self.assertRegex(archive.name,r'^SmoothBoot-logs-\d{8}-\d{6}-[0-9a-f]{6}\.zip$')
            # Move only the just-generated ZIP into the isolated fixture.
            archive=archive.replace(root/archive.name)
            with zipfile.ZipFile(archive) as packed:
                names={name.replace('\\','/'):name for name in packed.namelist()}
                self.assertIn('Logs/fixture.log',names)
                self.assertEqual(packed.read(names['Logs/fixture.log']),log.read_bytes())
                self.assertIn('crashes.txt',names)
                self.assertIn('SmoothBoot/config.txt',names)
                self.assertIn('Diagnostics/mod_lag_finder.log',names,'watchdog evidence missing from support ZIP')
                self.assertIn('Diagnostics/MDL.cfg',names)
                self.assertEqual(packed.read(names['Diagnostics/mod_lag_finder.log']),watchdog.read_bytes())
                self.assertEqual(packed.read(names['Diagnostics/MDL.cfg']),(mdl/'MDL.cfg').read_bytes())
            for name in ('crashes.txt','modlist.txt'):
                self.assertEqual((temporary/name).read_text(encoding='utf-8'),'user-file-preserve')
            self.assertFalse(list(temporary.glob('SmoothBoot-collect-*')),'staging directory leaked')

    def test_clean_install_creates_tools_and_config(self):
        with tempfile.TemporaryDirectory(prefix='sb-tools-') as tmp:
            root = pathlib.Path(tmp)
            runtime = start(root)
            folder = root / 'CowboyBingus/Helldivers2/SmoothBoot'
            for name in ('Collect-Logs.bat', 'README.txt', 'config.txt'):
                self.assertTrue((folder / name).is_file(), name + ' missing on first run')
            self.assertTrue(runtime.globals().HD2SmoothBoot.tools_ready)

    def test_delayed_folder_retries_without_ffi(self):
        with tempfile.TemporaryDirectory(prefix='sb-tools-') as tmp:
            root = pathlib.Path(tmp)
            clock = [0.0]
            runtime = lua51.LuaRuntime()
            runtime.globals().os.getenv = lambda key: str(root) if key == 'LOCALAPPDATA' else None
            runtime.globals().os.clock = lambda: clock[0]
            runtime.execute('CowboyBingusModLoader = {}; update = function() end')
            runtime.execute(SOURCE)
            folder = root / 'CowboyBingus/Helldivers2/SmoothBoot'
            folder.mkdir(parents=True)
            clock[0] = 11.0
            runtime.globals().update(0.016)
            self.assertTrue((folder / 'Collect-Logs.bat').is_file(), 'no retry after directory appears')

    def test_existing_user_config_is_preserved(self):
        with tempfile.TemporaryDirectory(prefix='sb-tools-') as tmp:
            root = pathlib.Path(tmp)
            folder = root / 'CowboyBingus/Helldivers2/SmoothBoot'
            folder.mkdir(parents=True)
            config = folder / 'config.txt'
            original = b'exclude=mods/test/keep\r\nwriter_release_s=23\r\n'
            config.write_bytes(original)
            start(root)
            self.assertTrue(config.read_bytes().startswith(original),'existing settings changed during migration')
            effective=re.findall(r'^exclude=(.*)$',config.read_text(encoding='utf-8'),re.M)[-1].split(',')
            self.assertEqual(set(effective),{'mods/test/keep','lte/helmet_cape_passives'})

    def test_picker_preserves_existing_exclusions(self):
        with tempfile.TemporaryDirectory(prefix='sb-tools-') as tmp:
            root = pathlib.Path(tmp)
            start(root)
            folder = root / 'CowboyBingus/Helldivers2/SmoothBoot'
            config = folder / 'config.txt'
            config.write_text('# user settings\nexclude=mods/test/keep\nwriters=mods/test/new\n', encoding='utf-8')
            logs = root / 'CowboyBingus/Helldivers2/Logs'
            (logs / 'SmoothBoot.log').write_text('chain inventory (copy fragments for exclude=/writers=): mods/test/new.lua, mods/test/third.lua\n', encoding='utf-8')
            bat = (folder / 'Collect-Logs.bat').read_text(encoding='utf-8')
            command = re.search(r'powershell -NoProfile -Command "(.*)"', bat).group(1)
            env = dict(os.environ, LOCALAPPDATA=str(root))
            for selection in ('1', '2'):
                answers = " $script:answers=@('E','" + selection + "'); $script:answer=0; function Read-Host { $r=$script:answers[$script:answer]; $script:answer++; return $r }; "
                result = subprocess.run(['powershell.exe', '-NoProfile', '-Command', answers + command], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
            actual = config.read_text(encoding='utf-8-sig')
            effective = re.findall(r'^exclude=(.*)$', actual, re.M)[-1].split(',')
            self.assertEqual(set(effective), {'mods/test/keep', 'mods/test/new', 'mods/test/third'})
            self.assertIn('writers=mods/test/new', actual)
            self.assertIn('# user settings', actual)

    def test_picker_accepts_extensionless_inventory(self):
        with tempfile.TemporaryDirectory(prefix='sb-tools-') as tmp:
            root = pathlib.Path(tmp)
            start(root)
            folder = root / 'CowboyBingus/Helldivers2/SmoothBoot'
            log = root / 'CowboyBingus/Helldivers2/Logs/SmoothBoot.log'
            log.write_text('chain inventory: mods/test/extensionless\n', encoding='utf-8')
            command = re.search(r'powershell -NoProfile -Command "(.*)"', (folder / 'Collect-Logs.bat').read_text(encoding='utf-8')).group(1)
            answers = "$script:answers=@('E','1'); $script:answer=0; function Read-Host { $r=$script:answers[$script:answer]; $script:answer++; return $r }; "
            result = subprocess.run(['powershell.exe', '-NoProfile', '-Command', answers + command], env=dict(os.environ, LOCALAPPDATA=str(root)), capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            effective=re.findall(r'^exclude=(.*)$',(folder/'config.txt').read_text(encoding='utf-8-sig'),re.M)[-1].split(',')
            self.assertEqual(set(effective),{'lte/helmet_cape_passives','mods/test/extensionless'})

    def test_picker_ignores_config_check_line(self):
        """Reported by a user on 3.0.22: the config-check warning mentioned the
        words "chain inventory", so the collector's last-match picker selected the
        warning instead of the inventory and the exclude picker found no mods.
        Logs written by that version still contain the old wording, so the picker
        must skip "config check" lines regardless of what the warning says."""
        with tempfile.TemporaryDirectory(prefix='sb-tools-') as tmp:
            root = pathlib.Path(tmp)
            start(root)
            folder = root / 'CowboyBingus/Helldivers2/SmoothBoot'
            config = folder / 'config.txt'
            config.write_text('exclude=lte/helmet_cape_passives\n', encoding='utf-8')
            logs = root / 'CowboyBingus/Helldivers2/Logs'
            logs.mkdir(parents=True, exist_ok=True)
            (logs / 'SmoothBoot.log').write_text(
                '2026-10-04T04:32:53Z first frame reached, head=mods/patpatpatrick/mod_lag_finder.lua\n'
                '2026-10-04T04:32:53Z chain inventory (copy fragments for exclude=/writers=): '
                'mods/patpatpatrick/mod_lag_finder.lua, mods/codex/player_dismember_off.lua\n'
                '2026-10-04T04:32:53Z config check: "lte/helmet_cape_passives" matched no mod on the chain '
                '(fragments must match the names in the chain inventory line)\n'
                '2026-10-04T04:32:53Z config check: writers fragment(s) not on chain (mod not installed?): k9_p\n',
                encoding='utf-8')
            command = re.search(r'powershell -NoProfile -Command "(.*)"',
                                (folder / 'Collect-Logs.bat').read_text(encoding='utf-8')).group(1)
            answers = ("$script:answers=@('E','1'); $script:answer=0; "
                       "function Read-Host { $r=$script:answers[$script:answer]; $script:answer++; return $r }; ")
            result = subprocess.run(['powershell.exe', '-NoProfile', '-Command', answers + command],
                                    env=dict(os.environ, LOCALAPPDATA=str(root)),
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertIn('mod_lag_finder', result.stdout, 'picker did not offer the real inventory entry')
            effective = re.findall(r'^exclude=(.*)$', config.read_text(encoding='utf-8-sig'), re.M)[-1].split(',')
            self.assertTrue(any('mod_lag_finder' in entry for entry in effective),
                            'the picked mod was not written to exclude= (picked the warning line instead?)')

    def test_unmatched_fragment_message_is_actionable(self):
        """The shipped LTE default is inert when that mod is absent; the log must
        say what it is and how to remove it instead of sounding like an error."""
        with tempfile.TemporaryDirectory(prefix='sb-frag-') as tmp:
            root = pathlib.Path(tmp)
            runtime = start(root)
            runtime.execute("HD2SmoothBoot.discovered_sources={'mods/test/other.lua'}")
            runtime.globals().HD2SmoothBoot.frag_check()
            log = (root / 'CowboyBingus/Helldivers2/Logs/SmoothBoot.log').read_text(encoding='utf-8')
            self.assertIn('shipped default "lte/helmet_cape_passives" is not on this chain', log)
            self.assertNotIn('chain inventory line', log)

    def test_config_check_warning_cannot_be_confused_with_inventory(self):
        """Defence in depth: the shipped warning must never contain the literal
        phrase the collector filters on, whatever the collector does."""
        warnings = re.findall(r"log\('config check:.*?'\)", SOURCE, re.S)
        self.assertTrue(warnings, 'no config-check warning found in the source')
        for warning in warnings:
            self.assertNotIn('chain inventory', warning,
                             'a config-check line still mentions the inventory line')

    def test_unspliceable_head_reports_the_real_reason(self):
        """A later wrapper can only be adopted when it keeps us in a function
        upvalue. If its previous hook lives somewhere else, reordering the mod
        list cannot help, so the log must say that instead of blaming the order
        (a user reported SmoothBoot being at the bottom already)."""
        with tempfile.TemporaryDirectory(prefix='sb-head-') as tmp:
            root = pathlib.Path(tmp)
            runtime = start(root)
            runtime.execute(r'''
                ours = update
                -- previous hook kept in a table field: no function upvalue at all
                local boxed = assert(loadstring(
                    "local box = ...; return function(...) return box.prev(...) end",
                    "@mods/test/fake_head.lua"))({prev = update})
                -- previous hook is a function, but a different one (another wrapper
                -- sits between us), so the order advice still applies
                local dummy = function() end
                local chained = assert(loadstring(
                    "local prev = ...; return function(...) return prev(...) end",
                    "@mods/test/fake_mid.lua"))(dummy)
                rawset(_G, 'update', boxed);   ours(0.016)
                rawset(_G, 'update', chained); ours(0.016)
            ''')
            log = (root / 'CowboyBingus/Helldivers2/Logs/SmoothBoot.log').read_text(encoding='utf-8')
            self.assertIn('mods/test/fake_head', log)
            self.assertIn('its previous hook is not held as a function upvalue', log,
                          'a table-held previous hook must not be blamed on the mod order')
            self.assertIn('another wrapper sits between SmoothBoot and it', log,
                          'a function-valued previous hook should still suggest the load order')


if __name__ == '__main__':
    unittest.main()

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
            self.assertEqual(config.read_bytes(), original)

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
            self.assertIn('exclude=mods/test/extensionless', (folder / 'config.txt').read_text(encoding='utf-8-sig'))


if __name__ == '__main__':
    unittest.main()

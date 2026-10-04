"""No speculative popup; known feedback exclusions survive upgrade and protect nested callbacks."""
from pathlib import Path
import tempfile
import unittest
from lupa.luajit21 import LuaRuntime
SOURCE=Path(__file__).with_name('smoothboot.lua').read_text(encoding='utf-8')
class PolicyTests(unittest.TestCase):
 def setup_runtime(self,config=''):
  tmp=tempfile.TemporaryDirectory(prefix='smooth-no-popup-');self.addCleanup(tmp.cleanup)
  home=Path(tmp.name)/'CowboyBingus/Helldivers2';(home/'SmoothBoot').mkdir(parents=True);(home/'Logs').mkdir()
  if config:(home/'SmoothBoot/config.txt').write_text(config,encoding='utf-8')
  rt=LuaRuntime();rt.globals().os.getenv=lambda key:tmp.name if key=='LOCALAPPDATA' else None
  rt.execute("CowboyBingusModLoader={};update=function() return 123 end")
  return rt,home
 def test_legacy_hud_setting_does_not_create_popup(self):
  rt,home=self.setup_runtime('hud=on\nthrottle=auto\nboot_pause_s=0\nwriters=\n')
  rt.execute("HD2Transmog={};LTE_helmet_cape_passives={};popup_calls=0;local function forbidden()popup_calls=popup_calls+1;error('unexpected popup')end;stingray={Gui={rect=forbidden},World={create_screen_gui=forbidden}}")
  rt.execute(SOURCE);rt.execute('for i=1,300 do assert(update(0.016)==123) end')
  self.assertEqual(rt.globals().popup_calls,0,'Smooth invoked a graphics API')
  self.assertFalse('GetAsyncKeyState' in SOURCE,'mouse sampler remains')
  self.assertIsNone(rt.globals().HD2SmoothBoot['_hud_draw'])
 def test_existing_list_is_merged_once_and_user_can_undo(self):
  rt,home=self.setup_runtime('exclude=my_custom_mod\n')
  rt.execute(SOURCE);cfg=home/'SmoothBoot/config.txt';text=cfg.read_text(encoding='utf-8')
  self.assertIn('exclude=my_custom_mod,lte/helmet_cape_passives',text)
  cfg.write_text('exclude=my_custom_mod\n',encoding='utf-8')
  rt=LuaRuntime()
  rt.globals().os.getenv=lambda key:str(home.parent.parent) if key=='LOCALAPPDATA' else None
  rt.execute('CowboyBingusModLoader={};update=function() end');rt.execute(SOURCE)
  self.assertEqual(cfg.read_text(encoding='utf-8'),'exclude=my_custom_mod\n')
 def test_new_install_seeds_feedback_list(self):
  rt,home=self.setup_runtime();rt.execute(SOURCE)
  text=(home/'SmoothBoot/config.txt').read_text(encoding='utf-8')
  self.assertIn('exclude=lte/helmet_cape_passives',text)
  self.assertIn('throttle=auto',text)
 def test_excluded_nested_callback_stays_at_full_rate(self):
  rt,home=self.setup_runtime('throttle=yes\nboot_s=0\ngrace_s=0\nboot_pause_s=0\nwriters=\nbusy_ms=1\ntrip_ms=1\ntrip_n=1\n')
  clock=[0.0];rt.globals().os.clock=lambda:clock[0]
  rt.globals().expensive=lambda:clock.__setitem__(0,clock[0]+0.02)
  rt.execute("calls=0;update=assert(loadstring('local previous=...;return function(...) calls=calls+1;expensive();return previous(...) end','@mods/lte/helmet_cape_passives'))(update)")
  rt.execute(SOURCE)
  for i in range(180):clock[0]+=1/60;self.assertEqual(rt.globals().update(1/60),123)
  self.assertEqual(rt.globals().calls,180)
if __name__=='__main__':unittest.main(verbosity=2)

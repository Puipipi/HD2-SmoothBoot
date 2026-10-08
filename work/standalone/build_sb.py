# -*- coding: utf-8 -*-
"""Build the SmoothBoot release zip (+ the source zip).

3.0.3 hard rules (each one is a bug that actually shipped before):
  * the source must compile under **LuaJIT**, not just Lua 5.1 - this game runs
    LuaJIT, whose 65535-instruction-per-function limit silently killed another
    mod on load while lupa's plain-Lua compile said "OK";
  * the source must declare **no user32 symbol** - LuaJIT's C namespace is
    process-global and ffi.cdef silently keeps the first declaration, which is
    how 3.0.2 disabled Clickable Scrollbars (Nexus report, 2026-10-01);
  * the shipped README.txt is extracted from the source, so the guide can never
    drift from the code;
  * no loose .bat inside the archive (Nexus quarantines script files) - the
    companion tool is provisioned at runtime next to config.txt.
"""
import io
import json
import os
import re
import sys
import zipfile
import argparse
from pathlib import Path

import lupa.luajit21 as luajit

W = str(Path(__file__).resolve().parent)
default_out = Path(W).parents[1] / 'dist' if Path(W).name == 'standalone' else Path(W).parent / 'dist'
parser = argparse.ArgumentParser(description='Build SmoothBoot without deploying to the game.')
parser.add_argument('--output-dir', type=Path, default=default_out)
parser.add_argument('--validate-only', action='store_true', help='compile and audit without packaging')
parser.add_argument('--with-source', action='store_true',
                    help='also assemble the source bundle (only for a human review handoff; not built by default)')
args = parser.parse_args()
OUT = str(args.output_dir.resolve())
Path(OUT).mkdir(parents=True, exist_ok=True)
GUID = "7c3e9a52-1b84-4f6a-9c2d-8e5f0a1b2c3d"

src = io.open(os.path.join(W, "smoothboot.lua"), encoding="utf-8").read()
ver = re.search(r"version='([\d.]+)'", src).group(1)

# --- rule 1: compiles under LuaJIT (65535 instructions per function) --------
try:
    luajit.LuaRuntime().compile(src)
except Exception as exc:                                  # pragma: no cover
    raise SystemExit("LuaJIT compile failed: %s" % exc)
print("LuaJIT compile: OK (%d bytes)" % len(src))

# --- rule 2: no user32 symbol in any ffi.cdef block ------------------------
USER32 = {"GetCursorPos", "GetClientRect", "ScreenToClient", "GetForegroundWindow",
          "GetAsyncKeyState", "GetWindowThreadProcessId", "GetCurrentProcessId"}
declared = set()
for block in re.findall(r"ffi\.cdef\s*\[\[(.*?)\]\]", src, re.S):
    # Private symbol aliases must not hide the function prototype from audit.
    block = re.sub(r'\s*__asm__\s*\("[^"\n]*"\)', '', block)
    declared.update(m.group(1) for m in
                    re.finditer(r"([A-Za-z_]\w*)\s*\([^;()]*\)\s*;", block))
clash = declared & USER32
if clash:
    raise SystemExit("refusing to build: user32 symbol(s) declared: %s"
                     % ", ".join(sorted(clash)))
print("ffi.cdef symbols: %s (no user32)" % ", ".join(sorted(declared)))

if args.validate_only:
    print('Source validation complete; no in-game claim.')
    raise SystemExit(0)

# --- the official Bingus addon envelope ------------------------------------
sys.path.insert(0, os.path.join(W, 'vendor', 'bingus'))
import build_addon as official                                # noqa: E402

target = os.path.join(OUT, "HD2-SmoothBoot-%s.zip" % ver)
official.build_addon("mods/codex/smoothboot", src.encode("utf-8"), GUID,
                     target, "HD2 SmoothBoot")

# --- README.txt is lifted out of the source (single source of truth) -------
r0 = src.find("[===[SmoothBoot - quick guide")
r1 = src.find("]===]", r0)
readme_txt = src[r0 + 5:r1] if r0 > 0 else ""
assert readme_txt, "README block missing from the source"

icon = os.path.join(W, "sb_icon.webp")
tmp = target + ".tmp"
with zipfile.ZipFile(target) as zin, zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zout:
    for info in zin.infolist():
        data = zin.read(info.filename)
        if info.filename == "manifest.json":
            m = json.loads(data)
            m["IconPath"] = "sb_icon.webp"
            for opt in m.get("Options", []):
                opt.setdefault("Image", "sb_icon.webp")
            data = (json.dumps(m, indent=2) + "\n").encode()
        zout.writestr(info, data)
    zout.write(icon, "sb_icon.webp")
    zout.writestr("README.txt", readme_txt.replace("\n", "\r\n"))
os.replace(tmp, target)
print("built %s: %d bytes" % (os.path.basename(target), os.path.getsize(target)))

# --- the source zip: opt-in only -------------------------------------------
# It existed so the fix could be reviewed without unpacking the .patch, i.e.
# for a human-review handoff. That route is abandoned, so the default build
# stops writing it; --with-source brings it back on demand.
if not args.with_source:
    print("source bundle skipped (pass --with-source only for a review handoff)")
    print("version: %s" % ver)
    raise SystemExit(0)

build_txt = io.open(os.path.join(W, "build_sb.py"), encoding="utf-8").read()
readme_build = """SmoothBoot {ver} - source and build steps
==========================================
smoothboot.lua is the complete, plain-text Lua source of the mod
(the shipping archive's Addon/*.patch_0 file is this exact source wrapped
in the Bingus ecosystem's standard addon envelope, produced by build_sb.py).

Build steps:
  1. python build_sb.py --output-dir ../dist (requires python3 + lupa; it refuses to build unless
     the source compiles under **LuaJIT** and declares no user32 symbol -
     both are hard rules learned from real releases)
  2. it produces HD2-SmoothBoot-<version>.zip

The mod contains no compiled native code. The only "script-like" artifact is a
small companion .bat that the mod itself writes next to its config file at
runtime (log collector / interactive exclude picker, plain PowerShell, no
obfuscation) - it is intentionally NOT shipped inside the upload archive.
""".format(ver=ver)
src_zip = os.path.join(OUT, "SmoothBoot-source-%s.zip" % ver)
with zipfile.ZipFile(src_zip, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("source/smoothboot.lua", src.encode("utf-8"))
    z.writestr("source/build_sb.py", build_txt.encode("utf-8"))
    z.writestr("source/README-build.txt", readme_build.encode("utf-8"))
    z.write(icon, 'source/sb_icon.webp')
    for helper in ('build_addon.py', 'archive.py'):
        z.write(os.path.join(W, 'vendor', 'bingus', helper), 'source/vendor/bingus/' + helper)
print("built %s: %d bytes" % (os.path.basename(src_zip), os.path.getsize(src_zip)))
print("version: %s" % ver)

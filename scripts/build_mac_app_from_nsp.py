#!/usr/bin/env python3
# NSPs -> a self-contained native macOS app for Apple silicon, locally ad-hoc signed.
# Run in Spyder (F5, settings below) or a terminal (arguments override settings).
# Shares NSP extraction, build-ID checks, rewriting and shader splitting with the IPA
# script. All game files and caches stay in <NSP folder>/<title ID>_build/.
# Mac packaging follows https://github.com/jhaizhou-ops/d2r-mobile (mac_app.sh / app_mac.m).
import argparse
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path

# ---- Settings ----
NSP_DIR = ''                            # folder holding one game's NSPs (empty = ask)
PROD_KEYS = ''                          # path of prod.keys (empty = ask; key values are never printed)
PACKAGE = ''                            # empty = the game profile's package
OUT_APP = ''                            # empty = <profile's IPA stem>.app beside the NSPs
APP_NAME = ''                           # empty = the game name from the base NSP
BUNDLE_ID = ''                          # empty = org.nxnative.<base title ID in lowercase>
KEEP_EXTRACTED = False                  # retain extract/ for future builds
DM_ENV_FILE = ''                        # optional KEY=VALUE file bundled for diagnostics
CONTROLLER_UI = ''                      # optional prepared local DualSense UI pack

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_ipa_from_nsp as nsp


def parse_args(argv):
    ap = argparse.ArgumentParser(description='Build a native Apple silicon .app from NSPs (macOS 26+, local ad-hoc signature).')
    ap.add_argument('nsp_dir', nargs='?', default=NSP_DIR, help="Folder holding one game's base, update and optional DLC NSPs")
    ap.add_argument('-k', '--keys', default=PROD_KEYS, help='Path of prod.keys')
    ap.add_argument('-p', '--package', default=PACKAGE, help="Version to pack (default: the game profile's package)")
    ap.add_argument('-o', '--out', default=OUT_APP, help='Output .app (default: beside the NSPs)')
    ap.add_argument('--app-name', default=APP_NAME, help='Display name (default: from the base NSP)')
    ap.add_argument('--bundle-id', default=BUNDLE_ID, help='Bundle ID; also identifies the save and log folders')
    ap.add_argument('--keep-extracted', action='store_true', default=KEEP_EXTRACTED, help='Keep extracted game files after packaging')
    ap.add_argument('--env-file', default=DM_ENV_FILE, help='Diagnostic switches, one KEY=VALUE per line')
    ap.add_argument('--controller-ui', default=CONTROLLER_UI, help='Install a prepared DualSense UI pack beside the app in patches/dualsense-ui')
    return ap.parse_args(argv)


def check_prereqs(env, xlate):
    if sys.platform != 'darwin' or platform.machine() != 'arm64':
        raise nsp.BuildError('Build on an Apple silicon Mac, using an arm64 Python.')
    if int(platform.mac_ver()[0].split('.')[0]) < 26:
        raise nsp.BuildError('The graphics backend requires macOS 26 or later (Metal 4).')
    missing = [m for m in ('lz4.block', 'capstone', 'fontTools') if not nsp._importable(m)]
    if missing: raise nsp.BuildError(f'{sys.executable} needs: {", ".join(missing)} (pip install lz4 capstone fonttools)')
    tools = ('xcrun', 'clang', 'make', 'dotnet', 'zstd', 'spirv-cross', 'codesign', 'sips', 'iconutil', 'lipo', 'plutil')
    missing = [t for t in tools if not shutil.which(t, path=env['PATH'])]
    if missing: raise nsp.BuildError('Tools not found: ' + ', '.join(missing))
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], env=env, text=True).strip()
    if int(sdk.split('.')[0]) < 26: raise nsp.BuildError('Xcode with a macOS 26 or newer SDK is required.')
    if not xlate.is_file(): raise nsp.BuildError(f'Shader translator missing: {xlate}')


def main(args=None):
    args = args or parse_args([])
    repo = nsp.find_repo(Path(__file__).resolve())
    sys.path.insert(0, str(repo / 'dm/games')); import game as gamemod
    sys.path.insert(0, str(repo / 'dm/tools')); import nacp
    sys.path.insert(0, str(repo / 'dm/macos/tools')); import package_app
    nsp.nacp = nacp   # The shared unknown-title survey reads the extracted control data.
    nsp_dir = Path(args.nsp_dir or nsp.ask('NSP folder: ', 'the NSP folder')).expanduser().resolve()
    keys = Path(args.keys or nsp.ask('prod.keys path: ', 'prod.keys (-k)')).expanduser().resolve()
    if not nsp_dir.is_dir(): raise nsp.BuildError(f'Not a folder: {nsp_dir}')
    if not keys.is_file(): raise nsp.BuildError(f'File not found: {keys}')
    env = dict(os.environ, PATH=os.pathsep.join(nsp.TOOL_PATHS + [os.environ.get('PATH', '/usr/bin:/bin:/usr/sbin:/sbin')]))
    app_id, fam = nsp.scan_nsps(nsp_dir)
    g = gamemod.by_title(app_id)
    if g is None:
        missing = [m for m in ('lz4.block', 'capstone') if not nsp._importable(m)]
        if missing: raise nsp.BuildError('Missing Python modules: ' + ', '.join(missing))
        if not shutil.which('dotnet', path=env['PATH']): raise nsp.BuildError('.NET SDK 10 is required.')
        return nsp.survey(nsp_dir, app_id, fam, keys, repo, sys.executable, env)
    pkg = args.package or g.get('package')
    if pkg not in g.builds(): raise nsp.BuildError(f'Package must be a registered version: {", ".join(g.builds())}')
    need = g.words('shader_versions'); versions = need + ([pkg] if pkg not in need else [])
    out = Path(args.out).expanduser().resolve() if args.out else nsp_dir / Path(g.get('ipa')).with_suffix('.app')
    work = nsp_dir / f'{g.id}_build'; logs = work / 'logs/macos'; ex = work / 'extract'
    if out.suffix != '.app': raise nsp.BuildError('The output path must end in .app')
    if out.is_relative_to(repo) or out.is_relative_to(ex):
        raise nsp.BuildError('Put the output app outside the repository and the extraction folder.')
    env_file = Path(args.env_file).expanduser().resolve() if args.env_file else None
    if env_file and not env_file.is_file(): raise nsp.BuildError(f'Environment file not found: {env_file}')
    xlate = repo / 'dm/gfx/tools/dmsh_xlate_bin/dmsh_xlate'
    check_prereqs(env, xlate)
    # Keep temporary jobs and the host compiler's module cache on the game's drive.
    env.update(DM_GAME=g.id, DM_ROOT=str(work), WORK=str(work / 'tmp'), TMPDIR=str(work / 'tmp'),
               CLANG_MODULE_CACHE_PATH=str(work / 'tools/clang_modules'),
               MACOSX_DEPLOYMENT_TARGET='26.0', FONT_PY=sys.executable)
    env.pop('IOSOUT', None)   # A Mac-only run must not inherit an iOS build request.
    picks = nsp.pick_nsps(fam, nsp.nsp_versions(fam, g.builds()), versions)
    gb = sum({p.stat().st_size for b, u in picks.values() for p in (b, u) if p}) / 2**30 + 6
    if nsp.free_gb(nsp_dir) < gb and not all((ex / v).exists() for v in versions):
        raise nsp.BuildError(f'Less than {gb:.0f} GB free on the NSP volume.')
    ex.mkdir(parents=True, exist_ok=True); (work / 'tmp').mkdir(exist_ok=True)
    nsp.say(f'Game profile: {g.id}; output app: {out}')
    nx = nsp.build_nx_extract(repo, work, logs, env)
    dirs, clone = {}, None
    for ver in versions:
        base, update = picks[ver]
        dirs[ver] = nsp.extract(nx, keys, ex, ver, base, update, clone, logs, g)
        if update is None and clone is None and nsp.can_clone(ex): clone = dirs[ver] / 'RomFS'
    mismatches = [f'{v}: {item}' for v in versions for item in nsp.build_mismatch(dirs[v], v, g)]
    if mismatches: raise nsp.BuildError('The extracted modules do not match the registered builds: ' + '; '.join(mismatches))
    game = dirs[pkg]
    aoc = nsp.extract_aoc(nx, keys, repo, work, app_id, fam, logs)
    base = next((dirs[v] for v in versions if picks[v][1] is None), dirs[versions[0]])
    app_name = args.app_name or nacp.name(base / 'control.nacp')
    if not app_name: raise nsp.BuildError('Cannot read the game name; re-extract or use --app-name.')
    bundle_id = args.bundle_id or f'org.nxnative.{app_id:016x}'
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle_id):
        raise nsp.BuildError('Use a reverse-DNS bundle ID (letters, digits, hyphens and dots).')
    patched = work / f'patched_{pkg}'
    env['MAIN'] = str(game / 'ExeFS/main')
    nsp.rewrite(sys.executable, repo, game / 'ExeFS', patched, env, logs, g)
    nsp.chain_header(sys.executable, repo, env, logs)
    if g.get('shader_glslc_capture', 'off') == 'on':
        nsp.capture_glslc(repo, {v: dirs[v] for v in need}, pkg, patched, work, env, logs, g)
    sh = work / 'shader'
    package_key = nsp.split_shaders(sys.executable, repo, [dirs[v] / 'RomFS' for v in need],
                      [dirs[v] / 'ExeFS/main' for v in need], sh / 'pkg', env, logs, g)
    nsp.build_shaders(sys.executable, repo, sh, xlate, env, logs, g, package_key, with_ios=False)
    icon = next((d / 'icon.jpg' for d in (game, base) if (d / 'icon.jpg').is_file()), None)
    if not icon: nsp.say('【红】No extracted game icon; the app will use the generic icon. Re-extract to restore it.')
    nsp.say('Packaging the Mac app (game files, macOS shaders, fonts and local signature)')
    try:
        minimum = package_app.build_app(repo, work, out, g, patched, game / 'RomFS', sh / 'cache',
                                        app_name, bundle_id, g.builds()[pkg]['display'], icon, aoc,
                                        env_file, env, nsp.run, nsp.can_clone,
                                        controller_ui=getattr(args, 'controller_ui', None))
    except package_app.PackageError as e: raise nsp.BuildError(str(e)) from e
    nsp.rmtree(work / 'tmp')
    if not args.keep_extracted: nsp.rmtree(ex)
    nsp.say(f'Done: {out} (Apple silicon, macOS {minimum}+)')
    nsp.say(f'Saves: ~/Library/Application Support/{bundle_id}/save; log: ~/Library/Logs/{bundle_id}/log.txt')


def cli(argv):
    try: main(parse_args(argv))
    except (nsp.BuildError, OSError, ValueError, subprocess.CalledProcessError) as e:
        print(f'【红】{e}', flush=True); return 1
    except KeyboardInterrupt:
        print('【红】Interrupted', flush=True); return 130
    return 0


if __name__ == '__main__':
    code = cli(sys.argv[1:])
    if not nsp.in_ipython(): sys.exit(code)

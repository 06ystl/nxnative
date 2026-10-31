#!/usr/bin/env python3
# Build macOS .app, unsigned iOS .ipa, or both from one game's NSPs.
# Shared extraction, rewriting and shader processing run once; platform packaging
# follows in sequence. Extraction is cleaned only after every selected target succeeds.
# Run from a terminal (-h for options) or edit Settings and press F5 in Spyder.
import argparse
import getpass
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# ---- Settings ----
NSP_DIR = ''                            # one game's base, update and optional DLC NSPs (empty = ask)
PROD_KEYS = ''                          # path of prod.keys (empty = ask)
TARGET = 'both'                         # 'macos', 'ios', or 'both'
PACKAGE = ''                            # empty = the game profile's package
OUT_DIR = ''                            # empty = beside the NSPs
OUT_APP = ''                            # optional full .app path; overrides OUT_DIR for macOS
OUT_IPA = ''                            # optional full .ipa path; overrides OUT_DIR for iOS
APP_NAME = ''                           # empty = the name in the base NSP
BUNDLE_ID = ''                          # empty = org.nxnative.<base title ID in lowercase>
KEEP_EXTRACTED = False                  # retain extraction after a successful build
DM_ENV_FILE = ''                        # optional diagnostic switches (one KEY=VALUE per line)
CONTROLLER_UI = ''                      # optional local PS5 UI pack for macOS

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_ipa_from_nsp as nsp
import build_mac_app_from_nsp as mac


def parse_args(argv):
    ap = argparse.ArgumentParser(description='Build a native Mac app and/or unsigned IPA from one shared NSP extraction.')
    ap.add_argument('nsp_dir', nargs='?', default=NSP_DIR, help="Folder holding one game's NSPs")
    ap.add_argument('-k', '--keys', default=PROD_KEYS, help='Path of prod.keys')
    ap.add_argument('--target', choices=('macos', 'ios', 'both'), default=TARGET, help='Output platforms (default: both)')
    ap.add_argument('-p', '--package', default=PACKAGE, help="Version to pack (default: the profile's package)")
    ap.add_argument('-o', '--out-dir', default=OUT_DIR, help='Output folder for the selected platforms (default: NSP folder)')
    ap.add_argument('--out-app', default=OUT_APP, help='Full output .app path (overrides --out-dir for macOS)')
    ap.add_argument('--out-ipa', default=OUT_IPA, help='Full output .ipa path (overrides --out-dir for iOS)')
    ap.add_argument('--app-name', default=APP_NAME, help='Display name for both apps (default: from the base NSP)')
    ap.add_argument('--bundle-id', default=BUNDLE_ID, help='Bundle ID for both apps')
    ap.add_argument('--keep-extracted', action='store_true', default=KEEP_EXTRACTED, help='Keep extracted game files on success')
    ap.add_argument('--env-file', default=DM_ENV_FILE, help='Diagnostic switches bundled in each selected app')
    ap.add_argument('--controller-ui', default=CONTROLLER_UI, help='Install a prepared DualSense UI pack beside the Mac app in patches/dualsense-ui')
    return ap.parse_args(argv)


def package_ios(repo, work, out, g, patched, romfs, ios, name, bundle_id, icon, aoc, env_file, env, logs):
    if nsp.free_gb(out.parent) < 5: raise nsp.BuildError(f'Less than 5 GB free on the output volume: {out.parent}')
    out.parent.mkdir(parents=True, exist_ok=True)
    ipa_env = dict(env, GAME=g.id, W=str(work / 'ipa'), PATCHED=str(patched), ROMFS=str(romfs),
                   MSL_IOS=str(ios), FONT_PY=sys.executable, DM_DISPLAY_NAME=name,
                   DM_BUNDLE_ID=bundle_id, AOC=str(aoc or ''))
    if icon: ipa_env['DM_ICON'] = str(icon)
    if env_file: ipa_env['DM_ENV_FILE'] = str(env_file)
    nsp.run(['bash', repo / 'dm/ios/tools/build_ipa.sh', out], logs / 'build_ipa.log', env=ipa_env)
    if not out.is_file(): raise nsp.BuildError(f'No IPA at {out}')


def main(args=None):
    args = args or parse_args([])
    if args.target not in ('macos', 'ios', 'both'): raise nsp.BuildError('TARGET must be macos, ios, or both.')
    targets = ('macos', 'ios') if args.target == 'both' else (args.target,)
    repo = nsp.find_repo(Path(__file__).resolve())
    sys.path.insert(0, str(repo / 'dm/games')); import game as gamemod
    sys.path.insert(0, str(repo / 'dm/tools')); import nacp
    sys.path.insert(0, str(repo / 'dm/macos/tools')); import package_app
    nsp.nacp = nacp
    nsp_dir = Path(args.nsp_dir or nsp.ask('NSP folder: ', 'the NSP folder')).expanduser().resolve()
    keys = Path(args.keys or nsp.ask('prod.keys path: ', 'prod.keys (-k)')).expanduser().resolve()
    if not nsp_dir.is_dir(): raise nsp.BuildError(f'Not a folder: {nsp_dir}')
    if not keys.is_file(): raise nsp.BuildError(f'File not found: {keys}')
    env = dict(os.environ, PATH=os.pathsep.join(nsp.TOOL_PATHS + [os.environ.get('PATH', '/usr/bin:/bin:/usr/sbin:/sbin')]))
    env.setdefault('USER', getpass.getuser())
    app_id, fam = nsp.scan_nsps(nsp_dir)
    g = gamemod.by_title(app_id)
    if g is None:
        missing = [m for m in ('lz4.block', 'capstone') if not nsp._importable(m)]
        if missing: raise nsp.BuildError('Missing Python modules: ' + ', '.join(missing))
        if not shutil.which('dotnet', path=env['PATH']): raise nsp.BuildError('.NET SDK 10 is required.')
        return nsp.survey(nsp_dir, app_id, fam, keys, repo, sys.executable, env)
    builds, need = g.builds(), g.words('shader_versions')
    pkg = args.package or g.get('package')
    if pkg not in builds: raise nsp.BuildError(f'Package must be a registered version: {", ".join(builds)}')
    versions = need + ([pkg] if pkg not in need else [])
    work = nsp_dir / f'{g.id}_build'; ex = work / 'extract'; logs = work / 'logs/shared'
    out_dir = Path(args.out_dir).expanduser().resolve() if args.out_dir else nsp_dir
    outputs = {}
    for target, override, suffix in (('macos', args.out_app, '.app'), ('ios', args.out_ipa, '.ipa')):
        if target not in targets: continue
        out = Path(override).expanduser().resolve() if override else out_dir / Path(g.get('ipa')).with_suffix(suffix)
        if out.suffix != suffix: raise nsp.BuildError(f'{target} output must end in {suffix}: {out}')
        if any(out.is_relative_to(d) for d in (repo, ex, work / 'tmp')):
            raise nsp.BuildError('Put output apps outside the repository, extraction and temporary folders.')
        outputs[target] = out
    env_file = Path(args.env_file).expanduser().resolve() if args.env_file else None
    if env_file and not env_file.is_file(): raise nsp.BuildError(f'Environment file not found: {env_file}')
    bundle_id = args.bundle_id or f'org.nxnative.{app_id:016x}'
    if 'macos' in targets and not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle_id):
        raise nsp.BuildError('Use a reverse-DNS bundle ID (letters, digits, hyphens and dots).')
    xlate = repo / 'dm/gfx/tools/dmsh_xlate_bin/dmsh_xlate'
    # Validate only the selected platforms, before starting expensive shared work.
    if 'macos' in targets: mac.check_prereqs(env, xlate)
    if 'ios' in targets: nsp.check_prereqs(env, xlate)
    env.update(DM_GAME=g.id, DM_ROOT=str(work), WORK=str(work / 'tmp'), FONT_PY=sys.executable)
    env.pop('IOSOUT', None)
    if 'macos' in targets:
        env.update(MACOSX_DEPLOYMENT_TARGET='26.0', CLANG_MODULE_CACHE_PATH=str(work / 'tools/clang_modules'))
    picks = nsp.pick_nsps(fam, nsp.nsp_versions(fam, g.builds()), versions)
    gb = sum({p.stat().st_size for b, u in picks.values() for p in (b, u) if p}) / 2**30 + 6
    if nsp.free_gb(nsp_dir) < gb and not all((ex / v).exists() for v in versions):
        raise nsp.BuildError(f'Less than {gb:.0f} GB free on the NSP volume.')
    ex.mkdir(parents=True, exist_ok=True); (work / 'tmp').mkdir(exist_ok=True)
    nsp.say(f'Game profile: {g.id}; targets: {", ".join(targets)}; shared work: {work}')
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
    name = args.app_name or nacp.name(base / 'control.nacp')
    if not name: raise nsp.BuildError('Cannot read the game name; re-extract or use --app-name.')
    icon = next((d / 'icon.jpg' for d in (game, base) if (d / 'icon.jpg').is_file()), None)
    if not icon: nsp.say('【红】No extracted game icon; the apps will use a generic icon. Re-extract to restore it.')
    patched = work / f'patched_{pkg}'
    env['MAIN'] = str(game / 'ExeFS/main')
    nsp.rewrite(sys.executable, repo, game / 'ExeFS', patched, env, logs, g)
    nsp.chain_header(sys.executable, repo, env, logs)
    if g.get('shader_glslc_capture', 'off') == 'on':
        nsp.capture_glslc(repo, {v: dirs[v] for v in need}, pkg, patched, work, env, logs, g)
    sh = work / 'shader'
    package_key = nsp.split_shaders(sys.executable, repo, [dirs[v] / 'RomFS' for v in need],
                      [dirs[v] / 'ExeFS/main' for v in need], sh / 'pkg', env, logs, g)
    ios = None
    if 'ios' in targets:
        # One dmsh_build invocation produces the Mac cache and, via IOSOUT, iOS libraries.
        ios = nsp.build_shaders(sys.executable, repo, sh, xlate, env, logs, g, package_key)
    else:
        nsp.build_shaders(sys.executable, repo, sh, xlate, env, logs, g, package_key, with_ios=False)
    completed, failures = [], []
    for target in targets:
        out = outputs[target]
        nsp.say(f'Packaging {target}: {out}')
        try:
            if target == 'macos':
                minimum = package_app.build_app(repo, work, out, g, patched, game / 'RomFS', sh / 'cache',
                                                name, bundle_id, builds[pkg]['display'], icon, aoc,
                                                env_file, env, nsp.run, nsp.can_clone,
                                                controller_ui=getattr(args, 'controller_ui', None))
                nsp.say(f'Mac app ready (macOS {minimum}+): {out}')
            else:
                package_ios(repo, work, out, g, patched, game / 'RomFS', ios, name, bundle_id,
                            icon, aoc, env_file, env, logs)
                nsp.say(f'Unsigned IPA ready: {out}')
            completed.append(out)
        except (nsp.BuildError, package_app.PackageError, OSError, ValueError, subprocess.CalledProcessError) as e:
            failures.append(f'{target}: {e}')
            nsp.say(f'【红】{target} packaging failed: {e}')
    if failures:
        ready = '; '.join(map(str, completed)) or 'none'
        raise nsp.BuildError(f'Packaging failed: {"; ".join(failures)}. Completed outputs: {ready}. '
                             f'Extraction and temporary files retained in {work}; rerun with --target for the failed platform.')
    nsp.rmtree(work / 'tmp')
    if not args.keep_extracted: nsp.rmtree(ex)
    nsp.say('Done: ' + '; '.join(map(str, completed)))


def cli(argv):
    try: main(parse_args(argv))
    except (nsp.BuildError, OSError, ValueError, subprocess.CalledProcessError) as e:
        print(f'【红】{e}', flush=True); return 1
    except KeyboardInterrupt:
        print('【红】Interrupted; intermediate files retained.', flush=True); return 130
    return 0


if __name__ == '__main__':
    code = cli(sys.argv[1:])
    if not nsp.in_ipython(): sys.exit(code)

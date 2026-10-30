"""Package a self-contained Apple silicon app, using d2r-mobile's mac_app.sh layout.

Called by scripts/build_mac_app_from_nsp.py; all game-derived files stay on the
game's drive. No Xcode project or developer signing identity is needed.
"""
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'gfx/tools'))
import dmsh_chain


class PackageError(Exception):
    pass


def version_tuple(value):
    return tuple((list(map(int, value.split('.'))) + [0, 0])[:3])


def shader_inventory(msl, chain):
    """Read actual AIR targets, including cached libraries built with newer Xcode."""
    folder = msl / f'b-{chain}'
    libraries = sorted(folder.glob('*.metallib'))
    if not any(p.name.endswith('_b.metallib') for p in libraries):
        raise PackageError(f'No macOS shader libraries in {folder}')
    minimum = (26, 0, 0)
    for lib in libraries:
        data = lib.read_bytes()
        targets = re.findall(rb'air64(?:_v\d+)?-apple-macosx(\d+\.\d+(?:\.\d+)?)', data)
        if data[:4] != b'MTLB' or not targets:
            raise PackageError(f'Cannot read a macOS AIR target from {lib}; rebuild the macOS shader cache')
        minimum = max(minimum, *(version_tuple(t.decode()) for t in targets))
        if lib.name.endswith('_b.metallib') and not lib.with_suffix('.json').is_file():
            raise PackageError(f'Missing shader reflection: {lib.with_suffix(".json")}')
    return libraries, '.'.join(map(str, minimum if minimum[2] else minimum[:2]))



def validate_shader_inputs(msl, chain, g):
    folder = msl / f'b-{chain}'
    stamp = dmsh_chain.read_stamp(folder)
    if stamp.get('game') != g.id or stamp.get('inputs') != dmsh_chain.inputs(g):
        raise PackageError(f'Shader inputs in {folder} do not match game profile {g.id}; rebuild its shaders')
    expected = dmsh_chain.table_head(folder)
    for name in ('c1_full.tsv', 'cb_extent.tsv'):
        table = g.table(name)
        head = table.read_text().partition('\n')[0] if table.is_file() else ''
        if not head.startswith(expected + ' '):
            raise PackageError(f'{table} does not name the shader library inputs; rebuild its shader tables')


def build_app(repo, work, out, g, patched, romfs, msl, app_name, bundle_id,
              display_version, icon, aoc, env_file, env, run, can_clone):
    chain = re.search(r'^#define DMSH_CHAIN "([^"]+)"', (repo / 'dm/gfx/nvn/dmsh_chain.h').read_text(), re.M).group(1)
    libraries, minimum = shader_inventory(msl, chain)
    validate_shader_inputs(msl, chain, g)
    logs = work / 'logs/macos'
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        info = out / 'Contents/Info.plist'
        if out.is_symlink() or not info.is_file(): raise PackageError(f'Refusing to replace an unrelated path: {out}')
        with info.open('rb') as f: old = plistlib.load(f)
        if old.get('CFBundleIdentifier') != bundle_id: raise PackageError(f'The existing app has another bundle ID: {out}')
    run(['make', '-C', repo / 'dm/host', f'GAME={g.id}', f'MACOS_MIN={minimum}', 'dmhost_app'],
        logs / 'host_build.log', env=env)
    host = repo / 'dm/host/dmhost_app'
    archs = subprocess.check_output(['lipo', '-archs', host], env=env, text=True).strip()
    if archs != 'arm64': raise PackageError(f'Expected an arm64 host, got {archs}')
    # Build beside the destination: only a complete, signed app replaces an earlier build.
    with tempfile.TemporaryDirectory(prefix='.nxnative-mac-', dir=out.parent) as staging:
        app = Path(staging) / out.name
        contents = app / 'Contents'; res = contents / 'Resources'; dm = res / 'dm'
        (contents / 'MacOS').mkdir(parents=True); dm.mkdir(parents=True)
        shutil.copy2(host, contents / 'MacOS/nxnative')
        for module in g.words('modules'):
            for suffix in ('patched.bin', 'fixups.tsv', 'gates.tsv', 'cuts.tsv', 'obs.tsv'):
                shutil.copy2(patched / f'{module}.{suffix}', dm)
        for name in ('shader_map.tsv', 'c1_full.tsv', 'cb_extent.tsv', 'pso_manifest.tsv'):
            shutil.copy2(g.table(name), dm)
        if env_file: shutil.copy2(env_file, dm / 'env.txt')
        shader_dst = res / 'msl' / f'b-{chain}'; shader_dst.mkdir(parents=True)
        shutil.copy2(msl / f'b-{chain}' / 'inputs.tsv', shader_dst)
        for lib in libraries:
            shutil.copy2(lib, shader_dst)
            if lib.with_suffix('.json').is_file(): shutil.copy2(lib.with_suffix('.json'), shader_dst)
        font = dm / 'font'; font.mkdir()
        standard = Path(env.get('STD_FONT', '/System/Library/Fonts/Supplemental/Arial Unicode.ttf'))
        shutil.copyfile(standard, font / 'standard.ttf')   # Do not copy macOS's restricted system-file flags.
        run([env['FONT_PY'], repo / 'dm/tools/make_ext_font.py', font / 'nintendo_ext.ttf'], logs / 'font.log', env=env)
        # APFS clones keep an app self-contained without duplicating unchanged resource blocks.
        clone = can_clone(res)
        required = sum(p.stat().st_size for root in (romfs, aoc) if root and
                       not (clone and root.stat().st_dev == res.stat().st_dev)
                       for p in root.rglob('*') if p.is_file())
        if shutil.disk_usage(res).free < required + 512 * 2**20:
            raise PackageError(f'Not enough free space to copy game resources to {out.parent}')
        for source, name in ((romfs, 'romfs'), (aoc, 'aoc')):
            if source:
                flag = '-cR' if clone and source.stat().st_dev == res.stat().st_dev else '-R'
                run(['cp', flag, source, res / name], logs / f'{name}_copy.log', env=env)
        info = dict(CFBundleName=app_name, CFBundleDisplayName=app_name,
                    CFBundleIdentifier=bundle_id, CFBundleExecutable='nxnative',
                    CFBundlePackageType='APPL', CFBundleShortVersionString=display_version,
                    CFBundleVersion='1', LSMinimumSystemVersion=minimum,
                    LSArchitecturePriority=['arm64'], LSRequiresNativeExecution=True,
                    NSHighResolutionCapable=True, LSSupportsGameMode=True,
                    NSLocalNetworkUsageDescription='Connect to your phone for gyroscope and accelerometer input.',
                    GCSupportsControllerUserInteraction=True,
                    GCSupportedGameControllers=[{'ProfileName': 'ExtendedGamepad'}],
                    LSApplicationCategoryType=g.get('app_category'))
        if icon:
            iconset = Path(staging) / 'AppIcon.iconset'; iconset.mkdir()
            for size in (16, 32, 128, 256, 512):
                for scale in (1, 2):
                    filename = f'icon_{size}x{size}' + ('@2x' if scale == 2 else '') + '.png'
                    run(['sips', '-s', 'format', 'png', '-z', str(size * scale), str(size * scale),
                         icon, '--out', iconset / filename], logs / f'icon_{size}_{scale}.log', env=env)
            run(['iconutil', '-c', 'icns', iconset, '-o', res / 'AppIcon.icns'], logs / 'icon.log', env=env)
            info['CFBundleIconFile'] = 'AppIcon.icns'
        with (contents / 'Info.plist').open('wb') as f: plistlib.dump(info, f)
        (contents / 'PkgInfo').write_bytes(b'APPL????')
        run(['plutil', '-lint', contents / 'Info.plist'], logs / 'plist.log', env=env)
        # A local ad-hoc signature, without hardened runtime: the Mac loader seals
        # rewritten guest code with mprotect(RX) after copying it into anonymous pages.
        run(['codesign', '--force', '--sign', '-', app], logs / 'codesign.log', env=env)
        run(['codesign', '--verify', '--strict', app], logs / 'codesign_verify.log', env=env)
        previous = Path(staging) / 'previous.app'
        if out.exists(): out.rename(previous)
        try: app.rename(out)
        except OSError:
            if previous.exists(): previous.rename(out)
            raise
    return minimum

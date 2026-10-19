#!/usr/bin/env python3
"""Build an unsigned MotionSource repair and its complete source archive."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import zipfile

# Spyder F5 settings; command-line arguments override these values.
OUT_DIR = ''  # A folder on your game/development drive; never inside this repo.

SOURCES = {
    'source': ('https://github.com/shiftinv/MotionSourceiOS.git', '65d402873906bc44fe2e627089a6a0fe4c4ef077'),
    'socket': ('https://github.com/robbiehanson/CocoaAsyncSocket.git', '4b88ce116b0ecbf974776c6a5f027c1bb90e0fd4'),
}


def run(args, cwd, env):
    subprocess.run([str(a) for a in args], cwd=cwd, env=env, check=True)


def build(folder):
    repo = Path(__file__).resolve().parents[1]
    folder = folder.expanduser().resolve()
    if folder.is_relative_to(repo):
        raise ValueError('Choose an output folder outside the repository.')
    folder.mkdir(parents=True, exist_ok=True)
    work = folder / 'build'
    if work.exists():
        if not (work / '.motionsource-nx').is_file():
            raise ValueError(f'Refusing to replace an unrelated folder: {work}')
        shutil.rmtree(work)
    work.mkdir()
    (work / '.motionsource-nx').touch()
    env = dict(os.environ, TMPDIR=str(work / 'tmp'), CLANG_MODULE_CACHE_PATH=str(work / 'clang-cache'))
    (work / 'tmp').mkdir()
    for name, (url, revision) in SOURCES.items():
        cache = folder / f'upstream-{name}'
        if not cache.exists():
            run(['git', 'clone', '--no-checkout', url, cache], folder, env)
        run(['git', '-C', cache, 'archive', '--format=tar', '-o', work / f'{name}.tar', revision], folder, env)
        target = work / name
        target.mkdir()
        run(['tar', '-xf', work / f'{name}.tar', '-C', target], work, env)
        (work / f'{name}.tar').unlink()
    patch = repo / 'dm/motion_source/motionsource.patch'
    run(['git', 'apply', '--directory=source', patch], work, env)
    support = repo / 'dm/motion_source'
    for path in support.iterdir():
        if path.suffix in ('.h', '.m'):
            shutil.copy2(path, work / 'source/MotionSourceiOS' / path.name)
    headers = work / 'include'
    headers.mkdir()
    (headers / 'CocoaAsyncSocket').symlink_to(work / 'socket/Source/GCD', target_is_directory=True)
    shutil.copy2(repo / 'dm/motion_source/project.yml', work / 'project.yml')
    shutil.copytree(repo / 'dm/motion_source/tests', work / 'tests')
    info = plistlib.loads((work / 'source/MotionSourceiOS/Info.plist').read_bytes())
    info.update(CFBundleDisplayName='MotionSource NX', CFBundleShortVersionString='1.1.3', CFBundleVersion='3',
                NSMotionUsageDescription='Use the phone gyroscope and accelerometer as a game controller.',
                UIRequiresFullScreen=True,
                NSLocalNetworkUsageDescription='Send phone motion to your Mac game on the local network.')
    info.pop('UIMainStoryboardFile', None)
    info['UIApplicationSceneManifest'] = {
        'UIApplicationSupportsMultipleScenes': False,
        'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [{
            'UISceneConfigurationName': 'Default Configuration',
            'UISceneDelegateClassName': 'MotionSceneDelegate',
            'UISceneStoryboardFile': 'Main',
        }]},
    }
    (work / 'Info.plist').write_bytes(plistlib.dumps(info))
    run(['xcodegen', 'generate'], work, env)
    with (folder / 'build.log').open('w') as log:
        subprocess.run(['xcodebuild', '-project', 'MotionSourceNX.xcodeproj', '-scheme', 'MotionSourceNX',
                        '-configuration', 'Release', '-sdk', 'iphoneos', '-destination', 'generic/platform=iOS',
                        '-derivedDataPath', str(work / 'dd'), 'CODE_SIGNING_ALLOWED=NO',
                        'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_IDENTITY=', 'build'],
                       cwd=work, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    app = work / 'dd/Build/Products/Release-iphoneos/MotionSourceNX.app'
    ipa = folder / 'MotionSourceNX.ipa'
    with zipfile.ZipFile(ipa, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path in app.rglob('*'):
            if path.is_file():
                archive.write(path, str(Path('Payload/MotionSourceNX.app') / path.relative_to(app)))
    source_zip = folder / 'MotionSourceNX-source.zip'
    with zipfile.ZipFile(source_zip, 'w', zipfile.ZIP_DEFLATED) as archive:
        for name in (*SOURCES, 'tests'):
            for path in (work / name).rglob('*'):
                if path.is_file(): archive.write(path, str(path.relative_to(work)))
        archive.write(work / 'socket/Source/GCD/GCDAsyncUdpSocket.h', 'include/CocoaAsyncSocket/GCDAsyncUdpSocket.h')
        for path in (work / 'Info.plist', work / 'project.yml', patch, repo / 'dm/motion_source/README.md'):
            archive.write(path, path.name)
        for path in (patch, support / 'project.yml', support / 'README.md', Path(__file__)):
            archive.write(path, str(path.relative_to(repo)))
        for path in support.iterdir():
            if path.suffix in ('.h', '.m'): archive.write(path, str(path.relative_to(repo)))
        for path in (support / 'tests').rglob('*'):
            if path.is_file(): archive.write(path, str(path.relative_to(repo)))
    print(f'Unsigned IPA: {ipa}\nComplete sources: {source_zip}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('out_dir', nargs='?', default=OUT_DIR)
    args = parser.parse_args()
    folder = args.out_dir or input('Output folder: ').strip()
    if not folder: raise ValueError('An output folder is required.')
    build(Path(folder))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f'【红】{exc}', file=sys.stderr)
        if 'IPython' not in sys.modules: sys.exit(1)

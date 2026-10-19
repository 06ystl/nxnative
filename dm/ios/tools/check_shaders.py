#!/usr/bin/env python3
"""Check that an IPA's shader libraries can run on its declared minimum iOS."""
import json
import plistlib
import re
import sys
from pathlib import Path


def version(text):
    return tuple((list(map(int, text.split('.'))) + [0, 0])[:3])


def check(folder, info_plist, graphics='nvn'):
    with Path(info_plist).open('rb') as stream:
        minimum = plistlib.load(stream)['MinimumOSVersion']
    folder = Path(folder)
    libraries = sorted(folder.glob('*.metallib'))
    if graphics == 'vulkan':
        if not (folder / 'vk_shaders.metallib').is_file():
            raise ValueError(f'No Vulkan shader library in {folder}')
    elif not any(p.name.endswith('_b.metallib') for p in libraries):
        raise ValueError(f'No base shader libraries in {folder}')
    chain = folder.name.removeprefix('b-')
    for library in libraries:
        data = library.read_bytes()
        targets = re.findall(rb'air64(?:_v\d+)?-apple-ios(\d+\.\d+(?:\.\d+)?)', data)
        if data[:4] != b'MTLB' or not targets:
            raise ValueError(f'Cannot read an iOS AIR target from {library}')
        if any(version(t.decode()) > version(minimum) for t in targets):
            raise ValueError(f'{library.name} requires newer iOS than the app minimum {minimum}; rebuild the iOS shaders')
        if graphics != 'vulkan' and library.name.endswith('_b.metallib'):
            reflection = json.loads(library.with_suffix('.json').read_text())
            if reflection.get('chain') != chain:
                raise ValueError(f'Shader chain mismatch: {library.name}')
    return len(libraries), minimum


if __name__ == '__main__':
    try:
        count, minimum = check(*sys.argv[1:])
    except (OSError, ValueError, KeyError, TypeError) as error:
        sys.exit(f'【红】{error}')
    print(f'{count} iOS shader libraries validated for iOS {minimum}')

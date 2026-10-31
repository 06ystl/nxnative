#!/usr/bin/env python3
"""Prepare a local BotW PS5 prompt pack from Gantz79's TotK Dualsense UI mod."""
import argparse
from pathlib import Path
import subprocess
import sys

# Spyder F5 settings; command-line arguments override these paths.
ROMFS = ''
MOD = ''                 # Downloaded RAR or extracted mod directory
DICTIONARY = ''          # TotK Pack/ZsDic.pack.zs, or dictionary 1 (*.zsdic)
OUTPUT = ''              # New folder on the game's drive


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name, default in [('romfs', ROMFS), ('mod', MOD), ('dictionary', DICTIONARY), ('out', OUTPUT)]:
        parser.add_argument('--'+name, default=default, required=not default)
    args = parser.parse_args(argv)
    repo = Path(__file__).resolve().parents[1]
    sys.path.insert(0, str(repo/'dm/tools'))
    try:
        import controller_ui
        output = Path(args.out).expanduser().resolve()
        if output == repo or repo in output.parents:
            raise ValueError('Keep generated game/mod resources outside the repository')
        controller_ui.build(Path(args.romfs).expanduser().resolve(), Path(args.mod).expanduser().resolve(),
                            Path(args.dictionary).expanduser().resolve(), output)
        print('PS5 UI pack:', output)
    except (ImportError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print('【红】'+str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))

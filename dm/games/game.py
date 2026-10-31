#!/usr/bin/env python3
# Game profiles: dm/games/<base game title ID>/game.tsv (key <TAB> values..., lines starting with # are comments) + the shader tables (and patches.py, the rewriter's patches of the game's builds) in the same folder. The shader tools, the host build, iOS packaging and the NSP script take each game's constants from here.
# Usage: game.py list (list all profiles); game.py <id> <key> (print that key's value, for shell); game.py header <id> <out.h> (generate the host's game_profile.h);
#   game.py dir <id> (print the profile folder); game.py link <id> <link> (point a symlink at the profile folder: make cannot take paths with spaces)
#   From Python: import game; g = game.load() (takes DM_GAME; there is no default game: unset is an error that lists the profiles); game.by_title(title ID); g.get / g.words / g.int / g.builds() / g.table(file name)
# DM_GAMES_DIR (folders separated by ':') adds profile folders outside the repository, searched after dm/games: the NSP script writes a provisional profile for a game without one into
#   <NSP folder>/<id>_build/profile/<id>/ and points DM_GAMES_DIR at <id>_build/profile, so the shader tools, the host build and build_ipa.sh all find it.
#   DM_GAMES_FIRST=1 searches DM_GAMES_DIR before dm/games (the NSP script's --provisional: a provisional profile for a game that has one in dm/games, to test the guesses)
import os, re, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


class Game:
    def __init__(self, d):
        self.dir = Path(d).resolve(); self.id = self.dir.name; self.rows = []
        for line in (self.dir / 'game.tsv').read_text(encoding='utf-8').splitlines():
            if not line.strip() or line.lstrip().startswith('#'): continue
            c = line.split('\t'); self.rows.append((c[0].strip(), [v.strip() for v in c[1:]]))

    def values(self, key):   # every row of this key (keys such as build repeat)
        return [v for k, v in self.rows if k == key]

    def get(self, key, default=None):
        r = self.values(key)
        if r: return '\t'.join(r[0])
        if default is None: raise KeyError(f'{self.dir / "game.tsv"} has no key {key}')
        return default

    def words(self, key, default=None): return self.get(key, default).split()
    def int(self, key): return int(self.get(key), 0)
    def table(self, name): return self.dir / name

    @property
    def title_id(self): return int(self.get('title_id'), 16)

    def builds(self):
        """{version: {'display': display version, module name: build ID, ...}}"""
        out = {}
        for ver, disp, *mods in self.values('build'):
            out[ver] = dict([('display', disp)] + [tuple(m.split('=', 1)) for m in mods])
        return out

    def pairs(self, key):   # "a=b c=d" → [(a, b), (c, d)]
        return [tuple(w.split('=', 1)) for w in self.words(key)]


def extra_dirs():   # profile folders outside the repository (DM_GAMES_DIR), searched after dm/games
    return [Path(p) for p in os.environ.get('DM_GAMES_DIR', '').split(':') if p]


def search_dirs():   # dm/games, then DM_GAMES_DIR; DM_GAMES_FIRST=1 the other way round
    return extra_dirs() + [HERE] if os.environ.get('DM_GAMES_FIRST') else [HERE] + extra_dirs()


def find_dir(name):   # the profile folder of a title ID (the first of search_dirs that has it); a path is taken as is
    if os.sep in str(name): return Path(name)
    return next((d / name for d in search_dirs() if (d / name / 'game.tsv').exists()), HERE / name)


def load(name=None):
    name = name or os.environ.get('DM_GAME')
    if not name:   # there is no default game
        have = ', '.join(f'{g.id} ({g.get("name", "")})' for g in all_games())
        raise SystemExit(f'[RED] DM_GAME is not set: pick a game profile by base game title ID: {have}')
    d = find_dir(name)
    if not (d / 'game.tsv').exists():   # profile folders are named after the base game's title ID (the old names smbw / fe_engage are gone)
        have = ', '.join(f'{g.id} ({g.get("name", "")})' for g in all_games())
        raise SystemExit(f'[RED] no game profile {d / "game.tsv"} (DM_GAME / GAME take the base game title ID: {have})')
    return Game(d)


def all_games():
    out, seen = [], set()
    for root in search_dirs():
        if not root.is_dir(): continue
        for d in sorted(root.iterdir()):
            if (d / 'game.tsv').exists() and d.name not in seen: seen.add(d.name); out.append(Game(d))
    return out


def by_title(tid):
    return next((g for g in all_games() if g.title_id == tid), None)


def header(g):
    """the host's game_profile.h: the profile constants the host uses, as macros"""
    q = lambda s: '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'
    mods = g.words('modules')
    vers = ', '.join('{' + q(b['main']) + ', ' + q(b['display']) + '}' for b in g.builds().values() if 'main' in b)
    pi = g.get('present_interval', 'game')   # present interval: game = as the game sets it (as on the Switch), display = one frame per display tick
    if pi not in ('game', 'display'): sys.exit(f'{g.id}: present_interval must be game or display: {pi}')
    ft = g.get('fps_target', '0')   # frame rate cap of the rewriter's frame step (FRAME_STEP in the profile's patches.py: Tears of the Kingdom 1.4.3, Breath of the Wild 1.9.0) or of the engine's own frame limit (hle_fpslock.c): 0 = the game's own step, 30 / 60
    if ft not in ('0', '30', '60'): sys.exit(f'{g.id}: fps_target must be 0, 30 or 60: {ft}')
    fh = g.get('fps_hold', 'on')   # whether the frame step may hold a frame longer than the cap's vsyncs when frames come late (hle_nvn.c fstep_tick): on / off
    if fh not in ('on', 'off'): sys.exit(f'{g.id}: fps_hold must be on or off: {fh}')
    cp = g.get('core_preempt', 'off')   # same-core preemption approximation (hle_thread.c): on / off
    if cp not in ('on', 'off'): sys.exit(f'{g.id}: core_preempt must be on or off: {cp}')
    aba = g.get('alloc_big_align', 'off')   # nn::mem::StandardAllocator::Allocate aligns blocks of 64 KB or more to 64 KB (hle_os.c; Vanillaware's memory pool storage): on / off
    if aba not in ('on', 'off'): sys.exit(f'{g.id}: alloc_big_align must be on or off: {aba}')
    sf = g.get('shared_font', 'bfttf')   # what the shared-font address points at (hle_sdk16.c): bfttf = 8-byte header + TTF, ttf = the TTF alone
    if sf not in ('bfttf', 'ttf'): sys.exit(f'{g.id}: shared_font must be bfttf or ttf: {sf}')
    pl = g.get('pad_layout', 'simple')   # the virtual gamepad's first layout (DmGamepad.m; afterwards whatever the player switched to in game is kept): simple = 2D, full = 3D (D-pad, right stick, L3 / R3)
    if pl not in ('simple', 'full'): sys.exit(f'{g.id}: pad_layout must be simple or full: {pl}')
    fbs = g.words('feedback_snap', '')   # fragment shader key prefixes whose same-pass feedback sampling gets a snapshot first (nvn_mtl.m fb_prepare); none by default
    if any(not re.fullmatch(r'[0-9a-f]{8,16}', k) for k in fbs): sys.exit(f'{g.id}: feedback_snap 要写片元着色器键（8–16 位小写十六进制）| feedback_snap takes fragment shader keys (8-16 lowercase hex digits): {fbs}')
    afr = g.words('alpha_from_red', '')   # fragment shader key prefixes that read layout capture textures with R/RG channel mappings (nvn_mtl.m tex_layout_capture); none by default
    if any(not re.fullmatch(r'[0-9a-f]{8,16}', k) for k in afr): sys.exit(f'{g.id}: alpha_from_red 要写片元着色器键（8–16 位小写十六进制）| alpha_from_red takes fragment shader keys (8-16 lowercase hex digits): {afr}')
    rcd = g.get('render_cond', 'off')   # NVN conditional rendering evaluated at replay, timestamp reports with counter 0 (nvn_mtl.m OP_RENDER_COND): on / off
    if rcd not in ('on', 'off'): sys.exit(f'{g.id}: render_cond must be on or off: {rcd}')
    tfu = g.get('tex_flush_upload', 'off')   # textures written by the CPU into a pool and published with nvnMemoryPoolFlushMappedRange are uploaded like packaged ones (hle_nvn.c): on / off
    if tfu not in ('on', 'off'): sys.exit(f'{g.id}: tex_flush_upload must be on or off: {tfu}')
    tdu = g.get('tex_dirty_upload', 'off')   # with tex_flush_upload: a registered texture the CPU writes after init without any flush is uploaded too (dirty pages, hle_nvn.c nvn_ft_written): on / off
    if tdu not in ('on', 'off') or (tdu == 'on' and tfu != 'on'): sys.exit(f'{g.id}: tex_dirty_upload must be on or off, and needs tex_flush_upload on: {tdu}')
    tds = g.get('tex_dyn_slots', 'off')   # shaders whose texture handle the translator could not trace to one slot: slot indices in c2, the bound slots in the fallback arrays (nvn_mtl.m): on / off
    if tds not in ('on', 'off'): sys.exit(f'{g.id}: tex_dyn_slots must be on or off: {tds}')
    vcr = g.get('vconv_range', 'off')   # vertex attributes converted on the CPU only over the vertices each draw reads (nvn_mtl.m vc_draw_range): on / off
    if vcr not in ('on', 'off'): sys.exit(f'{g.id}: vconv_range must be on or off: {vcr}')
    mml = g.get('mem_map_limit', 'off')   # MapPhysicalMemory refused beyond the application pool, as on Horizon (hle_svc.c): on / off
    if mml not in ('on', 'off'): sys.exit(f'{g.id}: mem_map_limit must be on or off: {mml}')
    gts = g.get('gpu_timestamps', 'submission')   # counter timestamps (nvn_mtl.m rep_ticks): submission = one time per submission, segment = the GPU start / end of the segment holding the report
    if gts not in ('submission', 'segment'): sys.exit(f'{g.id}: gpu_timestamps must be submission or segment: {gts}')
    om = g.get('op_mode', 'console')   # the operation mode reported at start (hle_oe.c dm_opmode; DM_OPMODE overrides): console = docked, handheld = touch screen in use (Super Mario Galaxy's pointer)
    if om not in ('console', 'handheld'): sys.exit(f'{g.id}: op_mode must be console or handheld: {om}')
    pm = g.get('perf_mode', 'follow')   # the performance mode reported (hle_oe.c): follow = the operation mode's (Boost docked, Normal handheld), boost = Boost always
    if pm not in ('follow', 'boost'): sys.exit(f'{g.id}: perf_mode must be follow or boost: {pm}')
    api = g.get('device_api', '55.15')   # the NVN API major.minor version nvnDeviceGetInteger reports (hle_nvn.c)
    if not re.fullmatch(r'\d+\.\d+', api): sys.exit(f'{g.id}: device_api 要写成 主.次 | device_api must be major.minor: {api}')
    ub = g.get('mac_uniform_batch', 'off')
    if ub not in ('on', 'off'): raise ValueError(f'{g.id}: mac_uniform_batch must be on or off: {ub}')
    resolution_rows = []
    known_builds = {b['main'] for b in g.builds().values() if 'main' in b}
    seen = set()
    for row in g.values('mac_resolution_patch'):
        if len(row) != 5 or row[0] not in known_builds:
            raise ValueError(f'{g.id}: mac_resolution_patch requires a known main build, offset, original, 720p and 1080p instruction words')
        build, *numbers = row
        offset, original, hd, full_hd = (int(v, 0) for v in numbers)
        if offset < 0 or offset % 4 or any(w < 0 or w > 0xffffffff for w in (original, hd, full_hd)):
            raise ValueError(f'{g.id}: invalid mac_resolution_patch offset or instruction')
        if (build, offset) in seen:
            raise ValueError(f'{g.id}: duplicate mac_resolution_patch site for {build} at {offset:#x}')
        seen.add((build, offset))
        resolution_rows.append('{' + q(build) + f', {offset:#x}, {original:#x}, {hd:#x}, {full_hd:#x}' + '}')
    resolution_rows = ', '.join(resolution_rows) or '{0}'
    cheat_rows, cheat_sites = [], set()
    for row in g.values('mac_cheat_patch'):
        if len(row) != 5 or row[0] not in known_builds:
            raise ValueError(f'{g.id}: mac_cheat_patch requires a known main build, name, offset, original and replacement word')
        build, name, *numbers = row
        offset, original, replacement = (int(v, 0) for v in numbers)
        if not re.fullmatch(r'[a-z][a-z0-9_]*', name) or offset < 0 or offset % 4 or any(w < 0 or w > 0xffffffff for w in (original, replacement)):
            raise ValueError(f'{g.id}: invalid mac_cheat_patch name, offset or instruction')
        if (build, offset) in cheat_sites:
            raise ValueError(f'{g.id}: duplicate mac_cheat_patch site for {build} at {offset:#x}')
        cheat_sites.add((build, offset))
        cheat_rows.append('{' + q(build) + ', ' + q(name) + f', {offset:#x}, {original:#x}, {replacement:#x}' + '}')
    cheat_rows = ', '.join(cheat_rows) or '{0}'
    frame_rows, frame_guards, frame_seen = [], [], set()
    for key, count, target in [('mac_frame_step', 6, frame_rows), ('mac_frame_guard', 3, frame_guards)]:
        for row in g.values(key):
            if len(row) != count or row[0] not in known_builds:
                raise ValueError(f'{g.id}: {key} requires a known main build and {count - 1} numeric fields')
            numbers = [int(value, 0) for value in row[1:]]
            if numbers[0] < 0 or numbers[0] % 4 or any(value < 0 or value > 0xffffffff for value in numbers):
                raise ValueError(f'{g.id}: invalid {key} offset or instruction')
            identity = (key, row[0], numbers[0] if key == 'mac_frame_guard' else 0)
            if identity in frame_seen:
                raise ValueError(f'{g.id}: duplicate {key} for {row[0]}')
            if key == 'mac_frame_step' and (numbers[2] > 0xfff or numbers[3] > 0x3ffc or numbers[3] % 4 or not 1 <= numbers[4] <= 240):
                raise ValueError(f'{g.id}: invalid mac_frame_step fields or base rate')
            frame_seen.add(identity)
            target.append('{' + q(row[0]) + ', ' + ', '.join(hex(value) for value in numbers) + '}')
    frame_rows = ', '.join(frame_rows) or '{0}'
    frame_guards = ', '.join(frame_guards) or '{0}'
    bow_rows, bow_builds = [], set()
    for row in g.values('mac_bow_state'):
        if len(row) not in (17,18) or row[0] not in known_builds:
            raise ValueError(f'{g.id}: mac_bow_state requires a known main build, 16 layout fields and optional shot-bow register')
        values = [int(value, 0) for value in row[1:]]
        if len(values)==16: values.append(31)
        if any(value < 0 or value > 0xffffffff for value in values) or values[7] > 255:
            raise ValueError(f'{g.id}: invalid mac_bow_state fields')
        if values[16]>31: raise ValueError(f'{g.id}: invalid bow shot-bow register')
        if any(values[i] % 4 for i in (0, 1, 2, 3, 4, 5, 10, 11, 12, 13)):
            raise ValueError(f'{g.id}: unaligned mac_bow_state field')
        if len({values[8], values[14], values[15]}) != 3:
            raise ValueError(f'{g.id}: duplicate mac_bow_state phase values')
        if row[0] in bow_builds:
            raise ValueError(f'{g.id}: duplicate mac_bow_state build')
        bow_builds.add(row[0])
        bow_rows.append('{' + q(row[0]) + ', ' + ', '.join(hex(value) for value in values) + '}')
    bow_rows = ', '.join(bow_rows) or '{0}'
    shield_rows, shield_builds = [], set()
    for row in g.values('mac_shield_state'):
        if len(row) != 14 or row[0] not in known_builds:
            raise ValueError(f'{g.id}: mac_shield_state requires a known main build and 13 layout fields')
        values = [int(value, 0) for value in row[1:]]
        if any(value < 0 or value > 0xffffffff for value in values) or values[4] > 255 or not values[11]:
            raise ValueError(f'{g.id}: invalid mac_shield_state fields')
        if any(values[i] % 4 for i in (0, 1, 2, 6, 7, 8, 9, 10, 12)):
            raise ValueError(f'{g.id}: unaligned mac_shield_state field')
        if row[0] in shield_builds:
            raise ValueError(f'{g.id}: duplicate mac_shield_state build')
        shield_builds.add(row[0])
        shield_rows.append('{' + q(row[0]) + ', ' + ', '.join(hex(value) for value in values) + '}')
    shield_rows = ', '.join(shield_rows) or '{0}'
    audio_rows, audio_builds = [], set()
    for key in ('mac_audio_events', 'mac_audio_footsteps'):
        for row in g.values(key):
            if len(row) != 25 or row[0] not in known_builds:
                raise ValueError(f'{g.id}: {key} requires a known main build, event patterns and 23 fields')
            patterns = row[1]
            if key == 'mac_audio_footsteps':
                if len(patterns) > 63 or not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*', patterns):
                    raise ValueError(f'{g.id}: invalid legacy footstep token')
                patterns = '*' + patterns + '*'
            if len(patterns) > 1023 or any(not re.fullmatch(r'\*?[A-Za-z][A-Za-z0-9_]{0,62}\*?', p) for p in patterns.split(',')):
                raise ValueError(f'{g.id}: invalid {key} patterns')
            values = [int(value, 0) for value in row[2:]]
            if any(value < 0 or value > 0xffffffff for value in values) or values[4] > 255 or values[6] > 30 or values[13] > values[14]:
                raise ValueError(f'{g.id}: invalid {key} layout')
            if row[0] in audio_builds:
                raise ValueError(f'{g.id}: duplicate audio-event build')
            audio_builds.add(row[0])
            audio_rows.append('{' + q(row[0]) + ', ' + q(patterns) + ', ' + ', '.join(hex(v) for v in values) + '}')
    audio_rows = ', '.join(audio_rows) or '{0}'
    src = f'dm/games/{g.id}' if g.dir.parent == HERE else str(g.dir)
    L = [f'// Generated by dm/games/game.py from {src}/game.tsv; do not edit',
         '#pragma once',
         f'#define DM_GAME_ID {q(g.id)}',
         f'#define DM_GAME_NAME {q(g.get("name"))}',
         f'#define DM_GAME_PROGRAM_ID 0x{int(g.get("program_id"), 16):016X}ull',
         f'#define DM_GAME_MODULES {{{", ".join(map(q, mods))}}}',
         f'#define DM_GAME_NMOD {len(mods)}',
         f'#define DM_GAME_ROMFS_MARKER {q(g.get("romfs_marker"))}',
         f'#define DM_GAME_MEM_RESERVE {g.int("mem_reserve"):#x}ull',
         f'#define DM_GAME_MEM_ALIAS {g.int("mem_alias"):#x}ull',
         f'#define DM_GAME_MEM_STACK {g.int("mem_stack"):#x}ull',
         f'#define DM_GAME_APP_POOL {g.int("app_pool"):#x}ull',
         f'#define DM_GAME_MEM_USED {int(g.get("mem_used", "0x4000000"), 0):#x}ull',   # used memory reported beside the heap (hle_svc.c GetInfo UsedMemorySize)
         f'#define DM_GAME_SYS_RESOURCE {int(g.get("sys_resource", "0x2000000"), 0):#x}ull',   # the NPDM's system resource size (hle_svc.c GetInfo TotalSystemResourceSize; 0 = no virtual address memory)
         f'#define DM_GAME_ARGS {q(g.get("game_args", ""))}',   # game arguments when the command line gives none (main.c; Octopath Traveler 0: Unreal's -SwitchVirtualAddressSpaceSize=)
         f'#define DM_GAME_ENV {q(g.get("game_env", ""))}',   # KEY=VALUE pairs getenv answers (hle_os.c; Absolum: .NET's DOTNET_GCRegionRange)
         f'#define DM_GAME_MEM_MAP_LIMIT {int(mml == "on")}',
         f'#define DM_GAME_DISPLAY_VERSIONS {vers}',
         f'#define DM_GAME_PRESENT_DISPLAY {int(pi == "display")}',
         f'#define DM_GAME_CORE_PREEMPT {int(cp == "on")}',
         f'#define DM_GAME_ALLOC_BIG_ALIGN {int(aba == "on")}',
         f'#define DM_GAME_FPS_TARGET {int(ft)}',
         f'#define DM_GAME_FPS_HOLD {int(fh == "on")}',
         *([f'#define DM_GAME_SHARED_FONT_TTF {int(sf == "ttf")}'] if g.get('shared_font', '') else []),   # without the key the host decides by the SDK version (hle_sdk16.c)
         f'#define DM_GAME_PAD_FULL {int(pl == "full")}',
         f'#define DM_GAME_OPMODE {int(om == "console")}',
         f'#define DM_GAME_PERF_BOOST {int(pm == "boost")}',
         f'#define DM_GAME_FEEDBACK_SNAP {q(" ".join(fbs))}',
         f'#define DM_GAME_ALPHA_FROM_RED {q(" ".join(afr))}',
         f'#define DM_GAME_TEX_FLUSH_UPLOAD {int(tfu == "on")}',
         f'#define DM_GAME_RENDER_COND {int(rcd == "on")}',
         f'#define DM_GAME_TEX_DIRTY_UPLOAD {int(tdu == "on")}',
         f'#define DM_GAME_TEX_DYN_SLOTS {int(tds == "on")}',
         f'#define DM_GAME_GPU_TS_SEGMENT {int(gts == "segment")}',
         f'#define DM_GAME_VCONV_RANGE {int(vcr == "on")}',
         *([f'#define DM_GAME_NVN_API_MAJOR {api.split(".")[0]}', f'#define DM_GAME_NVN_API_MINOR {api.split(".")[1]}'] if g.get('device_api', '') else []),   # without the key: by the SDK version (hle_nvn.c nvn_api)
         f'#define DM_GAME_MAC_UNIFORM_BATCH {int(ub == "on")}',
         f'#define DM_GAME_MAC_RESOLUTION_PATCHES {resolution_rows}',
         f'#define DM_GAME_MAC_CHEAT_PATCHES {cheat_rows}',
         f'#define DM_GAME_MAC_FRAME_STEP {frame_rows}',
         f'#define DM_GAME_MAC_FRAME_GUARDS {frame_guards}',
         f'#define DM_GAME_MAC_BOW_STATE {bow_rows}',
         f'#define DM_GAME_MAC_SHIELD_STATE {shield_rows}',
         f'#define DM_GAME_MAC_AUDIO_EVENTS {audio_rows}',
         '']
    return '\n'.join(L)


if __name__ == '__main__':
    a = sys.argv[1:]
    if a == ['list']:
        for g in all_games(): print(f'{g.id}\t{g.title_id:016X}\t{g.get("name", "")}')
    elif len(a) == 3 and a[0] == 'header':
        out, text = Path(a[2]), header(load(a[1])); out.parent.mkdir(parents=True, exist_ok=True)
        if not (out.exists() and out.read_text() == text):   # written only when it changes: make runs this every time (the profile folder can change under the same GAME), and an unchanged header must not rebuild the host
            tmp = out.with_name(out.name + '.tmp'); tmp.write_text(text); tmp.replace(out)
    elif len(a) == 2 and a[0] == 'dir':
        print(load(a[1]).dir)
    elif len(a) == 3 and a[0] == 'link':   # link → the profile folder (replaced when it points elsewhere)
        d, ln = load(a[1]).dir, Path(a[2]); ln.parent.mkdir(parents=True, exist_ok=True)
        if not (ln.is_symlink() and Path(os.readlink(ln)) == d):
            if ln.is_symlink() or ln.exists(): ln.unlink()
            ln.symlink_to(d)
    elif len(a) == 2:
        print(load(a[0]).get(a[1]))
    else:
        sys.exit(__doc__ or 'usage: game.py list | game.py <id> <key> | game.py header <id> <out.h> | game.py dir <id> | game.py link <id> <link>')

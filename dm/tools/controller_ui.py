"""Adapt locally supplied Gantz79 DualSense UI assets to BotW's Switch UI.

Requires oead, Pillow and the zstd command. Donor archives and the game's zstd
dictionary remain outside the repository. Only controller artwork and glyphs are
transferred; language fonts, text and target layout structure stay in BotW.
"""
import io
import json
import math
import struct
import subprocess
import tempfile
import zlib
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps

GAME = '01007EF00011E000'
SOURCE = 'https://www.nexusmods.com/legendofzeldatearsofthekingdom/mods/123'
GUIDE_COLOUR = (255, 252, 198, 255)
CLUSTER_RING_SIZE = {'dpad': 72, 'face': 80}
# Basic-page label offsets in the target layout's coordinate system.
BASIC_GROUP_OFFSETS = {'N_CrossKey_00': 56, 'N_Minus_00': -6}
BASIC_STICK_OFFSET = -106
# Semantic buttons retain the Mac input mapping; only their HUD positions change.
SWITCH_FACE_POSITIONS = {'A': (26, 0), 'B': (0, -26), 'X': (0, 26), 'Y': (-26, 0)}
PS5_FACE_POSITIONS = {'A': (0, -26), 'B': (26, 0), 'X': (-26, 0), 'Y': (0, 26)}
FACE_GLYPHS = {button: 0xe040+i for i, button in enumerate('ABXY')}
RESOURCE_TABLE = 'System/Resource/ResourceSizeTable.product.srsizetable'


def unpack(data):
    import oead
    return bytes(oead.yaz0.decompress(data)) if data[:4] == b'Yaz0' else bytes(data)


def archive(data):
    import oead
    return {f.name: bytes(f.data) for f in oead.Sarc(unpack(data)).get_files()}


def replace_members(original, replacements, check_size=True):
    import oead
    writer = oead.SarcWriter.from_sarc(oead.Sarc(unpack(original)))
    for name, data in replacements.items():
        if name not in writer.files:
            raise ValueError('Missing target archive member: '+name)
        writer.files[name] = data
    _, raw = writer.write()
    raw = bytes(raw)
    if check_size and len(raw) > len(unpack(original)):
        raise ValueError('Converted UI exceeds the original resource allocation')
    alignment = struct.unpack_from('>I', original, 8)[0] if original[:4] == b'Yaz0' else 0
    return bytes(oead.yaz0.compress(raw, alignment)) if original[:4] == b'Yaz0' else raw


def textures(data):
    if data[:4] != b'BNTX':
        raise ValueError('Expected Switch BNTX')
    u32 = lambda at: struct.unpack_from('<I', data, at)[0]
    u64 = lambda at: struct.unpack_from('<Q', data, at)[0]
    result = {}
    for i in range(u32(0x24)):
        at = u64(u64(0x28)+8*i)
        name = u64(at+0x60)
        length = struct.unpack_from('<H', data, name)[0]
        result[data[name+2:name+2+length].decode()] = dict(
            at=at, fmt=u32(at+0x1c), width=u32(at+0x24), height=u32(at+0x28),
            tile=u32(at+0x34)&7, size=u32(at+0x50), data=u64(u64(at+0x70)))
    return result


def tile_offset(x, y, row, tile):
    """NVN GOB addressing; matches dm/gfx/tex/nvn_deswizzle.c."""
    height = 1 << tile
    return ((y//(8*height))*((row+63)//64)*512*height + (x//64)*512*height +
            ((y%(8*height))//8)*512 + (x%64//32)*256 + (y%8//2)*64 +
            (x%32//16)*32 + (y%2)*16 + x%16)


def linear(data, texture):
    fmt = texture['fmt']
    block, bpp = {0x0201: (1, 1), 0x0901: (1, 2), 0x1d01: (4, 8),
                  0x2001: (4, 16), 0x2006: (4, 16)}[fmt]
    row = (texture['width']+block-1)//block*bpp
    height = (texture['height']+block-1)//block
    output = bytearray(row*height)
    for y in range(height):
        for x in range(0, row, bpp):
            at = texture['data']+tile_offset(x, y, row, texture['tile'])
            output[y*row+x:y*row+x+bpp] = data[at:at+bpp]
    return bytes(output)


def image(data, texture):
    width, height, fmt = (texture[k] for k in ('width', 'height', 'fmt'))
    raw = linear(data, texture)
    if fmt in (0x0201, 0x0901):
        return Image.frombytes('L' if fmt == 0x0201 else 'LA', (width, height), raw)
    header = bytearray(128 if fmt == 0x1d01 else 148)
    header[:4] = b'DDS '
    struct.pack_into('<I', header, 4, 124)
    struct.pack_into('<I', header, 8, 0x81007)
    struct.pack_into('<II', header, 12, height, width)
    struct.pack_into('<I', header, 20, len(raw))
    struct.pack_into('<II', header, 76, 32, 4)
    struct.pack_into('<I', header, 108, 0x1000)
    header[84:88] = b'ATI1' if fmt == 0x1d01 else b'DX10'
    if fmt != 0x1d01:
        struct.pack_into('<5I', header, 128, 98, 3, 0, 1, 0)
    return Image.open(io.BytesIO(header+raw)).convert('L' if fmt == 0x1d01 else 'RGBA')


def bc4(block):
    hi, lo = max(block), min(block)
    palette = [hi, lo] + [(hi*(7-i)+lo*i)//7 for i in range(1, 7)]
    bits = sum(min(range(8), key=lambda k: abs(palette[k]-value)) << (3*i)
               for i, value in enumerate(block))
    return bytes((hi, lo))+bits.to_bytes(6, 'little')


def write_image(data, texture, picture):
    """Overwrite pixels in place, retaining BNTX pointers and allocation size."""
    width, height, fmt = (texture[k] for k in ('width', 'height', 'fmt'))
    if picture.size != (width, height):
        raise ValueError('Texture size mismatch')
    if fmt == 0x1d01:
        pixels = picture.convert('L')
        old = image(data, texture)
        row = (width+3)//4*8
        for y in range(0, height, 4):
            for x in range(0, width, 4):
                box = (x, y, x+4, y+4)
                values = pixels.crop(box).tobytes()
                if values == old.crop(box).tobytes():
                    continue
                at = texture['data']+tile_offset(x//4*8, y//4, row, texture['tile'])
                data[at:at+8] = bc4(values)
        return
    mode, bpp = {0x0201: ('L', 1), 0x0901: ('LA', 2)}[fmt]
    raw = picture.convert(mode).tobytes()
    row = width*bpp
    for y in range(height):
        for x in range(0, row, bpp):
            offset = tile_offset(x, y, row, texture['tile'])
            if offset+bpp > texture['size']:
                raise ValueError('Artwork exceeds texture storage')
            at = texture['data']+offset
            data[at:at+bpp] = raw[y*row+x:y*row+x+bpp]


def decode_font(data):
    decoded = b''.join(struct.pack('>I', int.from_bytes(data[i:i+4], 'big') ^ 0x49621806)
                       for i in range(8, len(data), 4))
    if decoded[:4] not in (b'\0\1\0\0', b'OTTO'):
        raise ValueError('Unsupported donor font')
    return decoded


def adapt_font(original, donor):
    data = bytearray(original)
    base = data.index(b'BNTX')
    payload = bytearray(data[base:])
    texture, = textures(payload).values()
    sheet = image(payload, texture).transpose(Image.Transpose.FLIP_TOP_BOTTOM)
    font = ImageFont.truetype(io.BytesIO(donor), 200)
    # The donor uses Nintendo's positional convention. Preserve the Mac's
    # existing semantic mapping: cross=A, circle=B, square=X, triangle=Y.
    symbols = {0: 0xe041, 1: 0xe040, 2: 0xe043, 3: 0xe042,
               4: 0xe044, 5: 0xe045, 6: 0xe046, 7: 0xe047,
               11: 0xe04c, 12: 0xe04b}
    for index, codepoint in symbols.items():
        x, y = index%5*51, index//5*51
        box = sheet.crop((x, y, x+50, y+50)).getbbox()
        glyph = Image.new('L', (256, 256))
        ImageDraw.Draw(glyph).text((0, 0), chr(codepoint), font=font, fill=255, anchor='lt')
        glyph = ImageOps.contain(glyph.crop(glyph.getbbox()), (box[2]-box[0], box[3]-box[1]), Image.Resampling.LANCZOS)
        sheet.paste(0, (x, y, x+50, y+50))
        sheet.paste(glyph, (x+box[0]+(box[2]-box[0]-glyph.width)//2,
                            y+box[1]+(box[3]-box[1]-glyph.height)//2))
    write_image(payload, texture, sheet.transpose(Image.Transpose.FLIP_TOP_BOTTOM))
    data[base:] = payload
    return bytes(data), sheet


def fitted(picture, size):
    picture = ImageOps.contain(picture, size, Image.Resampling.LANCZOS)
    canvas = Image.new('RGBA', size)
    canvas.paste(picture, ((size[0]-picture.width)//2, (size[1]-picture.height)//2))
    return canvas


def adapt_textures(original, donor):
    result = bytearray(original)
    target, source = textures(original), textures(donor)
    changes = {}
    for letter, other in {'A': 'B', 'B': 'A', 'X': 'Y', 'Y': 'X'}.items():
        name = 'Nt_KeyTex'+letter+'_00^d'
        picture = image(donor, source['Nt_KeyTex'+other+'_00^d'])
        changes[name] = fitted(picture, (target[name]['width'], target[name]['height'])).getchannel('A')
    for suffix in ('L', 'ZL', 'LSt'):
        name = 'Nt_KeyTex'+suffix+'_00^d'
        changes[name] = fitted(image(donor, source[name]), (48, 48)).getchannel('A')
    front = image(donor, source['Controller_Pro^w'])
    top = image(donor, source['Controller_Pro1^w'])
    changes['Nt_NNillust_00^f'] = fitted(front, (576, 288))
    # The original 576x100 texture reserves 147456 bytes of block-linear RG8.
    # 288x168 fits that same allocation and keeps the donor's aspect ratio.
    upper = target['Nt_NNillust_01^f']
    struct.pack_into('<II', result, upper['at']+0x24, 288, 168)
    upper.update(width=288, height=168)
    changes['Nt_NNillust_01^f'] = fitted(top, (288, 168))
    # The tutorial's shoulder/face/stick closeups use separate textures.
    crops = [top.crop((0, 0, 300, 220)), top.crop((280, 0, 580, 220)),
             front.crop((290, 0, 580, 290)), front.crop((0, 0, 290, 290))]
    for prefix, count in [('Nt_GamePadIllustS', 5), ('Nt_GamePadIllustSnn', 4)]:
        for i in range(count):
            name = prefix+'_'+str(i).zfill(2)+'^f'
            texture = target[name]
            changes[name] = fitted(crops[2 if i == 4 else i],
                                   (texture['width'], texture['height']))
    for name, picture in changes.items():
        write_image(result, target[name], picture)
    return bytes(result), list(changes)


def layout_panes(data):
    """Read pane transforms, including mirrored parent groups."""
    if data[:6] != b'FLYT\xff\xfe':
        raise ValueError('Expected little-endian Switch layout')
    at = struct.unpack_from('<H', data, 6)[0]
    rows, stack, last = [], [], None
    while at < len(data):
        kind, size = bytes(data[at:at+4]), struct.unpack_from('<I', data, at+4)[0]
        if size < 8 or at+size > len(data):
            raise ValueError('Invalid target layout section')
        if kind == b'pas1':
            stack.append(last)
        elif kind == b'pae1':
            stack.pop()
        elif kind in (b'pan1', b'pic1', b'txt1', b'wnd1', b'bnd1', b'prt1'):
            name = bytes(data[at+12:at+36]).split(b'\0')[0].decode()
            x, y, _, _, _, angle, sx, sy, _, _ = struct.unpack_from('<10f', data, at+44)
            angle = math.radians(angle)
            p = stack[-1]['world'] if stack else (1, 0, 0, 1, 0, 0)
            local = (sx*math.cos(angle), sx*math.sin(angle), -sy*math.sin(angle), sy*math.cos(angle), x, y)
            a, b, c, d, tx, ty = p
            aa, bb, cc, dd, xx, yy = local
            world = (a*aa+c*bb, b*aa+d*bb, a*cc+c*dd, b*cc+d*dd, a*xx+c*yy+tx, b*xx+d*yy+ty)
            last = dict(name=name, at=at, kind=kind, size=size, parent=p, world=world,
                        ancestors=tuple(q['name'] for q in stack))
            rows.append(last)
        at += size
    return rows


def inverse_point(matrix, point):
    a, b, c, d, x, y = matrix
    dx, dy = point[0]-x, point[1]-y
    determinant = a*d-b*c
    return ((d*dx-c*dy)/determinant, (-b*dx+a*dy)/determinant)


def control_point(point, upper=False):
    """Land on the donor artwork, after its actual texture/pane fit."""
    texture = (288, 168) if upper else (576, 288)
    pane = (340, 198.333333) if upper else texture
    fitted_size = ImageOps.contain(Image.new('L', (580, 340)), texture).size
    x = point[0]*fitted_size[0]/580+(texture[0]-fitted_size[0])//2
    y = point[1]*fitted_size[1]/340+(texture[1]-fitted_size[1])//2
    return ((x/texture[0]-.5)*pane[0]*.67,
            (.5-y/texture[1])*pane[1]*.67+(-194 if upper else -10))


def adapt_layout(original):
    """Reconnect BotW's own guide sprites to the actual DualSense controls."""
    data = bytearray(original)
    rows = layout_panes(original)
    # Basic controls: menu button, D-pad trio, then movement/crouch. Move each
    # label block with its icon/background and route its guide from the new edge.
    for row in rows:
        if 'N_Kihon_00' not in row['ancestors']:
            continue
        delta = BASIC_GROUP_OFFSETS.get(row['name'], 0)
        if row['ancestors'][-1] == 'N_Kihon_00' and row['name'] in (
                'T_Lstick_00', 'T_Lstick_01', 'T_Icon_16', 'W_Base_02', 'N_Line_00'):
            delta = BASIC_STICK_OFFSET
        if delta:
            y = struct.unpack_from('<f', data, row['at']+48)[0]
            struct.pack_into('<f', data, row['at']+48, y+delta)
    rows = layout_panes(data)
    by_name = {r['name']: r for r in rows}
    # Reuse the game's straight blue line and endpoint-dot materials/UVs.
    straight = by_name.get('P_Line_15')
    dot = by_name.get('P_Line_07')
    def geometry(row, start, end=None, template=None):
        at = row['at']
        a = inverse_point(row['parent'], start)
        b = inverse_point(row['parent'], end) if end else a
        data[at+8] |= 1
        data[at+9] = 0  # centre origin on both axes
        data[at+10] = 255
        struct.pack_into('<ff', data, at+44, (a[0]+b[0])*.5, (a[1]+b[1])*.5)
        if template:
            if row['size'] != template['size']:
                raise ValueError('Incompatible guide sprite geometry')
            data[at+84:at+row['size']] = original[template['at']+84:template['at']+template['size']]
            angle = math.degrees(math.atan2(b[1]-a[1], b[0]-a[0])) if end else 0
            struct.pack_into('<5f', data, at+64, angle, 1, 1,
                             math.hypot(b[0]-a[0], b[1]-a[1]) if end else 10, 10)
    anchors = {
        'stick_left': control_point((215, 166)), 'stick_right': control_point((360, 166)),
        'pad': control_point((148, 104)), 'face': control_point((431, 104)),
        'create': control_point((182, 55)), 'options': control_point((390, 55)),
        'L2': control_point((165, 31), True), 'R2': control_point((415, 31), True),
        'L1': control_point((158, 65), True), 'R1': control_point((425, 65), True),
    }
    semantic = ['stick_left', 'stick_right', 'pad', 'options', 'L2', 'R2', 'face', 'R1',
                'stick_left', 'L1', 'stick_left', 'L2', 'L2', 'face', 'pad', 'L1',
                'L1', 'stick_right', 'options', 'R2', 'R1', 'face', 'pad', 'R2',
                'options', 'stick_right']
    groups = {'N_Line_'+str(i).zfill(2): value for i, value in enumerate(semantic)}
    groups.update({'N_Minus_'+str(i).zfill(2): 'create' for i in range(3)})
    for group, feature in groups.items():
        members = []
        for r in rows:
            owners = [n for n in r['ancestors'] if n in groups]
            if owners and owners[-1] == group and r['kind'] == b'pic1' and r['name'].startswith(('P_Line_', 'Nt_TipsLineCircle_')):
                members.append(r)
        if not members:
            continue
        if not straight or not dot:
            raise ValueError('Missing target guide sprite templates')
        edges = [r['world'][4:6] for r in members
                 if abs(abs(r['world'][4])-195) < .01 and original[r['at']+9] == 0]
        if len(edges) != 1:
            raise ValueError('Cannot identify the label edge of '+group)
        edge = edges[0]
        x, y = anchors[feature]
        side = -1 if edge[0] < 0 else 1
        ring_size = CLUSTER_RING_SIZE['face' if feature == 'face' else 'dpad']
        if feature == 'stick_left':
            path = ([edge, (x, edge[1]), (x, y)] if 'N_Kihon_00' in members[0]['ancestors']
                    else [edge, (-170, edge[1]), (-170, 52), (x, 52), (x, y)])
        elif feature == 'pad':
            path = [(edge[0], y), (x-ring_size/2, y)]
        elif feature == 'face':
            path = [(edge[0], y), (x+ring_size/2, y)]
        elif feature in ('L2', 'R2'):
            path = [edge, (side*82, edge[1]), (side*82, y), (x, y)]
        else:
            path = [edge, (x, edge[1]), (x, y)]
        path = [point for i, point in enumerate(path)
                if not i or math.dist(point, path[i-1]) > 1e-5]
        ring = next((r for r in members if r['name'].startswith('Nt_TipsLineCircle_')), None)
        endpoint = ring or members[-1]
        segments = [r for r in members if r is not endpoint]
        if len(segments) < len(path)-1:
            raise ValueError('Not enough guide segments in '+group)
        for row in members:
            data[row['at']+8] &= ~1
        for row, a, b in zip(segments, path, path[1:]):
            geometry(row, a, b, straight)
        geometry(endpoint, (x, y), template=None if ring else dot)
        if ring:
            struct.pack_into('<ff', data, ring['at']+76, ring_size, ring_size)
    for row in rows:
        if row['name'] == 'P_NNillust_01':
            struct.pack_into('<ff', data, row['at']+76, 340, 198.333333)
    # Material colour register 1 controls the original blue guide sprites.
    # Match the game's warm-white text without changing textures or alpha.
    at = data.index(b'mat1')
    count = struct.unpack_from('<H', data, at+8)[0]
    for i in range(count):
        material = at+struct.unpack_from('<I', data, at+12+i*4)[0]
        name = bytes(data[material:material+28]).split(b'\0')[0]
        if name.startswith((b'P_Line_', b'Nt_TipsLineCircle_')):
            data[material+40:material+44] = bytes(GUIDE_COLOUR)
    return bytes(data)


def action_prompt_font(original):
    """Add the existing button-symbol font without changing the language font."""
    at = struct.unpack_from('<H', original, 6)[0]
    while at < len(original):
        kind, size = original[at:at+4], struct.unpack_from('<I', original, at+4)[0]
        if kind == b'fnl1':
            section = original[at:at+size]
            count = struct.unpack_from('<H', section, 8)[0]
            offsets = struct.unpack_from('<'+str(count)+'I', section, 12)
            names = [section[12+offset:].split(b'\0', 1)[0] for offset in offsets]
            if b'External_00.bffnt' in names:
                return original, names.index(b'External_00.bffnt')
            strings = section[12+4*count:]
            font = b'External_00.bffnt\0'
            font += bytes(-len(font)%4)
            extra = struct.pack('<I', 4*(count+1)+len(strings))
            result = bytearray(section[:12]+b''.join(struct.pack('<I', o+4) for o in offsets)+extra+strings+font)
            struct.pack_into('<I', result, 4, len(result))
            struct.pack_into('<H', result, 8, count+1)
            data = bytearray(original[:at]+result+original[at+size:])
            struct.pack_into('<I', data, 12, len(data))
            return bytes(data), count
        at += size
    raise ValueError('Contextual prompt has no font list')


def resize_common_allocation(original, before, after):
    """Keep Common.blarc's existing allocation overhead when its layouts grow."""
    data = bytearray(unpack(original))
    if data[:4] != b'RSTB':
        raise ValueError('Expected BotW resource size table')
    count = struct.unpack_from('<I', data, 4)[0]
    key = zlib.crc32(b'Layout/Common.blarc')
    entries = [12+8*i for i in range(count) if struct.unpack_from('<I', data, 12+8*i)[0] == key]
    if len(entries) != 1:
        raise ValueError('Missing Common.blarc resource allocation')
    at = entries[0]+4
    allocated = struct.unpack_from('<I', data, at)[0]
    struct.pack_into('<I', data, at, (allocated+max(0, after-before)+31)&~31)
    if original[:4] == b'Yaz0':
        import oead
        return bytes(oead.yaz0.compress(data, struct.unpack_from('>I', original, 8)[0]))
    return bytes(data)


def adapt_action_prompt(original, button, left_caption):
    """Place contextual four-button hints at the physical DualSense positions.

    The highlighted button and its caption move together. The left-hand square
    uses the game's existing left-facing caption geometry, retaining its own
    text, material references and animation targets.
    """
    original, font_index = action_prompt_font(original)
    data = bytearray(original)
    rows = layout_panes(original)
    icon = next(r for r in rows if r['name'] == f'Nt_KeyTex{button}_00')
    active = icon['ancestors'][-1]
    dx, dy = (b-a for a, b in zip(SWITCH_FACE_POSITIONS[button], PS5_FACE_POSITIONS[button]))
    for row in rows:
        at, name = row['at'], row['name']
        if name in (active, f'N_Capture{button}_00') or (
                name == 'N_Attention_00' and row['ancestors'] == ('RootPane',)):
            x, y = struct.unpack_from('<ff', original, at+44)
            struct.pack_into('<ff', data, at+44, x+dx, y+dy)
        elif row['kind'] == b'txt1' and row['ancestors'][-1:] == ('N_Loop_00',):
            parts = name.split('_')
            if len(parts) == 3 and parts[0] == 'T' and parts[1] in PS5_FACE_POSITIONS:
                source = SWITCH_FACE_POSITIONS[parts[1]]
                target = PS5_FACE_POSITIONS[parts[1]]
                x, y = struct.unpack_from('<ff', original, at+44)
                struct.pack_into('<ff', data, at+44, x+target[0]-source[0], y+target[1]-source[1])
                struct.pack_into('<H', data, at+90, font_index)
                text = struct.unpack_from('<I', original, at+100)[0]
                struct.pack_into('<H', data, at+text, FACE_GLYPHS[parts[1]])
    if button == 'X':
        templates = {r['name']: r for r in layout_panes(left_caption)}
        replacements = {
            'N_CaptureX_00': 'N_CaptureY_00',
            'T_GuideX_00': 'T_GuideY_00',
            'Nt_KeyTexX_01': 'Nt_KeyTexY_01',
            'P_CaptureUse_02': 'P_CaptureUse_02',
            'W_BaseX_00': 'W_BaseY_00',
            'T_GuideX_01': 'T_GuideY_01',
        }
        for row in rows:
            if row['name'] not in replacements:
                continue
            template = templates[replacements[row['name']]]
            at, other = row['at'], template['at']
            if row['kind'] != template['kind'] or row['size'] != template['size']:
                raise ValueError('Incompatible contextual caption geometry')
            data[at+9] = left_caption[other+9]  # pane origin; never mirror the text
            data[at+44:at+84] = left_caption[other+44:other+84]
            if row['kind'] == b'txt1':
                data[at+92:at+94] = left_caption[other+92:other+94]  # text alignment
    return bytes(data)


def donor_members(mod, dictionary, scratch):
    """Read an extracted mod directory or its RAR without executing its contents."""
    with tempfile.TemporaryDirectory(prefix='.controller-ui-', dir=scratch) as temporary:
        temporary = Path(temporary)
        if dictionary.name.endswith('.zs'):
            raw = subprocess.check_output(['zstd', '-qdc', str(dictionary)])
            dictionaries = [v for v in archive(raw).values()
                            if v[:8] == bytes.fromhex('37a430ec01000000')]
            if len(dictionaries) != 1:
                raise ValueError('No dictionary 1 in ZsDic.pack.zs')
            dictionary = temporary/'common.zsdic'
            dictionary.write_bytes(dictionaries[0])
        if mod.is_dir():
            fonts = list(mod.rglob('Font.Nin_NX_NVN.bfarc.zs'))
            layouts = list(mod.rglob('Common.Product.110.Nin_NX_NVN.blarc.zs'))
            if len(fonts) != 1 or len(layouts) != 1:
                raise ValueError('Expected the Dualsense Controller UI v1 mod')
            compressed = [fonts[0].read_bytes(), layouts[0].read_bytes()]
        else:
            names = subprocess.check_output(['bsdtar', '-tf', str(mod)], text=True).splitlines()
            compressed = []
            for suffix in ('/Font/Font.Nin_NX_NVN.bfarc.zs', '/UI/LayoutArchive/Common.Product.110.Nin_NX_NVN.blarc.zs'):
                matches = [n for n in names if n.endswith(suffix)]
                if len(matches) != 1:
                    raise ValueError('Expected the Dualsense Controller UI v1 RAR')
                compressed.append(subprocess.check_output(['bsdtar', '-xOf', str(mod), matches[0]]))
        outputs = []
        for i, data in enumerate(compressed):
            path = temporary/str(i)
            path.write_bytes(data)
            outputs.append(archive(subprocess.check_output(['zstd', '-qdc', '-D', str(dictionary), str(path)])))
        return outputs


def build(romfs, mod, dictionary, output):
    if output.exists():
        raise ValueError('Choose a new output directory: '+str(output))
    output.parent.mkdir(parents=True, exist_ok=True)
    donor_font, donor_ui = donor_members(mod, dictionary, output.parent)
    font = decode_font(donor_font['scft/External.bfotf'])
    files = {}
    for path in sorted((romfs/'Font').glob('Font_*.sbfarc')):
        original = path.read_bytes()
        external, preview = adapt_font(archive(original)['External_00.bffnt'], font)
        files['Font/'+path.name] = replace_members(original, {'External_00.bffnt': external})
    if not files:
        raise ValueError('No BotW Switch font archives found')
    boot = (romfs/'Pack/Bootup.pack').read_bytes()
    common = archive(boot)['Layout/Common.sblarc']
    members = archive(common)
    atlas, changed = adapt_textures(members['timg/__Combined.bntx'], donor_ui['timg/__Combined.bntx'])
    layout = 'blyt/PaAllControllerTipsNN_00.bflyt'
    replacements = {'timg/__Combined.bntx': atlas, layout: adapt_layout(members[layout])}
    left_caption = members['blyt/PaDoCommandY_00.bflyt']
    for button in PS5_FACE_POSITIONS:
        name = f'blyt/PaDoCommand{button}_00.bflyt'
        replacements[name] = adapt_action_prompt(members[name], button, left_caption)
    converted_common = replace_members(common, replacements, check_size=False)
    files[RESOURCE_TABLE] = resize_common_allocation((romfs/RESOURCE_TABLE).read_bytes(),
                                                    len(unpack(common)), len(unpack(converted_common)))
    # Bootup.pack has no RSTB entry: its outer allocation follows file size.
    # Common.blarc's allocation is updated above; font allocations stay unchanged.
    files['Pack/Bootup.pack'] = replace_members(boot, {'Layout/Common.sblarc': converted_common}, check_size=False)
    output.mkdir(parents=True)
    for name, data in files.items():
        path = output/'romfs'/name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    preview.save(output/'glyph-preview.png')
    (output/'manifest.tsv').write_text('game\t'+GAME+'\nsource\t'+SOURCE+'\nmapping\tcross=A,circle=B,square=X,triangle=Y\n')
    (output/'ATTRIBUTION.txt').write_text(
        'Dualsense Controller UI by Gantz79, version 1 (2024-01-08).\n'+SOURCE+'\n'
        'Locally adapted for BotW from the user-supplied TotK mod.\n'
        'Game and mod assets are not nxnative source. Follow the original authors\'\n'
        'permissions; this local conversion grants no redistribution permission.\n')
    (output/'README.txt').write_text(
        'Place this directory at patches/dualsense-ui beside the Mac game App.\n'
        'Connect the player-1 DualSense before starting the game (USB or Bluetooth).\n'
        'The patch activates only for that controller. Other controllers use original UI.\n'
        'Move this directory out of patches and restart to disable it.\n'
        'Restart after changing controllers. No env.txt setting is needed.\n')
    (output/'conversion.json').write_text(json.dumps({
        'source': SOURCE, 'files': list(files), 'textures': changed,
        'guide_colour': '#'+bytes(GUIDE_COLOUR[:3]).hex(),
        'basic_left_order': ['Create', 'D-pad trio', 'movement/crouch'],
        'basic_dpad_adjustment': 'Compact 3-4 screen-pixel gaps; movement/crouch unchanged',
        'cluster_ring_size': CLUSTER_RING_SIZE,
        'contextual_button_positions': PS5_FACE_POSITIONS,
        'dpad_guide': 'direct horizontal'}, indent=2))

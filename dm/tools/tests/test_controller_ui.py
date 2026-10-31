"""Binary UI conversion contracts, using generated resources only."""
import struct
import zlib
import sys
import unittest
import importlib.util
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
try:
    import controller_ui as ui
    from PIL import Image
except ModuleNotFoundError:
    ui = None


@unittest.skipIf(ui is None or importlib.util.find_spec('oead') is None,
                 'Optional UI conversion requires Pillow and oead')
class ControllerUIConversionTests(unittest.TestCase):
    @staticmethod
    def action_prompt(button):
        """Synthetic panes retain distinct materials and text for each layout."""
        def pane(kind, name, x=0, y=0):
            data = bytearray(200 if kind == b'txt1' else 148)
            data[:4] = kind
            struct.pack_into('<I', data, 4, len(data))
            data[12:12+len(name)] = name.encode()
            struct.pack_into('<10f', data, 44, x, y, 0, 0, 0, 0, 1, 1, 116, 30)
            data[9] = 2 if button == 'Y' else 1
            if kind == b'txt1':
                data[88:90] = button.encode()*2  # material reference
                struct.pack_into('<I', data, 100, 168)
                data[92] = 2 if button == 'Y' else 1
                data[180:184] = button.encode()*4  # text payload
                struct.pack_into('<ff', data, 112, 17, 25.5)
            if kind == b'wnd1' and button == 'Y':
                struct.pack_into('<f', data, 68, -1)
            return data
        begin, end = b'pas1\x08\0\0\0', b'pae1\x08\0\0\0'
        x, y = ui.SWITCH_FACE_POSITIONS[button]
        left = button == 'Y'
        active = 'N_BtnX_00' if left else f'N_Btn{button}_00'
        body = pane(b'pan1', 'RootPane')+begin
        body += pane(b'pan1', f'N_Capture{button}_00', x+(-60 if left else 60), y)+begin
        body += pane(b'txt1', f'T_Guide{button}_00', 37 if left else -39)
        body += pane(b'pic1', f'Nt_KeyTex{button}_01', 60 if left else -60)+end
        body += pane(b'pan1', 'N_Loop_00')+begin
        for other, (xx, yy) in ui.SWITCH_FACE_POSITIONS.items():
            if other != button:
                body += pane(b'txt1', f'T_{other}_00', xx, yy)
        body += pane(b'pan1', active, x, y)+begin
        body += pane(b'pic1', f'Nt_KeyTex{button}_00')
        body += pane(b'pic1', 'P_CaptureUse_02', -60 if left else 60)
        body += pane(b'wnd1', f'W_Base{button}_00', 33 if left else -33)
        body += pane(b'txt1', f'T_Guide{button}_01', -23 if left else 21)+end+end+end
        header = bytearray(20)
        header[:6] = b'FLYT\xff\xfe'
        struct.pack_into('<H', header, 6, 20)
        fonts = bytearray(36)
        fonts[:4] = b'fnl1'
        struct.pack_into('<IHHI', fonts, 4, 36, 1, 0, 4)
        fonts[16:33] = b'NormalS_00.bffnt\0'
        return bytes(header+fonts+body)

    def test_contextual_face_buttons_follow_physical_dualsense_positions(self):
        left_caption = self.action_prompt('Y')
        for button in 'ABXY':
            with self.subTest(button=button):
                original = self.action_prompt(button)
                result = ui.adapt_action_prompt(original, button, left_caption)
                rows = ui.layout_panes(result)
                active = next(r for r in rows if r['name'] == f'Nt_KeyTex{button}_00')
                self.assertEqual(active['world'][4:6], ui.PS5_FACE_POSITIONS[button])
                for other in 'ABXY':
                    if other != button:
                        row = next(r for r in rows if r['name'] == f'T_{other}_00')
                        self.assertEqual(row['world'][4:6], ui.PS5_FACE_POSITIONS[other])
                self.assertEqual(len(result), len(original)+24)
                original_rows = {r['name']: r for r in ui.layout_panes(original)}
                for row in rows:
                    if row['kind'] == b'txt1':
                        at, before = row['at'], original_rows[row['name']]['at']
                        self.assertEqual(result[at+88:at+90], original[before+88:before+90])
                        self.assertEqual(result[at+180:at+184], original[before+180:before+184])
                        parts = row['name'].split('_')
                        if parts[1] in ui.FACE_GLYPHS:
                            self.assertEqual(struct.unpack_from('<H', result, at+90)[0], 1)
                            self.assertEqual(struct.unpack_from('<H', result, at+168)[0], ui.FACE_GLYPHS[parts[1]])
                            width, height = struct.unpack_from('<ff', result, at+112)
                            self.assertEqual((width, height), (25.5, 25.5))
                            self.assertGreaterEqual(struct.unpack_from('<f', result, at+76)[0], width)

    def test_contextual_prompt_reuses_its_external_font_reference(self):
        result, index = ui.action_prompt_font(self.action_prompt('A'))
        again, reused = ui.action_prompt_font(result)
        self.assertEqual(again, result)
        self.assertEqual((index, reused), (1, 1))

    def test_contextual_growth_updates_only_the_common_resource_allocation(self):
        key = zlib.crc32(b'Layout/Common.blarc')
        original = b'RSTB'+struct.pack('<II', 2, 0)+struct.pack('<IIII', 123, 8192, key, 4096)
        result = ui.resize_common_allocation(original, 3000, 3024)
        self.assertEqual(result[:24], original[:24])
        self.assertEqual(struct.unpack_from('<I', result, 24)[0], 4128)

    def test_square_caption_faces_left_without_mirroring_its_text(self):
        result = ui.adapt_action_prompt(self.action_prompt('X'), 'X', self.action_prompt('Y'))
        rows = {r['name']: r for r in ui.layout_panes(result)}
        window, text = rows['W_BaseX_00'], rows['T_GuideX_01']
        self.assertEqual(struct.unpack_from('<f', result, window['at']+68)[0], -1)
        self.assertEqual(struct.unpack_from('<f', result, text['at']+68)[0], 1)
        self.assertLess(text['world'][4], ui.PS5_FACE_POSITIONS['X'][0])
        self.assertEqual(result[text['at']+9], 2)
        self.assertEqual(result[text['at']+92], 2)

    def test_only_selected_archive_members_change(self):
        import oead
        writer = oead.SarcWriter(oead.Endianness.Little)
        writer.files['External_00.bffnt'] = b'old font'*100
        writer.files['ChineseText.bffnt'] = b'language payload\0\xff'
        _, raw = writer.write()
        original = bytes(oead.yaz0.compress(raw, 4096))
        result = ui.replace_members(original, {'External_00.bffnt': b'new font'})
        self.assertEqual(ui.archive(result)['ChineseText.bffnt'], b'language payload\0\xff')
        self.assertEqual(ui.archive(result)['External_00.bffnt'], b'new font')
        self.assertEqual(result[8:12], original[8:12])
        with self.assertRaisesRegex(ValueError, 'allocation'):
            ui.replace_members(original, {'External_00.bffnt': b'oversize'*1000})

    def test_subword_texture_upload_preserves_padding_and_neighbours(self):
        texture = dict(fmt=0x0901, width=19, height=17, tile=2, size=4096, data=64)
        data = bytearray([0x7b]*4224)
        picture = Image.new('LA', (19, 17), (41, 207))
        ui.write_image(data, texture, picture)
        self.assertEqual(ui.image(data, texture).tobytes(), picture.tobytes())
        self.assertEqual(data[:64], bytes([0x7b])*64)
        self.assertEqual(data[4160:], bytes([0x7b])*64)
        self.assertEqual(data[64+ui.tile_offset(40, 0, 38, 2)], 0x7b)

    def test_bc4_patch_preserves_unedited_compressed_blocks(self):
        texture = dict(fmt=0x1d01, width=8, height=8, tile=0, size=512, data=0)
        data = bytearray(512)
        for y in range(2):
            for x in range(2):
                at = ui.tile_offset(x*8, y, 16, 0)
                data[at:at+8] = bytes([60, 60])+bytes(6)
        before = bytes(data)
        picture = ui.image(data, texture)
        picture.paste(220, (0, 0, 4, 4))
        ui.write_image(data, texture, picture)
        self.assertEqual(ui.image(data, texture).tobytes(), picture.tobytes())
        changed = ui.tile_offset(0, 0, 16, 0)
        self.assertEqual(data[changed+8:], before[changed+8:])

    def test_controller_art_keeps_its_aspect_ratio(self):
        result = ui.fitted(Image.new('RGBA', (580, 340), 'white'), (576, 288))
        x0, y0, x1, y1 = result.getbbox()
        self.assertAlmostEqual((x1-x0)/(y1-y0), 580/340, delta=.01)

    def test_font_obfuscation_decodes_to_font_payload(self):
        payload = b'\0\1\0\0abcdefgh'
        source = bytes(8)+b''.join(struct.pack('>I', int.from_bytes(payload[i:i+4], 'big') ^ 0x49621806)
                                     for i in range(0, len(payload), 4))
        self.assertEqual(ui.decode_font(source), payload)

    def test_layout_adjustment_preserves_labels_and_section_sizes(self):
        header = bytearray(20)
        header[:6] = b'FLYT\xff\xfe'
        struct.pack_into('<H', header, 6, 20)
        def section(kind, name):
            data = bytearray(100)
            data[:4] = kind
            struct.pack_into('<I', data, 4, len(data))
            data[8] = 1
            data[12:12+len(name)] = name.encode()
            return data
        text = section(b'txt1', 'T_ChineseLabel')
        line = section(b'pic1', 'P_Line_01')
        picture = section(b'pic1', 'P_NNillust_01')
        materials = bytearray(60)
        materials[:4] = b'mat1'
        struct.pack_into('<I', materials, 4, len(materials))
        struct.pack_into('<H', materials, 8, 1)
        struct.pack_into('<I', materials, 12, 16)
        materials[16:25] = b'P_Line_01'
        materials[56:60] = bytes((0, 72, 255, 255))
        original = bytes(header+text+line+picture+materials)
        result = ui.adapt_layout(original)
        self.assertEqual(result[:120], original[:120])
        self.assertEqual(len(result), len(original))
        self.assertEqual(result[128]&1, 1)
        width, height = struct.unpack_from('<ff', result, 220+76)
        self.assertAlmostEqual(width/height, 288/168, places=5)
        self.assertEqual(result[-4:], bytes((255, 252, 198, 255)))

    def test_control_anchors_follow_both_illustrations_and_mirrored_groups(self):
        left = ui.control_point((215, 166))
        right = ui.control_point((360, 166))
        self.assertLess(left[0], 0)
        self.assertGreater(right[0], 0)
        self.assertAlmostEqual(left[1], right[1])
        self.assertLess(ui.control_point((165, 31), True)[1], -130)
        self.assertEqual(ui.inverse_point((-1, 0, 0, 1, 123, 27), (80, 40)), (43, 13))


if __name__ == '__main__':
    unittest.main()

"""python -m unittest tools/velo_import/test_import.py  (from the velo folder): converts tests/fixtures/import."""

import pathlib
import re
import subprocess
import sys
import tempfile
import unittest

VELO = pathlib.Path(__file__).resolve().parents[2]
FIX = VELO / "tests" / "fixtures" / "import"


def convert(engine, src, out):
    subprocess.run([sys.executable, str(VELO / "tools" / "import_assets.py"), engine, str(src), "--assets", str(out)],
                   check=True, capture_output=True, text=True)


def field(scene, node, name):
    block = re.search(r"node " + node + r" \{(.*?)\n\s*(node|\})", scene, re.S).group(1)
    m = re.search(r"\b" + name + r" = (\[[^\]]*\]|\"[^\"]*\"|@asset\(\"[^\"]*\"\)|\S+)", block)
    return m.group(1) if m else None


class ImportTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.out = pathlib.Path(cls.tmp.name)
        convert("unity", FIX / "unity", cls.out)
        cls.unity_report = (cls.out / "prefabs/imported/import_report.md").read_text(encoding="utf-8")
        convert("godot", FIX / "godot", cls.out)
        convert("tiled", FIX / "tiled", cls.out)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_unity_particles(self):
        s = (self.out / "prefabs/imported/Fire.scene").read_text(encoding="utf-8")
        self.assertEqual(field(s, "Fire", "angle"), "-90")  # cone rotated X -90 points up
        self.assertEqual(field(s, "Fire", "rate"), "40")
        self.assertEqual(field(s, "Fire", "lifetime"), "1")
        self.assertEqual(field(s, "Fire", "lifetime_var"), "0.2")
        self.assertEqual(field(s, "Fire", "start_size"), "40")
        self.assertEqual(field(s, "Fire", "end_size"), "8")
        self.assertEqual(field(s, "Fire", "gravity"), "[0, -98.1]")
        self.assertEqual(field(s, "Fire", "additive"), "true")
        self.assertEqual(field(s, "Fire", "mid_time"), "0.3")
        self.assertEqual(field(s, "Fire", "texture"), '@asset("imported/unity/Fx/spark.png")')
        self.assertEqual(field(s, "Sparks", "burst"), "30")
        self.assertEqual(field(s, "Sparks", "spread"), "180")
        self.assertIn("Noise module not supported", self.unity_report)

    def test_unity_sprite(self):
        s = (self.out / "prefabs/imported/Fire.scene").read_text(encoding="utf-8")
        self.assertEqual(field(s, "Coin", "position"), "[-100, -50]")
        self.assertEqual(field(s, "Coin", "rotation"), "-45")
        self.assertEqual(field(s, "Coin", "frame"), "1")
        self.assertEqual(field(s, "Coin", "size"), "[100, 100]")  # 16 px at 16 ppu -> 1 unit -> 100 px
        meta = (self.out / "imported/unity/Fx/coins.png.meta").read_text()
        self.assertIn("filter: nearest", meta)
        self.assertIn("frame_width: 16", meta)

    def test_godot4(self):
        s = (self.out / "prefabs/imported/campfire.scene").read_text(encoding="utf-8")
        self.assertEqual(field(s, "Flames", "rate"), "40")
        self.assertEqual(field(s, "Flames", "speed"), "90")
        self.assertEqual(field(s, "Flames", "additive"), "true")
        self.assertEqual(field(s, "Flames", "start_size"), "12")  # 16 px frame * 0.75 * curve 1
        self.assertEqual(field(s, "Flames", "end_size"), "3")
        self.assertEqual(field(s, "Flames", "mid_color"), "[255, 102, 0, 255]")
        self.assertEqual(field(s, "Embers", "shape_size"), "[80, 10]")
        self.assertEqual(field(s, "Embers", "spin"), "135")
        self.assertEqual(field(s, "Logo", "rotation"), "45")
        self.assertIn("frame_width: 16", (self.out / "imported/godot/fx/flip.png.meta").read_text())

    def test_tiled_isometric_tmx(self):
        s = (self.out / "prefabs/imported/iso_room.scene").read_text(encoding="utf-8")
        self.assertIn('layout = "isometric"', s)
        self.assertIn("tile_size = [32, 16]", s)
        # gid 6|H -> frame 5 + flip_x, 1|D|H -> 0 + transpose + flip_x, 3|V -> 2 + flip_y
        self.assertIn(f"tiles = [0, 1, -1, {5 | 1 << 24}, 5, -1, {(1 << 26) | (1 << 24)}, -1, {2 | 1 << 25}]", s)
        self.assertIn("animations = [2, 2, 4]", s)  # tile 2 -> 3 at 250 ms
        self.assertIn("TileMapCollider { solid_tiles = [5] }", s)
        self.assertEqual(field(s, "PlayerStart", "position"), "[56, 12]")  # grid space -> screen

    def test_tiled_orthogonal_tmj(self):
        s = (self.out / "prefabs/imported/level.scene").read_text(encoding="utf-8")
        self.assertIn("tiles = [2, " + "-1, " * 17 + "5, 5, 5, 5, 5, 5]", s)  # base64 + zlib layer
        self.assertEqual(field(s, "Fade", "color"), "[255, 255, 255, 128]")  # layer opacity
        self.assertEqual(s.count("TileMapCollider {"), 1)  # only the layer that uses tile 5
        self.assertEqual(field(s, "Door", "position"), "[40, 32]")  # rectangle centre
        self.assertEqual(field(s, "Chest", "frame"), "6")
        from PIL import Image
        self.assertEqual(Image.open(self.out / "imported/tiled/tiles_spaced_packed.png").size, (64, 64))

    def test_godot3(self):
        s = (self.out / "prefabs/imported/old_burst.scene").read_text(encoding="utf-8")
        self.assertIn("burst = 30", s)
        self.assertIn("looping = false", s)
        self.assertIn("speed = 112.5", s)
        self.assertIn("gravity = [0, 98]", s)


if __name__ == "__main__":
    unittest.main()

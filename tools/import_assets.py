"""Convert Unity or Godot content into Velo prefab scenes + assets.

    python tools/import_assets.py unity <Prefab.prefab | Scene.unity | folder> --assets <velo assets dir> [--ppu 100]
    python tools/import_assets.py godot <scene.tscn | folder> --assets <velo assets dir>
    python tools/import_assets.py tiled <map.tmj | map.tmx | folder> --assets <velo assets dir>

Each converted file becomes <assets>/<--prefabs, default prefabs/imported>/<name>.scene; the textures, Spine files
and so on it uses are copied under <assets>/<--subdir, default imported/<unity|godot>>/ keeping their project
paths, with .meta files (filter, sprite sheet frame size). A report of every approximation is printed and saved
as import_report.md next to the prefabs. Use a prefab in a scene with `node Fx from @asset("prefabs/imported/x.scene") { }`.

Converted:
  Unity  GameObject tree (position / rotation / scale / active / sorting order), ParticleSystem (main, emission,
         shape, size / colour / rotation over lifetime, texture sheet animation, renderer material texture and
         additive blending), SpriteRenderer (sprite sheets with regular grids), spine-unity SkeletonAnimation
         (Spine 4.2 JSON + atlas + pages -> Kine2D)
  Godot  Node2D tree, Sprite2D / Sprite (hframes / vframes), CPUParticles2D, GPUParticles2D / Particles2D with
         ParticleProcessMaterial / ParticlesMaterial, CanvasItemMaterial additive + particle animation,
         gradients and scale curves; Godot 3 and 4 files
  Tiled  .tmj / .tmx maps (orthogonal, isometric, staggered, hexagonal): one TileMap per tile layer and tileset,
         flips / rotations, tile animations, tiles with collision shapes -> TileMapCollider, groups, layer
         opacity / offset, object layers -> nodes (tile objects -> Sprites), tilesets with spacing repacked
Unity units become pixels with --ppu (pixels per unit). Requires PyYAML for Unity files.
"""

import argparse
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from velo_import.common import Report  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("engine", choices=["unity", "godot", "tiled"])
    ap.add_argument("source", help="a file, or a folder to convert every prefab / scene in")
    ap.add_argument("--assets", required=True, help="the Velo game's assets folder")
    ap.add_argument("--prefabs", default="prefabs/imported", help="where the converted scenes go (within assets)")
    ap.add_argument("--subdir", default=None, help="where copied files go (within assets)")
    ap.add_argument("--ppu", type=float, default=100, help="Unity: pixels per unit")
    a = ap.parse_args()

    src = pathlib.Path(a.source)
    assets = pathlib.Path(a.assets)
    report = Report()
    subdir = a.subdir or f"imported/{a.engine}"
    if a.engine == "unity":
        from velo_import.unity import UnityImporter

        exts = (".prefab", ".unity")
        imp = UnityImporter(src, assets, subdir, a.ppu, report)
    elif a.engine == "godot":
        from velo_import.godot import GodotImporter

        exts = (".tscn",)
        imp = GodotImporter(src, assets, subdir, report)
    else:
        from velo_import.tiled import TiledImporter

        exts = (".tmj", ".tmx")
        imp = TiledImporter(src, assets, subdir, report)
    files = [src] if src.is_file() else sorted(p for p in src.rglob("*") if p.suffix in exts)
    if not files:
        sys.exit(f"nothing to convert in {src}")
    done = 0
    for f in files:
        out = assets / a.prefabs / (f.stem + ".scene")
        print(f"{f.name} -> {out.relative_to(assets).as_posix()}")
        try:
            if imp.convert_file(f, out) is not None:
                done += 1
        except Exception as e:  # keep going with the other files
            report.warn(f"{f.name}: failed: {e!r}")
    rp = assets / a.prefabs / "import_report.md"
    rp.parent.mkdir(parents=True, exist_ok=True)
    rp.write_text("# Import report\n\n" + f"{done} of {len(files)} files converted from {a.engine} ({src}).\n\n## Converted\n\n"
                  + "\n".join(f"- {x}" for x in report.lines) + "\n\n## Approximations / not converted\n\n"
                  + ("\n".join(f"- {x}" for x in report.warnings) or "- none") + "\n", encoding="utf-8")
    print(f"{done}/{len(files)} converted, {len(report.warnings)} warnings -> {rp.as_posix()}")


if __name__ == "__main__":
    main()

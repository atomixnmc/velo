"""Tiled (mapeditor.org) -> Velo: .tmj (JSON) and .tmx (XML) maps become a scene with one TileMap per tile layer
(and per tileset the layer uses), object layers become nodes, tile animations, flips and per-tile collision come
along.

Layouts: orthogonal, isometric, staggered (stagger axis y) and hexagonal (axis y -> hex_pointy, x -> hex_flat).
Tile layer data may be CSV, plain arrays or base64 (uncompressed, zlib or gzip).
"""

import base64
import gzip
import json
import pathlib
import xml.etree.ElementTree as ET
import zlib

from .common import AssetCopier, Color, Node, Ref, write_scene

FLIP_H = 0x80000000
FLIP_V = 0x40000000
FLIP_D = 0x20000000
ROT_HEX = 0x10000000
GID_MASK = 0x0FFFFFFF

# Velo TileMap flip bits (render/tilemap.v)
V_FLIP_X = 1 << 24
V_FLIP_Y = 1 << 25
V_TRANSPOSE = 1 << 26


def _num(v, d=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return d


# ---------- reading TMX into the TMJ shape ----------

def _props(el):
    return {p.get("name"): p.get("value") for p in el.findall("./properties/property")}


def _tsx(path):
    root = ET.parse(path).getroot()
    return _tileset_el(root, path.parent)


def _tileset_el(el, base):
    ts = {k: (_num(v) if k in ("tilewidth", "tileheight", "spacing", "margin", "tilecount", "columns") else v)
          for k, v in el.attrib.items()}
    img = el.find("image")
    if img is not None:
        ts["image"] = img.get("source")
        ts["imagewidth"] = _num(img.get("width"))
        ts["imageheight"] = _num(img.get("height"))
    ts["_base"] = str(base)
    tiles = []
    for t in el.findall("tile"):
        tile = {"id": int(t.get("id"))}
        anim = t.find("animation")
        if anim is not None:
            tile["animation"] = [{"tileid": int(f.get("tileid")), "duration": int(f.get("duration"))}
                                 for f in anim.findall("frame")]
        og = t.find("objectgroup")
        if og is not None and len(og.findall("object")):
            tile["objectgroup"] = {"objects": [dict(o.attrib) for o in og.findall("object")]}
        tiles.append(tile)
    ts["tiles"] = tiles
    return ts


def _layer_data(el, width, height):
    data = el.find("data")
    if data is None:
        return []
    enc = data.get("encoding")
    comp = data.get("compression")
    if data.findall("chunk"):
        raise ValueError("infinite maps (chunks) are not supported; uncheck 'Infinite' in Tiled")
    if enc == "csv":
        return [int(x) for x in data.text.replace("\n", "").split(",") if x.strip()]
    if enc == "base64":
        return _decode_b64(data.text.strip(), comp)
    return [int(t.get("gid", 0)) for t in data.findall("tile")]


def _decode_b64(text, comp):
    raw = base64.b64decode(text)
    if comp == "zlib":
        raw = zlib.decompress(raw)
    elif comp == "gzip":
        raw = gzip.decompress(raw)
    elif comp:
        raise ValueError(f"layer compression {comp} is not supported (use CSV, zlib or gzip)")
    return [int.from_bytes(raw[i:i + 4], "little") for i in range(0, len(raw), 4)]


def _layers_el(parent, w, h):
    out = []
    for el in parent:
        common = {"name": el.get("name", ""), "visible": el.get("visible", "1") != "0",
                  "opacity": _num(el.get("opacity"), 1), "offsetx": _num(el.get("offsetx")),
                  "offsety": _num(el.get("offsety")), "properties": _props(el)}
        if el.tag == "layer":
            out.append({**common, "type": "tilelayer", "width": int(el.get("width", w)),
                        "height": int(el.get("height", h)), "data": _layer_data(el, w, h)})
        elif el.tag == "objectgroup":
            objs = []
            for o in el.findall("object"):
                d = {k: (_num(v) if k in ("x", "y", "width", "height", "rotation", "gid") else v) for k, v in o.attrib.items()}
                if o.find("point") is not None:
                    d["point"] = True
                if o.find("ellipse") is not None:
                    d["ellipse"] = True
                if o.find("polygon") is not None or o.find("polyline") is not None:
                    d["polygon"] = True
                objs.append(d)
            out.append({**common, "type": "objectgroup", "objects": objs})
        elif el.tag == "group":
            out.append({**common, "type": "group", "layers": _layers_el(el, w, h)})
        elif el.tag == "imagelayer":
            img = el.find("image")
            out.append({**common, "type": "imagelayer", "image": img.get("source") if img is not None else ""})
    return out


def load_map(path):
    path = pathlib.Path(path)
    if path.suffix in (".tmj", ".json"):
        m = json.loads(path.read_text(encoding="utf-8"))
        for ts in m.get("tilesets", []):
            ts["_base"] = str(path.parent)
            if "source" in ts:
                src = path.parent / ts["source"]
                ext = json.loads(src.read_text(encoding="utf-8")) if src.suffix in (".tsj", ".json") else _tsx(src)
                ext["_base"] = str(src.parent)
                first = ts["firstgid"]
                ts.clear()
                ts.update(ext)
                ts["firstgid"] = first
        for layer in _walk(m.get("layers", [])):
            if layer.get("type") == "tilelayer" and isinstance(layer.get("data"), str):
                layer["data"] = _decode_b64(layer["data"], layer.get("compression"))
            if layer.get("chunks"):
                raise ValueError("infinite maps (chunks) are not supported; uncheck 'Infinite' in Tiled")
        return m
    root = ET.parse(path).getroot()
    m = {k: (int(v) if k in ("width", "height", "tilewidth", "tileheight", "hexsidelength") else v) for k, v in root.attrib.items()}
    tilesets = []
    for ts in root.findall("tileset"):
        first = int(ts.get("firstgid"))
        if ts.get("source"):
            src = path.parent / ts.get("source")
            t = json.loads(src.read_text(encoding="utf-8")) if src.suffix in (".tsj", ".json") else _tsx(src)
            t["_base"] = str(src.parent)
        else:
            t = _tileset_el(ts, path.parent)
        t["firstgid"] = first
        tilesets.append(t)
    m["tilesets"] = tilesets
    m["layers"] = _layers_el(root, m["width"], m["height"])
    return m


def _walk(layers):
    for layer in layers:
        yield layer
        if layer.get("type") == "group":
            yield from _walk(layer.get("layers", []))


# ---------- converter ----------

class TiledImporter:
    def __init__(self, src, out_assets, subdir, report):
        self.src = pathlib.Path(src)
        self.report = report
        self.copier = AssetCopier(out_assets, subdir, report)
        self.root_dir = self.src if self.src.is_dir() else self.src.parent
        self.ts_keys = {}  # tileset image -> asset key

    def layout(self, m):
        o = m.get("orientation", "orthogonal")
        axis = m.get("staggeraxis", "y")
        odd = m.get("staggerindex", "odd") == "odd"
        if o == "orthogonal":
            return {"layout": "orthogonal"}
        if o == "isometric":
            return {"layout": "isometric"}
        if o == "staggered":
            if axis == "x":
                self.report.warn("staggered map with stagger axis X: Velo staggers rows (axis Y); drawn as Y")
            return {"layout": "staggered", "stagger_odd": odd}
        if o == "hexagonal":
            f = {"layout": "hex_flat" if axis == "x" else "hex_pointy", "stagger_odd": odd}
            if m.get("hexsidelength"):
                f["hex_side"] = float(m["hexsidelength"])
            return f
        self.report.warn(f"orientation {o} drawn as orthogonal")
        return {"layout": "orthogonal"}

    def tileset_texture(self, ts):
        if "image" in ts:
            k = str((pathlib.Path(ts["_base"]) / ts["image"]).resolve())
            if k not in self.ts_keys:
                self.ts_keys[k] = self._tileset_texture(ts)
            return self.ts_keys[k]
        return self._tileset_texture(ts)

    def _tileset_texture(self, ts):
        if "image" not in ts:
            self.report.warn(f"tileset {ts.get('name')}: image-collection tilesets are not supported (pack the "
                             "images into one sheet)")
            return None
        img = pathlib.Path(ts["_base"]) / ts["image"]
        sp, mg = int(_num(ts.get("spacing"))), int(_num(ts.get("margin")))
        tw, th = int(_num(ts.get("tilewidth"))), int(_num(ts.get("tileheight")))
        try:
            rel = str(img.resolve().relative_to(self.root_dir.resolve())).replace("\\", "/")
        except ValueError:
            rel = img.name
        if sp or mg:
            img, rel = self.repack(img, rel, ts, tw, th, sp, mg)
        return self.copier.texture(img, rel, filter="nearest", frame=(tw, th))

    def repack(self, img, rel, ts, tw, th, sp, mg):
        """Velo sheets have no spacing / margin: write a copy with the tiles packed edge to edge"""
        try:
            from PIL import Image
        except ImportError:
            self.report.warn(f"{img.name}: tileset has spacing/margin; install Pillow to repack it (tiles will be offset)")
            return img, rel
        src = Image.open(img).convert("RGBA")
        cols = int(_num(ts.get("columns"))) or max(1, (src.width - 2 * mg + sp) // (tw + sp))
        count = int(_num(ts.get("tilecount"))) or cols * max(1, (src.height - 2 * mg + sp) // (th + sp))
        rows = (count + cols - 1) // cols
        out = Image.new("RGBA", (cols * tw, rows * th))
        for i in range(count):
            c, r = i % cols, i // cols
            x, y = mg + c * (tw + sp), mg + r * (th + sp)
            out.paste(src.crop((x, y, x + tw, y + th)), (c * tw, r * th))
        packed = pathlib.Path(self.copier.root) / self.copier.subdir / (pathlib.PurePosixPath(rel).with_suffix("").as_posix() + "_packed.png")
        packed.parent.mkdir(parents=True, exist_ok=True)
        out.save(packed)
        self.report.info(f"{img.name}: spacing {sp} / margin {mg} removed -> {packed.name}")
        return packed, pathlib.PurePosixPath(rel).with_suffix("").as_posix() + "_packed.png"

    def animations(self, ts):
        out = []
        for t in ts.get("tiles", []) or []:
            frames = t.get("animation") or []
            if len(frames) < 2:
                continue
            ids = [f["tileid"] for f in frames]
            durs = {f["duration"] for f in frames}
            if ids != list(range(ids[0], ids[0] + len(ids))) or t["id"] != ids[0]:
                self.report.warn(f"tileset {ts.get('name')}: tile {t['id']} animation is not consecutive frames "
                                 "starting at itself; skipped")
                continue
            if len(durs) > 1:
                self.report.warn(f"tileset {ts.get('name')}: tile {t['id']} animation has uneven durations; averaged")
            fps = max(1, round(1000 * len(frames) / sum(f["duration"] for f in frames)))
            out += [ids[0], len(ids), fps]
        return out

    def solid_tiles(self, ts):
        return [t["id"] for t in ts.get("tiles", []) or [] if (t.get("objectgroup") or {}).get("objects")]

    def convert_file(self, path, out_scene):
        m = load_map(path)
        path = pathlib.Path(path)
        if str(m.get("infinite", "0")).lower() in ("1", "true"):
            raise ValueError("infinite maps are not supported; uncheck 'Infinite' in Tiled")
        lay = self.layout(m)
        tw, th = float(m["tilewidth"]), float(m["tileheight"])
        tilesets = sorted(m.get("tilesets", []), key=lambda t: t["firstgid"])
        root = Node(path.stem)
        any_solid = False
        z = 0

        def ts_of(gid):
            found = None
            for ts in tilesets:
                if ts["firstgid"] <= gid:
                    found = ts
            return found

        def add_layers(layers, parent):
            nonlocal z, any_solid
            for layer in layers:
                kind = layer.get("type")
                name = layer.get("name") or kind
                n = Node(name)
                n.position = (_num(layer.get("offsetx")), _num(layer.get("offsety")))
                n.active = layer.get("visible", True) is not False
                alpha = _num(layer.get("opacity"), 1)
                if kind == "group":
                    add_layers(layer.get("layers", []), n)
                    parent.children.append(n)
                    continue
                z += 1
                n.z_index = z
                if kind == "tilelayer":
                    w, h = int(layer.get("width", m["width"])), int(layer.get("height", m["height"]))
                    data = layer.get("data") or []
                    used = {}
                    for gid in data:
                        g = gid & GID_MASK
                        if g:
                            ts = ts_of(g)
                            if ts is not None:
                                used[ts["firstgid"]] = ts
                    for fg, ts in sorted(used.items()):
                        key = self.tileset_texture(ts)
                        if key is None:
                            continue
                        tiles = []
                        for gid in data:
                            g = gid & GID_MASK
                            if not g or ts_of(g) is not ts:
                                tiles.append(-1)
                                continue
                            v = g - fg
                            if gid & FLIP_H:
                                v |= V_FLIP_X
                            if gid & FLIP_V:
                                v |= V_FLIP_Y
                            if gid & FLIP_D:
                                v |= V_TRANSPOSE
                            if gid & ROT_HEX:
                                self.report.warn(f"{name}: hexagonal 120-degree tile rotation ignored")
                            tiles.append(v)
                        if int(_num(ts.get("tileheight"))) != int(th) or int(_num(ts.get("tilewidth"))) != int(tw):
                            self.report.warn(f"{name}: tileset {ts.get('name')} tiles are {int(_num(ts.get('tilewidth')))}x"
                                             f"{int(_num(ts.get('tileheight')))}, the map's cells {int(tw)}x{int(th)}: "
                                             "Velo draws each tile into its cell (taller art is squeezed)")
                        f = {"tileset": Ref(key), "columns": w, "rows": h, "tile_size": (tw, th), **lay, "tiles": tiles}
                        frames_used = {t & 0xFFFFFF for t in tiles if t >= 0}
                        anims = self.animations(ts)
                        anims = [x for i in range(0, len(anims), 3) if anims[i] in frames_used for x in anims[i:i + 3]]
                        if anims:
                            f["animations"] = anims
                        if alpha < 1:
                            f["color"] = Color(255, 255, 255, alpha * 255)
                        target = n if len(used) == 1 else Node(f"{name}_{ts.get('name', fg)}")
                        target.add("TileMap", f)
                        solid = self.solid_tiles(ts)
                        if solid and frames_used & set(solid):
                            target.add("TileMapCollider", {"solid_tiles": solid})
                            any_solid = True
                        if target is not n:
                            target.z_index = z
                            n.children.append(target)
                    parent.children.append(n)
                    self.report.info(f"tile layer {name}: {w}x{h}, {len(used)} tileset(s)")
                elif kind == "objectgroup":
                    for o in layer.get("objects", []):
                        on = Node(o.get("name") or o.get("type") or o.get("class") or f"Object{o.get('id', '')}")
                        x, y = _num(o.get("x")), _num(o.get("y"))
                        ow, oh = _num(o.get("width")), _num(o.get("height"))
                        gid = int(_num(o.get("gid")))
                        if gid:
                            g = gid & GID_MASK
                            ts = ts_of(g)
                            key = self.tileset_texture(ts) if ts else None
                            if key:
                                sf = {"texture": Ref(key), "frame": g - ts["firstgid"], "anchor": (0.0, 1.0)}
                                if ow and oh:
                                    sf["size"] = (ow, oh)
                                if gid & FLIP_H:
                                    sf["flip_x"] = True
                                if gid & FLIP_V:
                                    sf["flip_y"] = True
                                on.add("Sprite", sf)
                        else:
                            if ow or oh:
                                on.comments.append(f"Tiled {'ellipse' if o.get('ellipse') else 'rectangle'} {ow:g} x {oh:g}"
                                                   + (f", type {o.get('type') or o.get('class')}" if (o.get('type') or o.get('class')) else ""))
                                x, y = x + ow / 2, y + oh / 2  # the node sits at the shape's centre
                            if o.get("polygon"):
                                on.comments.append("Tiled polygon / polyline (points not converted)")
                        if m.get("orientation") == "isometric":
                            # Tiled keeps isometric objects in grid space (tile height units on both axes)
                            gx, gy = x / th, y / th
                            x, y = (int(m["height"]) + gx - gy) * tw / 2, (gx + gy) * th / 2
                        on.position = (x, y)
                        on.rotation = _num(o.get("rotation"))
                        if o.get("visible") is False:
                            on.active = False
                        n.children.append(on)
                    parent.children.append(n)
                    self.report.info(f"object layer {name}: {len(layer.get('objects', []))} objects")
                elif kind == "imagelayer":
                    img = pathlib.Path(path.parent) / layer.get("image", "")
                    if img.exists():
                        key = self.copier.copy(img, img.name)
                        n.add("Sprite", {"texture": Ref(key), "anchor": (0.0, 0.0)})
                        parent.children.append(n)
                else:
                    self.report.warn(f"layer {name}: type {kind} skipped")

        add_layers(m.get("layers", []), root)
        if any_solid:
            root.comments.append("tiles with collision shapes in Tiled get a TileMapCollider: the scene needs a "
                                 "PhysicsWorld on this node or an ancestor")
        write_scene(root, out_scene, f"Converted from Tiled: {path.name} (tools/velo_import)\n"
                    f"{m['width']}x{m['height']} cells of {int(tw)}x{int(th)}, orientation {m.get('orientation')}")
        self.copier.finish()
        return root

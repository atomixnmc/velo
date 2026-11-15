"""Shared pieces of the Unity / Godot importers: the Velo .scene writer, texture metas, asset copying."""

import os
import pathlib
import random
import shutil
import struct


class Report:
    """What was converted, and what could not be (printed at the end, also written next to the output)."""

    def __init__(self):
        self.lines = []
        self.warnings = []

    def info(self, msg):
        self.lines.append(msg)
        print("  " + msg)

    def warn(self, msg):
        if msg not in self.warnings:
            self.warnings.append(msg)
            print("  WARN " + msg)


def image_size(path):
    """(width, height) of a PNG / JPEG / anything Pillow reads; (0, 0) when unknown."""
    p = pathlib.Path(path)
    try:
        with open(p, "rb") as f:
            head = f.read(32)
        if head[:8] == b"\x89PNG\r\n\x1a\n":
            return struct.unpack(">II", head[16:24])
    except OSError:
        return 0, 0
    try:
        from PIL import Image  # optional

        with Image.open(p) as im:
            return im.size
    except Exception:
        return 0, 0


def fmt_num(v):
    v = float(v)
    if abs(v - round(v)) < 1e-4:
        return str(int(round(v)))
    return f"{v:.4f}".rstrip("0").rstrip(".")


def fmt_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return fmt_num(v)
    if isinstance(v, Ref):
        return f'@asset("{v.key}")'
    if isinstance(v, Color):
        return f"[{v.r}, {v.g}, {v.b}, {v.a}]"
    if isinstance(v, (tuple, list)):
        return "[" + ", ".join(fmt_num(x) for x in v) + "]"
    s = str(v).replace("\\", "\\\\").replace('"', '\\"')
    return f'"{s}"'


class Ref:
    """An asset reference written as @asset("path within the assets folder")."""

    def __init__(self, key):
        self.key = key


class Color:
    def __init__(self, r, g, b, a=255):
        self.r, self.g, self.b, self.a = (max(0, min(255, int(round(x)))) for x in (r, g, b, a))

    @staticmethod
    def from_float(c):
        """from a dict / tuple of 0..1 floats"""
        if isinstance(c, dict):
            c = (c.get("r", 1), c.get("g", 1), c.get("b", 1), c.get("a", 1))
        r, g, b = c[0], c[1], c[2]
        a = c[3] if len(c) > 3 else 1
        return Color(r * 255, g * 255, b * 255, a * 255)

    def mul(self, o):
        return Color(self.r * o.r / 255, self.g * o.g / 255, self.b * o.b / 255, self.a * o.a / 255)

    def lerp(self, o, t):
        return Color(*(a + (b - a) * t for a, b in zip(self.tuple(), o.tuple())))

    def tuple(self):
        return (self.r, self.g, self.b, self.a)

    def __eq__(self, o):
        return isinstance(o, Color) and self.tuple() == o.tuple()


class Node:
    """A Velo scene node: transform, components (name -> {field: value}), children."""

    def __init__(self, name):
        self.name = name
        self.position = (0.0, 0.0)
        self.rotation = 0.0
        self.scale = (1.0, 1.0)
        self.z_index = 0
        self.active = True
        self.components = []  # (type, {field: value})
        self.children = []
        self.comments = []

    def add(self, ctype, fields):
        self.components.append((ctype, fields))


def safe_name(name):
    out = "".join(ch if ch.isalnum() or ch == "_" else "_" for ch in (name or "Node"))
    if not out or out[0].isdigit():
        out = "N" + out
    return out


def write_scene(root, path, header):
    lines = [f"# {h}" for h in header.splitlines()]

    def emit(n, d):
        ind = "  " * d
        lines.append(f"{ind}node {safe_name(n.name)} {{")
        for c in n.comments:
            lines.append(f"{ind}  # {c}")
        if n.position != (0.0, 0.0):
            lines.append(f"{ind}  position = {fmt_value(n.position)}")
        if abs(n.rotation) > 1e-3:
            lines.append(f"{ind}  rotation = {fmt_num(n.rotation)}")
        if n.scale != (1.0, 1.0):
            lines.append(f"{ind}  scale = {fmt_value(n.scale)}")
        if n.z_index:
            lines.append(f"{ind}  z_index = {n.z_index}")
        if not n.active:
            lines.append(f"{ind}  active = false")
        for ctype, fields in n.components:
            body = "  ".join(f"{k} = {fmt_value(v)}" for k, v in fields.items())
            lines.append(f"{ind}  {ctype} {{ {body} }}" if body else f"{ind}  {ctype} {{ }}")
        for ch in n.children:
            emit(ch, d + 1)
        lines.append(f"{ind}}}")

    emit(root, 0)
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")


def new_id(assets_root):
    """a fresh 8-hex asset id not used by any .meta under the assets folder"""
    used = set()
    for m in pathlib.Path(assets_root).rglob("*.meta"):
        try:
            first = m.read_text(encoding="utf-8").splitlines()[0]
            if first.startswith("id:"):
                used.add(first[3:].strip())
        except (OSError, IndexError):
            pass
    while True:
        i = f"{random.getrandbits(32):08x}"
        if i not in used:
            return i


def read_meta(path):
    meta = {}
    p = pathlib.Path(str(path) + ".meta")
    if p.exists():
        for line in p.read_text(encoding="utf-8").splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                meta[k.strip()] = v.strip()
    return meta


def write_meta(path, assets_root, kind, settings):
    """write / update `<path>.meta` keeping an existing id; settings with value None are removed"""
    meta = read_meta(path)
    mid = meta.get("id") or new_id(assets_root)
    meta.update({k: str(v) for k, v in settings.items() if v is not None})
    for k, v in settings.items():
        if v is None:
            meta.pop(k, None)
    out = [f"id: {mid}", f"kind: {kind}", f"version: {meta.get('version', '1')}"]
    out += [f"{k}: {v}" for k, v in meta.items() if k not in ("id", "kind", "version")]
    pathlib.Path(str(path) + ".meta").write_text("\n".join(out) + "\n", encoding="utf-8", newline="\n")
    return mid


class AssetCopier:
    """Copies source files into <assets>/<subdir>/..., once each, and returns their asset paths."""

    def __init__(self, assets_root, subdir, report):
        self.root = pathlib.Path(assets_root)
        self.subdir = subdir.strip("/")
        self.report = report
        self.done = {}  # source path -> asset key
        self.texture_settings = {}  # asset key -> settings

    def copy(self, src, rel_name=None, rename=None):
        src = pathlib.Path(src)
        key_src = str(src.resolve())
        if key_src in self.done:
            return self.done[key_src]
        rel = pathlib.PurePosixPath(self.subdir) / (rel_name or src.name)
        if rename:
            rel = rel.with_name(rename)
        dst = self.root / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        if not src.exists():
            self.report.warn(f"missing source file {src}")
        elif not dst.exists() or os.path.getmtime(src) > os.path.getmtime(dst) or dst.stat().st_size != src.stat().st_size:
            shutil.copy2(src, dst)
        key = str(rel)
        self.done[key_src] = key
        return key

    def texture(self, src, rel_name=None, filter=None, frame=None):
        """copy a texture and remember its import settings (filter, frame size of a sprite sheet)"""
        key = self.copy(src, rel_name)
        s = self.texture_settings.setdefault(key, {})
        if filter:
            s["filter"] = filter
        if frame and frame[0] > 0 and frame[1] > 0:
            old = s.get("frame")
            if old and old != frame:
                self.report.warn(f"{key}: used with frame sizes {old} and {frame}; keeping {old}")
            else:
                s["frame"] = frame
        return key

    def finish(self):
        for key, s in self.texture_settings.items():
            settings = {"filter": s.get("filter", "linear")}
            if "frame" in s:
                settings["frame_width"], settings["frame_height"] = s["frame"]
            write_meta(self.root / key, self.root, "texture", settings)

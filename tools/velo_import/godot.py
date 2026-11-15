"""Godot (3.x and 4.x) -> Velo: .tscn scenes (Node2D tree, Sprite2D / Sprite, CPUParticles2D, GPUParticles2D /
Particles2D with their process material) and the textures they use.

Godot 2D units are already pixels with y down, so positions copy over; rotations are converted to degrees.
Curves and gradients become start -> (mid ->) end values, min/max ranges become value +- var.
"""

import math
import pathlib
import re

from .common import AssetCopier, Color, Node, Ref, image_size, write_scene

# ---------- the text resource format ----------


class Call:
    """Constructor-style value: Vector2(1, 2), SubResource("id"), ExtResource(1), Color(...) ..."""

    def __init__(self, name, args):
        self.name = name
        self.args = args

    def __repr__(self):
        return f"{self.name}{tuple(self.args)}"


_NUM = re.compile(r"[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?")
_ID = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def parse_value(s, i=0):
    """(value, next index) of a Godot variant literal"""
    n = len(s)
    while i < n and s[i] in " \t\r\n,":
        i += 1
    if i >= n:
        return None, i
    c = s[i]
    if c == "&" or c == "^":  # StringName / NodePath prefix
        return parse_value(s, i + 1)
    if c == '"':
        j = i + 1
        out = []
        while j < n and s[j] != '"':
            if s[j] == "\\" and j + 1 < n:
                j += 1
            out.append(s[j])
            j += 1
        return "".join(out), j + 1
    if c == "[":
        items = []
        i += 1
        while True:
            while i < n and s[i] in " \t\r\n,":
                i += 1
            if i >= n or s[i] == "]":
                return items, i + 1
            v, i = parse_value(s, i)
            items.append(v)
    if c == "{":
        d = {}
        i += 1
        while True:
            while i < n and s[i] in " \t\r\n,":
                i += 1
            if i >= n or s[i] == "}":
                return d, i + 1
            k, i = parse_value(s, i)
            while i < n and s[i] in " \t:":
                i += 1
            v, i = parse_value(s, i)
            d[k] = v
    m = _NUM.match(s, i)
    if m and (c.isdigit() or c in "-+."):
        txt = m.group(0)
        return (float(txt) if any(ch in txt for ch in ".eE") else int(txt)), m.end()
    m = _ID.match(s, i)
    if m:
        name = m.group(0)
        j = m.end()
        while j < n and s[j] == " ":
            j += 1
        if j < n and s[j] == "(":
            args = []
            j += 1
            while True:
                while j < n and s[j] in " \t\r\n,":
                    j += 1
                if j >= n or s[j] == ")":
                    return Call(name, args), j + 1
                v, j = parse_value(s, j)
                args.append(v)
        word = {"true": True, "false": False, "null": None, "nan": float("nan"), "inf": float("inf")}
        return word.get(name, name), m.end()
    return None, i + 1


def _balanced(text):
    depth = 0
    in_str = False
    prev = ""
    for ch in text:
        if ch == '"' and prev != "\\":
            in_str = not in_str
        elif not in_str:
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth -= 1
        prev = ch
    return depth <= 0 and not in_str


class Section:
    def __init__(self, kind, attrs):
        self.kind = kind
        self.attrs = attrs
        self.props = {}


def parse_resource_file(path):
    """the [sections] of a .tscn / .tres file, each with its header attributes and properties"""
    sections = []
    cur = None
    pending = None
    for raw in pathlib.Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        if pending is not None:
            pending[1] += "\n" + raw
            if _balanced(pending[1]):
                cur.props[pending[0]] = parse_value(pending[1])[0]
                pending = None
            continue
        line = raw.strip()
        if not line or line.startswith(";"):
            continue
        if line.startswith("[") and line.endswith("]") and "=" not in line.split(" ")[0]:
            body = line[1:-1]
            kind, _, rest = body.partition(" ")
            attrs = {}
            for m in re.finditer(r'([A-Za-z_]+)=("(?:[^"\\]|\\.)*"|[A-Za-z_]+\([^)]*\)|[^\s]+)', rest):
                attrs[m.group(1)] = parse_value(m.group(2))[0]
            cur = Section(kind, attrs)
            sections.append(cur)
            continue
        if cur is None or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key, val = key.strip(), val.strip()
        if _balanced(val):
            cur.props[key] = parse_value(val)[0]
        else:
            pending = [key, val]
    return sections


def find_project(p):
    p = pathlib.Path(p).resolve()
    for d in [p] + list(p.parents):
        if (d / "project.godot").exists():
            return d
    return p.parent


def num(v, d=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return d


def vec(v, d=(0.0, 0.0)):
    if isinstance(v, Call) and v.name.startswith("Vector"):
        return tuple(num(a) for a in v.args)
    return d


def color(v, d=None):
    if isinstance(v, Call) and v.name == "Color":
        a = [num(x, 1) for x in v.args] + [1, 1, 1, 1]
        return Color.from_float(a[:4])
    return d or Color(255, 255, 255, 255)


# ---------- converter ----------

class GodotImporter:
    def __init__(self, src, out_assets, subdir, report):
        self.src = pathlib.Path(src)
        self.project = find_project(self.src)
        self.report = report
        self.out = pathlib.Path(out_assets)
        self.copier = AssetCopier(out_assets, subdir, report)
        self.default_filter = "linear"
        pg = self.project / "project.godot"
        if pg.exists():
            txt = pg.read_text(encoding="utf-8", errors="replace")
            if re.search(r"default_texture_filter\s*=\s*0", txt):
                self.default_filter = "nearest"
        report.info(f"Godot project: {self.project}")

    def res_path(self, p):
        if isinstance(p, str) and p.startswith("res://"):
            return self.project / p[6:]
        return self.src.parent / str(p)

    def convert_file(self, path, out_scene):
        secs = parse_resource_file(path)
        self.ext = {}
        self.sub = {}
        nodes = []
        for s in secs:
            if s.kind == "ext_resource":
                self.ext[str(s.attrs.get("id"))] = s
            elif s.kind == "sub_resource":
                self.sub[str(s.attrs.get("id"))] = s
            elif s.kind == "node":
                nodes.append(s)
        if not nodes:
            self.report.warn(f"{path}: no nodes")
            return None
        by_path = {}
        root = None
        for s in nodes:
            n = self.node_of(s)
            parent = s.attrs.get("parent")
            if parent is None:
                root = n
                by_path["."] = n
                continue
            pnode = by_path.get(str(parent))
            if pnode is None:
                self.report.warn(f"{n.name}: parent {parent} not found; attached to the root")
                pnode = root
            pnode.children.append(n)
            by_path[(n.name if parent == "." else f"{parent}/{n.name}")] = n
        root.name = pathlib.Path(path).stem
        root.position = (0.0, 0.0)
        write_scene(root, out_scene, f"Converted from Godot: {path.name if hasattr(path, 'name') else path} (tools/velo_import)\n"
                    "Approximations and unsupported settings are listed in the import report.")
        self.copier.finish()
        return root

    # ----- resources -----

    def resource(self, v):
        """the Section a SubResource(...) / ExtResource(...) points at"""
        if isinstance(v, Call) and v.args:
            key = str(v.args[0])
            if v.name == "SubResource":
                return self.sub.get(key)
            if v.name == "ExtResource":
                return self.ext.get(key)
        return None

    def texture(self, v, filt=None, frame=None):
        r = self.resource(v)
        if r is None:
            return None, (0, 0)
        if r.kind == "sub_resource" and r.attrs.get("type") == "AtlasTexture":
            self.report.warn("AtlasTexture region ignored (the whole atlas is used)")
            return self.texture(r.props.get("atlas"), filt, frame)
        p = self.res_path(r.attrs.get("path"))
        if not p.exists():
            self.report.warn(f"texture {r.attrs.get('path')} not found")
            return None, (0, 0)
        if filt is None:
            filt = self.default_filter
            imp = pathlib.Path(str(p) + ".import")
            if imp.exists() and re.search(r"flags/filter\s*=\s*false", imp.read_text(encoding="utf-8", errors="replace")):
                filt = "nearest"
        try:
            rel = str(p.resolve().relative_to(self.project.resolve())).replace("\\", "/")
        except ValueError:
            rel = p.name
        return self.copier.texture(p, rel, filter=filt, frame=frame), image_size(p)

    def gradient(self, v):
        """[(offset, Color)] of a Gradient / GradientTexture1D/2D"""
        r = self.resource(v)
        if r is None:
            return None
        if r.attrs.get("type") in ("GradientTexture1D", "GradientTexture", "GradientTexture2D"):
            return self.gradient(r.props.get("gradient"))
        offs = r.props.get("offsets")
        cols = r.props.get("colors")
        offs = [num(x) for x in (offs.args if isinstance(offs, Call) else (offs or [0, 1]))]
        cl = [num(x, 1) for x in (cols.args if isinstance(cols, Call) else (cols or [0, 0, 0, 1, 1, 1, 1, 1]))]
        keys = [(offs[i], Color.from_float(cl[i * 4:i * 4 + 4])) for i in range(min(len(offs), len(cl) // 4))]
        return sorted(keys, key=lambda k: k[0]) or None

    def curve(self, v):
        """[(x, y)] points of a Curve / CurveTexture"""
        r = self.resource(v)
        if r is None:
            return None
        if r.attrs.get("type") in ("CurveTexture", "CurveXYZTexture"):
            return self.curve(r.props.get("curve"))
        data = r.props.get("_data") or []
        pts = []
        if isinstance(data, list):
            for item in data:
                if isinstance(item, Call) and item.name == "Vector2":
                    pts.append((num(item.args[0]), num(item.args[1])))
        elif isinstance(data, dict):  # Godot 4 serialises {"points": [...]}
            raw = data.get("points") or []
            for k in range(0, len(raw), 7):
                pts.append((num(raw[k]), num(raw[k + 1])))
        return pts or None

    # ----- nodes -----

    def node_of(self, s):
        p = s.props
        t = s.attrs.get("type") or ""
        n = Node(s.attrs.get("name") or "Node")
        n.position = vec(p.get("position"), (0.0, 0.0))
        if "rotation" in p:
            n.rotation = math.degrees(num(p["rotation"]))
        if "rotation_degrees" in p:
            n.rotation = num(p["rotation_degrees"])
        n.scale = vec(p.get("scale"), (1.0, 1.0))
        n.z_index = int(num(p.get("z_index")))
        if p.get("visible") is False:
            n.active = False
        if "instance" in s.attrs:
            r = self.resource(s.attrs["instance"])
            self.report.warn(f"{n.name}: instanced scene {r.attrs.get('path') if r else '?'} not expanded (convert it on its own)")
        modulate = color(p.get("modulate")).mul(color(p.get("self_modulate")))
        filt = {1: "nearest", 2: "linear", 3: "nearest", 4: "linear"}.get(int(num(p.get("texture_filter"))))
        if t in ("Sprite2D", "Sprite"):
            self.sprite(n, p, modulate, filt)
        elif t in ("CPUParticles2D",):
            self.cpu_particles(n, p, modulate, filt)
        elif t in ("GPUParticles2D", "Particles2D"):
            self.gpu_particles(n, p, modulate, filt, godot3=(t == "Particles2D"))
        elif t in ("AnimatedSprite2D", "AnimatedSprite"):
            self.animated_sprite(n, p, modulate, filt)
        elif t == "SpineSprite":
            self.report.warn(f"{n.name}: spine-godot SpineSprite: point a Kine2D at the Spine 4.2 .json + .atlas by hand")
        elif t and t not in ("Node2D", "Node", "CanvasLayer", "Marker2D", "Position2D", "Control"):
            self.report.warn(f"{n.name}: {t} skipped")
        return n

    def sprite(self, n, p, modulate, filt):
        hf, vf = int(num(p.get("hframes"), 1)), int(num(p.get("vframes"), 1))
        key, (tw, th) = self.texture(p.get("texture"), filt)
        if not key:
            return
        if hf * vf > 1 and tw:
            self.copier.texture_settings[key]["frame"] = (tw // hf, th // vf)
        f = {"texture": Ref(key)}
        if hf * vf > 1:
            f["frame"] = int(num(p.get("frame")))
        if p.get("centered") is False:
            f["anchor"] = (0.0, 0.0)
        off = vec(p.get("offset"), (0.0, 0.0))
        if off != (0.0, 0.0):
            n.position = (n.position[0] + off[0], n.position[1] + off[1])
        if p.get("flip_h"):
            f["flip_x"] = True
        if p.get("flip_v"):
            f["flip_y"] = True
        if p.get("region_enabled"):
            self.report.warn(f"{n.name}: sprite region ignored")
        if modulate != Color(255, 255, 255, 255):
            f["color"] = modulate
        n.add("Sprite", f)

    def animated_sprite(self, n, p, modulate, filt):
        frames = self.resource(p.get("sprite_frames") or p.get("frames"))
        anims = (frames.props.get("animations") if frames else None) or []
        if not anims:
            self.report.warn(f"{n.name}: AnimatedSprite without frames")
            return
        first = anims[0].get("frames") or []
        tex = first[0].get("texture") if first and isinstance(first[0], dict) else (first[0] if first else None)
        key, _ = self.texture(tex, filt)
        if key:
            f = {"texture": Ref(key)}
            if modulate != Color(255, 255, 255, 255):
                f["color"] = modulate
            n.add("Sprite", f)
        self.report.warn(f"{n.name}: AnimatedSprite converted to its first frame (frames are separate textures; "
                         "pack them into a sheet for SpriteAnimator)")

    def particles_common(self, n, f, amount, lifetime, p):
        f["max_particles"] = max(1, amount)
        f["lifetime"] = max(lifetime, 0.01)
        lr = num(p.get("lifetime_randomness"))
        if lr > 0:
            f["lifetime_var"] = lifetime * lr / 2
            f["lifetime"] = lifetime * (1 - lr / 2)
        expl = num(p.get("explosiveness"))
        one_shot = bool(p.get("one_shot"))
        f["looping"] = not one_shot
        f["duration"] = lifetime
        f["playing"] = p.get("emitting", True) is not False
        if expl >= 0.99:
            f["burst"] = amount
            f["rate"] = 0
            if not one_shot:
                self.report.warn(f"{n.name}: looping explosive emitter bursts once")
        else:
            f["rate"] = amount / max(lifetime, 0.01)
            if expl > 0.01:
                self.report.warn(f"{n.name}: explosiveness {expl:g} approximated as a steady rate")
        if num(p.get("speed_scale"), 1) != 1:
            self.report.warn(f"{n.name}: speed_scale ignored")
        if num(p.get("preprocess")) > 0:
            self.report.warn(f"{n.name}: preprocess ignored")
        f["world_space"] = not bool(p.get("local_coords", False))

    def apply_motion(self, n, f, p, m, godot3):
        """direction, speed, gravity, spin ... shared by CPUParticles2D props and process materials"""
        d = vec(m.get("direction"), (1.0, 0.0, 0.0))
        f["angle"] = math.degrees(math.atan2(d[1], d[0]))
        f["spread"] = num(m.get("spread"), 45)
        if "initial_velocity_min" in m or "initial_velocity_max" in m:
            lo, hi = num(m.get("initial_velocity_min")), num(m.get("initial_velocity_max"))
        else:
            v = num(m.get("initial_velocity"))
            r = num(m.get("initial_velocity_random"))
            lo, hi = v * (1 - r), v
        f["speed"] = (lo + hi) / 2
        if hi != lo:
            f["speed_var"] = abs(hi - lo) / 2
        if "angular_velocity_min" in m or "angular_velocity_max" in m:
            a0, a1 = num(m.get("angular_velocity_min")), num(m.get("angular_velocity_max"))
        else:
            a1 = num(m.get("angular_velocity"))
            a0 = a1 * (1 - num(m.get("angular_velocity_random")))
        if a0 or a1:
            f["spin"] = (a0 + a1) / 2
            if a1 != a0:
                f["spin_var"] = abs(a1 - a0) / 2
        if "angle_min" in m or "angle_max" in m:
            if abs(num(m.get("angle_max")) - num(m.get("angle_min"))) > 1:
                f["random_angle"] = True
        elif num(m.get("angle_random")) > 0:
            f["random_angle"] = True
        damp = (num(m.get("damping_min")) + num(m.get("damping_max"))) / 2 if "damping_min" in m or "damping_max" in m else num(m.get("damping"))
        if damp > 0 and f["speed"] > 0:
            f["damping"] = min(damp / f["speed"], 5)
            self.report.warn(f"{n.name}: linear damping approximated as a fraction per second")
        for key in ("orbit_velocity", "orbit_velocity_min", "radial_accel", "radial_accel_min", "tangential_accel",
                    "tangential_accel_min", "linear_accel", "linear_accel_min", "hue_variation", "hue_variation_min",
                    "turbulence_enabled", "attractor_interaction_enabled", "collision_mode"):
            if num(m.get(key)) not in (0,) and key in m:
                self.report.warn(f"{n.name}: {key} not supported")

    def apply_shape(self, n, f, m, gpu):
        shape = int(num(m.get("emission_shape")))
        if shape == 0:
            f["shape"] = "point"
        elif shape in (1, 2) or (gpu and shape == 6):
            f["shape"] = "circle"
            r = num(m.get("emission_sphere_radius"), 1) if shape != 6 else num(m.get("emission_ring_radius"), 1)
            f["shape_size"] = (r, 0.0)
            if shape in (2, 6):
                self.report.warn(f"{n.name}: sphere surface / ring emitted from the whole disc")
        elif shape == 3:
            e = vec(m.get("emission_box_extents") if gpu else m.get("emission_rect_extents"), (1.0, 1.0))
            f["shape"] = "box"
            f["shape_size"] = (e[0] * 2, e[1] * 2)
        else:
            self.report.warn(f"{n.name}: emission points shape emitted from a point")

    def apply_look(self, n, f, m, base_size, modulate, scale_keys):
        smin = num(m.get(scale_keys[0]), 1) if scale_keys[0] in m else None
        smax = num(m.get(scale_keys[1]), 1) if scale_keys[1] in m else None
        if smin is None and smax is None:
            s = num(m.get(scale_keys[2]), 1) if scale_keys[2] in m else 1.0
            r = num(m.get(scale_keys[3]))
            smin, smax = s * (1 - r), s
        smin = 1.0 if smin is None else smin
        smax = smin if smax is None else smax
        mid = (smin + smax) / 2
        curve = self.curve(m.get(scale_keys[4]))
        k0 = curve[0][1] if curve else 1.0
        k1 = curve[-1][1] if curve else 1.0
        f["start_size"] = base_size * mid * k0
        f["end_size"] = base_size * mid * k1
        if smax != smin:
            f["size_var"] = base_size * abs(smax - smin) / 2
        if curve and len(curve) > 2:
            self.report.warn(f"{n.name}: scale curve with {len(curve)} points kept as start/end")
        base = color(m.get("color")).mul(modulate)
        grad = self.gradient(m.get("color_ramp"))
        if grad:
            c0, c1 = base.mul(grad[0][1]), base.mul(grad[-1][1])
            f["start_color"], f["end_color"] = c0, c1
            inner = [(t, c) for t, c in grad if 0.02 < t < 0.98]
            if inner:
                t, c = max(inner, key=lambda tc: sum(abs(a - b) for a, b in zip(base.mul(tc[1]).tuple(), c0.lerp(c1, tc[0]).tuple())))
                f["use_mid_color"] = True
                f["mid_color"] = base.mul(c)
                f["mid_time"] = t
                if len(inner) > 1:
                    self.report.warn(f"{n.name}: colour ramp has more than 3 keys; kept start, {t:.2f}, end")
        else:
            f["start_color"] = base
            f["end_color"] = base
        if m.get("color_initial_ramp") is not None:
            self.report.warn(f"{n.name}: color_initial_ramp ignored")

    def apply_texture(self, n, f, tex_v, mat_v, filt, anim_src):
        key, (tw, th) = self.texture(tex_v, filt)
        mat = self.resource(mat_v)
        hf = vf = 1
        if mat is not None:
            if int(num(mat.props.get("blend_mode"))) == 1:
                f["additive"] = True
            if mat.props.get("particles_animation"):
                hf = int(num(mat.props.get("particles_anim_h_frames"), 1))
                vf = int(num(mat.props.get("particles_anim_v_frames"), 1))
        if key:
            f["texture"] = Ref(key)
            if hf * vf > 1 and tw:
                self.copier.texture_settings[key]["frame"] = (tw // hf, th // vf)
                sp = (num(anim_src.get("anim_speed_min")) + num(anim_src.get("anim_speed_max"))) / 2 if "anim_speed_min" in anim_src or "anim_speed_max" in anim_src else num(anim_src.get("anim_speed"))
                off = num(anim_src.get("anim_offset_max")) if "anim_offset_max" in anim_src else num(anim_src.get("anim_offset_random"))
                if sp > 0:
                    # Godot's anim_speed is sheet loops over the particle's life when particles_anim_loop is off
                    f["animate_frames"] = True
                    f["frame_cycles"] = sp
                if off > 0:
                    f["random_frame"] = True
            fw = tw // hf if tw else 0
            fh = th // vf if th else 0
            if fw and fh and fw != fh:
                self.report.warn(f"{n.name}: non-square particle texture drawn square")
            return max(fw, fh) or 1
        self.report.warn(f"{n.name}: particles without a texture (Velo draws squares of start_size)")
        return 4

    def cpu_particles(self, n, p, modulate, filt):
        f = {}
        amount = int(num(p.get("amount"), 8))
        self.particles_common(n, f, amount, num(p.get("lifetime"), 1), p)
        size = self.apply_texture(n, f, p.get("texture"), p.get("material"), filt, p)
        godot3 = "scale_amount" in p or "initial_velocity" in p
        self.apply_motion(n, f, p, p, godot3)
        g = vec(p.get("gravity"), (0.0, 98.0 if godot3 else 980.0))
        if g != (0.0, 0.0):
            f["gravity"] = g[:2]
        self.apply_shape(n, f, p, gpu=False)
        self.apply_look(n, f, p, size, modulate, ("scale_amount_min", "scale_amount_max", "scale_amount",
                                                  "scale_amount_random", "scale_amount_curve"))
        n.add("ParticleSystem", f)
        self.report.info(f"CPUParticles2D {n.name}: rate {f['rate']:g}/s life {f['lifetime']:g}s speed {f['speed']:g}px/s")

    def gpu_particles(self, n, p, modulate, filt, godot3):
        f = {}
        amount = int(num(p.get("amount"), 8))
        self.particles_common(n, f, amount, num(p.get("lifetime"), 1), p)
        if godot3 and "local_coords" not in p:
            f["world_space"] = False  # Particles2D defaults to local coordinates
        mat = self.resource(p.get("process_material"))
        m = mat.props if mat else {}
        if mat is None:
            self.report.warn(f"{n.name}: no process material; defaults used")
        size = self.apply_texture(n, f, p.get("texture"), p.get("material"), filt, m)
        self.apply_motion(n, f, p, m, godot3)
        g = vec(m.get("gravity"), (0.0, -9.8, 0.0))
        if g[:2] != (0.0, 0.0):
            f["gravity"] = g[:2]
        self.apply_shape(n, f, m, gpu=True)
        self.apply_look(n, f, m, size, modulate, ("scale_min", "scale_max", "scale", "scale_random", "scale_curve"))
        if p.get("trail_enabled"):
            self.report.warn(f"{n.name}: trails not supported")
        n.add("ParticleSystem", f)
        self.report.info(f"{'Particles2D' if godot3 else 'GPUParticles2D'} {n.name}: rate {f['rate']:g}/s life {f['lifetime']:g}s speed {f['speed']:g}px/s")

"""Unity -> Velo: prefabs / scenes (GameObject tree, ParticleSystem, SpriteRenderer, spine-unity SkeletonAnimation)
and the textures / Spine files they use.

Unity units become pixels (--ppu, default 100), y flips (Unity is y-up, Velo y-down) and rotations change sign.
Velo's ParticleSystem is simpler than Shuriken: curves become start -> (mid ->) end values, random ranges become
value +- var, 3D directions are projected on the screen plane. Everything that cannot be expressed is listed in
the report.
"""

import math
import pathlib
import re

import yaml

from .common import AssetCopier, Color, Node, Ref, image_size, write_scene

# ---------- Unity YAML ----------

_DOC = re.compile(r"^--- !u!(\d+) &(-?\d+)(.*)$")

CLASS_GAMEOBJECT = 1
CLASS_TRANSFORM = 4
CLASS_MONOBEHAVIOUR = 114
CLASS_PARTICLES = 198
CLASS_PARTICLE_RENDERER = 199
CLASS_SPRITE_RENDERER = 212
CLASS_RECT_TRANSFORM = 224
CLASS_PREFAB_INSTANCE = 1001


class _Loader(yaml.SafeLoader):
    pass


def _any_tag(loader, suffix, node):
    if isinstance(node, yaml.MappingNode):
        return loader.construct_mapping(node, deep=True)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node, deep=True)
    return loader.construct_scalar(node)


_Loader.add_multi_constructor("", _any_tag)


def load_unity_yaml(path):
    """{file_id: (class_id, type_name, data)} of a Unity text-serialized file"""
    text = pathlib.Path(path).read_text(encoding="utf-8", errors="replace")
    docs = {}
    cur = None
    buf = []

    def flush():
        if cur is None:
            return
        try:
            data = yaml.load("\n".join(buf), Loader=_Loader) or {}
        except yaml.YAMLError:
            data = {}
        if isinstance(data, dict) and len(data) == 1:
            (tname, body), = data.items()
        else:
            tname, body = "?", data
        docs[cur[1]] = (cur[0], tname, body or {})

    for line in text.splitlines():
        m = _DOC.match(line)
        if m:
            flush()
            cur = (int(m.group(1)), int(m.group(2)))
            buf = []
        elif line.startswith("%"):
            continue
        else:
            buf.append(line)
    flush()
    return docs


def find_project_root(p):
    p = pathlib.Path(p).resolve()
    for d in [p] + list(p.parents):
        if (d / "Assets").is_dir() and ((d / "ProjectSettings").is_dir() or (d / "Packages").is_dir()):
            return d
    for d in [p] + list(p.parents):
        if d.name == "Assets":
            return d.parent
    return p if p.is_dir() else p.parent


class GuidIndex:
    """guid -> asset path, from every .meta file under the project (Assets and Packages)"""

    def __init__(self, root):
        self.paths = {}
        self.metas = {}
        for sub in ("Assets", "Packages"):
            base = pathlib.Path(root) / sub
            if not base.is_dir():
                continue
            for meta in base.rglob("*.meta"):
                try:
                    head = meta.read_text(encoding="utf-8", errors="replace")[:400]
                except OSError:
                    continue
                m = re.search(r"^guid:\s*([0-9a-f]{32})", head, re.M)
                if m:
                    self.paths[m.group(1)] = meta.with_suffix("")
        # a guid's .meta is parsed on demand (texture import settings)

    def path(self, ref):
        if not isinstance(ref, dict):
            return None
        return self.paths.get(str(ref.get("guid", "")))

    def meta(self, asset_path):
        key = str(asset_path)
        if key not in self.metas:
            mp = pathlib.Path(key + ".meta")
            try:
                self.metas[key] = yaml.load(mp.read_text(encoding="utf-8", errors="replace"), Loader=_Loader) or {}
            except (OSError, yaml.YAMLError):
                self.metas[key] = {}
        return self.metas[key]


# ---------- curves, gradients ----------

def fnum(v, d=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return d


def curve_eval(curve, t):
    """AnimationCurve {m_Curve: [{time, value}, ...]} at t (linear between keys, tangents ignored)"""
    keys = (curve or {}).get("m_Curve") or []
    if not keys:
        return 1.0
    keys = sorted(keys, key=lambda k: fnum(k.get("time")))
    if t <= fnum(keys[0].get("time")):
        return fnum(keys[0].get("value"), 1)
    for a, b in zip(keys, keys[1:]):
        ta, tb = fnum(a.get("time")), fnum(b.get("time"))
        if t <= tb:
            k = 0 if tb <= ta else (t - ta) / (tb - ta)
            return fnum(a.get("value")) + (fnum(b.get("value")) - fnum(a.get("value"))) * k
    return fnum(keys[-1].get("value"), 1)


def mmc_range(m, t=0.0):
    """MinMaxCurve -> (lo, hi) at t (0 = start values)"""
    if not isinstance(m, dict):
        v = fnum(m)
        return v, v
    state = int(fnum(m.get("minMaxState")))
    s = fnum(m.get("scalar"), 1)
    if state == 0:
        return s, s
    if state == 3:
        lo = fnum(m.get("minScalar"), s)
        return min(lo, s), max(lo, s)
    hi = s * curve_eval(m.get("maxCurve"), t)
    if state == 2:
        lo = fnum(m.get("minScalar"), s) * curve_eval(m.get("minCurve"), t)
        return min(lo, hi), max(lo, hi)
    return hi, hi


def mmc_mid(m, t=0.0):
    lo, hi = mmc_range(m, t)
    return (lo + hi) / 2, (hi - lo) / 2


def gradient_eval(g, t):
    """Gradient (key0..7, ctime0..7, atime0..7) at t -> Color"""
    if not isinstance(g, dict):
        return Color(255, 255, 255, 255)
    nc = int(fnum(g.get("m_NumColorKeys"), 2))
    na = int(fnum(g.get("m_NumAlphaKeys"), 2))
    ckeys = [(fnum(g.get(f"ctime{i}")) / 65535.0, g.get(f"key{i}") or {}) for i in range(max(nc, 1))]
    akeys = [(fnum(g.get(f"atime{i}")) / 65535.0, fnum((g.get(f"key{i}") or {}).get("a"), 1)) for i in range(max(na, 1))]

    def interp(keys, val):
        if t <= keys[0][0]:
            return val(keys[0][1])
        for (ta, a), (tb, b) in zip(keys, keys[1:]):
            if t <= tb:
                k = 0 if tb <= ta else (t - ta) / (tb - ta)
                va, vb = val(a), val(b)
                return tuple(x + (y - x) * k for x, y in zip(va, vb)) if isinstance(va, tuple) else va + (vb - va) * k
        return val(keys[-1][1])

    rgb = interp(ckeys, lambda c: (fnum(c.get("r"), 1), fnum(c.get("g"), 1), fnum(c.get("b"), 1)))
    a = interp(akeys, lambda x: x)
    return Color.from_float((rgb[0], rgb[1], rgb[2], a))


def gradient_times(g):
    if not isinstance(g, dict):
        return []
    nc = int(fnum(g.get("m_NumColorKeys"), 2))
    na = int(fnum(g.get("m_NumAlphaKeys"), 2))
    return sorted({fnum(g.get(f"ctime{i}")) / 65535.0 for i in range(nc)} | {fnum(g.get(f"atime{i}")) / 65535.0 for i in range(na)})


def mmg_eval(m, t):
    """MinMaxGradient at t (random-between modes give their middle)"""
    if not isinstance(m, dict):
        return Color(255, 255, 255, 255)
    state = int(fnum(m.get("minMaxState")))
    if state == 0:
        return Color.from_float(m.get("maxColor") or {})
    if state == 1:
        return gradient_eval(m.get("maxGradient"), t)
    if state == 2:
        return Color.from_float(m.get("minColor") or {}).lerp(Color.from_float(m.get("maxColor") or {}), 0.5)
    return gradient_eval(m.get("minGradient"), t).lerp(gradient_eval(m.get("maxGradient"), t), 0.5)


def mmg_times(m):
    if not isinstance(m, dict):
        return []
    return gradient_times(m.get("maxGradient")) if int(fnum(m.get("minMaxState"))) in (1, 3) else []


# ---------- transforms ----------

def quat_rotate(q, v):
    x, y, z, w = q
    vx, vy, vz = v
    # v' = v + w t + q.xyz x t, with t = 2 (q.xyz x v)
    tx, ty, tz = 2 * (y * vz - z * vy), 2 * (z * vx - x * vz), 2 * (x * vy - y * vx)
    return (vx + w * tx + (y * tz - z * ty), vy + w * ty + (z * tx - x * tz), vz + w * tz + (x * ty - y * tx))


def quat_mul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw,
            aw * bw - ax * bx - ay * by - az * bz)


def euler_quat(e):
    """Unity euler degrees (applied Z, then X, then Y) -> quaternion"""
    def axis(ax, deg):
        h = math.radians(deg) / 2
        s = math.sin(h)
        return (s if ax == 0 else 0, s if ax == 1 else 0, s if ax == 2 else 0, math.cos(h))
    x, y, z = (fnum((e or {}).get(k)) for k in ("x", "y", "z"))
    return quat_mul(axis(1, y), quat_mul(axis(0, x), axis(2, z)))


def q_of(t):
    q = t.get("m_LocalRotation") or {}
    return (fnum(q.get("x")), fnum(q.get("y")), fnum(q.get("z")), fnum(q.get("w"), 1))


def z_angle(q):
    """the rotation about Z (degrees, Unity counter-clockwise) of a quaternion"""
    x, y, z, w = q
    return math.degrees(math.atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z)))


# ---------- converter ----------

class UnityImporter:
    def __init__(self, src, out_assets, subdir, ppu, report):
        self.src = pathlib.Path(src)
        self.project = find_project_root(self.src)
        self.ppu = ppu
        self.report = report
        self.out = pathlib.Path(out_assets)
        self.copier = AssetCopier(out_assets, subdir, report)
        report.info(f"Unity project: {self.project}")
        self.guids = GuidIndex(self.project)
        report.info(f"{len(self.guids.paths)} assets indexed")

    def rel(self, p):
        try:
            return str(pathlib.Path(p).resolve().relative_to((self.project / "Assets").resolve())).replace("\\", "/")
        except ValueError:
            return pathlib.Path(p).name

    # ----- files -----

    def convert_file(self, path, out_scene):
        docs = load_unity_yaml(path)
        roots = []
        transforms = {fid: d for fid, (cid, _, d) in docs.items() if cid in (CLASS_TRANSFORM, CLASS_RECT_TRANSFORM)}
        for fid, t in transforms.items():
            if int(fnum((t.get("m_Father") or {}).get("fileID"))) == 0:
                roots.append(fid)
        for fid, (cid, _, d) in docs.items():
            if cid == CLASS_PREFAB_INSTANCE:
                src = self.guids.path((d.get("m_SourcePrefab") or {}))
                self.report.warn(f"{pathlib.Path(path).name}: nested prefab instance of {src.name if src else '?'} not expanded (convert it on its own)")
        if not roots:
            self.report.warn(f"{path}: no GameObjects found")
            return None
        if len(roots) == 1:
            root = self.node_of(docs, roots[0], (0, 0, 0, 1))
        else:
            root = Node(pathlib.Path(path).stem)
            for r in roots:
                root.children.append(self.node_of(docs, r, (0, 0, 0, 1)))
            root.comments.append("several Unity root objects")
        root.name = pathlib.Path(path).stem
        root.position = (0.0, 0.0)  # the prefab's own origin
        write_scene(root, out_scene, f"Converted from Unity: {self.rel(path)} (tools/velo_import, ppu {self.ppu:g})\n"
                    "Approximations and unsupported settings are listed in the import report.")
        self.copier.finish()
        return root

    def node_of(self, docs, tfid, parent_q):
        _, _, t = docs[tfid]
        go_id = int(fnum((t.get("m_GameObject") or {}).get("fileID")))
        go = docs.get(go_id, (0, "", {}))[2]
        n = Node(go.get("m_Name") or "Node")
        n.active = int(fnum(go.get("m_IsActive"), 1)) == 1
        p = t.get("m_LocalPosition") or {}
        n.position = (fnum(p.get("x")) * self.ppu, -fnum(p.get("y")) * self.ppu)
        q = q_of(t)
        n.rotation = -z_angle(q)
        s = t.get("m_LocalScale") or {}
        n.scale = (fnum(s.get("x"), 1), fnum(s.get("y"), 1))
        world_q = quat_mul(parent_q, q)
        comps = [int(fnum((c.get("component") or c.get("second") or {}).get("fileID"))) for c in (go.get("m_Component") or [])
                 if isinstance(c, dict)]
        renderer = None
        for cid_ in comps:
            if docs.get(cid_, (0,))[0] == CLASS_PARTICLE_RENDERER:
                renderer = docs[cid_][2]
        for cfid in comps:
            if cfid not in docs:
                continue
            cid, tname, d = docs[cfid]
            if cid == CLASS_PARTICLES:
                self.particles(n, d, renderer, world_q)
            elif cid == CLASS_SPRITE_RENDERER:
                self.sprite(n, d)
            elif cid == CLASS_MONOBEHAVIOUR and "skeletonDataAsset" in d:
                self.spine(n, d)
            elif cid in (CLASS_TRANSFORM, CLASS_RECT_TRANSFORM, CLASS_PARTICLE_RENDERER):
                pass
            elif cid == CLASS_MONOBEHAVIOUR:
                script = self.guids.path(d.get("m_Script"))
                self.report.warn(f"{n.name}: script {script.stem if script else '?'} skipped")
            else:
                self.report.warn(f"{n.name}: {tname} skipped")
        for ch in t.get("m_Children") or []:
            cf = int(fnum((ch or {}).get("fileID")))
            if cf in docs:
                n.children.append(self.node_of(docs, cf, world_q))
        return n

    # ----- textures -----

    def texture_of(self, tex_path, frame=None):
        meta = self.guids.meta(tex_path).get("TextureImporter") or {}
        filt = "nearest" if int(fnum(meta.get("filterMode"), 1)) == 0 else "linear"
        if frame is None:
            frame = self.sheet_frame(tex_path, meta)
        return self.copier.texture(tex_path, self.rel(tex_path), filter=filt, frame=frame)

    def sheet_frame(self, tex_path, meta):
        """(w, h) when a 'Multiple' sprite texture is cut into a regular grid"""
        rects = self.sprite_rects(meta)
        if len(rects) < 2:
            return None
        w, h = rects[0][1][2], rects[0][1][3]
        if all(abs(r[2] - w) < 0.5 and abs(r[3] - h) < 0.5 and abs(r[0] % w) < 0.5 for _, r in rects):
            return (int(w), int(h))
        self.report.warn(f"{pathlib.Path(tex_path).name}: sprites are not a regular grid; frames not set")
        return None

    def sprite_rects(self, meta):
        out = []
        for s in ((meta.get("spriteSheet") or {}).get("sprites") or []):
            r = s.get("rect") or {}
            out.append((s, (fnum(r.get("x")), fnum(r.get("y")), fnum(r.get("width")), fnum(r.get("height")))))
        return out

    def material_texture(self, renderer):
        """(texture asset key, additive?) of a ParticleSystemRenderer's first material"""
        mats = (renderer or {}).get("m_Materials") or []
        if not mats:
            return None, False
        mpath = self.guids.path(mats[0])
        if not mpath or not mpath.exists():
            if mats[0] and int(fnum(mats[0].get("fileID"))) != 0:
                self.report.warn("particle material is a Unity built-in one; no texture copied")
            return None, False
        docs = load_unity_yaml(mpath)
        mat = next((d for c, _, d in docs.values() if c == 21), {})
        props = mat.get("m_SavedProperties") or {}
        tex = None
        for env in props.get("m_TexEnvs") or []:
            for k, v in (env or {}).items():
                if k in ("_MainTex", "_BaseMap", "_BaseColorMap") and isinstance(v, dict):
                    tex = tex or self.guids.path(v.get("m_Texture"))
        floats = {}
        for f in props.get("m_Floats") or []:
            floats.update(f or {})
        shader = self.guids.path(mat.get("m_Shader"))
        name = (mat.get("m_Name") or "") + " " + (shader.stem if shader else "") + " " + mpath.stem
        additive = fnum(floats.get("_DstBlend"), -1) == 1 or "add" in name.lower() or int(fnum(floats.get("_Blend"), -1)) == 2
        if (mat.get("m_Shader") or {}).get("fileID") in (200, 202):  # legacy Particles/Additive (and soft)
            additive = True
        key = self.texture_of(tex) if tex and tex.exists() else None
        if tex and not tex.exists():
            self.report.warn(f"material {mpath.name}: texture file missing")
        return key, additive

    # ----- components -----

    def sprite(self, n, d):
        sp = d.get("m_Sprite") or {}
        tex_path = self.guids.path(sp)
        if not tex_path or not tex_path.exists():
            self.report.warn(f"{n.name}: SpriteRenderer without a sprite file")
            return
        meta = self.guids.meta(tex_path).get("TextureImporter") or {}
        key = self.texture_of(tex_path)
        f = {"texture": Ref(key)}
        frame_px = None
        rects = self.sprite_rects(meta)
        if rects and int(fnum(meta.get("spriteMode"), 1)) == 2:
            want = int(fnum(sp.get("fileID")))
            names = {}
            for e in meta.get("internalIDToNameTable") or []:
                first = (e or {}).get("first") or {}
                for _, v in first.items():
                    names[int(fnum(v))] = e.get("second")
            for e in (meta.get("fileIDToRecycleName") or {}).items() if isinstance(meta.get("fileIDToRecycleName"), dict) else []:
                names[int(fnum(e[0]))] = e[1]
            sname = names.get(want)
            for s, r in rects:
                if s.get("name") == sname or int(fnum(s.get("internalID"))) == want:
                    tw, th = image_size(tex_path)
                    cols = max(1, int(tw // r[2])) if r[2] else 1
                    row = int((th - (r[1] + r[3])) // r[3]) if r[3] else 0
                    f["frame"] = int(r[0] // r[2]) + row * cols if r[2] else 0
                    frame_px = (r[2], r[3])
        tex_ppu = fnum(meta.get("spritePixelsToUnits"), 100) or 100
        if abs(tex_ppu - self.ppu) > 1e-3:
            w, h = frame_px or image_size(tex_path)
            k = self.ppu / tex_ppu
            f["size"] = (w * k, h * k)
        c = Color.from_float(d.get("m_Color") or {})
        if c != Color(255, 255, 255, 255):
            f["color"] = c
        if int(fnum(d.get("m_FlipX"))):
            f["flip_x"] = True
        if int(fnum(d.get("m_FlipY"))):
            f["flip_y"] = True
        if int(fnum(d.get("m_DrawMode"))) in (1, 2):
            self.report.warn(f"{n.name}: sliced/tiled SpriteRenderer: set Sprite.draw_mode and borders by hand")
        n.z_index = int(fnum(d.get("m_SortingOrder")))
        n.add("Sprite", f)

    def spine(self, n, d):
        sda = self.guids.path(d.get("skeletonDataAsset"))
        if not sda or not sda.exists():
            self.report.warn(f"{n.name}: SkeletonAnimation without its SkeletonDataAsset")
            return
        sd = next((x for _, _, x in load_unity_yaml(sda).values()), {})
        js = self.guids.path(sd.get("skeletonJSON"))
        atlas_assets = sd.get("atlasAssets") or []
        atlas_file = None
        if atlas_assets:
            aa = self.guids.path(atlas_assets[0])
            if aa and aa.exists():
                ad = next((x for _, _, x in load_unity_yaml(aa).values()), {})
                atlas_file = self.guids.path(ad.get("atlasFile"))
        if not js or not atlas_file:
            self.report.warn(f"{n.name}: Spine data incomplete (json / atlas not found)")
            return
        if js.suffix == ".bytes" or js.name.endswith(".skel.bytes"):
            self.report.warn(f"{n.name}: binary .skel export; Velo reads Spine 4.2 JSON - re-export as JSON")
            return
        base = js.name.replace(".json.txt", "").replace(".json", "").replace(".txt", "")
        folder = str(pathlib.PurePosixPath(self.rel(js)).parent)
        data_key = self.copier.copy(js, f"{folder}/{base}.json")
        atlas_key = self.copier.copy(atlas_file, f"{folder}/{base}.atlas")
        for line in atlas_file.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if line.lower().endswith((".png", ".jpg", ".webp")):
                page = atlas_file.parent / line
                if page.exists():
                    self.copier.texture(page, f"{folder}/{line}")
                else:
                    self.report.warn(f"Spine page {line} not next to {atlas_file.name}")
        f = {"data": Ref(data_key), "atlas": Ref(atlas_key)}
        if d.get("_animationName"):
            f["animation"] = d["_animationName"]
        if "loop" in d:
            f["looping"] = bool(int(fnum(d.get("loop"), 1)))
        if fnum(d.get("timeScale"), 1) != 1:
            f["speed"] = fnum(d.get("timeScale"))
        skin = d.get("initialSkinName")
        if skin and skin != "default":
            f["skin"] = skin
        scale = fnum(sd.get("scale"), 0.01) * self.ppu
        if abs(scale - 1) > 1e-3:
            n.scale = (n.scale[0] * scale, n.scale[1] * scale)
        n.comments.append("Spine: Velo reads Spine 4.2 JSON; older exports need re-exporting")
        n.add("Kine2D", f)

    def particles(self, n, d, renderer, world_q):
        ppu = self.ppu
        rep = self.report
        name = n.name
        init = d.get("InitialModule") or {}
        f = {}
        if not int(fnum(init.get("enabled"), 1)):
            pass
        f["looping"] = bool(int(fnum(d.get("looping"), 1)))
        f["duration"] = fnum(d.get("lengthInSec"), 5)
        f["playing"] = bool(int(fnum(d.get("playOnAwake"), 1)))
        f["world_space"] = int(fnum(d.get("moveWithTransform"))) != 0
        f["max_particles"] = int(fnum(init.get("maxNumParticles"), 1000))
        life, life_var = mmc_mid(init.get("startLifetime"))
        f["lifetime"] = max(life, 0.01)
        if life_var > 0:
            f["lifetime_var"] = life_var
        speed, speed_var = mmc_mid(init.get("startSpeed"))
        size, size_var = mmc_mid(init.get("startSize"))
        rot_lo, rot_hi = mmc_range(init.get("startRotation"))
        if abs(rot_hi - rot_lo) > 0.1:
            f["random_angle"] = True
        g = mmc_mid(init.get("gravityModifier"))[0]
        if g:
            f["gravity"] = (0.0, g * 9.81 * ppu)
        if fnum(d.get("startDelay", {}).get("scalar") if isinstance(d.get("startDelay"), dict) else 0) > 0:
            rep.warn(f"{name}: start delay ignored")
        if int(fnum(d.get("prewarm"))):
            rep.warn(f"{name}: prewarm ignored")

        # emission
        em = d.get("EmissionModule") or {}
        rate = 0.0
        burst = 0
        if int(fnum(em.get("enabled"), 1)):
            rate = mmc_mid(em.get("rateOverTime") or em.get("rate"))[0]
            for b in em.get("m_Bursts") or []:
                count = mmc_mid(b.get("countCurve"))[0] if b.get("countCurve") else (fnum(b.get("minCount")) + fnum(b.get("maxCount"))) / 2
                if fnum(b.get("time")) <= 0.05:
                    burst += int(round(count))
                else:
                    rep.warn(f"{name}: burst at {fnum(b.get('time')):g}s moved to the start")
                    burst += int(round(count))
                if int(fnum(b.get("cycleCount"), 1)) != 1:
                    rep.warn(f"{name}: repeating bursts emitted once")
            if mmc_mid(em.get("rateOverDistance"))[0] > 0:
                rep.warn(f"{name}: rate over distance ignored")
        f["rate"] = rate
        if burst:
            f["burst"] = burst

        # shape and direction
        sh = d.get("ShapeModule") or {}
        direction = (0.0, 0.0, 1.0)
        spread = 0.0
        shape = "point"
        shape_size = None
        radial = False
        if int(fnum(sh.get("enabled"), 1)):
            st = int(fnum(sh.get("type"), 4))
            rad = sh.get("radius")
            radius = fnum(rad.get("value"), 1) if isinstance(rad, dict) else fnum(rad, 1)
            sc = sh.get("m_Scale") or {}
            sx, sy = fnum(sc.get("x"), 1), fnum(sc.get("y"), 1)
            if st in (4, 7, 8, 9):  # cone
                spread = fnum(sh.get("angle"), 25)
                if radius * ppu > 2:
                    shape, shape_size = "circle", (radius * ppu * min(abs(sx), abs(sy)), 0.0)
            elif st in (0, 1, 2, 3, 10, 11, 17):  # sphere, hemisphere, circle, donut: outward
                radial = True
                shape, shape_size = "circle", (radius * ppu * min(abs(sx), abs(sy)), 0.0)
                arc = fnum(sh.get("arc"), 360)
                if arc < 359:
                    rep.warn(f"{name}: circle arc {arc:g} emitted all around")
            elif st in (5, 15, 16, 18):  # box, rectangle
                shape, shape_size = "box", (abs(sx) * ppu, abs(sy) * ppu)
            elif st == 12:  # edge
                shape, shape_size = "box", (radius * 2 * ppu * abs(sx), 0.0)
                direction = (0.0, 1.0, 0.0)
            else:
                rep.warn(f"{name}: emission shape type {st} (mesh / sprite) emitted from a point")
            q = euler_quat(sh.get("m_Rotation") or {})
            direction = quat_rotate(quat_mul(world_q, q), direction)
            if fnum(sh.get("randomDirectionAmount")) > 0.5 or fnum(sh.get("sphericalDirectionAmount")) > 0.5:
                radial = True
        else:
            direction = quat_rotate(world_q, direction)
        dx, dy = direction[0], -direction[1]  # screen y is down
        flat = math.hypot(dx, dy)
        if radial or flat < 0.3:
            f["angle"] = -90
            f["spread"] = 180
            if not radial and spread:
                speed *= math.sin(math.radians(min(spread, 90)))
                speed_var *= math.sin(math.radians(min(spread, 90)))
            if not radial:
                rep.warn(f"{name}: emits toward the camera; converted to all directions on screen")
        else:
            f["angle"] = math.degrees(math.atan2(dy, dx))
            f["spread"] = spread
            speed *= flat
            speed_var *= flat
        f["speed"] = speed * ppu
        if speed_var:
            f["speed_var"] = speed_var * ppu
        f["shape"] = shape
        if shape_size:
            f["shape_size"] = shape_size

        # size over life
        szm = d.get("SizeModule") or {}
        k0 = k1 = 1.0
        if int(fnum(szm.get("enabled"))):
            k0 = mmc_mid(szm.get("curve"), 0.0)[0]
            k1 = mmc_mid(szm.get("curve"), 1.0)[0]
            if int(fnum(szm.get("separateAxes"))):
                rep.warn(f"{name}: separate-axes size over life uses X only")
        f["start_size"] = size * ppu * k0
        f["end_size"] = size * ppu * k1
        if size_var:
            f["size_var"] = size_var * ppu

        # colour
        start = mmg_eval(init.get("startColor"), 0.0)
        cm = d.get("ColorModule") or {}
        if int(fnum(cm.get("enabled"))):
            grad = cm.get("gradient")
            c0, c1 = start.mul(mmg_eval(grad, 0.0)), start.mul(mmg_eval(grad, 1.0))
            f["start_color"], f["end_color"] = c0, c1
            best, best_t = 0, None
            for t in mmg_times(grad):
                if 0.02 < t < 0.98:
                    c = start.mul(mmg_eval(grad, t))
                    lin = c0.lerp(c1, t)
                    dev = sum(abs(a - b) for a, b in zip(c.tuple(), lin.tuple()))
                    if dev > best:
                        best, best_t = dev, t
            if best_t is not None and best > 12:
                f["use_mid_color"] = True
                f["mid_color"] = start.mul(mmg_eval(grad, best_t))
                f["mid_time"] = best_t
                if len([t for t in mmg_times(grad) if 0.02 < t < 0.98]) > 1:
                    rep.warn(f"{name}: colour gradient has more than 3 keys; kept start, {best_t:.2f}, end")
        else:
            f["start_color"] = start
            f["end_color"] = start
        if int(fnum((init.get("startColor") or {}).get("minMaxState"))) in (2, 3):
            rep.warn(f"{name}: random start colour averaged")

        # rotation over life
        rm = d.get("RotationModule") or {}
        if int(fnum(rm.get("enabled"))):
            sp, sv = mmc_mid(rm.get("curve"))
            f["spin"] = -math.degrees(sp)
            if sv:
                f["spin_var"] = math.degrees(sv)

        # velocity limits -> damping; unsupported modules
        lv = d.get("ClampVelocityModule") or {}
        if int(fnum(lv.get("enabled"))):
            f["damping"] = fnum(lv.get("dampen"), 0) * 3
            rep.warn(f"{name}: limit velocity approximated as damping")
        for mod in ("VelocityModule", "ForceModule", "NoiseModule", "CollisionModule", "SubModule", "TrailModule",
                    "LightsModule", "ExternalForcesModule", "InheritVelocityModule", "SizeBySpeedModule",
                    "ColorBySpeedModule", "RotationBySpeedModule", "TriggerModule", "CustomDataModule"):
            if int(fnum((d.get(mod) or {}).get("enabled"))):
                rep.warn(f"{name}: {mod.replace('Module', '')} module not supported")

        # renderer / texture sheet
        tex_key, additive = self.material_texture(renderer)
        uv = d.get("UVModule") or {}
        if tex_key and int(fnum(uv.get("enabled"))):
            tx, ty = int(fnum(uv.get("tilesX"), 1)), int(fnum(uv.get("tilesY"), 1))
            src_tex = self.out / tex_key
            tw, th = image_size(src_tex)
            if tx * ty > 1 and tw and th:
                self.copier.texture_settings.setdefault(tex_key, {})["frame"] = (tw // tx, th // ty)
                fot = uv.get("frameOverTime") or {}
                state = int(fnum(fot.get("minMaxState")))
                if state in (1, 2):
                    f["animate_frames"] = True
                    f["frame_cycles"] = fnum(uv.get("cycles"), 1)
                else:
                    f["random_frame"] = True
                lo, hi = mmc_range(uv.get("startFrame"))
                if hi - lo >= 1 and state in (1, 2):
                    f["random_frame"] = True
                if int(fnum(uv.get("animationType"))) == 1:
                    rep.warn(f"{name}: texture sheet 'single row' mode plays the whole sheet")
        if tex_key:
            f["texture"] = Ref(tex_key)
        else:
            rep.warn(f"{name}: no particle texture (drawn as squares)")
        if additive:
            f["additive"] = True
        if renderer:
            n.z_index = int(fnum(renderer.get("m_SortingOrder")))
            if int(fnum(renderer.get("m_RenderMode"))) not in (0,):
                rep.warn(f"{name}: render mode {int(fnum(renderer.get('m_RenderMode')))} drawn as billboards")
        n.add("ParticleSystem", f)
        self.report.info(f"ParticleSystem {name}: rate {rate:g}/s burst {burst} life {life:g}s speed {f['speed']:.0f}px/s")

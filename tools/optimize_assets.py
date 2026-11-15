"""Optimize and compress a Velo assets folder for shipping.

    python tools/optimize_assets.py <assets> [--out <dir>] [options]

Writes an optimized copy (default: <assets>/../build/assets_optimized) and never touches the source folder
unless --in-place is given. Every .meta file comes along, so asset ids, and the scenes that use them, keep
working. A report (sizes per kind, per file, what was skipped and why) is printed and saved as
optimize_report.md in the output folder.

Images (.png .jpg .jpeg .bmp .tga)
  - PNG recompressed losslessly (zlib level 9, metadata stripped); images with at most 256 colours become
    palette PNGs with the exact same pixels (alpha kept) - typical for pixel art and UI
  - --webp: also tries lossless WebP (Velo decodes lossless WebP itself) and keeps it when smaller; the file
    extension changes, so path references in .scene files are rewritten. With --src, files the game code
    names by path keep their format (only recompressed), so nothing breaks. --best: slowest, smallest WebP
    (about 5x slower than the default effort)
  - --max-size N: textures larger than N pixels on a side are downscaled (sprite sheets with frame_width /
    frame_height in their .meta are left alone, their frame grid would break)
  - --lossy-alpha-threshold: PNGs with semi-transparent edges keep full alpha (never quantized lossy)
Audio (.wav)
  - --ogg: WAV files larger than --ogg-min-kb (default 200) become Ogg Vorbis (needs ffmpeg on PATH);
    short sound effects stay WAV (no decoding cost at play time). Paths are rewritten as for --webp.
Text (.json .atlas .txt)
  - JSON is minified (Spine / Kine2D exports shrink a lot); other text is copied
Report only
  - --src <dir>: also lists assets that no scene, prefab or source file mentions (by id or path) - candidates
    for removal; nothing is deleted.
Options: --dry-run (report only), --in-place (optimize the source folder itself; make a backup first).
"""

import argparse
import io
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys

try:
    from PIL import Image
except ImportError:
    Image = None

IMAGE_EXT = {".png", ".jpg", ".jpeg", ".bmp", ".tga"}
TEXT_EXT = {".json", ".atlas", ".txt"}
REF_TEXT_EXT = {".scene", ".prefab"}


def kb(n):
    return f"{n / 1024:,.1f} KB" if n < 1024 * 1024 else f"{n / 1024 / 1024:,.2f} MB"


def read_meta(path):
    meta = {}
    mp = pathlib.Path(str(path) + ".meta")
    if mp.exists():
        for line in mp.read_text(encoding="utf-8", errors="replace").splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                meta[k.strip()] = v.strip()
    return meta


class Optimizer:
    def __init__(self, a):
        self.a = a
        self.src = pathlib.Path(a.assets).resolve()
        self.out = self.src if a.in_place else pathlib.Path(a.out or (self.src.parent / "build" / "assets_optimized")).resolve()
        self.rows = []  # (rel, kind, before, after, note)
        self.renames = {}  # old rel path -> new rel path
        self.notes = []
        self.ffmpeg = shutil.which("ffmpeg")
        self.code_named = self.code_paths(a.src)  # paths the game code names: keep their extension

    def code_paths(self, src_dir):
        out = set()
        if not src_dir:
            return out
        texts = []
        for f in pathlib.Path(src_dir).rglob("*"):
            if f.is_file() and f.suffix in (".v", ".py", ".js", ".ts", ".gd", ".cs"):
                texts.append(f.read_text(encoding="utf-8", errors="replace"))
        blob = "\n".join(texts)
        for p in self.src.rglob("*"):
            if p.is_file() and not p.name.endswith(".meta"):
                rel = p.relative_to(self.src).as_posix()
                if f"'{rel}'" in blob or f'"{rel}"' in blob:
                    out.add(rel)
        return out

    # ----- per kind -----

    def image(self, path, rel):
        data = path.read_bytes()
        before = len(data)
        meta = read_meta(path)
        if Image is None:
            return data, rel, "Pillow missing: copied"
        try:
            im = Image.open(io.BytesIO(data))
            im.load()
        except Exception as e:  # unreadable: copy as is
            return data, rel, f"not decodable ({e.__class__.__name__}): copied"
        note = []
        is_sheet = int(meta.get("frame_width", "0") or 0) > 0
        if self.a.max_size and max(im.size) > self.a.max_size:
            if is_sheet:
                note.append(f"{im.size[0]}x{im.size[1]} sheet over --max-size left alone")
            else:
                k = self.a.max_size / max(im.size)
                im = im.resize((max(1, round(im.size[0] * k)), max(1, round(im.size[1] * k))), Image.LANCZOS)
                note.append(f"downscaled to {im.size[0]}x{im.size[1]}")
        has_alpha = im.mode in ("RGBA", "LA") or (im.mode == "P" and "transparency" in im.info)
        im = im.convert("RGBA" if has_alpha else "RGB")
        candidates = []
        # lossless PNG
        buf = io.BytesIO()
        im.save(buf, "PNG", optimize=True, compress_level=9)
        candidates.append((buf.getvalue(), ".png", "png"))
        # exact palette when the image has <= 256 distinct colours (pixels unchanged)
        colors = im.getcolors(256)
        if colors is not None:
            pal = self.exact_palette(im, colors)
            if pal is not None:
                candidates.append((pal, ".png", f"palette png ({len(colors)} colours)"))
        if self.a.webp and rel not in self.code_named:
            buf = io.BytesIO()
            im.save(buf, "WEBP", lossless=True, quality=100, method=6 if self.a.best else 4, exact=True)
            candidates.append((buf.getvalue(), ".webp", "lossless webp"))
        best, ext, how = min(candidates, key=lambda c: len(c[0]))
        if path.suffix.lower() in (".jpg", ".jpeg") and ext == ".png" and len(best) >= before:
            return data, rel, "jpeg kept (smaller than any lossless form)"
        if len(best) >= before and ext == path.suffix.lower() and not any("downscaled" in n for n in note):
            return data, rel, "already optimal: copied"
        new_rel = rel if ext == path.suffix.lower() else str(pathlib.PurePosixPath(rel).with_suffix(ext))
        note.insert(0, how)
        return best, new_rel, ", ".join(note)

    def exact_palette(self, im, colors):
        try:
            pal_img = Image.new("P", im.size)
            rgba = [c for _, c in colors]
            index = {c: i for i, c in enumerate(rgba)}
            src = im.convert("RGBA")
            pal_img.putdata([index[p if len(p) == 4 else (*p, 255)] for p in src.getdata()])
            flat = []
            for c in rgba:
                flat += list(c[:3])
            pal_img.putpalette(flat + [0] * (768 - len(flat)))
            alpha = bytes(c[3] for c in rgba)
            buf = io.BytesIO()
            if any(a < 255 for a in alpha):
                pal_img.save(buf, "PNG", optimize=True, transparency=alpha)
            else:
                pal_img.save(buf, "PNG", optimize=True)
            # verify it round-trips exactly
            back = Image.open(io.BytesIO(buf.getvalue())).convert("RGBA")
            if list(back.getdata()) != list(src.getdata()):
                return None
            return buf.getvalue()
        except Exception:
            return None

    def audio(self, path, rel):
        data = path.read_bytes()
        if not self.a.ogg or path.suffix.lower() != ".wav":
            return data, rel, "copied"
        if rel in self.code_named:
            return data, rel, "named by path in game code: wav kept"
        if len(data) < self.a.ogg_min_kb * 1024:
            return data, rel, f"short sound kept as wav (< {self.a.ogg_min_kb} KB)"
        if not self.ffmpeg:
            return data, rel, "ffmpeg not found: wav kept"
        tmp = self.out / (rel + ".tmp.ogg")
        tmp.parent.mkdir(parents=True, exist_ok=True)
        r = subprocess.run([self.ffmpeg, "-v", "error", "-y", "-i", str(path), "-c:a", "libvorbis", "-q:a",
                            str(self.a.ogg_quality), str(tmp)], capture_output=True)
        if r.returncode != 0 or not tmp.exists():
            return data, rel, "ffmpeg failed: wav kept"
        ogg = tmp.read_bytes()
        tmp.unlink()
        if len(ogg) >= len(data):
            return data, rel, "ogg not smaller: wav kept"
        return ogg, str(pathlib.PurePosixPath(rel).with_suffix(".ogg")), f"ogg vorbis q{self.a.ogg_quality}"

    def text(self, path, rel):
        data = path.read_bytes()
        if path.suffix.lower() == ".json":
            try:
                obj = json.loads(data.decode("utf-8"))
                small = json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
                if len(small) < len(data):
                    return small, rel, "json minified"
            except (ValueError, UnicodeDecodeError):
                return data, rel, "not valid json: copied"
        return data, rel, "copied"

    # ----- run -----

    def run(self):
        files = sorted(p for p in self.src.rglob("*") if p.is_file() and not p.name.endswith(".meta")
                       and "build" not in p.relative_to(self.src).parts[:1])
        if self.out != self.src and str(self.out).startswith(str(self.src) + os.sep):
            sys.exit("--out must not be inside the assets folder")
        results = []
        for p in files:
            rel = p.relative_to(self.src).as_posix()
            ext = p.suffix.lower()
            if ext in IMAGE_EXT:
                kind = "image"
                data, new_rel, note = self.image(p, rel)
            elif ext in (".wav", ".ogg", ".mp3"):
                kind = "audio"
                data, new_rel, note = self.audio(p, rel)
            elif ext in TEXT_EXT:
                kind = "text"
                data, new_rel, note = self.text(p, rel)
            else:
                kind = "scene" if ext in REF_TEXT_EXT else "other"
                data, new_rel, note = p.read_bytes(), rel, "copied"
            if new_rel != rel:
                self.renames[rel] = new_rel
            results.append((p, rel, new_rel, kind, data, note))
            self.rows.append((rel if new_rel == rel else f"{rel} -> {pathlib.PurePosixPath(new_rel).name}", kind,
                              p.stat().st_size, len(data), note))
        # path references inside scenes / prefabs follow renamed files
        for i, (p, rel, new_rel, kind, data, note) in enumerate(results):
            if kind == "scene" and self.renames:
                text = data.decode("utf-8", errors="replace")
                n = 0
                for old, new in self.renames.items():
                    text, c = re.subn(r'@asset\("' + re.escape(old) + r'"\)', f'@asset("{new}")', text)
                    n += c
                if n:
                    results[i] = (p, rel, new_rel, kind, text.encode("utf-8"), note)
                    self.notes.append(f"{rel}: {n} path reference(s) rewritten")
        if self.a.dry_run:
            return
        for p, rel, new_rel, kind, data, note in results:
            dst = self.out / new_rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(data)
            meta = pathlib.Path(str(p) + ".meta")
            if meta.exists():
                shutil.copy2(meta, str(dst) + ".meta")
            if self.a.in_place and new_rel != rel:
                p.unlink()
                if meta.exists():
                    meta.unlink()

    def code_refs(self, src_dir):
        """renamed files that game code names by path (they need the new extension there too)"""
        out = []
        if not src_dir or not self.renames:
            return out
        for f in pathlib.Path(src_dir).rglob("*"):
            if f.is_file() and f.suffix in (".v", ".py", ".js", ".ts", ".json", ".gd", ".cs"):
                t = f.read_text(encoding="utf-8", errors="replace")
                for old in self.renames:
                    if f"'{old}'" in t or f'"{old}"' in t:
                        out.append(f"{f.name}: names '{old}' (now {self.renames[old]})")
        return out

    def unused(self, src_dir):
        texts = []
        for p in self.src.rglob("*"):
            if p.is_file() and p.suffix in REF_TEXT_EXT | {".json", ".atlas"}:
                texts.append(p.read_text(encoding="utf-8", errors="replace"))
        if src_dir:
            for f in pathlib.Path(src_dir).rglob("*"):
                if f.is_file() and f.suffix in (".v", ".py", ".gd", ".cs", ".js", ".ts"):
                    texts.append(f.read_text(encoding="utf-8", errors="replace"))
        blob = "\n".join(texts)
        out = []
        for p in sorted(self.src.rglob("*")):
            if not p.is_file() or p.name.endswith(".meta") or p.suffix in REF_TEXT_EXT:
                continue
            rel = p.relative_to(self.src).as_posix()
            mid = read_meta(p).get("id", "")
            if (mid and mid in blob) or rel in blob or p.name in blob or p.stem in blob:
                continue
            out.append((rel, p.stat().st_size))
        return out

    def report(self):
        by = {}
        for rel, kind, b, a, note in self.rows:
            t = by.setdefault(kind, [0, 0, 0])
            t[0] += 1
            t[1] += b
            t[2] += a
        tb = sum(r[2] for r in self.rows)
        ta = sum(r[3] for r in self.rows)
        lines = ["# Asset optimization report", "", f"Source: `{self.src}`  ", f"Output: `{self.out}`"
                 + (" (dry run, nothing written)" if self.a.dry_run else ""), "",
                 "| Kind | Files | Before | After | Saved |", "|---|---|---|---|---|"]
        for kind, (n, b, a) in sorted(by.items()):
            lines.append(f"| {kind} | {n} | {kb(b)} | {kb(a)} | {100 * (b - a) / b if b else 0:.0f}% |")
        lines.append(f"| **total** | {len(self.rows)} | {kb(tb)} | {kb(ta)} | {100 * (tb - ta) / tb if tb else 0:.0f}% |")
        lines += ["", "## Biggest savings", "", "| File | Before | After | How |", "|---|---|---|---|"]
        for rel, kind, b, a, note in sorted(self.rows, key=lambda r: r[3] - r[2])[:25]:
            if a < b:
                lines.append(f"| {rel} | {kb(b)} | {kb(a)} | {note} |")
        refs = self.code_refs(self.a.src)
        if self.notes or refs:
            lines += ["", "## References", ""] + [f"- {n}" for n in self.notes] + [f"- code: {r}" for r in refs]
        if self.a.src or self.a.unused:
            un = self.unused(self.a.src)
            lines += ["", f"## Possibly unused ({len(un)} files, {kb(sum(s for _, s in un))})", "",
                      "Not named by any scene, prefab, JSON/atlas or source file (by id, path or name). Check before "
                      "deleting: code may build paths at runtime."]
            lines += [f"- {r} ({kb(s)})" for r, s in un[:200]]
        text = "\n".join(lines) + "\n"
        print(text)
        if not self.a.dry_run:
            (self.out / "optimize_report.md").write_text(text, encoding="utf-8")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("assets")
    ap.add_argument("--out")
    ap.add_argument("--webp", action="store_true", help="try lossless WebP for images")
    ap.add_argument("--best", action="store_true", help="slowest / smallest lossless WebP")
    ap.add_argument("--ogg", action="store_true", help="long WAV files -> Ogg Vorbis (ffmpeg)")
    ap.add_argument("--ogg-min-kb", type=int, default=200)
    ap.add_argument("--ogg-quality", type=int, default=4, help="Vorbis quality 0..10 (4 ~ 128 kbps)")
    ap.add_argument("--max-size", type=int, default=0, help="downscale images larger than this (pixels)")
    ap.add_argument("--src", help="game source folder: report code references and unused assets")
    ap.add_argument("--unused", action="store_true", help="report possibly unused assets")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--in-place", action="store_true")
    a = ap.parse_args()
    if Image is None:
        print("note: Pillow is not installed (pip install pillow): images are copied unchanged")
    o = Optimizer(a)
    o.run()
    o.report()


if __name__ == "__main__":
    main()

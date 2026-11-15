# Velo engine code review — November 2026

A read-through of render/, core/, app/, assets/, serialize/, physics/, audio/, kine2d/, editor/, webp/, tools/ and
tests/ (not tools/v2js, tools/velo or webgl). Items marked **(checked)** were confirmed by reading the code a second
time; the rest come from a careful read but were not re-verified. Paths are relative to the repo root.

## 1. Fix first: bugs that lose data, crash, or are wrong in common cases

| # | Problem | Where | Fix |
|---|---|---|---|
| 1 | **Save file can be lost on Windows.** `os.mv` cannot rename over an existing file there and falls back to delete-then-copy; a crash in between leaves no save. No fsync, no `.tmp` recovery. **(checked)** | `core/store.v:153` | `MoveFileExW(REPLACE_EXISTING \| WRITE_THROUGH)` on Windows, fsync + rename elsewhere; recover from `.tmp` / `.bak` in `Store.open` |
| 2 | **A corrupt save is silently overwritten.** One bad line rejects the whole file; the next save writes an empty store over the player's data. | `core/store.v:39, 201` | parse line by line, skip bad lines; keep a `.corrupt-<time>` copy before writing |
| 3 | **`on_destroy` runs twice** (second time with `scene == nil`) when a parent and child are destroyed in the same frame. **(checked)** | `core/scene.v:196`, `core/node.v:298` | skip nodes already detached; mark the whole subtree destroyed in `destroy()` |
| 4 | **Removing a component during `update` can index past the end** (count is snapshotted). **(checked)** | `core/node.v:318` | deferred removal flag, or re-check the length; stop ticking a node once destroyed |
| 5 | **Flipped physics bodies turn upside down.** `rotation_deg = atan2(b, a)` reads scale.x = -1 as 180°, written back as rotation; collider offsets mirror on the wrong axis. **(checked)** | `physics/world.v:235`, `core/math.v:155` | decompose with signed scale (det < 0 = reflection), keep the node's own sign when writing back |
| 6 | **Keys stay held after alt-tab** (no key-up arrives); the character keeps walking. | `app/app.v:519`, `core/input.v` | `Input.release_all()` on unfocused / suspended / iconified |
| 7 | **The optimizer can break Spine / Kine2D rigs**: with `--webp` it renames atlas pages but does not rewrite `.atlas` / `.atlas.json` page names; same-stem files (`a.png` + `a.jpg`) overwrite each other; `--in-place` deletes before all writes succeed. **(checked: atlas)** | `tools/optimize_assets.py` | rewrite page names (or never convert atlas pages), detect name collisions, delete only after writing |
| 8 | **Scene loader merges same-named siblings and repeated components** — a save/load round trip of two `node Wall {}` gives one. | `serialize/loader.v:135` | only merge into nodes/components that came from the `from` prefab |
| 9 | **Hidden buttons stay clickable**: hit tests honour ScrollView clipping but not `Mask`. **(checked)** | `render/ui.v:88` | test enabled Mask ancestors too |
| 10 | **No scissor set at the start of `draw_tree`**: the world can draw outside the fit area unless the caller set one. **(checked)** | `render/renderer.v:84` | `r.set_scissor(base)` first; round scissor edges outward instead of truncating |
| 11 | **A zero-size Slider (or NaN progress) sticks at NaN**: `clamp01` passes NaN through. **(checked)** | `render/ui.v:1138`, `render/ui_widgets.v:115` | guard zero sizes; make `clamp01` map NaN to 0 |
| 12 | **Spine premultiplied-alpha pages are drawn as straight alpha** (dark fringes): `pma` is parsed and never used. **(checked)** | `kine2d/spine.v:786` | pass `pma` to the mesh and use (ONE, ONE_MINUS_SRC_ALPHA) |
| 13 | **Spine colours overflow** (bezier overshoot cast to u8 wraps: flashing colours). | `kine2d/spine_pose.v:513`, `kine2d/kine2d.v:266` | clamp channels to 0..1 |
| 14 | **Corrupt WAV / WebP chunk sizes hang or crash** (u32 size cast to int goes negative). | `audio/sound.v:72`, `webp/webp.v:81` | keep sizes unsigned, clamp to the data, always advance |
| 15 | **Physics ignores inactive nodes** (a deactivated pickup still collides and fires `began`). | `physics/world.v:77` | `b2Body_Disable` / `Enable` on active-state changes |

**Fixed (2026-11-15):** 1, 2 (`core/store.v`, `core/store_sync.c.v`: flushed temp file, `.bak`, MoveFileEx /
rename, recovery from `.tmp` / `.bak`, line-by-line parse, `.corrupt-<time>` copy), 3 and 4 (`core/node.v`: detach
once, removals during update deferred, a destroyed node stops updating), 6 (`Input.release_all`, called by the app on
focus loss), 14 (`audio/sound.v`, `webp/webp.v`: sizes kept unsigned and clamped). Covered by
`tests/robustness_test.v`.

## 2. Correctness gaps (less common, still real)

- **Persistent nodes keep scene-bound state**: a persistent player's RigidBody stays registered to the old,
  destroyed PhysicsWorld; persistent nodes arrive after the new scene's `on_load` (`core/scene.v:77`, `app/app.v:105`).
- **`remove_from_parent` on a live node leaks it** (stays registered as camera, body, asset user); `insert_child` has no
  cycle check and moving across scenes skips `on_destroy` (`core/node.v:50-114`).
- **Moved assets keep their old path** when the content hash is unchanged (`assets/database.v:467`).
- **Floats are saved with 4 decimals** (`0.00005` -> `0`), losing precision on every save (`serialize/value.v:113`).
- **Prefab overrides cannot remove or reorder** children / components (`serialize/writer.v`, `loader.v`).
- **Colliders and body settings are frozen at load**: runtime size / scale / friction / gravity_scale changes do
  nothing; no `rebuild()` or setters (`physics/collider.v`, `body.v`).
- **No physics interpolation**: on 144 Hz displays bodies visibly judder (`physics/world.v:83`).
- **Contacts can point at destroyed nodes for a frame**; `TileMapCollider.rebuild` re-fires `began` for everything on
  the map (`physics/world.v:154`).
- **Audio**: stop / restart clicks (no micro fade), Ogg decoding while holding the mixer lock on the game thread (can
  underrun the 46 ms device queue), hard clipping of the summed mix (`audio/mixer.v`).
- **Spine**: deform timelines ignore the skin and linked meshes never get their parent's deform; IK misses the
  `noRotationOrReflection` parent case and the zero-length chain case (`kine2d/spine_pose.v`).
- **Editor undo**: a cancelled drag (Esc) leaves an empty undo step and wipes redo; checkpoint failures are swallowed
  (`editor/gizmo.v:523`, `editor/panels.v:313`).
- **Rendering**: panel borders show gaps when scaled; post-processing targets are never freed after a scene drops its
  PostProcess (hundreds of MB at 4K with MSAA); `init_shaders` leaks on partial failure; the gg image cache only grows
  on hot reload; `end_frame` with a zero-size window drops the UI layer.
- **Small**: `Node.path()` includes the root but `Scene.find` does not; JPEGs with big EXIF fail size detection;
  same-named component types in two modules overwrite each other in the registry; Esc always quits on desktop.

## 3. Performance (per-frame work that grows with scene size)

| Area | What happens every frame | Better |
|---|---|---|
| Draw list | new array, full sort, 4 component scans per node; `draw_order` rebuilt again for pointer targets and drop zones | reuse the buffer, skip the sort when already ordered, one collect pass shared by drawing, input and drop zones |
| Transforms | `world_matrix` / `screen_matrix` recomputed from the root (sin/cos per level) on every call — UI hit tests, physics sync, camera | cache with dirty flags; cache the view matrix once per frame |
| Hit testing | ancestor walks for UIGroup, ScrollView (O(depth²)), plus a matrix inverse, per widget per pointer | per-frame node data from the collect pass |
| Spine / Kine2D | re-poses and re-meshes on every draw with dozens of allocations (strings in attachment lookups, per-timeline arrays, maps); IK reruns all bones | scratch buffers, integer attachment tables, pre-sorted IK, cache per (time, animation, skin) |
| Particles | ~3 small arrays allocated per particle; vertices transformed 6x per quad; world -> node -> world round trip | reusable buffers, a direct particle draw path |
| Tick loop | `children.clone()` per node; timers / tweens re-filtered even when nothing finished | index loops, filter only on change |
| Strings | `Node.find` (splits the path) in Button / Toggle / ProgressBar / Slider / Joystick every frame; label layout key formatted every frame; string enums compared on hot paths | single-name fast path / cached child; struct keys; parse enums once |
| PostProcess | `find_post` walks the whole tree each frame | register with the scene like cameras |
| Hot reload | rescans all assets every 0.5 s on the main thread, also in shipped desktop builds | off in `-prod`, OS file watcher or a worker thread |
| Prefab spawn | reflection over `map[string]Value` per instance, `choices` re-split per field | cache attributes at register time, clone a built prototype |
| Physics sync | every body (also sleeping / static) walks the parent chain 2-3 times | body move events, dirty flags |

## 4. API / structure

- Global mutable state behind const pointers (`pointer_cache`, `fade_state`, `builtin_effects`) breaks with two
  scenes or renderers: move it onto `Scene` / `Renderer`.
- The quad-drawing loop and sgl state save / restore are copied five times; one `begin_textured / quad /
  end_textured` helper would remove the drift (some copies skip the fade and draw-call count).
- 'simple' sprites take a different path (gg `draw_image_with_config`, loses shear) from every other draw mode: route
  them through the same batch.
- Missing basics compared with Godot / Unity: `on_enable` / `on_disable`, signals / events, groups / tags, find by
  type, configurable Esc. (See `docs/godot_parity.md` for the feature list.)

## 5. Tests and tooling

- `physics/box2d.v` has no Windows link path: physics tests need `-d box2d_source` and gcc, and
  `tests/tilemap_features_test.v` imports physics, so its non-physics tests cannot build on a stock Windows setup.
  Split it or document the flags.
- `tests/spine42_test.v` and `tests/webp_test.v` default to a personal path and print "skipped" (pass) everywhere
  else: commit a small fixture pack.
- Test binaries that import gg hide their assertion output on Windows; `-subsystem console` shows it — worth a
  note in the README / `velo doctor`.
- No tests for: physics destroy order / reparent / flipped bodies, mixer threading and clicks, Spine colour /
  deform / inherit modes, editor undo flows, `optimize_assets.py`, importer name collisions.
- Importers: output and copied-file name collisions overwrite silently; `new_id` rescans every `.meta` per asset;
  atlas page paths are not confined to the assets folder.

## Suggested order

1. Data safety and crashes: 1-4, 6, 14 (small, contained fixes).
2. Visible bugs: 5, 9-13, 15, physics inactive / frozen settings, audio clicks.
3. Tooling: 7 and the importer collisions (they silently damage content).
4. One collect pass + cached transforms (removes most per-frame cost in UI-heavy and large scenes).
5. Spine / particle allocation work (largest per-frame cost in battle scenes).
6. Structure: move global state onto Scene / Renderer, unify quad drawing, simple-sprite path.

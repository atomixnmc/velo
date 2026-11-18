# Agent handoff — local engine work (November 2026)

Notes for an AI agent (or a person) continuing the engine work on this branch. They cover what changed on top of
`main`, how to test it, and the rules for publishing it. User-facing API docs stay in `README.md`, the code review
findings are in `docs/code_review_2026_11.md`, and the Godot comparison and roadmap are in `docs/godot_parity.md`.

## 1. Branches

| Branch | Where | What |
|---|---|---|
| `main` | upstream `origin` | upstream engine |
| `spine42-loader` | local working branch | all the work below; most of it is uncommitted in the working tree |
| `snapshot/<date>` | fork | sanitised snapshots of the working tree (section 5); the latest is the newest date |
| `feat/spine42-webp-loader`, `feat/asset-mounts`, `fix/windows-*` | fork | smaller topic branches proposed upstream |

Upstream contribution (PRs from the topic branches or the snapshot) is deferred: do not open PRs unless asked.

## 2. What the local work adds

### Runtime (app/, render/, core/, assets/, audio/)
- **Silent frame capture:** `app/capture.v`.
  - `VELO_CAPTURE=<png>` renders in a hidden window at the design size and reads the back buffer with `glReadPixels` before the swap.
  - It writes the PNG and quits. `VELO_CAPTURE_AFTER=<s>` sets the delay (default 3); `VELO_CAPTURE_EXIT` controls quitting.
  - A capture also mutes the mixer.
- **Mute:** `VELO_MUTE=1` sets the mixer master to 0. Do not skip `audio.start()`: an un-started mixer panics on its empty buffer.
- **Frame pacing:**
  - gg `swap_interval: 0` with the window swap interval set to 1, plus a 240 FPS fallback cap.
  - `VELO_VSYNC=0` uncaps for profiling.
  - Windows timer resolution: `app/timer_windows.c.v` (`@[c_extern]` declaration, because including windows.h breaks builds through its `far`/`near` macros). The default is in `app/timer_default.c.v`.
- **Profiling:** `VELO_PROFILE=<file|1>`.
  - Writes a FrameProfile line every 2 s (update / draw / end / outside).
  - Synchronous in-frame texture loads of 8 ms or more are logged as `SLOW texture` (`render.profile_log`, `slow_load_ms`).
- **Preloading:** `App.preload(keys)` / `App.preload_done()` decode on worker threads (`app/preload.v`: `Preloader.add` and `add_keys`). Games show a loading cover until it's done.
- **Store robustness:** `core/store.v` and `core/store_sync.c.v`.
  - Writes go to a flushed temp file with a `.bak`, then MoveFileEx or rename.
  - On open it recovers from `.tmp` or `.bak`, parses line by line, and keeps a `.corrupt-<time>` copy.
- **Node lifetime:** `core/node.v` detaches once; removals during `update` are deferred; a destroyed node stops updating.
- **Input:** `Input.release_all()` runs on focus loss, so keys aren't stuck after alt-tab.
- **Audio and WebP:** chunk sizes stay unsigned and clamped (`audio/sound.v`, `webp/webp.v`).
- **UI widgets** (documented in README "UI"):
  - Button sprite states, glow and scale;
  - Toggle sprites; ToggleGroup;
  - ProgressBar smooth fill and trail;
  - ScrollView scroll bars; Mask;
  - Slider, Draggable / DropZone, UIGroup, Form;
  - Label optical centring, padding and auto_size;
  - Sprite `ornament_x/y` (stretch-safe panels) and `fit`;
  - `core.Spring`.
- **Tile maps:** per-tile flips and rotation, animated tiles, 16-tile edge autotiling, `TileMapCollider`, Tiled import.

### Kine2D / Spine
- **Spine UVs** (`kine2d/kine2d.v` spine_meshes): normalised by the **atlas-declared page size**, not the loaded image size.
  Many packs ship page images resized to powers of two, and using the image size scrambles every attachment.
- **Spine 4.2 JSON and atlas loading and posing:** `kine2d/spine.v` and `spine_pose.v`. WebP pages are decoded by `webp/`.

### Tools and examples
- `tools/gen_gothic_ui.py`: a stretch-safe gothic UI kit with `ui_kit.json` borders and ornament spans; `--check` verifies no stretched band holds a detail.
- `tools/import_assets.py`: Unity, Godot and Tiled import. `tools/optimize_assets.py`: see the review, item 7, before using `--webp` on atlases.
- `examples/effects`, `examples/postfx`, `examples/ui_gothic`: demo scenes for particles and imports, post-processing, and the gothic kit.

## 3. Open work

- **Code review:** `docs/code_review_2026_11.md` lists the problems. Items 1–4, 6 and 14 are fixed. Next by severity:
  - 5: flipped physics bodies;
  - 7: optimizer breaking atlases;
  - 8: loader merging siblings;
  - 9: Mask hit testing;
  - 10: scissor;
  - 11: NaN;
  - 12: Spine PMA;
  - 13: Spine colour overflow;
  - 15: inactive physics.
- **Godot parity roadmap:** `docs/godot_parity.md`. Input actions and gamepad first, then the animation timeline, then the character controller.
- **Missing feature:** a built-in Parallax component. Games currently implement their own parallax loop.

## 4. Build and test

- V 0.5.2. On Windows use **gcc** (`-cc gcc`): tcc builds have no sound.
- Unit tests: `v -cc gcc test tests/`.
- **Spine and WebP pack tests** read every pack under `SPINE42_REFS` and are skipped when it is unset.
  Never hard-code a local pack path in a test.
- Run graphical checks hidden and muted (`VELO_CAPTURE` + `VELO_MUTE=1`). Never open visible windows on the user's desktop.
- **V pitfalls:**
  - `dump` is a builtin;
  - no locals named `far` or `near` on Windows;
  - use `1_000_000_000.0` instead of `1e9` inside string interpolation;
  - if V offers to upload a C compiler bug report, decline: it would send local code.

## 5. Publishing (the fork is public)

Never push the working checkout directly, and do not switch or reset the user's checkout. Publish a snapshot built from a
temporary index:

```bash
export GIT_INDEX_FILE=$(mktemp -u)
git read-tree HEAD
git add -A . ':!tools/v2js' ':!webgl/pnpm-lock.yaml'   # never publish these two: another contributor's local edits
# replace any file that leaks local details with a sanitised blob:
#   git update-index --cacheinfo 100644,$(git hash-object -w <clean copy>),<path>
T=$(git write-tree)
git grep -nIiE '<drive>:[/\\]|C:[/\\]Users|<private project names>' $T -- . ':!thirdparty'   # must print nothing
C=$(git commit-tree $T -p <previous snapshot> -m "Engine snapshot of the current local work (<date>)")
git update-ref refs/heads/snapshot/<date> $C
git push fork snapshot/<date>
rm -f "$GIT_INDEX_FILE"
```

- **Leak scan:** check the exact tree being pushed for absolute local paths, user folders, and the names of private
  game projects or third-party asset packs. That covers file content, file names, branch names and commit messages.
- **Generated reports** (`examples/*/assets/prefabs/imported/import_report.md`) record absolute import paths. Strip them to
  repo-relative paths in the snapshot.
- Keep this document free of local paths and private project names too: it is published.

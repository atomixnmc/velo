# Velo vs Godot 4 (2D) — feature parity

Status as of 2026-11-14, against Godot 4's 2D feature set (3D, XR and GDScript-the-language are out of scope:
Velo is a 2D engine and its game code is V). Legend: **done** = comparable, **partial** = the common cases,
**missing** = not in the engine.

## Summary

Velo covers the core of a 2D game as well as Godot does: scene tree with components, prefab scenes with
overrides, hot reload, sprites / sheets / 9-slice, UI with anchors and layouts, particles, tile maps in every
Godot layout, Box2D physics, Spine / skeletal animation, audio buses, tweens, a scene editor, and desktop /
Android / iOS / Web builds. The biggest gaps for shipping a Godot-style 2D game are: an **animation timeline**
(keyframe any property), **2D lights and shadows**, **navigation / path finding**, **kinematic character
movement** (move_and_slide), **input actions with gamepads**, **localization**, **rich text**, and **physics
joints**. Editor gaps: animation editor, multi-select, copy/paste between scenes.

## Detail

| Area | Godot 4 | Velo | Status | Gap / note |
|---|---|---|---|---|
| Scene tree | Node tree, scenes, instancing, inheritance | Node + Component tree, Scene = Prefab, `from` instancing with overrides | done | removing a prefab component via override |
| Signals | signals / `connect` | per-frame flags (`Button.clicked`, contact `began`), callbacks in tweens | partial | a general event / signal bus |
| Groups | node groups, `get_nodes_in_group` | — | missing | tags + query |
| Scripting | GDScript / C#, hot reload | V components, scene hot reload (code needs a rebuild) | partial | code hot reload (V `-live`) |
| Resources | `.tres` custom resources | assets with `.meta` ids, ref counting, dependency graph | done | user-defined resource types (JSON assets work) |
| Sprites | Sprite2D, AnimatedSprite2D, NinePatchRect | Sprite (simple / sliced / tiled), SpriteAnimator | done | |
| Skeletal | Skeleton2D, Spine via plugin | Kine2D + Spine 4.2 JSON built in | done | binary `.skel`, IK constraint editing |
| Shaders | canvas_item shaders, visual shader | per-sprite `.glsl` effects (all backends), 15 built-in SpriteFx effects | partial | visual shader editor; D3D11 / WebGPU backends lack shaders |
| Post-processing | WorldEnvironment glow, adjustments, `BackBufferCopy` | `PostProcess` (bloom, grade, LUT, vignette, CA, grain, flash, custom pass) | done | screen-reading shaders mid-scene |
| 2D lights | PointLight2D, DirectionalLight2D, normal maps, LightOccluder2D shadows | — (additive glow sprites only) | missing | light pass into an offscreen buffer, now possible with the post-processing render target |
| Particles | GPUParticles2D / CPUParticles2D, process material, sub-emitters, trails, turbulence, collision | ParticleSystem (CPU): shapes, gravity, damping, spin, 3-key colour, flipbook | partial | curves with many keys, sub-emitters, trails, turbulence, attractors, collisions |
| Tile maps | TileMapLayer: square / iso / half-offset / hex, terrains, animated tiles, physics / navigation layers, scene tiles | TileMap: orthogonal / isometric / staggered / hex, flips + rotations, animated tiles, 16-tile edge autotiling, TileMapCollider, Tiled import | partial | 47-tile corner+edge terrains, multiple tilesets per layer, per-tile navigation, scene tiles, terrain painting in the editor |
| Lines / shapes | Line2D, Polygon2D, Path2D / PathFollow2D | MeshDrawable (any triangles) | partial | Line2D with joints / caps, path following |
| Parallax | Parallax2D | games do it themselves (their own parallax loop) | missing | a built-in Parallax component |
| Camera | Camera2D: smoothing, limits, zoom, drag margins, shake (custom) | Camera: follow, smoothing, limits, zoom, shake | done | drag margins |
| UI | Control nodes, containers, themes, RichTextLabel (BBCode), focus / gamepad navigation | UITransform anchors, Layout, Panel, Button, Toggle, ProgressBar, ScrollView, TextInput, Joystick | partial | rich text, themes, sliders / dropdowns / lists, keyboard / gamepad focus |
| Text | dynamic fonts, outlines, shadows, localization (`tr`, CSV / PO) | TTF fonts, wrap / shrink, outline, shadow | partial | localization tables, right-to-left / shaping |
| Input | InputMap actions, gamepads, touch, gestures | keys, mouse, multi-touch, virtual joystick, axes | partial | named actions, gamepads (sokol has no gamepad API: needs a platform layer), rebinding |
| Audio | buses with effects, AudioStreamPlayer2D, interactive music | mixer with buses (sfx / music / ui / voice), spatial range, fades, WAV / OGG | partial | bus effects (reverb, low-pass, ducking), streaming of long music |
| Physics | Godot / Jolt 2D: bodies, areas, joints, CharacterBody2D, one-way collision, ray / shape queries | Box2D v3: bodies, box / circle / capsule / tile-map colliders, sensors, contacts, raycast | partial | joints, polygon colliders, CharacterBody-style kinematic movement, one-way platforms, shape casts |
| Navigation | NavigationRegion2D, NavigationAgent2D, AStarGrid2D | `TileMap.neighbors` (for your own A*) | missing | grid A* + agent following; nav meshes later |
| Animation | AnimationPlayer (keyframe any property), AnimationTree, state machines | Tween sequences, SpriteAnimator, Kine2D / Spine clips | partial | property timeline asset + player, animation state machine |
| Save data | FileAccess, ConfigFile | Store (saved on quit / background, localStorage on web) | done | |
| Networking | HTTP, WebSocket, high-level multiplayer | — (V's `net.http` / `net.websocket` usable from game code) | missing | engine-level replication |
| Video | VideoStreamPlayer (Theora) | — | missing | |
| Editor | full editor: animation, tile, shader, debugger, profiler, remote tree | scene / prefab editor, inspector, gizmos, tile painting, undo, play button | partial | animation editor, multi-select, copy / paste, profiler view (VELO_PROFILE logs today) |
| Import | asset import presets, compression, atlases | `.meta` import settings; `tools/import_assets.py` (Unity, Godot, Tiled); `tools/optimize_assets.py` | partial | GPU texture compression (ETC2 / ASTC / BC), automatic atlas packing, mipmaps |
| Platforms | Windows, macOS, Linux, Android, iOS, Web | Windows, macOS, Linux, Android, iOS, Web (Emscripten + WebGL path) | done | consoles |

## Suggested order

Ranked by how often a 2D game needs it and how much it unlocks, with a rough size:

1. **Input actions + gamepad** (S–M): an `InputMap` of named actions over keys / touch / gamepad; gamepads need a
   small platform layer (XInput / SDL GameController / Web Gamepad API) since sokol_app has none.
2. **Animation timeline** (M): a `.anim` asset of tracks (node path + property + keys + easing) and an
   `AnimationPlayer` component; the editor gets a simple track view later.
3. **Kinematic character controller + one-way platforms + joints** (M): Box2D v3 has the pieces (shape casts,
   mover, joints); expose `CharacterBody` (`move_and_slide`) and the common joints.
4. **Grid navigation** (S): A* over `TileMap` (`neighbors` already handles every layout) and a `PathFollower`.
5. **2D lights** (M–L): lights drawn into a light buffer and multiplied in the post-processing composite; normal
   maps and occluder shadows after.
6. **Localization + rich text** (M): string tables (CSV), `Label.key`, BBCode-like runs (colour, bold, icons).
7. **Signals / groups** (S): a small typed event bus and node tags.
8. **Texture atlases + GPU compression** (M–L): pack sprites per scene at build time; ETC2 / ASTC on mobile.
9. **Parallax, Line2D, path follow** (S each).
10. **Editor**: multi-select and copy / paste first, then the animation editor.

Items done in this pass: isometric / staggered / hex were already there; added per-tile flips and rotation,
animated tiles, 16-tile edge autotiling, `TileMapCollider`, the Tiled importer and the asset optimizer.

module app

import gg
import os
import sokol.sapp
import time
import velo.core
import velo.assets
import velo.serialize
import velo.render
import velo.audio

pub struct Config {
pub:
	title string = 'Velo Engine'
	// Design resolution: the screen size the game is made for, in screen units. `scale_mode` fits it to the
	// real window / phone screen (see core.ScaleMode): expand (default), fit, fill, width, height or none.
	width      int    = 960
	height     int    = 540
	scale_mode string = 'expand'
	// Desktop window size at startup, in points; 0 = the design resolution.
	window_width  int
	window_height int
	assets_dir    string = 'assets'
	scene         string // path (within assets) or asset ID of the startup scene
	background    core.Color = core.rgba(30, 30, 40, 255)
	hot_reload    bool       = true // always off on Android/iOS
	font_path     string // .ttf used for text; empty = the platform default
	// Names the save data folder (see open_store); '' = made from the title. Keep it once the game ships.
	app_id string
	// Where to save the player's data instead of the platform's usual place (desktop and phones).
	save_file string
	// Set this hook to run code after each time the scene is (re)loaded.
	on_scene_loaded fn (mut a App) = unsafe { nil }
}

// App — game loop: read input -> scene.update(dt) -> draw -> check hot reload.
@[heap]
pub struct App {
pub mut:
	cfg      Config
	ctx      &gg.Context = unsafe { nil }
	db       &assets.AssetDatabase
	registry &serialize.Registry
	loader   &serialize.SceneLoader
	scene    &core.Scene = unsafe { nil }
	input    &core.Input
	renderer &render.Renderer = unsafe { nil }
	scene_id string
	// Where the game is drawn in the window this frame (see core.fit_screen).
	fit core.ScreenFit
	// The safe area insets in window points, refreshed twice a second (the scene gets them in screen units).
	safe_insets core.Insets
	// The player's saved data, given to every scene (scene.store); saved on quit and when sent to the background.
	store &core.Store
mut:
	keyboard_shown bool
	fade           SceneFade
	preload        Preloader
	mode           core.ScaleMode
	last_ticks     i64
	reload_timer   f32
	fps            f32
	prof           FrameProfile // VELO_PROFILE=1: per-stage frame timing, printed every 2 s
	capture        FrameCapture // VELO_CAPTURE=<png>: silent screenshot (capture.v)
	safe_timer     f32
}

// new opens the AssetDatabase and registers built-in components. Call app.register[T]() for the game's components,
// then app.run().
//
// On Android/iOS, assets_dir is ignored: the assets packaged by `velo build android|ios` are used instead.
pub fn new(config Config) !&App {
	cfg := Config{
		...config
		assets_dir: runtime_assets_dir(config.assets_dir)!
		hot_reload: config.hot_reload && !is_mobile() && !is_web() // packaged assets never change
	}
	mode := core.scale_mode_from_str(cfg.scale_mode)!
	setup_web_gc()
	mut db := assets.open(cfg.assets_dir)!
	mut reg := serialize.new_registry()
	render.register_builtins(mut reg)
	audio.register_builtins(mut reg)
	mut a := &App{
		cfg:      cfg
		db:       db
		registry: reg
		loader:   serialize.new_loader(reg, db)
		input:    &core.Input{}
		mode:     mode
		store:    open_store(cfg)
	}
	a.update_fit()
	println('[velo] ${db.len()} assets in ${db.root}')
	return a
}

// register registers a game component so it can be used in .scene files.
pub fn (mut a App) register[T]() {
	a.registry.register[T]()
}

// load_scene replaces the current scene (calls on_destroy on the old scene, releases assets no longer in use).
pub fn (mut a App) load_scene(key string) ! {
	mut next := a.loader.load_scene(key)!
	next.input = a.input
	next.store = a.store
	next.key = a.db.resolve(key) or { key }
	a.apply_fit(mut next)
	if a.scene != unsafe { nil } {
		next.take_persistent(mut a.scene)
		a.scene.unload()
	}
	a.scene = next
	a.scene_id = next.key
	if a.cfg.on_scene_loaded != unsafe { nil } {
		a.cfg.on_scene_loaded(mut a)
	}
	println('[velo] loaded scene "${a.db.path_of(a.scene_id) or { key }}" (${a.scene.node_count()} nodes, ${a.db.loaded_count()} assets in memory)')
}

pub fn (mut a App) run() {
	a.ctx = gg.new_context(
		bg_color:     gg.Color{a.cfg.background.r, a.cfg.background.g, a.cfg.background.b, 255}
		width:        if a.cfg.window_width > 0 && !capture_on() { a.cfg.window_width } else { a.cfg.width }
		height:       if a.cfg.window_height > 0 && !capture_on() { a.cfg.window_height } else { a.cfg.height }
		window_title: a.cfg.title
		font_path:    if a.cfg.font_path != '' { a.cfg.font_path } else { system_font() }
		init_fn:      on_init
		frame_fn:     on_frame
		cleanup_fn:   on_cleanup
		event_fn:     on_event
		user_data:    a
		// 0 = gg does not sleep its fixed 60 Hz budget (pace_frame); vsync is turned back on below on the window.
		swap_interval: 0
	)
	$if android {
		// sokol asks for GLES 3.1 by default, which emulators and older devices lack; gg only needs 3.0.
		a.ctx.window.gl.major_version = 3
		a.ctx.window.gl.minor_version = 0
	}
	// Pace by vsync only. gg sleeps a fixed 60 Hz budget on top of vsync when its swap_interval is set
	// (pace_frame); that drifts against 59/75/144 Hz displays, frames miss a vblank and 50 FPS snaps to 30.
	// So gg gets swap_interval 0 and the sokol window gets vsync directly.
	// on_frame caps at fallback_max_fps itself in case the platform ignores vsync.
	unsafe {
		mut win := &a.ctx.window // the field is not `mut` in gg; gcc builds reject the plain assignment
		win.swap_interval = if vsync_off { 0 } else { 1 } // VELO_VSYNC=0: uncapped, for profiling
	}
	precise_timers(true) // Windows: 1 ms sleep granularity for the fallback cap (timer_windows.c.v)
	a.ctx.run()
	precise_timers(false)
}

fn on_init(mut a App) {
	if capture_on() {
		hide_window_for_capture()
	}
	a.renderer = render.new_renderer(a.ctx, a.db)
	audio.start()
	// VELO_MUTE=1 or a silent capture (VELO_CAPTURE): the device stays open (the mixer needs it) but the master
	// gain is 0, so hidden test runs make no sound. Nothing else sets the master gain.
	if capture_on() || os.getenv('VELO_MUTE') == '1' {
		mut m := audio.mixer()
		m.master = 0
	}
	a.load_scene(a.cfg.scene) or {
		eprintln('[velo] scene load error: ${err}')
		exit(1)
	}
	a.last_ticks = time.ticks()
}

// fallback_max_fps caps the frame rate only when vsync is not honoured (frames arrive faster than this).
const fallback_max_fps = 240

// vsync_off: VELO_VSYNC=0 runs uncapped (profiling only).
const vsync_off = os.getenv('VELO_VSYNC') == '0'

// VELO_PROFILE=1 prints per-stage frame times every 2 s to stderr; VELO_PROFILE=<file> appends them to that file
// (GUI builds on Windows have no console, so stderr is lost there). See render.profile_log.
const profile_on = os.getenv('VELO_PROFILE') != ''

// FrameProfile sums stage times (ns) and prints averages: update (scene logic), draw (CPU draw submission),
// end (gg/sokol flush and GPU submit), outside (present, vsync wait, OS), worst full frame.
struct FrameProfile {
mut:
	last_end i64
	outside  i64
	update   i64
	draw     i64
	end      i64
	worst    i64
	calls    i64
	frames   int
	since    i64
}

fn (mut p FrameProfile) add(update i64, draw i64, end i64, total i64, calls int) {
	p.update += update
	p.draw += draw
	p.end += end
	p.calls += calls
	p.frames++
	if total > p.worst {
		p.worst = total
	}
	now := time.sys_mono_now()
	if p.since == 0 {
		p.since = now
	}
	if now - p.since >= 2_000_000_000 && p.frames > 0 {
		n := f64(p.frames) * 1_000_000.0
		line := '[velo] PROFILE fps=${f64(p.frames) / (f64(now - p.since) / 1_000_000_000.0):.1f} update_ms=${f64(p.update) / n:.2f} draw_ms=${f64(p.draw) / n:.2f} end_ms=${f64(p.end) / n:.2f} outside_ms=${f64(p.outside) / n:.2f} worst_in_frame_ms=${f64(p.worst) / 1_000_000.0:.1f} draw_calls=${p.calls / i64(p.frames)}'
		render.profile_log(line)
		p = FrameProfile{
			last_end: p.last_end
		}
	}
}

fn on_frame(mut a App) {
	mut now := time.ticks()
	if now - a.last_ticks < 1000 / fallback_max_fps && !vsync_off {
		time.sleep(time.Duration(1000 / fallback_max_fps - (now - a.last_ticks)) * time.millisecond)
		now = time.ticks()
	}
	mut dt := f32(now - a.last_ticks) / 1000.0
	a.last_ticks = now
	if dt > 0.1 {
		dt = 0.1 // avoid a big "jump" after dragging the window / debugging
	}
	if dt > 0 {
		a.fps = a.fps * 0.95 + (1.0 / dt) * 0.05
	}

	if a.input.was_pressed(.f1) {
		a.renderer.debug = !a.renderer.debug
	}
	a.fit_scale()
	a.update_fit()
	a.safe_timer -= dt
	if a.safe_timer <= 0 {
		a.safe_timer = 0.5 // cheap, but not free on Android (JNI); insets only change on rotation
		if insets := query_safe_insets(a.ctx.scale) {
			if insets != a.safe_insets {
				a.safe_insets = insets
				println('[velo] safe area insets: left ${insets.left} top ${insets.top} right ${insets.right} bottom ${insets.bottom}')
			}
		}
	}
	t_start := time.sys_mono_now()
	if a.prof.last_end > 0 {
		a.prof.outside += t_start - a.prof.last_end // present / vsync / OS between frames
	}
	a.apply_fit(mut a.scene)
	a.scene.update(dt)
	a.sync_keyboard()
	a.input.end_frame()
	a.preload.pump(mut a.renderer)
	a.update_scene_change(dt)
	audio.pump()

	t_update := time.sys_mono_now()
	a.ctx.begin()
	a.renderer.base_clip =
		render.Rect{a.fit.area_pos.x, a.fit.area_pos.y, a.fit.area_size.x, a.fit.area_size.y}
	a.renderer.draw_scene(a.scene, a.fit.to_window())
	a.draw_fade()
	a.draw_bars()
	if a.renderer.debug {
		a.ctx.draw_text(int(a.window_points().x) - 10, 10,
			'FPS ${int(a.fps)} | node ${a.scene.node_count()} | asset ${a.db.loaded_count()}/${a.db.len()} | draw ${a.renderer.draw_calls}',
			size:  16
			color: gg.Color{255, 255, 0, 255}
			align: .right
		)
	}
	t_draw := time.sys_mono_now()
	a.renderer.end_frame() // ctx.end(), or the PostProcess chain (render/postfx.v)
	a.capture.capture_frame() // VELO_CAPTURE: read the finished frame before sokol swaps it (capture.v)
	t_end := time.sys_mono_now()
	if profile_on {
		a.prof.add(t_update - t_start, t_draw - t_update, t_end - t_draw, t_end - t_start, a.renderer.draw_calls)
	}
	a.prof.last_end = t_end

	for ev in a.db.drain_events() {
		a.on_asset_event(ev)
	}
	if a.cfg.hot_reload {
		a.reload_timer += dt
		if a.reload_timer >= 0.5 {
			a.reload_timer = 0
			a.check_hot_reload()
		}
	}
}

// sync_keyboard shows the phone's on-screen keyboard while a text field is being edited.
fn (mut a App) sync_keyboard() {
	if a.input.text_editing != a.keyboard_shown {
		a.keyboard_shown = a.input.text_editing
		$if android || ios || emscripten ? {
			sapp.show_keyboard(a.keyboard_shown)
		}
	}
}

fn on_cleanup(mut a App) {
	a.store.save_if_changed()
	a.preload.pool.close()
	audio.shutdown()
}

// SceneFade — the fade of a scene change in progress (see core.Scene.change_scene).
struct SceneFade {
mut:
	target   string
	change   core.SceneChange
	alpha    f32 // 0 = clear, 1 = covered
	fading   bool
	coming   bool // fading back in, after loading
	web_save f32
}

// update_scene_change carries out scene.change_scene: fade out (the old scene keeps running) while the textures
// and sounds of the next scene are decoded in the background (see Preloader), load it, fade in.
fn (mut a App) update_scene_change(dt f32) {
	mut f := &a.fade
	if a.scene.next_scene != '' && !f.fading {
		f.target = a.scene.next_scene
		f.change = a.scene.next_change
		f.fading = true
		f.coming = false
		a.scene.next_scene = ''
		a.preload.start(mut a.db, a.renderer, f.target)
	}
	if f.fading {
		step := if f.change.fade > 0 { dt / f.change.fade } else { f32(1) }
		if !f.coming {
			// a cut (fade 0) keeps showing the old scene until the new one is decoded
			if f.change.fade > 0 {
				f.alpha = if f.alpha + step > 1 { f32(1) } else { f.alpha + step }
			}
			if (f.alpha >= 1 || f.change.fade <= 0) && a.preload.done() {
				a.load_scene(f.target) or { eprintln('[velo] change_scene("${f.target}"): ${err}') }
				a.preload.release(mut a.db)
				f.coming = true
			}
		} else {
			f.alpha = if f.alpha - step < 0 { f32(0) } else { f.alpha - step }
			if f.alpha <= 0 {
				f.fading = false
			}
		}
	}
	$if emscripten ? {
		// a browser tab can close without warning: keep localStorage up to date
		f.web_save += dt
		if f.web_save >= 1 {
			f.web_save = 0
			a.store.save_if_changed()
		}
	}
}

// loading_progress: 0..1 while the next scene's assets are decoded during a scene change, else 1.
pub fn (a &App) loading_progress() f32 {
	return a.preload.progress()
}

// preload decodes textures and sounds on worker threads before they are first drawn or played, so spawning
// them later does not stall a frame. Keys are asset ids or paths (mounted folders work). Use it for assets a
// scene creates from code (rigs, effects, HUD art), behind a fade or loading screen, and wait for
// preload_done(). References are held until the next scene change completes.
pub fn (mut a App) preload(keys []string) {
	a.preload.add_keys(mut a.db, a.renderer, keys)
}

// preload_done: true once everything queued by preload (or a scene change) is decoded and uploaded.
pub fn (a &App) preload_done() bool {
	return a.preload.done()
}

fn (mut a App) draw_fade() {
	if a.fade.alpha <= 0 {
		return
	}
	c := a.fade.change.color
	w := a.window_points()
	a.ctx.draw_rect_filled(0, 0, w.x, w.y, gg.Color{c.r, c.g, c.b, u8(f32(c.a) * a.fade.alpha)})
}

// on_asset_event: the renderer frees GPU images, the mixer forgets decoded sounds.
fn (mut a App) on_asset_event(ev assets.AssetEvent) {
	a.renderer.on_asset_event(ev)
	if ev.kind in [.unloaded, .removed] {
		mut m := audio.mixer()
		m.forget(ev.id)
	}
}

// window_points: the window size in points (the configured size until the window exists).
fn (a &App) window_points() core.Vec2 {
	if a.ctx == unsafe { nil } {
		return core.vec2(if a.cfg.window_width > 0 { a.cfg.window_width } else { a.cfg.width }, if a.cfg.window_height > 0 {
			a.cfg.window_height
		} else {
			a.cfg.height
		})
	}
	sz := a.ctx.window_size() // gg.window_size() assumes the dpi scale, which Android does not use
	return core.vec2(sz.width, sz.height)
}

// update_fit recomputes where the design resolution goes in the window (it changes when the window is resized
// or the phone rotates).
fn (mut a App) update_fit() {
	a.fit = core.fit_screen(a.window_points(), core.vec2(a.cfg.width, a.cfg.height), a.mode)
}

// apply_fit gives the scene its visible area and safe area, in screen units.
fn (a &App) apply_fit(mut s core.Scene) {
	s.view_origin = a.fit.view_origin
	s.view_size = a.fit.view_size
	s.safe_insets = a.fit.insets_from_window(a.window_points(), a.safe_insets)
}

// to_screen converts a window point (gg mouse/touch coordinates) to screen units.
fn (a &App) to_screen(x f32, y f32) core.Vec2 {
	return a.fit.from_window(core.vec2(x, y))
}

// draw_bars covers what is outside the game area (letterbox bars of the `fit` scale mode) in black.
fn (mut a App) draw_bars() {
	w := a.window_points()
	p := a.fit.area_pos
	sz := a.fit.area_size
	if p.x <= 0 && p.y <= 0 && sz.x >= w.x && sz.y >= w.y {
		return
	}
	a.ctx.scissor_rect(0, 0, int(w.x), int(w.y))
	black := gg.Color{0, 0, 0, 255}
	a.ctx.draw_rect_filled(0, 0, w.x, p.y, black)
	a.ctx.draw_rect_filled(0, p.y + sz.y, w.x, w.y - p.y - sz.y, black)
	a.ctx.draw_rect_filled(0, p.y, p.x, sz.y, black)
	a.ctx.draw_rect_filled(p.x + sz.x, p.y, w.x - p.x - sz.x, sz.y, black)
}

// fit_scale: gg's scale (framebuffer pixels per window point) comes from the configured size on Android at
// startup but from the screen density after a rotation. Pin it to the density; the scale mode does the fitting.
// Text must use the same scale, which gg forgets when it loads the font from memory (as on Android).
fn (mut a App) fit_scale() {
	$if android {
		a.ctx.scale = gg.dpi_scale()
	}
	if a.ctx.ft != unsafe { nil } && a.ctx.ft.scale != a.ctx.scale {
		a.ctx.ft.scale = a.ctx.scale
	}
}

// check_hot_reload: texture changed -> draw the new image; scene/prefab changed -> reload the current scene.
fn (mut a App) check_hot_reload() {
	events := a.db.poll_changes()
	mut reload := false
	used := a.db.dependencies_deep(a.scene_id)
	for ev in events {
		a.on_asset_event(ev)
		if ev.kind == .unloaded {
			continue
		}
		println('[hot-reload] ${ev.kind}: ${ev.path}')
		if ev.kind == .modified && (ev.id == a.scene_id || ev.id in used) {
			if e := a.db.entry(ev.id) {
				if e.kind == .scene {
					reload = true
				}
			}
		}
	}
	if reload {
		a.load_scene(a.scene_id) or {
			eprintln('[hot-reload] keeping the old scene due to error: ${err}')
		}
	}
}

fn on_event(e &gg.Event, mut a App) {
	match e.typ {
		.key_down {
			if e.key_repeat {
				a.input.key_repeat(int(e.key_code))
			} else {
				a.input.key_down(int(e.key_code))
			}
			if e.key_code == .escape && !a.keyboard_shown { // Esc while typing leaves the text field instead
				a.ctx.quit()
			}
		}
		.char {
			a.input.type_char(e.char_code)
		}
		.key_up {
			a.input.key_up(int(e.key_code))
		}
		.mouse_move {
			a.input.mouse = a.to_screen(e.mouse_x, e.mouse_y) // gg already divides by the dpi scale
		}
		.mouse_down {
			// A click can arrive without a move before it (first click in a browser page, synthetic events).
			a.input.mouse = a.to_screen(e.mouse_x, e.mouse_y)
			if e.mouse_button == .left {
				a.input.mouse_press()
			}
		}
		.mouse_up {
			a.input.mouse = a.to_screen(e.mouse_x, e.mouse_y)
			if e.mouse_button == .left {
				a.input.mouse_release()
			}
		}
		.mouse_scroll {
			a.input.mouse_scroll(e.scroll_x, e.scroll_y)
		}
		.touches_began, .touches_moved, .touches_ended, .touches_cancelled {
			a.on_touch(e)
		}
		.unfocused {
			a.input.focus_lost = true
			a.input.release_all() // key-ups of keys held now never arrive
		}
		.suspended, .iconified {
			a.input.focus_lost = true
			a.input.release_all()
			mut m := audio.mixer()
			m.set_paused(true) // app in the background (phones) or minimized
			a.store.save_if_changed() // a phone may kill a background app without warning
		}
		.resumed, .restored {
			mut m := audio.mixer()
			m.set_paused(false)
		}
		else {}
	}
}

// on_touch forwards every finger that changed to Input (which also emulates the mouse with the first one).
fn (mut a App) on_touch(e &gg.Event) {
	scale := if a.ctx.scale > 0 { a.ctx.scale } else { f32(1) }
	for i in 0 .. e.num_touches {
		t := e.touches[i]
		if !t.changed {
			continue
		}
		pos := a.to_screen(t.pos_x / scale, t.pos_y / scale)
		match e.typ {
			.touches_began { a.input.touch_begin(t.identifier, pos) }
			.touches_moved { a.input.touch_move(t.identifier, pos) }
			.touches_ended { a.input.touch_end(t.identifier, pos, false) }
			else { a.input.touch_end(t.identifier, pos, true) }
		}
	}
}

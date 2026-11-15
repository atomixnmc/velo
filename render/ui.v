module render

import math
import velo.core
import velo.assets

// UI components. They live in the world like any other node (the scene has no camera, so world = screen):
//
//   node Menu {
//     UITransform { size = [300, 200] }
//     Panel { color = [30, 30, 40, 230]  radius = 8 }
//     node Play {
//       UITransform { size = [160, 44] }
//       Panel { color = [70, 130, 220, 255]  radius = 6 }
//       Button { }
//       node Text { Label { text = "Play"  align = "center"  valign = "middle" } }
//     }
//   }
//
// UITransform gives a node its rectangle; Panel/ProgressBar draw it, Button/Toggle/ScrollView react to the
// mouse inside it, Widget/Layout position nodes relative to it.

// Rect — an axis-aligned rectangle (node space or screen space depending on where it comes from).
pub struct Rect {
pub mut:
	x f32
	y f32
	w f32
	h f32
}

pub fn (r Rect) has(p core.Vec2) bool {
	return p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h
}

pub fn (r Rect) intersect(o Rect) Rect {
	x0 := math.max(r.x, o.x)
	y0 := math.max(r.y, o.y)
	x1 := math.min(r.x + r.w, o.x + o.w)
	y1 := math.min(r.y + r.h, o.y + o.h)
	return Rect{x0, y0, math.max(x1 - x0, 0), math.max(y1 - y0, 0)}
}

// UITransform — the rectangle of a UI node, in node space: `anchor` is where the node's position sits in it
// ((0,0) top-left corner, (0.5,0.5) center).
pub struct UITransform {
	core.Component
pub mut:
	size   core.Vec2 = core.Vec2{100, 100}
	anchor core.Vec2 = core.Vec2{0.5, 0.5}
}

pub fn (t &UITransform) rect() Rect {
	return Rect{-t.anchor.x * t.size.x, -t.anchor.y * t.size.y, t.size.x, t.size.y}
}

// node_rect: the node's rectangle in node space — its UITransform, otherwise its Sprite.
pub fn node_rect(n &core.Node) ?Rect {
	if t := n.get_component[UITransform]() {
		return t.rect()
	}
	if s := n.get_component[Sprite]() {
		x, y, w, h := s.local_rect()
		if w > 0 && h > 0 {
			return Rect{x, y, w, h}
		}
	}
	if tm := n.get_component[TileMap]() {
		x, y, w, h := tm.local_rect()
		if w > 0 && h > 0 {
			return Rect{x, y, w, h}
		}
	}
	return none
}

// hit_test: true if the screen point `p` (input.mouse, a touch) is inside the node's rectangle and not clipped away
// by a ScrollView above it. The scene camera applies unless the node is under a Canvas.
pub fn hit_test(n &core.Node, p core.Vec2) bool {
	return hit_test_in(n, p, true)
}

// hit_test_world: like hit_test, with a world point and no camera (the editor picks this way).
pub fn hit_test_world(n &core.Node, p core.Vec2) bool {
	return hit_test_in(n, p, false)
}

fn hit_test_in(n &core.Node, p core.Vec2, screen bool) bool {
	if screen && !group_interactable(n) {
		return false // under a UIGroup with interactable = false (or fully faded)
	}
	r := node_rect(n) or { return false }
	if !r.has(node_point(n, p, screen)) {
		return false
	}
	mut cur := n.parent
	for cur != unsafe { nil } {
		if sv := cur.get_component[ScrollView]() {
			if sv.enabled && sv.clip {
				vr := node_rect(cur) or { Rect{} }
				if !vr.has(node_point(cur, p, screen)) {
					return false
				}
			}
		}
		cur = cur.parent
	}
	return true
}

fn node_point(n &core.Node, p core.Vec2, screen bool) core.Vec2 {
	m := if screen { n.screen_matrix() } else { n.world_matrix() }
	return m.inverse().apply(p)
}

// ---------- Pointer targets ----------

// UI that takes the pointer (Button, ScrollView, Joystick, TextInput, and Panels with block_input) is hit in
// draw order: only the topmost element under a click receives it, so a dialog stops the buttons behind it.
// An element still receives presses on its own children (a button inside a ScrollView: the ScrollView can
// start a drag from it).

@[heap]
struct PointerCache {
mut:
	scene   voidptr
	frame   u64
	targets []&core.Node // pointer targets in draw order, for `frame`
}

const pointer_cache = &PointerCache{}

fn is_pointer_target(n &core.Node) bool {
	for c in n.components {
		if !c.enabled {
			continue
		}
		if c is Button || c is ScrollView || c is Joystick || c is TextInput || c is Slider || c is Draggable {
			return true
		}
		if c is Panel && c.block_input {
			return true
		}
	}
	return false
}

fn pointer_targets(sc &core.Scene) []&core.Node {
	mut pc := unsafe { pointer_cache }
	if pc.scene != voidptr(sc) || pc.frame != sc.frame {
		pc.scene = voidptr(sc)
		pc.frame = sc.frame
		pc.targets = draw_order(sc.root).filter(is_pointer_target(it))
	}
	return pc.targets
}

// pointer_target: the topmost UI element under the screen point `p` (none = the pointer is over the game).
pub fn pointer_target(sc &core.Scene, p core.Vec2) ?&core.Node {
	targets := pointer_targets(sc)
	for i := targets.len - 1; i >= 0; i-- {
		n := targets[i]
		if !n.destroyed && hit_test(n, p) {
			return n
		}
	}
	return none
}

// pointer_over_ui: some UI element is under `p`; gameplay that reacts to clicks (tap to move, shoot)
// should ignore those.
pub fn pointer_over_ui(sc &core.Scene, p core.Vec2) bool {
	pointer_target(sc, p) or { return false }
	return true
}

// ui_hit: `n` is under the screen point `p` and no other UI drawn over it takes the pointer there.
pub fn ui_hit(n &core.Node, p core.Vec2) bool {
	if !hit_test(n, p) {
		return false
	}
	if n.scene == unsafe { nil } {
		return true
	}
	t := pointer_target(n.scene, p) or { return true }
	return voidptr(t) == voidptr(n) || n.is_ancestor_of(t)
}

// in_dragged_scroll_view: true while a ScrollView above `n` is being dragged (buttons inside it cancel their press).
fn in_dragged_scroll_view(n &core.Node) bool {
	mut cur := n.parent
	for cur != unsafe { nil } {
		if sv := cur.get_component[ScrollView]() {
			if sv.dragging {
				return true
			}
		}
		cur = cur.parent
	}
	return false
}

fn mul_color(a core.Color, b core.Color) core.Color {
	return core.Color{u8(u32(a.r) * b.r / 255), u8(u32(a.g) * b.g / 255), u8(u32(a.b) * b.b / 255), u8(u32(a.a) * b.a / 255)}
}

// Panel — fills the node's UITransform rectangle with a color, with optional rounded corners and border.
pub struct Panel {
	core.Component
pub mut:
	color        core.Color = core.rgba(60, 60, 72, 255)
	radius       f32 // rounded corners (only when the node is not rotated)
	border_color core.Color = core.rgba(255, 255, 255, 80)
	border_width int
	// Stops clicks and touches from reaching UI drawn under it (a dialog over buttons).
	block_input bool = true
}

// ---------- Button ----------

pub type ClickHandler = fn (mut b Button)

// Button — clickable (or tappable, with any finger) rectangle (the node's UITransform or Sprite). Tints the Panel/Sprite of `target`
// by state: the colors multiply the target's own color, so white = unchanged.
//
//   if mut btn := node.get_component[render.Button]() {
//       btn.on_click(fn (mut b render.Button) { println('clicked ${b.node.name}') })
//   }
// Or poll `btn.clicked`, true for the one frame the click happened.
//
// States can also swap the target Sprite's image (`hover_sprite` ...: unset = the normal image), add an
// additive highlight (`hover_glow` / `pressed_glow`, alpha = strength) and scale the whole button with its
// text and icons (`hover_scale` / `pressed_scale`, eased at `scale_speed`):
//
//   Button { hover_sprite = @asset("ui/btn_hover.png")  pressed_sprite = @asset("ui/btn_pressed.png")
//            hover_scale = 1.04  pressed_scale = 0.95  hover_glow = [255, 220, 150, 60] }
pub struct Button {
	core.Component
pub mut:
	interactable    bool = true
	target          string // path of the node to tint, relative to this node ('' = this node)
	normal_color    core.Color = core.white
	hover_color     core.Color = core.rgba(225, 225, 225, 255)
	pressed_color   core.Color = core.rgba(170, 170, 170, 255)
	disabled_color  core.Color = core.rgba(140, 140, 140, 180)
	hover_sprite    assets.AssetRef[assets.Texture]
	pressed_sprite  assets.AssetRef[assets.Texture]
	disabled_sprite assets.AssetRef[assets.Texture]
	hover_glow      core.Color = core.Color{255, 255, 255, 0}
	pressed_glow    core.Color = core.Color{255, 255, 255, 0}
	hover_scale     f32        = 1
	pressed_scale   f32        = 1
	scale_speed     f32        = 18 // 1/s; 0 = jump
	state           string @[hide] // normal / hover / pressed / disabled
	normal_tex      assets.AssetRef[assets.Texture] @[hide] // the target's own image
	has_normal_tex  bool           @[hide]
	base_scale      core.Vec2      @[hide]
	has_base_scale  bool           @[hide]
	cur_scale       f32 = 1            @[hide]
	hovered         bool           @[hide]
	pressed         bool           @[hide]
	pointer         u64            @[hide] // the pointer (Input.pointers) holding the button down
	clicked         bool           @[hide]
	handlers        []ClickHandler @[hide]
	base_color      core.Color     @[hide] // the target's color before tinting
	has_base        bool           @[hide]
}

pub fn (mut b Button) on_click(f ClickHandler) {
	b.handlers << f
}

pub fn (mut b Button) on_destroy() {
	b.set_tint(core.white) // leave the target as it was (matters when the node is reused, e.g. in the editor)
	b.has_base = false
	if b.state != '' && b.state != 'normal' {
		b.show_state('normal')
	}
	if b.has_base_scale && b.node != unsafe { nil } {
		b.node.scale = b.base_scale
	}
}

pub fn (mut b Button) update(dt f32) {
	b.clicked = false
	if !b.interactable {
		b.hovered = false
		b.pressed = false
		b.set_tint(b.disabled_color)
		b.show_state('disabled')
		b.ease_scale(1, dt)
		return
	}
	input := b.input()
	b.hovered = ui_hit(b.node, input.mouse)
	// Any pointer (the mouse or any finger) can press the button; the one that pressed it must also release it.
	if !b.pressed {
		for p in input.pointers() {
			if p.phase == .began && ui_hit(b.node, p.pos) {
				b.pressed = true
				b.pointer = p.id
				break
			}
		}
	}
	if b.pressed && in_dragged_scroll_view(b.node) {
		b.pressed = false
	}
	mut inside := false
	if b.pressed {
		if p := input.pointer(b.pointer) {
			inside = ui_hit(b.node, p.pos)
			if p.is_up() {
				b.pressed = false
				if inside && p.phase == .ended {
					b.clicked = true
					for h in b.handlers {
						h(mut b)
					}
				}
			}
		} else {
			b.pressed = false
		}
	}
	state := if b.pressed && inside {
		'pressed'
	} else if b.hovered || inside {
		'hover'
	} else {
		'normal'
	}
	b.set_tint(match state {
		'pressed' { b.pressed_color }
		'hover' { b.hover_color }
		else { b.normal_color }
	})
	b.show_state(state)
	b.ease_scale(match state {
		'pressed' { b.pressed_scale }
		'hover' { b.hover_scale }
		else { f32(1) }
	}, dt)
}

// target_node: the node whose Panel / Sprite shows the states.
fn (b &Button) target_node() ?&core.Node {
	if b.node == unsafe { nil } {
		return none
	}
	if b.target == '' {
		return b.node
	}
	return b.node.find(b.target)
}

// show_state swaps the target Sprite's image and glow for `state` (only when it changes).
fn (mut b Button) show_state(state string) {
	if state == b.state {
		return
	}
	b.state = state
	target := b.target_node() or { return }
	mut s := target.get_component[Sprite]() or { return }
	if !b.has_normal_tex {
		b.normal_tex = s.texture
		b.has_normal_tex = true
	}
	want := match state {
		'hover' {
			b.hover_sprite
		}
		'pressed' {
			if b.pressed_sprite.is_set() { b.pressed_sprite } else { b.hover_sprite }
		}
		'disabled' {
			b.disabled_sprite
		}
		else {
			b.normal_tex
		}
	}

	img := if want.is_set() { want } else { b.normal_tex }
	if img.id != s.texture.id && img.is_set() {
		s.set_texture(img)
	}
	s.glow = match state {
		'hover' {
			b.hover_glow
		}
		'pressed' {
			if b.pressed_glow.a > 0 { b.pressed_glow } else { b.hover_glow }
		}
		else {
			core.Color{255, 255, 255, 0}
		}
	}
}

// ease_scale moves the button's scale toward `k` times its own scale.
fn (mut b Button) ease_scale(k f32, dt f32) {
	if b.node == unsafe { nil } || (b.hover_scale == 1 && b.pressed_scale == 1 && b.cur_scale == 1) {
		return
	}
	if !b.has_base_scale {
		b.base_scale = b.node.scale
		b.has_base_scale = true
	}
	if b.scale_speed <= 0 || dt <= 0 {
		b.cur_scale = k
	} else {
		t := f32(1) - f32(math.exp(-b.scale_speed * dt))
		b.cur_scale += (k - b.cur_scale) * t
		if math.abs(b.cur_scale - k) < 0.0005 {
			b.cur_scale = k
		}
	}
	mut n := b.node
	n.scale = b.base_scale.mul(b.cur_scale)
}

fn (mut b Button) set_tint(c core.Color) {
	if b.node == unsafe { nil } {
		return
	}
	target := if b.target == '' { b.node } else { b.node.find(b.target) or { return } }
	if mut p := target.get_component[Panel]() {
		if !b.has_base {
			b.base_color = p.color
			b.has_base = true
		}
		p.color = mul_color(b.base_color, c)
	} else if mut s := target.get_component[Sprite]() {
		if !b.has_base {
			b.base_color = s.color
			b.has_base = true
		}
		s.color = mul_color(b.base_color, c)
	}
}

// Toggle — on/off switch driven by the Button on the same node: each click flips `is_on`, and the
// `checkmark` child node is shown only while on.
pub struct Toggle {
	core.Component
pub mut:
	is_on     bool
	checkmark string = 'Checkmark'
	// optional images for the node's Sprite (a switch, a lit / unlit rune); unset = keep the Sprite's own
	on_sprite  assets.AssetRef[assets.Texture]
	off_sprite assets.AssetRef[assets.Texture]
	changed    bool @[hide] // true for the frame `is_on` changed through a click
}

pub fn (mut t Toggle) on_load() {
	t.sync()
}

pub fn (mut t Toggle) update(dt f32) {
	t.changed = false
	if btn := t.node.get_component[Button]() {
		if btn.clicked {
			// in a ToggleGroup (radio buttons) the group decides
			if t.node.parent != unsafe { nil } {
				if mut g := t.node.parent.get_component[ToggleGroup]() {
					if g.enabled {
						was := t.is_on
						t.is_on = g.toggle_clicked(t.node.name, was)
						t.changed = t.is_on != was
						t.sync()
						return
					}
				}
			}
			t.is_on = !t.is_on
			t.changed = true
		}
	}
	t.sync()
}

fn (mut t Toggle) sync() {
	if t.node == unsafe { nil } {
		return
	}
	if mut c := t.node.find(t.checkmark) {
		c.active = t.is_on
	}
	want := if t.is_on { t.on_sprite } else { t.off_sprite }
	if want.is_set() {
		if mut s := t.node.get_component[Sprite]() {
			if s.texture.id != want.id {
				s.set_texture(want)
			}
		}
	}
}

// ProgressBar — draws a background and a fill covering `progress` (0..1) of the node's UITransform rectangle.
pub struct ProgressBar {
	core.Component
pub mut:
	progress f32 = 0.5
	// 'vertical' fills bottom to top
	direction  string = 'horizontal' @[choices: 'horizontal|vertical']
	reverse    bool // fill right to left / top to bottom
	fill_color core.Color = core.rgba(90, 200, 120, 255)
	back_color core.Color = core.rgba(0, 0, 0, 120)
	radius     f32
	// `smooth` (1/s, 0 = instant) eases the shown fill toward `progress`; with `trail_color` set, a drop
	// leaves a trail of the old value that catches up after `trail_delay` seconds (health bars)
	smooth      f32
	trail_color core.Color = core.Color{255, 255, 255, 0}
	trail_delay f32        = 0.4
	// a child node of this name (any Sprite art) is sized to the fill instead of drawing fill_color
	fill_node string = 'Fill'
	shown     f32 = -1 @[hide] // the displayed progress
	trail     f32 = -1 @[hide]
	trail_wait f32 @[hide]
}

pub fn (mut p ProgressBar) update(dt f32) {
	target := clamp01(p.progress)
	if p.shown < 0 || p.smooth <= 0 {
		p.shown = target
	} else {
		p.shown += (target - p.shown) * (1 - f32(math.exp(-p.smooth * dt)))
	}
	if p.trail < 0 || p.trail < p.shown {
		p.trail = p.shown
		p.trail_wait = p.trail_delay
	} else if p.trail > p.shown {
		p.trail_wait -= dt
		if p.trail_wait <= 0 {
			p.trail += (p.shown - p.trail) * (1 - f32(math.exp(-6 * dt)))
			if p.trail - p.shown < 0.001 {
				p.trail = p.shown
			}
		}
	}
	if p.node == unsafe { nil } {
		return
	}
	if mut f := p.node.find(p.fill_node) {
		r := node_rect(p.node) or { return }
		fr := p.part(r, p.shown)
		f.position = core.vec2(fr.x + fr.w / 2, fr.y + fr.h / 2)
		if mut t := f.get_component[UITransform]() {
			t.anchor = core.vec2(0.5, 0.5)
			t.size = core.vec2(fr.w, fr.h)
		}
		if mut sp := f.get_component[Sprite]() {
			sp.size = core.vec2(fr.w, fr.h)
		}
	}
}

// shown_progress: what the bar shows now (eased toward progress when smooth > 0).
pub fn (p &ProgressBar) shown_progress() f32 {
	return if p.shown < 0 { clamp01(p.progress) } else { p.shown }
}

// skinned: the fill is a child node with art.
pub fn (p &ProgressBar) skinned() bool {
	if p.fill_node == '' || p.node == unsafe { nil } {
		return false
	}
	if _ := p.node.find(p.fill_node) {
		return true
	}
	return false
}

// fill_rect: the filled part, in node space.
pub fn (p &ProgressBar) fill_rect(r Rect) Rect {
	return p.part(r, clamp01(p.progress))
}

// part: the part of `r` covering `k` (0..1) of it, in the bar's direction.
pub fn (p &ProgressBar) part(r Rect, k0 f32) Rect {
	k := clamp01(k0)
	if p.direction == 'vertical' {
		h := r.h * k
		return if p.reverse { Rect{r.x, r.y, r.w, h} } else { Rect{r.x, r.y + r.h - h, r.w, h} }
	}
	w := r.w * k
	return if p.reverse { Rect{r.x + r.w - w, r.y, w, r.h} } else { Rect{r.x, r.y, w, r.h} }
}

// ---------- ScrollView ----------

// ScrollView — shows the `content` child node through the node's UITransform rectangle (the viewport).
// Drag inside the viewport or use the mouse wheel to scroll; the content needs a UITransform (a Layout
// with resize = true keeps its size in sync with its children).
pub struct ScrollView {
	core.Component
pub mut:
	content      string = 'Content'
	horizontal   bool
	vertical     bool = true
	clip         bool = true // hide the content outside the viewport
	inertia      bool = true
	deceleration f32  = 4    // how fast the inertia slows down
	elastic      bool = true // allow dragging past the edges, then spring back
	wheel_speed  f32  = 40   // pixels per wheel step
	// Scroll bars along the right / bottom edge, shown only when the content is larger than the view;
	// auto_hide fades them out a second after scrolling stops.
	scrollbar       bool       = true
	scrollbar_width f32        = 6
	scrollbar_color core.Color = core.rgba(255, 255, 255, 150)
	scrollbar_track core.Color = core.rgba(0, 0, 0, 50)
	auto_hide       bool       = true
	idle            f32       @[hide] // seconds since the content last moved
	last_content    core.Vec2 @[hide]
	dragging        bool      @[hide]
	velocity        core.Vec2 @[hide]
	tracking        bool      @[hide] // mouse went down inside the viewport, not yet a drag
	press_pos       core.Vec2 @[hide] // viewport space
	last_pos        core.Vec2 @[hide]
}

pub fn (mut s ScrollView) content_node() ?&core.Node {
	return s.node.find(s.content)
}

pub fn (mut s ScrollView) update(dt f32) {
	mut content := s.content_node() or { return }
	view := node_rect(s.node) or { return }
	if content.position != s.last_content || s.dragging {
		s.idle = 0
		s.last_content = content.position
	} else {
		s.idle += dt
	}
	input := s.input()
	local := s.node.screen_matrix().inverse().apply(input.mouse)
	inside := ui_hit(s.node, input.mouse)

	if input.mouse_pressed && inside {
		s.tracking = true
		s.press_pos = local
		s.last_pos = local
		s.velocity = core.Vec2{}
	}
	if s.tracking && input.mouse_down {
		if !s.dragging && local.distance(s.press_pos) > 6 {
			s.dragging = true // from here on the content follows the mouse, including the first 6px
		}
		if s.dragging {
			d := s.mask(local - s.last_pos)
			s.last_pos = local
			s.move_content(mut content, view, d)
			if dt > 0 {
				s.velocity = s.velocity.lerp(d.mul(1 / dt), 0.5)
			}
		}
	} else if s.tracking {
		s.tracking = false
		s.dragging = false
		if !s.inertia {
			s.velocity = core.Vec2{}
		}
	}

	if inside && (input.scroll.x != 0 || input.scroll.y != 0) {
		mut d := core.vec2(input.scroll.x, input.scroll.y).mul(s.wheel_speed)
		if !s.vertical && d.x == 0 {
			d = core.vec2(d.y, 0) // plain wheel scrolls a horizontal-only view sideways
		}
		s.velocity = core.Vec2{}
		s.move_content(mut content, view, s.mask(d))
		s.clamp_content(mut content, view, 1)
		return
	}
	if s.dragging {
		return
	}
	if s.velocity.length() > 1 {
		s.move_content(mut content, view, s.velocity.mul(dt))
		s.velocity = s.velocity.mul(f32(math.exp(-s.deceleration * dt)))
	} else {
		s.velocity = core.Vec2{}
	}
	// out of range: spring back (elastic) or snap
	k := if s.elastic { math.min(f32(1), 12 * dt) } else { f32(1) }
	if s.clamp_content(mut content, view, k) {
		s.velocity = core.Vec2{}
	}
}

// scrollbar_rects: the track and thumb of the vertical (axis 1) or horizontal (axis 0) bar, in node space;
// none when the content fits.
pub fn (mut s ScrollView) scrollbar_rects(axis int) ?(Rect, Rect) {
	content := s.content_node() or { return none }
	view := node_rect(s.node) or { return none }
	cr := node_rect(content) or { return none }
	w := if s.scrollbar_width > 0 { s.scrollbar_width } else { f32(6) }
	if axis == 1 {
		len := cr.h * math.abs(content.scale.y)
		if !s.vertical || len <= view.h + 0.5 {
			return none
		}
		top := content.position.y + cr.y * math.abs(content.scale.y)
		thumb := math.max(view.h * view.h / len, math.min(f32(24), view.h))
		k := clamp01((view.y - top) / (len - view.h))
		track := Rect{view.x + view.w - w - 2, view.y + 2, w, view.h - 4}
		return track, Rect{track.x, track.y + k * (track.h - thumb), w, thumb}
	}
	len := cr.w * math.abs(content.scale.x)
	if !s.horizontal || len <= view.w + 0.5 {
		return none
	}
	left := content.position.x + cr.x * math.abs(content.scale.x)
	thumb := math.max(view.w * view.w / len, math.min(f32(24), view.w))
	k := clamp01((view.x - left) / (len - view.w))
	track := Rect{view.x + 2, view.y + view.h - w - 2, view.w - 4, w}
	return track, Rect{track.x + k * (track.w - thumb), track.y, thumb, w}
}

// scrollbar_alpha: 0..1 visibility of the bars (fades out after a second idle when auto_hide).
pub fn (s &ScrollView) scrollbar_alpha() f32 {
	if !s.scrollbar {
		return 0
	}
	if !s.auto_hide {
		return 1
	}
	return clamp01(1 - (s.idle - 1) / 0.4)
}

// Mask — clips the node's children to its UITransform rectangle (a ScrollView without scrolling): cards,
// portraits, bars and lists whose content must not spill out of their frame.
pub struct Mask {
	core.Component
}

fn (s &ScrollView) mask(d core.Vec2) core.Vec2 {
	return core.vec2(if s.horizontal { d.x } else { 0 }, if s.vertical { d.y } else { 0 })
}

// overflow: how far the content is past its allowed range, per axis (0 = in range).
fn (s &ScrollView) overflow(content &core.Node, view Rect) core.Vec2 {
	cr := node_rect(content) or { return core.Vec2{} }
	sx := math.abs(content.scale.x)
	sy := math.abs(content.scale.y)
	left := content.position.x + cr.x * sx
	top := content.position.y + cr.y * sy
	return core.vec2(range_overflow(left, view.x, view.w, cr.w * sx), range_overflow(top, view.y,
		view.h, cr.h * sy))
}

// range_overflow: the content edge `start` must stay between (view_start + view_len - len) and view_start;
// content smaller than the view sticks to its start.
fn range_overflow(start f32, view_start f32, view_len f32, len f32) f32 {
	hi := view_start
	lo := if len > view_len { view_start + view_len - len } else { view_start }
	if start > hi {
		return start - hi
	}
	if start < lo {
		return start - lo
	}
	return 0
}

fn (s &ScrollView) move_content(mut content core.Node, view Rect, d core.Vec2) {
	mut step := d
	if s.dragging && s.elastic {
		// resistance past the edges
		o := s.overflow(content, view)
		if o.x * d.x > 0 {
			step.x *= 0.4
		}
		if o.y * d.y > 0 {
			step.y *= 0.4
		}
	}
	content.position = content.position + step
	if !s.elastic {
		s.clamp_content(mut content, view, 1)
	}
}

// clamp_content pulls the content back into range by the fraction `k` (1 = snap). Returns true if it was out of range.
fn (s &ScrollView) clamp_content(mut content core.Node, view Rect, k f32) bool {
	o := s.overflow(content, view)
	if o.x == 0 && o.y == 0 {
		return false
	}
	mut fix := o.mul(-k)
	if math.abs(o.x) < 0.5 {
		fix.x = -o.x
	}
	if math.abs(o.y) < 0.5 {
		fix.y = -o.y
	}
	content.position = content.position + fix
	return true
}

pub fn (mut s ScrollView) scroll_to_top() {
	mut content := s.content_node() or { return }
	view := node_rect(s.node) or { return }
	cr := node_rect(content) or { return }
	content.position.y = view.y - cr.y * math.abs(content.scale.y)
	s.velocity = core.Vec2{}
}

pub fn (mut s ScrollView) scroll_to_bottom() {
	mut content := s.content_node() or { return }
	view := node_rect(s.node) or { return }
	cr := node_rect(content) or { return }
	sy := math.abs(content.scale.y)
	content.position.y = view.y + math.min(view.h - cr.h * sy, 0) - cr.y * sy
	s.velocity = core.Vec2{}
}

// ---------- Joystick ----------

// Joystick — on-screen thumb stick. A pointer (finger or mouse) going down inside the node's UITransform
// rectangle grabs it; while held, the `knob` child follows it, up to `radius` away from the `base` child.
//
//   node Stick {
//     UITransform { size = [240, 240] }       # where a thumb can grab the stick
//     Joystick { radius = 50 }
//     node Base {
//       UITransform { size = [120, 120] }  Panel { color = [255, 255, 255, 40]  radius = 60 }
//       node Knob { UITransform { size = [56, 56] }  Panel { color = [255, 255, 255, 160]  radius = 28 } }
//     }
//   }
//
// Read `value` (-1..1 per axis, y down, length <= 1) from the game's components.
pub struct Joystick {
	core.Component
pub mut:
	radius    f32    = 50   // how far the knob travels from the base's center, in node space
	dead_zone f32    = 0.1  // values shorter than this read as zero
	floating  bool   = true // the base jumps under the thumb where it lands, and goes back when released
	base      string = 'Base'
	knob      string = 'Base/Knob'
	value     core.Vec2 @[hide]
	held      bool      @[hide]
	pointer   u64       @[hide]
	rest      core.Vec2 @[hide] // the base's position when the stick is not held
	has_rest  bool      @[hide]
}

pub fn (mut j Joystick) start() {
	if base := j.node.find(j.base) {
		j.rest = base.position
		j.has_rest = true
	}
}

pub fn (mut j Joystick) on_destroy() {
	j.release() // leave the knob/base where they were authored (matters in the editor)
}

pub fn (mut j Joystick) update(dt f32) {
	input := j.input()
	if !j.held {
		for p in input.pointers() {
			if p.phase == .began && ui_hit(j.node, p.pos) {
				j.held = true
				j.pointer = p.id
				if j.floating {
					if mut base := j.node.find(j.base) {
						base.position = j.to_local(p.pos)
					}
				}
				break
			}
		}
	}
	if !j.held {
		return
	}
	p := input.pointer(j.pointer) or {
		j.release()
		return
	}
	if p.is_up() {
		j.release()
		return
	}
	center := if base := j.node.find(j.base) { base.position } else { core.Vec2{} }
	mut d := j.to_local(p.pos) - center
	if j.radius > 0 && d.length() > j.radius {
		d = d.normalized().mul(j.radius)
	}
	if mut knob := j.node.find(j.knob) {
		knob.position = d
	}
	v := if j.radius > 0 { d.mul(1 / j.radius) } else { core.Vec2{} }
	j.value = if v.length() < j.dead_zone { core.Vec2{} } else { v }
}

// release lets go of the stick: value back to zero, knob recentered, base back to its rest position.
pub fn (mut j Joystick) release() {
	j.held = false
	j.value = core.Vec2{}
	if j.node == unsafe { nil } {
		return
	}
	if mut knob := j.node.find(j.knob) {
		knob.position = core.Vec2{}
	}
	if j.floating && j.has_rest {
		if mut base := j.node.find(j.base) {
			base.position = j.rest
		}
	}
}

fn (j &Joystick) to_local(p core.Vec2) core.Vec2 {
	return j.node.screen_matrix().inverse().apply(p)
}

// ---------- Widget ----------

// Widget — keeps the node aligned to the edges/center of its parent's rectangle (the parent's UITransform,
// or the screen if the parent has none). Aligning both left and right (or top and bottom) stretches
// the node's UITransform. Distances are in the parent's space.
//
// On phones the screen's edges can be hidden by a notch, rounded corners or system bars: with `safe_area`
// (the default) a Widget aligned to the screen stays inside the safe area (Scene.safe_insets); turn it off for
// things that should reach the real edges, like a full-screen background. A Widget aligned to a parent's
// UITransform ignores `safe_area` — it follows the parent, which can itself be a safe-area Widget.
pub struct Widget {
	core.Component
pub mut:
	align_left     bool
	left           f32
	align_right    bool
	right          f32
	align_top      bool
	top            f32
	align_bottom   bool
	bottom         f32
	align_center_x bool
	center_x       f32 // offset from the parent's horizontal center
	align_center_y bool
	center_y       f32
	always         bool = true // re-align every frame (false = only once, on start)
	safe_area      bool = true // aligning to the screen: stay inside the safe area instead of the full screen
}

pub fn (mut w Widget) start() {
	w.align()
}

pub fn (mut w Widget) update(dt f32) {
	if w.always {
		w.align()
	}
}

// parent_rect: the rectangle to align to, in the parent's node space.
fn (w &Widget) parent_rect() ?Rect {
	p := w.node.parent
	if p == unsafe { nil } {
		return none
	}
	if r := node_rect(p) {
		return r
	}
	if w.node.scene == unsafe { nil } {
		return none
	}
	// the screen (or its safe area), brought into the parent's space (ignores parent rotation)
	inv := p.screen_matrix().inverse()
	sc := w.node.scene
	ins := if w.safe_area { sc.safe_insets } else { core.Insets{} }
	o := sc.view_origin
	a := inv.apply(core.vec2(o.x + ins.left, o.y + ins.top))
	b := inv.apply(core.vec2(o.x + sc.view_size.x - ins.right, o.y + sc.view_size.y - ins.bottom))
	return Rect{math.min(a.x, b.x), math.min(a.y, b.y), math.abs(b.x - a.x), math.abs(b.y - a.y)}
}

pub fn (mut w Widget) align() {
	pr := w.parent_rect() or { return }
	mut n := w.node
	mut anchor := core.Vec2{0.5, 0.5}
	mut size := core.Vec2{}
	if t := n.get_component[UITransform]() {
		anchor = t.anchor
		size = t.size
	}
	sx := math.abs(n.scale.x)
	sy := math.abs(n.scale.y)
	if w.align_left && w.align_right && sx > 0 {
		size.x = math.max((pr.w - w.left - w.right) / sx, 0)
	}
	if w.align_top && w.align_bottom && sy > 0 {
		size.y = math.max((pr.h - w.top - w.bottom) / sy, 0)
	}
	if mut t := n.get_component[UITransform]() {
		t.size = size
	}
	if w.align_left {
		n.position.x = pr.x + w.left + anchor.x * size.x * sx
	} else if w.align_right {
		n.position.x = pr.x + pr.w - w.right - (1 - anchor.x) * size.x * sx
	} else if w.align_center_x {
		n.position.x = pr.x + pr.w / 2 + w.center_x + (anchor.x - 0.5) * size.x * sx
	}
	if w.align_top {
		n.position.y = pr.y + w.top + anchor.y * size.y * sy
	} else if w.align_bottom {
		n.position.y = pr.y + pr.h - w.bottom - (1 - anchor.y) * size.y * sy
	} else if w.align_center_y {
		n.position.y = pr.y + pr.h / 2 + w.center_y + (anchor.y - 0.5) * size.y * sy
	}
}

// ---------- Layout ----------

// Layout — arranges the active children with a rectangle (UITransform or Sprite) in a row, a column or a grid,
// starting from the top-left of this node's UITransform.
pub struct Layout {
	core.Component
pub mut:
	kind    string    = 'vertical' @[choices: 'vertical|horizontal|grid']
	spacing core.Vec2 = core.Vec2{8, 8}
	padding f32
	// cross-axis alignment for rows/columns
	child_align string = 'start' @[choices: 'start|center|end']
	columns     int // grid: 0 = as many as fit the width
	resize      bool = true // grow/shrink this node's UITransform to fit the children (along the layout direction)
}

pub fn (mut l Layout) update(dt f32) {
	l.arrange()
}

struct LayoutItem {
mut:
	node &core.Node
	r    Rect // the child's rect in this node's space, relative to the child's position
}

pub fn (mut l Layout) arrange() {
	mut items := []LayoutItem{}
	for ch in l.node.children {
		if !ch.active || ch.destroyed {
			continue
		}
		r := node_rect(ch) or { continue }
		sx := math.abs(ch.scale.x)
		sy := math.abs(ch.scale.y)
		items << LayoutItem{ch, Rect{r.x * sx, r.y * sy, r.w * sx, r.h * sy}}
	}
	mut own := node_rect(l.node) or { Rect{} }
	pad := l.padding
	match l.kind {
		'horizontal' {
			mut total := pad * 2
			for i, it in items {
				total += it.r.w + if i > 0 { l.spacing.x } else { 0 }
			}
			own = l.fit(own, total, -1)
			mut x := own.x + pad
			for mut it in items {
				mut n := it.node
				n.position.x = x - it.r.x
				n.position.y = cross(l.child_align, own.y + pad, own.h - pad * 2, it.r.h) - it.r.y
				x += it.r.w + l.spacing.x
			}
		}
		'grid' {
			mut cell := core.Vec2{}
			for it in items {
				cell = core.vec2(math.max(cell.x, it.r.w), math.max(cell.y, it.r.h))
			}
			mut cols := l.columns
			if cols <= 0 {
				cols = if cell.x + l.spacing.x > 0 {
					int((own.w - pad * 2 + l.spacing.x) / (cell.x + l.spacing.x))
				} else {
					1
				}
			}
			cols = math.max(cols, 1)
			rows := (items.len + cols - 1) / cols
			own = l.fit(own, -1, pad * 2 + f32(rows) * cell.y + f32(math.max(rows -
				1, 0)) * l.spacing.y)
			for i, mut it in items {
				mut n := it.node
				cx := own.x + pad + f32(i % cols) * (cell.x + l.spacing.x)
				cy := own.y + pad + f32(i / cols) * (cell.y + l.spacing.y)
				n.position.x = cx + (cell.x - it.r.w) / 2 - it.r.x
				n.position.y = cy + (cell.y - it.r.h) / 2 - it.r.y
			}
		}
		else {
			mut total := pad * 2
			for i, it in items {
				total += it.r.h + if i > 0 { l.spacing.y } else { 0 }
			}
			own = l.fit(own, -1, total)
			mut y := own.y + pad
			for mut it in items {
				mut n := it.node
				n.position.y = y - it.r.y
				n.position.x = cross(l.child_align, own.x + pad, own.w - pad * 2, it.r.w) - it.r.x
				y += it.r.h + l.spacing.y
			}
		}
	}
}

// fit resizes this node's UITransform to width `w` / height `h` (negative = keep) when `resize` is on,
// and returns the new rect.
fn (mut l Layout) fit(own Rect, w f32, h f32) Rect {
	if !l.resize {
		return own
	}
	mut t := l.node.get_component[UITransform]() or { return own }
	if w >= 0 {
		t.size.x = w
	}
	if h >= 0 {
		t.size.y = h
	}
	return t.rect()
}

// cross: start coordinate of an item of length `len` aligned inside [start, start + avail].
fn cross(align string, start f32, avail f32, len f32) f32 {
	return match align {
		'center' { start + (avail - len) / 2 }
		'end' { start + avail - len }
		else { start }
	}
}

fn clamp01(v f32) f32 {
	return if v < 0 {
		0
	} else if v > 1 {
		1
	} else {
		v
	}
}

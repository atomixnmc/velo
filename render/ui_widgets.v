module render

import math
import velo.core

// More UI: Slider, ToggleGroup (radio buttons), Draggable + DropZone (drag and drop), UIGroup (fade /
// disable a whole subtree), Form (focus order, submit, values, validation). Springy motion: core.Spring.

// ---------- Slider ----------

// Slider — drag (or click, or arrow keys while its Form focus is on it) to pick `value` between `min` and
// `max`, snapped to `step` (0 = continuous). Draws a track, a fill and a round handle in its UITransform rect;
// with `Fill` / `Handle` child nodes (any Sprite art) it places those instead and draws nothing itself.
//
//   node Volume { UITransform { size = [240, 24] }  Slider { value = 0.8 } }
pub struct Slider {
	core.Component
pub mut:
	value        f32 = 0.5
	min          f32
	max          f32 = 1
	step         f32 // 0 = continuous; 1 = whole numbers ...
	vertical     bool
	reverse      bool // fill from the right / top
	interactable bool       = true
	track_color  core.Color = core.rgba(0, 0, 0, 120)
	fill_color   core.Color = core.rgba(220, 170, 80, 255)
	handle_color core.Color = core.rgba(255, 240, 210, 255)
	handle_size  f32        = 22       // diameter
	fill_node    string     = 'Fill'   // child sized to the filled part (anchor at the start side)
	handle_node  string     = 'Handle' // child moved to the value's position
	changed      bool @[hide] // the value changed this frame through the user
	dragging     bool @[hide]
	pointer      u64  @[hide]
	focused      bool @[hide] // set by Form
}

// fraction: the value as 0..1 between min and max.
pub fn (s &Slider) fraction() f32 {
	if s.max == s.min {
		return 0
	}
	return clamp01((s.value - s.min) / (s.max - s.min))
}

// set_value sets the value (clamped and snapped) without marking it `changed`.
pub fn (mut s Slider) set_value(v f32) {
	s.value = s.snap(v)
	s.sync()
}

fn (s &Slider) snap(v f32) f32 {
	lo, hi := math.min(s.min, s.max), math.max(s.min, s.max)
	mut x := math.max(lo, math.min(hi, v))
	if s.step > 0 {
		x = s.min + f32(math.round((x - s.min) / s.step)) * s.step
		x = math.max(lo, math.min(hi, x))
	}
	return x
}

pub fn (mut s Slider) on_load() {
	s.value = s.snap(s.value)
	s.sync()
}

pub fn (mut s Slider) update(dt f32) {
	s.changed = false
	if !s.interactable || !group_interactable(s.node) {
		s.dragging = false
		s.sync()
		return
	}
	input := s.input()
	if !s.dragging {
		for p in input.pointers() {
			if p.phase == .began && ui_hit(s.node, p.pos) {
				s.dragging = true
				s.pointer = p.id
				break
			}
		}
	}
	if s.dragging {
		if p := input.pointer(s.pointer) {
			s.set_from_point(p.pos)
			if p.is_up() {
				s.dragging = false
			}
		} else {
			s.dragging = false
		}
	}
	if s.focused {
		step := if s.step > 0 { s.step } else { (s.max - s.min) / 20 }
		mut d := f32(0)
		if input.was_typed(.right) || input.was_typed(.up) {
			d = step
		}
		if input.was_typed(.left) || input.was_typed(.down) {
			d = -step
		}
		if d != 0 {
			old := s.value
			s.value = s.snap(s.value + if s.reverse { -d } else { d })
			s.changed = s.value != old
		}
	}
	s.sync()
}

fn (mut s Slider) set_from_point(p core.Vec2) {
	r := node_rect(s.node) or { return }
	local := s.node.screen_matrix().inverse().apply(p)
	mut k := if s.vertical { 1 - (local.y - r.y) / r.h } else { (local.x - r.x) / r.w }
	if s.reverse {
		k = 1 - k
	}
	old := s.value
	s.value = s.snap(s.min + clamp01(k) * (s.max - s.min))
	if s.value != old {
		s.changed = true
	}
}

// handle_pos: the handle's centre in node space.
pub fn (s &Slider) handle_pos(r Rect) core.Vec2 {
	mut k := s.fraction()
	if s.reverse {
		k = 1 - k
	}
	if s.vertical {
		return core.vec2(r.x + r.w / 2, r.y + r.h * (1 - k))
	}
	return core.vec2(r.x + r.w * k, r.y + r.h / 2)
}

// fill_part: the filled part of the track in node space.
pub fn (s &Slider) fill_part(r Rect) Rect {
	p := ProgressBar{
		progress:  s.fraction()
		direction: if s.vertical { 'vertical' } else { 'horizontal' }
		reverse:   s.reverse
	}
	return p.fill_rect(r)
}

// sync places the Fill / Handle children (when the slider is skinned with art).
fn (mut s Slider) sync() {
	if s.node == unsafe { nil } {
		return
	}
	r := node_rect(s.node) or { return }
	if mut h := s.node.find(s.handle_node) {
		h.position = s.handle_pos(r)
	}
	if mut f := s.node.find(s.fill_node) {
		fr := s.fill_part(r)
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

// skinned: the slider has art children and draws nothing itself.
fn (s &Slider) skinned() bool {
	if _ := s.node.find(s.handle_node) {
		return true
	}
	return false
}

fn (mut r Renderer) draw_slider(s &Slider, m core.Affine2) {
	if s.skinned() {
		return
	}
	rc := node_rect(s.node) or { return }
	th := if s.vertical { rc.w } else { rc.h }
	track := if s.vertical {
		Rect{rc.x + rc.w / 2 - th / 6, rc.y, th / 3, rc.h}
	} else {
		Rect{rc.x, rc.y + rc.h / 2 - th / 6, rc.w, th / 3}
	}
	r.fill_quad(m, track, th / 6, s.track_color)
	r.fill_quad(m, s.fill_part(track), th / 6, s.fill_color)
	hp := s.handle_pos(rc)
	hs := s.handle_size / 2
	ring := if s.focused || s.dragging { s.fill_color } else { core.rgba(0, 0, 0, 90) }
	r.fill_quad(m, Rect{hp.x - hs - 2, hp.y - hs - 2, 2 * hs + 4, 2 * hs + 4}, hs + 2, ring)
	r.fill_quad(m, Rect{hp.x - hs, hp.y - hs, 2 * hs, 2 * hs}, hs, s.handle_color)
}

// ---------- ToggleGroup (radio buttons) ----------

// ToggleGroup — makes the Toggles among its node's children exclusive (radio buttons): turning one on turns
// the others off. `allow_none = false` keeps one on (a click on the selected one does nothing).
// `selected` is the name of the child that is on ('' = none); `changed` is true for that frame.
pub struct ToggleGroup {
	core.Component
pub mut:
	allow_none bool
	selected   string
	changed    bool @[hide]
}

pub fn (mut g ToggleGroup) on_load() {
	g.apply(g.selected)
}

// select turns on the child named `name` (and the others off), '' = none (when allow_none).
pub fn (mut g ToggleGroup) select(name string) {
	g.apply(name)
}

fn (mut g ToggleGroup) apply(name string) {
	if g.node == unsafe { nil } {
		return
	}
	mut first := ''
	mut found := false
	for mut ch in g.node.children {
		if mut t := ch.get_component[Toggle]() {
			if first == '' {
				first = ch.name
			}
			on := ch.name == name
			found = found || on
			t.is_on = on
			t.sync()
		}
	}
	g.selected = if found { name } else { '' }
	if !found && !g.allow_none && first != '' {
		g.apply(first)
	}
}

// toggle_clicked: called by a Toggle of the group that was clicked; returns its new state.
fn (mut g ToggleGroup) toggle_clicked(name string, was_on bool) bool {
	if was_on {
		if !g.allow_none {
			return true // the selected one stays on
		}
		g.apply('')
		g.changed = true
		return false
	}
	g.apply(name)
	g.changed = true
	return true
}

pub fn (mut g ToggleGroup) update(dt f32) {
	// `changed` lasts one frame: cleared on the frame after it was set
	if g.changed {
		g.changed = false
	}
}

// ---------- Drag and drop ----------

// Draggable — the node can be dragged with the mouse or a finger (UI under a Canvas, or world sprites with a
// UITransform). Released over a DropZone that accepts its `tag`, it is dropped there (snapped to the zone's
// centre with `snap`); anywhere else it goes back to where it started (`return_home`, springing back when the
// node has a core.Spring). While dragged it is drawn on top (`lift_z`) and slightly enlarged (`lift_scale`).
//
//   node Card { UITransform { size = [90, 120] }  Sprite { ... }  Draggable { tag = "card" }  Spring { } }
//   node Slot { UITransform { size = [100, 130] }  DropZone { accepts = "card" } }
pub struct Draggable {
	core.Component
pub mut:
	tag          string // what kind of thing it is, for DropZone.accepts
	data         string // anything the drop handler needs (an item id ...)
	threshold    f32 = 6 // pointer travel (screen units) before a press becomes a drag
	lock_x       bool
	lock_y       bool
	return_home  bool = true
	snap         bool = true
	lift_z       int  = 1000
	lift_scale   f32  = 1.06
	interactable bool = true
	dragging     bool      @[hide]
	dropped      bool      @[hide] // dropped on a zone this frame
	cancelled    bool      @[hide] // released over nothing (going home) this frame
	zone         string    @[hide] // path of the zone it was last dropped on
	home         core.Vec2 @[hide]
	pointer      u64       @[hide]
	pressing     bool      @[hide]
	press_pos    core.Vec2 @[hide]
	grab         core.Vec2 @[hide] // node position - pointer (parent space) when grabbed
	saved_z      int       @[hide]
	saved_scale  core.Vec2 @[hide]
}

pub fn (mut d Draggable) update(dt f32) {
	d.dropped = false
	d.cancelled = false
	if !d.interactable || !group_interactable(d.node) {
		return
	}
	input := d.input()
	if !d.pressing && !d.dragging {
		for p in input.pointers() {
			if p.phase == .began && ui_hit(d.node, p.pos) {
				d.pressing = true
				d.pointer = p.id
				d.press_pos = p.pos
				break
			}
		}
	}
	if !d.pressing && !d.dragging {
		return
	}
	p := input.pointer(d.pointer) or {
		d.release(core.Vec2{}, false)
		return
	}
	if d.pressing && !d.dragging && p.pos.distance(d.press_pos) >= d.threshold {
		d.begin(d.press_pos) // grab offset from where the press started, so the node does not jump
	}
	if d.dragging {
		mut n := d.node
		pp := d.parent_point(p.pos)
		mut np := pp + d.grab
		if d.lock_x {
			np.x = n.position.x
		}
		if d.lock_y {
			np.y = n.position.y
		}
		n.position = np
		if mut z := d.hover_zone(p.pos) {
			z.hovered = true
		}
	}
	if p.is_up() {
		d.release(p.pos, p.phase == .ended)
	}
}

fn (d &Draggable) parent_point(p core.Vec2) core.Vec2 {
	if d.node.parent == unsafe { nil } {
		return p
	}
	return d.node.parent.screen_matrix().inverse().apply(p)
}

fn (mut d Draggable) begin(p core.Vec2) {
	mut n := d.node
	d.dragging = true
	d.home = n.position
	d.grab = n.position - d.parent_point(p)
	d.saved_z = n.z_index
	d.saved_scale = n.scale
	n.z_index = d.saved_z + d.lift_z
	n.scale = n.scale.mul(d.lift_scale)
	if mut s := n.get_component[core.Spring]() {
		s.follow_position = false // the finger drives it now
	}
}

fn (mut d Draggable) release(p core.Vec2, ok bool) {
	was := d.dragging
	d.pressing = false
	d.dragging = false
	if !was {
		return
	}
	mut n := d.node
	n.z_index = d.saved_z
	n.scale = d.saved_scale
	if ok {
		if mut z := d.hover_zone(p) {
			d.dropped = true
			d.zone = z.node.path()
			if d.snap {
				target := d.parent_point(z.node.screen_matrix().apply(core.Vec2{}))
				d.move_to(target)
			}
			z.accept(mut d)
			return
		}
	}
	d.cancelled = true
	if d.return_home {
		d.move_to(d.home)
	}
}

fn (mut d Draggable) move_to(p core.Vec2) {
	if mut s := d.node.get_component[core.Spring]() {
		s.to_position(p)
		return
	}
	mut n := d.node
	n.position = p
}

// hover_zone: the topmost enabled DropZone under the screen point that accepts this draggable.
fn (d &Draggable) hover_zone(p core.Vec2) ?&DropZone {
	if d.node.scene == unsafe { nil } {
		return none
	}
	zones := drop_zones(d.node.scene.root)
	for i := zones.len - 1; i >= 0; i-- {
		z := zones[i]
		if z.node.is_ancestor_of(d.node) || voidptr(z.node) == voidptr(d.node) {
			continue
		}
		if hit_test(z.node, p) && z.accepts_tag(d.tag) {
			return z
		}
	}
	return none
}

fn drop_zones(root &core.Node) []&DropZone {
	mut out := []&DropZone{}
	for n in draw_order(root) {
		if z := n.get_component[DropZone]() {
			if z.enabled {
				out << z
			}
		}
	}
	return out
}

pub type DropHandler = fn (mut z DropZone, mut d Draggable)

// DropZone — where Draggables can be dropped. `accepts` lists the tags it takes (comma separated, '' = any).
// `hovered` is true while an accepted draggable is over it (tint it, show a frame); `received` holds the node
// dropped this frame. `on_drop(fn (mut z DropZone, mut d Draggable) {...})` runs on each drop;
// `reparent` moves the dropped node under the zone (inventory slots, sorted piles).
pub struct DropZone {
	core.Component
pub mut:
	accepts       string
	reparent      bool
	hover_color   core.Color = core.rgba(255, 230, 150, 255) // tint of the zone's Panel / Sprite while hovered
	hovered       bool          @[hide]
	was_hovered   bool          @[hide]
	received      &core.Node = unsafe { nil }    @[hide]
	just_received bool          @[hide]
	handlers      []DropHandler @[hide]
	base_color    core.Color    @[hide]
	has_base      bool          @[hide]
}

pub fn (mut z DropZone) on_drop(f DropHandler) {
	z.handlers << f
}

pub fn (z &DropZone) accepts_tag(tag string) bool {
	if z.accepts.trim_space() == '' {
		return true
	}
	return tag in z.accepts.split(',').map(it.trim_space())
}

fn (mut z DropZone) accept(mut d Draggable) {
	z.received = d.node
	z.just_received = true
	if z.reparent && d.node.parent != voidptr(z.node) {
		mut n := d.node
		mut zn := z.node
		world := n.world_matrix().position()
		n.remove_from_parent()
		zn.add_child(mut n)
		n.position = zn.world_matrix().inverse().apply(world)
		if d.snap {
			d.move_to(core.Vec2{})
		}
	}
	for h in z.handlers {
		h(mut z, mut d)
	}
}

pub fn (mut z DropZone) update(dt f32) {
	// `hovered` is set by draggables during their update; show it, then clear it for the next frame
	if z.hovered != z.was_hovered {
		z.tint(if z.hovered { z.hover_color } else { core.white })
		z.was_hovered = z.hovered
	}
	z.hovered = false
	if z.received != unsafe { nil } && !z.just_received {
		z.received = unsafe { nil }
	}
	z.just_received = false
}

fn (mut z DropZone) tint(c core.Color) {
	if mut p := z.node.get_component[Panel]() {
		if !z.has_base {
			z.base_color = p.color
			z.has_base = true
		}
		p.color = mul_color(z.base_color, c)
	} else if mut s := z.node.get_component[Sprite]() {
		if !z.has_base {
			z.base_color = s.color
			z.has_base = true
		}
		s.color = mul_color(z.base_color, c)
	}
}

// ---------- UIGroup ----------

// UIGroup — one switch for a whole subtree: `alpha` fades everything under the node (fade a menu in / out),
// `interactable = false` disables every button, slider, field, toggle and drag under it (a locked panel, a
// dialog while it animates). Groups nest: alphas multiply, any non-interactable ancestor wins.
pub struct UIGroup {
	core.Component
pub mut:
	alpha        f32  = 1
	interactable bool = true
}

// group_alpha: the product of the UIGroup alphas from `n` up to the root.
pub fn group_alpha(n &core.Node) f32 {
	mut a := f32(1)
	mut cur := unsafe { n }
	for cur != unsafe { nil } {
		if g := cur.get_component[UIGroup]() {
			if g.enabled {
				a *= clamp01(g.alpha)
			}
		}
		cur = cur.parent
	}
	return a
}

// group_interactable: no UIGroup from `n` up to the root disables input.
pub fn group_interactable(n &core.Node) bool {
	mut cur := unsafe { n }
	for cur != unsafe { nil } {
		if g := cur.get_component[UIGroup]() {
			if g.enabled && (!g.interactable || g.alpha <= 0) {
				return false
			}
		}
		cur = cur.parent
	}
	return true
}

// ---------- Form ----------

// Form — the fields under its node as one form: Tab / Shift+Tab move the focus through the TextInputs and
// Sliders in tree order, Enter in the last field (or a click on the `submit` button) submits. `values()` maps
// each field's node name to its value (TextInput text, Toggle "true"/"false", Slider number, ToggleGroup
// selected name); `validate()` checks the fields' rules (TextInput.required / min_length / kind) and marks
// the invalid ones; `submitted` is true for the frame a valid form was submitted, `on_submit` runs then.
pub type SubmitHandler = fn (mut f Form)

pub struct Form {
	core.Component
pub mut:
	submit        string = 'Submit' // path of the submit Button ('' = Enter only)
	focus_first   bool // focus the first field when the form starts
	invalid_color core.Color = core.rgba(230, 70, 60, 255) // border of invalid fields' Panels
	submitted     bool              @[hide]
	errors        map[string]string @[hide] // field name -> what is wrong
	handlers      []SubmitHandler   @[hide]
	focus_index   int = -1               @[hide]
}

pub fn (mut f Form) on_submit(h SubmitHandler) {
	f.handlers << h
}

pub fn (mut f Form) start() {
	if f.focus_first {
		f.focus_at(0)
	}
	// submit in the click's own frame (the form updates before its buttons, so polling would lag a frame)
	if f.submit != '' {
		if b := f.node.find(f.submit) {
			if mut btn := b.get_component[Button]() {
				fp := unsafe { &f }
				btn.on_click(fn [fp] (mut b Button) {
					mut form := unsafe { fp }
					form.submit_now()
				})
			}
		}
	}
}

// fields: the focusable fields in tree order (TextInputs and Sliders).
pub fn (f &Form) fields() []&core.Node {
	mut out := []&core.Node{}
	collect_fields(f.node, mut out)
	return out
}

fn collect_fields(n &core.Node, mut out []&core.Node) {
	for ch in n.children {
		if !ch.active {
			continue
		}
		if _ := ch.get_component[TextInput]() {
			out << ch
		} else if _ := ch.get_component[Slider]() {
			out << ch
		}
		collect_fields(ch, mut out)
	}
}

fn (mut f Form) focus_at(i int) {
	fields := f.fields()
	if fields.len == 0 {
		return
	}
	idx := ((i % fields.len) + fields.len) % fields.len
	for j, n in fields {
		if mut t := n.get_component[TextInput]() {
			if j == idx {
				t.focus()
			} else if t.focused {
				t.blur()
			}
		}
		if mut s := n.get_component[Slider]() {
			s.focused = j == idx
		}
	}
	f.focus_index = idx
}

// focused_index: the field that has the focus (-1 = none).
pub fn (f &Form) focused_index() int {
	for j, n in f.fields() {
		if t := n.get_component[TextInput]() {
			if t.focused {
				return j
			}
		}
		if s := n.get_component[Slider]() {
			if s.focused {
				return j
			}
		}
	}
	return -1
}

pub fn (mut f Form) update(dt f32) {
	f.submitted = false
	input := f.input()
	cur := f.focused_index()
	if input.was_typed(.tab) {
		back := input.is_down(.left_shift) || input.is_down(.right_shift)
		f.focus_at(if cur < 0 {
			0
		} else if back {
			cur - 1
		} else {
			cur + 1
		})
		return
	}
	mut want_submit := false
	fields := f.fields()
	if cur >= 0 && cur < fields.len {
		if t := fields[cur].get_component[TextInput]() {
			if t.submitted {
				if cur == fields.len - 1 {
					want_submit = true
				} else {
					f.focus_at(cur + 1)
				}
			}
		}
	}
	if want_submit {
		f.submit_now()
	}
}

// submit_now validates and, when valid, marks the form submitted and runs the handlers. Returns the result.
pub fn (mut f Form) submit_now() bool {
	if !f.validate() {
		return false
	}
	f.submitted = true
	for h in f.handlers {
		h(mut f)
	}
	return true
}

// values: field name -> value, for every field, toggle and toggle group under the form.
pub fn (f &Form) values() map[string]string {
	mut out := map[string]string{}
	collect_values(f.node, mut out)
	return out
}

fn collect_values(n &core.Node, mut out map[string]string) {
	for ch in n.children {
		if !ch.active {
			continue
		}
		if t := ch.get_component[TextInput]() {
			out[ch.name] = t.text
		} else if s := ch.get_component[Slider]() {
			out[ch.name] = s.value.str()
		} else if g := ch.get_component[ToggleGroup]() {
			out[ch.name] = g.selected
			continue // its toggles are the group's value
		} else if t := ch.get_component[Toggle]() {
			out[ch.name] = t.is_on.str()
		}
		collect_values(ch, mut out)
	}
}

// validate checks every TextInput's rules; invalid fields get their message in `errors` (and their Panel
// border in invalid_color). Returns true when everything is valid.
pub fn (mut f Form) validate() bool {
	f.errors = map[string]string{}
	for n in f.fields() {
		mut t := n.get_component[TextInput]() or { continue }
		msg := t.check()
		if msg != '' {
			f.errors[n.name] = msg
		}
		t.error = msg
		if mut p := n.get_component[Panel]() {
			if !t.has_base_border {
				t.base_border = p.border_color
				t.has_base_border = true
			}
			p.border_color = if msg == '' { t.base_border } else { f.invalid_color }
		}
	}
	return f.errors.len == 0
}

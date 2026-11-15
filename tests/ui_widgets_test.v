import velo.core
import velo.render

// Slider, ToggleGroup, Draggable / DropZone, core.Spring, UIGroup, Form, ProgressBar smoothing (no GPU).

fn node(name string, pos core.Vec2, size core.Vec2) &core.Node {
	mut n := core.Node.new(name).with(&render.UITransform{
		size: size
	})
	n.position = pos
	return n
}

fn step(mut s core.Scene, n int) {
	for _ in 0 .. n {
		s.update(0.016)
		s.input.end_frame()
	}
}

fn press(mut s core.Scene, p core.Vec2) {
	s.input.mouse = p
	s.input.mouse_press()
	step(mut s, 1)
}

fn move(mut s core.Scene, p core.Vec2) {
	s.input.mouse = p
	step(mut s, 1)
}

fn release(mut s core.Scene, p core.Vec2) {
	s.input.mouse = p
	s.input.mouse_release()
	step(mut s, 1)
}

fn test_slider_drag_step_and_keys() {
	mut s := core.Scene.new('T')
	mut n := node('Vol', core.vec2(100, 100), core.vec2(200, 20))
	sl := n.add_component(&render.Slider{
		value: 0.5
		min:   0
		max:   10
		step:  1
	})
	s.add(mut n)
	assert sl.value == 1 // 0.5 snapped to the step
	press(mut s, core.vec2(150, 100)) // 3/4 of the track
	assert sl.value == 8 && sl.changed && sl.dragging
	move(mut s, core.vec2(0, 100)) // past the left end: clamped
	assert sl.value == 0
	release(mut s, core.vec2(0, 100))
	assert !sl.dragging
	mut ms := n.get_component[render.Slider]() or { panic('') }
	ms.focused = true
	s.input.key_down(int(core.Key.right))
	step(mut s, 1)
	assert sl.value == 1
}

fn test_toggle_group_is_exclusive() {
	mut s := core.Scene.new('T')
	mut g := core.Node.new('Difficulty')
	grp := g.add_component(&render.ToggleGroup{
		selected: 'Normal'
	})
	for i, name in ['Easy', 'Normal', 'Hard'] {
		mut t := node(name, core.vec2(50 + f32(i) * 100, 50), core.vec2(80, 30))
		t.add_component(&render.Button{})
		t.add_component(&render.Toggle{})
		g.add_child(mut t)
	}
	s.add(mut g)
	step(mut s, 1)
	assert grp.selected == 'Normal'
	is_on := fn [g] (name string) bool {
		n := g.find(name) or { return false }
		t := n.get_component[render.Toggle]() or { return false }
		return t.is_on
	}
	assert is_on('Normal') && !is_on('Easy') && !is_on('Hard')
	press(mut s, core.vec2(250, 50))
	release(mut s, core.vec2(250, 50))
	assert grp.selected == 'Hard'
	assert is_on('Hard') && !is_on('Normal')
	// clicking the selected one keeps it on (allow_none = false)
	press(mut s, core.vec2(250, 50))
	release(mut s, core.vec2(250, 50))
	assert is_on('Hard') && grp.selected == 'Hard'
}

fn test_drag_and_drop() {
	mut s := core.Scene.new('T')
	mut zone := node('Slot', core.vec2(300, 100), core.vec2(100, 100)).with(&render.Panel{})
	z := zone.add_component(&render.DropZone{
		accepts:  'card'
		reparent: true
	})
	mut other := node('Bin', core.vec2(300, 300), core.vec2(100, 100))
	other.add_component(&render.DropZone{
		accepts: 'potion'
	})
	mut card := node('Card', core.vec2(100, 100), core.vec2(60, 80))
	d := card.add_component(&render.Draggable{
		tag: 'card'
	})
	s.add(mut zone)
	s.add(mut other)
	s.add(mut card)
	mut drops := &[]string{}
	mut zz := zone.get_component[render.DropZone]() or { panic('') }
	zz.on_drop(fn [mut drops] (mut z render.DropZone, mut d render.Draggable) {
		drops << d.node.name
	})
	// a small move is not a drag yet
	press(mut s, core.vec2(100, 100))
	move(mut s, core.vec2(103, 100))
	assert !d.dragging
	// drag onto the wrong zone: back home
	move(mut s, core.vec2(300, 300))
	assert d.dragging && card.position == core.vec2(300, 300)
	assert card.z_index >= 1000 // lifted while dragged
	release(mut s, core.vec2(300, 300))
	assert !d.dropped && card.position == core.vec2(100, 100) && card.z_index == 0
	// drag onto the slot: dropped, reparented, snapped to its centre
	press(mut s, core.vec2(100, 100))
	move(mut s, core.vec2(320, 110))
	release(mut s, core.vec2(320, 110))
	assert drops.len == 1 && (*drops)[0] == 'Card'
	assert voidptr(card.parent) == voidptr(zone)
	assert card.position == core.vec2(0, 0)
	assert voidptr(z.received) == voidptr(card)
}

fn test_spring_glides_and_settles() {
	mut s := core.Scene.new('T')
	mut n := core.Node.new('P')
	sp := n.add_component(&core.Spring{
		stiffness: 200
		damping:   28
	})
	s.add(mut n)
	mut msp := n.get_component[core.Spring]() or { panic('') }
	msp.to_position(core.vec2(100, 0))
	step(mut s, 10)
	assert n.position.x > 10 && n.position.x < 100
	step(mut s, 200)
	assert n.position.x > 99.9 && n.position.x < 100.1 && sp.settled
	msp.punch_scale(0.3)
	step(mut s, 3)
	assert n.scale.x > 1.01
	step(mut s, 300)
	assert n.scale.x > 0.999 && n.scale.x < 1.001
	x, v := core.spring_step(0, 0, 1, 100, 20, 1) // one big frame stays stable
	assert x > 0.9 && x < 1.1 && v < 1
}

fn test_ui_group_disables_and_fades() {
	mut s := core.Scene.new('T')
	mut panel := core.Node.new('Menu')
	grp := panel.add_component(&render.UIGroup{
		alpha: 0.5
	})
	mut b := node('Ok', core.vec2(50, 50), core.vec2(80, 30))
	btn := b.add_component(&render.Button{})
	panel.add_child(mut b)
	s.add(mut panel)
	assert render.group_alpha(b) == 0.5
	press(mut s, core.vec2(50, 50))
	release(mut s, core.vec2(50, 50))
	assert btn.clicked
	mut g := panel.get_component[render.UIGroup]() or { panic('') }
	g.interactable = false
	press(mut s, core.vec2(50, 50))
	release(mut s, core.vec2(50, 50))
	assert !btn.clicked
	assert !render.group_interactable(b) && grp.alpha == 0.5
}

fn test_form_focus_values_validation_submit() {
	mut s := core.Scene.new('T')
	mut f := core.Node.new('Signup')
	form := f.add_component(&render.Form{})
	mut name := node('Name', core.vec2(100, 50), core.vec2(200, 30)).with(&render.Panel{})
	name.add_component(&render.TextInput{
		required: true
	})
	mut mail := node('Email', core.vec2(100, 100), core.vec2(200, 30)).with(&render.Panel{})
	mail.add_component(&render.TextInput{
		kind: 'email'
	})
	mut age := node('Age', core.vec2(100, 150), core.vec2(200, 20))
	age.add_component(&render.Slider{
		value: 30
		max:   100
		step:  1
	})
	mut news := node('News', core.vec2(100, 200), core.vec2(30, 30))
	news.add_component(&render.Toggle{
		is_on: true
	})
	mut submit := node('Submit', core.vec2(100, 260), core.vec2(120, 40))
	submit.add_component(&render.Button{})
	f.add_child(mut name)
	f.add_child(mut mail)
	f.add_child(mut age)
	f.add_child(mut news)
	f.add_child(mut submit)
	s.add(mut f)
	step(mut s, 1)
	// Tab walks the fields in order (wrapping)
	mut frm := f.get_component[render.Form]() or { panic('') }
	assert frm.fields().len == 3
	s.input.key_down(int(core.Key.tab))
	step(mut s, 1)
	assert frm.focused_index() == 0
	s.input.key_up(int(core.Key.tab))
	s.input.key_down(int(core.Key.tab))
	step(mut s, 1)
	assert frm.focused_index() == 1
	// invalid: name required, email malformed
	mut ti := mail.get_component[render.TextInput]() or { panic('') }
	ti.text = 'not-an-email'
	press(mut s, core.vec2(100, 260))
	release(mut s, core.vec2(100, 260))
	assert !form.submitted
	assert form.errors['Name'] == 'required' && form.errors['Email'] == 'not an email address'
	pn := mail.get_component[render.Panel]() or { panic('') }
	assert pn.border_color == form.invalid_color
	// fix it and submit
	mut tn := name.get_component[render.TextInput]() or { panic('') }
	tn.text = 'Kael'
	ti.text = 'kael@emberfall.gg'
	mut got := &[]map[string]string{}
	frm.on_submit(fn [mut got] (mut f render.Form) {
		got << f.values()
	})
	press(mut s, core.vec2(100, 260))
	release(mut s, core.vec2(100, 260))
	assert form.submitted && form.errors.len == 0
	assert got.len == 1
	v := (*got)[0].clone()
	assert v['Name'] == 'Kael' && v['Email'] == 'kael@emberfall.gg' && v['Age'] == '30.0'
		&& v['News'] == 'true'
	assert pn.border_color != form.invalid_color
}

fn test_text_rules() {
	assert render.TextInput{
		text: '12.5'
		kind: 'number'
	}.check() == ''
	assert render.TextInput{
		text: '12.5'
		kind: 'integer'
	}.check() == 'not a whole number'
	assert render.TextInput{
		text:       'ab'
		min_length: 3
	}.check() == 'at least 3 characters'
	assert render.TextInput{}.check() == '' // empty and optional
}

fn test_progress_smooth_and_trail() {
	mut s := core.Scene.new('T')
	mut n := node('HP', core.vec2(0, 0), core.vec2(100, 10))
	p := n.add_component(&render.ProgressBar{
		progress:    1
		smooth:      10
		trail_color: core.rgba(255, 255, 255, 200)
		trail_delay: 0.2
	})
	s.add(mut n)
	step(mut s, 1)
	mut mp := n.get_component[render.ProgressBar]() or { panic('') }
	mp.progress = 0.4
	step(mut s, 3)
	assert p.shown_progress() < 1 && p.shown_progress() > 0.4 // easing down
	assert p.trail > p.shown_progress() // the trail waits
	step(mut s, 120)
	assert p.shown_progress() < 0.401 && p.trail < 0.41
}

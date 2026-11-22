module kine2d

import math

// Spine 4.2 physics constraints (PhysicsConstraint.update of the official runtimes): each constrained bone
// keeps spring offsets for translation, rotation (+ shearX) and scaleX that react to how the bone moved in
// the world since the last step (inertia), a spring back to the animated pose (strength), damping, mass,
// wind and gravity, stepped at the constraint's fps. The offsets are state, so they live in an SpPhysicsRun
// owned by the playing component: Kine2D.update steps it, drawing only applies the stored offsets.
// Not applied: physics constraint timelines (animated inertia / strength / wind ... and reset keys).

// SpPhysics — one physics constraint as exported (JSON defaults of the official loader).
pub struct SpPhysics {
pub mut:
	name     string
	order    int
	bone     int
	x        f32
	y        f32
	rotate   f32
	scale_x  f32
	shear_x  f32
	limit    f32 = 5000
	step     f32 = f32(1.0 / 60)
	inertia  f32 = 1
	strength f32 = 100
	damping  f32 = 1
	mass_inv f32 = 1
	wind     f32
	gravity  f32
	mix      f32 = 1
}

pub struct SpPhysicsState {
pub mut:
	fresh     bool = true
	ux        f32
	uy        f32
	cx        f32
	cy        f32
	tx        f32
	ty        f32
	x_off     f32
	x_vel     f32
	y_off     f32
	y_vel     f32
	rot_off   f32
	rot_vel   f32
	scale_off f32
	scale_vel f32
	remaining f32
}

// SpPhysicsRun — the physics state of one playing skeleton.
pub struct SpPhysicsRun {
pub mut:
	states  []SpPhysicsState
	order   []int
	time    f32 // seconds stepped
	last    f32
	ox      f32 // skeleton origin in skeleton units (y up): moving the node feeds the inertia
	oy      f32
	wind    f32 // added to every constraint's wind (a global breeze)
	gravity f32 // added to every constraint's gravity
}

pub fn (mut r SpPhysicsRun) reset() {
	r.states = []
	r.order = []
}

@[inline]
fn clampf(v f32, lo f32, hi f32) f32 {
	return if v < lo {
		lo
	} else if v > hi {
		hi
	} else {
		v
	}
}

@[inline]
fn atan2f(y f32, x f32) f32 {
	return f32(math.atan2(f64(y), f64(x)))
}

fn (d &SpineData) physics_order() []int {
	mut order := []int{len: d.physics.len, init: index}
	order.sort_with_compare(fn [d] (x &int, y &int) int {
		a, b := d.physics[*x], d.physics[*y]
		if a.order != b.order {
			return a.order - b.order
		}
		return a.bone - b.bone
	})
	return order
}

// recompute_below: world transforms of every bone under `bi`, after its world transform was changed.
fn (d &SpineData) recompute_below(bi int, locals []SpLocal, mut w []SpWorld) {
	for j in bi + 1 .. d.bones.len {
		mut p := d.bones[j].parent
		for p > bi {
			p = d.bones[p].parent
		}
		if p == bi {
			d.world_transform(j, locals[j], mut w)
		}
	}
}

fn rot_scale_apply(c SpPhysics, s SpPhysicsState, mut bw SpWorld) {
	if c.rotate > 0 || c.shear_x > 0 {
		mut o := s.rot_off * c.mix
		if c.shear_x > 0 {
			mut r := f32(0)
			if c.rotate > 0 {
				r = o * c.rotate
				sn, cs := f32(math.sin(r)), f32(math.cos(r))
				a := bw.b
				bw.b = cs * a - sn * bw.d
				bw.d = sn * a + cs * bw.d
			}
			r += o * c.shear_x
			sn, cs := f32(math.sin(r)), f32(math.cos(r))
			a := bw.a
			bw.a = cs * a - sn * bw.c
			bw.c = sn * a + cs * bw.c
		} else {
			o *= c.rotate
			sn, cs := f32(math.sin(o)), f32(math.cos(o))
			mut a := bw.a
			bw.a = cs * a - sn * bw.c
			bw.c = sn * a + cs * bw.c
			a = bw.b
			bw.b = cs * a - sn * bw.d
			bw.d = sn * a + cs * bw.d
		}
	}
	if c.scale_x > 0 {
		sc := 1 + s.scale_off * c.mix * c.scale_x
		bw.a *= sc
		bw.c *= sc
	}
}

// physics_step: Physics.update for one constraint (world `w` already holds the animated pose).
fn (d &SpineData) physics_step(c SpPhysics, mut s SpPhysicsState, mut w []SpWorld, run &SpPhysicsRun, delta f32) {
	if c.mix == 0 {
		return
	}
	bi := c.bone
	l := d.bones[bi].length
	has_x, has_y := c.x > 0, c.y > 0
	rot_or_shear := c.rotate > 0 || c.shear_x > 0
	has_scale := c.scale_x > 0
	mut bw := w[bi]
	bx, by := bw.wx + run.ox, bw.wy + run.oy
	if s.fresh {
		s.fresh = false
		s.ux = bx
		s.uy = by
		s.remaining = 0
	} else {
		s.remaining += delta
		mut a := s.remaining
		i := c.inertia
		t := c.step
		f := d.reference_scale
		mut dd := f32(-1)
		qx := c.limit * delta
		qy := qx
		if has_x || has_y {
			if has_x {
				s.x_off += clampf((s.ux - bx) * i, -qx, qx)
				s.ux = bx
			}
			if has_y {
				s.y_off += clampf((s.uy - by) * i, -qy, qy)
				s.uy = by
			}
			if a >= t {
				dd = f32(math.pow(f64(c.damping), f64(60 * t)))
				m := c.mass_inv * t
				e := c.strength
				wv := (c.wind + run.wind) * f
				g := (c.gravity + run.gravity) * f
				for a >= t {
					if has_x {
						s.x_vel += (wv - s.x_off * e) * m
						s.x_off += s.x_vel * t
						s.x_vel *= dd
					}
					if has_y {
						s.y_vel -= (g + s.y_off * e) * m
						s.y_off += s.y_vel * t
						s.y_vel *= dd
					}
					a -= t
				}
			}
			if has_x {
				bw.wx += s.x_off * c.mix * c.x
			}
			if has_y {
				bw.wy += s.y_off * c.mix * c.y
			}
		}
		if rot_or_shear || has_scale {
			ca := atan2f(bw.c, bw.a)
			mut cc, mut ss, mut mr := f32(0), f32(0), f32(0)
			dx := clampf(s.cx - (bw.wx + run.ox), -qx, qx)
			dy := clampf(s.cy - (bw.wy + run.oy), -qy, qy)
			wsx := f32(math.sqrt(f64(bw.a * bw.a + bw.c * bw.c)))
			if rot_or_shear {
				mr = (c.rotate + c.shear_x) * c.mix
				mut r := atan2f(dy + s.ty, dx + s.tx) - ca - s.rot_off * mr
				r -= f32(math.ceil(f64(r) / (2 * math.pi) - 0.5) * 2 * math.pi)
				s.rot_off += r * i
				r = s.rot_off * mr + ca
				cc, ss = f32(math.cos(r)), f32(math.sin(r))
				if has_scale && l * wsx > 0 {
					s.scale_off += (dx * cc + dy * ss) * i / (l * wsx)
				}
			} else {
				cc, ss = f32(math.cos(ca)), f32(math.sin(ca))
				if l * wsx > 0 {
					s.scale_off += (dx * cc + dy * ss) * i / (l * wsx)
				}
			}
			a = s.remaining
			if a >= t {
				if dd == -1 {
					dd = f32(math.pow(f64(c.damping), f64(60 * t)))
				}
				m := c.mass_inv * t
				e := c.strength
				wv := c.wind + run.wind
				g := c.gravity + run.gravity
				h := l / f
				for {
					a -= t
					if has_scale {
						s.scale_vel += (wv * cc - g * ss - s.scale_off * e) * m
						s.scale_off += s.scale_vel * t
						s.scale_vel *= dd
					}
					if rot_or_shear {
						s.rot_vel -= ((wv * ss + g * cc) * h + s.rot_off * e) * m
						s.rot_off += s.rot_vel * t
						s.rot_vel *= dd
						if a < t {
							break
						}
						r := s.rot_off * mr + ca
						cc, ss = f32(math.cos(r)), f32(math.sin(r))
					} else if a < t {
						break
					}
				}
			}
		}
		s.remaining = a
	}
	s.cx = bw.wx + run.ox
	s.cy = bw.wy + run.oy
	rot_scale_apply(c, s, mut bw)
	s.tx = l * bw.a
	s.ty = l * bw.c
	w[bi] = bw
}

// physics_pose: Physics.pose for one constraint (apply the stored offsets, no stepping).
fn physics_pose(c SpPhysics, s SpPhysicsState, mut w []SpWorld) {
	if c.mix == 0 || s.fresh {
		return
	}
	mut bw := w[c.bone]
	if c.x > 0 {
		bw.wx += s.x_off * c.mix * c.x
	}
	if c.y > 0 {
		bw.wy += s.y_off * c.mix * c.y
	}
	rot_scale_apply(c, s, mut bw)
	w[c.bone] = bw
}

// step_physics advances the physics of `run` by `dt` seconds with the skeleton posed at `anim`/`t`.
pub fn (d &SpineData) step_physics(anim ?SpAnimation, t f32, mut run SpPhysicsRun, dt f32) {
	if d.physics.len == 0 {
		return
	}
	if run.states.len != d.physics.len {
		run.states = []SpPhysicsState{len: d.physics.len}
		run.order = d.physics_order()
		run.last = run.time
	}
	run.time += dt
	// a hitch (loading, a breakpoint) must not turn into hundreds of sub-steps
	delta := clampf(run.time - run.last, 0, 0.1)
	run.last = run.time
	mut p, locals := d.pose_locals(anim, t)
	for i in run.order {
		d.physics_step(d.physics[i], mut run.states[i], mut p.world, run, delta)
		d.recompute_below(d.physics[i].bone, locals, mut p.world)
	}
}

// pose_physics: the pose of `anim` at `t` with the stored physics offsets of `run` applied.
pub fn (d &SpineData) pose_physics(anim ?SpAnimation, t f32, run &SpPhysicsRun) SpinePose {
	mut p, locals := d.pose_locals(anim, t)
	if run.states.len != d.physics.len {
		return p
	}
	for i in run.order {
		physics_pose(d.physics[i], run.states[i], mut p.world)
		d.recompute_below(d.physics[i].bone, locals, mut p.world)
	}
	return p
}

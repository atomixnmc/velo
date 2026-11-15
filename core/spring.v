module core

import math

// spring_step advances a damped spring by `dt`: `x` moves toward `target` with velocity `v`.
// `stiffness` (1/s², higher = snappier) and `damping` (1/s; 2 * sqrt(stiffness) = no overshoot, lower =
// bouncier). Stable for any frame time (sub-steps of at most 1/120 s).
pub fn spring_step(x f32, v f32, target f32, stiffness f32, damping f32, dt f32) (f32, f32) {
	mut px, mut pv := x, v
	steps := int(math.ceil(dt * 120))
	h := if steps > 0 { dt / f32(steps) } else { f32(0) }
	for _ in 0 .. steps {
		a := stiffness * (target - px) - damping * pv
		pv += a * h
		px += pv * h
	}
	return px, pv
}

// Spring — moves its node's position / scale / rotation toward targets with a damped spring: UI that
// follows a finger, cards snapping back, a button that wobbles when hit, a panel that slides in and overshoots.
//
//   Spring { stiffness = 300  damping = 18 }            # bouncy
//   spring.to_position(core.vec2(400, 300))              # glide there
//   spring.punch_scale(0.3)                              # a squash-and-stretch kick, settles back to 1
//
// Each property only moves once it has a target (to_position / to_scale / to_rotation, or the
// `target_*` fields with `follow_*` on), so a Spring does nothing until told to.
pub struct Spring {
	Component
pub mut:
	stiffness f32 = 220
	damping   f32 = 22 // 2 * sqrt(stiffness) ~ 30 settles without overshoot; less = bouncier
	// targets in the parent's space; `follow_*` = move toward them
	target_position Vec2
	target_scale    Vec2 = Vec2{1, 1}
	target_rotation f32
	follow_position bool
	follow_scale    bool
	follow_rotation bool
	unscaled        bool // run on real time (keeps animating while the game is paused)
	vel_position    Vec2 @[hide]
	vel_scale       Vec2 @[hide]
	vel_rotation    f32  @[hide]
	settled         bool = true @[hide]  // nothing moving
}

pub fn (mut s Spring) update(dt f32) {
	d := if s.unscaled && s.node.scene != unsafe { nil } { s.node.scene.unscaled_dt } else { dt }
	if d <= 0 {
		return
	}
	mut n := s.node
	mut moving := false
	if s.follow_position {
		n.position.x, s.vel_position.x = spring_step(n.position.x, s.vel_position.x,
			s.target_position.x, s.stiffness, s.damping, d)
		n.position.y, s.vel_position.y = spring_step(n.position.y, s.vel_position.y,
			s.target_position.y, s.stiffness, s.damping, d)
		moving = moving || near(n.position, s.target_position, s.vel_position, 0.05)
	}
	if s.follow_scale {
		n.scale.x, s.vel_scale.x = spring_step(n.scale.x, s.vel_scale.x, s.target_scale.x,
			s.stiffness, s.damping, d)
		n.scale.y, s.vel_scale.y = spring_step(n.scale.y, s.vel_scale.y, s.target_scale.y,
			s.stiffness, s.damping, d)
		moving = moving || near(n.scale, s.target_scale, s.vel_scale, 0.0005)
	}
	if s.follow_rotation {
		n.rotation, s.vel_rotation = spring_step(n.rotation, s.vel_rotation, s.target_rotation,
			s.stiffness, s.damping, d)
		moving = moving || math.abs(n.rotation - s.target_rotation) > 0.01
			|| math.abs(s.vel_rotation) > 0.01
	}
	s.settled = !moving
}

// near: false while the value is still away from the target or moving (true = settled).
fn near(x Vec2, target Vec2, v Vec2, eps f32) bool {
	return math.abs(x.x - target.x) > eps || math.abs(x.y - target.y) > eps
		|| math.abs(v.x) > eps * 10 || math.abs(v.y) > eps * 10
}

// to_position glides the node to `p` (parent space).
pub fn (mut s Spring) to_position(p Vec2) {
	s.target_position = p
	s.follow_position = true
	s.settled = false
}

// to_scale springs the node's scale to `k`.
pub fn (mut s Spring) to_scale(k Vec2) {
	s.target_scale = k
	s.follow_scale = true
	s.settled = false
}

// to_rotation springs the rotation to `deg`.
pub fn (mut s Spring) to_rotation(deg f32) {
	s.target_rotation = deg
	s.follow_rotation = true
	s.settled = false
}

// punch_scale kicks the scale by `amount` (0.2 = 20% bigger at once) and lets it wobble back to its target.
pub fn (mut s Spring) punch_scale(amount f32) {
	if !s.follow_scale {
		s.target_scale = s.node.scale
		s.follow_scale = true
	}
	s.vel_scale = s.vel_scale + Vec2{amount, amount}.mul(s.stiffness * 0.08)
	s.settled = false
}

// punch_position kicks the node by velocity `v` (units / s) around its position target (a shake / nudge).
pub fn (mut s Spring) punch_position(v Vec2) {
	if !s.follow_position {
		s.target_position = s.node.position
		s.follow_position = true
	}
	s.vel_position = s.vel_position + v
	s.settled = false
}

// snap ends the motion at the targets.
pub fn (mut s Spring) snap() {
	mut n := s.node
	if s.follow_position {
		n.position = s.target_position
	}
	if s.follow_scale {
		n.scale = s.target_scale
	}
	if s.follow_rotation {
		n.rotation = s.target_rotation
	}
	s.vel_position = Vec2{}
	s.vel_scale = Vec2{}
	s.vel_rotation = 0
	s.settled = true
}

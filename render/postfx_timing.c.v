module render

import time

// Post-processing GPU timing, for profiling only (VELO_PROFILE set and VELO_POSTFX_TIMING=1): glFinish() before
// and after the effect passes, so the measured time is what the GPU spent on them. It stalls the pipeline, so it
// is never on otherwise. Windows desktop GL only; elsewhere the number is the CPU submit time.

type GlFinishFn = fn ()

fn C.GetModuleHandleA(name &char) voidptr
fn C.GetProcAddress(h voidptr, name &char) voidptr

const postfx_timing = os_env_on('VELO_POSTFX_TIMING') && os_env_set('VELO_PROFILE')

struct PostTiming {
mut:
	finish voidptr
	looked bool
	sum    i64
	frames int
	since  i64
}

fn (mut t PostTiming) gpu_finish() {
	$if windows {
		if !t.looked {
			t.looked = true
			h := C.GetModuleHandleA(c'opengl32.dll')
			if h != unsafe { nil } {
				t.finish = C.GetProcAddress(h, c'glFinish')
			}
		}
		if t.finish != unsafe { nil } && gfx_is_gl() {
			f := unsafe { GlFinishFn(t.finish) }
			f()
		}
	}
}

fn (mut t PostTiming) add(ns i64, w int, h int) {
	t.sum += ns
	t.frames++
	now := time.sys_mono_now()
	if t.since == 0 {
		t.since = now
	}
	if now - t.since >= 2_000_000_000 {
		profile_log('[velo] POSTFX ${w}x${h} passes_ms=${f64(t.sum) / f64(t.frames) / 1_000_000.0:.3f} (gpu, glFinish-timed)')
		t.sum = 0
		t.frames = 0
		t.since = now
	}
}

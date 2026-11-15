module app

import os
import stbi
import time
import velo.render
import sokol.sapp

// Silent frame capture for tests and screenshots, without a visible window:
//   VELO_CAPTURE=<file.png>      save one frame as PNG (folders are created)
//   VELO_CAPTURE_AFTER=<seconds>  wait this long after the first frame (default 3)
//   VELO_CAPTURE_EXIT=0           keep running after the capture (default: quit)
// A capture is always muted (no audio device is opened); VELO_MUTE=1 mutes any other run.
// The window is created at the design size (cfg.width x cfg.height) and hidden at once, so nothing appears on
// the desktop and the capture is full resolution whatever the screen. The frame is read back from the GL back
// buffer after it is drawn and before it is presented (sokol GL core backend; Windows default).
const capture_path = os.getenv('VELO_CAPTURE')
const capture_after_s = if os.getenv('VELO_CAPTURE_AFTER') != '' {
	os.getenv('VELO_CAPTURE_AFTER').f64()
} else {
	3.0
}
const capture_exit = os.getenv('VELO_CAPTURE_EXIT') != '0'

struct FrameCapture {
mut:
	start i64
	done  bool
}

fn capture_on() bool {
	return capture_path != ''
}

// hide_window_for_capture hides the game window as soon as it exists (Windows); rendering continues.
fn hide_window_for_capture() {
	$if windows {
		C.ShowWindow(sapp.win32_get_hwnd(), 0) // SW_HIDE
	}
}

fn C.ShowWindow(hwnd voidptr, cmd int) bool
fn C.glReadPixels(x int, y int, w int, h int, format u32, typ u32, data voidptr)
fn C.glReadBuffer(mode u32)

// capture_frame: call right after the frame is drawn (after ctx.end), before the swap.
fn (mut c FrameCapture) capture_frame() {
	if c.done || !capture_on() {
		return
	}
	now := time.sys_mono_now()
	if c.start == 0 {
		c.start = now
		return
	}
	if f64(now - c.start) / 1_000_000_000.0 < capture_after_s {
		return
	}
	c.done = true
	w := sapp.width()
	h := sapp.height()
	mut px := []u8{len: w * h * 4}
	$if !emscripten ? {
		C.glReadBuffer(0x0405) // GL_BACK
		C.glReadPixels(0, 0, w, h, 0x1908, 0x1401, px.data) // GL_RGBA, GL_UNSIGNED_BYTE
	}
	// GL rows run bottom-up: flip, and make the image opaque
	mut out := []u8{len: px.len}
	row := w * 4
	for y in 0 .. h {
		src := (h - 1 - y) * row
		for i in 0 .. row {
			out[y * row + i] = if i % 4 == 3 { u8(255) } else { px[src + i] }
		}
	}
	os.mkdir_all(os.dir(capture_path)) or {}
	stbi.stbi_write_png(capture_path, w, h, 4, out.data, row) or {
		eprintln('[velo] capture failed: ${err}')
	}
	render.profile_log('[velo] CAPTURE ${w}x${h} -> ${capture_path}')
	if capture_exit {
		sapp.request_quit()
	}
}

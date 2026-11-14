module app

// gg paces frames with time.sleep on top of vsync; Windows' default 15.6 ms sleep granularity then
// overshoots the frame budget and every frame waits for a second vblank (a hard ~30 FPS ceiling).
// Asking for 1 ms timer resolution while the game runs keeps the sleep inside the budget.
#flag windows -lwinmm
#include <windows.h>
#include <timeapi.h>

fn C.timeBeginPeriod(u32) u32

fn C.timeEndPeriod(u32) u32

fn precise_timers(on bool) {
	if on {
		C.timeBeginPeriod(1)
	} else {
		C.timeEndPeriod(1)
	}
}

#ifndef NOTPROTON_FULLSCREEN_CAPTURE_H
#define NOTPROTON_FULLSCREEN_CAPTURE_H

#include <limits.h>
#include <stdatomic.h>
#include <string.h>

/*
 * Display-capture opt-out helper for Wine fullscreen.
 * This controls only Wine's display-wide CGCaptureAllDisplays pair. It does
 * not request AppKit native fullscreen or change WineWindow geometry/state.
 */
struct np_fullscreen_capture {
	int disabled;
	atomic_uint suppressed_captures;
};

static inline int np_fullscreen_capture_opt_out_from_env(const char *value)
{
	return value != NULL && strcmp(value, "1") == 0;
}

static inline void np_fullscreen_capture_init(struct np_fullscreen_capture *state,
						      const char *value)
{
	state->disabled = np_fullscreen_capture_opt_out_from_env(value);
	atomic_init(&state->suppressed_captures, 0);
}

static inline int np_fullscreen_capture_begin(struct np_fullscreen_capture *state,
						      int (*capture)(void))
{
	if (state->disabled) {
		unsigned int value = atomic_load_explicit(&state->suppressed_captures,
		                                         memory_order_relaxed);
		while (value != UINT_MAX &&
		       !atomic_compare_exchange_weak_explicit(&state->suppressed_captures,
		                                             &value, value + 1,
		                                             memory_order_relaxed,
		                                             memory_order_relaxed))
			;
		return 0;
	}
	return capture();
}

static inline int np_fullscreen_capture_end(struct np_fullscreen_capture *state,
						    int fullscreen_windows_remain,
						    int (*release)(void))
{
	if (state->disabled) {
		unsigned int value = atomic_load_explicit(&state->suppressed_captures,
		                                         memory_order_relaxed);
		while (value > 0) {
			if (atomic_compare_exchange_weak_explicit(&state->suppressed_captures,
			                                          &value, value - 1,
			                                          memory_order_relaxed,
			                                          memory_order_relaxed))
				return 0;
		}
		/* Never release a display capture this opt-out did not acquire. */
		return 0;
	}
	if (fullscreen_windows_remain)
		return 0;
	return release();
}

#endif

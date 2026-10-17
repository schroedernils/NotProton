#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <stdlib.h>

#include "fullscreen_capture.h"

typedef CGError (*display_capture_fn)(void);

static struct np_fullscreen_capture capture_state;

static int original_capture(void)
{
	display_capture_fn next = (display_capture_fn)dlsym(RTLD_NEXT, "CGCaptureAllDisplays");
	return next != NULL ? next() : kCGErrorFailure;
}

static int original_release(void)
{
	display_capture_fn next = (display_capture_fn)dlsym(RTLD_NEXT, "CGReleaseAllDisplays");
	return next != NULL ? next() : kCGErrorFailure;
}

static CGError notproton_capture_all_displays(void)
{
	return (CGError)np_fullscreen_capture_begin(&capture_state, original_capture);
}

static CGError notproton_release_all_displays(void)
{
	return (CGError)np_fullscreen_capture_end(&capture_state, 0, original_release);
}

__attribute__((constructor)) static void fullscreen_capture_load(void)
{
	np_fullscreen_capture_init(&capture_state,
	                          getenv("NOTPROTON_RELEASE_DISPLAYS_FULLSCREEN"));
}

#define NP_DYLD_INTERPOSE(replacement, replacee) \
	__attribute__((used)) static struct { \
		const void *replacement; \
		const void *replacee; \
	} np_interpose_##replacee __attribute__((section("__DATA,__interpose"))) = { \
		(const void *)(unsigned long)&replacement, \
		(const void *)(unsigned long)&replacee \
	}

NP_DYLD_INTERPOSE(notproton_capture_all_displays, CGCaptureAllDisplays);
NP_DYLD_INTERPOSE(notproton_release_all_displays, CGReleaseAllDisplays);

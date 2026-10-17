#ifndef NOTPROTON_HOOKS_NATIVE_PRESENTATION_H
#define NOTPROTON_HOOKS_NATIVE_PRESENTATION_H

#ifdef __OBJC__
#import <Foundation/Foundation.h>

// Returns a copied, updated environment only for a verified Steam-installed app.
// Returns nil for unrelated targets or whenever metadata/presentation is unsafe.
NSDictionary<NSString *, NSString *> *np_native_presentation_environment(
    NSString *target, NSDictionary<NSString *, NSString *> *environment);
#endif

// C bridge used by spawn hooks. A NULL return means leave the original envp alone.
char **np_native_presentation_spawn_environment(const char *target, char *const envp[]);
void np_native_presentation_free_environment(char **environment);

#endif

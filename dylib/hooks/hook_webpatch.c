// Feeds a compat-gate-patched SteamUI chunk to the loopback reader. The bytes are
// rewritten in memory and handed back as an anonymous fd, so the on-disk file is
// not modified, to keep the Steam bootstrap happy.

#include "../feats/webpatch.h"
#include "../feats/compat.h"
#include "../feats/compatsvc.h"
#include "../feats/nativeplatform.h"
#include "../util/file.h"
#include "../util/log.h"
#include "webpatch_cache.h"

#include <stdarg.h>
#include <stdint.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <stdio.h>
#include <errno.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { \
        const void *replacement; \
        const void *replacee; \
    } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(uintptr_t)&_replacement, \
        (const void *)(uintptr_t)&_replacee \
    }


_Pragma("clang diagnostic push")
_Pragma("clang diagnostic ignored \"-Wdeprecated-declarations\"")
static int sys_open(const char *path, int oflag, mode_t mode) {
    return (int)syscall(SYS_open, path, oflag, mode);
}
static int sys_openat(int dirfd, const char *path, int oflag, mode_t mode) {
    return (int)syscall(SYS_openat, dirfd, path, oflag, mode);
}
_Pragma("clang diagnostic pop")

#define WEBPATCH_MAX_CHUNK (32 * 1024 * 1024)

static pthread_once_t transform_lock_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t transform_lock;
static int transform_lock_status;

static void init_transform_lock(void) {
    pthread_mutexattr_t attr;
    if (pthread_mutexattr_init(&attr) != 0) { transform_lock_status = -1; return; }
    if (pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE) != 0 ||
        pthread_mutex_init(&transform_lock, &attr) != 0)
        transform_lock_status = -1;
    pthread_mutexattr_destroy(&attr);
}

typedef struct {
    uint64_t generation;
    const char *fex[NP_WEBPATCH_FEX_TOOLS_MAX];
    size_t fex_count;
} transform_context;

static char *transform_for_cache(const unsigned char *raw, size_t raw_len,
                                 const char *fallback, size_t *patched_len,
                                 int *cache_negative,
                                 void *context) {
    const transform_context *input = context;
    uint64_t expected_generation = input->generation;
    if (np_nativeplatform_generation() != expected_generation) {
        *cache_negative = 0;
        return NULL;
    }
    pthread_once(&transform_lock_once, init_transform_lock);
    if (transform_lock_status || pthread_mutex_lock(&transform_lock) != 0) {
        *cache_negative = 0;
        return NULL;
    }
    np_webpatch_set_fallback_tool(fallback);
    np_webpatch_set_fex_tools(input->fex, input->fex_count);
    const char *shape = NULL;
    char *patched = np_webpatch_transform(raw, raw_len, patched_len, &shape);
    pthread_mutex_unlock(&transform_lock);
    *cache_negative = !patched && shape == NULL;
    if (np_nativeplatform_generation() != expected_generation) {
        free(patched);
        patched = NULL;
        *cache_negative = 0;
    }
    if (shape && strcmp(shape, NP_SHAPE_SELECTTOOL) == 0 &&
        np_compatsvc_routes() == NP_COMPATSVC_ABSENT)
        NP_ERR("webpatch: the compat page sources its tools from CompatManager and this "
               "client cannot answer, so the list will be empty");
    return patched;
}

static int cache_source_open(const char *path, int flags) {
    return sys_open(path, flags, 0);
}

static int open_patched(const char *path, int flags) {
    np_log_attach();
    transform_context context = { .generation = np_nativeplatform_generation() };
    context.fex_count = np_compat_fex_tools(context.fex, NP_WEBPATCH_FEX_TOOLS_MAX);
    // Tool capability changes invalidate cached UI, just like platform metadata.
    char generation_key[32 + NP_WEBPATCH_FEX_TOOLS_MAX * 130];
    size_t used = (size_t)snprintf(generation_key, sizeof(generation_key), "%llu",
                                 (unsigned long long)context.generation);
    for (size_t i = 0; i < context.fex_count; ++i) {
        int n = snprintf(generation_key + used, sizeof(generation_key) - used, "|%s", context.fex[i]);
        if (n < 0 || (size_t)n >= sizeof(generation_key) - used) return -1;
        used += (size_t)n;
    }
    int fd = np_webpatch_cache_open(path, flags, np_compat_fallback_tool_name(), generation_key,
                                    cache_source_open,
                                    transform_for_cache, &context,
                                    WEBPATCH_MAX_CHUNK);
    if (fd < 0) return -1;

    NP_LOG_FIRST("webpatch: served patched compat chunk (%s) to %s pid %d",
                 path, getprogname(), getpid());
    return fd;
}

static const int WRITE_INTENT = O_WRONLY | O_RDWR | O_CREAT | O_TRUNC | O_APPEND;

static int try_serve(const char *path, int oflag) {
    if (oflag & WRITE_INTENT)
        return -1;
    if (!np_webpatch_should_patch(path))
        return -1;
    return open_patched(path, oflag);
}

static mode_t creat_mode(int oflag, va_list ap) {
    if (oflag & O_CREAT)
        return (mode_t)va_arg(ap, int);
    return 0;
}

static int np_open(const char *path, int oflag, ...) {
    va_list ap; va_start(ap, oflag);
    mode_t mode = creat_mode(oflag, ap);
    va_end(ap);

    int served = try_serve(path, oflag);
    if (served >= 0)
        return served;
    return sys_open(path, oflag, mode);
}

static int np_openat(int dirfd, const char *path, int oflag, ...) {
    va_list ap; va_start(ap, oflag);
    mode_t mode = creat_mode(oflag, ap);
    va_end(ap);

    if (path && path[0] == '/') {
        int served = try_serve(path, oflag);
        if (served >= 0)
            return served;
    }
    return sys_openat(dirfd, path, oflag, mode);
}

static int mode_string_flags(const char *mode) {
    if (!mode || !mode[0])
        return -1;

    int oflag;
    switch (mode[0]) {
        case 'r': oflag = O_RDONLY; break;
        case 'w': oflag = O_WRONLY | O_CREAT | O_TRUNC; break;
        case 'a': oflag = O_WRONLY | O_CREAT | O_APPEND; break;
        default:  return -1;
    }
    for (const char *p = mode + 1; *p; p++) {
        switch (*p) {
            case '+': oflag = (oflag & ~(O_RDONLY | O_WRONLY)) | O_RDWR; break;
            case 'x': oflag |= O_EXCL;    break;
            case 'e': oflag |= O_CLOEXEC; break;
            default: break;
        }
    }
    return oflag;
}

static FILE *np_fopen(const char *path, const char *mode) {
    int oflag = mode_string_flags(mode);
    if (!path || oflag < 0) {
        errno = EINVAL;
        return NULL;
    }

    int served = try_serve(path, oflag);
    if (served >= 0) {
        FILE *fp = fdopen(served, mode);
        if (fp)
            return fp;
        close(served);
    }

    int fd = sys_open(path, oflag, 0666);
    if (fd < 0)
        return NULL;
    FILE *fp = fdopen(fd, mode);
    if (!fp) {
        int e = errno;
        close(fd);
        errno = e;
    }
    return fp;
}

DYLD_INTERPOSE(np_open, open);
DYLD_INTERPOSE(np_openat, openat);
DYLD_INTERPOSE(np_fopen, fopen);

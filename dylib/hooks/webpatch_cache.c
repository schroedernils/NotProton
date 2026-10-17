#define _DARWIN_C_SOURCE
#include "webpatch_cache.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define CACHE_SLOTS 8
#define CACHE_BYTE_BUDGET (32u * 1024u * 1024u)

typedef struct {
    dev_t dev; ino_t ino; off_t size;
    time_t mtime_sec, ctime_sec;
    long mtime_nsec, ctime_nsec;
} source_key;

typedef struct {
    int valid;
    source_key key;
    char fallback[128];
    char *namespace_identity;
    char *bytes;
    size_t length;
    int negative;
    uint64_t age;
} cache_entry;

static cache_entry entries[CACHE_SLOTS];
static pthread_mutex_t cache_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t cache_age;
static size_t cache_bytes;

static source_key make_key(const struct stat *st) {
#if defined(__APPLE__)
    source_key k = { st->st_dev, st->st_ino, st->st_size,
                     st->st_mtimespec.tv_sec, st->st_ctimespec.tv_sec,
                     st->st_mtimespec.tv_nsec, st->st_ctimespec.tv_nsec };
#else
    source_key k = { st->st_dev, st->st_ino, st->st_size,
                     st->st_mtim.tv_sec, st->st_ctim.tv_sec,
                     st->st_mtim.tv_nsec, st->st_ctim.tv_nsec };
#endif
    return k;
}

static int same_key(source_key a, source_key b) {
    return a.dev == b.dev && a.ino == b.ino && a.size == b.size &&
        a.mtime_sec == b.mtime_sec && a.ctime_sec == b.ctime_sec &&
        a.mtime_nsec == b.mtime_nsec && a.ctime_nsec == b.ctime_nsec;
}

static int read_source(int fd, char *buf, size_t size) {
    size_t done = 0;
    while (done < size) {
        ssize_t n = pread(fd, buf + done, size - done, (off_t)done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        done += (size_t)n;
    }
    return 0;
}

static int anonymous_fd(const char *bytes, size_t len, int flags) {
    char name[] = "/tmp/notproton-webpatch-XXXXXX";
    int fd = mkstemp(name);
    if (fd < 0) return -1;
    unlink(name);
    size_t done = 0;
    while (done < len) {
        ssize_t n = write(fd, bytes + done, len - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { int e = errno; close(fd); errno = e; return -1; }
        done += (size_t)n;
    }
    if (lseek(fd, 0, SEEK_SET) < 0 ||
        ((flags & O_CLOEXEC) && fcntl(fd, F_SETFD, FD_CLOEXEC) < 0)) {
        int e = errno; close(fd); errno = e; return -1;
    }
    return fd;
}

int np_webpatch_cache_open(const char *path, int flags, const char *fallback,
                           const char *namespace_identity,
                           np_webpatch_source_open_fn source_open,
                           np_webpatch_transform_fn transform, void *context,
                           size_t max_size) {
    int unsupported = 0;
#ifdef O_NOFOLLOW
    unsupported |= O_NOFOLLOW;
#endif
#ifdef O_DIRECTORY
    unsupported |= O_DIRECTORY;
#endif
    int supported = O_CLOEXEC;
    if (!path || !fallback || !namespace_identity || !source_open || !transform || (flags & unsupported) ||
        (flags & O_ACCMODE) != O_RDONLY || (flags & ~(supported | O_ACCMODE))) return -1;

    int source = source_open(path, O_RDONLY);
    if (source < 0) return -1;
    struct stat before, after;
    if (fstat(source, &before) || !S_ISREG(before.st_mode) || before.st_size <= 0 ||
        (uintmax_t)before.st_size > max_size || strlen(fallback) >= sizeof(entries[0].fallback)) {
        close(source); return -1;
    }
    source_key key = make_key(&before);

    pthread_mutex_lock(&cache_lock);
    for (size_t i = 0; i < CACHE_SLOTS; i++) {
        if (entries[i].valid && same_key(entries[i].key, key) &&
            strcmp(entries[i].fallback, fallback) == 0 &&
            strcmp(entries[i].namespace_identity, namespace_identity) == 0) {
            entries[i].age = ++cache_age;
            if (entries[i].negative) {
                pthread_mutex_unlock(&cache_lock);
                close(source);
                return -1;
            }
            int result = anonymous_fd(entries[i].bytes, entries[i].length, flags);
            pthread_mutex_unlock(&cache_lock);
            close(source);
            return result;
        }
    }
    pthread_mutex_unlock(&cache_lock);

    size_t raw_len = (size_t)before.st_size;
    unsigned char *raw = malloc(raw_len);
    if (!raw || read_source(source, (char *)raw, raw_len) || fstat(source, &after) ||
        !same_key(key, make_key(&after))) {
        free(raw); close(source); return -1;
    }
    close(source);
    size_t patched_len = 0;
    int cache_negative = 0;
    char *patched = transform(raw, raw_len, fallback, &patched_len,
                              &cache_negative, context);
    free(raw);
    if (patched && (!patched_len || patched_len > max_size)) { free(patched); return -1; }

    int verify = source_open(path, O_RDONLY);
    int stable = verify >= 0 && fstat(verify, &after) == 0 && same_key(key, make_key(&after));
    if (verify >= 0) close(verify);
    if (!stable) { free(patched); return -1; }

    pthread_mutex_lock(&cache_lock);
    size_t slot = 0;
    for (size_t i = 0; i < CACHE_SLOTS; i++) {
        if (entries[i].valid && same_key(entries[i].key, key) &&
            strcmp(entries[i].fallback, fallback) == 0 &&
            strcmp(entries[i].namespace_identity, namespace_identity) == 0) { slot = i; goto selected; }
        if (!entries[i].valid || entries[i].age < entries[slot].age) slot = i;
    }
selected:
    if ((patched || cache_negative) && entries[slot].valid) {
        cache_bytes -= entries[slot].length + strlen(entries[slot].namespace_identity) + 1;
        free(entries[slot].bytes);
        free(entries[slot].namespace_identity);
        memset(&entries[slot], 0, sizeof(entries[slot]));
    }
    if (patched || cache_negative) {
        size_t identity_len = strlen(namespace_identity) + 1;
        size_t cost = patched_len + identity_len;
        if (cost <= CACHE_BYTE_BUDGET) {
            while (cache_bytes + cost > CACHE_BYTE_BUDGET) {
                size_t oldest = CACHE_SLOTS;
                for (size_t i = 0; i < CACHE_SLOTS; i++)
                    if (entries[i].valid && (oldest == CACHE_SLOTS || entries[i].age < entries[oldest].age)) oldest = i;
                if (oldest == CACHE_SLOTS) break;
                cache_bytes -= entries[oldest].length + strlen(entries[oldest].namespace_identity) + 1;
                free(entries[oldest].bytes); free(entries[oldest].namespace_identity);
                memset(&entries[oldest], 0, sizeof(entries[oldest]));
            }
            if (cache_bytes + cost <= CACHE_BYTE_BUDGET) {
                entries[slot].namespace_identity = strdup(namespace_identity);
                if (entries[slot].namespace_identity) {
                    entries[slot].valid = 1; entries[slot].key = key;
                    memcpy(entries[slot].fallback, fallback, strlen(fallback) + 1);
                    entries[slot].bytes = patched; entries[slot].length = patched_len;
                    entries[slot].negative = patched == NULL;
                    entries[slot].age = ++cache_age;
                    cache_bytes += cost;
                    if (patched) patched = NULL; // Cache owns it from here.
                }
            }
        }
    }
    char *served_bytes = patched;
    if (!served_bytes) {
        for (size_t i = 0; i < CACHE_SLOTS; i++)
            if (entries[i].valid && same_key(entries[i].key, key) &&
                strcmp(entries[i].fallback, fallback) == 0 &&
                strcmp(entries[i].namespace_identity, namespace_identity) == 0) {
                if (entries[i].negative) { pthread_mutex_unlock(&cache_lock); return -1; }
                served_bytes = entries[i].bytes;
                break;
            }
    }
    if (!served_bytes) { pthread_mutex_unlock(&cache_lock); return -1; }
    int result = anonymous_fd(served_bytes, patched_len, flags);
    if (patched && result >= 0) free(patched);
    if (patched && result < 0) free(patched);
    pthread_mutex_unlock(&cache_lock);
    return result;
}

#ifndef NP_WEBPATCH_CACHE_H
#define NP_WEBPATCH_CACHE_H

#include <stddef.h>

typedef char *(*np_webpatch_transform_fn)(const unsigned char *, size_t,
                                          const char *, size_t *, int *, void *);
typedef int (*np_webpatch_source_open_fn)(const char *, int);

int np_webpatch_cache_open(const char *path, int flags, const char *fallback,
                           const char *namespace_identity,
                           np_webpatch_source_open_fn source_open,
                           np_webpatch_transform_fn transform, void *context,
                           size_t max_size);

#endif

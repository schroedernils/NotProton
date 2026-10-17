/* Exit status contract: 0 game present, 1 idle, 2 unknown. */
#include <libproc.h>
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <unistd.h>

enum session_state {
    SESSION_GAME_PRESENT = 0,
    SESSION_IDLE = 1,
    SESSION_UNKNOWN = 2
};

struct session_process {
    int pid;
    uint64_t start_sec;
    uint64_t start_usec;
    const char *name;
    const char *args;
    int query_ok;
    int socket_matches_prefix;
    int argv_complete;
};

static int pid_count_from_bytes(int got, int capacity, size_t *count_out) {
    if (got < 0 || got > capacity || got % (int)sizeof(pid_t) != 0)
        return -1;
    *count_out = (size_t)got / sizeof(pid_t);
    return 0;
}

static int list_user_pids(pid_t **pids_out, size_t *count_out) {
    int bytes = proc_listpids(PROC_UID_ONLY, getuid(), NULL, 0);
    if (bytes <= 0) return -1;
    pid_t *pids = calloc(1, (size_t)bytes);
    if (!pids) return -1;
    int got = proc_listpids(PROC_UID_ONLY, getuid(), pids, bytes);
    if (pid_count_from_bytes(got, bytes, count_out) != 0) {
        free(pids);
        errno = EIO;
        return -1;
    }
    *pids_out = pids;
    return 0;
}

static int process_identity(pid_t pid, uint64_t *sec, uint64_t *usec,
                            char *name, size_t name_size) {
    struct proc_bsdinfo info;
    int n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (n != sizeof(info)) return -1;
    *sec = info.pbi_start_tvsec;
    *usec = info.pbi_start_tvusec;
    if (!*sec && !*usec) return -1;
    int named = proc_name(pid, name, (uint32_t)name_size);
    if (named <= 0) return -1;
    name[name_size - 1] = '\0';
    return 0;
}

static int same_process_identity(pid_t pid, uint64_t sec, uint64_t usec) {
    struct proc_bsdinfo info;
    int n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    return n == sizeof(info) && info.pbi_start_tvsec == sec &&
           info.pbi_start_tvusec == usec;
}

static int read_process_argv(pid_t pid, char *out, size_t out_size) {
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size < sizeof(int))
        return -1;
    char *buf = malloc(size);
    if (!buf) return -1;
    if (sysctl(mib, 3, buf, &size, NULL, 0) != 0 || size < sizeof(int)) {
        free(buf);
        return -1;
    }
    int argc = 0;
    memcpy(&argc, buf, sizeof(argc));
    if (argc < 1 || argc > 4096) { free(buf); return -1; }
    char *p = buf + sizeof(argc), *end = buf + size;
    while (p < end && *p) p++; // executable path
    while (p < end && !*p) p++;
    size_t used = 0;
    for (int i = 0; i < argc && p < end; i++) {
        size_t len = strnlen(p, (size_t)(end - p));
        if (len == (size_t)(end - p)) { free(buf); return -1; }
        if (i && used + 1 < out_size) out[used++] = ' ';
        size_t copy = len < out_size - used - 1 ? len : out_size - used - 1;
        memcpy(out + used, p, copy);
        used += copy;
        out[used] = '\0';
        p += len + 1;
    }
    free(buf);
    return argc > 0 && used > 0 ? 0 : -1;
}

static int pid_owns_server_path(pid_t pid, const char *server_dir,
                                dev_t server_dev) {
    int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (bytes <= 0) return -1;
    struct proc_fdinfo *fds = malloc((size_t)bytes);
    if (!fds) return -1;
    int got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, bytes);
    if (got < 0) { free(fds); return -1; }
    int count = got / (int)sizeof(*fds);
    int saw_vnode = 0;
    int query_failed = 0;
    for (int i = 0; i < count; i++) {
        if (fds[i].proc_fdtype == PROX_FDTYPE_VNODE) {
            struct vnode_fdinfowithpath vi;
            int n = proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDVNODEPATHINFO,
                                   &vi, sizeof(vi));
            if (n != sizeof(vi)) { query_failed = 1; continue; }
            saw_vnode = 1;
            const char *path = vi.pvip.vip_path;
            if (vi.pvip.vip_vi.vi_stat.vst_dev == (uint32_t)server_dev &&
                strncmp(path, server_dir, strlen(server_dir)) == 0 &&
                path[strlen(server_dir)] == '/' &&
                strncmp(path + strlen(server_dir) + 1, "tmpmap-", 7) == 0 &&
                vi.pvip.vip_vi.vi_stat.vst_ino != 0) {
                free(fds);
                return 1;
            }
        }
    }
    free(fds);
    return query_failed ? -1 : saw_vnode ? 0 : -1;
}

static int socket_is_peer_of(uint64_t connected_socket,
                             const uint64_t *server_sockets, size_t count) {
    if (!connected_socket) return 0;
    for (size_t i = 0; i < count; i++)
        if (server_sockets[i] == connected_socket) return 1;
    return 0;
}

static int starts_with_windows_path(const char *s) {
    return s && isalpha((unsigned char)s[0]) && s[1] == ':' &&
           (s[2] == '\\' || s[2] == '/');
}

static int is_wine_helper(const char *name) {
    static const char *const helpers[] = {
        "winedevice.exe", "services.exe", "plugplay.exe", "svchost.exe",
        "rpcss.exe", "explorer.exe", "steam.exe", "winemenubuilder.exe",
        "conhost.exe", "start.exe", "wineboot.exe", "rundll32.exe",
        "tabtip.exe", "vc_redist", "vcredist", "dxsetup.exe", "msiexec.exe",
        "installinf", "iscriptevaluator.exe", "regsvr32.exe", "winedbg.exe",
        "unitycrashhandler",
        // Store clients can outlive the game in its private prefix.
        "upc.exe", "ubisoftgamelauncher.exe", "uplaywebcore.exe", "uplayservice.exe"
    };
    if (!name) return -1;
    char folded[128];
    size_t n = strlen(name);
    if (n >= sizeof(folded)) return -1;
    for (size_t i = 0; i <= n; i++)
        folded[i] = (char)tolower((unsigned char)name[i]);
    for (size_t i = 0; i < sizeof(helpers) / sizeof(helpers[0]); i++) {
        size_t helper_len = strlen(helpers[i]);
        const char *match = strstr(folded, helpers[i]);
        if (strcmp(helpers[i], "unitycrashhandler") == 0 && match &&
            match == folded) return 1;
        if (match && (match == folded || match[-1] == '\\' || match[-1] == '/') &&
            (match[helper_len] == '\0' || match[helper_len] == '.' ||
             !isalnum((unsigned char)match[helper_len])))
            return 1;
    }
    return 0;
}

static enum session_state classify(const struct session_process *p) {
    if (!p || !p->query_ok || !p->argv_complete ||
        !p->socket_matches_prefix || p->pid <= 0 ||
        (!p->start_sec && !p->start_usec))
        return SESSION_UNKNOWN;
    if (!p->args) return SESSION_UNKNOWN;
    // The server owns sockets in the prefix too, but is never the game.
    if (p->name && (strcasecmp(p->name, "wineserver") == 0 ||
                    strcasecmp(p->name, "wineserve") == 0) &&
        !starts_with_windows_path(p->args))
        return SESSION_IDLE;
    const char *arg = p->args;
    while (*arg) {
        while (*arg == ' ' || *arg == '\t') arg++;
        const char *end = arg + strcspn(arg, " \t");
        const char *base = arg;
        for (const char *c = arg; c < end; c++)
            if (*c == '\\' || *c == '/') base = c + 1;
        size_t len = (size_t)(end - base);
        if (len && len < 128) {
            char name[128];
            memcpy(name, base, len);
            name[len] = '\0';
            int helper = is_wine_helper(name);
            if (helper < 0) return SESSION_UNKNOWN;
            if (helper) return SESSION_IDLE;
        }
        arg = end;
    }
    if (!starts_with_windows_path(p->args)) return SESSION_UNKNOWN;
    return SESSION_GAME_PRESENT;
}

/* An attached process that cannot be classified must never contribute to idle. */
static enum session_state aggregate(enum session_state current,
                                    enum session_state observation) {
    if (current == SESSION_GAME_PRESENT || observation == SESSION_GAME_PRESENT)
        return SESSION_GAME_PRESENT;
    if (current == SESSION_UNKNOWN || observation == SESSION_UNKNOWN)
        return SESSION_UNKNOWN;
    return SESSION_IDLE;
}

static int check_server(const char *server_dir) {
    char canonical[MAXPATHLEN];
    struct stat server_stat;
    if (!server_dir || !realpath(server_dir, canonical) ||
        stat(canonical, &server_stat) != 0 || !S_ISDIR(server_stat.st_mode)) {
        return SESSION_UNKNOWN;
    }
    pid_t *pids = NULL;
    size_t count = 0;
    if (list_user_pids(&pids, &count) != 0) {
        return SESSION_UNKNOWN;
    }
    int unknown = 0;
    enum session_state aggregate_state = SESSION_IDLE;
    uint64_t *server_sockets = NULL;
    size_t server_socket_count = 0;

    // Find the Wine server for this exact prefix by its tmpmap files, then
    // retain only socket handles owned by that server as peer identities.
    for (size_t i = 0; i < count; i++) {
        if (pids[i] <= 0) continue;
        uint64_t sec = 0, usec = 0;
        char name[2 * MAXCOMLEN] = {0};
        if (process_identity(pids[i], &sec, &usec, name, sizeof(name)) != 0)
            continue;
        if (strcasecmp(name, "wineserver") != 0 &&
            strcasecmp(name, "wineserve") != 0) continue;
        if (pid_owns_server_path(pids[i], canonical, server_stat.st_dev) != 1 ||
            !same_process_identity(pids[i], sec, usec)) continue;
        int fd_bytes = proc_pidinfo(pids[i], PROC_PIDLISTFDS, 0, NULL, 0);
        if (fd_bytes <= 0) { unknown = 1; continue; }
        struct proc_fdinfo *fds = malloc((size_t)fd_bytes);
        if (!fds) { unknown = 1; continue; }
        int fd_got = proc_pidinfo(pids[i], PROC_PIDLISTFDS, 0, fds, fd_bytes);
        if (fd_got < 0) { free(fds); unknown = 1; continue; }
        for (int f = 0; f < fd_got / (int)sizeof(*fds); f++) {
            if (fds[f].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
            struct socket_fdinfo si;
            if (proc_pidfdinfo(pids[i], fds[f].proc_fd, PROC_PIDFDSOCKETINFO,
                               &si, sizeof(si)) != sizeof(si)) continue;
            if (si.psi.soi_kind != SOCKINFO_UN || !si.psi.soi_so) continue;
            uint64_t *next = realloc(server_sockets,
                (server_socket_count + 1) * sizeof(*server_sockets));
            if (!next) { unknown = 1; break; }
            server_sockets = next;
            server_sockets[server_socket_count++] = si.psi.soi_so;
        }
        free(fds);
        if (!same_process_identity(pids[i], sec, usec)) unknown = 1;
    }
    if (server_socket_count == 0) unknown = 1;

    for (size_t i = 0; i < count; i++) {
        if (pids[i] <= 0) continue;
        uint64_t sec = 0, usec = 0;
        char name[2 * MAXCOMLEN] = {0};
        if (process_identity(pids[i], &sec, &usec, name, sizeof(name)) != 0) {
            continue;
        }
        int fd_bytes = proc_pidinfo(pids[i], PROC_PIDLISTFDS, 0, NULL, 0);
        if (fd_bytes <= 0) {
            if (same_process_identity(pids[i], sec, usec)) unknown = 1;
            continue;
        }
        struct proc_fdinfo *fds = malloc((size_t)fd_bytes);
        if (!fds) { unknown = 1; continue; }
        int fd_got = proc_pidinfo(pids[i], PROC_PIDLISTFDS, 0, fds, fd_bytes);
        if (fd_got < 0) {
            free(fds);
            if (same_process_identity(pids[i], sec, usec)) unknown = 1;
            continue;
        }
        int member = 0;
        int socket_query_failed = 0;
        for (int f = 0; f < fd_got / (int)sizeof(*fds); f++) {
            if (fds[f].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
            struct socket_fdinfo si;
            if (proc_pidfdinfo(pids[i], fds[f].proc_fd, PROC_PIDFDSOCKETINFO,
                               &si, sizeof(si)) != sizeof(si)) {
                socket_query_failed = 1;
                continue;
            }
            if (si.psi.soi_kind == SOCKINFO_UN &&
                socket_is_peer_of(si.psi.soi_proto.pri_un.unsi_conn_so,
                                  server_sockets, server_socket_count)) {
                member = 1;
                break;
            }
        }
        free(fds);
        if (!same_process_identity(pids[i], sec, usec)) continue;
        if (!member) {
            if (socket_query_failed) unknown = 1;
            continue;
        }
        char args[8192] = {0};
        if (read_process_argv(pids[i], args, sizeof(args)) != 0 ||
            !same_process_identity(pids[i], sec, usec)) {
            unknown = 1;
            continue;
        }
        struct session_process p = {
            .pid = pids[i], .start_sec = sec, .start_usec = usec,
            .name = name, .args = args, .query_ok = 1,
            .socket_matches_prefix = 1, .argv_complete = 1
        };
        if (!same_process_identity(pids[i], sec, usec)) {
            unknown = 1;
            continue;
        }
        aggregate_state = aggregate(aggregate_state, classify(&p));
    }
    free(server_sockets);
    free(pids);
    if (unknown) aggregate_state = aggregate(aggregate_state, SESSION_UNKNOWN);
    return aggregate_state;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        return SESSION_UNKNOWN;
    }
    return check_server(argv[1]);
}

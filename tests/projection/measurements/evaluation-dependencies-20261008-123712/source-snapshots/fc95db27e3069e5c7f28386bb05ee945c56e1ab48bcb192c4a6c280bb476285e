// Filesystem-only leases. No R API, model state, background thread or vendor code.
#include <cstring>
#include <cerrno>
#include <memory>
#include <string>
#include <vector>

#if defined(__APPLE__) || defined(__linux__)
#include <dirent.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {
#ifdef RELM_SPILL_TESTING
thread_local void (*before_open)() = nullptr;
#endif
constexpr const char * marker = ".relm-owner";
constexpr const char * format = "relm-managed-spill-v1\n";
struct Fd {
    int n;
    explicit Fd(int value = -1) : n(value) {}
    ~Fd() { if (n >= 0) close(n); }
    int release() { int value = n; n = -1; return value; }
    Fd(const Fd &) = delete;
    Fd & operator=(const Fd &) = delete;
};
bool same(const struct stat & a, const struct stat & b) {
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}
bool leaf_ok(const std::string & s) {
    return !s.empty() && s != "." && s != ".." && s.find('/') == std::string::npos;
}
// Walk from / with descriptor-relative opens: reject links in every component.
int open_root(const std::string & path, bool create) {
    if (path.empty() || path[0] != '/') return -1;
    Fd fd(open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC));
    if (fd.n < 0) return -1;
    size_t pos = 1;
    while (pos < path.size()) {
        size_t end = path.find('/', pos);
        if (end == std::string::npos) end = path.size();
        std::string part = path.substr(pos, end - pos);
        if (!leaf_ok(part)) return -1;
        if (create && mkdirat(fd.n, part.c_str(), 0700) != 0 && errno != EEXIST) {
            return -1;
        }
        int next = openat(fd.n, part.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(fd.n);
        fd.n = next;
        if (fd.n < 0) return -1;
        pos = end + 1;
    }
    struct stat st{};
    if (fstat(fd.n, &st) || st.st_uid != geteuid()) return -1;
    return fd.release();
}
struct Lease {
    std::string root_path, leaf;
    Fd root, dir, lock;
    struct stat root_id{}, dir_id{}, lock_id{};
    pid_t pid = getpid();
    Lease(std::string root_name, std::string name, int root_fd, int dir_fd, int lock_fd)
        : root_path(std::move(root_name)), leaf(std::move(name)),
          root(root_fd), dir(dir_fd), lock(lock_fd) {}
    bool identity() const {
        if (pid != getpid()) return false; // forked handles never delete a parent's files.
        Fd current(open_root(root_path, false));
        struct stat r{}, d{}, l{};
        return current.n >= 0 && !fstat(current.n, &r) && same(r, root_id) &&
            !fstatat(root.n, leaf.c_str(), &d, AT_SYMLINK_NOFOLLOW) &&
            S_ISDIR(d.st_mode) && same(d, dir_id) &&
            !fstatat(dir.n, marker, &l, AT_SYMLINK_NOFOLLOW) &&
            S_ISREG(l.st_mode) && l.st_nlink == 1 && same(l, lock_id);
    }
};
std::unique_ptr<Lease> acquire(const std::string & root, const std::string & leaf, bool create) {
    if (!leaf_ok(leaf)) return nullptr;
    Fd r(open_root(root, create));
    if (r.n < 0) return nullptr;
    if (create && mkdirat(r.n, leaf.c_str(), 0700)) return nullptr;
    Fd d(openat(r.n, leaf.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    if (d.n < 0) return nullptr;
    struct stat ds{};
    if (fstat(d.n, &ds) || ds.st_uid != geteuid()) return nullptr;
    Fd l(openat(d.n, marker, O_RDWR | O_NOFOLLOW | O_CLOEXEC |
        (create ? O_CREAT | O_EXCL : 0), 0600));
    if (l.n < 0 || flock(l.n, LOCK_EX | LOCK_NB)) return nullptr;
    struct stat ls{};
    if (fstat(l.n, &ls) || !S_ISREG(ls.st_mode) || ls.st_uid != geteuid() || ls.st_nlink != 1)
        return nullptr;
    if (create && write(l.n, format, std::strlen(format)) != static_cast<ssize_t>(std::strlen(format)))
        return nullptr;
    char content[64]{};
    ssize_t count = pread(l.n, content, sizeof(content), 0);
    if (count != static_cast<ssize_t>(std::strlen(format)) ||
        std::memcmp(content, format, std::strlen(format))) return nullptr;
    auto p = std::make_unique<Lease>(root, leaf, r.n, d.n, l.n);
    r.n = d.n = l.n = -1;
    if (fstat(p->root.n, &p->root_id) || fstat(p->dir.n, &p->dir_id) ||
        fstat(p->lock.n, &p->lock_id) || !p->identity()) return nullptr;
    return p;
}
// Managed directories are flat: never descend into an unknown directory or link.
// Preflight all entries before deleting any. Keep the lock until after rmdir.
bool remove_owned(Lease & p) {
    if (!p.identity()) return false;
    Fd scan(openat(p.dir.n, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC));
    if (scan.n < 0) return false;
    std::unique_ptr<DIR, int (*)(DIR *)> stream(fdopendir(scan.n), closedir);
    if (!stream) return false;
    scan.n = -1;
    std::vector<std::pair<std::string, struct stat>> entries;
    bool valid = true;
    errno = 0;
    while (auto * e = readdir(stream.get())) {
        std::string name(e->d_name);
        if (name == "." || name == ".." || name == marker) continue;
        struct stat st{};
        if (name.rfind("trace-", 0) != 0 || name.size() < 12 ||
            name.substr(name.size() - 6) != ".arrow" ||
            fstatat(p.dir.n, name.c_str(), &st, AT_SYMLINK_NOFOLLOW) ||
            !S_ISREG(st.st_mode) || st.st_uid != geteuid() || st.st_nlink != 1) {
            valid = false; break;
        }
        entries.emplace_back(name, st);
        errno = 0;
    }
    if (errno) valid = false;
    stream.reset();
    if (!valid) return false;
    for (const auto & entry : entries) {
        struct stat now{};
        if (!p.identity() || fstatat(p.dir.n, entry.first.c_str(), &now, AT_SYMLINK_NOFOLLOW) ||
            !same(now, entry.second) || !S_ISREG(now.st_mode) || now.st_nlink != 1 ||
            unlinkat(p.dir.n, entry.first.c_str(), 0)) return false;
    }
    if (!p.identity() || unlinkat(p.dir.n, marker, 0)) return false;
    return unlinkat(p.root.n, p.leaf.c_str(), AT_REMOVEDIR) == 0;
}
}

extern "C" void * relm_spill_lease_create(const char * root, const char * leaf) noexcept {
    try { return acquire(root, leaf, true).release(); } catch (...) { return nullptr; }
}
extern "C" void relm_spill_lease_release(void * ptr) noexcept {
    delete static_cast<Lease *>(ptr);
}
extern "C" int relm_spill_lease_valid(void * ptr) noexcept {
    try { return ptr && static_cast<Lease *>(ptr)->identity(); } catch (...) { return 0; }
}
extern "C" int relm_spill_lease_open(void * ptr, const char * name) noexcept {
    try {
        auto * p = static_cast<Lease *>(ptr);
        std::string leaf(name);
        if (!p || !leaf_ok(leaf) || leaf.rfind("trace-", 0) != 0 || leaf.size() < 12 ||
            leaf.substr(leaf.size() - 6) != ".arrow" || !p->identity()) return -1;
        // Anchor the write to the leased directory, never re-resolve its pathname.
        // A rename after identity() cannot redirect this open into another tree.
#ifdef RELM_SPILL_TESTING
        if (before_open) before_open();
#endif
        Fd fd(openat(p->dir.n, leaf.c_str(), O_WRONLY | O_CREAT | O_EXCL |
            O_NOFOLLOW | O_CLOEXEC, 0600));
        if (fd.n >= 0 && !p->identity()) {
            // Preserve the incomplete owned file; never touch the replacement.
            return -1;
        }
        return fd.release();
    } catch (...) { return -1; }
}
#ifdef RELM_SPILL_TESTING
extern "C" void relm_spill_test_before_open(void (*hook)()) noexcept { before_open = hook; }
#endif
extern "C" int relm_spill_lease_cleanup(void * ptr) noexcept {
    try { return ptr && remove_owned(*static_cast<Lease *>(ptr)); } catch (...) { return 0; }
}
extern "C" int relm_spill_lease_sweep(const char * root, const char * leaf, double cutoff) noexcept {
    try {
        auto p = acquire(root, leaf, false);
        if (!p || !p->identity() || static_cast<double>(p->dir_id.st_mtime) >= cutoff) return 0;
        return remove_owned(*p);
    } catch (...) { return 0; }
}
#else
// Until another platform has a verified lease implementation, retain directories.
extern "C" void * relm_spill_lease_create(const char *, const char *) noexcept { return nullptr; }
extern "C" void relm_spill_lease_release(void *) noexcept {}
extern "C" int relm_spill_lease_valid(void *) noexcept { return 0; }
extern "C" int relm_spill_lease_open(void *, const char *) noexcept { return -1; }
extern "C" int relm_spill_lease_cleanup(void *) noexcept { return 0; }
extern "C" int relm_spill_lease_sweep(const char *, const char *, double) noexcept { return 0; }
#endif

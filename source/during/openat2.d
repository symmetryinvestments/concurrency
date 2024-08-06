module during.openat2;

/**
 * Arguments for how `openat2(2)` should open the target path. If only `flags` and `mode` are
 * non-zero, then `openat2(2)`` operates very similarly to openat(2).
 *
 * However, unlike openat(2), unknown or invalid bits in @flags result in `-EINVAL` rather than
 * being silently ignored. @mode must be zero unless one of `O_CREAT`, `O_TMPFILE` are set.
 */
struct OpenHow
{
    ulong flags;        /// O_* flags
    ulong mode;         /// O_CREAT/O_TMPFILE file mode
    Resolve resolve;    /// Resolve flags
}

/// Resolve flags
enum Resolve : ulong
{
    /// Block mount-point crossings (includes bind-mounts).
    RESOLVE_NO_XDEV = 0x01,
    /// Block traversal through procfs-style "magic-links".
    RESOLVE_NO_MAGICLINKS = 0x02,
    /// Block traversal through all symlinks (implies OEXT_NO_MAGICLINKS)
    RESOLVE_NO_SYMLINKS = 0x04,
    /// Block "lexical" trickery like "..", symlinks, and absolute paths which escape the dirfd.
    RESOLVE_BENEATH = 0x08,
    /// Make all jumps to "/" and ".." be scoped inside the dirfd (similar to chroot(2)).
    RESOLVE_IN_ROOT = 0x10
}
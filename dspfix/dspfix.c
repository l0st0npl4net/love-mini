/*
 * From panelattack-miyoo by snyderman3000 (MIT License, see THIRD_PARTY_NOTICES.md);
 * love-mini primes libpadsp before its first /dev/dsp (see open64 below) and gives
 * OSS's argument-less ioctls an argument (see ioctl below).
 */
/*
 * dspfix: lets programs built with large-file support reach OnionOS's
 * audio server.
 *
 * OnionOS plays OSS audio through libpadsp.so (LD_PRELOAD), which intercepts
 * open("/dev/dsp") and sends the samples to its audioserver. Libraries built
 * with _FILE_OFFSET_BITS=64, like the OpenAL Soft in the Miyoo toolchain,
 * call open64() instead, which libpadsp doesn't hook, so they hit the real
 * /dev/dsp (owned by audioserver: "Device or resource busy").
 *
 * This library defines open64() and forwards /dev/dsp to libpadsp's open().
 * Preload it before libpadsp: LD_PRELOAD="libdspfix.so libpadsp.so"
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <string.h>
#include <sys/soundcard.h>
#include <sys/types.h>
#include <unistd.h>

typedef int (*open_fn)(const char *, int, ...);

int open64(const char *path, int flags, ...)
{
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    if (path && strncmp(path, "/dev/dsp", 8) == 0) {
        static open_fn padsp_open;
        if (!padsp_open) {
            padsp_open = (open_fn)dlsym(RTLD_DEFAULT, "open");
            /* libpadsp finds the real open() (dlsym RTLD_NEXT) only when it is asked
             * to open some other file; its /dev/dsp path calls that pointer
             * unchecked. In a program built entirely with large-file support
             * nothing calls open() before /dev/dsp, the pointer is still NULL and
             * the program crashes. One harmless open first sets it. */
            if (padsp_open) {
                int fd = padsp_open("/dev/null", O_RDONLY);
                if (fd >= 0) close(fd);
            }
        }
        if (padsp_open)
            return padsp_open(path, flags & ~O_LARGEFILE, mode);
    }
    static open_fn real_open64;
    if (!real_open64)
        real_open64 = (open_fn)dlsym(RTLD_NEXT, "open64");
    return real_open64(path, flags, mode);
}

/*
 * libpadsp reads 4 bytes from the argument of every ioctl on its /dev/dsp, even of
 * the OSS requests that take none: SNDCTL_DSP_RESET, which OpenAL Soft sends with
 * no argument when it stops (a game quitting), crashed there on whatever was left
 * in the register. Those requests get a pointer to a zero; the rest pass as they are.
 */
typedef int (*ioctl_fn)(int, unsigned long, ...);

int ioctl(int fd, unsigned long request, ...)
{
    va_list ap;
    va_start(ap, request);
    void *arg = va_arg(ap, void *);
    va_end(ap);
    static ioctl_fn next_ioctl;
    if (!next_ioctl)
        next_ioctl = (ioctl_fn)dlsym(RTLD_NEXT, "ioctl");
    switch (request) {
    case SNDCTL_DSP_RESET:
    case SNDCTL_DSP_SYNC:
    case SNDCTL_DSP_POST:
    case SNDCTL_DSP_NONBLOCK: {
        int zero = 0;
        return next_ioctl(fd, request, &zero);
    }
    }
    return next_ioctl(fd, request, arg);
}

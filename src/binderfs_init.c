//go:build ignore
/*
 * src/binderfs_init.c - Dynamic BinderFS and Legacy Binder IPC Initializer (Reference Implementation)
 * Target: OnePlus 7T (HD1901 / hotdogb) - SM8150 / Adreno 640
 *
 * Dynamically allocates binder, hwbinder, and vndbinder through
 * /dev/binderfs/binder-control via BINDER_CTL_ADD ioctl.
 * Sets permissions to 0666, establishes symlinks in /dev, and strictly
 * validates that all devices are character devices and openable O_RDWR.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/sysmacros.h>
#include <linux/types.h>

#ifndef BINDERFS_MAX_NAME
#define BINDERFS_MAX_NAME 255
#endif

struct binderfs_device {
    char name[BINDERFS_MAX_NAME + 1];
    __u32 major;
    __u32 minor;
};

#ifndef BINDER_CTL_ADD
#define BINDER_CTL_ADD _IOWR('b', 1, struct binderfs_device)
#endif

static void log_kmsg(const char *msg) {
    printf("%s\n", msg);
    int fd = open("/dev/kmsg", O_WRONLY | O_APPEND);
    if (fd >= 0) {
        dprintf(fd, "%s\n", msg);
        close(fd);
    }
}

int main(int argc, char *argv[]) {
    (void)argc;
    (void)argv;

    const char *devices[] = {"binder", "hwbinder", "vndbinder"};
    const char *control_path = "/dev/binderfs/binder-control";
    const char *mount_path = "/dev/binderfs";
    const char *dev_dir = "/dev";
    int num_devs = (int)(sizeof(devices) / sizeof(devices[0]));

    log_kmsg("[BINDERFS_INIT] Starting dynamic Binder device initialization (C)...");

    int ctl_fd = open(control_path, O_RDONLY | O_CLOEXEC);
    if (ctl_fd >= 0) {
        char msg[2048];
        snprintf(msg, sizeof(msg), "[BINDERFS_INIT] Opened binder-control at %s", control_path);
        log_kmsg(msg);

        for (int i = 0; i < num_devs; i++) {
            char target[512];
            snprintf(target, sizeof(target), "%s/%s", mount_path, devices[i]);

            struct stat st;
            if (stat(target, &st) == 0 && S_ISCHR(st.st_mode)) {
                snprintf(msg, sizeof(msg), "[BINDERFS_INIT] Device %s already exists in %s", devices[i], mount_path);
                log_kmsg(msg);
                continue;
            }

            struct binderfs_device req;
            memset(&req, 0, sizeof(req));
            strncpy(req.name, devices[i], BINDERFS_MAX_NAME);

            if (ioctl(ctl_fd, BINDER_CTL_ADD, &req) == 0) {
                snprintf(msg, sizeof(msg), "[BINDERFS_INIT] Successfully allocated '%s' in binderfs (major: %u, minor: %u)",
                         devices[i], req.major, req.minor);
                log_kmsg(msg);
                if (chmod(target, 0666) != 0) {
                    snprintf(msg, sizeof(msg), "[BINDERFS_INIT WARNING] chmod 0666 failed for '%s': %s",
                             target, strerror(errno));
                    log_kmsg(msg);
                }
            } else {
                snprintf(msg, sizeof(msg), "[BINDERFS_INIT WARNING] ioctl BINDER_CTL_ADD failed for '%s': %s",
                         devices[i], strerror(errno));
                log_kmsg(msg);
            }
        }
        close(ctl_fd);
    } else {
        char msg[2048];
        snprintf(msg, sizeof(msg), "[BINDERFS_INIT WARNING] Cannot open %s: %s. Checking legacy fallback.",
                 control_path, strerror(errno));
        log_kmsg(msg);
    }

    // Symlink /dev/<name> -> /dev/binderfs/<name> and fallback
    for (int i = 0; i < num_devs; i++) {
        char src[512], dst[512];
        snprintf(src, sizeof(src), "%s/%s", mount_path, devices[i]);
        snprintf(dst, sizeof(dst), "%s/%s", dev_dir, devices[i]);

        struct stat st;
        if (stat(src, &st) == 0 && S_ISCHR(st.st_mode)) {
            struct stat dst_st;
            if (lstat(dst, &dst_st) == 0) {
                if (S_ISLNK(dst_st.st_mode)) {
                    if (unlink(dst) != 0) {
                        char msg[2048];
                        snprintf(msg, sizeof(msg), "[BINDERFS_INIT WARNING] unlink stale symlink %s failed: %s", dst, strerror(errno));
                        log_kmsg(msg);
                    }
                } else if (!S_ISCHR(dst_st.st_mode)) {
                    char msg[2048];
                    snprintf(msg, sizeof(msg), "[BINDERFS_INIT ERROR] %s exists and is not a device node! Refusing to overwrite.", dst);
                    log_kmsg(msg);
                    continue;
                }
            }
            if (symlink(src, dst) == 0) {
                chmod(src, 0666);
                chmod(dst, 0666);
            } else if (errno != EEXIST) {
                char msg[2048];
                snprintf(msg, sizeof(msg), "[BINDERFS_INIT WARNING] symlink %s -> %s failed: %s", dst, src, strerror(errno));
                log_kmsg(msg);
            }
        } else {
            // Check sysfs fallback: /sys/class/misc/<name>/dev
            char sys_path[512];
            snprintf(sys_path, sizeof(sys_path), "/sys/class/misc/%s/dev", devices[i]);
            FILE *f = fopen(sys_path, "r");
            if (f) {
                int maj = 0, min = 0;
                if (fscanf(f, "%d:%d", &maj, &min) == 2 && maj >= 0 && min >= 0 && maj <= 0xfffff) {
                    if (lstat(dst, &st) != 0) {
                        if (mknod(dst, S_IFCHR | 0666, makedev((unsigned int)maj, (unsigned int)min)) == 0) {
                            chmod(dst, 0666);
                        } else {
                            char msg[2048];
                            snprintf(msg, sizeof(msg), "[BINDERFS_INIT WARNING] mknod %s failed: %s", dst, strerror(errno));
                            log_kmsg(msg);
                        }
                    } else if (S_ISCHR(st.st_mode)) {
                        chmod(dst, 0666);
                    } else {
                        char msg[2048];
                        snprintf(msg, sizeof(msg), "[BINDERFS_INIT ERROR] Target %s exists and is not a character device! Refusing to overwrite.", dst);
                        log_kmsg(msg);
                    }
                }
                fclose(f);
            }
        }
    }

    // Strict validation
    int all_ok = 1;
    for (int i = 0; i < num_devs; i++) {
        char dst[512];
        snprintf(dst, sizeof(dst), "%s/%s", dev_dir, devices[i]);
        struct stat st;
        if (stat(dst, &st) != 0 || !S_ISCHR(st.st_mode)) {
            char msg[2048];
            snprintf(msg, sizeof(msg), "[BINDERFS_INIT FATAL] Device %s does not exist or is not a character device!", dst);
            log_kmsg(msg);
            all_ok = 0;
            continue;
        }

        int fd = open(dst, O_RDWR | O_CLOEXEC);
        if (fd < 0) {
            char msg[2048];
            snprintf(msg, sizeof(msg), "[BINDERFS_INIT FATAL] Failed to open %s with O_RDWR: %s", dst, strerror(errno));
            log_kmsg(msg);
            all_ok = 0;
            continue;
        }
        close(fd);
    }

    if (!all_ok) {
        log_kmsg("[BINDERFS_INIT FATAL] Critical Binder IPC device initialization FAILED!");
        return 1;
    }

    log_kmsg("[BINDERFS_INIT] All required Binder IPC devices initialized and verified successfully.");
    return 0;
}

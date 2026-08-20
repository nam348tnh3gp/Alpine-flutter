#include <jni.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <android/log.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <dirent.h>

#define LOG_TAG "ProotLauncher"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__)

typedef struct {
    JNIEnv *env;
    jobject callback;
    jmethodID onLogMid;
} LogCtx;

static int g_master_fd = -1;
static pid_t g_child_pid = -1;

static void emit_log(LogCtx *ctx, const char *prefix, const char *line, size_t len) {
    if (ctx->callback == NULL || ctx->onLogMid == NULL) {
        LOGD("%s %.*s", prefix, (int)len, line);
        return;
    }
    char buf[4200];
    int n = snprintf(buf, sizeof(buf), "%s %.*s", prefix, (int)len, line);
    if (n < 0) return;
    jstring jline = (*ctx->env)->NewStringUTF(ctx->env, buf);
    if (jline == NULL) return;
    (*ctx->env)->CallVoidMethod(ctx->env, ctx->callback, ctx->onLogMid, jline);
    if ((*ctx->env)->ExceptionCheck(ctx->env)) {
        (*ctx->env)->ExceptionClear(ctx->env);
    }
    (*ctx->env)->DeleteLocalRef(ctx->env, jline);
}

static void drain_fd(int fd, LogCtx *ctx, const char *prefix, char *linebuf, size_t *linelen, size_t linecap) {
    char chunk[4096];
    for (;;) {
        ssize_t n = read(fd, chunk, sizeof(chunk));
        if (n <= 0) break;
        for (ssize_t i = 0; i < n; i++) {
            char c = chunk[i];
            if (c == '\n') {
                emit_log(ctx, prefix, linebuf, *linelen);
                *linelen = 0;
            } else if (*linelen < linecap - 1) {
                linebuf[(*linelen)++] = c;
            }
        }
    }
}

JNIEXPORT jint JNICALL
Java_com_example_alpinerunner_ProotLauncher_runProot(
    JNIEnv *env,
    jobject thiz,
    jstring prootPath,
    jobjectArray argsArray,
    jobjectArray envArray,
    jobject logCallback,
    jint rows,
    jint cols) {

    LogCtx ctx = {0};
    ctx.env = env;
    ctx.callback = logCallback;
    if (logCallback != NULL) {
        jclass cbClass = (*env)->GetObjectClass(env, logCallback);
        ctx.onLogMid = (*env)->GetMethodID(env, cbClass, "onLog", "(Ljava/lang/String;)V");
        if (ctx.onLogMid == NULL) {
            (*env)->ExceptionClear(env);
            LOGE("logCallback không có method onLog(String)");
        }
    }

    const char *proot = (*env)->GetStringUTFChars(env, prootPath, NULL);
    if (proot == NULL) {
        const char *m = "GetStringUTFChars(prootPath) thất bại";
        emit_log(&ctx, "[launcher]", m, strlen(m));
        return -1;
    }

    struct stat st;
    if (stat(proot, &st) != 0) {
        char msg[512];
        int n = snprintf(msg, sizeof(msg), "[launcher] Không tìm thấy proot binary tại '%s': %s", proot, strerror(errno));
        emit_log(&ctx, "[launcher]", msg, (size_t)n);
        (*env)->ReleaseStringUTFChars(env, prootPath, proot);
        return -1;
    } else if (!(st.st_mode & S_IXUSR)) {
        char msg[512];
        int n = snprintf(msg, sizeof(msg), "[launcher] '%s' thiếu quyền execute", proot);
        emit_log(&ctx, "[launcher]", msg, (size_t)n);
        (*env)->ReleaseStringUTFChars(env, prootPath, proot);
        return -1;
    }

    int argc = (*env)->GetArrayLength(env, argsArray);
    char **argv = malloc((argc + 2) * sizeof(char *));
    argv[0] = strdup(proot);
    for (int i = 0; i < argc; i++) {
        jstring arg = (jstring)(*env)->GetObjectArrayElement(env, argsArray, i);
        const char *argStr = (*env)->GetStringUTFChars(env, arg, NULL);
        argv[i + 1] = strdup(argStr);
        (*env)->ReleaseStringUTFChars(env, arg, argStr);
        (*env)->DeleteLocalRef(env, arg);
    }
    argv[argc + 1] = NULL;

    int envc = (*env)->GetArrayLength(env, envArray);
    char **envp = malloc((envc + 1) * sizeof(char *));
    for (int i = 0; i < envc; i++) {
        jstring envStr = (jstring)(*env)->GetObjectArrayElement(env, envArray, i);
        const char *envStrC = (*env)->GetStringUTFChars(env, envStr, NULL);
        envp[i] = strdup(envStrC);
        (*env)->ReleaseStringUTFChars(env, envStr, envStrC);
        (*env)->DeleteLocalRef(env, envStr);
    }
    envp[envc] = NULL;

    {
        char msg[4096];
        int off = snprintf(msg, sizeof(msg), "[launcher] exec: %s", argv[0]);
        for (int i = 1; argv[i] != NULL && off < (int)sizeof(msg) - 1; i++) {
            off += snprintf(msg + off, sizeof(msg) - off, " %s", argv[i]);
        }
        emit_log(&ctx, "[launcher]", msg, (size_t)off);
        for (int i = 0; envp[i] != NULL; i++) {
            emit_log(&ctx, "[launcher][env]", envp[i], strlen(envp[i]));
        }
    }

    // --- Tạo PTY giống Termux ---
    int master_fd = open("/dev/ptmx", O_RDWR | O_CLOEXEC);
    if (master_fd < 0) {
        char msg[256];
        int n = snprintf(msg, sizeof(msg), "[launcher] open(/dev/ptmx) thất bại: %s", strerror(errno));
        emit_log(&ctx, "[launcher]", msg, (size_t)n);
        return -1;
    }

    char devname[64];
    if (grantpt(master_fd) || unlockpt(master_fd) ||
        ptsname_r(master_fd, devname, sizeof(devname)) != 0) {
        char msg[256];
        int n = snprintf(msg, sizeof(msg), "[launcher] grantpt/unlockpt/ptsname_r thất bại");
        emit_log(&ctx, "[launcher]", msg, (size_t)n);
        close(master_fd);
        return -1;
    }

    // Cấu hình termios theo Termux
    struct termios tios;
    tcgetattr(master_fd, &tios);
    tios.c_iflag |= IUTF8;
    tios.c_iflag &= ~(IXON | IXOFF);
    tios.c_lflag |= (ECHO | ICANON | ISIG | IEXTEN);
    tios.c_oflag |= (OPOST | ONLCR);
    tios.c_iflag |= (ICRNL | IXON);
    tios.c_cc[VERASE] = 127;
    tios.c_cc[VINTR] = 3;
    tios.c_cc[VQUIT] = 28;
    tios.c_cc[VSUSP] = 26;
    tcsetattr(master_fd, TCSANOW, &tios);

    // Đặt kích thước
    if (rows <= 0) rows = 24;
    if (cols <= 0) cols = 80;
    struct winsize sz = {
        .ws_row = (unsigned short) rows,
        .ws_col = (unsigned short) cols,
        .ws_xpixel = (unsigned short) (cols * 8),
        .ws_ypixel = (unsigned short) (rows * 16)
    };
    ioctl(master_fd, TIOCSWINSZ, &sz);

    pid_t pid = fork();
    if (pid == 0) {
        // Tiến trình con
        close(master_fd);
        setsid();

        int slave_fd = open(devname, O_RDWR);
        if (slave_fd < 0) _exit(127);

        dup2(slave_fd, 0);
        dup2(slave_fd, 1);
        dup2(slave_fd, 2);

        // Đóng tất cả file descriptor > 2
        DIR *self_dir = opendir("/proc/self/fd");
        if (self_dir != NULL) {
            int self_dir_fd = dirfd(self_dir);
            struct dirent *entry;
            while ((entry = readdir(self_dir)) != NULL) {
                int fd = atoi(entry->d_name);
                if (fd > 2 && fd != self_dir_fd) close(fd);
            }
            closedir(self_dir);
        }

        // Xóa environment và set mới
        clearenv();
        if (envp) {
            for (char **p = envp; *p; ++p) putenv(*p);
        }

        // Chuyển đến thư mục gốc (có thể thay đổi nếu muốn)
        if (chdir("/") != 0) {
            perror("chdir");
        }

        execvp(proot, argv);
        // Nếu execvp thất bại
        perror("execvp");
        _exit(127);
    } else if (pid < 0) {
        char msg[128];
        int n = snprintf(msg, sizeof(msg), "[launcher] fork thất bại: %s", strerror(errno));
        emit_log(&ctx, "[launcher]", msg, (size_t)n);
        close(master_fd);
        return -1;
    }

    g_master_fd = master_fd;
    g_child_pid = pid;

    // Đọc output từ master và forward qua log callback
    fcntl(master_fd, F_SETFL, O_NONBLOCK);
    char linebuf[4096]; size_t linelen = 0;
    int status = 0;
    int childExited = 0;
    int exitCode = -1;

    while (!childExited) {
        struct pollfd fds[1] = { { master_fd, POLLIN, 0 } };
        poll(fds, 1, 100);
        drain_fd(master_fd, &ctx, "[pty]", linebuf, &linelen, sizeof(linebuf));
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid) {
            childExited = 1;
        } else if (r < 0 && errno != EINTR) {
            char msg[128];
            int n = snprintf(msg, sizeof(msg), "[launcher] waitpid lỗi: %s", strerror(errno));
            emit_log(&ctx, "[launcher]", msg, (size_t)n);
            break;
        }
    }

    drain_fd(master_fd, &ctx, "[pty]", linebuf, &linelen, sizeof(linebuf));
    if (linelen > 0) emit_log(&ctx, "[pty]", linebuf, linelen);
    close(master_fd);
    g_master_fd = -1;
    g_child_pid = -1;

    if (WIFEXITED(status)) {
        exitCode = WEXITSTATUS(status);
        if (exitCode == 127) {
            const char *m = "execvp thất bại (127)";
            emit_log(&ctx, "[launcher]", m, strlen(m));
        }
    } else if (WIFSIGNALED(status)) {
        char msg[128];
        int n = snprintf(msg, sizeof(msg), "[launcher] bị kill bởi signal %d", WTERMSIG(status));
        emit_log(&ctx, "[launcher]", msg, (size_t)n);
        exitCode = 128 + WTERMSIG(status);
    }

    free((void *)proot);
    for (int i = 0; i < argc + 1; i++) free(argv[i]);
    free(argv);
    for (int i = 0; i < envc; i++) free(envp[i]);
    free(envp);

    return exitCode;
}

JNIEXPORT jint JNICALL
Java_com_example_alpinerunner_ProotLauncher_writeToPty(
    JNIEnv *env,
    jobject thiz,
    jbyteArray data) {
    if (g_master_fd == -1) {
        LOGE("writeToPty: master_fd không hợp lệ");
        return -1;
    }
    jsize len = (*env)->GetArrayLength(env, data);
    jbyte *bytes = (*env)->GetByteArrayElements(env, data, NULL);
    if (bytes == NULL) {
        LOGE("writeToPty: không lấy được bytes");
        return -1;
    }
    ssize_t written = write(g_master_fd, bytes, len);
    if (written < 0) {
        LOGE("writeToPty: write thất bại: %s", strerror(errno));
    }
    (*env)->ReleaseByteArrayElements(env, data, bytes, JNI_ABORT);
    return (jint)written;
}

JNIEXPORT void JNICALL
Java_com_example_alpinerunner_ProotLauncher_killProot(JNIEnv *env, jobject thiz) {
    if (g_child_pid > 0) {
        kill(g_child_pid, SIGTERM);
        usleep(100000);
        if (kill(g_child_pid, 0) == 0) {
            kill(g_child_pid, SIGKILL);
        }
        g_child_pid = -1;
    }
    if (g_master_fd != -1) {
        close(g_master_fd);
        g_master_fd = -1;
    }
}

JNIEXPORT void JNICALL
Java_com_example_alpinerunner_ProotLauncher_resizePty(
    JNIEnv *env,
    jobject thiz,
    jint width,
    jint height) {
    if (g_master_fd == -1) return;
    if (width <= 0) width = 80;
    if (height <= 0) height = 24;
    struct winsize sz = {
        .ws_row = (unsigned short) height,
        .ws_col = (unsigned short) width,
        .ws_xpixel = (unsigned short) (width * 8),
        .ws_ypixel = (unsigned short) (height * 16)
    };
    ioctl(g_master_fd, TIOCSWINSZ, &sz);
    if (g_child_pid > 0) {
        kill(g_child_pid, SIGWINCH);
    }
}
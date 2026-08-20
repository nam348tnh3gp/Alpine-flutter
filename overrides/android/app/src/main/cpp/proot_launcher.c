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
    jobject logCallback) {

    LogCtx ctx = {0};
    ctx.env = env;
    ctx.callback = logCallback;
    if (logCallback != NULL) {
        jclass cbClass = (*env)->GetObjectClass(env, logCallback);
        ctx.onLogMid = (*env)->GetMethodID(env, cbClass, "onLog", "(Ljava/lang/String;)V");
        if (ctx.onLogMid == NULL) {
            (*env)->ExceptionClear(env);
            LOGE("logCallback không có method onLog(String) - log sẽ chỉ vào logcat");
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
        int n = snprintf(msg, sizeof(msg), "[launcher] Không tìm thấy proot binary tại '%s': %s (errno=%d)",
                          proot, strerror(errno), errno);
        emit_log(&ctx, "[launcher]", msg, (size_t)n);
        return -1;
    } else if (!(st.st_mode & S_IXUSR)) {
        char msg[512];
        int n = snprintf(msg, sizeof(msg), "[launcher] '%s' tồn tại nhưng thiếu quyền execute (mode=%o)",
                          proot, st.st_mode & 0777);
        emit_log(&ctx, "[launcher]", msg, (size_t)n);
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

    // Tạo PTY dùng posix_openpt
    int master_fd, slave_fd;
    struct termios term;
    struct winsize win;

    // Lấy termios từ stdin (nếu fail, dùng default)
    if (tcgetattr(STDIN_FILENO, &term) != 0) {
        cfmakeraw(&term);
        term.c_lflag |= (ECHO | ICANON | ISIG);
        term.c_oflag |= OPOST | ONLCR;
    }
    // Kích thước mặc định
    win.ws_row = 24;
    win.ws_col = 80;
    win.ws_xpixel = 0;
    win.ws_ypixel = 0;

    master_fd = posix_openpt(O_RDWR | O_NOCTTY);
    if (master_fd == -1) {
        char msg[256];
        int n = snprintf(msg, sizeof(msg), "[launcher] posix_openpt thất bại: %s", strerror(errno));
        emit_log(&ctx, "[launcher]", msg, (size_t)n);
        return -1;
    }
    if (grantpt(master_fd) == -1 || unlockpt(master_fd) == -1) {
        char msg[256];
        int n = snprintf(msg, sizeof(msg), "[launcher] grantpt/unlockpt thất bại: %s", strerror(errno));
        emit_log(&ctx, "[launcher]", msg, (size_t)n);
        close(master_fd);
        return -1;
    }
    const char* slave_name = ptsname(master_fd);
    if (slave_name == NULL) {
        char msg[128];
        snprintf(msg, sizeof(msg), "[launcher] ptsname thất bại: %s", strerror(errno));
        emit_log(&ctx, "[launcher]", msg, strlen(msg));
        close(master_fd);
        return -1;
    }
    slave_fd = open(slave_name, O_RDWR | O_NOCTTY);
    if (slave_fd == -1) {
        char msg[256];
        int n = snprintf(msg, sizeof(msg), "[launcher] mở slave '%s' thất bại: %s", slave_name, strerror(errno));
        emit_log(&ctx, "[launcher]", msg, (size_t)n);
        close(master_fd);
        return -1;
    }
    tcsetattr(slave_fd, TCSANOW, &term);
    ioctl(slave_fd, TIOCSWINSZ, &win);

    g_master_fd = master_fd;

    pid_t pid = fork();
    if (pid == 0) {
        close(master_fd);
        setsid();
        ioctl(slave_fd, TIOCSCTTY, 0);
        dup2(slave_fd, STDIN_FILENO);
        dup2(slave_fd, STDOUT_FILENO);
        dup2(slave_fd, STDERR_FILENO);
        close(slave_fd);
        execve(proot, argv, envp);
        fprintf(stderr, "[launcher] execve('%s') thất bại: %s (errno=%d)\n",
                proot, strerror(errno), errno);
        fflush(stderr);
        _exit(127);
    } else if (pid < 0) {
        char msg[256];
        int n = snprintf(msg, sizeof(msg), "[launcher] fork() thất bại: %s (errno=%d)", strerror(errno), errno);
        emit_log(&ctx, "[launcher]", msg, (size_t)n);
        close(master_fd);
        close(slave_fd);
        return -1;
    }

    g_child_pid = pid;
    close(slave_fd);
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
            char msg[256];
            int n = snprintf(msg, sizeof(msg), "[launcher] waitpid() lỗi: %s (errno=%d)", strerror(errno), errno);
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
            const char *m = "exit code 127 = execve() that bai (xem dong '[launcher] execve(...) that bai' phia tren de biet ly do chinh xac)";
            emit_log(&ctx, "[launcher]", m, strlen(m));
        }
    } else if (WIFSIGNALED(status)) {
        char msg[128];
        int n = snprintf(msg, sizeof(msg), "[launcher] proot bị kill bởi signal %d (%s)",
                          WTERMSIG(status), strsignal(WTERMSIG(status)));
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
        LOGE("writeToPty: g_master_fd is -1");
        return -1;
    }
    jsize len = (*env)->GetArrayLength(env, data);
    jbyte *bytes = (*env)->GetByteArrayElements(env, data, NULL);
    if (bytes == NULL) {
        LOGE("writeToPty: bytes == NULL");
        return -1;
    }
    ssize_t written = write(g_master_fd, bytes, len);
    if (written < 0) {
        LOGE("writeToPty: write failed: %s (errno=%d)", strerror(errno), errno);
    }
    (*env)->ReleaseByteArrayElements(env, data, bytes, JNI_ABORT);
    return (jint)written;
}

JNIEXPORT void JNICALL
Java_com_example_alpinerunner_ProotLauncher_killProot(JNIEnv *env, jobject thiz) {
    if (g_child_pid > 0) {
        kill(g_child_pid, SIGTERM);
        // Chờ một chút để child kịp exit (không block lâu)
        usleep(100000);
        // Nếu vẫn còn, kill mạnh
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
    struct winsize win;
    win.ws_row = (unsigned short)height;
    win.ws_col = (unsigned short)width;
    win.ws_xpixel = 0;
    win.ws_ypixel = 0;
    ioctl(g_master_fd, TIOCSWINSZ, &win);
    // Có thể gửi SIGWINCH tới child nếu cần
    if (g_child_pid > 0) {
        kill(g_child_pid, SIGWINCH);
    }
}
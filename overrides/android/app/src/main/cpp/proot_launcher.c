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

#define LOG_TAG "ProotLauncher"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__)

// BUG GỐC: bản cũ chỉ fork()+execve() rồi waitpid(), không hề redirect
// stdout/stderr của tiến trình con. Tiến trình con kế thừa fd 1/2 của
// app Android (thường là /dev/null hoặc fd đã bị Zygote đóng), nên toàn
// bộ log verbose của proot (kể cả cờ "-v 5" và lý do thật sự khiến
// proot không exec được loader: sai path, sai kiến trúc ELF, lỗi
// ptrace/seccomp...) bị mất hoàn toàn. JNI chỉ trả về mã exit code,
// không có bất kỳ dòng log nào -> đúng như triệu chứng "chỉ có exit
// code" được báo.
//
// Bản vá này: tạo 2 pipe cho stdout/stderr, dup2 vào tiến trình con,
// đọc non-blocking bằng poll() ngay trên thread gọi JNI (không cần
// AttachCurrentThread vì không tạo thread mới), và forward từng dòng
// log về phía Kotlin qua callback Java `onLog(String)` NGAY LẬP TỨC
// (không đợi proot thoát), để thấy được toàn bộ quá trình proot cố
// gắng nạp loader.

typedef struct {
    JNIEnv *env;
    jobject callback;    // đối tượng Kotlin implement interface có method onLog(String)
    jmethodID onLogMid;
} LogCtx;

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

// Đọc mọi thứ đang có trong fd (non-blocking), tách theo dòng, forward qua callback.
// buf/buflen là bộ đệm dòng dở (chưa gặp '\n') được giữ lại giữa các lần gọi.
static void drain_fd(int fd, LogCtx *ctx, const char *prefix, char *linebuf, size_t *linelen, size_t linecap) {
    char chunk[4096];
    for (;;) {
        ssize_t n = read(fd, chunk, sizeof(chunk));
        if (n <= 0) break; // EOF hoặc EAGAIN (non-blocking)
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
    ctx.onLogMid = NULL;
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
    } else if (!(st.st_mode & S_IXUSR)) {
        char msg[512];
        int n = snprintf(msg, sizeof(msg), "[launcher] '%s' tồn tại nhưng thiếu quyền execute (mode=%o)",
                          proot, st.st_mode & 0777);
        emit_log(&ctx, "[launcher]", msg, (size_t)n);
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

    // Log chi tiết argv/envp trước khi exec — hữu ích để xác nhận
    // PROOT_LOADER trỏ đúng chỗ, LD_LIBRARY_PATH có libtalloc.so v.v.
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

    int outPipe[2], errPipe[2];
    if (pipe(outPipe) != 0 || pipe(errPipe) != 0) {
        char msg[256];
        int n = snprintf(msg, sizeof(msg), "[launcher] pipe() thất bại: %s (errno=%d)", strerror(errno), errno);
        emit_log(&ctx, "[launcher]", msg, (size_t)n);
        return -1;
    }

    pid_t pid = fork();
    if (pid == 0) {
        // ---- Tiến trình con ----
        dup2(outPipe[1], STDOUT_FILENO);
        dup2(errPipe[1], STDERR_FILENO);
        close(outPipe[0]); close(outPipe[1]);
        close(errPipe[0]); close(errPipe[1]);

        execve(proot, argv, envp);

        // Chỉ tới đây khi execve() thất bại - đây chính là điểm quan
        // trọng nhất để chẩn đoán "proot không dùng được loader": nếu
        // proot binary tự nó exec được nhưng loader thì không, lỗi sẽ
        // không xuất hiện ở đây mà xuất hiện trong stderr của proot ở
        // trên (loader là proot tự fork/exec bên trong process của nó).
        // Nếu lỗi xuất hiện Ở ĐÂY nghĩa là chính proot binary (không
        // phải loader) mới là thứ không exec được (permission, ELF sai
        // kiến trúc, ENOENT do path sai...).
        fprintf(stderr, "[launcher] execve('%s') thất bại: %s (errno=%d)\n",
                proot, strerror(errno), errno);
        fflush(stderr);
        _exit(127);
    } else if (pid < 0) {
        char msg[256];
        int n = snprintf(msg, sizeof(msg), "[launcher] fork() thất bại: %s (errno=%d)", strerror(errno), errno);
        emit_log(&ctx, "[launcher]", msg, (size_t)n);
        close(outPipe[0]); close(outPipe[1]);
        close(errPipe[0]); close(errPipe[1]);
        return -1;
    }

    // ---- Tiến trình cha ----
    close(outPipe[1]);
    close(errPipe[1]);
    fcntl(outPipe[0], F_SETFL, O_NONBLOCK);
    fcntl(errPipe[0], F_SETFL, O_NONBLOCK);

    char outLine[4096]; size_t outLen = 0;
    char errLine[4096]; size_t errLen = 0;

    int status = 0;
    int childExited = 0;
    int exitCode = -1;

    while (!childExited) {
        struct pollfd fds[2] = {
            { outPipe[0], POLLIN, 0 },
            { errPipe[0], POLLIN, 0 },
        };
        poll(fds, 2, 100); // 100ms: vừa đọc log gần real-time vừa không busy-loop

        drain_fd(outPipe[0], &ctx, "[proot:stdout]", outLine, &outLen, sizeof(outLine));
        drain_fd(errPipe[0], &ctx, "[proot:stderr]", errLine, &errLen, sizeof(errLine));

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

    // Đọc nốt phần dữ liệu còn lại sau khi tiến trình con đã thoát
    // (tránh mất vài dòng log cuối do timing của poll()).
    drain_fd(outPipe[0], &ctx, "[proot:stdout]", outLine, &outLen, sizeof(outLine));
    drain_fd(errPipe[0], &ctx, "[proot:stderr]", errLine, &errLen, sizeof(errLine));
    if (outLen > 0) emit_log(&ctx, "[proot:stdout]", outLine, outLen);
    if (errLen > 0) emit_log(&ctx, "[proot:stderr]", errLine, errLen);

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

    close(outPipe[0]);
    close(errPipe[0]);

    free((void *)proot);
    for (int i = 0; i < argc + 1; i++) free(argv[i]);
    free(argv);
    for (int i = 0; i < envc; i++) free(envp[i]);
    free(envp);

    return exitCode;
}
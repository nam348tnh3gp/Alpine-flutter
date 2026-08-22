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
#include <pthread.h>

#define LOG_TAG "ProotLauncher"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__)

#define MAX_SESSIONS 16

typedef struct {
    int master_fd;
    pid_t child_pid;
    char session_id[64];
    int ref_count;        // tăng khi dùng, giảm khi xong
    pthread_mutex_t mutex; // mutex riêng cho từng session
} Session;

typedef struct {
    JNIEnv *env;
    jobject callback;
    jmethodID onLogMid;
    const char *session_id;
} LogCtx;

static Session g_sessions[MAX_SESSIONS];
static int g_session_count = 0;
static pthread_mutex_t g_session_mutex = PTHREAD_MUTEX_INITIALIZER;

// --- Quản lý session với ref-count ---
static Session* find_session_locked(const char *session_id, int *out_master_fd, pid_t *out_child_pid) {
    pthread_mutex_lock(&g_session_mutex);
    for (int i = 0; i < g_session_count; i++) {
        if (strcmp(g_sessions[i].session_id, session_id) == 0) {
            pthread_mutex_lock(&g_sessions[i].mutex);
            g_sessions[i].ref_count++;
            if (out_master_fd) *out_master_fd = g_sessions[i].master_fd;
            if (out_child_pid) *out_child_pid = g_sessions[i].child_pid;
            pthread_mutex_unlock(&g_sessions[i].mutex);
            pthread_mutex_unlock(&g_session_mutex);
            return &g_sessions[i];
        }
    }
    pthread_mutex_unlock(&g_session_mutex);
    return NULL;
}

static void release_session(Session *s) {
    if (!s) return;
    pthread_mutex_lock(&s->mutex);
    s->ref_count--;
    int should_close = (s->ref_count <= 0 && s->master_fd >= 0);
    pthread_mutex_unlock(&s->mutex);
    if (should_close) {
        close(s->master_fd);
        s->master_fd = -1;
        // Xóa khỏi danh sách
        pthread_mutex_lock(&g_session_mutex);
        for (int i = 0; i < g_session_count; i++) {
            if (strcmp(g_sessions[i].session_id, s->session_id) == 0) {
                for (int j = i; j < g_session_count - 1; j++) {
                    g_sessions[j] = g_sessions[j + 1];
                }
                g_session_count--;
                break;
            }
        }
        pthread_mutex_unlock(&g_session_mutex);
    }
}

static int add_session(const char *session_id, int master_fd, pid_t child_pid) {
    pthread_mutex_lock(&g_session_mutex);
    if (g_session_count >= MAX_SESSIONS) {
        pthread_mutex_unlock(&g_session_mutex);
        return -1;
    }
    Session *s = &g_sessions[g_session_count++];
    s->master_fd = master_fd;
    s->child_pid = child_pid;
    s->ref_count = 1; // runProot giữ 1 reference
    pthread_mutex_init(&s->mutex, NULL);
    strncpy(s->session_id, session_id, sizeof(s->session_id) - 1);
    s->session_id[sizeof(s->session_id) - 1] = '\0';
    pthread_mutex_unlock(&g_session_mutex);
    return 0;
}

// --- Logging (giữ nguyên, chỉ sửa nhỏ để an toàn UTF-8) ---
static void emit_log(LogCtx *ctx, const char *prefix, const char *line, size_t len) {
    if (ctx->callback == NULL || ctx->onLogMid == NULL) {
        LOGD("%s%s%.*s", ctx->session_id ? ctx->session_id : "", prefix, (int)len, line);
        return;
    }
    char buf[4200];
    int n = snprintf(buf, sizeof(buf), "[%s]%s%.*s",
                     ctx->session_id ? ctx->session_id : "",
                     prefix, (int)len, line);
    if (n < 0) return;
    jstring jline = (*ctx->env)->NewStringUTF(ctx->env, buf);
    if (jline == NULL) return;
    (*ctx->env)->CallVoidMethod(ctx->env, ctx->callback, ctx->onLogMid, jline);
    if ((*ctx->env)->ExceptionCheck(ctx->env)) {
        (*ctx->env)->ExceptionClear(ctx->env);
    }
    (*ctx->env)->DeleteLocalRef(ctx->env, jline);
}

// ========== CÁC HÀM JNI VỚI TÊN ĐÚNG PACKAGE ==========
// Package thực tế: com.TGFN.alpinerunner

JNIEXPORT jint JNICALL
Java_com_TGFN_alpinerunner_ProotLauncher_runProot(  // ← sửa package
    JNIEnv *env,
    jobject thiz,
    jstring prootPath,
    jobjectArray argsArray,
    jobjectArray envArray,
    jobject logCallback,
    jint rows,
    jint cols,
    jstring sessionId) {

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

    const char *session_id = (*env)->GetStringUTFChars(env, sessionId, NULL);
    if (session_id == NULL) {
        const char *m = "GetStringUTFChars(sessionId) thất bại";
        emit_log(&ctx, "[launcher]", m, strlen(m));
        return -1;
    }
    ctx.session_id = session_id;

    const char *proot = (*env)->GetStringUTFChars(env, prootPath, NULL);
    if (proot == NULL) {
        const char *m = "GetStringUTFChars(prootPath) thất bại";
        emit_log(&ctx, "[launcher]", m, strlen(m));
        (*env)->ReleaseStringUTFChars(env, sessionId, session_id);
        return -1;
    }

    struct stat st;
    if (stat(proot, &st) != 0) {
        char msg[512];
        int n = snprintf(msg, sizeof(msg), "[launcher] Không tìm thấy proot binary tại '%s': %s", proot, strerror(errno));
        emit_log(&ctx, "[launcher]", msg, (size_t)n);
        (*env)->ReleaseStringUTFChars(env, prootPath, proot);
        (*env)->ReleaseStringUTFChars(env, sessionId, session_id);
        return -1;
    } else if (!(st.st_mode & S_IXUSR)) {
        char msg[512];
        int n = snprintf(msg, sizeof(msg), "[launcher] '%s' thiếu quyền execute", proot);
        emit_log(&ctx, "[launcher]", msg, (size_t)n);
        (*env)->ReleaseStringUTFChars(env, prootPath, proot);
        (*env)->ReleaseStringUTFChars(env, sessionId, session_id);
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

    // --- Tạo PTY ---
    int master_fd = open("/dev/ptmx", O_RDWR | O_CLOEXEC);
    if (master_fd < 0) {
        char msg[256];
        int n = snprintf(msg, sizeof(msg), "[launcher] open(/dev/ptmx) thất bại: %s", strerror(errno));
        emit_log(&ctx, "[launcher]", msg, (size_t)n);
        (*env)->ReleaseStringUTFChars(env, prootPath, proot);
        (*env)->ReleaseStringUTFChars(env, sessionId, session_id);
        return -1;
    }

    char devname[64];
    if (grantpt(master_fd) || unlockpt(master_fd) ||
        ptsname_r(master_fd, devname, sizeof(devname)) != 0) {
        char msg[256];
        int n = snprintf(msg, sizeof(msg), "[launcher] grantpt/unlockpt/ptsname_r thất bại");
        emit_log(&ctx, "[launcher]", msg, (size_t)n);
        close(master_fd);
        (*env)->ReleaseStringUTFChars(env, prootPath, proot);
        (*env)->ReleaseStringUTFChars(env, sessionId, session_id);
        return -1;
    }

    // Đặt kích thước PTY
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

        struct termios tios;
        if (tcgetattr(slave_fd, &tios) == 0) {
            tios.c_iflag |= IUTF8;
            tios.c_iflag &= ~(IXON | IXOFF);
            tios.c_lflag |= (ECHO | ICANON | ISIG | IEXTEN);
            tios.c_oflag |= (OPOST | ONLCR);
            tios.c_iflag |= (ICRNL | IXON);
            tios.c_cc[VERASE] = 127;
            tios.c_cc[VINTR] = 3;
            tios.c_cc[VQUIT] = 28;
            tios.c_cc[VSUSP] = 26;
            tcsetattr(slave_fd, TCSANOW, &tios);
        }

        dup2(slave_fd, 0);
        dup2(slave_fd, 1);
        dup2(slave_fd, 2);

        DIR *self_dir = opendir("/proc/self/fd");
        if (self_dir != NULL) {
            int self_dir_fd = dirfd(self_dir);
            struct dirent *entry;
            while ((entry = readdir(self_dir)) != NULL) {
                int fd = atoi(entry->d_name);
                if (fd > 2 && fd != self_dir_fd && fd != slave_fd) {
                    close(fd);
                }
            }
            closedir(self_dir);
        }

        clearenv();
        if (envp) {
            for (char **p = envp; *p; ++p) putenv(*p);
        }

        if (chdir("/") != 0) {
            perror("chdir");
        }

        execvp(proot, argv);
        perror("execvp");
        _exit(127);
    } else if (pid < 0) {
        char msg[128];
        int n = snprintf(msg, sizeof(msg), "[launcher] fork thất bại: %s", strerror(errno));
        emit_log(&ctx, "[launcher]", msg, (size_t)n);
        close(master_fd);
        (*env)->ReleaseStringUTFChars(env, prootPath, proot);
        (*env)->ReleaseStringUTFChars(env, sessionId, session_id);
        return -1;
    }

    // Lưu session
    if (add_session(session_id, master_fd, pid) != 0) {
        char msg[128];
        int n = snprintf(msg, sizeof(msg), "[launcher] quá nhiều session");
        emit_log(&ctx, "[launcher]", msg, (size_t)n);
        kill(pid, SIGKILL);
        close(master_fd);
        (*env)->ReleaseStringUTFChars(env, prootPath, proot);
        (*env)->ReleaseStringUTFChars(env, sessionId, session_id);
        return -1;
    }

    fcntl(master_fd, F_SETFL, O_NONBLOCK);

    // --- Vòng lặp đọc PTY với bộ đệm UTF-8 an toàn ---
    int status = 0;
    int childExited = 0;
    int exitCode = -1;
    char utf8_buf[4096];
    size_t utf8_len = 0;

    while (!childExited) {
        struct pollfd fds[1] = { { master_fd, POLLIN, 0 } };
        poll(fds, 1, 100);

        char chunk[4096];
        ssize_t n;
        while ((n = read(master_fd, chunk, sizeof(chunk))) > 0) {
            // Nối vào bộ đệm
            if (utf8_len + n < sizeof(utf8_buf)) {
                memcpy(utf8_buf + utf8_len, chunk, n);
                utf8_len += n;
            } else {
                // Tràn bộ đệm – gửi những gì có thể (không xảy ra trong thực tế)
                emit_log(&ctx, "[pty]", utf8_buf, utf8_len);
                utf8_len = 0;
                memcpy(utf8_buf, chunk, n);
                utf8_len = n;
            }
            // Kiểm tra xem có ký tự UTF-8 hợp lệ hoàn chỉnh ở cuối không
            // Cách đơn giản: tìm vị trí ký tự không hợp lệ bằng cách kiểm tra byte đầu
            // Ở đây, để đơn giản, ta chỉ gửi toàn bộ nếu kết thúc bằng newline hoặc NULL
            // Thực tế, ta có thể gửi ngay sau mỗi lần đọc nhưng phải xử lý cắt giữa chừng:
            // Bằng cách không chia nhỏ nếu byte cuối là byte tiếp tục UTF-8.
            // Tôi dùng cách: lùi lại cho đến khi byte cuối không phải là 0x80-0xBF
            // Nếu tất cả đều là tiếp tục, đợi lần đọc sau.
            if (utf8_len > 0) {
                unsigned char last = utf8_buf[utf8_len - 1];
                if ((last & 0xC0) != 0x80) { // không phải byte tiếp tục
                    // Gửi toàn bộ
                    emit_log(&ctx, "[pty]", utf8_buf, utf8_len);
                    utf8_len = 0;
                }
                // Nếu là byte tiếp tục, giữ lại chờ thêm dữ liệu
            }
        }
        if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
            char msg[128];
            int len = snprintf(msg, sizeof(msg), "[launcher] read lỗi: %s", strerror(errno));
            emit_log(&ctx, "[launcher]", msg, (size_t)len);
        }

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

    // Đọc nốt dữ liệu còn lại
    char chunk[4096];
    ssize_t n;
    while ((n = read(master_fd, chunk, sizeof(chunk))) > 0) {
        // Gửi trực tiếp (không quan trọng UTF-8 vì đã kết thúc)
        emit_log(&ctx, "[pty]", chunk, (size_t)n);
    }
    if (utf8_len > 0) {
        emit_log(&ctx, "[pty]", utf8_buf, utf8_len);
    }

    // Đóng và giải phóng session
    // Tìm session, giảm ref
    Session *s = NULL;
    pthread_mutex_lock(&g_session_mutex);
    for (int i = 0; i < g_session_count; i++) {
        if (strcmp(g_sessions[i].session_id, session_id) == 0) {
            s = &g_sessions[i];
            break;
        }
    }
    if (s) {
        pthread_mutex_lock(&s->mutex);
        s->ref_count--;
        int should_close = (s->ref_count <= 0 && s->master_fd >= 0);
        pthread_mutex_unlock(&s->mutex);
        if (should_close) {
            close(s->master_fd);
            s->master_fd = -1;
            // Xóa khỏi danh sách
            for (int i = 0; i < g_session_count; i++) {
                if (strcmp(g_sessions[i].session_id, session_id) == 0) {
                    for (int j = i; j < g_session_count - 1; j++) {
                        g_sessions[j] = g_sessions[j + 1];
                    }
                    g_session_count--;
                    break;
                }
            }
        }
    }
    pthread_mutex_unlock(&g_session_mutex);

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

    // Giải phóng bộ nhớ đúng cách
    (*env)->ReleaseStringUTFChars(env, prootPath, proot);  // ← sửa
    for (int i = 0; i < argc + 1; i++) free(argv[i]);
    free(argv);
    for (int i = 0; i < envc; i++) free(envp[i]);
    free(envp);

    (*env)->ReleaseStringUTFChars(env, sessionId, session_id);

    return exitCode;
}

// Các hàm JNI còn lại với tên đúng package
JNIEXPORT jint JNICALL
Java_com_TGFN_alpinerunner_ProotLauncher_writeToPty(  // ← sửa
    JNIEnv *env,
    jobject thiz,
    jbyteArray data,
    jstring sessionId) {
    const char *session_id = (*env)->GetStringUTFChars(env, sessionId, NULL);
    if (session_id == NULL) return -1;

    int master_fd = -1;
    Session *s = find_session_locked(session_id, &master_fd, NULL);
    if (!s) {
        LOGE("writeToPty: không tìm thấy session %s", session_id);
        (*env)->ReleaseStringUTFChars(env, sessionId, session_id);
        return -1;
    }

    jsize len = (*env)->GetArrayLength(env, data);
    jbyte *bytes = (*env)->GetByteArrayElements(env, data, NULL);
    if (bytes == NULL) {
        release_session(s);
        (*env)->ReleaseStringUTFChars(env, sessionId, session_id);
        return -1;
    }
    ssize_t written = write(master_fd, bytes, len);
    if (written < 0) {
        LOGE("writeToPty: write thất bại: %s", strerror(errno));
    }
    (*env)->ReleaseByteArrayElements(env, data, bytes, JNI_ABORT);
    release_session(s);
    (*env)->ReleaseStringUTFChars(env, sessionId, session_id);
    return (jint)written;
}

JNIEXPORT void JNICALL
Java_com_TGFN_alpinerunner_ProotLauncher_killProot(  // ← sửa
    JNIEnv *env,
    jobject thiz,
    jstring sessionId) {
    const char *session_id = (*env)->GetStringUTFChars(env, sessionId, NULL);
    if (session_id == NULL) return;

    pid_t child_pid = -1;
    Session *s = find_session_locked(session_id, NULL, &child_pid);
    if (s) {
        if (child_pid > 0) {
            kill(child_pid, SIGTERM);
            usleep(100000);
            if (kill(child_pid, 0) == 0) {
                kill(child_pid, SIGKILL);
            }
        }
        release_session(s);
    }
    (*env)->ReleaseStringUTFChars(env, sessionId, session_id);
}

JNIEXPORT void JNICALL
Java_com_TGFN_alpinerunner_ProotLauncher_resizePty(  // ← sửa
    JNIEnv *env,
    jobject thiz,
    jint width,
    jint height,
    jstring sessionId) {
    const char *session_id = (*env)->GetStringUTFChars(env, sessionId, NULL);
    if (session_id == NULL) return;

    int master_fd = -1;
    pid_t child_pid = -1;
    Session *s = find_session_locked(session_id, &master_fd, &child_pid);
    if (!s) {
        (*env)->ReleaseStringUTFChars(env, sessionId, session_id);
        return;
    }

    if (width <= 0) width = 80;
    if (height <= 0) height = 24;
    struct winsize sz = {
        .ws_row = (unsigned short) height,
        .ws_col = (unsigned short) width,
        .ws_xpixel = (unsigned short) (width * 8),
        .ws_ypixel = (unsigned short) (height * 16)
    };
    ioctl(master_fd, TIOCSWINSZ, &sz);
    if (child_pid > 0) {
        kill(child_pid, SIGWINCH);
    }
    release_session(s);
    (*env)->ReleaseStringUTFChars(env, sessionId, session_id);
}
#include <jni.h>
#include <unistd.h>
#include <sys/wait.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>

JNIEXPORT jint JNICALL
Java_com_example_alpinerunner_ProotLauncher_runProot(
    JNIEnv *env,
    jobject thiz,
    jstring prootPath,
    jobjectArray argsArray,
    jobjectArray envArray) {

    const char *proot = (*env)->GetStringUTFChars(env, prootPath, NULL);
    if (proot == NULL) return -1;

    int argc = (*env)->GetArrayLength(env, argsArray);
    char **argv = malloc((argc + 2) * sizeof(char *));
    argv[0] = strdup(proot);
    for (int i = 0; i < argc; i++) {
        jstring arg = (jstring)(*env)->GetObjectArrayElement(env, argsArray, i);
        const char *argStr = (*env)->GetStringUTFChars(env, arg, NULL);
        argv[i + 1] = strdup(argStr);
        (*env)->ReleaseStringUTFChars(env, arg, argStr);
    }
    argv[argc + 1] = NULL;

    int envc = (*env)->GetArrayLength(env, envArray);
    char **envp = malloc((envc + 1) * sizeof(char *));
    for (int i = 0; i < envc; i++) {
        jstring envStr = (jstring)(*env)->GetObjectArrayElement(env, envArray, i);
        const char *envStrC = (*env)->GetStringUTFChars(env, envStr, NULL);
        envp[i] = strdup(envStrC);
        (*env)->ReleaseStringUTFChars(env, envStr, envStrC);
    }
    envp[envc] = NULL;

    pid_t pid = fork();
    if (pid == 0) {
        execve(proot, argv, envp);
        perror("execve");
        _exit(127);
    } else if (pid < 0) {
        perror("fork");
        return -1;
    } else {
        int status;
        waitpid(pid, &status, 0);
        int exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        free((void*)proot);
        for (int i = 0; i < argc + 1; i++) free(argv[i]);
        free(argv);
        for (int i = 0; i < envc; i++) free(envp[i]);
        free(envp);
        return exitCode;
    }
}
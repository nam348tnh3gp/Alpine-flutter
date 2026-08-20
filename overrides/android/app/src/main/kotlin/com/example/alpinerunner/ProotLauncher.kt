package com.example.alpinerunner

import android.content.Context

/**
 * Callback được gọi từ native (JNI) mỗi khi có một dòng log mới từ
 * proot (stdout/stderr) hoặc từ launcher (chẩn đoán execve/fork/pipe).
 * Được gọi TRÊN THREAD ĐANG CHẠY runProot() (không phải main thread),
 * nên phía Kotlin nhận callback này phải tự post về main thread nếu
 * cần cập nhật UI hoặc gọi MethodChannel/EventChannel.
 */
fun interface ProotLogCallback {
    fun onLog(line: String)
}

class ProotLauncher {
    companion object {
        init {
            System.loadLibrary("proot_launcher")
        }

        @JvmStatic
        external fun runProot(
            prootPath: String,
            args: Array<String>,
            env: Array<String>,
            logCallback: ProotLogCallback?
        ): Int

        fun launch(
            context: Context,
            prootBin: String,
            args: List<String>,
            envVars: Map<String, String>,
            onLog: ProotLogCallback? = null
        ): Int {
            val envArray = envVars.map { "${it.key}=${it.value}" }.toTypedArray()
            return runProot(prootBin, args.toTypedArray(), envArray, onLog)
        }
    }
}
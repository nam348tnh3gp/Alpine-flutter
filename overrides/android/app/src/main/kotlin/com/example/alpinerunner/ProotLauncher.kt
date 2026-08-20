package com.example.alpinerunner

import android.content.Context

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

        @JvmStatic
        external fun writeToPty(data: ByteArray): Int

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
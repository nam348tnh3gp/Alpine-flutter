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
            logCallback: ProotLogCallback?,
            rows: Int,
            cols: Int
        ): Int

        @JvmStatic
        external fun writeToPty(data: ByteArray): Int

        @JvmStatic
        external fun killProot()

        @JvmStatic
        external fun resizePty(width: Int, height: Int)

        fun launch(
            context: Context,
            prootBin: String,
            args: List<String>,
            envVars: Map<String, String>,
            rows: Int = 24,
            cols: Int = 80,
            onLog: ProotLogCallback? = null
        ): Int {
            val envArray = envVars.map { "${it.key}=${it.value}" }.toTypedArray()
            return runProot(prootBin, args.toTypedArray(), envArray, onLog, rows, cols)
        }
    }
}
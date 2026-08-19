package com.example.alpinerunner

import android.content.Context

class ProotLauncher {
    companion object {
        init {
            System.loadLibrary("proot_launcher")
        }

        @JvmStatic
        external fun runProot(prootPath: String, args: Array<String>, env: Array<String>): Int

        fun launch(
            context: Context,
            prootBin: String,
            args: List<String>,
            envVars: Map<String, String>
        ): Int {
            val envArray = envVars.map { "${it.key}=${it.value}" }.toTypedArray()
            return runProot(prootBin, args.toTypedArray(), envArray)
        }
    }
}
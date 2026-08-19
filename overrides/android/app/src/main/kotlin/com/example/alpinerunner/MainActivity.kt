package com.example.alpinerunner

import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val NATIVE_CHANNEL = "alpine_runner/native"
    private val PROOT_CHANNEL = "alpine_runner/proot"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // NativeBridge channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NATIVE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getNativeLibraryDir" -> result.success(applicationInfo.nativeLibraryDir)
                    "getFilesDir" -> result.success(filesDir.absolutePath)
                    "getAbi" -> result.success(Build.SUPPORTED_ABIS.firstOrNull() ?: "arm64-v8a")
                    else -> result.notImplemented()
                }
            }

        // JNI proot launcher channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PROOT_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "runProot") {
                    try {
                        val prootPath = call.argument<String>("prootPath")!!
                        val args = call.argument<List<String>>("args")!!
                        val env = call.argument<Map<String, String>>("env")!!
                        val exitCode = ProotLauncher.launch(this, prootPath, args, env)
                        result.success(exitCode)
                    } catch (e: Exception) {
                        result.error("JNI_ERROR", e.message, e.stackTrace)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }
}
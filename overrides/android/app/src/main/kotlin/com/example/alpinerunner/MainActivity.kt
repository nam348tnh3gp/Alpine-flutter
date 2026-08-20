package com.example.alpinerunner

import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val NATIVE_CHANNEL = "alpine_runner/native"
    private val PROOT_CHANNEL = "alpine_runner/proot"
    private val PROOT_LOG_CHANNEL = "alpine_runner/proot_logs"

    private val mainHandler = Handler(Looper.getMainLooper())
    // Dùng 2 executor riêng để writeToPty không bị block bởi runProot
    private val prootExecutor = Executors.newSingleThreadExecutor()
    private val ptyExecutor = Executors.newSingleThreadExecutor()

    private var logSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NATIVE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getNativeLibraryDir" -> result.success(applicationInfo.nativeLibraryDir)
                    "getFilesDir" -> result.success(filesDir.absolutePath)
                    "getAbi" -> result.success(Build.SUPPORTED_ABIS.firstOrNull() ?: "arm64-v8a")
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, PROOT_LOG_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    logSink = events
                }
                override fun onCancel(arguments: Any?) {
                    logSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PROOT_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "runProot" -> {
                        val prootPath = call.argument<String>("prootPath")
                        val args = call.argument<List<String>>("args")
                        val env = call.argument<Map<String, String>>("env")
                        if (prootPath == null || args == null || env == null) {
                            result.error("BAD_ARGS", "Thiếu prootPath/args/env", null)
                            return@setMethodCallHandler
                        }
                        prootExecutor.execute {
                            try {
                                val exitCode = ProotLauncher.launch(
                                    this,
                                    prootPath,
                                    args,
                                    env
                                ) { line ->
                                    mainHandler.post { logSink?.success(line) }
                                }
                                mainHandler.post { result.success(exitCode) }
                            } catch (e: Exception) {
                                mainHandler.post {
                                    result.error("JNI_ERROR", e.message, e.stackTraceToString())
                                }
                            }
                        }
                    }
                    "writeToPty" -> {
                        val data = call.argument<ByteArray>("data")
                        if (data == null) {
                            result.error("BAD_ARGS", "Missing data", null)
                            return@setMethodCallHandler
                        }
                        ptyExecutor.execute {
                            val written = ProotLauncher.writeToPty(data)
                            mainHandler.post { result.success(written) }
                        }
                    }
                    "killProot" -> {
                        ptyExecutor.execute {
                            ProotLauncher.killProot()
                            mainHandler.post { result.success(null) }
                        }
                    }
                    "resizePty" -> {
                        val width = call.argument<Int>("width") ?: 80
                        val height = call.argument<Int>("height") ?: 24
                        ptyExecutor.execute {
                            ProotLauncher.resizePty(width, height)
                            mainHandler.post { result.success(null) }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
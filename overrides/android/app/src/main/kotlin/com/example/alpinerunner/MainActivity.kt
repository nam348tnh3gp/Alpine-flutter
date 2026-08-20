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
    // runProot() ở native block cho tới khi proot thoát (waitpid) - KHÔNG
    // được chạy trên main thread hoặc UI sẽ bị treo / ANR trong lúc chạy.
    private val prootExecutor = Executors.newSingleThreadExecutor()

    private var logSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // NativeBridge
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NATIVE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getNativeLibraryDir" -> result.success(applicationInfo.nativeLibraryDir)
                    "getFilesDir" -> result.success(filesDir.absolutePath)
                    "getAbi" -> result.success(Build.SUPPORTED_ABIS.firstOrNull() ?: "arm64-v8a")
                    else -> result.notImplemented()
                }
            }

        // Stream log chi tiết từ proot (stdout/stderr) + launcher (execve/fork/pipe)
        // về Dart theo thời gian thực, thay vì chỉ trả exit code khi kết thúc.
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, PROOT_LOG_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    logSink = events
                }

                override fun onCancel(arguments: Any?) {
                    logSink = null
                }
            })

        // JNI proot
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PROOT_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "runProot") {
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
                                // onLog() được gọi từ native thread (không phải main) -> post về main
                                // thread trước khi đụng tới EventChannel.
                                mainHandler.post { logSink?.success(line) }
                            }
                            mainHandler.post { result.success(exitCode) }
                        } catch (e: Exception) {
                            mainHandler.post {
                                result.error("JNI_ERROR", e.message, e.stackTraceToString())
                            }
                        }
                    }
                } else {
                    result.notImplemented()
                }
            }
    }
}
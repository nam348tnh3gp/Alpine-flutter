package com.TGFN.alpinerunner

import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val NATIVE_CHANNEL = "alpine_runner/native"
    private val PROOT_CHANNEL = "alpine_runner/proot"
    private val PROOT_LOG_CHANNEL = "alpine_runner/proot_logs"

    private val mainHandler = Handler(Looper.getMainLooper())
    // Dùng cached thread pool để hỗ trợ nhiều phiên chạy song song
    private val prootExecutor = Executors.newCachedThreadPool()

    // Mỗi session có ĐÚNG 1 luồng ghi PTY riêng, xử lý tuần tự theo thứ tự gửi
    // (giống cơ chế hàng đợi + 1 consumer thread của Termux) — tránh việc paste/gõ
    // nhanh bị đảo thứ tự dòng khi nhiều lệnh ghi chạy song song trên cùng 1 session.
    private val ptyWriters = ConcurrentHashMap<String, ExecutorService>()

    private fun writerFor(sessionId: String): ExecutorService {
        return ptyWriters.computeIfAbsent(sessionId) {
            Executors.newSingleThreadExecutor()
        }
    }

    private fun closeWriterFor(sessionId: String) {
        ptyWriters.remove(sessionId)?.shutdown()
    }

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
                        val rows = call.argument<Int>("rows") ?: 24
                        val cols = call.argument<Int>("cols") ?: 80
                        val sessionId = call.argument<String>("sessionId") ?: "default"
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
                                    env,
                                    rows = rows,
                                    cols = cols,
                                    sessionId = sessionId
                                ) { line ->
                                    mainHandler.post { logSink?.success(line) }
                                }
                                mainHandler.post { result.success(exitCode) }
                            } catch (e: Exception) {
                                mainHandler.post {
                                    result.error("JNI_ERROR", e.message, e.stackTraceToString())
                                }
                            } finally {
                                closeWriterFor(sessionId) // tiến trình đã thoát -> dọn luồng ghi riêng
                            }
                        }
                    }
                    "writeToPty" -> {
                        val data = call.argument<ByteArray>("data")
                        val sessionId = call.argument<String>("sessionId") ?: "default"
                        if (data == null) {
                            result.error("BAD_ARGS", "Missing data", null)
                            return@setMethodCallHandler
                        }
                        // Đẩy vào đúng luồng ghi riêng của session này -> giữ nguyên thứ tự
                        writerFor(sessionId).execute {
                            val written = ProotLauncher.writeToPty(data, sessionId)
                            mainHandler.post { result.success(written) }
                        }
                    }
                    "killProot" -> {
                        val sessionId = call.argument<String>("sessionId") ?: "default"
                        writerFor(sessionId).execute {
                            ProotLauncher.killProot(sessionId)
                            mainHandler.post { result.success(null) }
                        }
                    }
                    "resizePty" -> {
                        val width = call.argument<Int>("width") ?: 80
                        val height = call.argument<Int>("height") ?: 24
                        val sessionId = call.argument<String>("sessionId") ?: "default"
                        writerFor(sessionId).execute {
                            ProotLauncher.resizePty(width, height, sessionId)
                            mainHandler.post { result.success(null) }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
package dev.bugcapsule.bug_capsule_native

import android.content.Context
import android.os.Handler
import android.os.Looper
import dev.bugcapsule.android.embedding.CrashBridge
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * The Android side of `bug_capsule_native`: runs the BugCapsule Android
 * SDK's [CrashBridge] (NDK crashes, ANRs, exit records) and hands its events
 * to the Dart SDK, which sends them.
 */
class BugCapsuleNativePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private var context: Context? = null
    private var channel: MethodChannel? = null
    private var events: EventChannel? = null
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var sink: EventChannel.EventSink? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "dev.bugcapsule/native_crash").also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, "dev.bugcapsule/native_crash/events").also { it.setStreamHandler(this) }
        CrashBridge.setListener { json -> main.post { sink?.success(json) } }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
        CrashBridge.setListener(null)
        channel = null
        events = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val ctx = context ?: return result.error("detached", "no application context", null)
                val release = call.argument<String>("release") ?: "unknown"
                val environment = call.argument<String>("environment") ?: "production"
                val options = CrashBridge.Options(
                    nativeCrashes = true,
                    anr = call.argument<Boolean>("appHangs") ?: true,
                    anrTimeoutMs = call.argument<Number>("appHangTimeoutMs")?.toLong() ?: 5_000L,
                    exitInfo = true,
                    inAppIncludes = call.argument<List<String>>("inAppIncludes") ?: emptyList(),
                )
                // Reading tombstones and ANR dumps takes a moment: off the platform thread.
                worker.execute {
                    val reply = try {
                        CrashBridge.install(ctx, release, environment, options)
                        mapOf(
                            "lastRunCrashed" to CrashBridge.lastRunCrashed,
                            "handlerInstalled" to CrashBridge.nativeCrashHandlerInstalled,
                            "events" to CrashBridge.takePendingEvents(),
                        )
                    } catch (e: Throwable) {
                        null.also { main.post { result.error("start_failed", e.toString(), null) } }
                    }
                    if (reply != null) main.post { result.success(reply) }
                }
            }
            "updateScope" -> {
                (call.arguments as? String)?.let { CrashBridge.updateScope(it) }
                result.success(null)
            }
            "takePending" -> worker.execute {
                val pending = CrashBridge.takePendingEvents(timeoutMs = 1_000)
                main.post { result.success(pending) }
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private companion object {
        val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "BugCapsule-native").apply { isDaemon = true } }
    }
}

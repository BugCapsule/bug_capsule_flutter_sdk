package dev.bugcapsule.bug_capsule_native

import android.content.Context
import android.os.Handler
import android.os.Looper
import dev.bugcapsule.android.embedding.CrashBridge
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The Android side of `bug_capsule_native`: runs the BugCapsule Android
 * SDK's [CrashBridge] (NDK crashes, ANRs, exit records) and hands its events
 * to the Dart SDK, which sends them.
 *
 * One instance per Flutter engine; the bridge is per process. Live events go
 * to the first engine whose Dart side listens (background engines of other
 * plugins register this one too, but never listen).
 */
class BugCapsuleNativePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private var context: Context? = null
    private var channel: MethodChannel? = null
    private var events: EventChannel? = null

    @Volatile
    private var sink: EventChannel.EventSink? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "dev.bugcapsule/native_crash").also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, "dev.bugcapsule/native_crash/events").also { it.setStreamHandler(this) }
        attached.add(this)
        CrashBridge.setListener { json ->
            main.post { attached.firstOrNull { it.sink != null }?.sink?.success(json) }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
        sink = null
        attached.remove(this)
        if (attached.isEmpty()) CrashBridge.setListener(null)
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
                // Install is quick (the previous run's reports are built in the
                // background, collected later with takePending); off the platform
                // thread all the same.
                worker.execute {
                    try {
                        CrashBridge.install(ctx, release, environment, options)
                        val reply = mapOf(
                            // Once per process: another engine, a second init or a hot
                            // restart must not crash a session that is still running.
                            "lastRunCrashed" to (CrashBridge.lastRunCrashed && lastRunCrashedReported.compareAndSet(false, true)),
                            "handlerInstalled" to CrashBridge.nativeCrashHandlerInstalled,
                        )
                        main.post { result.success(reply) }
                    } catch (e: Throwable) {
                        main.post { result.error("start_failed", e.toString(), null) }
                    }
                }
            }
            "updateScope" -> {
                (call.arguments as? String)?.let { CrashBridge.updateScope(it) }
                result.success(null)
            }
            "takePending" -> worker.execute {
                val pending = try {
                    CrashBridge.takePendingEvents()
                } catch (_: Throwable) {
                    emptyList()
                }
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
        val main = Handler(Looper.getMainLooper())
        val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "BugCapsule-native").apply { isDaemon = true } }
        val attached = CopyOnWriteArrayList<BugCapsuleNativePlugin>()
        val lastRunCrashedReported = AtomicBoolean(false)
    }
}

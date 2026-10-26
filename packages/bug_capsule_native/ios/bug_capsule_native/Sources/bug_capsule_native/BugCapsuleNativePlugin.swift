import Flutter
import Foundation

#if canImport(BugCapsule)
    import BugCapsule
#endif

/// The iOS side of `bug_capsule_native`: runs the BugCapsule iOS SDK's
/// `BugCapsuleCrashBridge` (signal and Mach crashes, app hangs, MetricKit)
/// and hands its events to the Dart SDK, which sends them.
///
/// The SDK comes through Swift Package Manager. Built with CocoaPods the
/// plugin has no SDK: it answers, reports nothing and says so once.
public final class BugCapsuleNativePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var sink: FlutterEventSink?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = BugCapsuleNativePlugin()
        let channel = FlutterMethodChannel(name: "dev.bugcapsule/native_crash", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: channel)
        FlutterEventChannel(name: "dev.bugcapsule/native_crash/events", binaryMessenger: registrar.messenger())
            .setStreamHandler(instance)
        #if canImport(BugCapsule)
            BugCapsuleCrashBridge.setListener { [weak instance] json in
                DispatchQueue.main.async { instance?.sink?(json) }
            }
        #endif
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "start":
            let args = call.arguments as? [String: Any] ?? [:]
            start(args, result: result)
        case "updateScope":
            #if canImport(BugCapsule)
                if let json = call.arguments as? String { BugCapsuleCrashBridge.updateScope(json: json) }
            #endif
            result(nil)
        case "takePending":
            #if canImport(BugCapsule)
                DispatchQueue.global(qos: .utility).async {
                    let pending = BugCapsuleCrashBridge.takePendingEvents(timeoutMs: 1_000)
                    DispatchQueue.main.async { result(pending) }
                }
            #else
                result([String]())
            #endif
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func start(_ args: [String: Any], result: @escaping FlutterResult) {
        #if canImport(BugCapsule)
            let hangs = args["appHangs"] as? Bool ?? true
            let timeoutMs = (args["appHangTimeoutMs"] as? NSNumber)?.doubleValue
            var includes = args["inAppIncludes"] as? [String] ?? []
            // Dart AOT code lives in App.framework; the host app's executable is Runner.
            includes += ["App", "Runner"]
            let options = BugCapsuleCrashBridge.Options(
                nativeCrashes: true,
                appHangs: hangs ? (timeoutMs.map { $0 / 1000 } ?? 2) : nil,
                metricKit: true,
                inAppIncludes: includes)
            let release = args["release"] as? String ?? "unknown"
            let environment = args["environment"] as? String ?? "production"
            // Reading the previous run's report takes a moment: off the platform thread.
            DispatchQueue.global(qos: .userInitiated).async {
                BugCapsuleCrashBridge.install(release: release, environment: environment, options: options)
                let reply: [String: Any] = [
                    "lastRunCrashed": BugCapsuleCrashBridge.lastRunCrashed,
                    "handlerInstalled": BugCapsuleCrashBridge.nativeCrashHandlerInstalled,
                    "events": BugCapsuleCrashBridge.takePendingEvents(),
                ]
                DispatchQueue.main.async { result(reply) }
            }
        #else
            NSLog(
                "[bugcapsule] bug_capsule_native: the BugCapsule iOS SDK comes through Swift Package Manager; "
                    + "this app builds plugins with CocoaPods, so native crashes are not reported on iOS. "
                    + "Run `flutter config --enable-swift-package-manager`.")
            result(["lastRunCrashed": false, "handlerInstalled": false, "events": [String]()])
        #endif
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }
}

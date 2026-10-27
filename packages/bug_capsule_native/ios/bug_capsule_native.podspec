#
# CocoaPods build of bug_capsule_native. The BugCapsule iOS SDK ships through
# Swift Package Manager only, so with CocoaPods the plugin builds without it
# and reports no native crashes on iOS (it logs why). Use Swift Package
# Manager: `flutter config --enable-swift-package-manager`.
#
Pod::Spec.new do |s|
  s.name             = 'bug_capsule_native'
  s.version          = '0.1.0'
  s.summary          = 'Native crash reporting for BugCapsule in Flutter apps.'
  s.description      = <<-DESC
Signal and Mach crashes, app hangs and MetricKit diagnostics through the BugCapsule iOS SDK (Swift Package Manager builds).
                       DESC
  s.homepage         = 'https://bugcapsule.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'BugCapsule' => 'contact@bugcapsule.com' }
  s.source           = { :path => '.' }
  s.source_files = 'bug_capsule_native/Sources/bug_capsule_native/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
  s.resource_bundles = {'bug_capsule_native_privacy' => ['bug_capsule_native/Sources/bug_capsule_native/PrivacyInfo.xcprivacy']}
end

Pod::Spec.new do |s|
  s.name             = 'bug_capsule_patch'
  s.version          = '0.1.0'
  s.summary          = 'BugCapsule patch runtime.'
  s.homepage         = 'https://bugcapsule.com'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'BugCapsule' => 'support@bugcapsule.com' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '15.0'
  s.dependency 'Flutter'
  # The prebuilt runtime ships inside the app's own IPA.
  s.vendored_frameworks = 'Frameworks/BcpatchRuntime.xcframework'
end

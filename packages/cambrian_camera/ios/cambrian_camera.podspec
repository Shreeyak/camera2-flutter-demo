Pod::Spec.new do |s|
  s.name             = 'cambrian_camera'
  s.version          = '1.2.0'
  s.summary          = 'Flutter plugin for Cambrian camera (iOS + Android).'
  s.homepage         = 'https://cambrian.ai'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'Cambrian' => 'dev@cambrian.ai' }
  s.source           = { :path => '.' }

  # Plan 1 (2026-05-18): repointed from 'Classes/**/*' (legacy pre-SPM layout)
  # to the SPM-resident sources under ios/cambrian_camera/Sources/. The plugin
  # registrar, HostApi impl, AND the Pigeon-generated Messages.g.swift all
  # live under the new SPM source tree (Pigeon swiftOut was repointed in
  # A2.6). The legacy ios/Classes/ directory is no longer used.
  s.source_files = 'cambrian_camera/Sources/cambrian_camera/**/*.swift'

  s.dependency 'Flutter'
  s.platform         = :ios, '26.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    # Match the SPM target's Swift settings — the podspec fallback compiles
    # the same source under CocoaPods. Cxx-interop is required to import
    # CameraKit's swiftmodule.
    'OTHER_SWIFT_FLAGS' => '$(inherited) -cxx-interoperability-mode=default'
  }
  s.swift_version = '5.0'
end

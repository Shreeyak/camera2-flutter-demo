Pod::Spec.new do |s|
  s.name             = 'cambrian_camera'
  s.version          = '0.1.0'
  s.summary          = 'Flutter plugin for Cambrian camera with Camera2 backend.'
  s.homepage         = 'https://cambrian.ai'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'Cambrian' => 'dev@cambrian.ai' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '12.0'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
  s.swift_version = '5.0'
end

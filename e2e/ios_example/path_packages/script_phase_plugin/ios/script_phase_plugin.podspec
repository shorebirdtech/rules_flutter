Pod::Spec.new do |s|
  s.name             = 'script_phase_plugin'
  s.version          = '0.0.1'
  s.summary          = 'An iOS plugin with a Package.swift and a podspec script phase.'
  s.homepage         = 'https://example.com'
  s.license          = { :type => 'BSD' }
  s.author           = { 'rules_flutter' => 'rules_flutter@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'script_phase_plugin/Sources/script_phase_plugin/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.script_phase     = { :name => 'Prepare', :script => 'echo prepared', :execution_position => :before_compile }
end

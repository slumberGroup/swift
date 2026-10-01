Pod::Spec.new do |s|
  s.name = 'SGStyle'
  s.version = '1.0.0'
  s.summary = 'Slumber Group Swift style rules, a format/lint runner, and the pinned SwiftFormat and SwiftLint.'
  s.description = <<-DESC
    The Slumber Group SwiftFormat and SwiftLint rules, the SwiftFormat and SwiftLint versions that run them,
    and a script that applies both to a client repo. Clients list this pod, SwiftFormat/CLI and SwiftLint
    as Debug-only pods and run SGStyle/sgstyle.rb from a build phase or CI.
  DESC
  s.homepage = 'https://github.com/slumberGroup/swift'
  s.license = { :type => 'MIT', :file => 'LICENSE.md' }
  s.authors = 'Slumber Group'
  s.source = { :git => 'https://github.com/slumberGroup/swift.git', :tag => "sgstyle-#{s.version}" }
  s.ios.deployment_target = '15.0'
  s.swift_versions = ['5.0']

  s.preserve_paths = [
    'SGStyle/sgstyle.rb',
    'Sources/AirbnbSwiftFormatTool/airbnb.swiftformat',
    'Sources/AirbnbSwiftFormatTool/swiftlint.yml'
  ]

  # These keep the tools out of Release only when the client Podfile also lists each of them
  # with `:configurations => ['Debug']`; CocoaPods adds transitive dependencies to every configuration.
  s.dependency 'SwiftFormat/CLI', '0.63.1', :configurations => ['Debug']
  s.dependency 'SwiftLint', '0.63.3', :configurations => ['Debug']
end

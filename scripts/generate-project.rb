#!/usr/bin/env ruby
# frozen_string_literal: true

require 'xcodeproj'

root = File.expand_path('..', __dir__)
project_path = File.join(root, 'WinterVoice.xcodeproj')
project = Xcodeproj::Project.new(project_path)
project.root_object.attributes['LastSwiftUpdateCheck'] = '2650'
project.root_object.attributes['LastUpgradeCheck'] = '2650'

app = project.new_target(:application, 'WinterVoice', :osx, '14.0')
tests = project.new_target(:unit_test_bundle, 'WinterVoiceTests', :osx, '14.0')
# Match the product reference (and the scheme's BuildableName derived from
# it) to PRODUCT_NAME below.
app.product_reference.path = 'MacVoice.app'

app_group = project.main_group.new_group('WinterVoice', 'WinterVoice')
Dir.glob(File.join(root, 'WinterVoice', '**', '*.swift')).sort.each do |path|
  app.add_file_references([app_group.new_file(path.delete_prefix(File.join(root, 'WinterVoice') + '/'))])
end

resources = app_group.new_group('Resources', 'Resources')
resources.new_file('Info.plist')
asset_catalog = resources.new_file('Assets.xcassets')
# Bundled UI typeface (Inter); registered via ATSApplicationFontsPath = Fonts.
fonts_folder = resources.new_file('Fonts')
fonts_folder.last_known_file_type = 'folder'
# Recording chimes; copied as a folder reference so they land in
# Contents/Resources/Sounds and load via url(forResource:subdirectory:).
sounds_folder = resources.new_file('Sounds')
sounds_folder.last_known_file_type = 'folder'
app.add_resources([asset_catalog, fonts_folder, sounds_folder])

test_group = project.main_group.new_group('WinterVoiceTests', 'WinterVoiceTests')
Dir.glob(File.join(root, 'WinterVoiceTests', '**', '*.swift')).sort.each do |path|
  tests.add_file_references([test_group.new_file(path.delete_prefix(File.join(root, 'WinterVoiceTests') + '/'))])
end

app.build_configurations.each do |config|
  # TCC pins an ad-hoc build's grants to its cdhash. If an ad-hoc build
  # (`CODE_SIGN_IDENTITY=-`, e.g. a CLI test run) shares the bundle ID, its
  # stale row shadows the Apple Development build: the System Settings toggle
  # is ON, yet AXIsProcessTrusted() stays false. `-` maps to `_` under
  # :identifier, so only ad-hoc builds pick up the `.adhoc` suffix.
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.iliagon.Dictation$(WV_BUNDLE_ID_SUFFIX_$(CODE_SIGN_IDENTITY:identifier))'
  config.build_settings['WV_BUNDLE_ID_SUFFIX__'] = '.adhoc'
  # The shipped app is MacVoice.app; the target and Swift module keep the
  # WinterVoice name so the fork stays diffable against upstream.
  config.build_settings['PRODUCT_NAME'] = 'MacVoice'
  config.build_settings['PRODUCT_MODULE_NAME'] = 'WinterVoice'
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  config.build_settings['INFOPLIST_FILE'] = 'WinterVoice/Resources/Info.plist'
  config.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
  config.build_settings['SWIFT_VERSION'] = '6.0'
  config.build_settings['SWIFT_STRICT_CONCURRENCY'] = 'complete'
  config.build_settings['CODE_SIGN_STYLE'] = 'Manual'
  config.build_settings['CODE_SIGN_IDENTITY'] = 'Apple Development'
  # Hardened Runtime blocks DYLD_INSERT_LIBRARIES-style injection into a
  # process holding Microphone, Accessibility, and Input Monitoring grants.
  config.build_settings['ENABLE_HARDENED_RUNTIME'] = 'YES'
  # A stable signing identity keeps the Microphone, Accessibility, and Input
  # Monitoring grants across rebuilds; ad-hoc signatures reset them each time.
  config.build_settings['DEVELOPMENT_TEAM'] = 'DPGLZB4Y9K'
  # Hardened Runtime denies microphone capture, without any prompt, unless
  # the signature carries the audio-input entitlement.
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'WinterVoice/Resources/WinterVoice.entitlements'
end

tests.build_configurations.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.iliagon.DictationTests'
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
  config.build_settings['SWIFT_VERSION'] = '6.0'
  config.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/MacVoice.app/Contents/MacOS/MacVoice'
  config.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
end

# Normalize the targets and project root before xcodeproj records their UUIDs as
# scalar strings inside PBXContainerItemProxy. A final pass then covers the
# dependency objects themselves.
project.sort
project.predictabilize_uuids
tests.add_dependency(app)
project.sort
project.predictabilize_uuids
project.root_object.attributes.delete('TargetAttributes')
project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_build_target(tests)
scheme.set_launch_target(app)
scheme.add_test_target(tests)
scheme.save_as(project_path, 'WinterVoice', true)

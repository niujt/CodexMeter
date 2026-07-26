#!/usr/bin/env ruby
# frozen_string_literal: true

require "xcodeproj"
require "fileutils"

root = File.expand_path("..", __dir__)
project_path = File.join(root, "CodexMeter.xcodeproj")
team_id = ENV["DEVELOPMENT_TEAM"]
FileUtils.rm_rf(project_path)
project = Xcodeproj::Project.new(project_path)

main = project.new_target(:application, "CodexMeter", :osx, "14.0")
widget = project.new_target(:app_extension, "CodexMeterWidget", :osx, "14.0")
widget.product_type = "com.apple.product-type.app-extension"

source_group = project.main_group.new_group("Sources", "Sources")
app_group = source_group.new_group("CodexMeter", "CodexMeter")
widget_group = source_group.new_group("CodexMeterWidget", "CodexMeterWidget")
resources_group = project.main_group.new_group("Resources", "Resources")

app_files = Dir.glob(File.join(root, "Sources/CodexMeter/**/*.swift")).sort
app_files.each do |path|
  relative = path.delete_prefix("#{root}/")
  reference = app_group.new_file(relative.delete_prefix("Sources/CodexMeter/"))
  main.add_file_references([reference])
end

shared_reference = app_group.files.find { |file| file.path == "Support/WidgetUsageCache.swift" }
widget_reference = widget_group.new_file("CodexMeterWidget.swift")
widget.add_file_references([widget_reference, shared_reference])

info = resources_group.new_file("Info.plist")
widget_info = resources_group.new_file("WidgetInfo.plist")
entitlements = resources_group.new_file("CodexMeter.entitlements")
widget_entitlements = resources_group.new_file("CodexMeterWidget.entitlements")
assets = resources_group.new_file("Assets.xcassets")
main.add_resources([assets])
[info, widget_info, entitlements, widget_entitlements].each { |reference| reference.include_in_index = "0" }

embed = main.new_copy_files_build_phase("Embed App Extensions")
embed.dst_subfolder_spec = "13"
embed.add_file_reference(widget.product_reference, true)
embed.files.each do |file|
  file.settings = { "ATTRIBUTES" => ["CodeSignOnCopy", "RemoveHeadersOnCopy"] }
end

main.build_configurations.each do |configuration|
  configuration.build_settings.merge!(
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.codexmeter.CodexMeter",
    "INFOPLIST_FILE" => "Resources/Info.plist",
    "CODE_SIGN_ENTITLEMENTS" => "Resources/CodexMeter.entitlements",
    "CODE_SIGN_STYLE" => "Automatic",
    "SWIFT_VERSION" => "6.0",
    "MACOSX_DEPLOYMENT_TARGET" => "14.0",
    "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon",
    "CODE_SIGNING_ALLOWED" => "YES"
  )
  configuration.build_settings["DEVELOPMENT_TEAM"] = team_id if team_id && !team_id.empty?
end

widget.build_configurations.each do |configuration|
  configuration.build_settings.merge!(
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.codexmeter.CodexMeter.WidgetV4",
    "INFOPLIST_FILE" => "Resources/WidgetInfo.plist",
    "CODE_SIGN_ENTITLEMENTS" => "Resources/CodexMeterWidget.entitlements",
    "CODE_SIGN_STYLE" => "Automatic",
    "SWIFT_VERSION" => "6.0",
    "MACOSX_DEPLOYMENT_TARGET" => "14.0",
    "SKIP_INSTALL" => "YES"
  )
  configuration.build_settings["DEVELOPMENT_TEAM"] = team_id if team_id && !team_id.empty?
end

project.root_object.build_configuration_list.build_configurations.each do |configuration|
  configuration.build_settings["MACOSX_DEPLOYMENT_TARGET"] = "14.0"
end

project.recreate_user_schemes
project.save

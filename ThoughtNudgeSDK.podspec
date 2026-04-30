Pod::Spec.new do |s|
  s.name             = 'ThoughtNudgeSDK'
  s.version          = '2.2.0-beta1'
  s.summary          = 'ThoughtNudge Push Notification SDK for iOS'
  s.description      = <<-DESC
    iOS SDK for ThoughtNudge push notifications. Registers for APNs directly
    via UIApplication, sends the raw APNs token to the ThoughtNudge backend,
    and tracks delivered/clicked/read events through UNUserNotificationCenter
    forwarding. Has no Firebase dependency — your app's Crashlytics, Analytics,
    Remote Config, or Firebase Messaging usage is fully untouched.
  DESC
  s.homepage         = 'https://github.com/ThoughtnudgeDev/thoughtnudge-ios-sdk'
  s.license          = { :type => 'MIT', :text => 'Copyright (c) ThoughtNudge' }
  s.author           = { 'ThoughtNudge' => 'support@thoughtnudge.com' }
  s.source           = {
    :git => 'https://github.com/ThoughtnudgeDev/thoughtnudge-ios-sdk.git',
    :tag => s.version.to_s
  }
  s.swift_versions   = ['5.5', '5.6', '5.7', '5.8', '5.9']
  s.ios.deployment_target = '14.0'
  s.source_files     = 'Sources/ThoughtNudgeSDK/**/*.swift'
  s.frameworks       = 'UIKit', 'UserNotifications'
end

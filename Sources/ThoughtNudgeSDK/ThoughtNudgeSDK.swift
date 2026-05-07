import Foundation
import UIKit
import UserNotifications
import os.log

/// ThoughtNudge Push Notification SDK for iOS.
///
/// As of 2.2.0 the SDK no longer depends on Firebase. It registers for APNs
/// directly via `UIApplication`, sends the raw APNs device token to the
/// ThoughtNudge backend, and lets the backend dispatch notifications via
/// APNs HTTP/2. The host app's Firebase setup (Crashlytics, Analytics,
/// Remote Config, its own FCM) is now completely untouched by this SDK.
///
/// Usage:
/// ```swift
/// // 1. Initialize in AppDelegate.application(_:didFinishLaunchingWithOptions:)
/// ThoughtNudgeSDK.shared.initialize(
///     appId: "YOUR_APP_ID",
///     environment: .production
/// )
///
/// // 2. Identify user after login
/// ThoughtNudgeSDK.shared.identify(userId: "user-123")
///
/// // 3. Forward APNs token to the SDK
/// func application(_ application: UIApplication,
///                  didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
///     ThoughtNudgeSDK.shared.application(application,
///         didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
/// }
///
/// // 4. Forward notification delegate calls
/// func userNotificationCenter(_ center: UNUserNotificationCenter,
///                             willPresent notification: UNNotification,
///                             withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
///     if ThoughtNudgeSDK.shared.isThoughtNudgeNotification(notification.request) {
///         ThoughtNudgeSDK.shared.handleForegroundNotification(notification, completionHandler: completionHandler)
///         return
///     }
///     // your logic
/// }
///
/// func userNotificationCenter(_ center: UNUserNotificationCenter,
///                             didReceive response: UNNotificationResponse,
///                             withCompletionHandler completionHandler: @escaping () -> Void) {
///     if ThoughtNudgeSDK.shared.isThoughtNudgeNotification(response.notification.request) {
///         ThoughtNudgeSDK.shared.handleNotificationResponse(response, completionHandler: completionHandler)
///         return
///     }
///     // your logic
/// }
/// ```
@objc public class ThoughtNudgeSDK: NSObject {

    @objc public static let shared = ThoughtNudgeSDK()

    /// SDK version — logged on init() so you can verify in Console.app
    /// which build is actually running on the device.
    @objc public static let sdkVersion = "2.3.0-beta12"

    private static let osLog = OSLog(subsystem: "com.thoughtnudge.sdk", category: "main")

    /// Logs to BOTH the Xcode debug console (via print) AND the system log
    /// (via os_log). System log entries are visible in Console.app even
    /// when Xcode is not attached — essential for cold-launch debugging
    /// where the debugger has detached.
    private func tnLog(_ message: String) {
        print("[ThoughtNudge] \(message)")
        os_log("[ThoughtNudge] %{public}@", log: Self.osLog, type: .info, message)
    }

    /// Target ThoughtNudge environment.
    @objc public enum Environment: Int {
        case production
        case staging
        case development

        internal var url: String {
            switch self {
            case .production:  return "https://api.thoughtnudge.com"
            case .staging:     return "https://staging-api.thoughtnudge.com"
            case .development: return "https://9twvb42p-8000.inc1.devtunnels.ms"
            }
        }
    }

    internal var apiBaseUrl: String = ""
    internal var appId: String = ""
    internal var userId: String = ""

    private let userIdKey = "tn_user_id"
    private let apnsTokenKey = "tn_apns_token"
    private let messageIdKey = "tn_message_id"

    private var initialized = false
    private var pendingUserId: String?

    // Tracks the messageId we already reported as clicked from a cold-launch
    // notification, so handleNotificationResponse (which iOS may also call
    // after the app finishes launching) doesn't double-report.
    private var lastColdLaunchMessageId: String?

    /// Set this from your AppDelegate to receive deep-link URLs directly,
    /// bypassing UIApplication.shared.open. Recommended for apps with a
    /// SceneDelegate that doesn't implement scene(_:openURLContexts:), or
    /// apps where URL routing depends on a third-party SDK (Adjust, Branch,
    /// etc.) that may not be initialized yet during didFinishLaunching.
    ///
    /// Example:
    /// ```swift
    /// ThoughtNudgeSDK.shared.onDeepLink = { url, messageId in
    ///     // Route the URL using your existing deep-link router
    ///     DeepLinkRouter.shared.handle(url)
    /// }
    /// ```
    ///
    /// If unset, the SDK falls back to UIApplication.shared.open(url),
    /// which routes through scene(_:openURLContexts:) (SceneDelegate apps)
    /// or application(_:open:options:) (non-scene apps).
    public var onDeepLink: ((URL, String) -> Void)?

    private override init() {
        super.init()
    }

    // MARK: - Public API

    /// Initialize the ThoughtNudge SDK.
    /// Call once from `application(_:didFinishLaunchingWithOptions:)`.
    @available(iOSApplicationExtension, unavailable, message: "Call from your main app target only — use ThoughtNudgeNotificationService inside Notification Service Extensions")
    @objc public func initialize(appId: String, environment: Environment = .production) {
        self.apiBaseUrl = environment.url
        self.appId = appId
        self.userId = UserDefaults.standard.string(forKey: userIdKey) ?? ""
        self.initialized = true

        tnLog("SDK initialized. appId=\(appId), env=\(environment)")

        if let pending = pendingUserId {
            pendingUserId = nil
            identify(userId: pending)
        }

        if !userId.isEmpty {
            requestPermissionAndRegister()
        }
    }

    /// Associate a user with this device.
    /// If called before `initialize()`, the call is queued and replayed.
    @available(iOSApplicationExtension, unavailable, message: "Call from your main app target only")
    @objc public func identify(userId: String) {
        if !initialized {
            tnLog("identify() called before initialize() — queued")
            pendingUserId = userId
            return
        }
        self.userId = userId
        UserDefaults.standard.set(userId, forKey: userIdKey)
        tnLog("User identified: \(userId)")
        requestPermissionAndRegister()
    }

    /// Handle a notification tap that launched the app from a killed state.
    /// Call from `application(_:didFinishLaunchingWithOptions:)` with the
    /// launchOptions dictionary you receive there.
    ///
    /// When the app is killed and the user taps a notification, iOS launches
    /// the app and the notification's userInfo is delivered via
    /// `launchOptions[.remoteNotification]`. The `userNotificationCenter
    /// (_:didReceive:)` callback may also fire later, but its delivery
    /// during cold launch is unreliable in apps that mix Firebase Messaging
    /// swizzling with custom delegates. This method handles that path
    /// directly so `clicked` events fire and deep links open consistently.
    @available(iOSApplicationExtension, unavailable, message: "Call from your main app target only")
    @objc public func handleColdLaunch(launchOptions: [UIApplication.LaunchOptionsKey: Any]?) {
        let optionKeys = launchOptions?.keys.map { String(describing: $0) } ?? []
        tnLog("handleColdLaunch (AppDelegate) invoked. launchOptions keys: \(optionKeys)")

        guard let userInfo = launchOptions?[.remoteNotification] as? [AnyHashable: Any] else {
            tnLog("handleColdLaunch (AppDelegate) — launchOptions[.remoteNotification] is nil. NOTE: SceneDelegate-based apps (most iOS 13+ apps) deliver cold-launch notification info via SceneDelegate.scene(_:willConnectTo:options:), NOT via launchOptions. Add ThoughtNudgeSDK.shared.handleColdLaunch(connectionOptions:) in your SceneDelegate.")
            return
        }
        processColdLaunchUserInfo(userInfo, source: "AppDelegate")
    }

    /// Handle a cold-launch notification tap on apps that use UIScene /
    /// SceneDelegate (iOS 13+). For those apps, the notification info
    /// arrives via UIScene.ConnectionOptions, NOT via the AppDelegate's
    /// launchOptions. Call this from your SceneDelegate's
    /// `scene(_:willConnectTo:options:)`.
    ///
    /// Example:
    /// ```swift
    /// func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
    ///            options connectionOptions: UIScene.ConnectionOptions) {
    ///     ThoughtNudgeSDK.shared.handleColdLaunch(connectionOptions: connectionOptions)
    ///     // ... your existing code
    /// }
    /// ```
    @available(iOS 13.0, *)
    @available(iOSApplicationExtension, unavailable, message: "Call from your main app target only")
    @objc public func handleColdLaunch(connectionOptions: UIScene.ConnectionOptions) {
        let hasResponse = connectionOptions.notificationResponse != nil
        tnLog("handleColdLaunch (SceneDelegate) invoked. notificationResponse: \(hasResponse ? "present" : "nil")")

        guard let response = connectionOptions.notificationResponse else {
            tnLog("handleColdLaunch (SceneDelegate) — connectionOptions.notificationResponse is nil. App was NOT launched from a notification tap (user opened it some other way).")
            return
        }
        let userInfo = response.notification.request.content.userInfo
        processColdLaunchUserInfo(userInfo, source: "SceneDelegate")
    }

    @available(iOSApplicationExtension, unavailable)
    private func processColdLaunchUserInfo(_ userInfo: [AnyHashable: Any], source: String) {
        let userInfoKeys = userInfo.keys.compactMap { $0 as? String }
        tnLog("handleColdLaunch (\(source)) — userInfo keys: \(userInfoKeys)")

        guard let messageId = userInfo[messageIdKey] as? String, !messageId.isEmpty else {
            tnLog("handleColdLaunch (\(source)) — no tn_message_id in userInfo. Either the cold-launch notification wasn't a ThoughtNudge push, or the userInfo was stripped before this method ran.")
            return
        }
        tnLog("Cold-launch from notification tap (\(source)): \(messageId)")
        lastColdLaunchMessageId = messageId
        TNWebhookReporter.reportEvent(eventType: "clicked", messageId: messageId)
        openCtaUrlIfPresent(userInfo: userInfo)
    }

    /// Call on user logout to deregister the device token.
    @objc public func logout() {
        guard initialized else { return }
        if let token = UserDefaults.standard.string(forKey: apnsTokenKey) {
            TNWebhookReporter.post(
                url: "\(apiBaseUrl)/notifications/deregister-token/",
                body: ["token": token]
            )
        }
        userId = ""
        UserDefaults.standard.removeObject(forKey: userIdKey)
        UserDefaults.standard.removeObject(forKey: apnsTokenKey)
        tnLog("User logged out, token deregistered")
    }

    /// Report a custom event to ThoughtNudge backend.
    @objc public func reportEvent(eventType: String, messageId: String) {
        TNWebhookReporter.reportEvent(eventType: eventType, messageId: messageId)
    }

    /// Forward APNs device token. Call from
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    /// The token is converted to a hex string and registered with the
    /// ThoughtNudge backend.
    @objc public func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: apnsTokenKey)
        tnLog("APNs token received: \(token.prefix(20))...")
        if !userId.isEmpty {
            registerToken(token: token)
        }
    }

    /// Handle APNs registration failure.
    @objc public func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        tnLog("APNs registration failed: \(error.localizedDescription)")
    }

    // MARK: - Notification Forwarding API

    /// Returns true if the given notification originated from ThoughtNudge.
    @objc public func isThoughtNudgeNotification(_ request: UNNotificationRequest) -> Bool {
        return request.content.userInfo[messageIdKey] != nil
    }

    /// Handle a ThoughtNudge notification while the app is in FOREGROUND.
    /// Reports "delivered" and shows the notification banner.
    @objc public func handleForegroundNotification(
        _ notification: UNNotification,
        completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        if let messageId = userInfo[messageIdKey] as? String, !messageId.isEmpty {
            TNWebhookReporter.reportEvent(eventType: "delivered", messageId: messageId)
        }
        completionHandler([.banner, .sound, .badge])
    }

    /// Handle a ThoughtNudge notification response (user tapped or dismissed).
    /// Reports "clicked" on tap and opens the `cta_url` deep link if present;
    /// reports "read" on dismiss.
    @available(iOSApplicationExtension, unavailable, message: "Call from your main app target only")
    @objc public func handleNotificationResponse(
        _ response: UNNotificationResponse,
        completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let messageId = userInfo[messageIdKey] as? String, !messageId.isEmpty {
            if response.actionIdentifier == UNNotificationDismissActionIdentifier {
                TNWebhookReporter.reportEvent(eventType: "read", messageId: messageId)
            } else if messageId == lastColdLaunchMessageId {
                // Cold-launch handler already reported this clicked + opened the deep link.
                // Skip to avoid double-reporting and re-opening.
                tnLog("handleNotificationResponse — already handled \(messageId) via cold-launch, skipping")
                lastColdLaunchMessageId = nil
            } else {
                TNWebhookReporter.reportEvent(eventType: "clicked", messageId: messageId)
                openCtaUrlIfPresent(userInfo: userInfo)
            }
        }
        completionHandler()
    }

    /// If the notification payload carries a `cta_url`, hand it to the client
    /// for navigation. Preference order:
    ///   1. `onDeepLink` callback if the host app set one (recommended for
    ///      apps with a SceneDelegate that doesn't implement
    ///      scene(_:openURLContexts:), or for apps where URL routing depends
    ///      on a third-party SDK that may not be initialized when the SDK
    ///      fires the deep link)
    ///   2. UIApplication.shared.open(url) as fallback — routes through
    ///      scene(_:openURLContexts:) or application(_:open:options:)
    @available(iOSApplicationExtension, unavailable)
    private func openCtaUrlIfPresent(userInfo: [AnyHashable: Any]) {
        guard let ctaUrlString = userInfo["cta_url"] as? String else {
            tnLog("cta_url not present in payload — skipping deep-link open")
            return
        }
        guard !ctaUrlString.isEmpty else {
            tnLog("cta_url is empty — skipping deep-link open")
            return
        }
        guard let ctaUrl = URL(string: ctaUrlString) else {
            tnLog("cta_url is not a parseable URL: \(ctaUrlString)")
            return
        }
        let messageId = (userInfo[messageIdKey] as? String) ?? ""

        // Path 1: host-app callback (preferred when set)
        if let callback = onDeepLink {
            tnLog("Forwarding cta_url to onDeepLink callback: \(ctaUrlString)")
            DispatchQueue.main.async {
                callback(ctaUrl, messageId)
            }
            return
        }

        // Path 2: fallback — ask iOS to open the URL
        tnLog("No onDeepLink callback set — falling back to UIApplication.shared.open: \(ctaUrlString)")
        DispatchQueue.main.async { [weak self] in
            UIApplication.shared.open(ctaUrl, options: [:]) { success in
                if success {
                    self?.tnLog("UIApplication.open returned success. If your app still didn't navigate, scene(_:openURLContexts:) is missing or your URL router didn't recognise the URL.")
                } else {
                    self?.tnLog("UIApplication.open returned FALSE for cta_url: \(ctaUrlString)")
                    self?.tnLog("  — declare the URL scheme in your Info.plist under CFBundleURLTypes")
                    self?.tnLog("  — implement scene(_:openURLContexts:) in your SceneDelegate (or application(_:open:options:) for non-scene apps)")
                    self?.tnLog("  — OR set ThoughtNudgeSDK.shared.onDeepLink to handle URLs programmatically")
                }
            }
        }
    }

    // MARK: - Internal

    @available(iOSApplicationExtension, unavailable)
    private func requestPermissionAndRegister() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
        ) { [weak self] granted, error in
            if let error = error {
                self?.tnLog("Permission error: \(error)")
                return
            }
            guard granted else {
                self?.tnLog("Push permission denied by user")
                return
            }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
            // APNs token arrives via AppDelegate forwarding, not here.
        }
    }

    internal func registerToken(token: String) {
        guard !userId.isEmpty, !apiBaseUrl.isEmpty else { return }
        UserDefaults.standard.set(token, forKey: apnsTokenKey)
        TNWebhookReporter.post(
            url: "\(apiBaseUrl)/notifications/register-token/",
            body: [
                "user_id": userId,
                "token": token,
                "platform": "ios",
                "app_id": appId
            ]
        )
        tnLog("APNs token registered with backend")
    }
}

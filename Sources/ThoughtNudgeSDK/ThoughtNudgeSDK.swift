import Foundation
import UIKit
import FirebaseCore
import FirebaseMessaging
import UserNotifications

/// ThoughtNudge Push Notification SDK for iOS.
///
/// The SDK does NOT install its own notification center delegate or
/// Messaging delegate. You must forward calls from your existing delegates.
///
/// Usage:
/// ```swift
/// // 1. Initialize in AppDelegate.didFinishLaunchingWithOptions
/// ThoughtNudgeSDK.shared.initialize(
///     appId: "YOUR_APP_ID",
///     environment: .production
/// )
///
/// // 2. Identify user after login
/// ThoughtNudgeSDK.shared.identify(userId: "user-123")
///
/// // 3. Forward APNs token
/// func application(_ application: UIApplication,
///                  didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
///     ThoughtNudgeSDK.shared.application(application,
///         didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
/// }
///
/// // 4. In your MessagingDelegate
/// func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
///     if let token = fcmToken {
///         ThoughtNudgeSDK.shared.onNewToken(token)
///     }
/// }
///
/// // 5. In your UNUserNotificationCenterDelegate
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

    /// Shared singleton instance.
    @objc public static let shared = ThoughtNudgeSDK()

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
    private let fcmTokenKey = "tn_fcm_token"
    private let messageIdKey = "tn_message_id"

    private var initialized = false
    private var pendingUserId: String?

    private override init() {
        super.init()
    }

    // MARK: - Public API

    /// Initialize the ThoughtNudge SDK.
    /// Call once from `AppDelegate.application(_:didFinishLaunchingWithOptions:)`.
    @objc public func initialize(appId: String, environment: Environment = .production) {
        self.apiBaseUrl = environment.url
        self.appId = appId
        self.userId = UserDefaults.standard.string(forKey: userIdKey) ?? ""
        self.initialized = true

        print("[ThoughtNudge] SDK initialized. appId=\(appId), env=\(environment)")

        // Replay any identify() call queued before init()
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
    @objc public func identify(userId: String) {
        if !initialized {
            print("[ThoughtNudge] identify() called before initialize() — queued")
            pendingUserId = userId
            return
        }
        self.userId = userId
        UserDefaults.standard.set(userId, forKey: userIdKey)
        print("[ThoughtNudge] User identified: \(userId)")
        requestPermissionAndRegister()
    }

    /// Call on user logout to deregister the device token.
    @objc public func logout() {
        guard initialized else { return }
        if let token = UserDefaults.standard.string(forKey: fcmTokenKey) {
            TNWebhookReporter.post(
                url: "\(apiBaseUrl)/notifications/deregister-token/",
                body: ["token": token]
            )
        }
        userId = ""
        UserDefaults.standard.removeObject(forKey: userIdKey)
        UserDefaults.standard.removeObject(forKey: fcmTokenKey)
        print("[ThoughtNudge] User logged out, token deregistered")
    }

    /// Report a custom event to ThoughtNudge backend.
    @objc public func reportEvent(eventType: String, messageId: String) {
        TNWebhookReporter.reportEvent(eventType: eventType, messageId: messageId)
    }

    /// Forward APNs device token. Call from
    /// `AppDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    @objc public func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Messaging.messaging().apnsToken = deviceToken
    }

    /// Handle APNs registration failure.
    @objc public func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[ThoughtNudge] APNs registration failed: \(error.localizedDescription)")
    }

    // MARK: - FCM Token Forwarding

    /// Forward a new FCM token. Call from your MessagingDelegate's
    /// `messaging(_:didReceiveRegistrationToken:)`.
    @objc public func onNewToken(_ token: String) {
        print("[ThoughtNudge] FCM token received: \(token.prefix(20))...")
        if !userId.isEmpty {
            registerToken(token: token)
        }
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
    /// Reports "clicked" on tap, "read" on dismiss.
    @objc public func handleNotificationResponse(
        _ response: UNNotificationResponse,
        completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let messageId = userInfo[messageIdKey] as? String, !messageId.isEmpty {
            if response.actionIdentifier == UNNotificationDismissActionIdentifier {
                TNWebhookReporter.reportEvent(eventType: "read", messageId: messageId)
            } else {
                TNWebhookReporter.reportEvent(eventType: "clicked", messageId: messageId)
            }
        }
        completionHandler()
    }

    // MARK: - Internal

    private func requestPermissionAndRegister() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
        ) { [weak self] granted, error in
            if let error = error {
                print("[ThoughtNudge] Permission error: \(error)")
                return
            }
            guard granted else {
                print("[ThoughtNudge] Push permission denied by user")
                return
            }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
            if let token = Messaging.messaging().fcmToken {
                self?.registerToken(token: token)
            }
        }
    }

    internal func registerToken(token: String) {
        guard !userId.isEmpty, !apiBaseUrl.isEmpty else { return }
        UserDefaults.standard.set(token, forKey: fcmTokenKey)
        TNWebhookReporter.post(
            url: "\(apiBaseUrl)/notifications/register-token/",
            body: [
                "user_id": userId,
                "token": token,
                "platform": "ios",
                "app_id": appId
            ]
        )
        print("[ThoughtNudge] Token registered with backend")
    }
}

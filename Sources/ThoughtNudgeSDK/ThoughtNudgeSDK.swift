import Foundation
import UIKit
import FirebaseCore
import FirebaseMessaging
import UserNotifications

/// ThoughtNudge Push Notification SDK for iOS.
///
/// Usage:
/// ```swift
/// // 1. Initialize (in AppDelegate.didFinishLaunchingWithOptions)
/// ThoughtNudgeSDK.shared.initialize(
///     apiBaseUrl: "https://api.thoughtnudge.com",
///     appId: "YOUR_APP_ID"
/// )
///
/// // 2. Set notification delegate
/// UNUserNotificationCenter.current().delegate = ThoughtNudgeSDK.shared
///
/// // 3. Identify user (after login)
/// ThoughtNudgeSDK.shared.identify(userId: "user-123")
///
/// // 4. Logout
/// ThoughtNudgeSDK.shared.logout()
/// ```
@objc public class ThoughtNudgeSDK: NSObject {

    /// Shared singleton instance
    @objc public static let shared = ThoughtNudgeSDK()

    internal var apiBaseUrl: String = ""
    internal var appId: String = ""
    internal var userId: String = ""

    private let userIdKey = "tn_user_id"
    private let fcmTokenKey = "tn_fcm_token"

    private override init() {
        super.init()
    }

    // MARK: - Public API

    /// Initialize the ThoughtNudge SDK.
    /// Call from `AppDelegate.application(_:didFinishLaunchingWithOptions:)`.
    ///
    /// - Parameters:
    ///   - apiBaseUrl: ThoughtNudge backend URL (provided by ThoughtNudge)
    ///   - appId: Your app ID (provided by ThoughtNudge)
    @objc public func initialize(apiBaseUrl: String, appId: String) {
        self.apiBaseUrl = apiBaseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.appId = appId

        // Restore user ID from UserDefaults (survives app restart)
        self.userId = UserDefaults.standard.string(forKey: userIdKey) ?? ""

        // Initialize Firebase
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }

        // Set FCM delegate
        Messaging.messaging().delegate = self

        print("[ThoughtNudge] SDK initialized. appId=\(appId)")

        // Re-register token if user was previously identified
        if !userId.isEmpty {
            requestPermissionAndRegister()
        }
    }

    /// Associate a user with this device. Call after user login.
    /// Requests push permission and registers the FCM token with ThoughtNudge.
    ///
    /// - Parameter userId: Your app's user identifier
    @objc public func identify(userId: String) {
        self.userId = userId
        UserDefaults.standard.set(userId, forKey: userIdKey)
        print("[ThoughtNudge] User identified: \(userId)")
        requestPermissionAndRegister()
    }

    /// Call on user logout to deregister the device token.
    @objc public func logout() {
        if let token = Messaging.messaging().fcmToken {
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
    /// Delivered and clicked events are tracked automatically.
    ///
    /// - Parameters:
    ///   - eventType: Event type string
    ///   - messageId: The tn_message_id from the notification data
    @objc public func reportEvent(eventType: String, messageId: String) {
        TNWebhookReporter.reportEvent(eventType: eventType, messageId: messageId)
    }

    /// Forward APNs device token to Firebase.
    /// Call from `AppDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    @objc public func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Messaging.messaging().apnsToken = deviceToken
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("[ThoughtNudge] APNs token received: \(tokenString.prefix(20))...")
    }

    /// Handle APNs registration failure.
    /// Call from `AppDelegate.application(_:didFailToRegisterForRemoteNotificationsWithError:)`.
    @objc public func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[ThoughtNudge] APNs registration failed: \(error.localizedDescription)")
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
            // If we already have a token, register it now
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

// MARK: - Firebase Messaging Delegate

extension ThoughtNudgeSDK: MessagingDelegate {

    public func messaging(
        _ messaging: Messaging,
        didReceiveRegistrationToken fcmToken: String?
    ) {
        guard let token = fcmToken else { return }
        print("[ThoughtNudge] FCM token: \(token.prefix(20))...")
        if !userId.isEmpty {
            registerToken(token: token)
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension ThoughtNudgeSDK: UNUserNotificationCenterDelegate {

    /// Called when notification arrives while app is in FOREGROUND.
    /// Reports "delivered" event and shows the notification.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        let messageId = userInfo["tn_message_id"] as? String ?? ""

        if !messageId.isEmpty {
            TNWebhookReporter.reportEvent(eventType: "delivered", messageId: messageId)
        }

        completionHandler([.banner, .sound, .badge])
    }

    /// Called when user interacts with the notification (tap or dismiss).
    /// Reports "clicked" on tap, "read" on dismiss.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let messageId = userInfo["tn_message_id"] as? String ?? ""

        if !messageId.isEmpty {
            if response.actionIdentifier == UNNotificationDismissActionIdentifier {
                TNWebhookReporter.reportEvent(eventType: "read", messageId: messageId)
            } else {
                TNWebhookReporter.reportEvent(eventType: "clicked", messageId: messageId)
            }
        }

        completionHandler()
    }
}

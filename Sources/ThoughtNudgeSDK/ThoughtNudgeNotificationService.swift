import Foundation
import UserNotifications
import os.log

/// Helper that handles all the heavy lifting inside a Notification Service
/// Extension: preserving userInfo across `mutableCopy`, reporting `delivered`
/// to the ThoughtNudge backend, appending `footer_text` to the body, and
/// downloading and attaching `image_url`.
///
/// Clients link the SDK to their NSE target and write a minimal extension:
///
/// ```swift
/// import UserNotifications
/// import ThoughtNudgeSDK
///
/// class NotificationService: UNNotificationServiceExtension {
///
///     private let tnService = ThoughtNudgeNotificationService(environment: .development)
///
///     override func didReceive(
///         _ request: UNNotificationRequest,
///         withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
///     ) {
///         tnService.didReceive(request, withContentHandler: contentHandler)
///     }
///
///     override func serviceExtensionTimeWillExpire() {
///         tnService.serviceExtensionTimeWillExpire()
///     }
/// }
/// ```
///
/// All backend URLs and event paths live inside the SDK — nothing is exposed
/// in the client's NSE source.
@objc public class ThoughtNudgeNotificationService: NSObject {

    private let environment: ThoughtNudgeSDK.Environment
    private let log = OSLog(subsystem: "com.thoughtnudge.sdk", category: "NSE")

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    @objc public init(environment: ThoughtNudgeSDK.Environment = .production) {
        self.environment = environment
        super.init()
    }

    /// Call from your NSE's `didReceive(_:withContentHandler:)`.
    @objc public func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttempt = (request.content.mutableCopy() as? UNMutableNotificationContent)
        guard let bestAttempt = bestAttempt else {
            contentHandler(request.content)
            return
        }

        // Not a ThoughtNudge notification — deliver as-is.
        guard let messageId = request.content.userInfo["tn_message_id"] as? String,
              !messageId.isEmpty else {
            contentHandler(bestAttempt)
            return
        }

        // CRITICAL: preserve userInfo so the main app's UN delegate methods
        // can detect the notification and fire clicked / read events.
        // ALSO mark `tn_delivered_reported` so handleForegroundNotification
        // in the main app skips its own delivered report — preventing the
        // duplicate-delivered events seen when the app is in foreground
        // (NSE always runs, willPresent also runs, both would fire delivered).
        var passedUserInfo = request.content.userInfo
        passedUserInfo["tn_delivered_reported"] = true
        bestAttempt.userInfo = passedUserInfo

        let userInfo = request.content.userInfo
        os_log("NSE didReceive — keys: %{public}@", log: log, type: .info,
               String(describing: Array(userInfo.keys.compactMap { $0 as? String })))

        // 1. Report delivered to ThoughtNudge backend.
        reportDelivered(
            messageId: messageId,
            userId: (userInfo["tn_user_id"] as? String) ?? "",
            appId: (userInfo["tn_app_id"] as? String) ?? ""
        )

        // 2. Append footer_text to body (iOS has no native footer slot).
        if let footer = userInfo["footer_text"] as? String, !footer.isEmpty {
            bestAttempt.body = "\(bestAttempt.body)\n\n\(footer)"
        }

        // 3. Download image_url and attach.
        guard let urlString = userInfo["image_url"] as? String,
              !urlString.isEmpty,
              let url = URL(string: urlString) else {
            contentHandler(bestAttempt)
            return
        }

        URLSession.shared.downloadTask(with: url) { [weak self] tempUrl, response, error in
            defer { contentHandler(bestAttempt) }
            if let error = error {
                os_log("Image download failed: %{public}@", log: self?.log ?? .default, type: .error, error.localizedDescription)
                return
            }
            guard let tempUrl = tempUrl else { return }
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                os_log("Image HTTP %d", log: self?.log ?? .default, type: .error, httpResponse.statusCode)
                return
            }
            let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
            let dest = tempUrl.appendingPathExtension(ext)
            do {
                try FileManager.default.moveItem(at: tempUrl, to: dest)
            } catch {
                os_log("Move failed: %{public}@", log: self?.log ?? .default, type: .error, error.localizedDescription)
                return
            }
            do {
                let attachment = try UNNotificationAttachment(identifier: "tn_image", url: dest, options: nil)
                bestAttempt.attachments = [attachment]
                os_log("Image attached", log: self?.log ?? .default, type: .info)
            } catch {
                os_log("Attachment init failed: %{public}@", log: self?.log ?? .default, type: .error, error.localizedDescription)
            }
        }.resume()
    }

    /// Call from your NSE's `serviceExtensionTimeWillExpire()`.
    /// Without this, iOS silently drops the notification when the extension times out.
    @objc public func serviceExtensionTimeWillExpire() {
        if let contentHandler = contentHandler, let bestAttempt = bestAttempt {
            contentHandler(bestAttempt)
        }
    }

    // MARK: - Internal

    private func reportDelivered(messageId: String, userId: String, appId: String) {
        guard let url = URL(string: "\(environment.url)/notifications/event") else { return }
        let body: [String: String] = [
            "event_type": "delivered",
            "message_id": messageId,
            "user_id": userId,
            "platform": "ios",
            "app_id": appId
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req).resume()
    }
}

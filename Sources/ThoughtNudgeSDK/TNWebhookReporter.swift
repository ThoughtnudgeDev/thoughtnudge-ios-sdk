import Foundation
import os.log

/// Internal HTTP client for reporting events back to ThoughtNudge backend.
internal class TNWebhookReporter {

    private static let osLog = OSLog(subsystem: "com.thoughtnudge.sdk", category: "webhook")

    private static func tnLog(_ message: String) {
        print("[ThoughtNudge] \(message)")
        os_log("[ThoughtNudge] %{public}@", log: osLog, type: .info, message)
    }

    static func reportEvent(eventType: String, messageId: String) {
        let sdk = ThoughtNudgeSDK.shared
        guard !sdk.apiBaseUrl.isEmpty else {
            tnLog("apiBaseUrl not set, skipping event report (eventType=\(eventType), messageId=\(messageId))")
            return
        }

        let urlString = "\(sdk.apiBaseUrl)/notifications/event"
        tnLog("reportEvent dispatching POST to \(urlString) — eventType=\(eventType), messageId=\(messageId), userId=\(sdk.userId), appId=\(sdk.appId)")
        post(
            url: urlString,
            body: [
                "event_type": eventType,
                "message_id": messageId,
                "user_id": sdk.userId,
                "platform": "ios",
                "app_id": sdk.appId
            ]
        )
    }

    static func post(url: String, body: [String: String]) {
        guard let requestUrl = URL(string: url) else {
            tnLog("Invalid URL: \(url)")
            return
        }

        var request = URLRequest(url: requestUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            tnLog("JSON serialization error: \(error)")
            return
        }

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                tnLog("API error for \(url): \(error.localizedDescription)")
                return
            }
            if let httpResponse = response as? HTTPURLResponse {
                tnLog("API response for \(url): HTTP \(httpResponse.statusCode)")
            } else {
                tnLog("API completed for \(url) with no HTTP response object")
            }
        }.resume()
    }
}

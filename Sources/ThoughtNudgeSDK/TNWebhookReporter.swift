import Foundation

/// Internal HTTP client for reporting events back to ThoughtNudge backend.
internal class TNWebhookReporter {

    static func reportEvent(eventType: String, messageId: String) {
        let sdk = ThoughtNudgeSDK.shared
        guard !sdk.apiBaseUrl.isEmpty else {
            print("[ThoughtNudge] apiBaseUrl not set, skipping event report")
            return
        }

        post(
            url: "\(sdk.apiBaseUrl)/notifications/event/",
            body: [
                "event_type": eventType,
                "message_id": messageId,
                "user_id": sdk.userId,
                "platform": "ios"
            ]
        )
        print("[ThoughtNudge] Reported event: \(eventType) for message \(messageId)")
    }

    static func post(url: String, body: [String: String]) {
        guard let requestUrl = URL(string: url) else {
            print("[ThoughtNudge] Invalid URL: \(url)")
            return
        }

        var request = URLRequest(url: requestUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            print("[ThoughtNudge] JSON serialization error: \(error)")
            return
        }

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                print("[ThoughtNudge] API error: \(error.localizedDescription)")
                return
            }
            if let httpResponse = response as? HTTPURLResponse {
                print("[ThoughtNudge] API response: \(httpResponse.statusCode)")
            }
        }.resume()
    }
}

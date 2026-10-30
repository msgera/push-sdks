import Foundation
import UserNotifications

/// Notification Service Extension for Msgera Push.
///
/// Subclass `MsgeraNotificationService` in your Notification Service Extension target
/// Add the same App Group to the app and this extension, and set Info.plist key
/// `MsgeraAppGroup` to that group id (for example `group.com.store.msgera`).
/// This extension reports `received` delivery events when the app is backgrounded or closed
/// and downloads rich notification images (`imageUrl`) into a `UNNotificationAttachment`.
open class MsgeraNotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private let stateLock = NSLock()
    private var delivered = false

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    open override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        let mutable = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        self.bestAttemptContent = mutable

        let userInfo = request.content.userInfo
        let msgera = userInfo["msgera"] as? [String: Any]
        let messageId = (msgera?["messageId"] as? String) ?? (userInfo["msgeraMessageId"] as? String)
        let imageUrlString = (msgera?["imageUrl"] as? String) ?? (userInfo["imageUrl"] as? String)

        let group = DispatchGroup()

        if let messageId = messageId, !messageId.isEmpty {
            group.enter()
            reportReceived(messageId: messageId) {
                group.leave()
            }
        }

        applyBadge(mutable, msgera: msgera)
        applyThread(mutable, userInfo: userInfo, msgera: msgera)

        let buttonRows = (msgera?["buttons"] as? [[String: Any]])
            ?? (userInfo["msgeraButtons"] as? [[String: Any]])
            ?? []
        if !buttonRows.isEmpty {
            group.enter()
            registerButtons(buttonRows, content: mutable) {
                group.leave()
            }
        }

        if let imageUrlString = imageUrlString,
           let imageUrl = URL(string: imageUrlString),
           let scheme = imageUrl.scheme?.lowercased(),
           scheme == "https" || scheme == "http" {
            group.enter()
            downloadAttachment(from: imageUrl) { attachment in
                if let attachment = attachment {
                    mutable.attachments = [attachment]
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.finish()
        }
    }

    open override func serviceExtensionTimeWillExpire() {
        finish()
    }

    private func finish() {
        stateLock.lock()
        guard !delivered else {
            stateLock.unlock()
            return
        }
        delivered = true
        let handler = contentHandler
        let content = bestAttemptContent
        stateLock.unlock()

        if let handler = handler, let content = content {
            handler(content)
        }
    }

    private func applyBadge(_ content: UNMutableNotificationContent, msgera: [String: Any]?) {
        guard msgera?["badgeMode"] as? String == "increment" else { return }
        let defaults = appGroupDefaults()
        let next = (defaults?.integer(forKey: "io.msgera.push.badgeCount") ?? 0) + 1
        defaults?.set(next, forKey: "io.msgera.push.badgeCount")
        content.badge = NSNumber(value: next)
    }

    private func applyThread(
        _ content: UNMutableNotificationContent,
        userInfo: [AnyHashable: Any],
        msgera: [String: Any]?
    ) {
        if !content.threadIdentifier.isEmpty { return }
        let aps = userInfo["aps"] as? [String: Any]
        let thread = (aps?["thread-id"] as? String)
            ?? (msgera?["groupKey"] as? String)
            ?? (userInfo["groupKey"] as? String)
        if let thread, !thread.isEmpty {
            content.threadIdentifier = thread
        }
    }

    private func registerButtons(
        _ rows: [[String: Any]],
        content: UNMutableNotificationContent,
        completion: @escaping () -> Void
    ) {
        var actions: [UNNotificationAction] = []
        var urls: [String: String] = [:]
        for row in rows.prefix(4) {
            guard let id = row["id"] as? String, !id.isEmpty else { continue }
            let title = (row["text"] as? String) ?? (row["title"] as? String) ?? id
            actions.append(UNNotificationAction(identifier: id, title: title, options: []))
            if let url = row["url"] as? String, !url.isEmpty { urls[id] = url }
        }
        guard !actions.isEmpty else {
            completion()
            return
        }
        if !urls.isEmpty {
            var info = content.userInfo
            info["msgeraButtonUrls"] = urls
            content.userInfo = info
        }
        let categoryId = "msgera." + actions.map(\.identifier).joined(separator: ".")
        content.categoryIdentifier = categoryId
        let category = UNNotificationCategory(
            identifier: categoryId,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { existing in
            var next = existing
            next.insert(category)
            center.setNotificationCategories(next)
            completion()
        }
    }

    private func reportReceived(messageId: String, completion: @escaping () -> Void) {
        let defaults = appGroupDefaults()
        let storedApi = defaults?.string(forKey: "io.msgera.push.apiBase") ?? ""
        let api = storedApi.isEmpty ? "https://api.msgera.io" : storedApi
        guard let appId = defaults?.string(forKey: "io.msgera.push.appId"),
              !appId.isEmpty,
              let subscriberId = defaults?.string(forKey: "io.msgera.push.subscriberId"),
              !subscriberId.isEmpty,
              let url = URL(string: "\(api)/v1/public/push/\(appId)/subscribers/\(subscriberId)/events") else {
            completion()
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "messageId": messageId,
            "type": "received",
        ])

        Self.session.dataTask(with: request) { _, _, _ in
            completion()
        }.resume()
    }

    private func downloadAttachment(from url: URL, completion: @escaping (UNNotificationAttachment?) -> Void) {
        Self.session.downloadTask(with: url) { tempUrl, response, error in
            guard error == nil, let tempUrl = tempUrl else {
                completion(nil)
                return
            }
            let ext = Self.resolveExtension(url: url, mimeType: response?.mimeType)
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ext)
            do {
                try FileManager.default.moveItem(at: tempUrl, to: destination)
                let attachment = try UNNotificationAttachment(identifier: "image", url: destination, options: nil)
                completion(attachment)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                completion(nil)
            }
        }.resume()
    }

    private func appGroupDefaults() -> UserDefaults? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "MsgeraAppGroup") as? String
        let id = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty else { return nil }
        return UserDefaults(suiteName: id)
    }

    private static func resolveExtension(url: URL, mimeType: String?) -> String {
        if let mime = mimeType?.lowercased() {
            switch mime {
            case "image/png": return ".png"
            case "image/gif": return ".gif"
            case "image/webp": return ".webp"
            case "image/jpeg", "image/jpg": return ".jpg"
            default: break
            }
        }
        let pathExt = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "gif", "webp"].contains(pathExt) {
            return ".\(pathExt)"
        }
        return ".jpg"
    }
}

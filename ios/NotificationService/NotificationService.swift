import Foundation
import UserNotifications
#if canImport(MsgeraPushExtension)
import MsgeraPushExtension

/// Notification Service Extension entry point.
/// Add the `MsgeraPushExtension` product to your Notification Service Extension target
/// Set Info.plist key `MsgeraAppGroup` to your App Group id on both targets.
class NotificationService: MsgeraNotificationService {}
#else
/// Standalone Notification Service Extension fallback when copied directly into a target.
/// Set Info.plist key `MsgeraAppGroup` to your App Group id.
class NotificationService: UNNotificationServiceExtension {
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

    override func didReceive(
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
            let defaults = Self.appGroupDefaults()
            let storedApi = defaults?.string(forKey: "io.msgera.push.apiBase") ?? ""
            let api = storedApi.isEmpty ? "https://api.msgera.io" : storedApi
            if let appId = defaults?.string(forKey: "io.msgera.push.appId"),
               let subscriberId = defaults?.string(forKey: "io.msgera.push.subscriberId"),
               let url = URL(string: "\(api)/v1/public/push/\(appId)/subscribers/\(subscriberId)/events") {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: ["messageId": messageId, "type": "received"])
                Self.session.dataTask(with: req) { _, _, _ in group.leave() }.resume()
            } else {
                group.leave()
            }
        }

        if msgera?["badgeMode"] as? String == "increment" {
            let defaults = Self.appGroupDefaults()
            let next = (defaults?.integer(forKey: "io.msgera.push.badgeCount") ?? 0) + 1
            defaults?.set(next, forKey: "io.msgera.push.badgeCount")
            mutable.badge = NSNumber(value: next)
        }
        if mutable.threadIdentifier.isEmpty {
            let aps = userInfo["aps"] as? [String: Any]
            let thread = (aps?["thread-id"] as? String)
                ?? (msgera?["groupKey"] as? String)
                ?? (userInfo["groupKey"] as? String)
            if let thread, !thread.isEmpty { mutable.threadIdentifier = thread }
        }
        let buttonRows = (msgera?["buttons"] as? [[String: Any]])
            ?? (userInfo["msgeraButtons"] as? [[String: Any]])
            ?? []
        if !buttonRows.isEmpty {
            group.enter()
            var actions: [UNNotificationAction] = []
            var urls: [String: String] = [:]
            for row in buttonRows.prefix(4) {
                guard let id = row["id"] as? String, !id.isEmpty else { continue }
                let title = (row["text"] as? String) ?? (row["title"] as? String) ?? id
                actions.append(UNNotificationAction(identifier: id, title: title, options: []))
                if let url = row["url"] as? String, !url.isEmpty { urls[id] = url }
            }
            if actions.isEmpty {
                group.leave()
            } else {
                if !urls.isEmpty {
                    var info = mutable.userInfo
                    info["msgeraButtonUrls"] = urls
                    mutable.userInfo = info
                }
                let categoryId = "msgera." + actions.map(\.identifier).joined(separator: ".")
                mutable.categoryIdentifier = categoryId
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
                    group.leave()
                }
            }
        }

        if let imageUrlString = imageUrlString,
           let imageUrl = URL(string: imageUrlString),
           let scheme = imageUrl.scheme?.lowercased(),
           scheme == "https" || scheme == "http" {
            group.enter()
            Self.session.downloadTask(with: imageUrl) { tempUrl, response, error in
                defer { group.leave() }
                guard error == nil, let tempUrl = tempUrl else { return }
                let ext = Self.resolveExtension(url: imageUrl, mimeType: response?.mimeType)
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ext)
                if (try? FileManager.default.moveItem(at: tempUrl, to: destination)) != nil,
                   let attachment = try? UNNotificationAttachment(identifier: "image", url: destination, options: nil) {
                    mutable.attachments = [attachment]
                }
            }.resume()
        }

        group.notify(queue: .main) { [weak self] in
            self?.finish()
        }
    }

    override func serviceExtensionTimeWillExpire() {
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

    private static func appGroupDefaults() -> UserDefaults? {
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
        return ["jpg", "jpeg", "png", "gif", "webp"].contains(pathExt) ? ".\(pathExt)" : ".jpg"
    }
}
#endif

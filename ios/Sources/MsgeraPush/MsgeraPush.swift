import Foundation
import ObjectiveC.runtime
import UIKit
import UserNotifications

/// iOS push for a Msgera app. Uses the Apple device token, not Firebase.
///
/// Call `MsgeraPush.shared.start(appId:)` from `application(_:didFinishLaunchingWithOptions:)`.
/// Call `MsgeraPush.shared.requestPermission()` from a button. Asking at launch is the prompt
/// users deny, and iOS will not show it again.
public final class MsgeraPush: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = MsgeraPush()
    public static let SDK_VERSION = "1.1.0"
    public static let DEFAULT_API_BASE = "https://api.msgera.io"

    /// When true (the default), `start(appId:)` installs the notification center delegate
    /// and hooks the app delegate for remote notification token registration and cold-start
    /// launch payloads automatically. Set to `false` before calling `start` to wire
    /// `didRegister(deviceToken:)` and `handleLaunch(userInfo:)` manually.
    public static var automaticSetup: Bool = true

    public enum LogLevel: String {
        case none
        case error
        case verbose
    }

    public typealias Done = (Error?) -> Void

    public final class MsgeraClickEvent {
        public let messageId: String?
        public let title: String?
        public let body: String?
        public let data: [String: String]
        public let launchUrl: String?
        public let actionId: String?
        private var prevented = false
        public func preventDefault() { prevented = true }
        var wasPrevented: Bool { prevented }
        init(messageId: String?, title: String?, body: String?, data: [String: String], launchUrl: String?, actionId: String?) {
            self.messageId = messageId
            self.title = title
            self.body = body
            self.data = data
            self.launchUrl = launchUrl
            self.actionId = actionId
        }
    }

    public final class MsgeraForegroundEvent {
        public let messageId: String?
        public let title: String?
        public let body: String?
        public let data: [String: String]
        private var prevented = false
        public func preventDefault() { prevented = true }
        var wasPrevented: Bool { prevented }
        init(messageId: String?, title: String?, body: String?, data: [String: String]) {
            self.messageId = messageId
            self.title = title
            self.body = body
            self.data = data
        }
    }

    public struct PushSubscriptionState {
        public let id: String?
        public let token: String?
        public let optedIn: Bool
    }

    private let sdkVersion = MsgeraPush.SDK_VERSION
    private let defaults = UserDefaults.standard
    private var appGroupId: String?
    private var sharedDefaults: UserDefaults? {
        guard let appGroupId, !appGroupId.isEmpty else { return nil }
        return UserDefaults(suiteName: appGroupId)
    }
    private var pendingClicks = Set<String>()
    private var queuedClicks: [MsgeraClickEvent] = []
    private var clickListeners: [(MsgeraClickEvent) -> Void] = []
    private var foregroundListeners: [(MsgeraForegroundEvent) -> Void] = []
    private var permissionObservers: [(Bool) -> Void] = []
    private var subscriptionObservers: [(PushSubscriptionState) -> Void] = []
    private var tagPatch: [String: Any] = [:]
    private var tagWork: DispatchWorkItem?
    private var consentRequired = false
    private var consentGiven = false
    private var inFlightToken: String?
    private var logLevel: LogLevel = .error
    private var swizzledDelegateClasses = Set<String>()
    private var launchObserverInstalled = false

    private override init() {
        super.init()
    }

    public static func setLogLevel(_ level: LogLevel) {
        shared.setLogLevel(level)
    }

    public func setLogLevel(_ level: LogLevel) {
        logLevel = level
    }

    public static func start(appId: String, apiBase: String = MsgeraPush.DEFAULT_API_BASE, appGroup: String? = nil) {
        shared.start(appId: appId, apiBase: apiBase, appGroup: appGroup)
    }

    public func start(appId: String, apiBase: String = MsgeraPush.DEFAULT_API_BASE, appGroup: String? = nil) {
        let trimmedGroup = appGroup?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        appGroupId = trimmedGroup.isEmpty ? nil : trimmedGroup
        let trimmed = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = trimmed.isEmpty ? MsgeraPush.DEFAULT_API_BASE : trimmed
        defaults.set(appId, forKey: "io.msgera.push.appId")
        defaults.set(base, forKey: "io.msgera.push.apiBase")
        sharedDefaults?.set(appId, forKey: "io.msgera.push.appId")
        sharedDefaults?.set(base, forKey: "io.msgera.push.apiBase")
        consentRequired = defaults.bool(forKey: "io.msgera.push.consentRequired")
        consentGiven = defaults.bool(forKey: "io.msgera.push.consentGiven")
        logVerbose("Initialized MsgeraPush v\(sdkVersion) for app \(appId)")

        installNotificationDelegate()
        refreshPermissionFlag()
        if MsgeraPush.automaticSetup {
            installAutomaticSetup()
        }
        DispatchQueue.main.async {
            if MsgeraPush.automaticSetup {
                self.swizzleAppDelegateIfNeeded()
            }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Assigns `MsgeraPush.shared` as the `UNUserNotificationCenter` delegate.
    public func installNotificationDelegate() {
        UNUserNotificationCenter.current().delegate = self
    }

    public func requestPermission(fallbackToSettings: Bool = false, done: ((Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            if settings.authorizationStatus == .denied {
                DispatchQueue.main.async {
                    if fallbackToSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url, options: [:], completionHandler: nil)
                    }
                    done?(false)
                }
                return
            }

            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                DispatchQueue.main.async {
                    if let error = error {
                        self?.logError("Permission request error: \(error.localizedDescription)")
                        done?(false)
                        return
                    }
                    if !granted {
                        self?.logVerbose("Notification permission was denied by user")
                        done?(false)
                        return
                    }
                    UIApplication.shared.registerForRemoteNotifications()
                    done?(true)
                }
            }
        }
    }

    public func didRegister(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        register(token: token, done: nil)
    }

    public func login(externalUserId: String, userHash: String?, done: Done? = nil) {
        guard let subscriberId = defaults.string(forKey: "io.msgera.push.subscriberId") else {
            done?(NSError(domain: "MsgeraPush", code: 2, userInfo: [NSLocalizedDescriptionKey: "Register the device before login"]))
            return
        }
        var body: [String: Any] = ["externalUserId": externalUserId]
        if let userHash = userHash {
            body["userHash"] = userHash
            defaults.set(userHash, forKey: "io.msgera.push.userHash")
        }
        post(path: "/v1/public/push/\(appId())/subscribers/\(subscriberId)/login", body: body, done: done)
    }

    public func logout(done: Done? = nil) {
        guard let subscriberId = defaults.string(forKey: "io.msgera.push.subscriberId") else {
            done?(nil)
            return
        }
        post(path: "/v1/public/push/\(appId())/subscribers/\(subscriberId)/logout", body: [:], done: done)
    }

    public var pushSubscription: PushSubscriptionState {
        PushSubscriptionState(
            id: defaults.string(forKey: "io.msgera.push.subscriberId"),
            token: defaults.string(forKey: "io.msgera.push.token"),
            optedIn: defaults.object(forKey: "io.msgera.push.optedIn") as? Bool ?? true
        )
    }

    public private(set) var canRequestPermission: Bool = true

    public func addClickListener(_ listener: @escaping (MsgeraClickEvent) -> Void) {
        clickListeners.append(listener)
        let pending = queuedClicks
        queuedClicks.removeAll()
        pending.forEach { dispatchClick($0) }
    }

    public func addForegroundListener(_ listener: @escaping (MsgeraForegroundEvent) -> Void) {
        foregroundListeners.append(listener)
    }

    public func addPermissionObserver(_ listener: @escaping (Bool) -> Void) {
        permissionObservers.append(listener)
    }

    public func addSubscriptionObserver(_ listener: @escaping (PushSubscriptionState) -> Void) {
        subscriptionObservers.append(listener)
    }

    public func optOut(done: Done? = nil) { setOptedIn(false, done: done) }
    public func optIn(done: Done? = nil) { setOptedIn(true, done: done) }

    public func addTag(_ key: String, value: String) { queueTag(key, value) }
    public func addTags(_ tags: [String: String]) { tags.forEach { queueTag($0.key, $0.value) } }
    public func removeTag(_ key: String) { queueTag(key, NSNull()) }
    public func removeTags(_ keys: [String]) { keys.forEach { queueTag($0, NSNull()) } }
    public func getTags() -> [String: String] {
        defaults.dictionary(forKey: "io.msgera.push.tags") as? [String: String] ?? [:]
    }

    public func setLanguage(_ language: String, done: Done? = nil) {
        defaults.set(language, forKey: "io.msgera.push.language")
        guard let subscriberId = defaults.string(forKey: "io.msgera.push.subscriberId") else {
            done?(nil)
            return
        }
        post(path: "/v1/public/push/\(appId())/subscribers/\(subscriberId)", body: ["language": language], done: done)
    }

    public func trackEvent(_ name: String, properties: [String: Any]? = nil, done: Done? = nil) {
        guard let subscriberId = defaults.string(forKey: "io.msgera.push.subscriberId") else {
            done?(NSError(domain: "MsgeraPush", code: 2, userInfo: [NSLocalizedDescriptionKey: "Register the device before trackEvent"]))
            return
        }
        var body: [String: Any] = ["name": name]
        if let properties = properties { body["properties"] = properties }
        post(path: "/v1/public/push/\(appId())/subscribers/\(subscriberId)/events", body: body, done: done)
    }

    public static func setConsentRequired(_ required: Bool) {
        shared.consentRequired = required
        shared.defaults.set(required, forKey: "io.msgera.push.consentRequired")
    }

    public static func setConsentGiven(_ given: Bool) {
        shared.consentGiven = given
        shared.defaults.set(given, forKey: "io.msgera.push.consentGiven")
        if given, let token = shared.defaults.string(forKey: "io.msgera.push.token") {
            shared.register(token: token, done: nil)
        }
    }

    public func deleteDevice(done: Done? = nil) {
        let finish: Done = { error in
            self.defaults.removeObject(forKey: "io.msgera.push.subscriberId")
            self.defaults.removeObject(forKey: "io.msgera.push.token")
            self.defaults.removeObject(forKey: "io.msgera.push.tags")
            self.defaults.removeObject(forKey: "io.msgera.push.userHash")
            self.defaults.set(true, forKey: "io.msgera.push.optedIn")
            self.notifySubscription()
            done?(error)
        }
        guard let subscriberId = defaults.string(forKey: "io.msgera.push.subscriberId"), networkAllowed() else {
            finish(nil)
            return
        }
        request(method: "DELETE", path: "/v1/public/push/\(appId())/subscribers/\(subscriberId)", body: nil, done: finish)
    }

    public func clearAllNotifications() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        let event = MsgeraForegroundEvent(
            messageId: messageId(from: userInfo),
            title: notification.request.content.title,
            body: notification.request.content.body,
            data: stringData(from: userInfo)
        )
        foregroundListeners.forEach { $0(event) }
        if event.wasPrevented {
            completionHandler([])
        } else if #available(iOS 14.0, *) {
            completionHandler([.banner, .list, .sound, .badge])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
        if let messageId = event.messageId {
            report(messageId: messageId, type: "received")
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier == UNNotificationDefaultActionIdentifier ? nil : response.actionIdentifier
        handle(userInfo: response.notification.request.content.userInfo, actionId: action)
        completionHandler()
    }

    /// Cold start: the tap can arrive before the first screen exists.
    public func handleLaunch(userInfo: [AnyHashable: Any]?) {
        guard let userInfo = userInfo else { return }
        handle(userInfo: userInfo)
    }

    private func installAutomaticSetup() {
        if !launchObserverInstalled {
            launchObserverInstalled = true
            NotificationCenter.default.addObserver(
                forName: UIApplication.didFinishLaunchingNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.swizzleAppDelegateIfNeeded()
                if let remoteNotification = notification.userInfo?[UIApplication.LaunchOptionsKey.remoteNotification] as? [AnyHashable: Any] {
                    self?.handleLaunch(userInfo: remoteNotification)
                }
            }
        }
        if Thread.isMainThread {
            swizzleAppDelegateIfNeeded()
        }
    }

    private func swizzleAppDelegateIfNeeded() {
        guard MsgeraPush.automaticSetup,
              let delegate = UIApplication.shared.delegate else { return }
        let delegateClass: AnyClass = object_getClass(delegate) ?? type(of: delegate)
        let className = NSStringFromClass(delegateClass)
        guard !swizzledDelegateClasses.contains(className) else { return }
        swizzledDelegateClasses.insert(className)

        let originalSelector = #selector(UIApplicationDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:))
        let swizzledSelector = #selector(MsgeraPush.msgera_application(_:didRegisterForRemoteNotificationsWithDeviceToken:))

        guard let swizzledMethod = class_getInstanceMethod(MsgeraPush.self, swizzledSelector) else { return }
        let swizzledImp = method_getImplementation(swizzledMethod)
        let types = method_getTypeEncoding(swizzledMethod)

        if let originalMethod = class_getInstanceMethod(delegateClass, originalSelector) {
            let aliasSelector = NSSelectorFromString("msgera_original_application:didRegisterForRemoteNotificationsWithDeviceToken:")
            class_addMethod(delegateClass, aliasSelector, method_getImplementation(originalMethod), method_getTypeEncoding(originalMethod))
            method_setImplementation(originalMethod, swizzledImp)
        } else {
            class_addMethod(delegateClass, originalSelector, swizzledImp, types)
        }
        logVerbose("Installed automatic AppDelegate token hook on \(className)")
    }

    @objc private func msgera_application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        MsgeraPush.shared.didRegister(deviceToken: deviceToken)
        let aliasSelector = NSSelectorFromString("msgera_original_application:didRegisterForRemoteNotificationsWithDeviceToken:")
        if responds(to: aliasSelector) {
            _ = perform(aliasSelector, with: application, with: deviceToken)
        }
    }

    private func handle(userInfo: [AnyHashable: Any], actionId: String? = nil) {
        guard let messageId = messageId(from: userInfo) else { return }
        if pendingClicks.contains(messageId) { return }
        pendingClicks.insert(messageId)
        report(messageId: messageId, type: "clicked")
        let contentTitle = userInfo["title"] as? String
        let contentBody = userInfo["body"] as? String
        let event = MsgeraClickEvent(
            messageId: messageId,
            title: contentTitle,
            body: contentBody,
            data: stringData(from: userInfo),
            launchUrl: buttonUrl(from: userInfo, actionId: actionId) ?? clickUrl(from: userInfo),
            actionId: actionId
        )
        if clickListeners.isEmpty {
            queuedClicks.append(event)
            return
        }
        dispatchClick(event)
    }

    private func dispatchClick(_ event: MsgeraClickEvent) {
        clickListeners.forEach { $0(event) }
        guard !event.wasPrevented, let urlString = event.launchUrl, let url = URL(string: urlString) else { return }
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    private func stringData(from userInfo: [AnyHashable: Any]) -> [String: String] {
        var data: [String: String] = [:]
        let source = (userInfo["msgera"] as? [String: Any]) ?? userInfo
        for (key, value) in source {
            let name = String(describing: key)
            if let text = value as? String { data[name] = text }
        }
        if let group = data["groupKey"] ?? userInfo["groupKey"] as? String {
            data["groupKey"] = group
        }
        return data
    }

    private func setOptedIn(_ optedIn: Bool, done: Done?) {
        defaults.set(optedIn, forKey: "io.msgera.push.optedIn")
        notifySubscription()
        guard let subscriberId = defaults.string(forKey: "io.msgera.push.subscriberId") else {
            done?(nil)
            return
        }
        post(
            path: "/v1/public/push/\(appId())/subscribers/\(subscriberId)/subscription",
            body: ["optedIn": optedIn],
            done: done
        )
    }

    private func queueTag(_ key: String, _ value: Any) {
        var cached = getTags()
        if value is NSNull { cached.removeValue(forKey: key) } else if let text = value as? String { cached[key] = text }
        defaults.set(cached, forKey: "io.msgera.push.tags")
        tagPatch[key] = value
        tagWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushTags() }
        tagWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func flushTags() {
        guard networkAllowed(), let subscriberId = defaults.string(forKey: "io.msgera.push.subscriberId") else { return }
        let patch = tagPatch
        tagPatch = [:]
        var body: [String: Any] = ["tags": patch]
        if let hash = defaults.string(forKey: "io.msgera.push.userHash") { body["userHash"] = hash }
        post(path: "/v1/public/push/\(appId())/subscribers/\(subscriberId)/tags", body: body, done: nil)
    }

    private func networkAllowed() -> Bool {
        !consentRequired || consentGiven
    }

    private func notifySubscription() {
        let state = pushSubscription
        subscriptionObservers.forEach { $0(state) }
    }

    private func refreshPermissionFlag() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let allowed = settings.authorizationStatus != .denied
            DispatchQueue.main.async {
                self?.canRequestPermission = allowed
                self?.permissionObservers.forEach { $0(allowed) }
            }
        }
    }

    private func messageId(from userInfo: [AnyHashable: Any]) -> String? {
        if let msgera = userInfo["msgera"] as? [String: Any],
           let id = msgera["messageId"] as? String {
            return id
        }
        return userInfo["msgeraMessageId"] as? String
    }

    private func buttonUrl(from userInfo: [AnyHashable: Any], actionId: String?) -> String? {
        guard let actionId,
              let urls = userInfo["msgeraButtonUrls"] as? [String: String],
              let url = urls[actionId],
              !url.isEmpty else { return nil }
        return url
    }

    private func clickUrl(from userInfo: [AnyHashable: Any]) -> String? {
        if let msgera = userInfo["msgera"] as? [String: Any],
           let url = msgera["clickUrl"] as? String {
            return url
        }
        return userInfo["clickUrl"] as? String
    }

    private func register(token: String, done: Done?) {
        // Re-sent daily so the server knows the device is still in use.
        let synced = defaults.double(forKey: "io.msgera.push.syncedAt")
        if defaults.string(forKey: "io.msgera.push.token") == token,
           defaults.string(forKey: "io.msgera.push.subscriberId") != nil,
           Date().timeIntervalSince1970 - synced < 24 * 60 * 60 {
            done?(nil)
            return
        }
        if !networkAllowed() {
            done?(NSError(domain: "MsgeraPush", code: 4, userInfo: [NSLocalizedDescriptionKey: "Consent is required before Msgera push can send data"]))
            return
        }
        if defaults.object(forKey: "io.msgera.push.optedIn") as? Bool == false {
            done?(nil)
            return
        }
        if inFlightToken == token {
            done?(nil)
            return
        }
        inFlightToken = token
        let body: [String: Any] = [
            "token": token,
            "platform": "ios",
            "transport": "apns",
            "language": defaults.string(forKey: "io.msgera.push.language") ?? Locale.current.identifier,
            "timezone": TimeZone.current.identifier,
            "sdkVersion": sdkVersion,
            "apnsEnvironment": apnsEnvironment(),
        ]
        post(path: "/v1/public/push/\(appId())/subscribers", body: body) { [weak self] error, json in
            self?.inFlightToken = nil
            if let error = error {
                self?.logError("Device registration failed: \(error.localizedDescription)")
                done?(error)
                return
            }
            if let id = json?["subscriberId"] as? String {
                self?.defaults.set(id, forKey: "io.msgera.push.subscriberId")
                self?.defaults.set(token, forKey: "io.msgera.push.token")
                self?.defaults.set(Date().timeIntervalSince1970, forKey: "io.msgera.push.syncedAt")
                self?.sharedDefaults?.set(id, forKey: "io.msgera.push.subscriberId")
                self?.sharedDefaults?.set(self?.apiBase(), forKey: "io.msgera.push.apiBase")
                self?.logVerbose("Registered subscriber \(id)")
                self?.notifySubscription()
            }
            done?(nil)
        }
    }

    private func report(messageId: String, type: String) {
        guard let subscriberId = defaults.string(forKey: "io.msgera.push.subscriberId") else { return }
        post(
            path: "/v1/public/push/\(appId())/subscribers/\(subscriberId)/events",
            body: ["messageId": messageId, "type": type],
            done: nil
        )
    }

    private func apnsEnvironment() -> String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    private func appId() -> String {
        defaults.string(forKey: "io.msgera.push.appId") ?? ""
    }

    private func apiBase() -> String {
        let stored = defaults.string(forKey: "io.msgera.push.apiBase") ?? ""
        return stored.isEmpty ? MsgeraPush.DEFAULT_API_BASE : stored
    }

    private func post(path: String, body: [String: Any], done: Done?) {
        request(method: "POST", path: path, body: body, done: done)
    }

    private func post(path: String, body: [String: Any], done: @escaping (Error?, [String: Any]?) -> Void) {
        request(method: "POST", path: path, body: body, done: done)
    }

    private func request(method: String, path: String, body: [String: Any]?, done: Done?) {
        request(method: method, path: path, body: body) { error, _ in done?(error) }
    }

    private func request(method: String, path: String, body: [String: Any]?, done: @escaping (Error?, [String: Any]?) -> Void) {
        guard networkAllowed() else {
            done(NSError(domain: "MsgeraPush", code: 4, userInfo: [NSLocalizedDescriptionKey: "Consent is required before Msgera push can send data"]), nil)
            return
        }
        guard let url = URL(string: apiBase() + path) else {
            done(NSError(domain: "MsgeraPush", code: 3, userInfo: [NSLocalizedDescriptionKey: "Bad API URL"]), nil)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body = body, method != "DELETE" {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                self?.logError("Request \(path) failed: \(error.localizedDescription)")
                done(error, nil)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
            if !(200...299).contains(status) {
                let message = json?["message"] as? String ?? "Push request failed (\(status))"
                self?.logError("Request \(path) returned \(status): \(message)")
                done(NSError(domain: "MsgeraPush", code: status, userInfo: [NSLocalizedDescriptionKey: message]), nil)
                return
            }
            done(nil, json)
        }.resume()
    }

    private func logVerbose(_ message: String) {
        guard logLevel == .verbose else { return }
        print("[MsgeraPush] \(message)")
    }

    private func logError(_ message: String) {
        guard logLevel == .error || logLevel == .verbose else { return }
        print("[MsgeraPush ERROR] \(message)")
    }
}

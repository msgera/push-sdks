# Msgera Push SDK for iOS

Native APNs push notifications and rich media Notification Service Extension for Msgera apps.

## 1. Install (Swift Package Manager)

In Xcode, go to **File → Add Package Dependencies…** and enter:

```
https://github.com/msgera/push-sdks
```

- Add **`MsgeraPush`** to your main application target.
- Add **`MsgeraPushExtension`** to your Notification Service Extension target.
- Enable **Push Notifications**, **Background Modes** (Remote notifications), and an **App Group you own** (for example `group.com.yourcompany.app.msgera`) on both your main app target and your Notification Service Extension target.
- Set the extension Info.plist key `MsgeraAppGroup` to that same group id, and pass it to `start(appId:appGroup:)`.

### Notification Service Extension (Rich Images & Delivery Receipts)

In your Notification Service Extension target's `NotificationService.swift`, subclass `MsgeraNotificationService`:

```swift
import MsgeraPushExtension

final class NotificationService: MsgeraNotificationService {}
```

## 2. Initialize

Call `MsgeraPush.shared.start(appId:appGroup:)` inside `application(_:didFinishLaunchingWithOptions:)`. By default, `MsgeraPush.automaticSetup` is `true`, so the SDK automatically sets the `UNUserNotificationCenter` delegate and captures the APNs device token and launch notifications:

```swift
import MsgeraPush
import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        MsgeraPush.setLogLevel(.verbose) // optional for debugging
        MsgeraPush.shared.start(appId: "YOUR_APP_PUBLIC_ID", appGroup: "group.YOUR.BUNDLE.msgera")
        return true
    }
}
```

> If you prefer not to use automatic AppDelegate hooking, set `MsgeraPush.automaticSetup = false` before calling `start(appId:)` and forward `MsgeraPush.shared.didRegister(deviceToken:)` and `MsgeraPush.shared.handleLaunch(userInfo:)` manually.

## 3. Request Permission

Request notification permission from a user interaction:

```swift
MsgeraPush.shared.requestPermission(fallbackToSettings: true) { granted in
    print("Push permission granted:", granted)
}
```

## 4. Login & Logout

Associate the device with your user ID (pass `userHash` when identity verification is enabled):

```swift
MsgeraPush.shared.login(externalUserId: "user_123", userHash: userHash) { error in
    // Linked to user_123
}

// On sign-out:
MsgeraPush.shared.logout()
```

## 5. Tags, consent, and notification events

`addTag`, `addTags`, `removeTag`, `removeTags`, and `getTags` cache locally and send one update after 2 seconds. `setLanguage("ar")` is stored on the subscriber. `trackEvent`, `optOut`, `optIn`, `pushSubscription` (`id`, `token`, `optedIn`), `addClickListener`, `addForegroundListener`, `addPermissionObserver`, `addSubscriptionObserver`, and `canRequestPermission` match the other SDKs. `preventDefault()` on a click skips `UIApplication.shared.open`; on a foreground event it hides the banner. Cold-start taps wait until `addClickListener`. Call `MsgeraPush.setConsentRequired(true)` before `start`, then `setConsentGiven(true)`. `deleteDevice()` removes the subscriber. `clearAllNotifications()` clears delivered and pending notifications. `groupKey` in the payload is included on the click event.

## 6. Test

1. Run your app on a physical iPhone and grant notification permission.
2. In the Msgera Dashboard, open **Subscribers**, click **Mark as test device** on your iOS subscriber, and send a test push with an image from **Compose**.

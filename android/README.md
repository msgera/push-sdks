# Msgera Push SDK for Android

Android push notifications for Msgera apps using Firebase Cloud Messaging (FCM).

## 1. Install

Add JitPack to your `settings.gradle.kts` repositories:

```kotlin
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
    }
}
```

Add the dependency to `app/build.gradle.kts` alongside your `google-services.json` configuration:

```kotlin
dependencies {
    implementation("com.github.msgera.push-sdks:android:1.1.0")
}
```

> **Small notification icon:** Add a monochrome status bar icon at `res/drawable/ic_stat_msgera.xml`. The SDK automatically uses `ic_stat_msgera` when present and falls back to your app launcher icon.

## 2. Initialize

Initialize the SDK once in `Application.onCreate()` and handle notification tap intents in your launcher `Activity`:

```kotlin
import io.msgera.push.MsgeraPush

class MainApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        MsgeraPush.setLogLevel(MsgeraPush.LogLevel.VERBOSE) // optional for debugging
        MsgeraPush.init(this, appId = "YOUR_APP_PUBLIC_ID")
    }
}
```

In your launcher `Activity`:

```kotlin
override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    MsgeraPush.handleIntent(intent)
}

override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    MsgeraPush.handleIntent(intent)
}
```

## 3. Request Permission

Trigger the permission prompt from a user action (such as an "Enable notifications" button). The SDK handles the Android 13+ permission dialog automatically via `MsgeraPermissionActivity`:

```kotlin
MsgeraPush.requestPermission(fallbackToSettings = true) { granted ->
    if (granted) {
        // Device is subscribed
    }
}
```

## 4. Login & Logout

Link the device to your authenticated user ID (pass `userHash = HMAC-SHA256(appSecret, externalUserId)` when identity verification is enabled):

```kotlin
MsgeraPush.login(externalUserId = "user_123", userHash = userHash) { error ->
    // Linked to user_123
}

// On sign-out:
MsgeraPush.logout { _ -> }
```

## 5. Tags, consent, and notification events

```kotlin
MsgeraPush.addTag("plan", "pro")
MsgeraPush.addTags(mapOf("city" to "Riyadh"))
MsgeraPush.removeTag("city")
MsgeraPush.getTags()
MsgeraPush.setLanguage("ar")
MsgeraPush.trackEvent("purchase", mapOf("sku" to "1"))
MsgeraPush.optOut()
MsgeraPush.optIn()
MsgeraPush.addClickListener { event ->
    if (event.actionId == "later") event.preventDefault()
}
MsgeraPush.addForegroundListener { event -> event.preventDefault() }
MsgeraPush.setConsentRequired(true) // before init
MsgeraPush.setConsentGiven(true)
MsgeraPush.clearAllNotifications()
MsgeraPush.removeNotification(id)
MsgeraPush.deleteDevice()
```

`pushSubscription` exposes `id`, `token`, and `optedIn`. `canRequestPermission()` is false after a permanent denial. Tag writes are sent together after 2 seconds. `groupKey` on the payload groups the notification.

## 6. Test

1. Run your app on a physical device or emulator with Google Play services and grant notification permission.
2. In the Msgera Dashboard, open your Push App → **Subscribers**, locate your device, and click **Mark as test device**.
3. Open **Compose** and click **Send test** to verify delivery.

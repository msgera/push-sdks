# Msgera Push SDK for Huawei (HMS Push Kit)

Huawei Push Kit integration for Msgera apps on Huawei devices without Google Play services.

## 1. Install

Add the Huawei Maven repository and JitPack in `settings.gradle.kts`:

```kotlin
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://developer.huawei.com/repo/") }
        maven { url = uri("https://jitpack.io") }
    }
}
```

Place `agconnect-services.json` in `app/src/main/assets/agconnect-services.json` (or configure the AGConnect plugin) and add the dependency in `app/build.gradle.kts`:

```kotlin
dependencies {
    implementation("com.github.msgera.push-sdks:android-huawei:1.1.0")
}
```

> **Small notification icon:** Add a monochrome icon at `res/drawable/ic_stat_msgera.xml`. The SDK automatically resolves `ic_stat_msgera` before falling back to the launcher icon.

## 2. Initialize

Call `init` in `Application.onCreate()`. The SDK automatically reads `client/app_id` from `agconnect-services.json` when `hmsAppId` is omitted:

```kotlin
import io.msgera.push.huawei.MsgeraHuaweiPush

class MainApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        MsgeraHuaweiPush.setLogLevel(MsgeraHuaweiPush.LogLevel.VERBOSE) // optional
        MsgeraHuaweiPush.init(this, appId = "YOUR_APP_PUBLIC_ID")
    }
}
```

In your launcher `Activity`, so taps open links and count as clicks:

```kotlin
override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    MsgeraHuaweiPush.handleIntent(intent)
}

override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    MsgeraHuaweiPush.handleIntent(intent)
}
```

## 3. Request Permission

Call `requestPermission` from a button click:

```kotlin
MsgeraHuaweiPush.requestPermission(fallbackToSettings = true) { granted ->
    if (granted) {
        // Device is subscribed
    }
}
```

## 4. Login & Logout

Link the device to your user ID (include `userHash` when identity verification is enabled):

```kotlin
MsgeraHuaweiPush.login(externalUserId = "user_123", userHash = userHash) { error ->
    // Linked to user_123
}

// On sign-out:
MsgeraHuaweiPush.logout { _ -> }
```

## 5. Tags, consent, and notification events

Same surface as the Android SDK, on `MsgeraHuaweiPush`: `addTag`, `addTags`, `removeTag`, `removeTags`, `getTags`, `setLanguage`, `trackEvent`, `optOut`, `optIn`, `addClickListener`, `addForegroundListener`, `addPermissionObserver`, `addSubscriptionObserver`, `canRequestPermission`, `setConsentRequired`, `setConsentGiven`, `deleteDevice`, `clearAllNotifications`, and `removeNotification`. Tag writes wait 2 seconds before they are sent. Call `setConsentRequired(true)` before `init` to hold every request until `setConsentGiven(true)`.

## 6. Test

1. Run the app on a Huawei device with HMS Core and accept the notification permission prompt.
2. In the Msgera Dashboard, go to **Subscribers**, mark the newly registered Huawei device as a **Test device**, and click **Send test** in the composer.

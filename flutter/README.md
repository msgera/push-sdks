# Msgera Push SDK for Flutter

Push notifications for Flutter apps on Android and iOS using Firebase Cloud Messaging and Msgera.

## 1. Install

Add `msgera_push` to your `pubspec.yaml`:

```yaml
dependencies:
  msgera_push:
    git:
      url: https://github.com/msgera/push-sdks.git
      path: flutter
      ref: 1.1.0
```

Make sure your Flutter app is configured with Firebase (`google-services.json` on Android and `GoogleService-Info.plist` on iOS).

## 2. Initialize

Initialize `MsgeraPush` after `Firebase.initializeApp()` in `main()`:

```dart
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';
import 'package:msgera_push/msgera_push.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  MsgeraPush.setLogLevel(MsgeraLogLevel.verbose); // optional for debugging
  await MsgeraPush.init(appId: 'YOUR_APP_PUBLIC_ID');

  runApp(const MyApp());
}
```

## 3. Request Permission

Ask for notification permission from a button tap:

```dart
await MsgeraPush.requestPermission(fallbackToSettings: true);
```

## 4. Login & Logout

Link the subscriber to your user ID (include `userHash` when identity verification is enabled):

```dart
await MsgeraPush.login('user_123', userHash: userHash);

// On sign-out:
await MsgeraPush.logout();
```

## 5. Tags, consent, and notification events

`addTag`, `addTags`, `removeTag`, `removeTags`, and `getTags` debounce for 2 seconds. Also: `setLanguage`, `trackEvent`, `optOut`, `optIn`, `pushSubscription`, `addClickListener`, `addForegroundListener`, `addPermissionObserver`, `addSubscriptionObserver`, `canRequestPermission`, `setConsentRequired`, `setConsentGiven`, `deleteDevice`, `clearAllNotifications`, and `removeNotification`. A click opens the launch URL unless `preventDefault()` is called. Call `setConsentRequired(true)` before `init`.

## 6. Test

1. Run the app on a physical device and tap your permission button.
2. In the Msgera Dashboard, open **Subscribers**, mark your device as a **Test device**, and click **Send test** in the composer.

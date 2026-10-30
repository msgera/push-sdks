# Msgera Push SDK for React Native

Push notifications for React Native apps on Android and iOS using `@react-native-firebase/messaging` and Msgera.

## 1. Install

Install `@msgera/push` alongside `@react-native-firebase/app` and `@react-native-firebase/messaging`:

```bash
npm install @msgera/push @react-native-firebase/app @react-native-firebase/messaging
```

Optional for foreground banners on Android:

```bash
npm install @notifee/react-native
```

## 2. Initialize

Register the background handler in `index.js` before `AppRegistry.registerComponent`, and call `init` when your app mounts:

```javascript
// index.js
import { registerBackgroundHandler } from '@msgera/push';
registerBackgroundHandler();
```

```javascript
// App.tsx
import { useEffect } from 'react';
import { init, setLogLevel } from '@msgera/push';

export default function App() {
  useEffect(() => {
    setLogLevel('verbose'); // optional for debugging
    init('YOUR_APP_PUBLIC_ID');
  }, []);
}
```

## 3. Request Permission

Call `requestPermission` from a user action:

```javascript
import { requestPermission } from '@msgera/push';

const granted = await requestPermission({ fallbackToSettings: true });
```

## 4. Login & Logout

Link the device to your user ID (pass `userHash` when identity verification is enabled):

```javascript
import { login, logout } from '@msgera/push';

await login('user_123', userHash);

// On sign-out:
await logout();
```

## 5. Tags, consent, and notification events

`addTag`, `addTags`, `removeTag`, `removeTags`, and `getTags` debounce for 2 seconds. Also: `setLanguage`, `trackEvent`, `optOut`, `optIn`, `pushSubscription`, `addClickListener`, `addForegroundListener`, `addPermissionObserver`, `addSubscriptionObserver`, `canRequestPermission`, `setConsentRequired`, `setConsentGiven`, `deleteDevice`, `clearAllNotifications`, and `removeNotification`. Clicks open with `Linking.openURL` unless `preventDefault()` is called. Call `setConsentRequired(true)` before `init`. `groupKey` on the payload sets the Android group and iOS thread when Notifee is installed.

## 6. Test

1. Launch your app on a device and grant notification permission.
2. In the Msgera Dashboard, open **Subscribers**, mark your device as a **Test device**, and use **Send test** in the composer.

# Msgera Push SDKs

Push notification SDKs for apps that send through [Msgera](https://msgera.io).
Setup guides: <https://msgera.io/docs/push>. Your app's install code, with its
app ID filled in, is on the app's **Install** tab in the Msgera dashboard.

| Platform | Folder | Install |
|---|---|---|
| Android (Firebase) | [`android`](android) | `implementation("com.github.msgera.push-sdks:android:1.1.0")` from `https://jitpack.io` |
| Huawei (Push Kit) | [`android-huawei`](android-huawei) | `implementation("com.github.msgera.push-sdks:android-huawei:1.1.0")` from `https://jitpack.io` |
| iOS | [`ios`](ios) | Swift Package Manager: `https://github.com/msgera/push-sdks`, from `1.1.0` |
| Flutter | [`flutter`](flutter) | git dependency, `path: flutter`, `ref: 1.1.0` |
| React Native | [`react-native`](react-native) | `npm install @msgera/push` |

Each folder's README has the full steps.

## License

MIT

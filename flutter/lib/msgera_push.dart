import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

const String SDK_VERSION = '1.1.0';
const String DEFAULT_API_BASE = 'https://api.msgera.io';
const String _channelId = 'msgera_default';

enum MsgeraLogLevel {
  none,
  error,
  verbose,
}

/// Call this from main(), before runApp. It must be a top-level function.
/// A background handler that is a class method is stripped in release builds,
/// and then a tap on a killed app never reaches you.
@pragma('vm:entry-point')
Future<void> msgeraMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await _report(message.data['msgeraMessageId'], 'received');
}

/// Flutter push for a Msgera app. Firebase delivers Android and iOS.
///
/// Call [MsgeraPush.init] after Firebase.initializeApp. Call
/// [MsgeraPush.requestPermission] from a button. [FirebaseMessaging.getToken]
/// asks for permission by itself, so init never calls it.
class MsgeraPush {
  MsgeraPush._();

  static const String sdkVersion = SDK_VERSION;
  static final _local = FlutterLocalNotificationsPlugin();
  static var _listening = false;
  static String? _subscriberId;
  static String? _token;
  static bool _optedInFlag = true;
  static final _seenClicks = <String>{};
  static final _clickListeners = <void Function(MsgeraClickEvent)>[];
  static final _foregroundListeners = <void Function(MsgeraForegroundEvent)>[];
  static final _permissionObservers = <void Function(bool)>[];
  static final _subscriptionObservers = <void Function(MsgeraSubscription)>[];
  static final _queuedClicks = <MsgeraClickEvent>[];
  static final _pendingTags = <String, Object?>{};
  static Timer? _tagTimer;
  static MsgeraLogLevel _logLevel = MsgeraLogLevel.error;

  static bool canRequestPermission = true;

  static void setLogLevel(MsgeraLogLevel level) {
    _logLevel = level;
  }

  static Future<void> init({
    required String appId,
    String apiBase = DEFAULT_API_BASE,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmedBase = apiBase.replaceAll(RegExp(r'/+$'), '');
    final resolvedBase = trimmedBase.isEmpty ? DEFAULT_API_BASE : trimmedBase;
    await prefs.setString('io.msgera.push.appId', appId);
    await prefs.setString('io.msgera.push.apiBase', resolvedBase);
    _subscriberId = prefs.getString('io.msgera.push.subscriberId');
    _token = prefs.getString('io.msgera.push.token');
    _optedInFlag = prefs.getBool('io.msgera.push.optedIn') ?? true;
    _logVerbose('Initialized MsgeraPush v$SDK_VERSION for app $appId');

    FirebaseMessaging.onBackgroundMessage(msgeraMessagingBackgroundHandler);
    if (_listening) return;
    _listening = true;
    await _local.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: _handleLocalResponse,
    );
    final launch = await _local.getNotificationAppLaunchDetails();
    final launchResponse = launch?.notificationResponse;
    if (launch?.didNotificationLaunchApp == true && launchResponse != null) {
      _handleLocalResponse(launchResponse);
    }
    FirebaseMessaging.instance.onTokenRefresh.listen((token) {
      unawaited(_register(token));
    });
    FirebaseMessaging.onMessage.listen(_onForeground);
    FirebaseMessaging.onMessageOpenedApp.listen(_onOpened);
    final settings = await FirebaseMessaging.instance.getNotificationSettings();
    canRequestPermission = settings.authorizationStatus != AuthorizationStatus.denied;
    _notifyPermission(settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional);
    if (await _networkAllowed()) {
      unawaited(_syncChannels());
    }
    if (settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional) {
      await _enableForegroundPresentation();
      if (await _networkAllowed() && await _optedIn()) await _registerCurrentToken();
    }
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) await _onOpened(initial);
  }

  static Future<bool> requestPermission({bool fallbackToSettings = false}) async {
    final current = await FirebaseMessaging.instance.getNotificationSettings();
    if (current.authorizationStatus == AuthorizationStatus.denied && fallbackToSettings) {
      if (Platform.isIOS) {
        final uri = Uri.tryParse('app-settings:');
        if (uri != null) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      }
    }

    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    final allowed = settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
    canRequestPermission = settings.authorizationStatus != AuthorizationStatus.denied;
    _notifyPermission(allowed);
    if (!allowed) {
      _logVerbose('Notification permission was denied');
      return false;
    }
    await _enableForegroundPresentation();
    await _registerCurrentToken();
    return true;
  }

  static Future<void> login(String externalUserId, {String? userHash}) async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString('io.msgera.push.subscriberId');
    if (id == null) {
      throw StateError('Call requestPermission before login');
    }
    await _post('/subscribers/$id/login', {
      'externalUserId': externalUserId,
      if (userHash != null) 'userHash': userHash,
    });
    if (userHash != null) await prefs.setString('io.msgera.push.userHash', userHash);
  }

  static Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString('io.msgera.push.subscriberId');
    if (id == null) return;
    await _post('/subscribers/$id/logout', {});
  }

  static MsgeraSubscription get pushSubscription => MsgeraSubscription._();

  static void addClickListener(void Function(MsgeraClickEvent) listener) {
    _clickListeners.add(listener);
    final pending = List<MsgeraClickEvent>.of(_queuedClicks);
    _queuedClicks.clear();
    for (final event in pending) {
      _dispatchClick(event);
    }
  }

  static void addForegroundListener(void Function(MsgeraForegroundEvent) listener) {
    _foregroundListeners.add(listener);
    unawaited(FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
      alert: false,
      badge: true,
      sound: false,
    ));
  }

  static void addPermissionObserver(void Function(bool granted) listener) {
    _permissionObservers.add(listener);
  }

  static void addSubscriptionObserver(void Function(MsgeraSubscription subscription) listener) {
    _subscriptionObservers.add(listener);
  }

  static Future<void> optOut() => _setOptedIn(false);
  static Future<void> optIn() => _setOptedIn(true);

  static Future<void> addTag(String key, String value) => _queueTag(key, value);
  static Future<void> addTags(Map<String, String> tags) async {
    for (final entry in tags.entries) {
      await _queueTag(entry.key, entry.value);
    }
  }

  static Future<void> removeTag(String key) => _queueTag(key, null);
  static Future<void> removeTags(List<String> keys) async {
    for (final key in keys) {
      await _queueTag(key, null);
    }
  }

  static Future<Map<String, String>> getTags() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('io.msgera.push.tags');
    if (raw == null) return {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return {};
    return decoded.map((key, value) => MapEntry(key.toString(), value.toString()));
  }

  static Future<void> setLanguage(String language) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('io.msgera.push.language', language);
    final id = prefs.getString('io.msgera.push.subscriberId');
    if (id == null) return;
    await _request('PATCH', '/subscribers/$id', {'language': language});
  }

  static Future<void> trackEvent(String name, [Map<String, Object?>? properties]) async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString('io.msgera.push.subscriberId');
    if (id == null) throw StateError('Call requestPermission before trackEvent');
    await _post('/subscribers/$id/events', {
      'name': name,
      if (properties != null) 'properties': properties,
    });
  }

  static Future<void> setConsentRequired(bool required) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('io.msgera.push.consentRequired', required);
  }

  static Future<void> setConsentGiven(bool given) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('io.msgera.push.consentGiven', given);
    if (given) await _registerCurrentToken();
  }

  static Future<void> deleteDevice() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString('io.msgera.push.subscriberId');
    if (id != null && await _networkAllowed()) {
      await _request('DELETE', '/subscribers/$id', {});
    }
    _subscriberId = null;
    _token = null;
    _optedInFlag = true;
    await prefs.remove('io.msgera.push.subscriberId');
    await prefs.remove('io.msgera.push.token');
    await prefs.remove('io.msgera.push.tags');
    await prefs.remove('io.msgera.push.userHash');
    await prefs.setBool('io.msgera.push.optedIn', true);
    _notifySubscription();
  }

  static Future<void> clearAllNotifications() => _local.cancelAll();

  static Future<void> removeNotification(int id) => _local.cancel(id);

  static Future<void> _enableForegroundPresentation() {
    return FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );
  }

  static Future<void> _registerCurrentToken() async {
    if (Platform.isIOS) {
      String? apns;
      for (var attempt = 0; attempt < 10 && apns == null; attempt++) {
        apns = await FirebaseMessaging.instance.getAPNSToken();
        if (apns == null) await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null || token.isEmpty) {
      throw StateError('Firebase did not return a token. Add the Firebase config files.');
    }
    await _register(token);
  }

  static Future<void> _register(String token) async {
    final prefs = await SharedPreferences.getInstance();
    // Re-sent daily so the server knows the device is still in use.
    final synced = prefs.getInt('io.msgera.push.syncedAt') ?? 0;
    final fresh =
        DateTime.now().millisecondsSinceEpoch - synced < 24 * 60 * 60 * 1000;
    if (prefs.getString('io.msgera.push.token') == token &&
        prefs.getString('io.msgera.push.subscriberId') != null &&
        fresh) {
      return;
    }
    if (!await _networkAllowed() || !await _optedIn()) return;
    final json = await _post('/subscribers', {
      'token': token,
      'platform': Platform.isIOS ? 'ios' : 'android',
      'transport': 'fcm',
      'language': prefs.getString('io.msgera.push.language') ?? Platform.localeName,
      'sdkVersion': SDK_VERSION,
    });
    final id = json['subscriberId'];
    if (id is String) {
      await prefs.setString('io.msgera.push.subscriberId', id);
      await prefs.setString('io.msgera.push.token', token);
      _subscriberId = id;
      _token = token;
      await prefs.setInt(
          'io.msgera.push.syncedAt', DateTime.now().millisecondsSinceEpoch);
      _logVerbose('Registered subscriber $id');
      _notifySubscription();
    }
  }

  static Future<void> _onForeground(RemoteMessage message) async {
    final data = message.data;
    final messageId = data['msgeraMessageId'];
    final event = MsgeraForegroundEvent(
      messageId: messageId,
      title: message.notification?.title ?? data['title'],
      body: message.notification?.body ?? data['body'],
      data: data,
    );
    for (final listener in _foregroundListeners) {
      listener(event);
    }
    final showOnIos = _foregroundListeners.isNotEmpty;
    if (!event.prevented && (!Platform.isIOS || showOnIos)) {
      final groupKey = data['groupKey'];
      final thread = groupKey is String && groupKey.isNotEmpty ? groupKey : null;
      final channel = (data['channelId'] ?? '').isEmpty ? _channelId : data['channelId']!;
      final buttons = _buttonRows(data['msgeraButtons'], limit: Platform.isIOS ? 4 : 2);
      final picture = await _httpsBytes(data['imageUrl']);
      final large = await _httpsBytes(data['largeIconUrl']);
      final largeBitmap = large == null ? null : ByteArrayAndroidBitmap(large);
      final icon = (data['smallIcon'] ?? '').isEmpty ? 'ic_stat_msgera' : data['smallIcon'];
      String? categoryId;
      if (Platform.isIOS && buttons.isNotEmpty) {
        categoryId = 'msgera.${buttons.map((button) => button['id']).join('.')}';
        await _local.initialize(
          InitializationSettings(
            android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
            iOS: DarwinInitializationSettings(
              requestAlertPermission: false,
              requestBadgePermission: false,
              requestSoundPermission: false,
              notificationCategories: [
                DarwinNotificationCategory(
                  categoryId,
                  actions: [
                    for (final button in buttons)
                      DarwinNotificationAction.plain(button['id']!, button['text']!),
                  ],
                ),
              ],
            ),
          ),
          onDidReceiveNotificationResponse: _handleLocalResponse,
        );
      }
      final payload = jsonEncode({
        'messageId': messageId ?? '',
        'url': data['clickUrl'] ?? '',
        'title': event.title ?? '',
        'body': event.body ?? '',
        'data': data,
        'buttons': {
          for (final button in buttons)
            if ((button['url'] ?? '').isNotEmpty) button['id']!: button['url']!,
        },
      });
      final id = (messageId ?? message.hashCode.toString()).hashCode;
      Future<void> show(String? iconName) {
        return _local.show(
          id,
          event.title,
          event.body,
          NotificationDetails(
            android: AndroidNotificationDetails(
              channel,
              'Notifications',
              importance: Importance.high,
              priority: Priority.high,
              groupKey: thread,
              icon: iconName,
              color: _accentColor(data['accentColor']),
              largeIcon: largeBitmap,
              styleInformation: picture == null
                  ? null
                  : BigPictureStyleInformation(
                      ByteArrayAndroidBitmap(picture),
                      largeIcon: largeBitmap,
                    ),
              actions: [
                for (final button in buttons.take(2))
                  AndroidNotificationAction(
                    button['id']!,
                    button['text']!,
                    showsUserInterface: true,
                  ),
              ],
            ),
            iOS: DarwinNotificationDetails(
              threadIdentifier: thread,
              categoryIdentifier: categoryId,
            ),
          ),
          payload: payload,
        );
      }
      try {
        await show(icon);
      } catch (error) {
        if (icon != 'ic_stat_msgera') {
          _logError('Could not show notification', error);
        } else {
          await show(null);
        }
      }
    }
    await _report(messageId, 'received');
  }

  static Future<void> _onOpened(RemoteMessage message) async {
    final data = message.data;
    await _openClick(
      data['msgeraMessageId'],
      data['clickUrl'],
      title: message.notification?.title ?? data['title'],
      body: message.notification?.body ?? data['body'],
      data: data,
    );
  }

  static void _handleLocalResponse(NotificationResponse response) {
    final parsed = _payload(response.payload);
    final messageId = parsed['messageId'] as String? ?? '';
    if (messageId.isEmpty) return;
    final buttons = parsed['buttons'];
    final action = response.actionId;
    var url = parsed['url'] as String?;
    if (action != null &&
        action.isNotEmpty &&
        buttons is Map &&
        buttons[action] is String &&
        (buttons[action] as String).isNotEmpty) {
      url = buttons[action] as String;
    }
    final rawData = parsed['data'];
    final data = rawData is Map
        ? rawData.map((key, value) => MapEntry(key.toString(), value.toString()))
        : <String, String>{'clickUrl': url ?? ''};
    unawaited(_openClick(
      messageId,
      url,
      title: parsed['title'] as String?,
      body: parsed['body'] as String?,
      actionId: action == null || action.isEmpty ? null : action,
      data: data,
    ));
  }

  static Future<void> _openClick(
    String? messageId,
    String? url, {
    String? title,
    String? body,
    String? actionId,
    Map<String, String>? data,
  }) async {
    if (messageId == null || messageId.isEmpty) return;
    final seenKey = '$messageId:${actionId ?? ''}';
    if (!_seenClicks.add(seenKey)) return;
    await _report(messageId, 'clicked');
    final event = MsgeraClickEvent(
      messageId: messageId,
      title: title,
      body: body,
      data: data ?? {'clickUrl': url ?? ''},
      launchUrl: url,
      actionId: actionId,
    );
    if (_clickListeners.isEmpty) {
      _queuedClicks.add(event);
      return;
    }
    await _dispatchClick(event);
  }

  static Future<void> _dispatchClick(MsgeraClickEvent event) async {
    for (final listener in _clickListeners) {
      listener(event);
    }
    final uri = event.launchUrl == null ? null : Uri.tryParse(event.launchUrl!);
    if (!event.prevented && uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  static Future<void> _setOptedIn(bool optedIn) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('io.msgera.push.optedIn', optedIn);
    _optedInFlag = optedIn;
    _notifySubscription();
    final id = prefs.getString('io.msgera.push.subscriberId');
    if (id == null) return;
    await _request('PATCH', '/subscribers/$id/subscription', {'optedIn': optedIn});
    if (optedIn) await _registerCurrentToken();
  }

  static Future<void> _queueTag(String key, String? value) async {
    final tags = await getTags();
    if (value == null) {
      tags.remove(key);
    } else {
      tags[key] = value;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('io.msgera.push.tags', jsonEncode(tags));
    _pendingTags[key] = value;
    _tagTimer?.cancel();
    _tagTimer = Timer(const Duration(seconds: 2), () {
      unawaited(_flushTags());
    });
  }

  static Future<void> _flushTags() async {
    if (!await _networkAllowed()) return;
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString('io.msgera.push.subscriberId');
    if (id == null || _pendingTags.isEmpty) return;
    final patch = Map<String, Object?>.of(_pendingTags);
    _pendingTags.clear();
    await _request('PATCH', '/subscribers/$id/tags', {
      'tags': patch,
      if (prefs.getString('io.msgera.push.userHash') != null)
        'userHash': prefs.getString('io.msgera.push.userHash'),
    });
  }

  static void _notifyPermission(bool granted) {
    for (final listener in _permissionObservers) {
      listener(granted);
    }
  }

  static void _notifySubscription() {
    final state = pushSubscription;
    for (final listener in _subscriptionObservers) {
      listener(state);
    }
  }

  static void _logVerbose(String message) {
    if (_logLevel == MsgeraLogLevel.verbose) {
      developer.log(message, name: 'MsgeraPush');
    }
  }

  static void _logError(String message, [Object? error]) {
    if (_logLevel == MsgeraLogLevel.error || _logLevel == MsgeraLogLevel.verbose) {
      developer.log(message, name: 'MsgeraPush', error: error, level: 1000);
    }
  }
}

Future<void> _report(String? messageId, String type) async {
  if (messageId == null || messageId.isEmpty) return;
  final prefs = await SharedPreferences.getInstance();
  final id = prefs.getString('io.msgera.push.subscriberId');
  if (id == null) return;
  try {
    await _post('/subscribers/$id/events', {'messageId': messageId, 'type': type});
  } catch (error) {
    MsgeraPush._logError('Event report ($type) failed', error);
  }
}

Future<bool> _networkAllowed() async {
  final prefs = await SharedPreferences.getInstance();
  final required = prefs.getBool('io.msgera.push.consentRequired') ?? false;
  if (!required) return true;
  return prefs.getBool('io.msgera.push.consentGiven') ?? false;
}

Future<bool> _optedIn() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool('io.msgera.push.optedIn') ?? true;
}

Color? _accentColor(String? raw) {
  if (raw == null || !RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(raw)) return null;
  return Color(int.parse('FF${raw.substring(1)}', radix: 16));
}

Future<Uint8List?> _httpsBytes(String? url) async {
  if (url == null || !url.startsWith('https://')) return null;
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close().timeout(const Duration(seconds: 4));
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 4))) {
      builder.add(chunk);
      if (builder.length > 2 * 1024 * 1024) return null;
    }
    final bytes = builder.takeBytes();
    return bytes.isEmpty ? null : bytes;
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

List<Map<String, String>> _buttonRows(String? raw, {int limit = 2}) {
  if (raw == null || raw.isEmpty) return [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return [];
    return [
      for (final item in decoded.take(limit))
        if (item is Map && item['id'] is String)
          {
            'id': item['id'] as String,
            'text': (item['text'] ?? item['title'] ?? item['id']).toString(),
            'url': (item['url'] ?? '').toString(),
          },
    ];
  } catch (_) {
    return [];
  }
}

Map<String, dynamic> _payload(String? raw) {
  if (raw == null || raw.isEmpty) return {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return decoded.map((key, value) => MapEntry(key.toString(), value));
  } catch (_) {}
  final parts = raw.split('\n');
  return {
    'messageId': parts.isNotEmpty ? parts.first : '',
    'url': parts.length > 1 ? parts[1] : '',
  };
}

Future<void> _syncChannels() async {
  try {
    final json = await _request('GET', '/config', {});
    final rows = json['channels'];
    if (rows is! List) return;
    final android = MsgeraPush._local
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;
    for (final row in rows) {
      if (row is! Map) continue;
      final id = row['channelId'];
      final name = row['name'];
      if (id is! String || name is! String || id.isEmpty) continue;
      final key = row['key'];
      final version = row['version'];
      if (key is String && version is num && version > 1) {
        for (var older = 1; older < version.toInt(); older++) {
          await android.deleteNotificationChannel('${key}_v$older');
        }
      }
      final importance = switch (row['importance']) {
        'low' => Importance.low,
        'default' => Importance.defaultImportance,
        _ => Importance.high,
      };
      final sound = row['sound'];
      await android.createNotificationChannel(AndroidNotificationChannel(
        id,
        name,
        description: row['description'] is String ? row['description'] as String : null,
        importance: importance,
        sound: sound is String && sound != 'default' && sound != 'none' && sound.isNotEmpty
            ? RawResourceAndroidNotificationSound(sound.split('.').first)
            : null,
        playSound: sound != 'none',
      ));
    }
  } catch (error) {
    MsgeraPush._logError('Channel sync failed', error);
  }
}

Future<Map<String, dynamic>> _post(String path, Map<String, Object?> body) {
  return _request('POST', path, body);
}

Future<Map<String, dynamic>> _request(
  String method,
  String path,
  Map<String, Object?> body,
) async {
  if (!await _networkAllowed()) {
    throw StateError('Consent is required before Msgera push can send data');
  }
  final prefs = await SharedPreferences.getInstance();
  final storedApi = prefs.getString('io.msgera.push.apiBase');
  final api = (storedApi == null || storedApi.isEmpty) ? DEFAULT_API_BASE : storedApi;
  final appId = prefs.getString('io.msgera.push.appId');
  if (appId == null) {
    throw StateError('Call MsgeraPush.init first');
  }
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, Uri.parse('$api/v1/public/push/$appId$path'));
    request.headers.set('Content-Type', 'application/json');
    request.add(utf8.encode(jsonEncode(body)));
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final errMessage = text.isEmpty ? 'Push request failed (${response.statusCode})' : text;
      MsgeraPush._logError('Request $path failed: $errMessage');
      throw StateError(errMessage);
    }
    if (text.isEmpty) return {};
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : {};
  } finally {
    client.close();
  }
}

class MsgeraClickEvent {
  MsgeraClickEvent({
    required this.messageId,
    required this.title,
    required this.body,
    required this.data,
    required this.launchUrl,
    required this.actionId,
  });

  final String? messageId;
  final String? title;
  final String? body;
  final Map<String, String> data;
  final String? launchUrl;
  final String? actionId;
  bool prevented = false;
  void preventDefault() => prevented = true;
}

class MsgeraForegroundEvent {
  MsgeraForegroundEvent({
    required this.messageId,
    required this.title,
    required this.body,
    required this.data,
  });

  final String? messageId;
  final String? title;
  final String? body;
  final Map<String, String> data;
  bool prevented = false;
  void preventDefault() => prevented = true;
}

class MsgeraSubscription {
  MsgeraSubscription._();
  String? get id => MsgeraPush._subscriberId;
  String? get token => MsgeraPush._token;
  bool get optedIn => MsgeraPush._optedInFlag;
}

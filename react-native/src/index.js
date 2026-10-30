const { Platform, PermissionsAndroid, Linking } = require('react-native');
const {
  getMessaging,
  getToken,
  onTokenRefresh,
  onMessage,
  onNotificationOpenedApp,
  getInitialNotification,
  setBackgroundMessageHandler,
  requestPermission: requestMessagingPermission,
  AuthorizationStatus,
  getAPNSToken,
  setAutoInitEnabled,
} = require('@react-native-firebase/messaging');

const SDK_VERSION = '1.1.0';
const DEFAULT_API_BASE = 'https://api.msgera.io';
const seenClicks = new Set();
let config = null;
let logLevel = 'error';
const clickListeners = [];
const foregroundListeners = [];
const permissionObservers = [];
const subscriptionObservers = [];
const queuedClicks = [];
let pendingTags = {};
let tagTimer = null;
let consentRequired = false;
let consentGiven = false;
let optedIn = true;

function networkAllowed() {
  return !consentRequired || consentGiven;
}

function notifySubscription() {
  const state = pushSubscription();
  subscriptionObservers.forEach((listener) => listener(state));
}

function notifyPermission(granted) {
  permissionObservers.forEach((listener) => listener(granted));
}

function javaHash(value) {
  let hash = 0;
  const text = value || '';
  for (let index = 0; index < text.length; index += 1) {
    hash = (Math.imul(hash, 31) + text.charCodeAt(index)) | 0;
  }
  return hash;
}

function logVerbose(message) {
  if (logLevel === 'verbose') {
    console.log(`[MsgeraPush] ${message}`);
  }
}

function logError(message, error) {
  if (logLevel === 'error' || logLevel === 'verbose') {
    console.error(`[MsgeraPush] ${message}`, error || '');
  }
}

function setLogLevel(level) {
  const normalized = String(level || '').toLowerCase();
  if (normalized === 'none' || normalized === 'error' || normalized === 'verbose') {
    logLevel = normalized;
  }
}

function base() {
  if (!config) throw new Error('Call init before using Msgera push');
  const raw = (config.apiBase || DEFAULT_API_BASE).replace(/\/+$/, '');
  return raw || DEFAULT_API_BASE;
}

async function post(path, body) {
  return request('POST', path, body);
}

async function request(method, path, body) {
  if (!networkAllowed()) throw new Error('Consent is required before Msgera push can send data');
  const response = await fetch(`${base()}/v1/public/push/${config.appId}${path}`, {
    method,
    headers: { 'Content-Type': 'application/json' },
    body: method === 'GET' || method === 'DELETE' ? undefined : JSON.stringify(body || {}),
  });
  const text = await response.text();
  if (!response.ok) {
    const errText = text || `Push request failed (${response.status})`;
    logError(`Request ${path} failed: ${errText}`);
    throw new Error(errText);
  }
  return text ? JSON.parse(text) : {};
}

async function register(token) {
  if (!networkAllowed() || !optedIn) return;
  if (config.token === token && config.subscriberId) return;
  const json = await post('/subscribers', {
    token,
    platform: Platform.OS === 'ios' ? 'ios' : 'android',
    transport: 'fcm',
    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    sdkVersion: SDK_VERSION,
  });
  config.subscriberId = json.subscriberId;
  config.token = token;
  logVerbose(`Registered subscriber ${json.subscriberId}`);
  notifySubscription();
  if (Object.keys(pendingTags).length) scheduleTagFlush();
}

async function currentToken() {
  if (Platform.OS === 'ios') {
    let apns = null;
    for (let attempt = 0; attempt < 10 && !apns; attempt += 1) {
      apns = await getAPNSToken(getMessaging());
      if (!apns) await new Promise((resolve) => setTimeout(resolve, 300));
    }
  }
  const token = await getToken(getMessaging());
  if (!token) throw new Error('Firebase did not return a token. Add the Firebase config files.');
  await register(token);
}

async function report(messageId, type) {
  if (!messageId || !config?.subscriberId) return;
  await post(`/subscribers/${config.subscriberId}/events`, { messageId, type }).catch((err) => {
    logError(`Event report (${type}) failed`, err);
  });
}

function pushSubscription() {
  return {
    id: config?.subscriberId || null,
    token: config?.token || null,
    optedIn,
  };
}

function dispatchClick(event) {
  clickListeners.forEach((listener) => listener(event));
  if (!event.prevented && event.launchUrl) {
    Linking.openURL(event.launchUrl).catch(() => undefined);
  }
}

async function openClick(message, actionId) {
  const data = message?.data || {};
  const messageId = data.msgeraMessageId;
  const resolvedAction = actionId && actionId !== 'default' ? actionId : data.actionId || null;
  const seenKey = `${messageId || ''}:${resolvedAction || ''}`;
  if (!messageId || seenClicks.has(seenKey)) return;
  seenClicks.add(seenKey);
  await report(messageId, 'clicked');
  let launchUrl = data.clickUrl || null;
  if (resolvedAction) {
    const match = parseButtons(data.msgeraButtons, 4).find((button) => button.id === resolvedAction);
    if (match && match.url) launchUrl = match.url;
  }
  const event = {
    messageId,
    title: message.notification?.title || data.title || null,
    body: message.notification?.body || data.body || null,
    data,
    launchUrl,
    actionId: resolvedAction,
    prevented: false,
    preventDefault() {
      this.prevented = true;
    },
  };
  if (!clickListeners.length) {
    queuedClicks.push(event);
    return;
  }
  dispatchClick(event);
}

function parseButtons(raw, limit = 2) {
  if (!raw) return [];
  try {
    const rows = JSON.parse(raw);
    if (!Array.isArray(rows)) return [];
    return rows.slice(0, limit).flatMap((row) => {
      if (!row || typeof row.id !== 'string') return [];
      return [{ id: row.id, text: row.text || row.title || row.id, url: row.url || '' }];
    });
  } catch {
    return [];
  }
}

async function syncChannels() {
  let notifee;
  try {
    notifee = require('@notifee/react-native').default;
  } catch {
    return;
  }
  const config = await request('GET', '/config');
  const rows = Array.isArray(config.channels) ? config.channels : [];
  for (const row of rows) {
    if (!row || !row.channelId || !row.name) continue;
    if (row.key && row.version > 1) {
      for (let older = 1; older < row.version; older += 1) {
        await notifee.deleteChannel(`${row.key}_v${older}`).catch(() => undefined);
      }
    }
    const importance = row.importance === 'low' ? 2 : row.importance === 'default' ? 3 : 4;
    await notifee.createChannel({
      id: row.channelId,
      name: row.name,
      description: row.description || undefined,
      importance,
      sound: row.sound && row.sound !== 'default' && row.sound !== 'none' ? row.sound : undefined,
    });
  }
}

async function showForeground(message) {
  const data = message.data || {};
  const event = {
    messageId: data.msgeraMessageId || null,
    title: message.notification?.title || data.title || null,
    body: message.notification?.body || data.body || null,
    data,
    prevented: false,
    preventDefault() {
      this.prevented = true;
    },
  };
  foregroundListeners.forEach((listener) => listener(event));
  if (event.prevented) return;
  let notifee;
  try {
    notifee = require('@notifee/react-native').default;
  } catch {
    return;
  }
  const channelId = data.channelId || (await notifee.createChannel({
    id: 'msgera_default',
    name: 'Notifications',
    importance: 4,
  }));
  const buttons = parseButtons(data.msgeraButtons, Platform.OS === 'ios' ? 4 : 2);
  let iosCategoryId;
  if (Platform.OS === 'ios' && buttons.length && typeof notifee.setNotificationCategories === 'function') {
    iosCategoryId = `msgera.${buttons.map((button) => button.id).join('.')}`;
    const existing = typeof notifee.getNotificationCategories === 'function'
      ? await notifee.getNotificationCategories().catch(() => [])
      : [];
    const next = (existing || []).filter((row) => row && row.id !== iosCategoryId);
    next.push({
      id: iosCategoryId,
      actions: buttons.map((button) => ({ id: button.id, title: button.text })),
    });
    await notifee.setNotificationCategories(next);
  }
  await notifee.displayNotification({
    id: String(javaHash(data.msgeraMessageId || event.title || 'msgera')),
    title: event.title,
    body: event.body,
    data: message.data,
    android: {
      channelId,
      smallIcon: data.smallIcon || 'ic_stat_msgera',
      pressAction: { id: 'default' },
      ...(data.groupKey ? { groupId: data.groupKey } : {}),
      ...(data.largeIconUrl ? { largeIcon: data.largeIconUrl } : {}),
      ...(data.accentColor ? { color: data.accentColor } : {}),
      ...(data.imageUrl ? { style: { type: 0, picture: data.imageUrl } } : {}),
      ...(buttons.length
        ? {
            actions: buttons.slice(0, 2).map((button) => ({
              title: button.text,
              pressAction: { id: button.id, launchActivity: 'default' },
            })),
          }
        : {}),
    },
    ios: {
      ...(data.groupKey ? { threadId: data.groupKey } : {}),
      ...(iosCategoryId ? { categoryId: iosCategoryId } : {}),
    },
  });
}

function notifeeClick(type, detail) {
  if (type !== 1 && type !== 2) return;
  const notification = detail?.notification || {};
  const actionId = type === 2 ? detail?.pressAction?.id : null;
  openClick({ data: notification.data || {}, notification }, actionId).catch(() => undefined);
}

function attachNotifeeClicks() {
  let notifee;
  try {
    notifee = require('@notifee/react-native').default;
  } catch {
    return;
  }
  if (attachNotifeeClicks.done) return;
  attachNotifeeClicks.done = true;
  notifee.onForegroundEvent(({ type, detail }) => notifeeClick(type, detail));
  notifee.getInitialNotification().then((initial) => {
    if (!initial?.notification) return;
    const actionId = initial.pressAction?.id;
    openClick(
      { data: initial.notification.data || {}, notification: initial.notification },
      actionId,
    ).catch(() => undefined);
  }).catch(() => undefined);
}

function registerBackgroundHandler() {
  setBackgroundMessageHandler(getMessaging(), async (message) => {
    await report(message?.data?.msgeraMessageId, 'received');
  });
  try {
    const notifee = require('@notifee/react-native').default;
    notifee.onBackgroundEvent(async ({ type, detail }) => {
      notifeeClick(type, detail);
    });
  } catch {
    /* notifee is optional */
  }
}

async function init(appIdOrOptions, apiBase = DEFAULT_API_BASE) {
  let resolvedAppId = appIdOrOptions;
  let resolvedApiBase = apiBase || DEFAULT_API_BASE;
  if (appIdOrOptions && typeof appIdOrOptions === 'object') {
    resolvedAppId = appIdOrOptions.appId;
    resolvedApiBase = appIdOrOptions.apiBase || DEFAULT_API_BASE;
  }
  config = {
    appId: resolvedAppId,
    apiBase: resolvedApiBase,
    subscriberId: config?.subscriberId || null,
    token: config?.token || null,
    tags: config?.tags || {},
    userHash: config?.userHash,
  };
  logVerbose(`Initialized MsgeraPush v${SDK_VERSION} for app ${resolvedAppId}`);
  if (networkAllowed()) syncChannels().catch((err) => logError('Channel sync failed', err));
  // Fetching a token asks for permission on its own. Init must not do that.
  await setAutoInitEnabled(getMessaging(), true);
  onTokenRefresh(getMessaging(), (token) => {
    register(token).catch((err) => logError('Token refresh failed', err));
  });
  onMessage(getMessaging(), async (message) => {
    await showForeground(message);
    await report(message?.data?.msgeraMessageId, 'received');
  });
  onNotificationOpenedApp(getMessaging(), (message) => {
    openClick(message).catch(() => undefined);
  });
  attachNotifeeClicks();
  const initial = await getInitialNotification(getMessaging());
  if (initial) await openClick(initial);
}

async function requestPermission(options) {
  const fallbackToSettings =
    typeof options === 'boolean' ? options : Boolean(options && options.fallbackToSettings);

  if (Platform.OS === 'android' && Platform.Version >= 33) {
    const result = await PermissionsAndroid.request(
      PermissionsAndroid.PERMISSIONS.POST_NOTIFICATIONS,
    );
    if (result !== PermissionsAndroid.RESULTS.GRANTED) {
      notifyPermission(false);
      if (fallbackToSettings && result === PermissionsAndroid.RESULTS.NEVER_ASK_AGAIN && Linking.openSettings) {
        await Linking.openSettings().catch(() => undefined);
      }
      return false;
    }
  }
  const status = await requestMessagingPermission(getMessaging());
  const allowed =
    status === AuthorizationStatus.AUTHORIZED ||
    status === AuthorizationStatus.PROVISIONAL;
  notifyPermission(Platform.OS === 'android' ? true : allowed);
  if (!allowed && Platform.OS === 'ios') {
    if (fallbackToSettings && Linking.openSettings) {
      await Linking.openSettings().catch(() => undefined);
    }
    return false;
  }
  await currentToken();
  return true;
}

async function login(externalUserId, userHash) {
  if (!config?.subscriberId) throw new Error('Call requestPermission before login');
  await post(`/subscribers/${config.subscriberId}/login`, {
    externalUserId,
    ...(userHash ? { userHash } : {}),
  });
  if (userHash) config.userHash = userHash;
}

function queueTag(key, value) {
  config.tags = config.tags || {};
  if (value == null) delete config.tags[key];
  else config.tags[key] = value;
  pendingTags[key] = value;
  scheduleTagFlush();
}

function scheduleTagFlush() {
  if (tagTimer) clearTimeout(tagTimer);
  tagTimer = setTimeout(() => {
    tagTimer = null;
    flushTags().catch((error) => logError('Tag update failed', error));
  }, 2000);
}

async function flushTags() {
  if (!networkAllowed() || !config?.subscriberId || !Object.keys(pendingTags).length) return;
  const tags = pendingTags;
  pendingTags = {};
  await request('PATCH', `/subscribers/${config.subscriberId}/tags`, {
    tags,
    ...(config.userHash ? { userHash: config.userHash } : {}),
  });
}

function addClickListener(listener) {
  clickListeners.push(listener);
  const pending = queuedClicks.splice(0, queuedClicks.length);
  pending.forEach((event) => dispatchClick(event));
}

function addForegroundListener(listener) {
  foregroundListeners.push(listener);
}

function addPermissionObserver(listener) {
  permissionObservers.push(listener);
}

function addSubscriptionObserver(listener) {
  subscriptionObservers.push(listener);
}

async function canRequestPermission() {
  try {
    const messaging = require('@react-native-firebase/messaging');
    if (typeof messaging.hasPermission === 'function') {
      const status = await messaging.hasPermission(getMessaging());
      return status !== AuthorizationStatus.DENIED;
    }
  } catch {
    /* older messaging builds only expose the request call */
  }
  if (Platform.OS === 'android' && Platform.Version >= 33) {
    return PermissionsAndroid.check(PermissionsAndroid.PERMISSIONS.POST_NOTIFICATIONS);
  }
  return true;
}

async function optOut() {
  optedIn = false;
  notifySubscription();
  if (config?.subscriberId) {
    await request('PATCH', `/subscribers/${config.subscriberId}/subscription`, { optedIn: false });
  }
}

async function optIn() {
  optedIn = true;
  notifySubscription();
  if (config?.subscriberId) {
    await request('PATCH', `/subscribers/${config.subscriberId}/subscription`, { optedIn: true });
  }
  await currentToken();
}

function addTag(key, value) {
  queueTag(key, value);
}
function addTags(tags) {
  Object.keys(tags || {}).forEach((key) => queueTag(key, tags[key]));
}
function removeTag(key) {
  queueTag(key, null);
}
function removeTags(keys) {
  (keys || []).forEach((key) => queueTag(key, null));
}
function getTags() {
  return { ...(config?.tags || {}) };
}

async function setLanguage(language) {
  config.language = language;
  if (!config?.subscriberId) return;
  await request('PATCH', `/subscribers/${config.subscriberId}`, { language });
}

async function trackEvent(name, properties) {
  if (!config?.subscriberId) throw new Error('Call requestPermission before trackEvent');
  await post(`/subscribers/${config.subscriberId}/events`, {
    name,
    ...(properties ? { properties } : {}),
  });
}

function setConsentRequired(required) {
  consentRequired = !!required;
}

function setConsentGiven(given) {
  consentGiven = !!given;
  if (consentGiven) currentToken().catch((error) => logError('Consent flush failed', error));
}

async function deleteDevice() {
  if (config?.subscriberId && networkAllowed()) {
    await request('DELETE', `/subscribers/${config.subscriberId}`, {});
  }
  if (config) {
    config.subscriberId = null;
    config.token = null;
    config.tags = {};
    config.userHash = null;
  }
  pendingTags = {};
  optedIn = true;
  notifySubscription();
}

async function clearAllNotifications() {
  try {
    const notifee = require('@notifee/react-native').default;
    await notifee.cancelAllNotifications();
  } catch {
    /* notifee is optional */
  }
}

async function removeNotification(id) {
  if (Platform.OS !== 'android') return;
  try {
    const notifee = require('@notifee/react-native').default;
    await notifee.cancelNotification(String(id));
  } catch {
    /* notifee is optional */
  }
}

async function logout() {
  if (!config?.subscriberId) return;
  await post(`/subscribers/${config.subscriberId}/logout`, {});
}

const MsgeraPush = {
  SDK_VERSION,
  DEFAULT_API_BASE,
  init,
  requestPermission,
  login,
  logout,
  setLogLevel,
  registerBackgroundHandler,
  pushSubscription,
  addClickListener,
  addForegroundListener,
  addPermissionObserver,
  addSubscriptionObserver,
  canRequestPermission,
  optOut,
  optIn,
  addTag,
  addTags,
  removeTag,
  removeTags,
  getTags,
  setLanguage,
  trackEvent,
  setConsentRequired,
  setConsentGiven,
  deleteDevice,
  clearAllNotifications,
  removeNotification,
};

module.exports = {
  ...MsgeraPush,
  MsgeraPush,
};

export type Done = (error?: Error) => void;
export type LogLevel = 'none' | 'error' | 'verbose';

export interface RequestPermissionOptions {
  fallbackToSettings?: boolean;
}

export interface InitOptions {
  appId: string;
  apiBase?: string;
}

export const SDK_VERSION: string;
export const DEFAULT_API_BASE: string;

export function init(appId: string, apiBase?: string): Promise<void>;
export function init(options: InitOptions): Promise<void>;
export function requestPermission(fallbackToSettings?: boolean | RequestPermissionOptions): Promise<boolean>;
export function login(externalUserId: string, userHash?: string): Promise<void>;
export function logout(): Promise<void>;
export function setLogLevel(level: LogLevel): void;

export interface PushSubscriptionState {
  id: string | null;
  token: string | null;
  optedIn: boolean;
}

export interface ClickEvent {
  messageId: string | null;
  title: string | null;
  body: string | null;
  data: Record<string, string>;
  launchUrl: string | null;
  actionId: string | null;
  preventDefault(): void;
}

export interface ForegroundEvent {
  messageId: string | null;
  title: string | null;
  body: string | null;
  data: Record<string, string>;
  preventDefault(): void;
}

export function pushSubscription(): PushSubscriptionState;
export function addClickListener(listener: (event: ClickEvent) => void): void;
export function addForegroundListener(listener: (event: ForegroundEvent) => void): void;
export function addPermissionObserver(listener: (granted: boolean) => void): void;
export function addSubscriptionObserver(listener: (subscription: PushSubscriptionState) => void): void;
export function canRequestPermission(): Promise<boolean>;
export function optOut(): Promise<void>;
export function optIn(): Promise<void>;
export function addTag(key: string, value: string): void;
export function addTags(tags: Record<string, string>): void;
export function removeTag(key: string): void;
export function removeTags(keys: string[]): void;
export function getTags(): Record<string, string>;
export function setLanguage(language: string): Promise<void>;
export function trackEvent(name: string, properties?: Record<string, unknown>): Promise<void>;
export function setConsentRequired(required: boolean): void;
export function setConsentGiven(given: boolean): void;
export function deleteDevice(): Promise<void>;
export function clearAllNotifications(): Promise<void>;
export function removeNotification(id: number): Promise<void>;

/** Call from index.js, before AppRegistry. A handler registered later misses a tap that launched a killed app. */
export function registerBackgroundHandler(): void;

export const MsgeraPush: {
  SDK_VERSION: string;
  DEFAULT_API_BASE: string;
  init: typeof init;
  requestPermission: typeof requestPermission;
  login: typeof login;
  logout: typeof logout;
  setLogLevel: typeof setLogLevel;
  registerBackgroundHandler: typeof registerBackgroundHandler;
  pushSubscription: typeof pushSubscription;
  addClickListener: typeof addClickListener;
  addForegroundListener: typeof addForegroundListener;
  addPermissionObserver: typeof addPermissionObserver;
  addSubscriptionObserver: typeof addSubscriptionObserver;
  canRequestPermission: typeof canRequestPermission;
  optOut: typeof optOut;
  optIn: typeof optIn;
  addTag: typeof addTag;
  addTags: typeof addTags;
  removeTag: typeof removeTag;
  removeTags: typeof removeTags;
  getTags: typeof getTags;
  setLanguage: typeof setLanguage;
  trackEvent: typeof trackEvent;
  setConsentRequired: typeof setConsentRequired;
  setConsentGiven: typeof setConsentGiven;
  deleteDevice: typeof deleteDevice;
  clearAllNotifications: typeof clearAllNotifications;
  removeNotification: typeof removeNotification;
};

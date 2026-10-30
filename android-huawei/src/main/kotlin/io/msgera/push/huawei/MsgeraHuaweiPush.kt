package io.msgera.push.huawei

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.huawei.hms.aaid.HmsInstanceId
import com.huawei.hms.common.ApiException
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors

/**
 * Huawei push for phones without Google services.
 *
 * Call [init] from Application.onCreate. Call [requestPermission] from a
 * button. [HmsInstanceId.getToken] blocks, so it never runs on the main
 * thread. An empty token is normal: Push Kit delivers it later through
 * [MsgeraHmsService.onNewToken]. Do not register a second HmsMessageService.
 */
object MsgeraHuaweiPush {
    const val CHANNEL_ID = "msgera_default"
    const val EXTRA_MESSAGE_ID = "msgeraMessageId"
    const val EXTRA_CLICK_URL = "clickUrl"
    const val EXTRA_TITLE = "msgeraTitle"
    const val EXTRA_BODY = "msgeraBody"
    const val EXTRA_DATA = "msgeraData"
    const val EXTRA_ACTION_ID = "msgeraActionId"
    const val SDK_VERSION = "1.1.0"
    const val DEFAULT_API_BASE = "https://api.msgera.io"

    private const val LOG_TAG = "MsgeraHuaweiPush"
    private const val PREFS = "io.msgera.push.huawei"
    private const val KEY_APP = "appId"
    private const val KEY_API = "apiBase"
    private const val KEY_HMS = "hmsAppId"
    private const val KEY_SUBSCRIBER = "subscriberId"
    private const val KEY_TOKEN = "token"
    private const val KEY_SYNCED = "syncedAt"
    private const val KEY_PERMISSION_ASKED = "permissionAsked"
    private const val KEY_TAGS = "tags"
    private const val KEY_LANGUAGE = "language"
    private const val KEY_USER_HASH = "userHash"
    private const val KEY_OPTED_IN = "optedIn"
    private const val KEY_CONSENT_REQUIRED = "consentRequired"
    private const val KEY_CONSENT_GIVEN = "consentGiven"
    // Re-sent daily so the server knows the device is still in use.
    private const val RESYNC_MS = 24 * 60 * 60 * 1000L

    enum class LogLevel {
        NONE,
        ERROR,
        VERBOSE,
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var appContext: Context
    private var pendingPermission: PermissionResult? = null
    @Volatile
    private var logLevel: LogLevel = LogLevel.ERROR
    @Volatile
    private var consentRequiredMem: Boolean? = null
    @Volatile
    private var consentGivenMem: Boolean? = null
    private val clickListeners = CopyOnWriteArrayList<ClickListener>()
    private val foregroundListeners = CopyOnWriteArrayList<ForegroundListener>()
    private val permissionObservers = CopyOnWriteArrayList<PermissionObserver>()
    private val subscriptionObservers = CopyOnWriteArrayList<SubscriptionObserver>()
    private val queuedClicks = ArrayDeque<ClickEvent>()
    private val pendingTagPatch = JSONObject()
    private var tagFlushPosted = false
    private val tagFlush = Runnable {
        tagFlushPosted = false
        executor.execute { flushTagsNow() }
    }

    class ClickEvent(
        val messageId: String?,
        val title: String?,
        val body: String?,
        val data: Map<String, String>,
        val launchUrl: String?,
        val actionId: String?,
    ) {
        private var prevented = false
        fun preventDefault() { prevented = true }
        internal fun wasPrevented() = prevented
    }

    class ForegroundEvent(
        val messageId: String?,
        val title: String?,
        val body: String?,
        val data: Map<String, String>,
    ) {
        private var prevented = false
        fun preventDefault() { prevented = true }
        internal fun wasPrevented() = prevented
    }

    data class SubscriptionState(val id: String?, val token: String?, val optedIn: Boolean)

    fun interface ClickListener { fun onClick(event: ClickEvent) }
    fun interface ForegroundListener { fun onForeground(event: ForegroundEvent) }
    fun interface PermissionObserver { fun onChange(granted: Boolean) }
    fun interface SubscriptionObserver { fun onChange(subscription: SubscriptionState) }

    fun interface Done {
        fun onComplete(error: Exception?)
    }

    fun interface PermissionResult {
        fun onResult(granted: Boolean)
    }

    @JvmStatic
    fun setLogLevel(level: LogLevel) {
        logLevel = level
    }

    @JvmStatic
    fun setLogLevel(level: String) {
        logLevel = when (level.trim().lowercase(Locale.ROOT)) {
            "none" -> LogLevel.NONE
            "verbose", "debug" -> LogLevel.VERBOSE
            else -> LogLevel.ERROR
        }
    }

    @JvmStatic
    @JvmOverloads
    fun init(
        context: Context,
        appId: String,
        apiBase: String = DEFAULT_API_BASE,
        hmsAppId: String? = null,
    ) {
        appContext = context.applicationContext
        val resolvedBase = apiBase.trimEnd('/').ifBlank { DEFAULT_API_BASE }
        val resolvedHmsAppId = hmsAppId?.takeIf { it.isNotBlank() } ?: readAgConnectAppId(appContext)
        val editor = prefs().edit().putString(KEY_APP, appId).putString(KEY_API, resolvedBase)
        if (!resolvedHmsAppId.isNullOrBlank()) editor.putString(KEY_HMS, resolvedHmsAppId)
        consentRequiredMem?.let { editor.putBoolean(KEY_CONSENT_REQUIRED, it) }
        consentGivenMem?.let { editor.putBoolean(KEY_CONSENT_GIVEN, it) }
        editor.apply()
        logVerbose("Initialized MsgeraHuaweiPush v$SDK_VERSION for app $appId")
        if (networkAllowed() && notificationsAllowed()) {
            ensureChannel()
            refreshToken(null)
        }
        if (networkAllowed()) syncChannels()
    }

    @JvmStatic
    @JvmOverloads
    fun requestPermission(fallbackToSettings: Boolean = false, done: PermissionResult? = null) {
        if (!::appContext.isInitialized) {
            done?.onResult(false)
            return
        }
        if (Build.VERSION.SDK_INT < 33 || notificationsAllowed()) {
            ensureChannel()
            finishPermission(done)
            return
        }
        pendingPermission = done
        reportNamed("permission_prompted")
        val intent = Intent(appContext, MsgeraPermissionActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            putExtra(MsgeraPermissionActivity.EXTRA_FALLBACK_TO_SETTINGS, fallbackToSettings)
        }
        appContext.startActivity(intent)
    }

    @JvmStatic
    @JvmOverloads
    fun requestPermission(activity: Activity, done: PermissionResult? = null) {
        requestPermission(activity, fallbackToSettings = false, done = done)
    }

    @JvmStatic
    fun requestPermission(activity: Activity, fallbackToSettings: Boolean, done: PermissionResult?) {
        if (!::appContext.isInitialized) {
            appContext = activity.applicationContext
        }
        if (Build.VERSION.SDK_INT < 33 || notificationsAllowed()) {
            ensureChannel()
            finishPermission(done)
            return
        }
        val askedBefore = markPermissionAsked()
        val shouldShowRationale = ActivityCompat.shouldShowRequestPermissionRationale(
            activity,
            android.Manifest.permission.POST_NOTIFICATIONS,
        )
        if (fallbackToSettings && askedBefore && !shouldShowRationale) {
            openNotificationSettings(activity)
            done?.onResult(false)
            return
        }
        pendingPermission = done
        reportNamed("permission_prompted")
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
            44102,
        )
    }

    @JvmStatic
    fun onPermissionResult(grantResults: IntArray) {
        val done = pendingPermission
        pendingPermission = null
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        notifyPermission(granted)
        if (granted) reportNamed("permission_granted")
        if (!granted) {
            logVerbose("Notification permission was denied")
            done?.onResult(false)
            return
        }
        ensureChannel()
        finishPermission(done)
    }

    @JvmStatic
    @JvmOverloads
    fun login(externalUserId: String, userHash: String? = null, done: Done? = null) {
        executor.execute {
            try {
                val id = subscriberId() ?: throw IllegalStateException("Call requestPermission before login")
                post("/v1/public/push/${appId()}/subscribers/$id/login", JSONObject().apply {
                    put("externalUserId", externalUserId)
                    if (userHash != null) put("userHash", userHash)
                })
                if (userHash != null) prefs().edit().putString(KEY_USER_HASH, userHash).apply()
                main(done, null)
            } catch (error: Exception) {
                logError("login failed", error)
                main(done, error)
            }
        }
    }

    @JvmStatic
    @JvmOverloads
    fun logout(done: Done? = null) {
        executor.execute {
            try {
                val id = subscriberId()
                if (id != null) post("/v1/public/push/${appId()}/subscribers/$id/logout", JSONObject())
                main(done, null)
            } catch (error: Exception) {
                logError("logout failed", error)
                main(done, error)
            }
        }
    }

    /** Call from the launcher activity onCreate and onNewIntent. */
    @JvmStatic
    fun handleIntent(intent: Intent?): Boolean {
        val messageId = intent?.getStringExtra(EXTRA_MESSAGE_ID) ?: return false
        report(messageId, "clicked")
        val data = linkedMapOf<String, String>()
        intent.extras?.keySet()?.forEach { key ->
            intent.getStringExtra(key)?.let { data[key] = it }
        }
        val event = ClickEvent(
            messageId,
            intent.getStringExtra(EXTRA_TITLE) ?: data["title"],
            intent.getStringExtra(EXTRA_BODY) ?: data["body"],
            data,
            intent.getStringExtra(EXTRA_CLICK_URL) ?: data["clickUrl"],
            intent.getStringExtra(EXTRA_ACTION_ID),
        )
        if (clickListeners.isEmpty()) {
            synchronized(queuedClicks) { queuedClicks.add(event) }
            return true
        }
        dispatchClick(event)
        return true
    }

    @JvmStatic fun addClickListener(listener: ClickListener) {
        clickListeners.add(listener)
        val pending = synchronized(queuedClicks) {
            val copy = queuedClicks.toList()
            queuedClicks.clear()
            copy
        }
        pending.forEach { dispatchClick(it) }
    }
    @JvmStatic fun addForegroundListener(listener: ForegroundListener) { foregroundListeners.add(listener) }
    @JvmStatic fun addPermissionObserver(observer: PermissionObserver) { permissionObservers.add(observer) }
    @JvmStatic fun addSubscriptionObserver(observer: SubscriptionObserver) { subscriptionObservers.add(observer) }
    @JvmStatic fun canRequestPermission(): Boolean {
        if (!::appContext.isInitialized) return false
        if (Build.VERSION.SDK_INT < 33 || notificationsAllowed()) return true
        return !prefs().getBoolean(KEY_PERMISSION_ASKED, false)
    }
    val pushSubscription: SubscriptionState get() = currentSubscription()

    @JvmStatic fun optOut(done: Done? = null) = patchSubscription(false, done)
    @JvmStatic fun optIn(done: Done? = null) {
        if (!::appContext.isInitialized) {
            done?.onComplete(IllegalStateException("Call MsgeraHuaweiPush.init first"))
            return
        }
        prefs().edit().putBoolean(KEY_OPTED_IN, true).apply()
        notifySubscription()
        executor.execute {
            try {
                subscriberId()?.let {
                    request("PATCH", "/v1/public/push/${appId()}/subscribers/$it/subscription", JSONObject().put("optedIn", true))
                }
            } catch (error: Exception) {
                main(done, error)
                return@execute
            }
            refreshToken(done)
        }
    }
    @JvmStatic fun addTag(key: String, value: String) = queueTag(key, value)
    @JvmStatic fun addTags(tags: Map<String, String>) { tags.forEach { (key, value) -> queueTag(key, value) } }
    @JvmStatic fun removeTag(key: String) = queueTag(key, JSONObject.NULL)
    @JvmStatic fun removeTags(keys: Collection<String>) { keys.forEach { queueTag(it, JSONObject.NULL) } }
    @JvmStatic fun getTags(): Map<String, String> {
        if (!::appContext.isInitialized) return emptyMap()
        val json = readTags()
        val tags = linkedMapOf<String, String>()
        json.keys().forEach { key -> if (json.opt(key) is String) tags[key] = json.getString(key) }
        return tags
    }
    @JvmStatic fun setLanguage(language: String, done: Done? = null) {
        if (!::appContext.isInitialized) {
            done?.onComplete(IllegalStateException("Call MsgeraHuaweiPush.init first"))
            return
        }
        prefs().edit().putString(KEY_LANGUAGE, language).apply()
        executor.execute {
            try {
                subscriberId()?.let {
                    request("PATCH", "/v1/public/push/${appId()}/subscribers/$it", JSONObject().put("language", language))
                }
                main(done, null)
            } catch (error: Exception) {
                main(done, error)
            }
        }
    }
    @JvmStatic fun trackEvent(name: String, properties: Map<String, *>? = null, done: Done? = null) {
        executor.execute {
            try {
                val id = subscriberId() ?: throw IllegalStateException("Call requestPermission before trackEvent")
                val body = JSONObject().put("name", name)
                if (properties != null) body.put("properties", JSONObject(properties))
                request("POST", "/v1/public/push/${appId()}/subscribers/$id/events", body)
                main(done, null)
            } catch (error: Exception) {
                main(done, error)
            }
        }
    }
    @JvmStatic fun setConsentRequired(required: Boolean) {
        consentRequiredMem = required
        if (::appContext.isInitialized) prefs().edit().putBoolean(KEY_CONSENT_REQUIRED, required).apply()
    }
    @JvmStatic fun setConsentGiven(given: Boolean) {
        consentGivenMem = given
        if (::appContext.isInitialized) {
            prefs().edit().putBoolean(KEY_CONSENT_GIVEN, given).apply()
            if (given && notificationsAllowed()) refreshToken(null)
        }
    }
    @JvmStatic fun deleteDevice(done: Done? = null) {
        executor.execute {
            try {
                val id = subscriberId()
                if (id != null && networkAllowed()) request("DELETE", "/v1/public/push/${appId()}/subscribers/$id", null)
                if (::appContext.isInitialized) {
                    prefs().edit().remove(KEY_SUBSCRIBER).remove(KEY_TOKEN).remove(KEY_TAGS).remove(KEY_USER_HASH).remove(KEY_SYNCED).putBoolean(KEY_OPTED_IN, true).apply()
                }
                notifySubscription()
                main(done, null)
            } catch (error: Exception) {
                main(done, error)
            }
        }
    }
    @JvmStatic fun clearAllNotifications() { if (::appContext.isInitialized) notificationManager().cancelAll() }
    @JvmStatic fun removeNotification(id: Int) { if (::appContext.isInitialized) notificationManager().cancel(id) }

    private fun patchSubscription(optedIn: Boolean, done: Done?) {
        if (!::appContext.isInitialized) {
            done?.onComplete(IllegalStateException("Call MsgeraHuaweiPush.init first"))
            return
        }
        prefs().edit().putBoolean(KEY_OPTED_IN, optedIn).apply()
        notifySubscription()
        executor.execute {
            try {
                subscriberId()?.let {
                    request("PATCH", "/v1/public/push/${appId()}/subscribers/$it/subscription", JSONObject().put("optedIn", optedIn))
                }
                main(done, null)
            } catch (error: Exception) {
                main(done, error)
            }
        }
    }

    internal fun resolveSmallIcon(context: Context): Int {
        val drawableId = context.resources.getIdentifier("ic_stat_msgera", "drawable", context.packageName)
        if (drawableId != 0) return drawableId
        val mipmapId = context.resources.getIdentifier("ic_stat_msgera", "mipmap", context.packageName)
        if (mipmapId != 0) return mipmapId
        val appIcon = context.applicationInfo.icon
        return if (appIcon != 0) appIcon else android.R.drawable.ic_dialog_info
    }

    internal fun markPermissionAsked(): Boolean {
        if (!::appContext.isInitialized) return false
        val alreadyAsked = prefs().getBoolean(KEY_PERMISSION_ASKED, false)
        if (!alreadyAsked) {
            prefs().edit().putBoolean(KEY_PERMISSION_ASKED, true).apply()
        }
        return alreadyAsked
    }

    internal fun onNewToken(token: String?) {
        if (token.isNullOrBlank() || !::appContext.isInitialized) return
        if (prefs().getString(KEY_APP, null) == null) return
        executor.execute { register(token, null) }
    }

    internal fun showForeground(
        title: String?,
        body: String?,
        messageId: String?,
        clickUrl: String?,
        smallIconResId: Int = 0,
        data: Map<String, String> = emptyMap(),
    ) {
        if (!::appContext.isInitialized || !notificationsAllowed() || title.isNullOrBlank()) return
        val foreground = ForegroundEvent(messageId, title, body, data)
        foregroundListeners.forEach { it.onForeground(foreground) }
        if (messageId != null) report(messageId, "received")
        if (foreground.wasPrevented()) return
        val channelId = data["channelId"]?.takeIf { it.isNotBlank() } ?: CHANNEL_ID
        MsgeraNotificationDisplay.ensureChannel(appContext, channelId)
        val launch = appContext.packageManager.getLaunchIntentForPackage(appContext.packageName)
            ?.apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                if (messageId != null) putExtra(EXTRA_MESSAGE_ID, messageId)
                if (clickUrl != null) putExtra(EXTRA_CLICK_URL, clickUrl)
                if (title != null) putExtra(EXTRA_TITLE, title)
                if (body != null) putExtra(EXTRA_BODY, body)
            } ?: return
        val flags = if (Build.VERSION.SDK_INT >= 23) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val pending = PendingIntent.getActivity(
            appContext,
            (messageId ?: title).hashCode(),
            launch,
            flags,
        )
        val iconRes = if (smallIconResId != 0) smallIconResId else resolveSmallIcon(appContext)
        val builder = NotificationCompat.Builder(appContext, channelId)
            .setSmallIcon(iconRes)
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
            .setContentIntent(pending)
        val groupKey = data["groupKey"]
        if (!groupKey.isNullOrBlank()) builder.setGroup(groupKey)
        MsgeraNotificationDisplay.decorate(appContext, builder, data, launch, messageId, flags)
        notificationManager().notify((messageId ?: title).hashCode(), builder.build())
    }

    private fun readAgConnectAppId(context: Context): String? {
        // 1. Try AGConnectOptionsBuilder via reflection if AGConnect core is present.
        try {
            val builderClass = Class.forName("com.huawei.agconnect.AGConnectOptionsBuilder")
            val builder = builderClass.getDeclaredConstructor().newInstance()
            val options = builderClass.getMethod("build", Context::class.java).invoke(builder, context)
            if (options != null) {
                val getString = options.javaClass.getMethod("getString", String::class.java)
                val appId = (getString.invoke(options, "client/app_id") as? String)?.trim()
                if (!appId.isNullOrEmpty()) return appId
            }
        } catch (_: Throwable) {
        }

        // 2. Fallback: parse assets/agconnect-services.json directly.
        try {
            val text = context.assets.open("agconnect-services.json").bufferedReader().use { it.readText() }
            val json = JSONObject(text)
            val fromClient = json.optJSONObject("client")?.optString("app_id")?.trim()
            if (!fromClient.isNullOrEmpty()) return fromClient
            val fromAppInfo = json.optJSONObject("app_info")?.optString("app_id")?.trim()
            if (!fromAppInfo.isNullOrEmpty()) return fromAppInfo
        } catch (_: Throwable) {
        }
        return null
    }

    private fun openNotificationSettings(context: Context) {
        try {
            val intent = if (Build.VERSION.SDK_INT >= 26) {
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                    putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                }
            } else {
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.fromParts("package", context.packageName, null)
                }
            }
            if (context !is Activity) {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
        } catch (error: Exception) {
            logError("Could not open notification settings", error)
        }
    }

    private fun finishPermission(done: PermissionResult?) {
        refreshToken(Done { error -> done?.onResult(error == null) })
    }

    private fun refreshToken(done: Done?) {
        executor.execute {
            try {
                val token = HmsInstanceId.getInstance(appContext).getToken(hmsAppId(), "HCM")
                if (!token.isNullOrBlank()) register(token, done) else main(done, null)
            } catch (error: ApiException) {
                val ex = IllegalStateException("Huawei token failed (${error.statusCode})", error)
                logError("Failed to fetch HMS token", ex)
                main(done, ex)
            } catch (error: Exception) {
                logError("Failed to fetch HMS token", error)
                main(done, error)
            }
        }
    }

    private fun register(token: String, done: Done?) {
        try {
            val fresh = System.currentTimeMillis() - prefs().getLong(KEY_SYNCED, 0L) < RESYNC_MS
            if (prefs().getString(KEY_TOKEN, null) == token && subscriberId() != null && fresh) {
                main(done, null)
                return
            }
            if (!networkAllowed()) {
                main(done, if (done == null) null else IllegalStateException("Consent is required before Msgera push can send data"))
                return
            }
            if (!optedIn()) {
                main(done, null)
                return
            }
            val response = post("/v1/public/push/${appId()}/subscribers", JSONObject()
                .put("token", token)
                .put("platform", "huawei")
                .put("transport", "hms")
                .put("language", prefs().getString(KEY_LANGUAGE, null) ?: Locale.getDefault().toLanguageTag())
                .put("timezone", TimeZone.getDefault().id)
                .put("sdkVersion", SDK_VERSION))
            val id = response.getString("subscriberId")
            prefs().edit()
                .putString(KEY_SUBSCRIBER, id)
                .putString(KEY_TOKEN, token)
                .putLong(KEY_SYNCED, System.currentTimeMillis())
                .apply()
            logVerbose("Registered Huawei subscriber $id")
            notifySubscription()
            if (pendingTagPatch.length() > 0) scheduleTagFlush()
            main(done, null)
        } catch (error: Exception) {
            logError("Device registration failed", error)
            main(done, error)
        }
    }

    private fun syncChannels() {
        executor.execute {
            try {
                val config = request("GET", "/v1/public/push/${appId()}/config", null)
                MsgeraNotificationDisplay.syncChannels(appContext, config.optJSONArray("channels"))
            } catch (error: Exception) {
                logError("Channel sync failed", error)
            }
        }
    }

    private fun reportNamed(name: String) {
        val id = subscriberId() ?: return
        executor.execute {
            try {
                post(
                    "/v1/public/push/${appId()}/subscribers/$id/events",
                    JSONObject().put("name", name),
                )
            } catch (error: Exception) {
                logError("Event report ($name) failed", error)
            }
        }
    }

    private fun report(messageId: String, type: String) {
        val id = subscriberId() ?: return
        executor.execute {
            try {
                post(
                    "/v1/public/push/${appId()}/subscribers/$id/events",
                    JSONObject().put("messageId", messageId).put("type", type),
                )
            } catch (error: Exception) {
                logError("Event report ($type) failed", error)
            }
        }
    }

    private fun post(path: String, body: JSONObject) = request("POST", path, body)

    private fun request(method: String, path: String, body: JSONObject?): JSONObject {
        if (!networkAllowed()) throw IllegalStateException("Consent is required before Msgera push can send data")
        val connection = (URL(apiBase() + path).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            setRequestProperty("Content-Type", "application/json")
            connectTimeout = 15_000
            readTimeout = 15_000
            if (body != null && method != "DELETE") doOutput = true
        }
        if (body != null && method != "DELETE") {
            connection.outputStream.use { it.write(body.toString().toByteArray()) }
        }
        val code = connection.responseCode
        val stream = if (code in 200..299) connection.inputStream else connection.errorStream
        val text = stream?.bufferedReader()?.use { it.readText() }.orEmpty()
        if (code !in 200..299) throw IllegalStateException(text.ifBlank { "Push request failed ($code)" })
        return if (text.isBlank()) JSONObject() else JSONObject(text)
    }

    private fun dispatchClick(event: ClickEvent) {
        val run = Runnable {
            clickListeners.forEach { it.onClick(event) }
            val url = event.launchUrl
            if (!event.wasPrevented() && !url.isNullOrBlank()) {
                try {
                    appContext.startActivity(viewIntent(url))
                } catch (error: Exception) {
                    logError("Could not open launch URL", error)
                }
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) run.run() else mainHandler.post(run)
    }

    private fun viewIntent(url: String): Intent {
        val uri = Uri.parse(url)
        val flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        val inApp = Intent(Intent.ACTION_VIEW, uri).setPackage(appContext.packageName).addFlags(flags)
        if (inApp.resolveActivity(appContext.packageManager) != null) return inApp
        return Intent(Intent.ACTION_VIEW, uri).addFlags(flags)
    }

    private fun queueTag(key: String, value: Any) {
        if (!::appContext.isInitialized) return
        synchronized(pendingTagPatch) {
            val cached = readTags()
            if (value == JSONObject.NULL) cached.remove(key) else cached.put(key, value)
            prefs().edit().putString(KEY_TAGS, cached.toString()).apply()
            pendingTagPatch.put(key, value)
        }
        scheduleTagFlush()
    }

    private fun scheduleTagFlush() {
        if (tagFlushPosted) mainHandler.removeCallbacks(tagFlush)
        tagFlushPosted = true
        mainHandler.postDelayed(tagFlush, 2_000)
    }

    private fun flushTagsNow() {
        if (!networkAllowed()) return
        val id = subscriberId() ?: return
        val patch = synchronized(pendingTagPatch) {
            if (pendingTagPatch.length() == 0) return
            val copy = JSONObject(pendingTagPatch.toString())
            pendingTagPatch.keys().asSequence().toList().forEach { pendingTagPatch.remove(it) }
            copy
        }
        val body = JSONObject().put("tags", patch)
        prefs().getString(KEY_USER_HASH, null)?.takeIf { it.isNotBlank() }?.let { body.put("userHash", it) }
        try {
            request("PATCH", "/v1/public/push/${appId()}/subscribers/$id/tags", body)
        } catch (error: Exception) {
            logError("Tag update failed", error)
        }
    }

    private fun readTags(): JSONObject {
        val raw = prefs().getString(KEY_TAGS, null) ?: return JSONObject()
        return try { JSONObject(raw) } catch (_: Exception) { JSONObject() }
    }

    private fun networkAllowed(): Boolean {
        val required = consentRequiredMem ?: if (::appContext.isInitialized) prefs().getBoolean(KEY_CONSENT_REQUIRED, false) else false
        if (!required) return true
        val given = consentGivenMem ?: if (::appContext.isInitialized) prefs().getBoolean(KEY_CONSENT_GIVEN, false) else false
        return given
    }

    private fun optedIn(): Boolean = if (::appContext.isInitialized) prefs().getBoolean(KEY_OPTED_IN, true) else true

    private fun currentSubscription() = SubscriptionState(
        if (::appContext.isInitialized) subscriberId() else null,
        if (::appContext.isInitialized) prefs().getString(KEY_TOKEN, null) else null,
        optedIn(),
    )

    private fun notifyPermission(granted: Boolean) {
        mainHandler.post { permissionObservers.forEach { it.onChange(granted) } }
    }

    private fun notifySubscription() {
        val state = currentSubscription()
        mainHandler.post { subscriptionObservers.forEach { it.onChange(state) } }
    }

    private fun notificationManager() =
        appContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(CHANNEL_ID, "Notifications", NotificationManager.IMPORTANCE_HIGH)
        manager.createNotificationChannel(channel)
    }

    private fun notificationsAllowed(): Boolean {
        if (Build.VERSION.SDK_INT < 33) return true
        return ContextCompat.checkSelfPermission(
            appContext,
            android.Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun prefs() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private fun appId() = prefs().getString(KEY_APP, null) ?: throw IllegalStateException("Call MsgeraHuaweiPush.init first")
    private fun apiBase() = prefs().getString(KEY_API, null)?.ifBlank { DEFAULT_API_BASE } ?: DEFAULT_API_BASE
    private fun hmsAppId(): String {
        val stored = prefs().getString(KEY_HMS, null)
        if (!stored.isNullOrBlank()) return stored
        val fromAgConnect = readAgConnectAppId(appContext)
        if (!fromAgConnect.isNullOrBlank()) {
            prefs().edit().putString(KEY_HMS, fromAgConnect).apply()
            return fromAgConnect
        }
        throw IllegalStateException("Add agconnect-services.json or pass hmsAppId to MsgeraHuaweiPush.init")
    }
    private fun subscriberId() = prefs().getString(KEY_SUBSCRIBER, null)

    private fun main(done: Done?, error: Exception?) {
        android.os.Handler(android.os.Looper.getMainLooper()).post { done?.onComplete(error) }
    }

    private fun logVerbose(message: String) {
        if (logLevel == LogLevel.VERBOSE) {
            Log.d(LOG_TAG, message)
        }
    }

    private fun logError(message: String, error: Throwable? = null) {
        if (logLevel == LogLevel.ERROR || logLevel == LogLevel.VERBOSE) {
            Log.e(LOG_TAG, message, error)
        }
    }
}

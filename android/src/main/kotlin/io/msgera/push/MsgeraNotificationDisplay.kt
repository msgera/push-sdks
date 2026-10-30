package io.msgera.push

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.graphics.Color
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import org.json.JSONArray
import java.net.HttpURLConnection
import java.net.URL

internal object MsgeraNotificationDisplay {
    fun ensureChannel(context: Context, channelId: String) {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = manager(context)
        if (manager.getNotificationChannel(channelId) != null) return
        val channel = NotificationChannel(
            channelId,
            if (channelId == MsgeraPush.CHANNEL_ID) "Notifications" else channelId,
            NotificationManager.IMPORTANCE_HIGH,
        )
        manager.createNotificationChannel(channel)
    }

    fun syncChannels(context: Context, channels: JSONArray?) {
        if (Build.VERSION.SDK_INT < 26 || channels == null) return
        val manager = manager(context)
        for (index in 0 until channels.length()) {
            val row = channels.optJSONObject(index) ?: continue
            val id = row.optString("channelId")
            val key = row.optString("key")
            val name = row.optString("name").ifBlank { key }
            if (id.isBlank() || key.isBlank()) continue
            for (existing in manager.notificationChannels) {
                if (existing.id.startsWith("${key}_v") && existing.id != id) {
                    manager.deleteNotificationChannel(existing.id)
                }
            }
            if (manager.getNotificationChannel(id) != null) continue
            val importance = when (row.optString("importance")) {
                "low" -> NotificationManager.IMPORTANCE_LOW
                "default" -> NotificationManager.IMPORTANCE_DEFAULT
                else -> NotificationManager.IMPORTANCE_HIGH
            }
            val channel = NotificationChannel(id, name, importance)
            val description = row.optString("description")
            if (description.isNotBlank()) channel.description = description
            applySound(context, channel, row.optString("sound", "default"))
            manager.createNotificationChannel(channel)
        }
    }

    fun decorate(
        context: Context,
        builder: NotificationCompat.Builder,
        data: Map<String, String>,
        launch: Intent,
        messageId: String?,
        flags: Int,
    ) {
        val iconName = data["smallIcon"]
        if (!iconName.isNullOrBlank()) {
            val res = context.resources.getIdentifier(iconName, "drawable", context.packageName)
                .takeIf { it != 0 }
                ?: context.resources.getIdentifier(iconName, "mipmap", context.packageName)
            if (res != 0) builder.setSmallIcon(res)
        }
        val accent = data["accentColor"]
        if (!accent.isNullOrBlank()) {
            try {
                builder.setColor(Color.parseColor(accent))
            } catch (_: IllegalArgumentException) {
            }
        }
        val large = bitmap(data["largeIconUrl"])
        if (large != null) builder.setLargeIcon(large)
        val picture = bitmap(data["imageUrl"])
        if (picture != null) {
            builder.setStyle(NotificationCompat.BigPictureStyle().bigPicture(picture))
        }
        val raw = data["msgeraButtons"]
        if (!raw.isNullOrBlank()) {
            val buttons = try {
                JSONArray(raw)
            } catch (_: Exception) {
                null
            }
            if (buttons != null) {
                val limit = minOf(buttons.length(), 2)
                for (index in 0 until limit) {
                    val button = buttons.optJSONObject(index) ?: continue
                    val id = button.optString("id")
                    val label = button.optString("text").ifBlank { button.optString("title") }
                    if (id.isBlank() || label.isBlank()) continue
                    val intent = Intent(launch).putExtra(MsgeraPush.EXTRA_ACTION_ID, id)
                    val url = button.optString("url")
                    if (url.isNotBlank()) intent.putExtra(MsgeraPush.EXTRA_CLICK_URL, url)
                    val pending = PendingIntent.getActivity(
                        context,
                        (messageId ?: label).hashCode() xor id.hashCode(),
                        intent,
                        flags,
                    )
                    builder.addAction(0, label, pending)
                }
            }
        }
    }

    private fun applySound(context: Context, channel: NotificationChannel, sound: String) {
        if (sound == "none") {
            channel.setSound(null, null)
            return
        }
        if (sound.isBlank() || sound == "default") return
        val raw = sound.substringBefore('.')
        val res = context.resources.getIdentifier(raw, "raw", context.packageName)
        if (res == 0) return
        val uri = Uri.parse("android.resource://${context.packageName}/$res")
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        channel.setSound(uri, attrs)
    }

    private fun bitmap(url: String?): android.graphics.Bitmap? {
        if (url.isNullOrBlank() || !url.startsWith("https://")) return null
        return try {
            val connection = (URL(url).openConnection() as HttpURLConnection).apply {
                connectTimeout = 4_000
                readTimeout = 4_000
                instanceFollowRedirects = true
            }
            connection.inputStream.use { BitmapFactory.decodeStream(it) }
        } catch (_: Exception) {
            null
        }
    }

    private fun manager(context: Context) =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
}

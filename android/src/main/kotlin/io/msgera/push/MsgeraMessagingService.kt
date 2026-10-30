package io.msgera.push

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Shows a notification while the app is open. FCM does not show one itself
 * in that case, so a message sent while the customer is in the app would
 * otherwise vanish. A tap is delivered to the launcher activity; call
 * [MsgeraPush.handleIntent] there.
 */
open class MsgeraMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        MsgeraPush.onNewToken(token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        val smallIcon = MsgeraPush.resolveSmallIcon(this)
        MsgeraPush.showForeground(
            message.notification?.title ?: data["title"],
            message.notification?.body ?: data["body"],
            data["msgeraMessageId"],
            data["clickUrl"],
            smallIcon,
            data,
        )
    }
}

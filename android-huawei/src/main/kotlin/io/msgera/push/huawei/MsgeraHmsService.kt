package io.msgera.push.huawei

import android.os.Bundle
import com.huawei.hms.push.HmsMessageService
import com.huawei.hms.push.RemoteMessage

/** Receives a token when getToken returns empty, which is normal on older EMUI. */
open class MsgeraHmsService : HmsMessageService() {
    override fun onNewToken(token: String?) {
        MsgeraHuaweiPush.onNewToken(token)
    }

    override fun onNewToken(token: String?, bundle: Bundle?) {
        MsgeraHuaweiPush.onNewToken(token)
    }

    override fun onMessageReceived(message: RemoteMessage?) {
        val data = message?.dataOfMap ?: return
        val smallIcon = MsgeraHuaweiPush.resolveSmallIcon(this)
        MsgeraHuaweiPush.showForeground(
            message.notification?.title ?: data["title"],
            message.notification?.body ?: data["body"],
            data["msgeraMessageId"],
            data["clickUrl"],
            smallIcon,
            data,
        )
    }
}

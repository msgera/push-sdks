package io.msgera.push

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat

/**
 * Transparent helper activity that requests `POST_NOTIFICATIONS` on Android 13+
 * and forwards the result to [MsgeraPush.onPermissionResult] without requiring
 * the host app to pass an [Activity] or override `onRequestPermissionsResult`.
 */
class MsgeraPermissionActivity : Activity() {
    private var rationaleBeforeRequest = false
    private var fallbackToSettings = false
    private var openedSettings = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        overridePendingTransition(0, 0)
        fallbackToSettings = intent?.getBooleanExtra(EXTRA_FALLBACK_TO_SETTINGS, false) ?: false

        if (Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        ) {
            MsgeraPush.onPermissionResult(intArrayOf(PackageManager.PERMISSION_GRANTED))
            finishQuietly()
            return
        }

        rationaleBeforeRequest = ActivityCompat.shouldShowRequestPermissionRationale(
            this,
            Manifest.permission.POST_NOTIFICATIONS,
        )
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_CODE,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_CODE) return

        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        val askedBefore = MsgeraPush.markPermissionAsked()
        if (!granted && fallbackToSettings && Build.VERSION.SDK_INT >= 33) {
            val rationaleAfter = ActivityCompat.shouldShowRequestPermissionRationale(
                this,
                Manifest.permission.POST_NOTIFICATIONS,
            )
            if (askedBefore && !rationaleBeforeRequest && !rationaleAfter) {
                openedSettings = true
                openNotificationSettings()
                return
            }
        }

        MsgeraPush.onPermissionResult(grantResults)
        finishQuietly()
    }

    override fun onResume() {
        super.onResume()
        if (!openedSettings) return
        openedSettings = false
        val granted = if (Build.VERSION.SDK_INT < 33) {
            true
        } else {
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        }
        val result = if (granted) PackageManager.PERMISSION_GRANTED else PackageManager.PERMISSION_DENIED
        MsgeraPush.onPermissionResult(intArrayOf(result))
        finishQuietly()
    }

    private fun openNotificationSettings() {
        try {
            val settingsIntent = if (Build.VERSION.SDK_INT >= 26) {
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                    putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                }
            } else {
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.fromParts("package", packageName, null)
                }
            }
            startActivity(settingsIntent)
        } catch (_: Exception) {
            MsgeraPush.onPermissionResult(intArrayOf(PackageManager.PERMISSION_DENIED))
            finishQuietly()
        }
    }

    private fun finishQuietly() {
        finish()
        overridePendingTransition(0, 0)
    }

    companion object {
        internal const val EXTRA_FALLBACK_TO_SETTINGS = "io.msgera.push.EXTRA_FALLBACK_TO_SETTINGS"
        private const val REQUEST_CODE = 44101
    }
}

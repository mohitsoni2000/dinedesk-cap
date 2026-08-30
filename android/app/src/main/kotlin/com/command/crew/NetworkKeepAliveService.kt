package com.command.crew

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Keeps the LAN socket to the desk alive while the operator's phone is
 * backgrounded or its screen is off.
 *
 * Two separate problems are solved here, and they need two different
 * mechanisms:
 *
 * 1. **The process gets frozen.** Doze, App Standby and (Android 14+) the
 *    cached-app freezer suspend the Flutter isolate once the app leaves the
 *    foreground. The socket dies without ever running `onDisconnect`, which is
 *    exactly the stale-`verified`-state hazard `main.dart`'s
 *    `_verifyConnectionOnResume` was written to clean up after. A foreground
 *    service is the only supported way to keep the process running. The type is
 *    `connectedDevice` rather than `dataSync` because Android 15 caps dataSync
 *    services at six hours — shorter than a restaurant shift.
 *
 * 2. **The Wi-Fi radio powers down.** Independently of the process, the chip
 *    enters 802.11 power save when the screen goes off. On a weak signal that
 *    is where packets start getting missed and a TCP connection rots into a
 *    half-open socket that neither end notices. A [WifiManager.WifiLock] is
 *    what disables power save.
 *
 * On the lock modes — this is the part that is easy to get wrong:
 *
 * - [WifiManager.WIFI_MODE_FULL_LOW_LATENCY] is the modern, non-deprecated
 *   mode, but per AOSP it only engages while the app is in the **foreground
 *   with the screen on**. That makes it useless on its own for the case this
 *   service exists for.
 * - [WifiManager.WIFI_MODE_FULL_HIGH_PERF] is deprecated as of API 29 but is
 *   still honored by the framework and is the only mode that keeps power save
 *   off with the screen off.
 * - [WifiManager.WIFI_MODE_FULL] has been a documented no-op since API 29 —
 *   don't reach for it as a "safer" fallback, it does nothing.
 *
 * So both are held: HIGH_PERF for the whole session, and LOW_LATENCY layered on
 * top only while the app is actually foregrounded. The framework picks the
 * strongest applicable lock.
 *
 * The [WifiManager.MulticastLock] is unrelated to power and easy to overlook:
 * without it the Wi-Fi chip filters out broadcast/multicast frames once the
 * phone idles, which silently blinds the UDP desk-discovery beacon on port
 * 45654 (`discovery_service.dart`). Rediscovery then reports "nothing found"
 * on a LAN where the desk is beaconing every two seconds.
 */
class NetworkKeepAliveService : Service() {

    companion object {
        private const val TAG = "CrewKeepAlive"

        const val ACTION_START = "com.command.crew.keepalive.START"
        const val ACTION_STOP = "com.command.crew.keepalive.STOP"
        const val ACTION_APP_FOREGROUNDED = "com.command.crew.keepalive.FOREGROUNDED"
        const val ACTION_APP_BACKGROUNDED = "com.command.crew.keepalive.BACKGROUNDED"

        const val EXTRA_RESTAURANT = "restaurant"

        private const val CHANNEL_ID = "crew_connection"
        private const val NOTIFICATION_ID = 1701
    }

    private var wifiLockHighPerf: WifiManager.WifiLock? = null
    private var wifiLockLowLatency: WifiManager.WifiLock? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    private var restaurantName: String? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                releaseLocks()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }

            ACTION_APP_FOREGROUNDED -> acquireLowLatencyLock()
            ACTION_APP_BACKGROUNDED -> releaseLowLatencyLock()

            else -> {
                intent?.getStringExtra(EXTRA_RESTAURANT)?.let { restaurantName = it }
                if (!promoteToForeground()) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                acquireSessionLocks()
            }
        }
        // START_STICKY so that if Android reclaims the process under memory
        // pressure mid-shift, the service comes back on its own and re-takes
        // the locks. The redelivered intent has a null action, which falls
        // through to the `else` branch above — the same path as a fresh start.
        return START_STICKY
    }

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }

    /**
     * Returns false if the platform refused the promotion — Android 12+ throws
     * [android.app.ForegroundServiceStartNotAllowedException] for a service
     * started while the app is in the background. Callers start this from a
     * foreground context, so that shouldn't happen, but a refusal must not take
     * the app down with it: without the service we simply fall back to the old,
     * best-effort reconnect-on-resume behaviour.
     */
    private fun promoteToForeground(): Boolean {
        return try {
            createChannel()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    buildNotification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
                )
            } else {
                startForeground(NOTIFICATION_ID, buildNotification())
            }
            true
        } catch (err: Exception) {
            Log.w(TAG, "Could not start foreground service", err)
            false
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        // IMPORTANCE_LOW: no sound, no heads-up. The notification is a platform
        // requirement for the service, not something the operator needs to act
        // on, so it should sit silently in the shade.
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Desk connection",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Keeps the connection to the billing desk alive during a shift."
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val tapIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle(restaurantName?.let { "Connected · $it" } ?: "Connected to desk")
            .setContentText("Orders and KOTs stay in sync while you work.")
            // Same icon the ready-order alerts already use
            // (`platform_surfaces.dart`), so the two notifications from this app
            // read as coming from the same place.
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(tapIntent)
            .setOngoing(true)
            .setShowWhen(false)
            .build()
    }

    private fun acquireSessionLocks() {
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        if (wifi == null) {
            Log.w(TAG, "No WifiManager — skipping locks")
            return
        }

        if (wifiLockHighPerf == null) {
            @Suppress("DEPRECATION")
            wifiLockHighPerf = wifi
                .createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "crew:wifi-highperf")
                .apply { setReferenceCounted(false) }
        }
        if (multicastLock == null) {
            multicastLock = wifi
                .createMulticastLock("crew:multicast")
                .apply { setReferenceCounted(false) }
        }

        wifiLockHighPerf?.takeUnless { it.isHeld }?.acquire()
        multicastLock?.takeUnless { it.isHeld }?.acquire()
        Log.i(TAG, "Session locks acquired")
    }

    private fun acquireLowLatencyLock() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            ?: return
        if (wifiLockLowLatency == null) {
            wifiLockLowLatency = wifi
                .createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "crew:wifi-lowlatency")
                .apply { setReferenceCounted(false) }
        }
        wifiLockLowLatency?.takeUnless { it.isHeld }?.acquire()
    }

    private fun releaseLowLatencyLock() {
        wifiLockLowLatency?.takeIf { it.isHeld }?.release()
    }

    private fun releaseLocks() {
        releaseLowLatencyLock()
        wifiLockHighPerf?.takeIf { it.isHeld }?.release()
        multicastLock?.takeIf { it.isHeld }?.release()
        Log.i(TAG, "Locks released")
    }
}

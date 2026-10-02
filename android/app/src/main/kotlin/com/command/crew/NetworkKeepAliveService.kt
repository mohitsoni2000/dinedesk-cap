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
 * PLAY CONSOLE REQUIREMENT: the manifest declares
 * FOREGROUND_SERVICE_CONNECTED_DEVICE for this service. Play Console will not
 * accept that declaration without a demo video showing the permission in use
 * (that is why this service was pulled from release 1.2.x the first time).
 * Record the video (phone paired, screen off, orders still arriving, the
 * "Connected to Desk" notification visible) BEFORE publishing a build that
 * contains this service.
 *
 * Two separate problems, two mechanisms:
 *
 * 1. The process gets frozen. Doze, App Standby and the Android 14+ cached-app
 *    freezer suspend the Flutter isolate once the app leaves the foreground;
 *    the socket dies without running onDisconnect. A foreground service is the
 *    supported way to keep running. Type is `connectedDevice`, not `dataSync`:
 *    Android 15 caps dataSync at ~6h per 24h, shorter than a restaurant shift.
 *
 * 2. The Wi-Fi radio powers down. 802.11 power save kicks in with the screen
 *    off, and on a weak signal that is where packets get missed and TCP rots
 *    into a half-open socket. A WifiLock disables power save.
 *
 * Which lock works where:
 * - WIFI_MODE_FULL_LOW_LATENCY (API 29+) only engages for a FOREGROUND app with
 *   the SCREEN ON, so it is useless for this service. MainActivity holds it
 *   while resumed.
 * - WIFI_MODE_FULL_HIGH_PERF is deprecated since API 29 but still honoured and
 *   is the only mode that keeps power save off with the screen off. This
 *   service holds it for the whole session.
 * - WIFI_MODE_FULL is a documented no-op since API 29; not used.
 *
 * The MulticastLock is for discovery: without it the chip filters the desk's
 * UDP beacon (port 45654) once the phone idles and rediscovery finds nothing.
 */
class NetworkKeepAliveService : Service() {

    companion object {
        private const val TAG = "CrewKeepAlive"

        const val ACTION_START = "com.command.crew.keepalive.START"
        const val ACTION_STOP = "com.command.crew.keepalive.STOP"
        const val EXTRA_RESTAURANT = "restaurant"

        private const val CHANNEL_ID = "crew_connection"
        private const val NOTIFICATION_ID = 1701
    }

    private var wifiLockHighPerf: WifiManager.WifiLock? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var restaurantName: String? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            releaseLocks()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        intent?.getStringExtra(EXTRA_RESTAURANT)?.let { restaurantName = it }
        if (!promoteToForeground()) {
            stopSelf()
            return START_NOT_STICKY
        }
        acquireLocks()
        // START_STICKY: if the process is reclaimed mid-shift the service
        // returns and re-takes the locks (redelivered intent has a null action,
        // which takes this same path).
        return START_STICKY
    }

    /**
     * The operator swiped the app away from Recents. The UI and its socket are
     * gone with the task, but this service is START_STICKY and would otherwise
     * stay up (and be restarted by the system) holding the Wi-Fi/multicast locks
     * and the "Connected to Desk" notification for an app that is no longer
     * running. Backgrounding the app does NOT come through here: only a removed
     * task does, so a shift in progress is unaffected.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.i(TAG, "Task removed - stopping keep-alive")
        releaseLocks()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }

    /** False if the platform refused (Android 12+ throws when started from the
     *  background); the app then falls back to reconnect-on-resume. */
    private fun promoteToForeground(): Boolean = try {
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

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        // IMPORTANCE_LOW: silent, no heads-up. It is a platform requirement,
        // not something the operator acts on.
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
            .setContentTitle("COMMAND Crew · Connected to Desk")
            .apply { restaurantName?.let { setContentText(it) } }
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(tapIntent)
            .setOngoing(true)
            .setShowWhen(false)
            .build()
    }

    private fun acquireLocks() {
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        if (wifi == null) {
            Log.w(TAG, "No WifiManager - skipping locks")
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
        Log.i(TAG, "Locks acquired")
    }

    private fun releaseLocks() {
        wifiLockHighPerf?.takeIf { it.isHeld }?.release()
        multicastLock?.takeIf { it.isHeld }?.release()
        Log.i(TAG, "Locks released")
    }
}

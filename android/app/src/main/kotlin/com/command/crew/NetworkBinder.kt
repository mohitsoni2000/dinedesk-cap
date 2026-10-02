package com.command.crew

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Pins the whole process to the restaurant Wi-Fi, even when Android has
 * decided that Wi-Fi is "No internet".
 *
 * The failure this exists for: the desk lives on the LAN (192.168.x.x), the
 * router has no uplink, so the OS marks the Wi-Fi unvalidated and quietly
 * routes app traffic over mobile data. The desk then becomes unreachable even
 * though the phone is associated with the right access point.
 *
 * Mechanism:
 * - A [NetworkRequest] for TRANSPORT_WIFI with NET_CAPABILITY_INTERNET (and
 *   VALIDATED, which the builder adds by default) removed, so an unvalidated
 *   Wi-Fi still matches.
 * - [ConnectivityManager.requestNetwork], NOT registerNetworkCallback: only a
 *   request counts as demand for the network, which stops the OS tearing down
 *   a Wi-Fi it considers useless for lack of validation.
 * - [ConnectivityManager.bindProcessToNetwork] once it is available. dart:io
 *   sockets (Socket, HttpClient, WebSocket, RawDatagramSocket) all follow the
 *   process default network and Dart exposes no fd for per-socket binding, so
 *   a process-wide bind is the only lever there is. (The in_app_update check
 *   runs in the Play Store process and is unaffected.)
 *
 * Exactly one request is ever outstanding; [bindWifi] is idempotent. minSdk is
 * 24, so the API 21-22 `setProcessDefaultNetwork` fallback is not needed.
 */
class NetworkBinder(context: Context) : EventChannel.StreamHandler {

    companion object {
        private const val TAG = "CrewNetBinder"

        /** How long [bindWifi] waits for a Wi-Fi before answering false. The
         *  request stays alive afterwards and binds (and emits `available`)
         *  whenever Wi-Fi shows up. */
        private const val BIND_WAIT_MS = 1200L
    }

    private val cm =
        context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE)
            as ConnectivityManager
    private val main = Handler(Looper.getMainLooper())

    private var callback: ConnectivityManager.NetworkCallback? = null
    private var bound: Network? = null
    private var sink: EventChannel.EventSink? = null
    private val pending = mutableListOf<MethodChannel.Result>()
    private var timeout: Runnable? = null

    // Last-emitted signature per concern, so signal-strength capability
    // updates (several per second on some devices) do not flood Dart.
    private var capSignature: String? = null
    private var linkSignature: String? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    fun bindWifi(result: MethodChannel.Result) {
        if (bound != null) {
            result.success(true)
            return
        }
        pending.add(result)
        if (callback == null) register()
        if (timeout == null) {
            val t = Runnable {
                timeout = null
                completePending(false)
            }
            timeout = t
            main.postDelayed(t, BIND_WAIT_MS)
        }
    }

    fun unbind() {
        callback?.let {
            try {
                cm.unregisterNetworkCallback(it)
            } catch (err: Exception) {
                Log.w(TAG, "unregister failed", err)
            }
        }
        callback = null
        bound = null
        capSignature = null
        linkSignature = null
        clearProcessBinding()
        timeout?.let { main.removeCallbacks(it) }
        timeout = null
        completePending(false)
    }

    private fun register() {
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                main.post {
                    if (callback !== this) return@post
                    bound = network
                    val ok = try {
                        cm.bindProcessToNetwork(network)
                    } catch (err: Exception) {
                        Log.w(TAG, "bindProcessToNetwork failed", err)
                        false
                    }
                    Log.i(TAG, "Bound to $network ok=$ok")
                    emit("available", network)
                    completePending(ok)
                }
            }

            override fun onLost(network: Network) {
                main.post {
                    if (callback !== this) return@post
                    // A roam can deliver onAvailable(new) before onLost(old);
                    // only the network we are bound to clears the binding.
                    if (bound != null && bound != network) return@post
                    bound = null
                    capSignature = null
                    linkSignature = null
                    clearProcessBinding()
                    Log.i(TAG, "Lost $network")
                    emit("lost", network)
                }
            }

            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                val sig = capabilitySignature(caps)
                main.post {
                    if (callback !== this) return@post
                    if (sig == capSignature) return@post
                    val first = capSignature == null
                    capSignature = sig
                    // The very first delivery just describes the network we
                    // already announced as `available`.
                    if (!first) emit("changed", network)
                }
            }

            override fun onLinkPropertiesChanged(network: Network, props: LinkProperties) {
                val sig = props.toString()
                main.post {
                    if (callback !== this) return@post
                    if (sig == linkSignature) return@post
                    val first = linkSignature == null
                    linkSignature = sig
                    if (!first) emit("changed", network)
                }
            }
        }
        callback = cb
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                cm.requestNetwork(request, cb, main)
            } else {
                cm.requestNetwork(request, cb)
            }
        } catch (err: Exception) {
            // SecurityException if CHANGE_NETWORK_STATE is missing, or
            // TooManyRequestsException. Report "not bound"; Dart carries on
            // with the default network.
            Log.w(TAG, "requestNetwork failed", err)
            callback = null
            completePending(false)
        }
    }

    /** validated + metered + BSSID: the facets that mean "different link". RSSI
     *  is deliberately excluded. BSSID is only a roam detector; without the
     *  location permission Android reports a constant placeholder, which is
     *  harmless. */
    private fun capabilitySignature(caps: NetworkCapabilities): String {
        val validated = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        val notMetered = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
        val bssid = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            (caps.transportInfo as? WifiInfo)?.bssid
        } else {
            null
        }
        return "v=$validated;nm=$notMetered;b=$bssid"
    }

    private fun clearProcessBinding() {
        try {
            cm.bindProcessToNetwork(null)
        } catch (err: Exception) {
            Log.w(TAG, "unbind failed", err)
        }
    }

    private fun completePending(value: Boolean) {
        if (pending.isEmpty()) return
        timeout?.let { main.removeCallbacks(it) }
        timeout = null
        val list = pending.toList()
        pending.clear()
        list.forEach { it.success(value) }
    }

    private fun emit(type: String, network: Network) {
        sink?.success(mapOf("type" to type, "networkId" to network.toString()))
    }
}

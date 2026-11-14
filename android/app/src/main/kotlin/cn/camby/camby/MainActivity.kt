package cn.camby.camby

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.view.Display
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.SecureRandom
import java.security.cert.X509Certificate
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "hdrCapabilities") {
                    result.success(readHdrCapabilities())
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NETWORK_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "setMulticastLock") {
                    result.success(setMulticastLock(call.argument<Boolean>("enabled") == true))
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SECURITY_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "setIgnoreSsl") {
                    result.success(setIgnoreSsl(call.argument<Boolean>("enabled") == true))
                } else {
                    result.notImplemented()
                }
            }
    }

    /**
     * v2.0.87：让 Android 原生网络栈接受自签证书。
     *
     * `video_player` / ExoPlayer 的 `DefaultHttpDataSource` 基于
     * `HttpsURLConnection`，与 Dart 的 `HttpClient` 是两套独立的 TLS 栈。
     * 绿联影视中心固定 HTTPS 9443 + 自签证书，Dart 层登录 / 拉库 / 海报
     * 都能过，唯独 Exo 取流会 SSLHandshakeException → 能刷库但播放黑屏。
     * 这里换掉进程级默认 SSLSocketFactory / HostnameVerifier，Exo 随之放行。
     *
     * 作用域控制：只有用户在该服务器配置里勾选「忽略 SSL 证书校验」时由
     * AppState 打开；切回普通服务器 / 断开连接都会恢复系统默认，不会长期
     * 降低整个进程的安全等级。MPV 走 libmpv 自带网络栈，不受影响。
     */
    private fun setIgnoreSsl(enabled: Boolean): Map<String, Any> {
        return try {
            if (enabled) {
                val factory = trustAllFactory ?: createTrustAllFactory().also {
                    trustAllFactory = it
                }
                HttpsURLConnection.setDefaultSSLSocketFactory(factory)
                HttpsURLConnection.setDefaultHostnameVerifier { _, _ -> true }
            } else {
                HttpsURLConnection.setDefaultSSLSocketFactory(defaultSocketFactory)
                HttpsURLConnection.setDefaultHostnameVerifier(defaultHostnameVerifier)
            }
            mapOf("enabled" to enabled)
        } catch (e: Throwable) {
            mapOf("enabled" to false, "error" to "$e")
        }
    }

    private fun createTrustAllFactory(): SSLSocketFactory {
        val tm = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
        }
        return SSLContext.getInstance("TLS").apply {
            init(null, arrayOf<TrustManager>(tm), SecureRandom())
        }.socketFactory
    }

    /**
     * v2.0.84：SSDP 发现期间短暂持有 Wi-Fi 组播锁。
     *
     * Android 的 Wi-Fi 驱动默认过滤组播包以省电，不持锁时 Dart 发出的
     * M-SEARCH 会被直接丢掉，现象是「一直搜索不到投屏设备」。这里只在
     * 发现阶段 acquire、发现结束立刻 release，引用计数避免重入泄漏。
     * 投屏控制（AVTransport SOAP）走普通单播 HTTP，不需要这把锁。
     */
    private fun setMulticastLock(enabled: Boolean): Map<String, Any> {
        return try {
            if (enabled) {
                if (multicastLock == null) {
                    val wm = applicationContext
                        .getSystemService(Context.WIFI_SERVICE) as? WifiManager
                    multicastLock = wm?.createMulticastLock("camby.dlna")?.apply {
                        setReferenceCounted(true)
                    }
                }
                if (multicastLock?.isHeld != true) multicastLock?.acquire()
            } else {
                if (multicastLock?.isHeld == true) {
                    try {
                        multicastLock?.release()
                    } catch (_: Throwable) {
                    }
                }
            }
            mapOf("held" to (multicastLock?.isHeld == true))
        } catch (e: Throwable) {
            mapOf("held" to false, "error" to "$e")
        }
    }

    override fun onDestroy() {
        try {
            if (multicastLock?.isHeld == true) multicastLock?.release()
        } catch (_: Throwable) {
        }
        multicastLock = null
        super.onDestroy()
    }

    /**
     * v2.0.83：只做**诊断读取**，不尝试 HDR 直通。
     *
     * Flutter texture 不支持 HDR passthrough（media-kit 官方结论），所以这里
     * 拿到的能力仅用于播放信息面板提示用户：设备不支持 DV 时，DV Profile 5
     * 只能靠 mpv gpu-next 色调映射，实在不行就开「DV 保底转码」。
     *
     * HDR 类型用数值常量而非 Display.HdrCapabilities.HDR_TYPE_* ：HDR10_PLUS
     * 是 API 34 才有的常量，minSdk 28 上直接引用会有兼容性告警。
     */
    private fun readHdrCapabilities(): Map<String, Any> {
        return try {
            val display: Display? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                display
            } else {
                @Suppress("DEPRECATION")
                windowManager.defaultDisplay
            }
            val caps = display?.hdrCapabilities
            val supported = caps?.supportedHdrTypes
            val types = supported?.map { v ->
                when (v) {
                    1 -> "Dolby Vision" // HDR_TYPE_DOLBY_VISION
                    2 -> "HDR10" // HDR_TYPE_HDR10
                    3 -> "HLG" // HDR_TYPE_HLG
                    4 -> "HDR10+" // HDR_TYPE_HDR10_PLUS (API 34)
                    else -> "type_$v"
                }
            } ?: emptyList()
            mapOf(
                "isHdr" to (supported?.isNotEmpty() == true),
                "types" to types,
                "desiredMaxLuminance" to (caps?.desiredMaxAverageLuminance ?: 0f),
            )
        } catch (e: Throwable) {
            mapOf(
                "isHdr" to false,
                "types" to emptyList<String>(),
                "error" to "$e",
            )
        }
    }

    companion object {
        private const val CHANNEL = "cn.camby.camby/display"
        private const val NETWORK_CHANNEL = "cn.camby.camby/network"
        private const val SECURITY_CHANNEL = "cn.camby.camby/security"

        // 类加载时记下系统默认值，关闭开关时原样恢复。
        private val defaultSocketFactory: SSLSocketFactory =
            HttpsURLConnection.getDefaultSSLSocketFactory()
        private val defaultHostnameVerifier: HostnameVerifier =
            HttpsURLConnection.getDefaultHostnameVerifier()

        @Volatile
        private var trustAllFactory: SSLSocketFactory? = null
    }
}

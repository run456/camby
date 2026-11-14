package cn.camby.camby

import android.os.Build
import android.view.Display
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
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
    }
}

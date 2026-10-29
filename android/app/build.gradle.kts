import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 读取正式签名配置（key.properties 不存在时回退到 debug 签名）
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "cn.camby.camby"
    compileSdk = 36
    // 本项目不含 C/C++ 源码（Flutter 引擎为预编译产物），无需下载完整 NDK
    // ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // 正式包名。测试包可用 -PcambyAppId=<别的包名> 覆盖，
        // 以便和已安装的正式版共存（签名不同时无法覆盖安装）。
        val appIdOverride = project.findProperty("cambyAppId") as String?
        applicationId = appIdOverride ?: "cn.camby.camby"
        resValue(
            "string",
            "app_name",
            if (appIdOverride != null) "Camby Test" else "Camby",
        )
        // Camby 最低支持 Android 9 (API 28)，目标平台 Android 16 (API 36)
        minSdk = 28
        targetSdk = 36
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = keystoreProperties["storeFile"]?.let { file(it as String) }
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    // 允许在 defaultConfig 里用 resValue 生成 app_name（区分正式版 / 测试版）
    buildFeatures {
        resValues = true
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    // 仅保留 arm64-v8a：media_kit 的 AAR 内含多架构 libmpv/ffmpeg，
    // 不剥离会额外增加约 27MB（armeabi-v7a + x86_64）
    packaging {
        jniLibs {
            excludes += setOf(
                "lib/armeabi-v7a/*.so",
                "lib/x86_64/*.so",
                "lib/x86/*.so",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

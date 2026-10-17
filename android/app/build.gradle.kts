import java.util.Properties
import java.util.Base64

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val signingProperties = Properties()
val signingFile = rootProject.file("key.properties")
if (signingFile.exists()) signingFile.inputStream().use { signingProperties.load(it) }
val isReleaseTask = gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }
if ((System.getenv("FLUX_RELEASE_BUILD") == "1" || isReleaseTask) && !signingFile.exists()) {
    throw GradleException("Publishing requires android/key.properties and a release keystore.")
}
val storeBuild = (project.findProperty("dart-defines") as String?)?.split(",")
    ?.any { runCatching { String(Base64.getDecoder().decode(it)) == "STORE_BUILD=true" }.getOrDefault(false) } ?: false

android {
    signingConfigs {
        if (signingFile.exists()) {
            create("release") {
                keyAlias = signingProperties.getProperty("keyAlias")
                keyPassword = signingProperties.getProperty("keyPassword")
                storeFile = file(requireNotNull(signingProperties.getProperty("storeFile")))
                storePassword = signingProperties.getProperty("storePassword")
            }
        }
    }
    namespace = "com.aur.flux"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.auralix.flux"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        require(flutter.versionCode in 1..209989999) { "Build exceeds Android versionCode range" }
        versionCode = 100000 + flutter.versionCode * 10
        versionName = flutter.versionName
        buildConfigField("boolean", "DIRECT_DIST", (!storeBuild).toString())
    }
    buildFeatures { buildConfig = true }
    if (!storeBuild) {
        for (type in listOf("debug", "profile", "release")) {
            sourceSets.getByName(type).manifest.srcFile("src/direct/AndroidManifest.xml")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
        }
    }
}

// Preserve ordering when users switch between universal and split APKs.
@Suppress("DEPRECATION")
android.applicationVariants.configureEach {
    val base = versionCode
    outputs.configureEach {
        val apk = this as com.android.build.gradle.api.ApkVariantOutput
        val abi = apk.getFilter(com.android.build.VariantOutput.FilterType.ABI)
        apk.versionCodeOverride = base + (mapOf("armeabi-v7a" to 1, "arm64-v8a" to 2, "x86_64" to 4)[abi] ?: 0)
    }
}

dependencies { implementation("androidx.core:core:1.13.1") }

flutter {
    source = "../.."
}

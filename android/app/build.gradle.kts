plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    signingConfigs {
        create("release") {
            val keyPath = System.getenv("ANDROID_KEYSTORE_PATH")
            if (!keyPath.isNullOrBlank()) {
                storeFile = file(keyPath)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
            }
        }
    }
    namespace = "app.pocketssh.pocket_ssh"
    compileSdk = flutter.compileSdkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    buildTypes {
        getByName("release") {
            val hasReleaseSigning = !System.getenv("ANDROID_KEYSTORE_PATH").isNullOrBlank()
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            } else if (providers.gradleProperty("pocketsshPerformanceBuild").orNull == "true") {
                signingConfig = signingConfigs.getByName("debug")
            }
        }
    }

    defaultConfig {
        applicationId = "app.pocketssh.pocket_ssh"
        minSdk = flutter.minSdkVersion
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }
}

flutter {
    source = "../.."
}

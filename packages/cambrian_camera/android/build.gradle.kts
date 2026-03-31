plugins {
    id("com.android.library")
    id("kotlin-android")
}

android {
    namespace = "com.cambrian.camera"
    // API 35 for latest Camera2 features; minSdk 33 targets Android 13+.
    compileSdk = 35
    // NDK version matching the OpenCV prebuilt used in Phase 4.
    ndkVersion = "25.1.8937393"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        minSdk = 33
    }

    // C++ JNI bridge and image pipeline (Phase 3+).
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }
}

dependencies {
    // androidx.lifecycle is used by the Flutter embedding; listed here so the IDE
    // can resolve lifecycle types during development. The Flutter plugin-loader
    // script injects flutter.jar (FlutterPlugin, ActivityAware, TextureRegistry, etc.)
    // as compileOnly automatically when this module is included by the host app.
    compileOnly("androidx.lifecycle:lifecycle-common:2.7.0")
}

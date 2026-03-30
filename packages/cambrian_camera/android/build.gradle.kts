plugins {
    id("com.android.library")
    id("kotlin-android")
}

android {
    namespace = "com.cambrian.camera"
    // API 35 for latest Camera2 features; minSdk 21 for broad device support.
    compileSdk = 35
    // NDK version matching the OpenCV prebuilt used in Phase 4.
    ndkVersion = "25.1.8937393"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = "11"
    }

    defaultConfig {
        minSdk = 21
    }

    // Phase 3+: C++ JNI bridge and image pipeline.
    // Uncommented in Phase 3 when CMakeLists.txt is added.
    // externalNativeBuild {
    //     cmake {
    //         path = file("src/main/cpp/CMakeLists.txt")
    //         version = "3.22.1"
    //     }
    // }
}

dependencies {
    // androidx.lifecycle is used by the Flutter embedding; listed here so the IDE
    // can resolve lifecycle types during development. The Flutter plugin-loader
    // script injects flutter.jar (FlutterPlugin, ActivityAware, TextureRegistry, etc.)
    // as compileOnly automatically when this module is included by the host app.
    compileOnly("androidx.lifecycle:lifecycle-common:2.7.0")
}

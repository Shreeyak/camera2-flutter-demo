# Kotlin Language Server Setup (Zed)

## Project Java Target

Both Android modules target **Java 17** (not 11 — the Flutter template default is outdated):

- `android/app/build.gradle.kts`
- `packages/cambrian_camera/android/build.gradle.kts`

```kotlin
compileOptions {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}
kotlinOptions {
    jvmTarget = "17"
}
```

The runtime JDK (Android Studio's JBR) is Java 21, which is fine — `jvmTarget` controls bytecode output format, not the JDK version used to run the compiler.

## Zed LSP Configuration

```json
"lsp": {
  "kotlin-language-server": {
    "binary": {
      "env": {
        "JAVA_HOME": "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
      }
    },
    "initialization_options": {
      "compiler": {
        "jvm": {
          "target": "17"
        }
      }
    }
  }
},
"languages": {
  "Kotlin": {
    "language_servers": ["kotlin-language-server"]
  }
}
```

Note: the server name is `kotlin-language-server`, not `kotlin-lsp`.

Open Zed rooted at `android/` (not the repo root) so KLS can find the Gradle project:

```bash
zed /path/to/camera2_flutter_demo/android
```

Or place a `.zed/settings.json` inside `android/` with the LSP config above.

## The `classes` Task Problem

KLS internally runs `./gradlew classes` to index sources. Android's AGP does not expose a root-level `classes` task — it uses per-variant tasks like `:app:compileDebugKotlin` instead.

Fix: a stub task in `android/build.gradle.kts` delegates to the real compile task:

```kotlin
// Allow kotlin-language-server to find a `classes` task
tasks.register("classes") {
    dependsOn(":app:compileDebugKotlin")
}
```

## Gradle Deprecation Warnings

Running `./gradlew --warning-mode all` shows warnings about:

- `ApkVariant` deprecation in `FlutterPlugin.kt`
- Groovy DSL space-assignment syntax
- `Task.project` at execution time

All originate from **Flutter's own Gradle plugin**, not project code. They are warnings about future Gradle versions and can be safely ignored until Flutter updates its tooling.

To suppress the deprecation banner in build output, add to `android/gradle.properties`:

```properties
org.gradle.warning.mode=summary
```

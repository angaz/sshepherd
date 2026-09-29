plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}
android {
    namespace = "io.angaz.sshepherd"
    compileSdk = 35
    ndkVersion = "28.0.13004108"
    defaultConfig {
        applicationId = "io.angaz.sshepherd"
        minSdk = 26
        targetSdk = 35
        versionCode = 10
        versionName = "0.3.0-native"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildTypes { release { isMinifyEnabled = false } }
    packaging { jniLibs.useLegacyPackaging = false }
    testOptions { unitTests.isIncludeAndroidResources = true }
}
// Native Android Views + Material Components; no web runtime.
dependencies {
    implementation("com.google.android.material:material:1.12.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.14.1")
}
tasks.register("verifyNative") {
    doLast {
        for (abi in listOf("arm64-v8a", "x86_64")) {
            for (library in listOf("sshepherd", "sshepherd_terminal")) {
                check(file("src/main/jniLibs/$abi/lib$library.so").isFile) {
                    "Missing $abi $library. Run scripts/build-android.sh first."
                }
            }
        }
        check(fileTree("src/main/assets").none { it.extension in listOf("html", "js", "wasm") }) {
            "Stale web assets must not be packaged in this native app. Run scripts/build-android.sh."
        }
    }
}
tasks.named("preBuild") { dependsOn("verifyNative") }

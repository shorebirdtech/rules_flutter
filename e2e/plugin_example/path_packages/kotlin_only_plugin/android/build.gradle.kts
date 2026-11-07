plugins {
    id("com.android.library")
    id("kotlin-android")
}

android {
    namespace = "com.example.kotlin_only_plugin"
    compileSdk = 35

    defaultConfig {
        minSdk = 24
    }
}

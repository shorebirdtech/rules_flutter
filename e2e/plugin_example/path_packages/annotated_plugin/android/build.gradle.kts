group = "com.example.annotated_plugin"
version = "1.0-SNAPSHOT"

plugins {
    id("com.android.library")
    id("kotlin-android")
}

android {
    namespace = "com.example.annotated_plugin"
    compileSdk = 35

    defaultConfig {
        minSdk = 24
    }
}

dependencies {
    // A BOM entry: not a dependency rules_flutter reads. The root's
    // `flutter_pub.annotation` states what it stands for.
    implementation(platform("androidx.compose:compose-bom:2024.01.00"))
}

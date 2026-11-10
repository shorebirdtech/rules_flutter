package com.example.annotated_plugin

import androidx.browser.customtabs.CustomTabsIntent
import io.flutter.embedding.engine.plugins.FlutterPlugin

/** Uses a class of `androidx.browser`, which only the root's annotation provides. */
class AnnotatedPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        CustomTabsIntent.Builder().build()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
}

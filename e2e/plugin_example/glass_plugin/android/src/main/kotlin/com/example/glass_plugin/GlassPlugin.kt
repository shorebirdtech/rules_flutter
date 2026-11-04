package com.example.glass_plugin

import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class GlassPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // BuildConfig is generated for the plugin's namespace, as Gradle does.
        if (BuildConfig.DEBUG) Log.d("GlassPlugin", "attached to engine")
        channel = MethodChannel(binding.binaryMessenger, "glass_plugin")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // Android has no system-wide reduce-transparency setting.
            "reduceTransparency" -> result.success(
                mapOf("platform" to "android", "reduceTransparency" to false),
            )
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }
}

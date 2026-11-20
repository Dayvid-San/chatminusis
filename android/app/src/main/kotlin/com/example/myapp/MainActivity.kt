package com.example.myapp

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.PersistableBundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity is required by local_auth (biometric prompt).
class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Blocks screenshots, screen recording and the preview in the recent apps list.
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The only way a message leaves the app is the user choosing "Copy". This copies it
        // flagged as sensitive (Android 13+) so the system does not show it in the clipboard preview.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "chatminusis/private_clipboard")
            .setMethodCallHandler { call, result ->
                if (call.method != "copy") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val text = call.argument<String>("text") ?: ""
                val clip = ClipData.newPlainText("", text)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    clip.description.extras = PersistableBundle().apply {
                        putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
                    }
                }
                (getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(clip)
                result.success(null)
            }
    }
}

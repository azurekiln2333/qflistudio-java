package com.azurekiln.qfli.jvmx

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val jdkWorker = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "qfli_jvmx/jdk")
            .setMethodCallHandler { call, result ->
                if (call.method != "prepare") {
                    result.notImplemented()
                } else {
                    jdkWorker.execute {
                        try {
                            val layout = JdkRuntime(applicationContext).prepare()
                            runOnUiThread { result.success(layout) }
                        } catch (error: Exception) {
                            runOnUiThread { result.error("JDK_PREPARE_FAILED", error.message, null) }
                        }
                    }
                }
            }
    }

    override fun onDestroy() {
        jdkWorker.shutdown()
        super.onDestroy()
    }
}

package com.studyapp.recall_app

import android.os.Handler
import android.os.Looper
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.SamplerConfig
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class OnDeviceAiChannel {
    companion object {
        private const val CHANNEL = "recall_app/on_device_ai"

        private val mainHandler = Handler(Looper.getMainLooper())
        private val executor = Executors.newSingleThreadExecutor()

        lateinit var appContext: android.content.Context

        // Engine init is expensive (~10s) so we cache it per model path and only
        // create a cheap Conversation per inference. Switching model path
        // re-initializes.
        private var cachedEngine: Engine? = null
        private var cachedModelPath: String? = null

        fun register(flutterEngine: FlutterEngine) {
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                CHANNEL
            ).setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
                when (call.method) {
                    "checkModel" -> handleCheckModel(call, result)
                    "runInference" -> handleRunInference(call, result)
                    "unloadModel" -> handleUnloadModel(result)
                    "totalRamMb" -> handleTotalRamMb(result)
                    else -> result.notImplemented()
                }
            }
        }

        // Lazily create + cache a LiteRT-LM Engine for [modelPath]. Must be
        // called on [executor] (initialize() blocks for several seconds).
        private fun ensureEngine(modelPath: String): Engine {
            val existing = cachedEngine
            if (existing != null && cachedModelPath == modelPath) {
                return existing
            }
            releaseEngine()

            val config = EngineConfig(
                modelPath = modelPath,
                // CPU is the safest default across Android devices. GPU can be
                // added later after per-device compatibility checks.
                backend = Backend.CPU(),
                cacheDir = appContext.cacheDir.path,
            )
            val engine = Engine(config)
            engine.initialize()
            cachedEngine = engine
            cachedModelPath = modelPath
            return engine
        }

        private fun handleCheckModel(call: MethodCall, result: MethodChannel.Result) {
            val modelPath = call.argument<String>("modelPath").orEmpty().trim()
            executor.execute {
                try {
                    if (modelPath.isEmpty()) {
                        postSuccess(result, mapOf(
                            "ready" to false,
                            "message" to "No model path provided."
                        ))
                        return@execute
                    }
                    val file = File(modelPath)
                    if (!file.exists()) {
                        postSuccess(result, mapOf(
                            "ready" to false,
                            "message" to "Model file not found: $modelPath"
                        ))
                        return@execute
                    }
                    val sizeMb = file.length() / (1024 * 1024)

                    // Actually load the model to confirm it is a valid LiteRT-LM
                    // model (not just that the file exists). Cached for reuse.
                    ensureEngine(modelPath)

                    postSuccess(result, mapOf(
                        "ready" to true,
                        "message" to "Model ready ($sizeMb MB)",
                        "sizeMb" to sizeMb
                    ))
                } catch (t: Throwable) {
                    releaseEngine()
                    postSuccess(result, mapOf(
                        "ready" to false,
                        "message" to "Model load failed: ${t.message}"
                    ))
                }
            }
        }

        private fun handleRunInference(call: MethodCall, result: MethodChannel.Result) {
            val modelPath = call.argument<String>("modelPath").orEmpty().trim()
            val prompt = call.argument<String>("prompt").orEmpty()
            // LiteRT-LM 0.12.0 does not expose a max output token setting on
            // ConversationConfig; keep reading the channel value for API
            // compatibility with the Dart engine contract.
            @Suppress("UNUSED_VARIABLE")
            val maxTokens = call.argument<Int>("maxTokens") ?: 2048
            // temperature=0 → greedy/deterministic (best for our structured
            // JSON extraction); topK=1 forces the single most likely token.
            val temperature = call.argument<Double>("temperature") ?: 0.0
            val topK = (call.argument<Int>("topK") ?: 1).coerceAtLeast(1)

            executor.execute {
                try {
                    if (modelPath.isEmpty()) {
                        postError(result, "no_model", "No model path provided.", null)
                        return@execute
                    }
                    if (prompt.isBlank()) {
                        postError(result, "no_prompt", "Prompt is empty.", null)
                        return@execute
                    }

                    val engine = ensureEngine(modelPath)

                    val sampler = SamplerConfig(
                        topK = topK,
                        topP = 1.0,
                        temperature = temperature,
                    )
                    val conversation = engine.createConversation(
                        ConversationConfig(samplerConfig = sampler)
                    )

                    val response = try {
                        extractText(conversation.sendMessage(prompt)).trim()
                    } finally {
                        conversation.close()
                    }

                    if (response.isEmpty()) {
                        postError(result, "empty_response", "Model returned empty response.", null)
                        return@execute
                    }
                    postSuccess(result, response)
                } catch (t: Throwable) {
                    releaseEngine()
                    postError(result, "inference_failed", t.message ?: t.javaClass.simpleName, null)
                }
            }
        }

        private fun handleUnloadModel(result: MethodChannel.Result) {
            executor.execute {
                releaseEngine()
                postSuccess(result, "unloaded")
            }
        }

        // Reports total physical RAM (MB) so the Dart AiCapabilityService can
        // pick the right model tier (Gemma 4 E2B vs Qwen3 0.6B vs fallback).
        private fun handleTotalRamMb(result: MethodChannel.Result) {
            try {
                val am = appContext.getSystemService(
                    android.content.Context.ACTIVITY_SERVICE
                ) as android.app.ActivityManager
                val memInfo = android.app.ActivityManager.MemoryInfo()
                am.getMemoryInfo(memInfo)
                val totalMb = (memInfo.totalMem / (1024 * 1024)).toInt()
                postSuccess(result, totalMb)
            } catch (t: Throwable) {
                postError(
                    result,
                    "ram_query_failed",
                    t.message ?: t.javaClass.simpleName,
                    null
                )
            }
        }

        private fun releaseEngine() {
            try {
                cachedEngine?.close()
            } catch (_: Throwable) {}
            cachedEngine = null
            cachedModelPath = null
        }

        private fun extractText(message: com.google.ai.edge.litertlm.Message): String {
            return message.contents.contents
                .filterIsInstance<Content.Text>()
                .joinToString(separator = "") { it.text }
        }

        private fun postSuccess(result: MethodChannel.Result, value: Any) {
            mainHandler.post { result.success(value) }
        }

        private fun postError(result: MethodChannel.Result, code: String, message: String, details: Any?) {
            mainHandler.post { result.error(code, message, details) }
        }
    }
}

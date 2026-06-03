# AI 模型選型 + 引擎遷移規劃（v2，2026-06）

> 本文修訂 `ai_strategy_plan.md` 的「模型/引擎」部分。觸發點：使用者質疑「為什麼不用
> Gemma 4 或 Qwen」。查證後發現原本的引擎假設已過時，故重新規劃。

---

## 0. 一句話結論

真正的決策不是「選哪個模型」，而是 **把 Android 本地引擎從已被 Google 淘汰的
MediaPipe LLM Inference API 遷移到 LiteRT-LM**。遷移完成後，Gemma 3n / Gemma 4 /
Qwen3 都能用**同一套引擎**跑、自由切換——所以我們可以、也應該為這個繁體中文 app
把 **Qwen3 當文字任務的預設**，Gemma 3n/4 留給多模態（拍照建卡）。

---

## 1. 關鍵事實更新（2026-06，已查證）

| 事實 | 影響 |
|------|------|
| **MediaPipe LLM Inference 的 Android/iOS 版已 deprecated**，官方建議遷移到 LiteRT-LM | 我們現有的 `OnDeviceAiChannel.kt` 用的是 EOL API，遲早要換 |
| **LiteRT-LM** 跨平台（Android/iOS/Web/Desktop），支援 **Gemma 3/3n/4、Qwen、Phi、Llama** | 一套引擎跑所有候選模型，不必再為 Qwen 引入 llama.cpp |
| `litert-community`（HF）有**現成轉好的端上檔**，如 `litert-community/Qwen3-0.6B` | Qwen 端上不必自己轉檔，可得性確認 |
| 效能參考：Gemma 4 E2B 在 LiteRT-LM 約 55 tok/s；Qwen 3.5 2B 在 MLX 約 61 tok/s | Gemma 4 / Qwen 端上都實際可用 |

> 我之前把 Qwen 列為「需 llama.cpp、所以只能當選項」——**這個理由已不成立**，特此更正。

---

## 2. 修正後的模型選型

| 模型 | 繁中 | 多模態 | LiteRT 現成檔 | RAM | 在本 app 的定位 |
|------|------|--------|---------------|-----|-----------------|
| **Qwen3（1.7B / 4B）** | ★★★★★ | 文字為主 | ✅（litert-community） | 1.7B≈2GB / 4B≈4–6GB | **文字任務預設**（提示/口訣/診斷/例句/干擾選項） |
| **Gemma 3n E2B/E4B** | ★★★ | ✅ 文字+圖+音 | ✅ | E2B<1.5GB / E4B≈3GB | **多模態任務**（拍照建卡）、低階機通用 |
| **Gemma 4 E2B** | ★★★ | ✅ | ✅ | ≈3GB | Gemma 3n 的升級替代（LiteRT-LM 上速度好） |
| **Apple Foundation Models** | ★★★ | ✅ | —（OS 內建，免下載） | OS 管理 | **iOS 預設**（零下載、免費、離線） |
| Phi-4-mini / Llama 3.2 | 中 / 弱 | 部分 | ✅ | ≈3GB | 不推（繁中弱於 Qwen） |
| DeepSeek（V3/V4） | 強 | — | ❌（伺服器級） | 跑不動 | 端上不用；最多雲端 fallback |

### 為什麼這樣排
- 這是**繁體中文高中生 app**，主力 AI 任務（提示、口訣、答錯診斷、例句、干擾選項）幾乎都是**短文字**且**中文品質至上** → **Qwen3 是最合理的預設**。
- 但**拍照建卡**需要看圖（多模態），Qwen 端上多模態支援未確認 → 這類任務交給 **Gemma 3n/4**（多模態在 LiteRT 上較成熟）或雲端 fallback。
- iOS 仍以 **Apple FM** 為主（零下載、免費）；LiteRT-LM 當作舊 iOS 的 fallback。

---

## 3. 引擎策略：遷移到 LiteRT-LM

### 現況
- `OnDeviceAiChannel.kt`（Kotlin）用 `com.google.mediapipe:tasks-genai` 的 `LlmInference`（**deprecated**）。
- 只能跑 Gemma 系列；Qwen / Gemma 4 在這個 API 上支援有限。

### 目標
- Android native 改用 **LiteRT-LM**（runtime + 對應 Gradle 依賴）。
- 一套引擎依「模型檔」切換 Gemma 3n / Gemma 4 / Qwen3。
- iOS 之後可共用 LiteRT-LM 當 Apple FM 的 fallback（跨平台紅利）。

### 已建好的架構讓遷移很省（C1 的回報）
- Dart 端早已抽象成 `LocalLlmEngine` + `AiRouter`，**完全與底層引擎無關**。
- 遷移只需：① 換 native 實作（Kotlin 內 MediaPipe → LiteRT-LM）② 更新 `ai_model_catalog.dart` 的模型清單與真實 URL。**Dart 業務邏輯、路由、UI 幾乎不動。**

---

## 4. 我的推薦（決策建議）

1. **引擎：遷移到 LiteRT-LM**（必做，因為 MediaPipe 行動版已 EOL；不遷移＝技術債）。
2. **Android 文字任務預設：Qwen3**——尺寸依裝置（RAM≥6GB 用 4B，否則 1.7B）。理由：繁中品質最好，且本 app 任務以短文字為主。
3. **多模態（拍照建卡）：Gemma 3n E2B**（保留多模態能力）；低階機 / 失敗時走雲端。
4. **Gemma 4 E2B**：列為 Gemma 3n 的升級候選，待實機驗證速度/品質後可替換。
5. **iOS：Apple FM 為主**，LiteRT-LM（Qwen/Gemma）為舊機 fallback。
6. **使用者可切換**：設定頁的模型卡支援「中文優先（Qwen）/ 多模態（Gemma）」切換——架構已支援。

> 換句話說：你想用 Qwen 和 Gemma 4 是對的，現在技術上也成立。代價是要先做**引擎遷移**這件 native 工程。

---

## 5. 修正後的 Roadmap

| 階段 | 內容 | 能否在純文字環境驗證 |
|------|------|----------------------|
| **C2.5（新增，關鍵）** | Android native：MediaPipe `LlmInference` → **LiteRT-LM** 遷移 | ❌ 需 Android Studio + 實機 build |
| C3-catalog | 更新 `ai_model_catalog.dart`：真實 litert-community URL + Qwen3 / Gemma 3n / Gemma 4 多筆 + SHA256 | ✅ 純 Dart（URL 需你確認） |
| C2-iOS native | Apple FM 的 Swift channel（先前規劃，iOS 之後做） | ❌ 需 Xcode + 實機 |
| C4 | 新本地功能（例句 / 智慧干擾選項 / L2 口訣按鈕 / AI 家教） | ✅ 純 Dart |

> 你目前的指示是「先確定 Android 能跑、iOS 之後」。對應到這份規劃：
> **Android 的下一步是 C2.5 引擎遷移**（這樣才能用 Qwen / Gemma 4），而不是急著填 URL。

---

## 6. 風險與取捨

| 風險 / 取捨 | 說明 | 建議 |
|------------|------|------|
| 遷移成本 | LiteRT-LM 的 Kotlin API 與 MediaPipe 不同，要重寫 `OnDeviceAiChannel.kt` 的推論部分 | 因 MediaPipe 已 EOL，遲早要做，越早越省 |
| 模型大小 vs 雙模型 | Qwen（文字）+ Gemma（多模態）= 兩份模型佔空間 | 先單一預設（看主力任務），多模態用雲端 fallback；之後再讓進階使用者加裝第二個 |
| Qwen 端上多模態未確認 | Qwen3.5 號稱原生多模態，但 LiteRT 端上多模態支援度待查 | 多模態先押 Gemma 3n/4，Qwen 專注文字 |
| 模型版本變動快 | Qwen3 → 3.5 → 3.6、Gemma 4 都在迭代 | catalog 設計成「資料」，換版本只改一行 |
| 我無法在此驗證 native | LiteRT-LM 遷移、Apple FM 都要實機 build | 我寫草稿 + 註解，你在 IDE build + 實機測 |

---

## 附：與既有程式的關聯
- `ai_strategy_plan.md`：本文取代其中「Android 用 MediaPipe tasks-genai」的假設。
- `lib/services/ai/`（C1 已建）：引擎抽象讓本遷移幾乎不動 Dart——這是當初先做基礎建設的回報。
- `OnDeviceAiChannel.kt`：C2.5 遷移的主要改動點。
- `ai_model_catalog.dart`：placeholder URL 要換成 litert-community 的真實連結，並擴充為多模型。

**Sources:**
[LiteRT-LM Overview](https://ai.google.dev/edge/litert-lm/overview) ·
[MediaPipe LLM Inference guide（含 deprecation 公告）](https://ai.google.dev/edge/mediapipe/solutions/genai/llm_inference) ·
[LiteRT 通用框架](https://developers.googleblog.com/litert-the-universal-framework-for-on-device-ai/) ·
[litert-community/Qwen3-0.6B](https://huggingface.co/litert-community/Qwen3-0.6B) ·
[iPhone 本地 runtime 實測（MLX/llama.cpp/LiteRT-LM/CoreML）](https://rockyshikoku.medium.com/local-llm-on-iphone-which-runtime-is-actually-fastest-58096685481e)

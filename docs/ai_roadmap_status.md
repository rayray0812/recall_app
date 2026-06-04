# Grasp AI 功能 — 現況與待辦 Roadmap

> **這份文件的用途**：清空對話後接續開發的單一入口。記錄本地優先 AI 的整體進度、
> 還沒做的功能、以及只能在實機驗證的待辦。最後更新：2026-06-04（L2/L3/智慧干擾完成；策略轉向「重新分流+加保護」見 §2.5）。
>
> 相關文件：`ai_strategy_plan.md`（本地優先策略總綱）、`ai_model_engine_plan.md`
> （模型選型 + LiteRT-LM 引擎遷移）。本檔是「目前做到哪 / 接下來做什麼」的彙整。

---

## 0. 核心定位（不變的北極星）
**第一個完全免費、離線、隱私優先的 AI 記憶 app。** 本地模型優先，雲端僅 fallback。
差異化：Quizlet AI 鎖付費、Anki 要自填 key、其他都上傳雲端 → 我們免費 + 資料不離手機
（對未成年族群同時是合規加分）。

## 1. 架構總覽（程式碼位置）
所有 AI 路由基礎建設在 `lib/services/ai/`：
- `local_llm_engine.dart` — `LocalLlmEngine` 介面 + `AndroidLiteRtLmEngine`（包 `OnDeviceAiService`）/ `AppleFoundationModelsEngine`（iOS, MethodChannel）/ `NullLocalLlmEngine`。
- `ai_capability_service.dart` — 偵測平台 / RAM / Apple FM；`AiCapability.resolve()` 純函式決定 `ModelTier`。
- `ai_model_catalog.dart` — `AiModelSpec` + 目錄（Gemma 4 E2B / Qwen3 0.6B，皆 Apache-2.0 直連下載）+ `recommended()`。
- `model_manager_service.dart` — 背景下載（`background_downloader`）+ SHA-256 驗證 + 安裝狀態/刪除。
- `ai_router.dart` — 任務→tier 政策表 + 純函式 `route()`。
- `lib/providers/ai_runtime_provider.dart` — 把以上接到 Riverpod（capability / engine / privacy / online / route providers）。
- Native：`android/.../OnDeviceAiChannel.kt`（LiteRT-LM：checkModel/runInference/unloadModel/totalRamMb）。
- 既有任務服務：`local_ai_service.dart`（L1 提示 / L2 口訣 / L3 混淆診斷 / 例句），prompt builders + cleaners 有單元測試。

**路由原則**：短/高頻/隱私 → localOnly（提示、口訣、診斷、例句）；拍照建卡、口說評分 → localPreferred；對話 → cloudPreferred。`localLlmEngineProvider` 先用使用者明確選的模型，否則 fallback 推薦模型。

## 2. 已完成 ✅（commit 參考）
- **C1 路由基礎建設**（`e95c853`）：engine 介面 + capability + catalog + manager + router + 22 測試。
- **C2-Dart**（`4aa9287`）：Apple Foundation Models 引擎（Dart 端）+ iOS 接線。
- **C3-1**（`cc904a6`）：Riverpod runtime providers + 隱私模式開關。
- **C3-2**（`fdfef7b` → `af39436`）：下載式模型管理 UI，列出所有模型可下載/切換/移除。
- **C3-3**（`f00235e`）：L1/L2/L3 改走 `aiRouteProvider` + 引擎抽象。
- **LiteRT-LM Android native**（`8fd00b1`）：MediaPipe → LiteRT-LM 遷移（草稿，需實機驗證）。
- **背景下載**（`9fb2f5c`，前身 `3017d8c`/`6d12114`/`994f6dd`）：鎖屏/背景續傳 + 進度節流 + 友善錯誤。
- **設定頁美化**（`52fe513`）：白話說明 + 隱私 SwitchListTile + 手動匯入收進「進階」。
- **C4 第一個功能：AI 例句生成**（`0d44d8f`）：卡片編輯頁 ✨ 按鈕,填入 `exampleSentence`。
- **AGP 8.9.1**（`15d3ec6`）：background_downloader 需要。
- **Code review 修正**（`f098b99`）：模型切換生效、availability 不再載入大模型、SHA-256 驗證機制、本機=不上雲、通知權限。
- **Flutter 官方 skills 安裝**（`7007b1e`）：`.claude/skills/` 10 個。

## 2.5 策略轉向（2026-06-04）⚠️ 重要
使用者提出**耗電/發熱/小模型品質**的疑慮。重新評估後決定「**重新分流 + 加保護**」：
- **本地只留罕見、短、隱私敏感的任務**（L1 提示 / L2 口訣 / L3 診斷 / 例句）——使用者主動點、頻率低、就算慢也沒差。這才是「免費+離線+隱私」賣點的真正體現。
- **高頻/重型任務應走雲端優先**（免費 Groq），本地只當離線/隱私 fallback。智慧干擾選項（每題自動觸發）是最高耗電風險，AI 家教（多輪連續生成）次之。
- **已加全域保護**（`e3d5317`）：`DevicePowerPolicy` + `AiRouter.localInferenceAllowed` gate + `localInferenceAllowedProvider`（battery_plus）。省電模式 / 低電量未充電 → 自動停用本地推論（localOnly 隱藏、localPreferred/cloudPreferred 轉雲端）。fail-safe：讀不到電量就允許。10 測試。
- **AI 家教暫不做**（原 roadmap B 最後一項）。決定：若日後做，走 **cloudPreferred**（不是 localPreferred），用既有 conversation 雲端基礎。
- **核心未驗證假設**：沒有人在實機跑過這些本地模型，延遲/發熱/品質全未知。**在 A 段實機驗證之前，不該再加更多本地 AI 功能。**

### A. 實機驗證（只能你在電腦/手機做，擋住後續）
- [ ] **LiteRT-LM native build**：`flutter run` 驗證 `OnDeviceAiChannel.kt` 編得過、能跑。VERIFY 點：`SamplerConfig(topK,topP,temperature)` 欄位、`extractText`/`message.text`、`litertlm-android:0.12.0` 版號、`Backend.CPU()`。
- [ ] **模型下載**：設定→AI→本機→下載 Qwen3 0.6B（614MB，先測流程）；確認鎖屏續傳、通知列進度。
- [ ] **端到端**：下載完 → SRS 複習「💡 提示」/ 卡片「✨ AI 例句」有反應。
- [ ] 填 catalog 的真實 **SHA-256**（實機下載成功後算 `shasum -a 256 <file>`，填進 `ai_model_catalog.dart`，啟用完整性驗證）。
- [ ] **智慧干擾選項延遲驗證**：實機測模型生成 3 個干擾選項要多久。目前是「進到該題才預取、就緒才換上」，若太慢使用者可能先看到隨機卡選項。觀察換上的時機是否自然；必要時改成「整份測驗開始前先批次預取前 N 題」。

### B. 還沒做的本地 AI 功能（純 Dart，可在對話內驗證）
- [x] **L2 口訣按鈕**（`cd3a77b`）：🧠 口訣 pill 加在 SRS 複習翻面後（評分按鈕上方），點擊呼叫 `mnemonicProvider` 顯示口訣 bubble。`localMnemonicAvailableProvider` gate 顯示、fail-silent。l10n（中/英）+ 3 widget 測試。
- [x] **L3 答錯混淆診斷對話框**（`5ff331c`）：選擇題主回合答錯且本地 AI 就緒時，暫停自動前進、顯示「🧠 為什麼會搞混?」按鈕 + 手動「下一步」。點按彈出 `ConfusionDiagnosisDialog`，呼叫 `confusionExplanationProvider` 對比選錯的干擾卡 vs 正解。`localConfusionAvailableProvider` gate、無模型時流程不變。l10n（中/英）+ 3 widget 測試。
- [x] **智慧干擾選項**（`e0743fa`）：新 `AiTaskType.smartDistractors`（localOnly）。測驗選擇題**懶載入**呼叫本地模型生成似是而非的錯誤選項，就緒才換上；隨機卡選項仍為永遠正確的基準與 fallback，計分不會卡在模型。`LocalAiService.generateDistractors` + `buildDistractorsPrompt`（正/反向）+ `parseDistractorLines`（去編號/項目符號/標籤、去重、排除正解、cap count）+ provider + 8 單元測試。answered-with-AI 時跳過 L3 診斷（無真實干擾卡可對比）。
  - **⚠️ 待重新分流**：依 §2.5 策略，這個高頻任務應改成 cloudPreferred。**但需先寫一個 Groq 雲端干擾選項生成器**（`smartDistractorsProvider` 目前 `!decision.isLocal → return null`，改 tier 後上線時會靜默關閉）。目前先靠電量保護 gate 緩解。下一步：加 `GroqVisionService`/新服務的文字補全干擾選項路徑，再把 tier 改 cloudPreferred。
- [x] **AI 家教對話 → 改為「增強現有對話功能」**（`2c8709f`）：不另建 Socratic 家教，而是把既有（雲端 Gemini）的情境對話**綁上 FSRS 弱點**。原本對話目標單字是隨機選；現在依弱點分數（overdue/難度/lapses/relearning/低 stability）weakest-first 排序選詞，練到真正不熟的字，且**零本地耗電**。`weak_term_selector.dart`（純函式 termWeaknessScore + 穩定 orderTermsByWeakness）+ `VocabularyTracker.priorityOrder`（向後相容，null = 原隨機行為）+ provider `_weaknessOrderedTerms`（讀 CardProgress，出錯 fallback 原順序）+ 11 測試。
  - 後續可再加：對話評分改進、weak-first 選詞加一點隨機性增加變化。
- [ ] 模式：每個新功能 = 加一個 `AiTaskType` + `LocalAiService` 方法 + prompt builder + provider/widget + 測試（參考 `0d44d8f` 例句的做法）。

### C. C2 iOS native（需 Xcode + 實機，無法在對話內驗證）
- [ ] iOS Swift MethodChannel 實作 `appleFoundationModelsAvailable` / `appleGenerate`（Apple Foundation Models framework, iOS 26+）。Dart 端 `AppleFoundationModelsEngine` 已就緒,native 一接上 iOS 就有本地 AI。
- [ ] Android Kotlin `totalRamMb` 已實作（在 OnDeviceAiChannel.kt），驗證即可。

### D. 健壯性 follow-up
- [ ] **背景下載 kill-resume tracking**：目前用 awaited `download()`,app 被系統殺掉後不會自動續傳。要改 `enqueue` + `FileDownloader().trackTasks()` + listener + 啟動時掃描未完成任務。
- [ ] 模型升級路徑：Gemma 4 E4B（高階機）、Qwen3 更大尺寸（等 litert-community 有現成檔）。

## 4. 重要提醒（給接手的對話）
- **Native（Kotlin/Swift）+ Gradle/pubspec 改動無法在純文字環境驗證** → 必須使用者實機 build。寫 native 一律標 VERIFY 點。
- **改 native / 加套件 → 要完整重 build，不能 hot reload**；純 Dart 改動才能 hot reload。
- **有第二個 agent（Codex）在 master 上平行做 community/admin** → commit 時只 stage 自己的檔案,別 `git add -A`。
- `flutter analyze` 已排除 `flutter-skills-repo/`（vendored，gitignored）。
- 模型 catalog 的下載 URL 是真實、Apache-2.0、未 gated（HF litert-community）。SHA-256 欄位故意留 null,別亂填（填錯會讓正常下載被誤判失敗）。
- 雲端服務（Gemini/Groq）仍需使用者自填 API key,存 `flutter_secure_storage`。

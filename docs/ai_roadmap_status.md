# Grasp AI 功能 — 現況與待辦 Roadmap

> **這份文件的用途**：清空對話後接續開發的單一入口。記錄本地優先 AI 的整體進度、
> 還沒做的功能、以及只能在實機驗證的待辦。最後更新：2026-06-05（智慧干擾選項重新分流為 cloudPreferred + Groq 雲端生成器完成，見 §2.5/§B）。
>
> 相關文件：`ai_strategy_plan.md`（本地優先策略總綱）、`ai_model_engine_plan.md`
> （模型選型 + LiteRT-LM 引擎遷移）。本檔是「目前做到哪 / 接下來做什麼」的彙整。

---

## 0. 核心定位（2026-06-04 更新）
AI 不再單獨作為「免費離線」賣點，而是服務新的產品主線：

> **台灣考試導向的 AI 主動回想教練。**

AI 的角色是補強 FSRS 與 ExamPlan：
- 短、低頻、隱私敏感任務：本地優先，保留「資料不離手機」賣點。
- 高頻、重型、品質敏感任務：雲端優先，受 quota / entitlement / cost logging 控制。
- 所有 AI 產出都應回到學習閉環：例句、答錯診斷、弱點字對話、考試 readiness。

產品文件主入口：`docs/product_master_plan.md`。

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

**路由原則（修正版）**：
- localOnly/localPreferred：L1 提示、L2 口訣、L3 診斷、短例句。這些是使用者主動點、頻率低、隱私敏感的任務。
- cloudPreferred：AI 對話、智慧干擾選項、批量建卡、長摘要。這些任務重品質/速度/穩定，不應預設消耗手機電力。
- 所有雲端任務必須先經過未來的 `AiGatewayService` + `AiQuotaService`，不能由 UI 直接呼叫 provider。

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

### 2.6 商業化與成本閘門（新增）
AI 功能上線到學生市場前，必須補齊：

- `AiGatewayService`：統一 route、provider fallback、safety、analytics。
- `AiQuotaService`：每日免費額度、Plus/Pro AI 額度、用量耗盡降級。
- `ai_usage_events`：記錄 taskType、provider、estimated input/output tokens、latency、result/failure。
- entitlement：free / plus / pro_ai / classroom。

短期不要承諾「所有 AI 免費無限用」。正確承諾是：

> 核心記憶功能免費；高成本 AI 功能有免費額度，重度使用需 Plus/Pro AI。

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
  - [x] **重新分流完成**：`smartDistractors` tier 改為 **cloudPreferred**（線上→Groq 雲端、離線→本地引擎 fallback）。新 `GroqCompletionService`（OpenAI 相容 chat completions，純 `buildBody`/`parseContent` 可測；`generateDistractors` 復用 `LocalAiService.buildDistractorsPrompt`/`parseDistractorLines` 使本地/雲端產出格式一致，並記 AiAnalytics）。`smartDistractorsProvider` 改為 cloud 分支（無 Groq key→null）/ local 分支 / unavailable→null。`localDistractorsAvailableProvider` 更名 `smartDistractorsAvailableProvider`（判斷 `target != unavailable`，不再只看 isLocal）。電量保護 gate 仍適用於離線本地 fallback。新增 5 測試（tier=cloudPreferred、cloud/offline 路由、buildBody、parseContent）。
    - 後續：若使用者只填 Gemini key（未填 Groq），雲端干擾選項目前不會啟用（僅 Groq 路徑）；要支援 Gemini 雲端干擾可再加。雲端干擾品質需實機/填 key 驗證。
- [x] **AI 家教對話 → 改為「增強現有對話功能」**（`2c8709f`）：不另建 Socratic 家教，而是把既有（雲端 Gemini）的情境對話**綁上 FSRS 弱點**。原本對話目標單字是隨機選；現在依弱點分數（overdue/難度/lapses/relearning/低 stability）weakest-first 排序選詞，練到真正不熟的字，且**零本地耗電**。`weak_term_selector.dart`（純函式 termWeaknessScore + 穩定 orderTermsByWeakness）+ `VocabularyTracker.priorityOrder`（向後相容，null = 原隨機行為）+ provider `_weaknessOrderedTerms`（讀 CardProgress，出錯 fallback 原順序）+ 11 測試。
  - 後續可再加：weak-first 選詞加一點隨機性增加變化。
- [x] **情境對話「針對性大改」**（`987945f`→`58d24bd`，4 階段）：使用者回報「很不完整、效果很差」。診斷三根因並重做（保留聊天 UI/語音/儲存/summary，state 契約不變）：
  - **S1 統一無狀態引擎**（`987945f`）：`ConversationEngine` 抽象 + `GeminiConversationEngine`（gemini-2.0-flash，非 lite）+ `GroqConversationEngine`（llama-3.3-70b，pure body/parse）+ `FallbackConversationEngine`（跨供應商 fallback）+ `conversationEngineProvider`（依 AiProvider 排序）。12 測試。
  - **S2 自然對話核心 + prompt**（`5e86958`）：`conversation_prompts.dart`——自然角色扮演、回應學生、目標單字「自然才用」不強制、無固定兩行格式。provider 改走引擎、**移除僵硬替換機制**（_containsAnyFocusTerm/_isScenarioAlignedQuestion/_looksUnnaturalQuestion + 罐頭 fallback、_parseAiTurnContent、Gemini model 輪替）。跨供應商 fallback 取代「降級成罐頭 local coach」當第一道防線。latestReplyHint 退役（鷹架改用既有 suggested replies）。12 測試。
  - **S3 情境品質**（`95ef04a`）：`conversation_scenario_validator.dart`——移除「情境須字面含 N 個目標單字」硬門檻（詞彙字本就不會字面出現 → 好情境被誤退成通用 fallback）。情境生成 prompt 改為「依單字主題挑合適真實情境」。9 測試。
  - **S4 評分**（`58d24bd`）：`buildScoringPrompt` 要求**非空、可行動**的修正句 + 一句具體提示（取代舊「沒錯就留空」）。Gemini 升 flash。新增 `evaluateTurnGroq`（Groq-only 也有真 AI 評分）+ provider `_scoreWithFallback`（偏好供應商優先、另一個 fallback、再離線）。`evaluateOffline` 給可行動提示（不再空白）。6 測試。
  - **⚠️ 品質需實機驗證**：自然度/情境貼合/評分品質需填 Gemini 或 Groq key 跑一場對話實測（文字環境無法驗證）。舊 `GeminiService.startConversation`/`chatModels` 現為 dead code，可清理。
- [ ] 模式：每個新功能 = 加一個 `AiTaskType` + `LocalAiService` 方法 + prompt builder + provider/widget + 測試（參考 `0d44d8f` 例句的做法）。

### C. C2 iOS native（需 Xcode + 實機，無法在對話內驗證）
- [ ] iOS Swift MethodChannel 實作 `appleFoundationModelsAvailable` / `appleGenerate`（Apple Foundation Models framework, iOS 26+）。Dart 端 `AppleFoundationModelsEngine` 已就緒,native 一接上 iOS 就有本地 AI。
- [ ] Android Kotlin `totalRamMb` 已實作（在 OnDeviceAiChannel.kt），驗證即可。

### D. 健壯性 follow-up
- [ ] **背景下載 kill-resume tracking**：目前用 awaited `download()`,app 被系統殺掉後不會自動續傳。要改 `enqueue` + `FileDownloader().trackTasks()` + listener + 啟動時掃描未完成任務。
- [ ] 模型升級路徑：Gemma 4 E4B（高階機）、Qwen3 更大尺寸（等 litert-community 有現成檔）。
- [ ] **AiGateway/Quota**：新增統一 AI 閘門，所有雲端 AI 任務都必須記錄用量與成本 bucket。
- [ ] **ExamPlan 連動**：AI 對話與例句應優先使用 `ExamPlan` 的 examType / targetLevel / weak terms。

## 4. 重要提醒（給接手的對話）
- **Native（Kotlin/Swift）+ Gradle/pubspec 改動無法在純文字環境驗證** → 必須使用者實機 build。寫 native 一律標 VERIFY 點。
- **改 native / 加套件 → 要完整重 build，不能 hot reload**；純 Dart 改動才能 hot reload。
- **有第二個 agent（Codex）在 master 上平行做 community/admin** → commit 時只 stage 自己的檔案,別 `git add -A`。
- `flutter analyze` 已排除 `flutter-skills-repo/`（vendored，gitignored）。
- 模型 catalog 的下載 URL 是真實、Apache-2.0、未 gated（HF litert-community）。SHA-256 欄位故意留 null,別亂填（填錯會讓正常下載被誤判失敗）。
- 雲端服務（Gemini/Groq）仍需使用者自填 API key,存 `flutter_secure_storage`。

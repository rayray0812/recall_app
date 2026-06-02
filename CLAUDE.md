# 專案：拾憶（Recall）— 開源 Quizlet 替代方案（高中生適用）
# 技術棧：Flutter (Mobile + Web), Supabase (後端/驗證 + 雲端同步), Hive (本地離線儲存)
# 狀態管理：Riverpod | 資料模型：freezed | 路由：GoRouter

## 使用者決策（已確認）

- 從一開始就使用 Supabase + Hive
- 三種學習模式：翻卡片、測驗、配對遊戲
- 驗證為選用（支援訪客模式，離線優先）

---

## 目前進度

所有基礎步驟 + 功能擴充 + FSRS + 驗證強化 + 管理後台 + UI 優化 + Daily Challenge + Grasp Phase 0 + A + B + B+ 皆已完成。
程式碼通過 `flutter test`（372 個測試全部通過）。
`flutter analyze` 無問題（2026-06-02）。

### 基礎建設（Step 1–10）✅
- [x] Step 1：專案骨架 + 核心設定
- [x] Step 2：資料模型（freezed）+ Hive 轉接器
- [x] Step 3：本地儲存服務（Hive CRUD）
- [x] Step 4：Supabase 服務（驗證 + 同步）
- [x] Step 5：Riverpod 狀態管理
- [x] Step 6：驗證畫面（登入/註冊/訪客）
- [x] Step 7：首頁 + 學習集列表
- [x] Step 8：WebView 匯入器（JS 注入抓取 Quizlet）
- [x] Step 9：三種學習模式（翻卡片/測驗/配對）
- [x] Step 10：GoRouter 路由設定

### 功能擴充（Feature 1–6）✅
- [x] F1：Import 頁 URL 輸入欄（TextField + 前往按鈕，自動補 https://）
- [x] F2：手動新增/編輯單字卡（CardEditorScreen + CardEditRow）
- [x] F3：匯入與匯出 JSON/CSV（ImportExportService + file_picker + share_plus）
- [x] F4：測驗與配對可選題目數量（CountPickerDialog）
- [x] F5：Tinder 風格滑動翻卡片（SwipeCardStack）
- [x] F6：拍照建卡（image_picker + Gemini Flash API，兩種模式）

### FSRS 間隔重複（Phase 1–6）✅
- [x] P1：資料基礎（CardProgress + ReviewLog 模型 / Hive 轉接器 / tags 欄位）
- [x] P2：FSRS 演算法（fsrs 套件引入 / FsrsService / Riverpod providers）
- [x] P3：SRS 複習畫面（翻卡片 + 評分 Again/Hard/Good/Easy / 複習結果）
- [x] P4：首頁整合 + 擴充功能（TodayReviewCard banner / 建立時自動初始化 CardProgress）
- [x] P5：統計儀表板（fl_chart 每日複習 / 熱力圖 / 正確率 / 連續天數 streak）
- [x] P6：自訂學習計畫（自訂學習頁面 / 跨學習集搜尋 / 批次標籤管理）

### 驗證系統強化（2026-02-13）✅
- [x] 忘記密碼、Google/Apple OAuth、Magic Link 登入
- [x] 生物辨識解鎖（指紋/Face ID）
- [x] 路由守衛 + 深層連結 + session 驗證
- [x] Security Center（全域登出、刪除帳號、加密備份）
- [x] 同步衝突偵測 + 解決 UI
- [x] Auth 分析日誌 + 統一錯誤訊息

### UI / 視覺設計（2026-02-13）✅
- [x] Liquid Glass 毛玻璃元件（iOS 限定，Android 用實色卡片）
- [x] Adaptive Glass Card（統一 API 跨平台切換）
- [x] 毛玻璃 Navigation Bar / App Bar / Bottom Sheet / 各種卡片
- [x] TTS 語音品質升級（智慧語音選擇）

### Daily Challenge（2026-02-07 + 2026-02-14 完善）✅
- [x] Daily Mission Card（每日目標 10 張 + 進度條 + streak）
- [x] 完成獎勵 UX（Toast 通知 + 綠色漸層 + 打勾 icon）
- [x] l10n 字串（中/英 9 個 key）
- [x] Widget tests（3 個狀態）+ Provider streak edge-case tests（7 個）

### Home Screen Widgets（W1+W2, 2026-02-07）✅
- [x] Daily Mission Card widget + Pressure Progress Bar widget
- [x] WidgetSnapshotService + widgetRefreshProvider
- [x] Deep Link: `recall://review` scheme

### 管理後台（Admin, 2026-02-13）✅
- [x] 帳號管理（封鎖/解鎖、角色分配、稽核日誌）
- [x] 審核工作流 + 冒充登入 + 批次作業
- [x] 合規匯出（HMAC 簽章）+ SLA 升級 + 治理自動化
- [x] 6 個 SQL migration + 3 個 Edge Function + 1 個 GitHub Actions CI

### 功能擴充 F7–F12（2026-02-14）✅
- [x] F7：資料夾分類（Folder model + Hive adapter + 管理頁面 + FolderChips 篩選）
- [x] F8：排序 & 釘選 & 滑動刪除（SortOption + isPinned/lastStudiedAt + Dismissible + undo）
- [x] F9：Onboarding 引導頁（3 頁 PageView + dot indicators + 首次啟動重定向）
- [x] F10：QR Code 分享學習集（qr_flutter + mobile_scanner + ShareCodec + deep link）
- [x] F11：成就徽章系統（12 個 AppBadge + BadgeChecker + 成就頁面）
- [x] F12：番茄鐘學習計時器（PomodoroNotifier + 全域 FAB overlay + TimerDial）

### Wrong Answer Revenge Mode（2026-02-16）✅
- [x] Revenge Provider（revengeCardIdsProvider + revengeCardCountProvider）
- [x] RevengeCard widget（首頁錯題複習入口）
- [x] Review Summary 加入 Revenge Mode 完成 banner（紫色「已清除 X 道錯題！」）
- [x] l10n 字串（中/英 revengeClearedCount）
- [x] RevengeCard widget test（4 個）
- [x] Quiz scoring unit tests（10 個）
- [x] QuizOptionTile widget test（4 個）
- [x] Deep-link routing test（7 個）

### Groq Cloud Vision 整合（2026-02-28）✅
- [x] GroqVisionService（Llama 4 Scout, http POST, base64 image）
- [x] AiProvider enum + AiProviderNotifier（Hive settings box）
- [x] GroqKeyNotifier（FlutterSecureStorage）
- [x] photo_import_screen 依 AI Provider 切換 Gemini/Groq
- [x] settings_tab AI Provider 選擇器 + Groq API Key 輸入
- [x] l10n 字串（中/英 groqApiKey, groqFreeLabel, aiProvider 等）
- [x] 8 個 Groq service tests 全過

### UX 修正與強化（2026-03-25）✅
- [x] 學習集重新命名（長按選單 + ⋮ 按鈕開啟 context menu → 重新命名對話框）
- [x] 長按多選 + 批次移動資料夾（多選模式 + AppBar 計數 + 全選 + 底部操作列）
- [x] 匯入預覽「只看可疑」破版修正（Row → SingleChildScrollView 水平滾動）
- [x] 測驗模式去除詞性前綴（_stripPos regex 移除 POS 前綴，只顯示中文意思）
- [x] 測驗模式顯示 POS 標籤提示（從 card.tags 提取詞性，以 chip 形式顯示在題目下方）
- [x] StudySetCard 新增 onMore 回調 + ⋮ 按鈕（context menu 入口）
- [x] l10n 新增：rename / renameStudySet / selectedCount / batchMoveToFolder（中/英）

### Grasp Phase 0 Hotfix（2026-04-26）✅
- [x] 移除 conversation stability bypass（`_applyConversationSrsFeedback` 直接乘 0.8，繞過 FsrsService）
- [x] 清除 `(localStorage as dynamic)` dynamic cast
- [x] 修正 Daily Challenge 雙重計數 conversation（srsCount 過濾 conversation log，convBonus 半權重）
- [x] 補齊 `review_logs` Supabase schema（`review_type` + `speaking_score` 欄位）
- [x] 補齊 sync mapper 雙向傳送新欄位（`reviewLogToRow` / `rowToReviewLog` 抽為 static）
- [x] Migration：`202604260001_review_logs_extension.sql`
- [x] 新增 6 個測試（Daily Challenge 計數 × 2、sync round-trip × 4）

### Grasp Phase B+（2026-04-27）✅
- [x] `local_ai_service.dart`：3 個本地 AI 任務（L1 reviewHint / L2 mnemonic / L3 confusionDiagnosis）
- [x] 各任務 prompt builder（buildReviewHintPrompt / buildMnemonicPrompt / buildConfusionPrompt）抽為 static，可獨立測試
- [x] 輸出清理 cleaner（cleanSingleSentence / cleanShortParagraph）：strip 「提示：」「Hint:」label、引號、列舉符號
- [x] 透過 `_runWithAnalytics` 包裝，所有本地 AI 呼叫自動記到 AiAnalyticsService（Phase B 建立的）
- [x] 模型不可用時返回 null（不 throw），UI 層可安全 fail silent
- [x] AiTaskType 新增 reviewHint / mnemonic / confusionDiagnosis 三種
- [x] `local_ai_provider.dart`：`hasLocalAiModelProvider`（gate UI 顯示）+ `reviewHintProvider` / `mnemonicProvider` / `confusionExplanationProvider`（FutureProvider.autoDispose.family）
- [x] L1 UI 整合：`ReviewHintButton` widget 在 SRS 複習畫面（卡片正面、未翻時顯示）；模型未設時自動隱藏
- [x] `ReviewHintButton` 狀態機：未請求 → 請求中（loading spinner） → 顯示提示（💡 bubble）/ 失敗顯示 fallback 文案
- [x] l10n 字串（中/英 3 個 key：localHintCta / localHintGenerating / localHintUnavailable）
- [x] 新增 10 個測試（prompt builders × 3、cleaners × 7）

### Grasp Phase B（2026-04-27）✅
- [x] B1：`ai_error.dart`（ScanFailureReason / ScanException 從 gemini_service 移出；AiErrorClassifier.classifySdkError + classifyHttpError + isRateLimit）
- [x] B1：gemini_service.dart 移除 `_classifyAiError` + `_isRateLimitError` 私有方法，改用 AiErrorClassifier；gemini_service re-export ScanFailureReason / ScanException 維持向後相容
- [x] B1：groq_vision_service.dart 移除 `_classifyHttpError`，改用 AiErrorClassifier.classifyHttpError
- [x] B2：`ai_task.dart`（AiTaskType enum + AiTaskState sealed class: Idle/Running/Done/Error + AiTask descriptor）
- [x] B3：`ai_analytics_service.dart`（Hive-backed AI 操作日誌，max 100 records；logEvent / getRecentEvents / recentFailureCount）
- [x] B3：`app_constants.settingAiEventsKey = 'ai_events'`
- [x] B3：photo_import_screen `_callAiExtract` 重構為單一出口 + try-catch 接 AiAnalyticsService 日誌（success 和 ScanException 都記錄）
- [x] 新增 13 個測試（classifySdkError × 4、classifyHttpError × 5、AiTaskState × 4）

### Grasp Phase A（2026-04-27）✅
- [x] A1：ReviewLog 擴充 5 個欄位（sessionId/responseLatencyMs/chosenDistractorId/predictedRetrievability/metadata）
- [x] A1：更新 ReviewLogAdapter（Hive 手動序列化新欄位）
- [x] A1：更新 supabase_service reviewLogToRow / rowToReviewLog 新欄位雙向
- [x] A1：Migration `202704270001_review_logs_phase_a.sql`
- [x] A2：ReviewSession freezed 模型（id/userId/modality/startedAt/endedAt/itemCount/completedCount/scoreAvg/metadata）
- [x] A2：ReviewSessionAdapter（Hive typeId: 5）
- [x] A2：LocalStorageService CRUD（saveReviewSession/getReviewSession/getAllReviewSessions/...）
- [x] A2：SupabaseService upsertReviewSessions sync
- [x] A2：Migration `202704270002_review_sessions.sql`（含 RLS + FK）
- [x] A3：OutcomeAdapter（ConversationOutcome enum + FsrsAction sealed class + resolve()）
- [x] A3：conversation_session_provider 接入 OutcomeAdapter（未使用詞彙 → rating=1 → FsrsService）
- [x] A3：conversation 建立 ReviewSession，ReviewLog 帶 sessionId
- [x] 新增 10 個測試（OutcomeAdapter × 4、ReviewSession × 3、ReviewLog Phase A × 3）

### 待辦 / 下一步
- [ ] 在 Supabase 執行 migrations（`202604260001` + `202704270001` + `202704270002`）
- [ ] 在 `supabase_constants.dart` 填入真實 Supabase URL 和 anon key
- [x] 清理 `community_screen.dart` 的 15 個 unused element warning
- [ ] 實機測試驗證（Android/iOS/Web）
- [ ] WebView 匯入功能實測
- [ ] 開始 Grasp Phase C（embedding pipeline + G1 contextual memory MVP）
- [ ] L2/L3 UI 整合（card editor 加口訣按鈕、quiz 答錯後加混淆診斷對話框）
- [ ] 模型升級至 Gemma 3 4B（PRD §4.4，目前是 2B）

---

## 專案結構

```
recall_app/lib/
├── main.dart                         # 初始化 Hive（4 boxes）、Supabase、ProviderScope
├── app.dart                          # MaterialApp.router + GoRouter + 主題
├── core/
│   ├── constants/
│   │   ├── app_constants.dart        # 應用常數（含 SRS box 名稱）
│   │   └── supabase_constants.dart   # Supabase URL + anon key（需替換）
│   ├── theme/
│   │   └── app_theme.dart            # Material 3 亮/暗主題
│   ├── router/
│   │   └── app_router.dart           # GoRouter 路由定義（含 SRS/統計/搜尋路由）
│   └── l10n/
│       └── app_localizations.dart    # 多語系（中文/英文，含 SRS/統計/Daily Challenge）
├── models/
│   ├── study_set.dart                # freezed 模型
│   ├── flashcard.dart                # freezed 模型（含 tags 欄位）
│   ├── card_progress.dart            # freezed 模型（SRS 狀態：stability/difficulty/due...）
│   ├── review_log.dart               # freezed 模型（複習記錄：rating/state/reviewedAt...）
│   ├── folder.dart                   # freezed 模型（資料夾：id/name/colorHex/iconCodePoint）
│   ├── badge.dart                    # freezed 模型（AppBadge：成就徽章）
│   ├── pomodoro_state.dart           # freezed 模型（番茄鐘狀態）
│   └── adapters/
│       ├── study_set_adapter.dart    # 手動 Hive 轉接器（typeId: 0）
│       ├── flashcard_adapter.dart    # 手動 Hive 轉接器（typeId: 1，含 tags）
│       ├── card_progress_adapter.dart # 手動 Hive 轉接器（typeId: 2）
│       ├── review_log_adapter.dart   # 手動 Hive 轉接器（typeId: 3）
│       └── folder_adapter.dart      # 手動 Hive 轉接器（typeId: 4）
├── services/
│   ├── local_storage_service.dart    # Hive CRUD（StudySet + CardProgress + ReviewLog）
│   ├── fsrs_service.dart             # FSRS 演算法（reviewCard / getSchedulingPreview）
│   ├── supabase_service.dart         # 驗證 + 資料同步
│   ├── sync_service.dart             # 離線優先同步邏輯
│   ├── import_export_service.dart    # JSON/CSV 匯出入（F3）
│   ├── gemini_service.dart           # Gemini Flash API 多模態（F6）
│   ├── groq_vision_service.dart     # Groq Cloud Vision API（Llama 4 Scout）
│   ├── badge_definitions.dart       # 12 個成就徽章定義（F11）
│   └── badge_checker.dart           # 徽章解鎖條件判斷（F11）
├── providers/
│   ├── study_set_provider.dart       # StudySetsNotifier（自動建立 CardProgress）
│   ├── fsrs_provider.dart            # dueCards / dueCount / dueBreakdown providers
│   ├── daily_challenge_provider.dart # Daily Challenge 狀態 + streak 計算
│   ├── stats_provider.dart           # 統計資料（todayCount / streak / dailyCounts / heatmap）
│   ├── tag_provider.dart             # 標籤管理（allTags）
│   ├── auth_provider.dart            # 驗證狀態串流
│   ├── sync_provider.dart            # 登入後觸發同步
│   ├── locale_provider.dart          # 語言切換
│   ├── gemini_key_provider.dart      # Gemini API Key（SecureStorage）（F6）
│   ├── ai_provider_provider.dart    # AI Provider 選擇 + Groq Key（Gemini/Groq）
│   ├── folder_provider.dart         # FoldersNotifier + selectedFolderProvider（F7）
│   ├── sort_provider.dart           # SortOption enum + StateNotifier（F8）
│   ├── badge_provider.dart          # BadgeNotifier（F11）
│   └── pomodoro_provider.dart       # PomodoroNotifier + Timer（F12）
└── features/
    ├── auth/
    │   ├── screens/
    │   │   ├── login_screen.dart      # 登入畫面
    │   │   └── signup_screen.dart     # 註冊畫面
    │   └── widgets/
    │       └── auth_form.dart         # 共用表單元件
    ├── home/
    │   ├── screens/
    │   │   ├── home_screen.dart       # 學習集列表 + 每日複習 Banner + 搜尋/統計入口
    │   │   ├── card_editor_screen.dart # 卡片編輯頁（含標籤管理）
    │   │   └── search_screen.dart     # 跨學習集搜尋（term/definition/tags）
    │   └── widgets/
    │       ├── study_set_card.dart    # 學習集卡片元件（含編輯/刪除/⋮ 按鈕、待複習數）
    │       ├── card_edit_row.dart     # 單張卡片輸入列（含標籤）
    │       ├── today_review_card.dart # 每日複習 Banner（含 + 數量/學習集統計）
    │       ├── daily_challenge_card.dart # Daily Challenge 卡片（目標 10 張 + streak）
    │       └── tag_chips.dart         # 標籤顯示/編輯元件
    ├── import/
    │   ├── screens/
    │   │   ├── web_import_screen.dart      # WebView + URL 輸入欄 + FAB 匯入（F1）
    │   │   ├── review_import_screen.dart   # 預覽 & 編輯後儲存（含可疑篩選水平滾動）
    │   │   └── photo_import_screen.dart    # 拍照建卡主畫面（F6）
    │   ├── widgets/
    │   │   └── import_preview_card.dart    # 匯入預覽卡片
    │   └── utils/
    │       └── js_scraper.dart             # JS 注入腳本（4 種備援選擇器）
    ├── study/
    │   ├── screens/
    │   │   ├── study_mode_picker_screen.dart  # 選擇學習模式（SRS 複習 + 快速瀏覽 + 測驗 + 配對）
    │   │   ├── srs_review_screen.dart         # SRS 複習畫面（翻卡片 + 評分 4 級）
    │   │   ├── review_summary_screen.dart     # 複習結果頁
    │   │   ├── custom_study_screen.dart       # 自訂學習計畫
    │   │   ├── flashcard_screen.dart          # Tinder 風格滑動翻卡（快速瀏覽）
    │   │   ├── quiz_screen.dart               # 測驗（可選題數 + POS 標籤提示 + 去詞性前綴）
    │   │   └── matching_game_screen.dart      # 配對遊戲（可選組數）
    │   ├── widgets/
    │   │   ├── flip_card.dart                 # 自製翻轉卡片動畫
    │   │   ├── swipe_card_stack.dart          # 滑動卡片堆疊元件
    │   │   ├── rating_buttons.dart            # Again/Hard/Good/Easy 評分按鈕（含預覽間隔）
    │   │   ├── count_picker_dialog.dart       # 題數選擇 Dialog
    │   │   ├── quiz_option_tile.dart          # 測驗選項元件
    │   │   └── matching_tile.dart             # 配對方塊元件
    │   └── utils/
    │       └── part_of_speech.dart            # POS 標籤常數 + extractPartOfSpeechTags()
    └── stats/
        ├── screens/
        │   └── stats_screen.dart              # 統計儀表板（多頁卡片 + 圖表）
        └── widgets/
            ├── daily_chart.dart               # fl_chart 每日複習（最近 30 天）
            ├── review_heatmap.dart            # GitHub 風格 7×52 熱力圖
            └── accuracy_donut.dart            # 評分環形圖
```

---

## 關鍵架構決策
- **驗證為選用**：訪客模式完全離線可用，登入後啟用雲端同步
- **離線優先**：Hive 為主要儲存，Supabase 透過 `isSynced` 旗標同步
- **手動 Hive 轉接器**：因為 freezed 和 hive_generator 有衝突
- **Cards 存為 JSONB**：Supabase 單一欄位，500 張卡以內不需 join
- **WebView 僅限手機**：Flutter web 不支援 WebView，用 `kIsWeb` 擋掉
- **多重 JS 選擇器**：Quizlet 經常改 DOM，4 種備援策略提高穩定性
- **Tinder 風格翻卡**：快速瀏覽模式，SRS 複習模式有獨立畫面
- **題數自選**：測驗和配對模式透過 `state.extra` 傳遞數量參數
- **Gemini API Key 本地存**：使用者自行在設定頁輸入，存於 FlutterSecureStorage，不上傳雲端
- **Groq 作為免費替代方案**：Llama 4 Scout Vision API，不需信用卡，使用者可在設定頁切換 Gemini/Groq
- **CardProgress 獨立儲存**：SRS 不綁定 Flashcard，獨立 Hive box 追蹤複習進度
- **FSRS-5 標準實作**：直接引用 `fsrs` Dart 套件（2.0.1），不自己實作演算法
- **ReviewLog 獨立 box**：append-only 記錄方便後續統計和分析
- **所有 SRS DateTime 統一用 UTC**：避免時區問題
- **Daily Challenge 固定目標 10 張**：參考 Duolingo，降低啟動門檻
- **Liquid Glass 僅限 iOS**：Android GPU 碎片化，用 `isLiquidGlassSupported` 切換
- **POS 標籤存於 tags**：詞性標籤（n./v./adj. 等）存於 Flashcard.tags，測驗模式自動提取顯示
- **測驗去詞性前綴**：_stripPos regex 自動移除定義中的 POS 前綴，只顯示中文意思
- **多選模式**：首頁長按進入多選，底部操作列支援批次移動資料夾
- **StudySetCard.onMore**：⋮ 按鈕開啟 context menu（重新命名/釘選/移動/分享）

## 路由表
| 路徑 | 畫面 |
|------|------|
| `/` | 首頁（學習集列表 + 每日複習 Banner） |
| `/login` | 登入 |
| `/signup` | 註冊 |
| `/import` | WebView 匯入（含 URL 輸入欄） |
| `/import/review` | 匯入預覽編輯 |
| `/import/photo` | 拍照建卡（F6） |
| `/review` | 跨學習集 SRS 複習 |
| `/review/summary` | 複習結果頁 |
| `/stats` | 統計儀表板 |
| `/search` | 跨學習集搜尋 |
| `/study/custom` | 自訂學習計畫 |
| `/edit/:setId` | 卡片編輯頁（含標籤管理） |
| `/study/:setId` | 學習模式選擇（含匯出選單） |
| `/study/:setId/srs` | 單一學習集 SRS 複習 |
| `/study/:setId/flashcards` | 快速瀏覽（Tinder 風格滑動） |
| `/study/:setId/quiz` | 測驗模式（extra: questionCount） |
| `/study/:setId/match` | 配對遊戲（extra: pairCount） |
| `/study/:setId/share` | QR Code 分享學習集（F10） |
| `/onboarding` | 首次啟動引導頁（F9） |
| `/folders` | 資料夾管理（F7） |
| `/scan` | QR Code 掃描匯入（F10） |
| `/achievements` | 成就徽章頁面（F11） |

## Supabase 資料表結構（待建立）
```sql
create table study_sets (
  id uuid primary key,
  user_id uuid references auth.users(id),
  title text not null,
  description text default '',
  cards jsonb default '[]',
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- RLS 政策：使用者只能存取自己的資料
alter table study_sets enable row level security;
create policy "Users can CRUD own sets"
  on study_sets for all
  using (auth.uid() = user_id);
```

## 新增套件
- `file_picker` — 選擇 JSON/CSV 檔案匯入（F3）
- `share_plus` — 分享匯出的檔案（F3）
- `path_provider` — 暫存匯出檔案路徑（F3）
- `image_picker` — 相機/相簿選圖（F6）
- `google_generative_ai` — Gemini Flash API（F6）
- `fsrs` — FSRS-5 間隔重複演算法
- `fl_chart` — 統計圖表（柱狀/環形）
- `home_widget` — Android/iOS Home Screen Widget
- `qr_flutter` — QR 碼生成（F10）
- `mobile_scanner` — QR 碼掃描（F10）

## 開發日誌（學習歷程）
- 位置：`D:\work\quizlet\portfolio\journal\YYYY-MM-DD.md`（不進 git）
- 每次開發結束時，幫我產生當天的日誌，聚焦在：
  1. **我做出的關鍵決策** — 為什麼選擇 A 而不是 B，背後的思考
  2. **決策造成的影響** — 對架構、UX、維護性的實際影響
  3. **人機協作觀察** — AI 做得好/不好的地方，我介入修正了什麼
  4. **遇到的問題與解法** — Bug、環境問題等
  5. **今天學到的事** — 技術層面的收穫
- 用途：高中學習歷程檔案，不是技術文件

## 驗證清單
- [ ] `flutter run` 在 Android/iOS 模擬器上正常執行
- [ ] WebView 載入網頁，URL 輸入欄可導航，FAB 在題組頁面出現
- [ ] 匯入流程：抓取 -> 預覽 -> 儲存 -> 出現在首頁
- [ ] 檔案匯入：選 JSON/CSV -> 預覽 -> 儲存
- [ ] 匯出：JSON/CSV 透過分享功能匯出
- [ ] 卡片編輯：建立學習集 -> 進入編輯頁 -> 新增/刪除卡片 -> 加標籤 -> 儲存
- [ ] 三種學習模式皆可正常運作
- [ ] 測驗選題數 -> 只出指定數量；配對選組數 -> 只出指定數量
- [ ] 測驗模式：選項只顯示中文意思（不含詞性前綴），題目下方顯示 POS 標籤 chip
- [ ] 翻卡片：滑動分類 -> 結束統計 -> 複習不記得的
- [ ] SRS 複習：翻卡片 -> 評分 -> 狀態更新 -> 結果頁
- [ ] 每日複習 Banner：有待複習 -> 點擊進入跨學習集 SRS 複習
- [ ] 統計畫面：柱狀/熱力圖/正確率圖表正確顯示
- [ ] 搜尋：跨學習集搜尋 term/definition/tags
- [ ] Daily Challenge：進度條 + streak + 完成後變綠 + Toast
- [ ] 驗證流程：註冊 -> 登入 -> 同步 -> 登出 -> 本地資料保留
- [ ] 離線測試：飛航模式下 app 正常使用 Hive 資料
- [ ] 拍照建卡：設定 API Key -> FAB 選拍照建卡 -> 拍照/選圖 -> 選模式 -> AI 分析 -> 預覽 -> 儲存
- [ ] 未設定 API Key 時點「拍照建卡」-> 顯示提示訊息
- [ ] `flutter run -d chrome` 網頁版（匯入隱藏，其餘正常）
- [ ] 長按多選 -> 批次移動資料夾 -> 退出多選
- [ ] 學習集重新命名：⋮ 按鈕 -> 重新命名 -> 修改標題 -> 儲存
- [ ] 匯入預覽：按鈕列可水平滾動，不破版

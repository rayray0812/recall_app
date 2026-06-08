# Grasp 產品總規劃 Product Master Plan
更新日期：2026-06-04  
適用產品：Grasp（Flutter + Riverpod + Supabase + Hive/FSRS + Local/Cloud AI）

相關營運文件：
- [Cloud Sync & Storage Policy](cloud_sync_storage_policy.md)：定義哪些資料必須上雲、哪些 local-only、以及 review logs / AI usage 的節省策略。

## 0. 核心定位

Grasp 不再定位為泛用字卡工具，而是：

> **台灣考試導向的 AI 主動回想教練。**

產品承諾：

- 每天告訴學生「今天該複習哪些字」。
- 用 FSRS 控制長期記憶，不靠隨機刷題。
- 答錯時能解釋混淆原因。
- 用弱點字生成情境對話，讓學生真的會用。
- 以學測、全民英檢、多益校園需求作為內容與成長主線。

不追求成為另一個 Quizlet。Grasp 的差異化是「考試進度 + FSRS 科學排程 + AI 弱點補強」。

## 1. 產品現況盤點

### 1.1 已高度符合市場的能力

- **Flutter 跨平台**：適合台灣高中/大學生 Android + iOS 混合環境。
- **離線優先資料層**：目前以 Hive 儲存 study sets、card progress、review logs；弱網與通勤可用。
- **FSRS**：`FsrsService` 已包裝 `fsrs` package，保留 stability、difficulty、retrievability 等科學排程能力。
- **多模式學習**：SRS、Quiz、Matching、Revenge Mode、Daily Challenge 已形成基礎學習閉環。
- **AI 對話**：Gemini/Groq engine + fallback 已存在，並已接上 FSRS 弱點詞優先。
- **社群/教室雛形**：公開題庫、下載、收藏、評分、好友、教室與班級進度已具備 B2B 擴展基礎。
- **安全與治理**：Supabase migration 已涵蓋 RLS、admin、moderation、audit、community hardening。

### 1.2 目前不符合或存在防禦缺口

- **缺考試主線**：尚未有 `ExamPlan`、學測/GEPT/TOEIC 官方題庫、考試日期倒推與 readiness score。
- **AI 成本閘門不足**：已有 route，但缺 quota、entitlement、per-user token/cost logging。
- **雲端 AI 摩擦高**：conversation 仍要求使用者自填 Gemini/Groq API key，普通學生不會理解。
- **本地 AI 商業承諾過早**：LiteRT-LM 與模型下載尚需實機驗證；高頻本地推論可能慢、耗電、發熱。
- **社群過早泛化**：留言、好友、排行榜已做，但學生最需要的是可信考試題庫，不是泛社群雜訊。
- **開源可信度不足**：README 仍偏 Recall/工程啟動說明，缺 Grasp 品牌、架構圖、privacy model、contribution guide。
- **資料查詢擴展限制**：Hive 適合本地物件，但未來弱點地圖、考試分析、全文搜尋、題庫品質分會更適合 SQLite/Drift。

## 2. 北極星與 KPI

### 北極星

每週完成至少 3 天考試複習任務的活躍學習者（Weekly Exam-Ready Learners, WERL）。

### P0 KPI

- 首日建立/匯入第一套卡片比例。
- 首日完成第一次 FSRS 複習比例。
- D7 留存。
- 每週完成複習天數中位數。
- 考試計畫啟用率。
- AI 每活躍用戶月成本。

### P1 KPI

- 弱點字 7 日恢復率。
- 考前 30 天留存。
- AI 對話完成率。
- 官方題庫下載後 7 日活躍率。
- Free -> Plus 轉換率。

### P2 KPI

- 班級建立數。
- 老師派發題庫完成率。
- 班級學生週活躍率。
- 官方/認證題庫複習完成率。

## 3. 使用者分群與 JTBD

### S1：學測衝刺高中生

- 需求：短時間記住大量英文單字。
- JTBD：我只想知道今天該背什麼、哪些快忘了、哪些會考。
- 核心功能：ExamPlan、官方學測字表、FSRS Today Review、錯題診斷。

### S2：全民英檢/多益檢定生

- 需求：長期累積字彙與使用能力。
- JTBD：我不只要背意思，還要會在句子/口說中用。
- 核心功能：AI 例句、弱點字對話、情境練習、熟練度地圖。

### S3：大學生/自學者

- 需求：快速把課堂、PDF、照片變成可複習素材。
- JTBD：我不想手打卡片，只想把講義丟進去開始練。
- 核心功能：OCR/PDF/文字匯入、AI 清理、批次標籤。

### S4：老師/補習班/讀書會幹部

- 需求：派發題庫、追蹤完成率、看弱點。
- JTBD：我想知道學生有沒有真的複習，不只是拿到單字表。
- 核心功能：Classroom、官方/老師題庫、班級進度、弱點統計。

## 4. 核心產品閉環

### Daily Exam Loop

ExamPlan -> Today Review -> FSRS rating -> Summary -> 明日任務。

目標：讓學生每天不用思考，打開 App 就知道要做什麼。

### Recovery Loop

答錯/低 retrievability -> Revenge Mode / Quiz -> L3 混淆診斷 -> 重新排程。

目標：把錯題從挫折變成可恢復的任務。

### AI Usage Loop

弱點字 -> AI 例句 / 情境對話 -> 使用紀錄 -> 回寫 review logs / weakness score。

目標：AI 不只是聊天，而是補強 FSRS 辨識出的弱點。

### Growth Loop

官方/老師題庫 -> 下載/加入班級 -> 複習完成 -> 分享成果/邀請同學。

目標：先靠可信內容擴散，再逐步開放 UGC。

## 5. 技術架構方向

### 5.1 本地資料

短期保留 Hive，因為現有模型與 adapter 已成熟。

中期新增 SQLite/Drift，適合以下資料：

- review logs 大量查詢。
- exam readiness 聚合。
- weak term ranking。
- 題庫搜尋與官方題庫索引。
- AI usage/cost 本地快取。

建議分工：

- Hive：設定、少量 object、向後相容資料。
- SQLite/Drift：可查詢事件、學習分析、全文搜尋、考試統計。

### 5.2 AI Gateway

所有雲端/本地 AI 呼叫不得由 UI 直接呼叫 provider，需統一經過 `AiGatewayService`。若使用 Grasp 自有 provider key 供免費額度/付費會員使用，Flutter 端不得持有 key，必須走 Supabase Edge Function `ai-proxy`；使用者自備 key 則只存在本機 `flutter_secure_storage`。詳細安全邊界見 `docs/ai_cloud_proxy_security_plan.md`。

責任：

- `AiRouter` 分流。
- `AiQuotaService` 檢查免費/付費用量。
- provider fallback。
- token/cost 預估。
- safety filter。
- analytics event。
- owner-token proxy：JWT 驗證、server entitlement、server-side quota、task/model 白名單、prompt 大小限制。

必備資料表：

- `ai_usage_events`
- `ai_daily_usage`
- `user_ai_entitlements`

### 5.3 AI 分流策略

- localOnly：L1 review hint、L2 mnemonic、L3 confusion diagnosis、短例句。原因：使用者主動點、頻率低、隱私敏感。
- cloudPreferred：conversationTurn、smartDistractors、批量建卡、長摘要。原因：品質與速度比離線更重要。
- localPreferred：photoImport、speakingScore。原因：本地可省成本，但失敗需雲端 fallback。

`smartDistractors` 不應長期維持 localOnly。它是高頻任務，會放大耗電與延遲風險。

### 5.4 考試資料模型

新增：

- `ExamPlan`
  - id
  - examType: gsat / gept / toeic / custom
  - examDate
  - targetLevel
  - dailyMinutes
  - createdAt / updatedAt

- `OfficialDeck`
  - id
  - examType
  - level
  - title
  - sourceVersion
  - moderationStatus

- `CardExamTag`
  - cardId
  - examType
  - frequencyBand
  - difficulty
  - source

- `ExamReadinessSnapshot`
  - date
  - examPlanId
  - dueCount
  - weakCount
  - projectedRetention
  - dailyLoad

### 5.5 社群資料模型

公開題庫需要從「泛 UGC」改為「可信內容分層」。

新增或補強欄位：

- `source_type`: official / teacher_verified / user
- `exam_type`
- `quality_score`
- `moderation_status`
- `review_completion_rate`
- `report_rate`
- `duplicate_score`

預設排序應優先：

official > teacher_verified > high quality user content。

## 6. 產品與功能 Roadmap

### Phase 0：策略收斂與可信底盤（1-2 週）

- 更新 README 與品牌：Recall -> Grasp。
- 補架構圖、privacy model、local/cloud AI 說明。
- 實機驗證 LiteRT-LM：build、下載、推論、耗電、延遲。
- 建立 `AiGatewayService` 設計文件。
- 把 `smartDistractors` 從長期 localOnly 計畫中移出，規劃 cloudPreferred fallback。

驗收：

- README 能讓外部開發者 10 分鐘內理解產品。
- 本地模型實測有數據：首次載入、單次推論、溫度/電量變化。
- AI 任務表每一項都有 tier、quota、fallback。

### Phase 1：考試模式 MVP（2-6 週）

- `ExamPlan` model + provider + onboarding。
- 首頁加入考試倒數與每日任務。
- 官方題庫匯入格式：學測高頻、GEPT 中級、多益校園。
- Today Review 依 exam plan 加權排序。
- Summary 顯示：今日完成率、弱點數、預估覆蓋率。

驗收：

- 新使用者 3 分鐘內可選考試目標並開始複習。
- Today Review 可回答「今天為什麼要背這些字」。
- D1 完成首輪複習比例提升。

### Phase 2：弱點地圖與 AI 補強（6-10 週）

- Weakness Map：overdue、lapses、low stability、confusion。
- AI 例句與 L3 診斷統一進 `AiGatewayService`。
- 對話練習固定使用 FSRS 弱點詞。
- 對話 summary 回寫學習成果。
- AI quota：免費每日次數、Plus/Pro 額度。

驗收：

- 學生能看到「最危險的 20 個字」。
- AI 對話結束後能明確列出已用/未用/需複習字。
- AI 每 MAU 成本可追蹤。

### Phase 3：可信題庫與社群擴散（10-16 週）

- 官方題庫首頁入口。
- 公開題庫標記 source_type 與 exam_type。
- 題庫品質分：下載完成率、複習完成率、檢舉率、評分。
- 老師認證題庫流程。
- 留言/評分 moderation 預設啟用。

驗收：

- 使用者搜尋「學測」時優先看到官方/認證題庫。
- UGC 不會壓過可信內容。
- 題庫下載後 7 日活躍率可追蹤。

### Phase 4：班級版與商業化（16-24 週）

- Entitlement：free / plus / pro_ai / classroom。
- Plus：考試計畫、弱點地圖、同步容量、更多 AI 次數。
- Pro AI：AI 對話、批量建卡、PDF/OCR 強化。
- Classroom：派發題庫、完成率、弱點統計、班級排行榜。
- 老師 dashboard：學生完成率、弱點分布、未完成名單。

驗收：

- 付費牆不影響 FSRS 核心學習。
- AI 成本可被 quota 控制。
- 第一批老師/補習班可試用班級版。

### Phase 5：規模化與開源護城河（6-12 個月）

- Self-host Supabase guide。
- 開源 core / 商業 cloud 分層。
- 官方題庫版本管理。
- 匿名 benchmark：考前 30 天完成率、弱點恢復率。
- 多校/補習班合作。

## 7. 商業化規劃

### Free

- FSRS。
- 本地字卡。
- 基礎匯入。
- 官方基礎題庫。
- 每日少量 AI 例句/診斷。

### Plus（建議 NT$79/月，NT$790/年）

- 考試計畫。
- 弱點地圖。
- 更多 AI 診斷/例句。
- 多裝置同步容量提升。
- 官方題庫完整包。

### Pro AI（建議 NT$149/月）

- AI 情境對話。
- PDF/OCR 批量建卡。
- AI 批次清理與標籤。
- 進階學習分析。

### Classroom（建議 NT$1,500-3,000/班/學期起）

- 老師派發題庫。
- 班級完成率。
- 弱點統計。
- 認證題庫發布。

原則：

- 不要把 FSRS 鎖付費。
- 收費點放在「省時間」、「考試計畫」、「AI 額度」、「班級管理」。

## 8. 風險與防線

### AI 成本失控

- 對策：`AiQuotaService`、task-level quota、雲端任務成本記錄、Pro AI 才開長對話。

### 本地 AI 體驗不穩

- 對策：實機驗證後才預設開啟；本地模型標 Beta；高頻任務走雲端或規則 fallback。

### 社群內容品質低

- 對策：官方/老師認證優先；UGC 預設需品質分；未成年留言 moderation。

### 功能過度複雜

- 對策：首頁只顯示今日任務、考試倒數、弱點入口。社群、教室、AI 設定都不搶主流程。

### 同步/資料一致性

- 對策：保留 delta sync；補 sync smoke test；重要學習事件 append-only。

### 開源與商業衝突

- 對策：core open source，cloud services / official decks / classroom / quota 為商業服務。

## 9. 近期 2 週行動清單

1. 更新 README：Grasp 品牌、安裝、架構、隱私、AI 分流。
2. 實作 `ExamPlan` model/provider/storage。
3. 首頁加入考試倒數與今日任務文案。
4. 建立官方題庫資料格式與第一份 sample deck。
5. 設計 `AiGatewayService` / `AiQuotaService` 介面。
6. 修正 AI roadmap：`smartDistractors` 目標改 cloudPreferred。
7. 實機測 LiteRT-LM：紀錄延遲/耗電/模型品質。
8. 社群 plan 補 source_type / exam_type / quality_score。

## 10. 文件關聯

- AI 現況與待辦：`docs/ai_roadmap_status.md`
- AI 策略總綱：`docs/ai_strategy_plan.md`
- AI 模型引擎：`docs/ai_model_engine_plan.md`
- 社群規劃：`docs/community_feature_plan.md`
- RLS 驗證：`docs/rls_verification.md`
- Admin 計畫：`docs/admin_account_management_plan.md`

# 社群與可信題庫實作規劃

> 2026-06-04 策略更新：社群不再以泛 UGC/留言互動為主軸。Grasp 的社群應服務台灣考試市場，優先提供**可信考試題庫**、老師認證題庫與班級派發能力。好友、留言、排行榜是輔助擴散，不是核心價值。

## 已完成基礎

- 公開學習集列表、搜尋、排序、分類篩選。
- 學習集預覽、下載到本機、重複下載辨識。
- 發布、重新發布更新、取消發布。
- 收藏公開學習集，本機保存收藏清單。
- 依本機學習內容推薦相近公開學習集。
- 我的發布區塊與發布狀態標記。
- 作者個人檔案入口、公開發布統計。
- 檢舉公開學習集。
- 教室入口、建立/加入班級、班級列表。
- 本機好友清單與好友聯賽雛形。

## 後端功能進度

### Phase 1：互動訊號 ✅

- [x] 新增 `community_likes`：使用者可按讚公開學習集。
- [x] 新增 `community_saves`：收藏同步到雲端，跨裝置可用。
- [x] 新增 `community_downloads`：記錄每位使用者下載過哪些公開集，避免只靠內容比對。
- [x] 更新熱門排序：依 `like_count`、`save_count`、`download_count` 與建立時間排序。

### Phase 2：留言與評分 ✅

- [x] 新增 `community_comments`：留言、刪除自己的留言、作者可隱藏留言。
- [x] 新增 `community_ratings`：1-5 星評分，每人每套一筆。
- [x] 公開學習集卡片顯示平均評分、留言數。
- [x] 詳情頁加入留言串與評分入口。

### Phase 3：真實好友系統 ✅

- [x] 新增 `community_friendships`：pending/accepted/blocked 狀態。
- [x] 支援搜尋使用者、送出好友邀請、接受/拒絕。
- [x] 聯賽改用真實好友的週學習分鐘與複習完成數。
- [x] 個人檔案加入「加好友 / 已是好友 / 取消邀請」狀態。

### Phase 4：審核與安全

- [x] 管理後台加入檢舉列表、處理狀態、下架公開集。
- [x] 對被多次檢舉的公開集加上自動隱藏或人工審核佇列。
- [x] 留言加入敏感詞過濾與 `moderation_status` 審核流程。
- 針對未成年使用者限制公開個資欄位與留言顯示。
- [x] 加入內容安全欄位：`visibility`, `moderation_status`, `moderation_reason`。

## 驗收標準

- `flutter analyze` 無問題。
- 社群服務單元測試涵蓋：公開集比對、下載轉本機、收藏狀態。
- 好友系統驗證涵蓋：搜尋、邀請、接受/拒絕、RLS 與聚合排行榜 RPC。
- Widget smoke tests 覆蓋：空狀態、分類篩選、收藏切換、已下載狀態。
- Supabase migration 需附 RLS policy，且匿名使用者只能讀公開內容，不能寫互動資料。

## 下一階段：可信考試題庫（P0）

### 目標

讓學生搜尋「學測」、「全民英檢」、「多益」時，先看到官方/老師認證題庫，而不是一般使用者隨機發布內容。

### 資料模型補強

公開題庫需新增或補強欄位：

- `source_type`: `official` / `teacher_verified` / `user`
- `exam_type`: `gsat` / `gept` / `toeic` / `custom`
- `exam_level`: 例如 GEPT 初級/中級/中高級，或學測核心/進階
- `quality_score`: 綜合品質分
- `review_completion_rate`: 下載後實際完成複習比例
- `report_rate`: 檢舉率
- `duplicate_score`: 與既有公開題庫相似度

排序優先級：

1. official
2. teacher_verified
3. high quality user content
4. normal user content

### 產品入口

- 社群首頁新增「考試題庫」區塊。
- 預設 chips：學測、GEPT、多益、老師認證、我的學校/班級。
- 公開卡片顯示 source badge：官方 / 老師認證 / 社群。
- 未審核或低品質題庫不應進熱門榜。

### Moderation 原則

- 未成年市場下，留言與公開內容必須預設走 moderation。
- 官方/老師題庫可關閉留言，只保留評分與回報錯誤。
- 使用者回報錯字/錯解釋應進入 correction queue，而不是普通留言。

## 下一階段：班級與商業化（P1）

- 老師可建立班級並派發 official / teacher_verified 題庫。
- 班級 dashboard 顯示：
  - 完成率
  - 弱點單字排行
  - 逾期未複習學生
  - 題庫整體掌握度
- 班級題庫可作為 Classroom 付費方案核心，而不是只賣社群功能。

## 明確不做或延後

- 不優先做開放式留言社群。
- 不做公開個人動態牆。
- 不做陌生人排行榜作為主入口。
- 不讓未審核 UGC 壓過考試題庫。

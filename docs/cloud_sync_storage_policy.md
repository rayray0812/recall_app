# Grasp Cloud Sync & Storage Policy

最後更新：2026-06-05

本文件定義 Grasp 的雲端同步邊界。核心原則是：雲端只存「換手機不能丟、跨裝置需要、多人互動必須、計費/權限必須可信」的資料；大量過程資料、可重建快取、敏感原文預設留在本地。

## 1. 一定要上傳

| 類型 | 資料 | 原因 |
|---|---|---|
| 帳號 | `profiles` 基本資料、display name、avatar metadata | 登入、社群、好友、教室需要 |
| 私人學習資產 | 使用者自建/匯入的 `study_sets`、`cards` | 換手機不能丟，是產品核心資產 |
| 整理狀態 | `folders`、釘選、收藏、排序偏好中會影響跨裝置的部分 | 跨裝置一致性 |
| FSRS 狀態 | `card_progress`：`stability`、`difficulty`、`state`、`due`、`last_review`、`reps`、`lapses` | 決定下一次複習，比完整 review log 更重要 |
| Sync 正確性 | 刪除紀錄 / tombstone | 避免 A 裝置刪除後被 B 裝置同步回來 |
| 教室 | classroom、membership、teacher/student roles、assignments | 多人協作必須在雲端 |
| 社群 | public deck metadata、下載數、評分、審核狀態 | 公開列表與信任排序需要 |
| 商業權限 | subscription、entitlement、quota、server-side usage counters | 不能只存在本地，否則可被竄改 |

## 2. 不要上傳

| 類型 | 資料 | 原因 |
|---|---|---|
| 內建內容複本 | 內建 7000 單每位使用者各存一份 | 極度浪費空間，應改為 official deck template + user progress |
| AI 原文 | 完整 prompt、完整 response、完整 chain/context | 省空間，也降低隱私與合規風險 |
| 對話紀錄 | AI conversation transcript、口說逐字稿 | 敏感資料，預設 local-only；除非使用者明確選擇備份 |
| OCR 原圖 | 考卷/筆記照片原圖 | 吃 Storage，且可能包含個資、學校、姓名 |
| 音訊快取 | TTS 產物、語音播放 cache | 可重建，不值得同步 |
| 本地模型 | Gemma / LiteRT / Foundation Models 相關模型檔 | 不屬於 Supabase 資料 |
| 裝置狀態 | 搜尋歷史、UI 狀態、動畫偏好、臨時 session state | 留在 Hive/SQLite 即可 |
| Debug | verbose debug logs、raw crash payload | 不該塞主 DB，可用外部 crash reporting |
| 留言 | community comments | 單字卡不需要留言功能；如保留 DB，UI 預設不使用 |

## 3. 可以上傳，但要節制

| 類型 | 建議策略 |
|---|---|
| `review_logs` | 本地保留完整；雲端只同步最近 90 天，或最近固定筆數 |
| 答題 telemetry | `response_latency_ms`、`chosen_distractor_id`、`predicted_retrievability` 只保留 AI 診斷所需的最近資料，例如最近 500-1000 筆 |
| AI usage events | 只存計費與品質分析必要欄位：task、provider、model、tokens、estimated_cost、success、latency、created_at |
| Conversation score | 存總分、弱點標籤、建議分類；不要預設存逐字稿 |
| Public deck cards | 只有使用者主動發布到社群時才上傳完整 cards；私人內建包不要複製 |

## 4. 推薦資料模型方向

### 4.1 私人字卡

使用者自己建立、匯入、拍照產生的牌組可以完整同步：

```text
study_sets
  user_id
  id
  title
  description
  cards jsonb
  folder_id
  created_at
  updated_at
```

短期可維持現有 `cards jsonb`。中長期若要支援大型牌組、逐卡衝突處理、搜尋與審核，應拆成：

```text
study_sets
cards
card_progress
```

### 4.2 內建官方字庫

不要把 7000 單複製到每個使用者的 `study_sets.cards`。建議改成：

```text
official_decks
official_cards
user_deck_subscriptions
card_progress
```

使用者只是訂閱官方 deck；雲端只存他的學習進度與個人筆記覆寫。

### 4.3 FSRS 進度

雲端必存最小 FSRS 狀態：

```text
card_progress
  user_id
  card_id
  set_id
  stability
  difficulty
  state
  due
  last_review
  reps
  lapses
  updated_at
```

`review_logs` 是分析資料，不是排程必需資料；不能讓它無限制成長。

### 4.4 Review Logs Retention

風險估算：

```text
1,000 active users * 100 reviews/day * 30 days = 3,000,000 logs/month
```

加上 indexes 後，Free tier 的 500 MB database 很容易被吃滿。

建議：

1. 本地保留完整 logs。
2. 雲端只同步最近 90 天。
3. 超過 90 天轉成 daily aggregate：

```text
daily_review_stats
  user_id
  date
  set_id
  reviews_count
  again_count
  hard_count
  good_count
  easy_count
  avg_latency_ms
  speaking_avg_score
```

### 4.5 AI Usage

雲端只存計費與營運必要欄位：

```text
ai_usage_events
  user_id
  task_type
  provider
  model
  input_tokens
  output_tokens
  estimated_cost
  success
  latency_ms
  failure_reason
  created_at
```

不預設保存完整 prompt、完整回答、OCR 原圖、口說逐字稿。

## 5. 實作優先順序

1. 將 `review_logs` 雲端同步改為 retention policy：只同步最近 90 天或最近 N 筆。
2. 新增 `daily_review_stats`，將舊 logs 聚合後刪除或停止上傳。
3. 將內建 7000 單規劃為 official deck template，不複製進每個 user 的 `study_sets.cards`。
4. 將 AI transcript、OCR image、TTS cache 明確標為 local-only。
5. 停止擴張 community comments；單字卡社群重心改為可信 deck、評分、下載與審核。
6. 將 entitlement/quota 由本地 placeholder 接到 Supabase 或 app store receipt 驗證。

## 6. 決策句

Grasp 的雲端應該存「狀態與資產」，不要存「過程與快取」。這能讓 Free tier 撐更久，也能讓 Pro tier 的成本成長保持可控。

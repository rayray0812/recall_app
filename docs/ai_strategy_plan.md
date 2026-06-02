# 拾憶 Grasp — AI 功能完整規劃（本地優先）

> 目標：**最大化本地模型使用**，讓 AI 功能免費 + 離線 + 隱私優先，與市面 app（Quizlet / Anki / Knowt）做出區隔。
> 撰寫日期：2026-06-02。模型資訊以 2026-06 現況為準。

---

## 1. 現況盤點

| 層 | 現狀 | 問題 |
|----|------|------|
| Android 本地 | MediaPipe `tasks-genai 0.10.27` + MethodChannel `recall_app/on_device_ai`，跑 Gemma 2B/3B（`.litertlm`/`.task`） | 模型要**使用者手動 import 檔案**（`gemma_local_model_path`）→ UX 很差；模型偏舊（2B） |
| iOS 本地 | **無**（`on_device_ai_service` 直接回「only available on Android」） | iOS 完全沒有本地 AI |
| 雲端 | Gemini Flash（拍照建卡）、Groq Llama 4 Scout（vision） | **需使用者自填 API key**；非零配置 |
| 任務框架 | `local_ai_service`（L1 提示 / L2 口訣 / L3 混淆診斷）、`ai_analytics_service`、`ai_task`、`ai_error` | 框架不錯，但缺「本地/雲端路由」與「裝置能力偵測」 |

現有本地任務：拍照 OCR→建卡、課本 Q&A、L1 reviewHint、L2 mnemonic、L3 confusionDiagnosis。
**核心缺口**：① iOS 無本地 AI ② 模型靠手動 import ③ 無統一路由策略 ④ 雲端要 API key。

---

## 2. 手機端開源模型比較（2026-06）

| 模型 | 尺寸（手機可行） | 中文 | 多模態 | 授權 | 端上 RAM | 在本專案怎麼跑 | 適配度 |
|------|------------------|------|--------|------|----------|----------------|--------|
| **Gemma 3n** (E2B/E4B) | 有效 2B/4B（MatFormer 選擇性啟動） | 良 | **文字+圖+音訊** | Gemma 授權 | E2B <1.5GB、E4B ~3GB | **MediaPipe / LiteRT 官方支援**（現成技術棧） | ★★★★★ Android 首選 |
| **Gemma 4** (E2B 等) | 2B 級 edge 變體 | 良 | 多模態 | Gemma 授權 | ~3GB | LiteRT（2026 新版，待穩定） | ★★★★ 升級路線 |
| **Qwen3** (1.7B/4B) | 1.7B / 4B，雙 thinking 模式 | **最佳（繁中強）** | 部分 | Apache-2.0 | 4B 需 6GB+ | llama.cpp / LiteRT 轉檔 | ★★★★★ 中文任務首選 |
| **Qwen 3.5 small** (0.8B/2B/4B) | 0.8–4B，**原生多模態** | **最佳** | 文字+圖+影片 | Apache-2.0 | 2B ~2GB | llama.cpp / LiteRT（2026 新） | ★★★★ 中文＋多模態升級 |
| **Apple Foundation Models** | ~3B（OS 內建） | 良 | 多模態 | 免費 OS API | OS 管理（**零下載**） | **iOS 26 Swift framework + 新 MethodChannel** | ★★★★★ iOS 首選 |
| Llama 3.2 (1B/3B) | 1B/3B | 弱（中文差） | 3B 有 vision | Llama 授權 | ~2–3GB | llama.cpp | ★★ 不推（中文弱） |
| Phi-4-mini (~3.8B) | 3.8B | 中 | 否 | MIT | ~3GB | llama.cpp | ★★ 英數推理強，中文一般 |
| **DeepSeek**（V3/V4） | 伺服器級 MoE（手機跑不動） | 強 | — | 開放權重 | 不適合端上 | 僅 distill（R1-Distill-Qwen-1.5B，偏數理/英文） | ★ **不建議端上**；可當雲端 fallback |

### 結論（選型）
- **Android 主力：Gemma 3n E2B（預設）/ E4B（高階機）** — 直接沿用 MediaPipe，支援端上多模態（拍照建卡可下放本地）。
- **中文加強選項：Qwen3 4B / Qwen 3.5 2B** — 繁中釋義/例句品質最好，給使用者「中文增強模式」切換。
- **iOS 主力：Apple Foundation Models（iOS 26+）** — 零下載、免費、Swift 原生、結構化輸出，補齊 iOS 缺口。
- **DeepSeek 不進端上**；如需高難度推理，當「雲端 fallback」之一即可。

---

## 3. 平台策略（本地優先三層）

```
┌─ 裝置能力偵測（AiCapabilityService）
│   • iOS 26 + Apple Intelligence 可用 → Apple Foundation Models
│   • Android RAM≥6GB → Gemma 3n E4B / Qwen3 4B
│   • Android RAM 3–6GB → Gemma 3n E2B
│   • RAM<3GB 或無模型 → 雲端 fallback（免 key 的免費層）
│
├─ 本地引擎抽象（LocalLlmEngine 介面）
│   ├ AndroidMediaPipeEngine（現有，擴充 Gemma 3n / 多模態）
│   └ AppleFoundationModelsEngine（新增 MethodChannel）
│
└─ 雲端 fallback（可選、預設關、無需 API key）
    └ 走專案自管的免費代理或 Groq/Gemini 免費層
```

**模型管理（取代手動 import）**：新增 `ModelManagerService` — 依裝置推薦模型、首次使用時 WiFi 下載、校驗 SHA、存路徑、可刪除釋放空間。**不 bundle 進 APK**（避免 audit #12 的體積爆炸）。

---

## 4. 功能分工矩陣（本地 / 雲端）

> 原則：**短輸出、高頻、隱私敏感、可離線 → 一律本地**。只有「長上下文、高準確度、大批量」才考慮雲端。

| 功能 | 預設 | Fallback | 為什麼 |
|------|------|----------|--------|
| 複習提示 L1（卡片 hint） | 🟢 本地 | 無（失敗就隱藏） | 短句、高頻、即時，雲端浪費成本 |
| 記憶口訣 L2（mnemonic） | 🟢 本地 | 雲端（品質不足時） | 短輸出，本地夠用 |
| 混淆診斷 L3（答錯解釋） | 🟢 本地 | 雲端 | 綁 FSRS 個人資料，隱私優先 |
| **例句生成**（新） | 🟢 本地 | 雲端 | 高頻、短，差異化賣點 |
| **智慧干擾選項**（測驗 distractor，新） | 🟢 本地 | 規則式 | 用相似詞生成更像的錯誤選項 |
| **自動 POS / 標籤**（新） | 🟢 本地 | 規則式（現有 regex） | 純文字分類，本地秒回 |
| **學習集摘要 / 難度評估**（新） | 🟢 本地 | 雲端 | 一次性、可離線 |
| 拍照建卡（OCR→卡片） | 🟡 本地（Gemma 3n 多模態 / 或 ML Kit OCR + 本地 LLM） | 雲端（Gemini/Groq） | 低階機或本地失敗才上雲 |
| 課本 Q&A 生成 | 🟡 本地 | 雲端 | 中等長度，本地優先 |
| **AI 家教對話**（Socratic tutor，新） | 🟡 本地（短輪） | 雲端（長上下文/多輪） | 綁弱點卡片，本地保隱私；複雜推理上雲 |
| 口說對話評分（現有 conversation） | 🟡 本地（評分/回饋） | 雲端（自然對話生成） | 評分本地化省成本 |
| 大批量整本書建卡 | 🔴 雲端 | 本地分批 | 長文＋大量，端上太慢 |

🟢 = 純本地　🟡 = 本地優先、雲端備援　🔴 = 雲端為主

---

## 5. 路由決策邏輯（AiRouter）

新增 `AiRouter`，每個 AI 呼叫先過它：

```
route(task):
  if 使用者開「隱私模式 / 離線」 → 強制本地；無本地能力則回 null（UI fail silent）
  cap = AiCapabilityService.detect()
  engine = pickLocalEngine(cap)            // Apple FM / Gemma 3n / Qwen3
  if task.tier == 本地 and engine != null:  return engine.run(task)
  if task.tier == 本地優先:
      try engine.run(task)  → 成功就回
      catch / 低信心 → 若允許雲端且在線 → cloudFallback(task)
  if task.tier == 雲端:  cloudFallback 優先，離線則本地分批
  全程記 AiAnalyticsService（已有）
```

路由輸入：裝置能力、模型是否就緒、任務 tier、線上狀態、使用者隱私設定。

---

## 6. 差異化定位（跟市面 app 區隔）

| 對手 | 他們的 AI | 我們的差異 |
|------|-----------|-----------|
| Quizlet | AI 功能鎖付費（Q-Chat / Magic Notes） | **全部免費** |
| Anki | 幾乎無內建 AI，靠外掛 + 自填 API key | **零配置、開箱即用** |
| Knowt / 其他 | 雲端 AI，筆記上傳 | **本地優先，資料不離開手機** |

**三大賣點**：
1. **免費 AI** — 核心 AI 不需任何 API key、不需訂閱（本地模型）。
2. **離線可用 + 隱私優先** — 「你的筆記永遠不離開手機」；對未成年族群同時是**合規加分**（呼應 audit #4）。
3. **與 FSRS 深度綁定的個人化 AI（Grasp）** — 本地模型知道你哪些卡常錯，給情境化提示/口訣/家教，這是雲端通用 app 做不到的。

一句話定位：**「第一個完全免費、離線、隱私優先的 AI 記憶 app。」**

---

## 7. 落地 Roadmap

> 對齊既有 Grasp 分期（目前已到 Phase B+）。

**Phase C1 — 基礎設施（先做）**
- [ ] `AiCapabilityService`：偵測平台 / RAM / iOS Apple Intelligence 可用性
- [ ] `LocalLlmEngine` 介面 + 把現有 Android MediaPipe 包成 `AndroidMediaPipeEngine`
- [ ] `AiRouter`：tier 路由 + 隱私模式開關
- [ ] `ModelManagerService`：推薦/下載/校驗模型，取代手動 import

**Phase C2 — iOS 補齊**
- [ ] iOS MethodChannel + `AppleFoundationModelsEngine`（iOS 26 Foundation Models）
- [ ] 舊 iOS / 不支援 → 雲端 fallback

**Phase C3 — 模型升級**
- [ ] Android 預設換 Gemma 3n E2B（多模態），高階機 E4B
- [ ] 「中文增強模式」可切 Qwen3 4B / Qwen 3.5 2B
- [ ] 拍照建卡走端上多模態（Gemma 3n），雲端僅 fallback

**Phase C4 — 新 AI 功能（差異化）**
- [ ] 例句生成、智慧干擾選項、自動標籤、學習集摘要
- [ ] 本地 AI 家教（Socratic，綁弱點卡片）

**Phase C5 — 免 key 雲端 fallback**
- [ ] 改造雲端層為「可選、預設關、免使用者 key」（自管免費代理或免費層），保留隱私模式可全關

---

## 8. 風險與對策

| 風險 | 對策 |
|------|------|
| App 體積（audit #12：別 bundle 大模型） | **不 bundle**，首次使用 WiFi 下載；依裝置給不同大小；可刪除 |
| 低階機 RAM 不足 | 能力偵測 → E2B / 雲端 fallback；可關 AI |
| 本地推理慢 / 卡 UI | 背景 isolate + loading 狀態（L1 已有狀態機）；temperature 0 greedy 已用 |
| Qwen/Gemma 端上格式轉換成本 | 先用 MediaPipe 現成 Gemma 3n；Qwen 走 LiteRT 轉檔或 llama.cpp，列為第二步 |
| 模型輸出不穩（小模型） | 已有多策略 parser（`parseLocalModelResponse`）；structured output（Apple FM guided generation）優先 |
| 合規（未成年 + AI 內容） | 本地優先本身就降風險；AI 家教加安全 prompt + 內容過濾 |

---

## 附：與 audit / 既有 TODO 的關聯
- 呼應 CLAUDE.md TODO：「模型升級至 Gemma 3 4B」→ 升級為 **Gemma 3n E2B/E4B**（更適合手機）。
- 呼應 audit #12（app size）→ 本規劃明確採「下載而非 bundle」。
- 呼應 audit #4（未成年合規）→「本地優先 + 資料不離手機」是合規與行銷雙贏。

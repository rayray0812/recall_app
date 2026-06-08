# Grasp AI 權限與 Token 保護規劃

更新日期：2026-06-08

## 目標

Grasp 的 AI 使用模式分成四種：

1. **免費核心功能**：FSRS、一般字卡、離線複習永遠免費。
2. **免費 AI 額度**：登入使用者每日有少量雲端 AI 額度，適合試用。
3. **付費會員 AI**：Plus / Pro AI / Classroom 使用 Grasp server-side provider key，但只經過 Supabase Edge Function。
4. **使用者自備 token / 免費本地模型**：使用者可輸入自己的 Gemini/Groq key，或使用 on-device model。這些 key 只存 `flutter_secure_storage`，不應上傳雲端。

## 絕對規則

- Grasp owner token **不得**放在 Flutter、`.env` committed 檔、Remote Config、Hive、SecureStorage、analytics、crash log、debug print。
- Grasp owner token 只能放在 Supabase Edge Function secrets，例如 `GRASP_GROQ_API_KEY`。
- App 呼叫 owner-funded AI 時只能走 `supabase/functions/ai-proxy`。
- Edge Function 不回傳 provider 原始錯誤 body，避免 provider error message 洩漏 request metadata。
- Edge Function 不記錄 prompt 原文，只記 task、provider、model、token 估算、成功/失敗、時間。
- Flutter 的本地 plan 只能作 debug 測試；release 的付費權限必須由 server entitlement 驗證。

## 已落地的安全底座

- `supabase/migrations/202606080001_ai_proxy_entitlements.sql`
  - `user_ai_entitlements`：server-side 權限來源。
  - `ai_daily_usage`：每日 quota 計數。
  - `ai_usage_events`：用量與成本 ledger。
  - RLS：使用者只能 read own rows，不能自行 grant/insert/update。
  - `consume_ai_daily_quota()`：Edge Function 用 service role 原子消耗 quota。
- `supabase/functions/ai-proxy/index.ts`
  - 驗證 Supabase JWT。
  - 白名單 task：`conversationTurn`、`smartDistractors`、`photoImport`、`speakingScore`。
  - 白名單 Groq model，限制 message 數量、單則長度、總長度與 max tokens。
  - 讀取 `GRASP_GROQ_API_KEY`，不回傳、不 log。
  - server-side entitlement + daily quota。
- `lib/services/ai/ai_proxy_client.dart`
  - Flutter proxy client 沒有 `apiKey` 參數。
  - 只送 task + messages，接收 text/provider/model/token。
- `effectiveAiEntitlementProvider`
  - release 版不信任本地 storage，避免改 Hive 偽造成付費會員。

## 後續接線順序

1. **Smart Distractors**
   - 最適合先接 proxy：輸入短、輸出短、成本可控。
   - 未登入或 quota 用完時 fallback 到本地/既有演算法。
2. **Conversation Turn**
   - 付費會員走 proxy；BYO key 繼續直連 Gemini/Groq。
   - 每輪必須壓 max tokens，避免對話暴漲成本。
3. **Photo Import / Speaking Score**
   - 成本與 payload 較大，需更嚴格限制圖片/文字大小後再切 proxy。
4. **StoreKit / RevenueCat / Admin Entitlement Sync**
   - 付款成功後由 server 寫入 `user_ai_entitlements`。
   - Client 只讀 server entitlement 快取，不得自行改 tier。

## Supabase Secrets

部署前設定：

```bash
supabase secrets set GRASP_GEMINI_API_KEY="..."
```

或使用 Groq：

```bash
supabase secrets set GRASP_GROQ_API_KEY="..."
```

可選：

```bash
supabase secrets set GRASP_AI_PROXY_PROVIDER="groq"
```

不要把任何真實 token 寫進文件、migration、Dart、TypeScript source、測試 fixture。

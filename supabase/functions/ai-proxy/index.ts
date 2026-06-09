import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.49.1';

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'authorization, x-client-info, apikey, content-type',
  'access-control-allow-methods': 'POST, OPTIONS',
};

const jsonHeaders = {
  ...corsHeaders,
  'content-type': 'application/json; charset=utf-8',
};

const supportedTasks = new Set([
  'exampleSentence',
  'conversationTurn',
  'smartDistractors',
  'photoImport',
  'speakingScore',
  'cardLookup',
]);

const defaultGroqModel = 'llama-3.1-8b-instant';
const defaultGeminiModel = 'gemini-2.5-flash-lite';
const allowedGroqModels = new Set([
  defaultGroqModel,
  'llama-3.3-70b-versatile',
  'meta-llama/llama-4-scout-17b-16e-instruct',
]);
const allowedGeminiModels = new Set([
  defaultGeminiModel,
  'gemini-2.5-flash',
]);

type AiEntitlement = 'free' | 'plus' | 'pro_ai' | 'classroom';
type ProviderName = 'gemini' | 'groq';

type ChatMessage = {
  role: 'system' | 'user' | 'assistant';
  content: string;
};

type ProxyBody = {
  taskType?: unknown;
  messages?: unknown;
  model?: unknown;
  temperature?: unknown;
  maxTokens?: unknown;
};

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  if (req.method !== 'POST') {
    return json({ error: 'method_not_allowed', message: 'Use POST.' }, 405);
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const groqKey = Deno.env.get('GRASP_GROQ_API_KEY');
  const geminiKey = Deno.env.get('GRASP_GEMINI_API_KEY');

  if (!supabaseUrl || !serviceRoleKey) {
    return json({ error: 'missing_env', message: 'Server is not configured.' }, 500);
  }

  const provider = chooseProvider({
    requested: Deno.env.get('GRASP_AI_PROXY_PROVIDER'),
    geminiKey,
    groqKey,
  });

  if (!provider) {
    return json({ error: 'provider_unavailable', message: 'Cloud AI is not configured.' }, 503);
  }

  const authHeader = req.headers.get('authorization') ?? '';
  const token = authHeader.replace('Bearer ', '').trim();
  if (!token) {
    return json({ error: 'unauthorized', message: 'Sign in required.' }, 401);
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const userResult = await admin.auth.getUser(token);
  const user = userResult.data.user;
  if (userResult.error || !user) {
    return json({ error: 'unauthorized', message: 'Invalid session.' }, 401);
  }

  const body = await parseJson(req);
  const validation = validateRequest(body, provider);
  if (!validation.ok) {
    return json({ error: 'invalid_request', message: validation.message }, 400);
  }

  const { taskType, messages, model, temperature, maxTokens } = validation;
  const tier = await entitlementFor(admin, user.id);
  const limit = dailyLimit(tier, taskType);
  const usageDate = new Date().toISOString().slice(0, 10);

  const quota = await admin.rpc('consume_ai_daily_quota', {
    p_user_id: user.id,
    p_task_type: taskType,
    p_usage_date: usageDate,
    p_limit: limit,
  });
  if (quota.error) {
    await logUsage(admin, {
      userId: user.id,
      taskType,
      model,
      provider,
      inputTokens: estimateTokens(messages),
      outputTokens: 0,
      success: false,
      failureReason: 'quota_rpc_failed',
    });
    return json({ error: 'server_error', message: 'Cloud AI quota check failed.' }, 500);
  }
  if (quota.data !== true) {
    return json({ error: 'quota_exceeded', message: 'Daily cloud AI quota exhausted.' }, 429);
  }

  const inputTokens = estimateTokens(messages);

  try {
    const providerResponse = provider === 'gemini'
      ? await callGemini({
          apiKey: geminiKey ?? '',
          model,
          messages,
          temperature,
          maxTokens,
        })
      : await callGroq({
          apiKey: groqKey ?? '',
          model,
          messages,
          temperature,
          maxTokens,
        });

    await logUsage(admin, {
      userId: user.id,
      taskType,
      model,
      provider,
      inputTokens: providerResponse.inputTokens ?? inputTokens,
      outputTokens: providerResponse.outputTokens,
      success: true,
    });

    return json({
      text: providerResponse.text,
      provider,
      model,
      inputTokens: providerResponse.inputTokens ?? inputTokens,
      outputTokens: providerResponse.outputTokens,
    });
  } catch (error) {
    await logUsage(admin, {
      userId: user.id,
      taskType,
      model,
      provider,
      inputTokens,
      outputTokens: 0,
      success: false,
      failureReason: sanitizeFailure(error),
    });
    return json({ error: 'provider_error', message: 'Cloud AI request failed.' }, 502);
  }
});

function validateRequest(body: ProxyBody, provider: ProviderName): {
  ok: true;
  taskType: string;
  messages: ChatMessage[];
  model: string;
  temperature: number;
  maxTokens: number;
} | { ok: false; message: string } {
  const taskType = asString(body?.taskType);
  if (!taskType || !supportedTasks.has(taskType)) {
    return { ok: false, message: 'Unsupported AI task.' };
  }

  const messages = parseMessages(body?.messages);
  if (!messages.ok) return messages;

  const totalChars = messages.messages.reduce((sum, message) => {
    return sum + message.content.length;
  }, 0);
  if (messages.messages.length > 12 || totalChars > 12000) {
    return { ok: false, message: 'AI request is too large.' };
  }

  const model = modelFor(provider, asString(body?.model));
  const maxAllowedTokens = maxTokensFor(taskType);

  return {
    ok: true,
    taskType,
    messages: messages.messages,
    model,
    temperature: clampNumber(body?.temperature, 0, 1.2, 0.3),
    maxTokens: clampInt(body?.maxTokens, 1, maxAllowedTokens, maxAllowedTokens),
  };
}

function chooseProvider(input: {
  requested: string | undefined;
  geminiKey: string | undefined;
  groqKey: string | undefined;
}): ProviderName | null {
  if (input.requested === 'groq' && input.groqKey) return 'groq';
  if (input.requested === 'gemini' && input.geminiKey) return 'gemini';
  if (input.geminiKey) return 'gemini';
  if (input.groqKey) return 'groq';
  return null;
}

function modelFor(provider: ProviderName, requested: string | null): string {
  if (provider === 'gemini') {
    return requested && allowedGeminiModels.has(requested)
      ? requested
      : defaultGeminiModel;
  }
  return requested && allowedGroqModels.has(requested) ? requested : defaultGroqModel;
}

function parseMessages(value: unknown): {
  ok: true;
  messages: ChatMessage[];
} | { ok: false; message: string } {
  if (!Array.isArray(value) || value.length === 0) {
    return { ok: false, message: 'Messages are required.' };
  }

  const messages: ChatMessage[] = [];
  for (const item of value) {
    if (!item || typeof item !== 'object') {
      return { ok: false, message: 'Invalid message.' };
    }
    const record = item as Record<string, unknown>;
    const role = asString(record.role);
    const content = asString(record.content);
    if (role !== 'system' && role !== 'user' && role !== 'assistant') {
      return { ok: false, message: 'Invalid message role.' };
    }
    if (!content || content.length > 4000) {
      return { ok: false, message: 'Invalid message content.' };
    }
    messages.push({ role, content });
  }
  return { ok: true, messages };
}

async function callGroq(input: {
  apiKey: string;
  model: string;
  messages: ChatMessage[];
  temperature: number;
  maxTokens: number;
}): Promise<{ text: string; inputTokens?: number; outputTokens: number }> {
  const response = await fetch('https://api.groq.com/openai/v1/chat/completions', {
    method: 'POST',
    headers: {
      authorization: `Bearer ${input.apiKey}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify({
      model: input.model,
      messages: input.messages,
      temperature: input.temperature,
      max_tokens: input.maxTokens,
    }),
  });

  const raw = await response.text();
  if (!response.ok) {
    throw new Error(`groq_${response.status}`);
  }

  const data = JSON.parse(raw) as Record<string, unknown>;
  const choices = data.choices;
  if (!Array.isArray(choices) || choices.length === 0) {
    throw new Error('missing_choices');
  }
  const first = choices[0] as Record<string, unknown>;
  const message = first.message as Record<string, unknown> | undefined;
  const text = asString(message?.content);
  if (!text) throw new Error('missing_content');

  const usage = data.usage as Record<string, unknown> | undefined;
  return {
    text,
    inputTokens: asInt(usage?.prompt_tokens),
    outputTokens: asInt(usage?.completion_tokens) ?? estimateTextTokens(text),
  };
}

async function callGemini(input: {
  apiKey: string;
  model: string;
  messages: ChatMessage[];
  temperature: number;
  maxTokens: number;
}): Promise<{ text: string; inputTokens?: number; outputTokens: number }> {
  const systemText = input.messages
    .filter((message) => message.role === 'system')
    .map((message) => message.content)
    .join('\n\n');
  const contents = input.messages
    .filter((message) => message.role !== 'system')
    .map((message) => ({
      role: message.role === 'assistant' ? 'model' : 'user',
      parts: [{ text: message.content }],
    }));

  const response = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${input.model}:generateContent`,
    {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-goog-api-key': input.apiKey,
      },
      body: JSON.stringify({
        contents,
        ...(systemText.length > 0
          ? { systemInstruction: { parts: [{ text: systemText }] } }
          : {}),
        generationConfig: {
          temperature: input.temperature,
          maxOutputTokens: input.maxTokens,
        },
      }),
    },
  );

  const raw = await response.text();
  if (!response.ok) {
    throw new Error(`gemini_${response.status}`);
  }

  const data = JSON.parse(raw) as Record<string, unknown>;
  const candidates = data.candidates;
  if (!Array.isArray(candidates) || candidates.length === 0) {
    throw new Error('missing_candidates');
  }
  const first = candidates[0] as Record<string, unknown>;
  const content = first.content as Record<string, unknown> | undefined;
  const parts = content?.parts;
  if (!Array.isArray(parts)) throw new Error('missing_parts');

  const text = parts
    .map((part) => (part as Record<string, unknown>).text)
    .filter((value): value is string => typeof value === 'string')
    .join('\n')
    .trim();
  if (!text) throw new Error('missing_content');

  const usage = data.usageMetadata as Record<string, unknown> | undefined;
  return {
    text,
    inputTokens: asInt(usage?.promptTokenCount),
    outputTokens: asInt(usage?.candidatesTokenCount) ?? estimateTextTokens(text),
  };
}

async function entitlementFor(
  admin: ReturnType<typeof createClient>,
  userId: string,
): Promise<AiEntitlement> {
  const response = await admin
    .from('user_ai_entitlements')
    .select('tier, expires_at')
    .eq('user_id', userId)
    .maybeSingle();

  if (response.error || !response.data) return 'free';

  const tier = asString(response.data.tier);
  if (tier !== 'plus' && tier !== 'pro_ai' && tier !== 'classroom') {
    return 'free';
  }

  const expiresAt = asString(response.data.expires_at);
  if (expiresAt && new Date(expiresAt).getTime() <= Date.now()) {
    return 'free';
  }

  return tier;
}

function dailyLimit(tier: AiEntitlement, taskType: string): number {
  if (tier === 'pro_ai' || tier === 'classroom') return -1;
  if (tier === 'plus') {
    if (taskType === 'exampleSentence') return 300;
    if (taskType === 'conversationTurn') return 200;
    if (taskType === 'smartDistractors') return 500;
    if (taskType === 'photoImport') return 100;
    if (taskType === 'speakingScore') return 200;
    if (taskType === 'cardLookup') return 300;
  }
  if (taskType === 'exampleSentence') return 30;
  if (taskType === 'conversationTurn') return 30;
  if (taskType === 'smartDistractors') return 60;
  if (taskType === 'photoImport') return 10;
  if (taskType === 'speakingScore') return 20;
  if (taskType === 'cardLookup') return 20;
  return 0;
}

async function logUsage(
  admin: ReturnType<typeof createClient>,
  event: {
    userId: string;
    taskType: string;
    model: string;
    provider: ProviderName;
    inputTokens: number;
    outputTokens: number;
    success: boolean;
    failureReason?: string;
  },
) {
  await admin.from('ai_usage_events').insert({
    user_id: event.userId,
    task_type: event.taskType,
    provider: event.provider,
    model: event.model,
    input_tokens: event.inputTokens,
    output_tokens: event.outputTokens,
    estimated_cost_usd: 0,
    success: event.success,
    failure_reason: event.failureReason ?? null,
  });
}

async function parseJson(req: Request): Promise<ProxyBody> {
  try {
    return (await req.json()) as ProxyBody;
  } catch (_) {
    return {};
  }
}

function json(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: jsonHeaders });
}

function maxTokensFor(taskType: string): number {
  if (taskType === 'exampleSentence') return 120;
  if (taskType === 'smartDistractors') return 180;
  if (taskType === 'speakingScore') return 320;
  if (taskType === 'photoImport') return 1800;
  if (taskType === 'cardLookup') return 220;
  return 420;
}

function estimateTokens(messages: ChatMessage[]): number {
  return messages.reduce((sum, message) => sum + estimateTextTokens(message.content), 0);
}

function estimateTextTokens(text: string): number {
  return Math.ceil(text.length / 4);
}

function sanitizeFailure(error: unknown): string {
  if (!(error instanceof Error)) return 'unknown';
  return error.message.slice(0, 80).replace(/[^a-zA-Z0-9_:-]/g, '_');
}

function asString(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function asInt(value: unknown): number | undefined {
  if (typeof value !== 'number' || !Number.isFinite(value)) return undefined;
  return Math.max(0, Math.floor(value));
}

function clampInt(value: unknown, min: number, max: number, fallback: number): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) return fallback;
  return Math.min(max, Math.max(min, Math.floor(value)));
}

function clampNumber(value: unknown, min: number, max: number, fallback: number): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) return fallback;
  return Math.min(max, Math.max(min, value));
}

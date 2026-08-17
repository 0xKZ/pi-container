/**
 * Labels the stable `llama-local/current` slot with the model that
 * llama-server actually has loaded.
 *
 * `llama-local` is a single llama-server endpoint: it serves exactly one
 * model at a time (whichever is loaded) and ignores the `model` field in
 * requests. models.json therefore declares one permanent slot,
 * `llama-local/current`, so `--model llama-local/current` works no matter
 * what is loaded. This extension asks the server what it is serving
 * (`GET /v1/models`) and re-registers the slot under that name, so `/model`
 * shows the model you will actually get. Switching models then requires no
 * config edits at all.
 *
 * Fail-soft: if models.json is absent (--openrouter mode hides the local
 * provider), the provider has no apiKey, the server is unreachable, or the
 * response is unexpected, the extension does nothing and the static slot
 * from models.json stays as-is.
 */

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const PROVIDER = "llama-local";

// models.json allows // comments (pi strips them before parsing), so do the
// same here to keep plain JSON.parse working.
function stripLineComments(input: string): string {
  return input.replace(/"(?:\\.|[^"\\])*"|\/\/[^\n]*/g, (m) => (m[0] === '"' ? m : ""));
}

export default async function (pi: ExtensionAPI) {
  const agentDir = process.env.PI_CODING_AGENT_DIR ?? join(homedir(), ".pi", "agent");
  const modelsJsonPath = join(agentDir, "models.json");
  if (!existsSync(modelsJsonPath)) return;

  let providers: Record<string, any>;
  try {
    const raw = readFileSync(modelsJsonPath, "utf8");
    providers = (JSON.parse(stripLineComments(raw)) as any).providers ?? {};
  } catch {
    return;
  }

  const provider = providers[PROVIDER];
  const slot = provider?.models?.[0];
  if (!provider?.baseUrl || !slot?.id || !provider.apiKey) return;

  let loadedModel: string | undefined;
  try {
    const res = await fetch(`${String(provider.baseUrl).replace(/\/+$/, "")}/models`, {
      signal: AbortSignal.timeout(3000),
    });
    if (res.ok) {
      const payload = (await res.json()) as { data?: Array<{ id?: string }> };
      loadedModel = payload.data?.[0]?.id;
    }
  } catch {
    // Server not up or slow -- keep the static label.
  }
  if (!loadedModel || loadedModel === slot.name) return;

  // Re-register the provider with the same single slot; only the human
  // label changes. Everything else (reasoning, thinkingLevelMap, compat,
  // ...) is copied from models.json so the template stays the source of
  // truth for capabilities.
  pi.registerProvider(PROVIDER, {
    baseUrl: provider.baseUrl,
    api: provider.api,
    apiKey: provider.apiKey,
    models: [{ ...slot, name: `${loadedModel} (llama-server)` }],
  });
}

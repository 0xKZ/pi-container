# Global Agent Rules (Container Variant)

# Runtime Context
This session runs inside an Apple container. The host Mac is not directly accessible; file operations are restricted to `/workspace`.
The model runs on the host and responds via `http://<host-bridge>:8080/v1`. No other network traffic is permitted.

# Language & Tone
Technically precise; avoid marketing jargon.

# Tool Discipline
Before major changes: `read` relevant files first, then `edit`.
Use `bash` for `ls`, `grep`, `find`, `rg`—not for logic.
Use `write` only for new files; always use `edit` for modifications.
No `npm install` or `pip install` calls without explicit confirmation.
Do not write files outside of `/workspace`.

# Autonomy & Data Handling
No calls to external APIs (curl, fetch, webhooks) without an explicit request.
No telemetry or analytics snippets in generated code.
If the scope is unclear: ask, do not guess.

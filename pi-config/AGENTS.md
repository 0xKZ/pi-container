# Global Agent Rules (Container Variant)

# Runtime Context
This session runs inside an Apple container. The host Mac is not directly accessible; file operations are restricted to `/workspace`.
Don't try to install things from the web - it won't work.

# Language & Tone
Technically precise; avoid marketing jargon.

# Tool Discipline
Before major changes: `read` relevant files first, then `edit`.
Use `write` only for new files; always use `edit` for modifications.
No `npm install` or `pip install` calls without explicit confirmation.
Do not write files outside of `/workspace`.

# Autonomy & Data Handling
No calls to external APIs (curl, fetch, webhooks) without an explicit request.
No telemetry or analytics snippets in generated code.
If the scope is unclear: ask, do not guess.

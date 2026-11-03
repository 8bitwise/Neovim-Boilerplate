#!/usr/bin/env python3
"""Emits Claude Code stream-json events; never makes network requests."""

import json
import os
import sys
import time

sys.stdin.read()


def emit(event):
    print(json.dumps(event), flush=True)


emit({"type": "system", "subtype": "init"})
if os.getenv("FAKE_CLAUDE_MODE") == "error":
    emit({"type": "result", "subtype": "success", "is_error": True, "result": "fixture not logged in"})
    print("[claude-code:fixture] {}", file=sys.stderr)
    sys.exit(1)
emit({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "thinking_delta", "thinking": "hidden"}}})
for text in ["```lua\n  local streamed", " = true\n", "  return streamed\n```"]:
    emit({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": text}}})
    time.sleep(0.2)
emit({"type": "result", "subtype": "success", "is_error": False,
      "result": "```lua\n  local streamed = true\n  return streamed\n```"})

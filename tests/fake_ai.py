"""Deterministic stdin/stdout AI substitute; never makes network requests."""

import json
import os
import sys
import time

mode = sys.argv[1]
prompt = sys.stdin.read()

if mode in ("slow", "timeout"):
    time.sleep(0.3 if mode == "slow" else 10)
if mode == "suggest":
    context = json.loads(prompt.split("File context (JSON): ", 1)[1])
    print(context["current_line"] + "_done()\n  next_line")
    sys.exit(0)
if mode == "stream":
    print("  local first = true", flush=True)
    time.sleep(0.3)
    print("  return first")
    sys.exit(0)
if mode == "fail":
    print("fixture authentication failed", file=sys.stderr)
    sys.exit(7)
if mode == "empty":
    print(" \n\t")
elif mode == "large":
    print("x" * 1000)
elif mode == "inspect":
    print(json.dumps({"prompt": prompt, "args": sys.argv[2:], "cwd": os.getcwd(),
                      "env": os.getenv("BOILERPLATE_TEST_VALUE")}))
else:
    print("```lua\n  local generated = true\n  return generated\n```")

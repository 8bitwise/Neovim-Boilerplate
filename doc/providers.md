# Choose your AI

Boilerplate generation is independent of the provider. It can call a
noninteractive CLI or a text-generation API and preview the returned code. Model names, credentials,
and service access are supplied by the user. It does not log into browser-only
chatbots; services with a different protocol need a custom adapter or wrapper.

Set **either** `command` or `provider` in `require("boilerplate").setup()`.
Existing `command = { ... }` configurations continue to work unchanged.

## CLI providers

For a command that reads stdin and prints an answer, no adapter is necessary:

```lua
require("boilerplate").setup({
  command = { "ollama", "run", "your-installed-model" },
})
```

Replace the model with one installed in [Ollama](https://docs.ollama.com/cli).
For an authenticated [Claude Code CLI](https://code.claude.com/docs/en/cli-reference),
use the built-in adapter. It runs `claude -p` without tools or MCP servers and
streams the code into the preview as Claude writes it:

```lua
require("boilerplate").setup({
  provider = require("boilerplate.providers").claude(),
})
```

It loads only your user-level Claude settings, so a repository's `.claude/`
settings cannot redirect requests. `claude()` accepts `executable` (default `claude`), `model`, `effort`, and extra
`args` appended to the argv list, e.g. `{ model = "haiku", effort = "low" }` for
faster, simpler output.

### Coding agents

Coding agents can edit files and run commands, so each preset locks that down:

| Preset | Runs | Safety |
| --- | --- | --- |
| `providers.claude()` | `claude -p` | Tools and MCP servers disabled; user settings only |
| `providers.codex()` | `codex exec -` | OS-enforced read-only sandbox, no saved session |
| `providers.opencode()` | `opencode run --pure` | Edit, shell, web fetch, and subagent tools denied |

Each accepts `executable`, `model`, and extra `args` (`claude()` also takes
`effort`). Authenticate the agent once in a terminal first. If OpenCode's model
tries a denied tool, `opencode run` waits until `timeout_ms` and then fails.

Any other agent works with `command` or `providers.cli()` when it has:

1. A noninteractive mode that exits when done (no TTY or approval prompts).
2. The prompt on stdin, or as an argument via `command = function(input) ... end`.
3. The answer on stdout; progress and logs on stderr, or use `parse`.
4. A text-only or read-only mode, so it cannot edit files or run commands.

Every command runs in an empty working directory, so agents see only the
prompt and cannot pick up a project's agent configuration. Terminal colour codes
are removed, and when an agent wraps the code in explanations, the first fenced
code block is used (except in Markdown files).

Use `providers.cli()` if your CLI takes its prompt as an argument or returns
structured output. This is a template: substitute your CLI's executable, flags,
and JSON response field.

```lua
local providers = require("boilerplate.providers")
require("boilerplate").setup({
  provider = providers.cli({
    command = function(input)
      return { "my-ai-cli", "--prompt", input, "--format", "json" }
    end,
    stdin = false,
    parse = function(stdout)
      return vim.json.decode(stdout).answer
    end,
  }),
})
```

`command` may be an argv list or `function(input) -> argv`. No shell is used, so
quotes, newlines, `$()`, and backticks are passed literally. `stdin` defaults to
the complete prompt; set it to `false` to send no stdin or to a function to
encode it differently. `parse(stdout)` must return the answer as a string; omit
it for plain text. Plain-text output streams into the preview line by line. With
`parse`, add `stream(line) -> text` to show structured output live (it receives
each complete stdout line and returns text to append, or nil), or leave it out
to show the preview after exit. Set `stream = false` to disable streaming. A wrapper can handle tools that write their answer to a file
or return a stream of JSON events. CLI authentication and model flags stay with
the CLI; they are not imposed by this plugin.

## HTTP API providers

These adapters use curl 7.76+ and Neovim's built-in JSON support. Configure one
provider and replace `your-model-id` with a text-capable model available through
your account or local server. No model is selected automatically.

```lua
local providers = require("boilerplate.providers")
require("boilerplate").setup({
  provider = providers.openai({ model = "your-model-id" }),
})
```

| Factory | Protocol | Default key variable |
| --- | --- | --- |
| `providers.openai(opts)` | OpenAI Responses (`/responses`) | `OPENAI_API_KEY` |
| `providers.openai_compatible(opts)` | Chat Completions (`/chat/completions`) | `OPENAI_API_KEY` |
| `providers.anthropic(opts)` | Anthropic Messages (`/messages`) | `ANTHROPIC_API_KEY` |
| `providers.gemini(opts)` | Gemini `generateContent` | `GEMINI_API_KEY` |
| `providers.ollama(opts)` | Ollama chat (`/api/chat`) | None |

The adapters follow the official [OpenAI Responses](https://developers.openai.com/api/docs/guides/text),
[Chat Completions](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create),
[Anthropic Messages](https://platform.claude.com/docs/en/api/messages/create),
[Gemini generateContent](https://ai.google.dev/api/generate-content), and
[Ollama chat](https://docs.ollama.com/api/chat) formats. They send non-streaming
text requests and extract answer text. The generator then removes enclosing
Markdown fences and opens an editable code preview. Returned reasoning
or thinking fields are not displayed. Tools and multimodal input are not
executed or handled by the plugin.

OpenAI-compatible hosted service:

```lua
require("boilerplate").setup({
  provider = providers.openai_compatible({
    model = "your-model-id",
    base_url = "https://your-provider.example/v1",
    api_key_env = "MY_PROVIDER_API_KEY",
    params = { temperature = 0.3 },
  }),
})
```

An unauthenticated local OpenAI-compatible server:

```lua
require("boilerplate").setup({
  provider = providers.openai_compatible({
    model = "your-local-model",
    base_url = "http://localhost:1234/v1",
    api_key_env = false,
  }),
})
```

Anthropic, Gemini, or Ollama:

```lua
-- Choose ONE of these providers:
local provider = providers.anthropic({ model = "your-model-id", max_tokens = 4096 })
-- local provider = providers.gemini({ model = "your-model-id" })
-- local provider = providers.ollama({ model = "your-installed-model" })
require("boilerplate").setup({ provider = provider })
```

All HTTP adapters accept:

| Option | Meaning |
| --- | --- |
| `model` | Required model identifier |
| `base_url` | API base including its version path, if applicable |
| `endpoint` | Full URL; overrides `base_url` and the default route |
| `api_key_env` | Key's environment-variable name, or `false` for no automatic auth header |
| `headers` | Additional string-valued HTTP headers |
| `params` | Additional JSON request fields, such as generation options |
| `curl` | Executable path; defaults to `curl` |

The Anthropic adapter additionally accepts `max_tokens` (default 4096) and
`api_version` (default `2026-10-21`). It sends the key in the `x-api-key` header;
authentication and version headers follow the [Anthropic API overview](https://platform.claude.com/docs/en/api/overview).
For a key requiring a workspace, supply `headers = { ["anthropic-workspace-id"] = "your-workspace-id" }`.
Gemini sends its key through the
[x-goog-api-key header](https://ai.google.dev/gemini-api/docs/api-key).

Core fields such as model, input, and non-streaming mode take precedence over
`params`. The Responses adapter sets `store = false`. Other services' retention,
generation limits, and supported parameters depend on the service and model.

Keys are looked up when each request starts: first in `setup({ env = ... })`,
then Neovim's environment. A missing key produces an actionable error without a
network call. HTTP headers and request bodies travel to curl in an escaped
[stdin configuration](https://curl.se/docs/manpage.html#-K), so keys and prompts
are not placed in process arguments or temporary files. Custom CLI argument
builders control their own argument handling.

## Custom providers

For any other protocol, implement the small provider contract. This template
uses a custom executable as an adapter:

```lua
require("boilerplate").setup({
  provider = {
    name = "My AI",                  -- optional label
    executable = "my-ai-adapter",    -- optional health-check hint
    build = function(input, env)
      return {
        command = { "my-ai-adapter", "--json" },
        stdin = vim.json.encode({ prompt = input }),
      }
    end,
    parse = function(stdout)
      local result = vim.json.decode(stdout)
      if result.error then error(result.error) end
      return result.answer
    end,
  },
})
```

`build(input, env)` runs before the process starts. `input` includes the instruction, target lines, bounded surrounding context,
file path, filetype, and indentation settings; `env` contains the configured environment
overrides. Return a nonempty string argv list plus an optional stdin string and
an optional `env` table of extra environment variables for the process.
Omit stdin or set it to `false` to close stdin without input. Never return a
shell command string. These callbacks should prepare/parse data; network work
belongs in the subprocess so Neovim stays responsive.

`parse(stdout)` runs on successful process exit and must return text. If omitted,
stdout is displayed directly. Optional `stream(line)` receives each complete
stdout line while the process runs and returns text to show in a read-only live
preview, or nil; the final preview always comes from `parse`. Errors thrown by
`stream` are ignored. Throw an error to report malformed data or a
provider-level failure. Nonzero exit codes and stderr, timeouts, cancellation,
input limits, and response limits are handled by the plugin for every provider.
The final answer text (after `parse`) is checked against `max_output_bytes`.

The built-in adapters are covered by local HTTP protocol tests with synthetic
responses. Live model availability, credentials, subscription entitlement, and
each service's future API changes cannot be guaranteed by those tests.

# boilerplate.nvim

Generate boilerplate with your chosen AI from Neovim. Describe the code you need,
edit the suggestion in a preview split, then accept it to insert or replace code.
Requires **Neovim 0.9+**. No Lua dependencies; HTTP adapters need **curl 7.76+**.

The plugin has no default AI or model. [Choose your AI](doc/providers.md) for
CLI, OpenAI, OpenAI-compatible services, Anthropic, Gemini, Ollama, or custom
provider setup. Your existing provider configuration continues to work.

## Install

From this checkout, run:

```sh
./install.sh
```

Restart Neovim and run `:checkhealth boilerplate`, then try
`:bp create a helper function`. The starter config uses **Claude Code**:
install and authenticate the `claude` CLI separately, and make
sure it is on your `PATH`. To use another AI, edit
`~/.config/nvim/plugin/boilerplate-local.lua` using the [provider guide](doc/providers.md).
The plugin itself still has no default provider.

The installer links this checkout into Neovim's native `pack/*/start` directory
and creates the small provider config only if it does not already exist. It
preserves your existing `boilerplate-local.lua` and does not edit `init.lua`.
If you already configure Boilerplate in another file, keep just one `setup()`
call by removing the generated config. No plugin manager or downloads are needed.

For another configuration:

```sh
./install.sh ~/.config/nvim-work
# Or use Neovim's usual environment variables:
NVIM_APPNAME=nvim-work ./install.sh
```

`XDG_CONFIG_HOME` is respected too. Each config gets its own settings and shares
the same checkout. Keep the checkout in place; edits and updates take effect on
the next Neovim launch. Rerunning the installer preserves your settings. To move
to another machine, copy the checkout there and run the installer again.

To uninstall, remove the symlink at
`~/.config/nvim/pack/boilerplate/start/boilerplate.nvim` and your
`plugin/boilerplate-local.lua` setup file (adjust paths for other configurations).

### With lazy.nvim

Use this [plugin spec](https://lazy.folke.io/spec) instead of the installer if
your configuration manages plugins with lazy.nvim:

```lua
{
  dir = vim.fn.expand("~/boilerplate.nvim"),
  name = "boilerplate.nvim",
  lazy = false, -- register the lowercase :bp alias at startup
  opts = function()
    return { provider = require("boilerplate.providers").claude() }
  end,
}
```

## Use

Type the instruction alongside the command:

```vim
:bp create a Python dataclass with name and email
:'<,'>bp implement these stubs with error handling
:10,20bp add constructors and getters
```

Without a range, code is inserted **below the cursor line**. An empty buffer is
filled without a leading blank line. A range replaces complete selected lines;
characterwise and blockwise visual selections are also treated as whole lines.
Running `:bp` without text reopens `:bp ` for inline typing and keeps the range.

Neovim requires uppercase custom commands, so typed `:bp` translates to
`:Boilerplate` on Enter. Scripts and `<Cmd>` mappings should use `Boilerplate`.
Use `:bprevious` for the built-in previous-buffer command.

| Action | Key / command |
| --- | --- |
| Edit the suggestion | Normal Neovim editing in the preview |
| Accept | Enter in normal mode, or `:BoilerplateAccept` |
| Discard | `q` in normal mode, or `:BoilerplateReject` |
| Cancel generation / discard preview | `:BoilerplateCancel` |
| Undo accepted code | `u` in the source buffer |

The preview opens as soon as the AI starts writing and fills in live; it becomes
editable once generation finishes. `q` while it streams cancels the request.

The source stays unchanged until acceptance. The edited preview is applied as
one undoable change; save the file yourself as usual. Closing the preview also
discards it. Only one request or preview is active at a time.

If the source text changes after generation starts, acceptance is blocked so
newer edits cannot be overwritten. Saving the file does not count as a change. Discard and regenerate, or copy the preview manually.

The prompt includes your instruction, full file path, filetype, indentation,
selected lines, and up to `context_lines` before and after the target. Unsaved
changes are included. Set `context_lines = 0` to omit surrounding lines. The AI
is asked for code only; enclosing Markdown fences are removed automatically.
Other returned text remains visible for you to review before accepting.

## Suggestions while typing

```vim
:bps on     " start suggesting
:bps off    " stop
:bps        " toggle
```

With suggestions on, pausing in Insert mode at the end of a line for
`suggest_delay_ms` (default 1000) asks your AI to complete the line or the next
few lines. The suggestion appears as grey ghost text; Tab accepts it, and typing
or moving the cursor dismisses it. Tab works normally whenever no suggestion is
shown. Suggestions use the same provider as `:bp`, and **every pause is one AI
request**, so a slow or metered provider costs time and usage. Suggestions start
off in each Neovim session; add `vim.cmd("BoilerplateSuggest on")` after
`setup()` to start them on.

Optional mappings leave the command line ready for your instruction:

```lua
vim.keymap.set("n", "<leader>ab", ":bp ", { desc = "AI boilerplate" })
vim.keymap.set("x", "<leader>ab", ":bp ", { desc = "AI replace selected lines" })
```

## Configuration

```lua
require("boilerplate").setup({
  command = { "your-ai-cli", "--noninteractive" },
  timeout_ms = 120000,
  context_lines = 80,
  max_prompt_bytes = 100000,
  max_output_bytes = 100000,
  suggest_delay_ms = 1000,
  -- env = { MY_AI_MODEL = "my-model" },
})
```

`command` is an argv list, never a shell string. Paths and arguments are passed
literally; use `vim.fn.expand()` for `~`. The command inherits Neovim's environment,
with optional additions from `env`. It runs in an empty directory
(`stdpath("cache")/boilerplate/workdir`), not your project, so a cloned
repository's agent configuration cannot redirect requests; the prompt already
contains the file context. Your CLI handles authentication, model choice,
processing location, and any billing. Use a text-only or read-only mode; the
built-in agent presets in the [provider guide](doc/providers.md) do this for
Claude Code, Codex, and OpenCode.

Choose either `command` or `provider`, not both. API adapters allow a model,
base URL or full endpoint, additional headers, request parameters, and the name
of the environment variable containing the API key. Keys are read per request
and passed through stdin, not command-line arguments or temporary files.
`env` can supply per-process variables and overrides for API key lookup.

Plain-text CLI output is shown line by line as it arrives, and `providers.claude()`
streams Claude Code's output; HTTP adapters show the response when it completes.
The final preview always comes from the complete output after the CLI exits. The
output limit rejects oversized responses after completion, rather than bounding
live process memory. Cancellation stops the launched CLI; independently spawned jobs
may continue.

Lua API:

```lua
local ai = require("boilerplate")
ai.generate("create a constructor")
ai.generate("implement stubs", { line1 = 5, line2 = 12 })
ai.accept()
ai.reject()
ai.cancel()
ai.status() -- "idle", "running", or "preview"
```

Ranges are inclusive and one-based. `generate()` returns true when a process
starts, or false for invalid input/configuration or an existing request/preview.
Supply the instruction explicitly. `accept()` returns true on success and false
when no preview is available, the source has changed, or it is not modifiable.

Run `:checkhealth boilerplate` to check the version, configured executable, and
whether an API key variable is set. It does not call an AI or validate access.
Run `:helptags ~/boilerplate.nvim/doc`, then `:help boilerplate` for local help.

## Development

```sh
make test
make test-http  # loopback-only mock APIs; requires curl and local socket access
make test NVIM=/path/to/nvim
make test-http NVIM=/path/to/nvim
```

Tests use Python 3 as a deterministic fake AI inside headless Neovim. They cover
inline commands, bounded context, editable previews, insertion, replacement,
undo, stale-buffer protection, cancellation, timeouts, and provider failures.
Provider tests exercise real HTTP requests to a local mock server with fake
credentials. No live AI calls are made by either test suite.

local M = {}

function M.valid_command(command)
  if type(command) ~= "table" or not (vim.islist or vim.tbl_islist)(command) or #command == 0 then
    return false
  end
  for _, arg in ipairs(command) do
    if type(arg) ~= "string" or arg:find("\0", 1, true) then return false end
  end
  return command[1] ~= ""
end

local function string_map(map)
  if type(map) ~= "table" then return false end
  for key, value in pairs(map) do
    if type(key) ~= "string" or type(value) ~= "string" then return false end
  end
  return true
end

function M.valid_invocation(invocation)
  return type(invocation) == "table" and M.valid_command(invocation.command)
    and (invocation.stdin == nil or invocation.stdin == false or type(invocation.stdin) == "string")
    and (invocation.env == nil or string_map(invocation.env))
end

function M.validate(provider)
  assert(type(provider) == "table" and type(provider.build) == "function", "Boilerplate: provider needs a build function")
  assert(provider.parse == nil or type(provider.parse) == "function", "Boilerplate: provider.parse must be a function")
  assert(provider.stream == nil or type(provider.stream) == "function", "Boilerplate: provider.stream must be a function")
  assert(provider.executable == nil or type(provider.executable) == "string", "Boilerplate: provider.executable must be a string")
end

-- Adapt stdin-based, argument-based, or JSON-output CLIs without a shell.
function M.cli(opts)
  assert(type(opts) == "table", "Boilerplate: CLI options are required")
  assert(type(opts.command) == "function" or M.valid_command(opts.command), "Boilerplate: CLI command must be an argv list or function")
  assert(opts.stdin == nil or opts.stdin == false or type(opts.stdin) == "function", "Boilerplate: CLI stdin must be false or a function")
  assert(opts.parse == nil or type(opts.parse) == "function", "Boilerplate: CLI parse must be a function")
  assert(opts.stream == nil or opts.stream == false or type(opts.stream) == "function", "Boilerplate: CLI stream must be false or a function")
  assert(opts.env == nil or string_map(opts.env), "Boilerplate: CLI env must map strings to strings")
  opts = vim.deepcopy(opts)
  -- Plain-text output can be shown line by line; structured output needs its own stream reader.
  local stream = opts.stream
  if stream == nil and not opts.parse then
    stream = function(line) return line .. "\n" end
  end
  return {
    name = opts.name or "CLI",
    executable = type(opts.command) == "table" and opts.command[1] or nil,
    parse = opts.parse,
    stream = stream or nil,
    build = function(input)
      local command = type(opts.command) == "function" and opts.command(input) or vim.deepcopy(opts.command)
      local stdin
      if opts.stdin ~= false then
        stdin = opts.stdin and opts.stdin(input) or input
      end
      return { command = command, stdin = stdin, env = vim.deepcopy(opts.env) }
    end,
  }
end

local function json_lines(output)
  local events = {}
  for line in output:gmatch("[^\n]+") do
    local ok, event = pcall(vim.json.decode, line)
    if ok and type(event) == "table" then events[#events + 1] = event end
  end
  return events
end

-- Shared options for the agent presets: executable, model, extra args.
local function agent(name, opts, command, flags)
  opts = opts or {}
  assert(type(opts) == "table", "Boilerplate: " .. name .. " options must be a table")
  for _, key in ipairs({ "executable", "model", "effort" }) do
    assert(opts[key] == nil or (type(opts[key]) == "string" and opts[key] ~= ""), "Boilerplate: " .. name .. " " .. key .. " must be a string")
  end
  table.insert(command, 1, opts.executable or command[1])
  table.remove(command, 2)
  for key, flag in pairs(flags) do
    if opts[key] then vim.list_extend(command, { flag, opts[key] }) end
  end
  vim.list_extend(command, opts.args or {})
  assert(M.valid_command(command), "Boilerplate: " .. name .. " args must be a list of strings")
  return command
end

-- Claude Code CLI in print mode, streaming text as it is written.
function M.claude(opts)
  local command = agent("Claude", opts, {
    "claude", "-p", "--output-format", "stream-json", "--include-partial-messages", "--verbose",
    "--safe-mode", "--tools", "", "--disallowedTools", "mcp__*", "--no-session-persistence",
    -- A user's ~/.claude settings still apply; any other source is ignored.
    "--setting-sources", "user",
  }, { model = "--model", effort = "--effort" })
  return M.cli({
    name = "Claude Code",
    command = command,
    stream = function(line)
      local event = json_lines(line)[1]
      local delta = event and event.type == "stream_event" and type(event.event) == "table"
        and event.event.type == "content_block_delta" and event.event.delta
      if type(delta) == "table" and delta.type == "text_delta" then return delta.text end
    end,
    parse = function(output)
      for _, event in ipairs(json_lines(output)) do
        if event.type == "result" then
          if event.is_error or event.subtype ~= "success" or type(event.result) ~= "string" then
            error("Claude Code failed: " .. tostring(event.result or event.subtype), 0)
          end
          return event.result
        end
      end
      error("Claude Code returned no result", 0)
    end,
  })
end

-- Codex CLI: an OS-enforced read-only sandbox and no saved session.
function M.codex(opts)
  local command = agent("Codex", opts, {
    "codex", "exec", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral", "--color", "never",
  }, { model = "--model" })
  command[#command + 1] = "-" -- Read the prompt from stdin.
  return M.cli({ name = "Codex", command = command })
end

-- OpenCode: every tool that edits, runs commands, or fetches is denied.
function M.opencode(opts)
  local command = agent("OpenCode", opts, { "opencode", "run", "--pure" }, { model = "--model" })
  return M.cli({
    name = "OpenCode",
    command = command,
    env = { OPENCODE_PERMISSION = vim.json.encode({ bash = "deny", edit = "deny", webfetch = "deny", task = "deny" }) },
  })
end

local function quote(value)
  assert(type(value) == "string" and not value:find("\0", 1, true), "Invalid HTTP configuration value")
  return '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"')
    :gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t"):gsub("\v", "\\v") .. '"'
end

local function decode(output)
  local ok, data = pcall(vim.json.decode, output)
  if not ok or type(data) ~= "table" then error("Provider returned invalid JSON", 0) end
  if data.error and data.error ~= vim.NIL then
    local message = type(data.error) == "table" and data.error.message or data.error
    error(type(message) == "string" and message or "Provider returned an API error", 0)
  end
  return data
end

local function text_parts(parts, kind)
  local texts = {}
  for _, part in ipairs(type(parts) == "table" and parts or {}) do
    if type(part) == "table" and not part.thought and (not kind or part.type == kind) and type(part.text) == "string" then
      texts[#texts + 1] = part.text
    elseif type(part) == "table" and part.type == "refusal" and type(part.refusal) == "string" then
      texts[#texts + 1] = part.refusal
    end
  end
  return table.concat(texts, "\n")
end

local function http(opts, spec)
  assert(type(opts) == "table" and type(opts.model) == "string" and opts.model ~= "", "Boilerplate: choose a model for the API provider")
  assert(opts.params == nil or type(opts.params) == "table", "Boilerplate: params must be a table")
  assert(opts.headers == nil or type(opts.headers) == "table", "Boilerplate: headers must be a table")
  opts = vim.deepcopy(opts)
  local base = (opts.base_url or spec.base_url):gsub("/+$", "")
  local endpoint = opts.endpoint or (base .. spec.path(opts.model))
  assert(endpoint:match("^https?://[^%s]+$") and not endpoint:find("\0", 1, true), "Boilerplate: endpoint must be an HTTP(S) URL")
  local key_env = opts.api_key_env
  if key_env == nil then key_env = spec.api_key_env end
  assert(key_env == false or type(key_env) == "string", "Boilerplate: api_key_env must be an environment-variable name or false")
  local executable = opts.curl or "curl"
  assert(type(executable) == "string" and executable ~= "", "Boilerplate: curl must be an executable path")
  return {
    name = spec.name,
    executable = executable,
    api_key_env = key_env,
    build = function(input, env)
      local headers = vim.tbl_extend("force", { ["Content-Type"] = "application/json" }, spec.headers or {}, opts.headers or {})
      if key_env then
        local key = (env or {})[key_env] or vim.env[key_env]
        if not key or key == "" then error("Set " .. key_env .. " before using " .. spec.name, 0) end
        if key:find("[%c]") then error("API key contains invalid control characters", 0) end
        headers[spec.key_header or "Authorization"] = (spec.key_prefix or "Bearer ") .. key
      end
      local body = vim.tbl_extend("force", {}, opts.params or {}, spec.body(input, opts))
      local config = { "url = " .. quote(endpoint), 'request = "POST"', "data-binary = " .. quote(vim.json.encode(body)) }
      for name, value in pairs(headers) do
        assert(type(name) == "string" and name:match("^[%w%-]+$"), "Invalid HTTP header name")
        assert(type(value) == "string" and not value:find("[%c]"), "Invalid HTTP header value")
        config[#config + 1] = "header = " .. quote(name .. ": " .. value)
      end
      -- Keep keys and prompt text out of argv and temporary files. Disable
      -- .curlrc so unrelated output/redirect options cannot alter the request.
      return {
        command = { executable, "--disable", "--silent", "--show-error", "--fail-with-body", "--config", "-" },
        stdin = table.concat(config, "\n") .. "\n",
      }
    end,
    parse = function(output)
      local text = spec.parse(decode(output))
      if type(text) ~= "string" or text:match("^%s*$") then
        error("Provider returned no text (the response may be blocked or require tools)", 0)
      end
      return text
    end,
  }
end

function M.openai(opts)
  return http(opts, {
    name = "OpenAI Responses", base_url = "https://api.openai.com/v1", api_key_env = "OPENAI_API_KEY",
    path = function() return "/responses" end,
    body = function(input, o) return { model = o.model, input = input, stream = false, store = false } end,
    parse = function(data)
      local texts = {}
      for _, item in ipairs(type(data.output) == "table" and data.output or {}) do
        if item.type == "message" then
          local text = text_parts(item.content, "output_text")
          if text ~= "" then texts[#texts + 1] = text end
        end
      end
      return table.concat(texts, "\n")
    end,
  })
end

function M.openai_compatible(opts)
  return http(opts, {
    name = "OpenAI-compatible Chat Completions", base_url = "https://api.openai.com/v1", api_key_env = "OPENAI_API_KEY",
    path = function() return "/chat/completions" end,
    body = function(input, o)
      return { model = o.model, messages = { { role = "user", content = input } }, stream = false }
    end,
    parse = function(data)
      local choice = type(data.choices) == "table" and data.choices[1]
      local message = type(choice) == "table" and choice.message
      if type(message) ~= "table" then return "" end
      if type(message.content) == "string" then return message.content end
      if type(message.refusal) == "string" then return message.refusal end
      return text_parts(message.content, "text")
    end,
  })
end

function M.anthropic(opts)
  opts = vim.deepcopy(opts or {})
  local max_tokens = opts.max_tokens or 4096
  assert(type(max_tokens) == "number" and max_tokens > 0 and max_tokens == math.floor(max_tokens), "Boilerplate: max_tokens must be a positive integer")
  return http(opts, {
    name = "Anthropic Messages", base_url = "https://api.anthropic.com/v1", api_key_env = "ANTHROPIC_API_KEY",
    key_header = "x-api-key", key_prefix = "",
    headers = { ["anthropic-version"] = opts.api_version or "2026-10-21" },
    path = function() return "/messages" end,
    body = function(input, o)
      return { model = o.model, max_tokens = max_tokens, messages = { { role = "user", content = input } }, stream = false }
    end,
    parse = function(data) return text_parts(data.content, "text") end,
  })
end

function M.gemini(opts)
  return http(opts, {
    name = "Gemini generateContent", base_url = "https://generativelanguage.googleapis.com/v1beta", api_key_env = "GEMINI_API_KEY",
    key_header = "x-goog-api-key", key_prefix = "",
    path = function(model)
      local encoded = model:gsub("^models/", ""):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end)
      return "/models/" .. encoded .. ":generateContent"
    end,
    body = function(input) return { contents = { { role = "user", parts = { { text = input } } } } } end,
    parse = function(data)
      if type(data.promptFeedback) == "table" and data.promptFeedback.blockReason then
        error("Provider blocked the prompt: " .. tostring(data.promptFeedback.blockReason), 0)
      end
      local first = type(data.candidates) == "table" and data.candidates[1]
      return text_parts(type(first) == "table" and type(first.content) == "table" and first.content.parts or {})
    end,
  })
end

function M.ollama(opts)
  return http(opts, {
    name = "Ollama", base_url = "http://localhost:11434", api_key_env = false,
    path = function() return "/api/chat" end,
    body = function(input, o)
      return { model = o.model, messages = { { role = "user", content = input } }, stream = false }
    end,
    parse = function(data) return type(data.message) == "table" and data.message.content or "" end,
  })
end

return M

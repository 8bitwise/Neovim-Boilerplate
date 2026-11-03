vim.opt.runtimepath:prepend(vim.fn.getcwd())
local api = vim.api
local ai = require("boilerplate")
local providers = require("boilerplate.providers")
local tests, messages = {}, {}
vim.notify = function(message) messages[#messages + 1] = message end
local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function notified(text)
  for _, message in ipairs(messages) do if message:find(text, 1, true) then return end end
  error("Missing notification: " .. text .. "\n" .. table.concat(messages, "\n"))
end

local port, server_error, exited
local server = vim.fn.jobstart({ "python3", vim.fn.getcwd() .. "/tests/mock_api.py" }, {
  on_stdout = function(_, data)
    for _, line in ipairs(data) do port = tonumber(line) or port end
  end,
  on_stderr = function(_, data) server_error = (server_error or "") .. table.concat(data, "\n") end,
  on_exit = function() exited = true end,
})
assert(vim.wait(5000, function() return port ~= nil or exited end, 10) and port,
  "Could not start loopback test server: " .. (server_error or "timeout"))
local base_url = "http://127.0.0.1:" .. port
local function opts(extra)
  return vim.tbl_extend("force", { model = "test-model", base_url = base_url, api_key_env = "PROMPT_TEST_API_KEY" }, extra or {})
end
local function setup(provider, extra)
  ai.cancel()
  vim.cmd("silent! only!")
  vim.cmd("enew!")
  messages = {}
  ai.setup(vim.tbl_extend("force", {
    provider = provider, env = { PROMPT_TEST_API_KEY = "fake-test-key", NO_PROXY = "127.0.0.1" },
  }, extra or {}))
end
local function done()
  assert(vim.wait(5000, function() return ai.status() ~= "running" end, 10), "Request stuck")
end
local function received()
  done()
  assert(vim.b.boilerplate_instruction, "No response: " .. table.concat(messages, "\n"))
  return vim.json.decode(table.concat(api.nvim_buf_get_lines(0, 0, -1, false), "\n"))
end

test("OpenAI Responses sends the chosen model and extracts message text", function()
  setup(providers.openai(opts({ params = { max_output_tokens = 100 } })))
  assert(ai.generate("hello"))
  local data = received()
  eq("/responses", data.path)
  eq("test-model", data.body.model)
  eq(false, data.body.stream)
  eq(false, data.body.store)
  eq(100, data.body.max_output_tokens)
  eq("Bearer fake-test-key", data.headers.Authorization)
  assert(data.body.input:find("User request: hello", 1, true))
end)

test("OpenAI-compatible services accept custom endpoints and headers", function()
  setup(providers.openai_compatible(opts({ base_url = base_url .. "/custom/v1/", headers = { ["X-Project"] = "test" } })))
  ai.generate("hello")
  local data = received()
  eq("/custom/v1/chat/completions", data.path)
  eq("test-model", data.body.model)
  eq("test", data.headers["X-Project"])
  eq("user", data.body.messages[1].role)
  eq(false, data.body.stream)
end)

test("Anthropic Messages handles max tokens and text content blocks", function()
  setup(providers.anthropic(opts({ max_tokens = 123, api_version = "2026-10-21" })))
  ai.generate("hello")
  local data = received()
  eq("/messages", data.path)
  eq(123, data.body.max_tokens)
  eq("2026-10-21", data.headers["anthropic-version"])
  eq("fake-test-key", data.headers["x-api-key"])
  eq(nil, data.headers.Authorization)
end)

test("Gemini sends contents and extracts only answer parts", function()
  setup(providers.gemini(opts({ model = "models/test-model" })))
  ai.generate("hello")
  local data = received()
  eq("/models/test-model:generateContent", data.path)
  eq("fake-test-key", data.headers["x-goog-api-key"])
  eq("user", data.body.contents[1].role)
  assert(data.body.contents[1].parts[1].text:find("User request: hello", 1, true))
end)

test("Ollama works without API credentials", function()
  setup(providers.ollama({ base_url = base_url, model = "local-model", params = { options = { temperature = 0.2 } } }))
  ai.generate("hello")
  local data = received()
  eq("/api/chat", data.path)
  eq("local-model", data.body.model)
  eq(false, data.body.stream)
  eq(nil, data.headers.Authorization)
  eq(0.2, data.body.options.temperature)
end)

test("local OpenAI-compatible servers can explicitly disable authentication", function()
  setup(providers.openai_compatible(opts({ api_key_env = false })))
  ai.generate("hello")
  eq(nil, received().headers.Authorization)
end)

test("curl config round-trips quotes, backslashes, newlines and Unicode", function()
  local input = 'quotes " and \\ paths\nnext line\t雪 $(echo literal)'
  local provider = providers.openai(opts())
  local invocation = provider.build(input, { PROMPT_TEST_API_KEY = "fake-secret" })
  assert(not table.concat(invocation.command, " "):find("fake-secret", 1, true))
  assert(not table.concat(invocation.command, " "):find(input, 1, true))
  setup(provider)
  ai.generate(input)
  assert(received().body.input:find(input, 1, true))
end)

test("missing API keys fail before a process starts", function()
  local key = "PROMPT_TEST_MISSING_KEY"
  vim.env[key] = nil
  setup(providers.openai(opts({ api_key_env = key })))
  eq(false, ai.generate("hello"))
  eq("idle", ai.status())
  notified("Set " .. key)
end)

test("HTTP authentication errors are not displayed as an AI answer", function()
  setup(providers.openai(opts()))
  ai.generate("CASE:http-error")
  done()
  eq(nil, vim.b.boilerplate_instruction)
  notified("exit 22")
  notified("401")
end)

test("API timeout uses the same cancellation lifecycle as a CLI", function()
  setup(providers.openai(opts()), { timeout_ms = 100 })
  ai.generate("CASE:timeout")
  done()
  notified("timed out")
end)

test("parser handles multiple text blocks, refusals and excludes reasoning", function()
  local p = providers.openai(opts())
  eq("one\ntwo", p.parse(vim.json.encode({ output = {
    { type = "reasoning", content = { { type = "output_text", text = "hidden" } } },
    { type = "message", content = { { type = "output_text", text = "one" }, { type = "output_text", text = "two" } } },
  } })))
  eq("refused", p.parse(vim.json.encode({ output = {
    { type = "message", content = { { type = "refusal", refusal = "refused" } } },
  } })))
  eq("refused", providers.openai_compatible(opts()).parse('{"choices":[{"message":{"content":null,"refusal":"refused"}}]}'))
  eq("one\ntwo", providers.anthropic(opts()).parse('{"content":[{"type":"text","text":"one"},{"type":"text","text":"two"}]}'))
end)

test("invalid JSON, API errors, blocked and non-text responses fail clearly", function()
  local p = providers.openai(opts())
  local ok, err = pcall(p.parse, "not json")
  eq(false, ok)
  assert(err:find("invalid JSON", 1, true))
  ok, err = pcall(p.parse, '{"error":{"message":"fixture quota exceeded"}}')
  eq(false, ok)
  eq("fixture quota exceeded", err)
  eq(false, pcall(p.parse, '{"output":[]}'))
  ok, err = pcall(providers.gemini(opts()).parse, '{"promptFeedback":{"blockReason":"SAFETY"}}')
  eq(false, ok)
  assert(err:find("SAFETY", 1, true))
end)

test("unsafe headers and malformed endpoint configuration are rejected", function()
  eq(false, pcall(providers.openai, opts({ endpoint = "file:///tmp/data" })))
  eq(false, pcall(providers.openai, {}))
  local p = providers.openai(opts({ headers = { ["X-Test"] = "bad\r\nheader" } }))
  eq(false, pcall(p.build, "hello", { PROMPT_TEST_API_KEY = "fake" }))
  p = providers.openai(opts())
  eq(false, pcall(p.build, "hello", { PROMPT_TEST_API_KEY = "bad\nkey" }))
end)

local failures = 0
for _, case in ipairs(tests) do
  local ok, err = xpcall(case.fn, debug.traceback)
  if ok then io.stdout:write("PASS " .. case.name .. "\n")
  else
    failures = failures + 1
    io.stderr:write("FAIL " .. case.name .. "\n" .. err .. "\n")
  end
  ai.cancel()
end
vim.fn.jobstop(server)
io.stdout:write(string.format("\n%d/%d provider tests passed\n", #tests - failures, #tests))
vim.cmd(failures > 0 and "cquit 1" or "qa!")

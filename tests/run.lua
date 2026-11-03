vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd("runtime plugin/boilerplate.lua")
local api = vim.api
local ai = require("boilerplate")
local fixture = vim.fn.getcwd() .. "/tests/fake_ai.py"
local tests, messages = {}, {}
vim.notify = function(message) messages[#messages + 1] = message end

local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function lines(buf) return api.nvim_buf_get_lines(buf, 0, -1, false) end
local function type_keys(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end
local function setup(mode, extra)
  ai.cancel()
  vim.cmd("silent! only!")
  vim.cmd("enew!")
  messages = {}
  local buf = api.nvim_get_current_buf()
  vim.bo[buf].filetype = "lua"
  api.nvim_buf_set_lines(buf, 0, -1, false, { "before", "TODO", "TODO", "after" })
  api.nvim_win_set_cursor(0, { 1, 0 })
  ai.setup(vim.tbl_extend("force", { command = { "python3", fixture, mode or "ok" } }, extra or {}))
  return buf
end
local function done()
  assert(vim.wait(5000, function() return ai.status() ~= "running" end, 10), "Request stuck: " .. table.concat(messages, "\n"))
end
local function response()
  done()
  eq("preview", ai.status())
  assert(vim.b.boilerplate_instruction ~= nil, "No preview: " .. table.concat(messages, "\n"))
  return api.nvim_get_current_buf()
end
local function notified(pattern)
  for _, message in ipairs(messages) do
    if message:find(pattern, 1, true) then return end
  end
  error("Missing notification: " .. pattern .. "\n" .. table.concat(messages, "\n"))
end
local function streaming_preview()
  assert(vim.wait(5000, function() return vim.b.boilerplate_instruction ~= nil end, 10), "No streaming preview")
  eq("running", ai.status())
  return api.nvim_get_current_buf()
end
local function received()
  response()
  return vim.json.decode(table.concat(lines(0), "\n"))
end

test("bp inserts only on acceptance and is undoable in one step", function()
  local buf = setup()
  local original = lines(buf)
  type_keys(":bp create a helper<CR>")
  eq("running", ai.status())
  eq({ "Loading..." }, messages)
  local preview = response()
  eq({ "Loading...", "Done" }, messages)
  eq(original, lines(buf))
  eq({ "  local generated = true", "  return generated" }, lines(preview))
  eq("lua", vim.bo[preview].filetype)
  eq(true, vim.bo[preview].modifiable)
  type_keys("<CR>")
  eq({ "before", "  local generated = true", "  return generated", "TODO", "TODO", "after" }, lines(buf))
  eq(false, api.nvim_buf_is_valid(preview))
  eq("idle", ai.status())
  vim.cmd("undo")
  eq(original, lines(buf))
end)

test("explicit ranges replace complete selected lines", function()
  local buf = setup()
  type_keys(":2,3bp implement these stubs<CR>")
  response()
  vim.cmd("BoilerplateAccept")
  eq({ "before", "  local generated = true", "  return generated", "after" }, lines(buf))
end)

test("empty files are filled without a leading blank line", function()
  local buf = setup()
  api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  ai.generate("create a module")
  response()
  assert(ai.accept())
  eq({ "  local generated = true", "  return generated" }, lines(buf))
end)

test("the editable preview is the code that gets accepted", function()
  local buf = setup()
  ai.generate("create a helper")
  response()
  api.nvim_buf_set_lines(0, 0, -1, false, { "edited()" })
  assert(ai.accept())
  eq({ "before", "edited()", "TODO", "TODO", "after" }, lines(buf))
end)

test("bp without arguments keeps instruction entry on the command line", function()
  setup("inspect")
  type_keys(":bp<CR>write a helper<CR>")
  assert(received().prompt:find("User request: write a helper\n", 1, true))
end)

test("inline prompt entry preserves a visual line range", function()
  local buf = setup()
  api.nvim_buf_set_mark(buf, "<", 2, 0, {})
  api.nvim_buf_set_mark(buf, ">", 3, 0, {})
  type_keys(":'<,'>bp<CR>implement these stubs<CR>")
  response()
  assert(ai.accept())
  eq({ "before", "  local generated = true", "  return generated", "after" }, lines(buf))
end)

test("Escape from inline entry does not call the AI", function()
  setup()
  type_keys(":bp<CR><Esc>")
  eq("idle", ai.status())
end)

test("q discards the preview without changing the source", function()
  local buf = setup()
  local original = lines(buf)
  ai.generate("create a helper")
  local preview = response()
  type_keys("q")
  eq(false, api.nvim_buf_is_valid(preview))
  eq("idle", ai.status())
  eq(original, lines(buf))
end)

test("closing the preview window releases the request", function()
  setup()
  ai.generate("create a helper")
  response()
  vim.cmd("close")
  eq("idle", ai.status())
end)

test("source edits during generation cannot be overwritten", function()
  local buf = setup("slow")
  ai.generate("create a helper")
  api.nvim_buf_set_lines(buf, 0, -1, false, { "new user edit" })
  response()
  eq(false, ai.accept())
  eq({ "new user edit" }, lines(buf))
  eq("preview", ai.status())
  notified("original buffer changed")
end)

test("source edits after generation cannot be overwritten", function()
  local buf = setup()
  ai.generate("create a helper")
  response()
  api.nvim_buf_set_lines(buf, 0, 1, false, { "new user edit" })
  eq(false, ai.accept())
  eq("new user edit", lines(buf)[1])
end)

test("deleted source cannot be accepted", function()
  local buf = setup("slow")
  ai.generate("create a helper")
  api.nvim_buf_delete(buf, { force = true })
  response()
  eq(false, ai.accept())
  notified("original buffer is gone")
end)

test("nonmodifiable source is protected at generation and acceptance", function()
  local buf = setup()
  vim.bo[buf].modifiable = false
  eq(false, ai.generate("create a helper"))
  vim.bo[buf].modifiable = true
  ai.generate("create a helper")
  response()
  vim.bo[buf].modifiable = false
  eq(false, ai.accept())
  notified("not modifiable")
  vim.bo[buf].modifiable = true
end)

test("changing focus during generation still applies to the captured source", function()
  local buf = setup("slow")
  ai.generate("create a helper")
  vim.cmd("enew!")
  local other = api.nvim_get_current_buf()
  response()
  assert(ai.accept())
  eq(6, #lines(buf))
  eq({ "" }, lines(other))
end)

test("another request cannot replace a running request or its preview", function()
  setup("slow")
  assert(ai.generate("first"))
  eq(false, ai.generate("second"))
  response()
  eq(false, ai.generate("third"))
  eq("first", vim.b.boilerplate_instruction)
  notified("Accept or discard")
end)

test("cancellation ignores late results and permits a new request", function()
  setup("slow")
  ai.generate("first")
  vim.cmd("BoilerplateCancel")
  eq("idle", ai.status())
  ai.setup({ command = { "python3", fixture, "ok" } })
  ai.generate("second")
  local preview = response()
  vim.wait(400, function() return false end, 10)
  eq(preview, api.nvim_get_current_buf())
  eq("second", vim.b.boilerplate_instruction)
end)

test("generation includes bounded surrounding context and indentation", function()
  local buf = setup("inspect", { context_lines = 1 })
  vim.bo[buf].shiftwidth = 2
  ai.generate("implement these", { line1 = 2, line2 = 3 })
  local data = received()
  local context = vim.json.decode(data.prompt:match("File context %(JSON%): (.*)"))
  eq({ "before" }, context.before)
  eq({ "TODO", "TODO" }, context.selected)
  eq({ "after" }, context.after)
  eq("lua", context.filetype)
  eq(2, context.indentation.shiftwidth)
  eq("replace selected lines", context.operation)
  assert(data.prompt:find("Return ONLY the code", 1, true))
end)

test("surrounding context can be disabled", function()
  setup("inspect", { context_lines = 0 })
  ai.generate("implement these", { line1 = 2, line2 = 3 })
  local context = vim.json.decode(received().prompt:match("File context %(JSON%): (.*)"))
  eq(0, #context.before)
  eq(0, #context.after)
  eq({ "TODO", "TODO" }, context.selected)
end)

test("the lowercase alias leaves unrelated commands and searches alone", function()
  setup()
  type_keys(":let g:boilerplate_alias_arg = 'bp'<CR>")
  eq("bp", vim.g.boilerplate_alias_arg)
  api.nvim_buf_set_lines(0, 0, -1, false, { "before", "bp", "after" })
  type_keys("/bp<CR>")
  eq(2, api.nvim_win_get_cursor(0)[1])
  eq("idle", ai.status())
end)

test("provider failures show exit code and stderr", function()
  local buf = setup("fail")
  ai.generate("question")
  done()
  eq(buf, api.nvim_get_current_buf())
  notified("exit 7")
  notified("fixture authentication failed")
end)

test("timeout releases the request", function()
  setup("timeout", { timeout_ms = 100 })
  ai.generate("question")
  done()
  notified("timed out")
end)

test("empty response is reported", function()
  setup("empty")
  ai.generate("question")
  done()
  notified("no code")
end)

test("response and prompt size limits are enforced", function()
  setup("large", { max_output_bytes = 50 })
  ai.generate("question")
  done()
  notified("max_output_bytes")
  setup("ok", { max_prompt_bytes = 10 })
  eq(false, ai.generate("question"))
  notified("Prompt too large")
end)

test("argv, prompts, cwd, and environment pass literally", function()
  local literal = "$(echo unsafe); `echo unsafe` | $HOME"
  setup("inspect", { command = { "python3", fixture, "inspect", literal }, env = { BOILERPLATE_TEST_VALUE = "test" } })
  ai.generate(literal)
  local data = received()
  eq({ literal }, data.args)
  eq(vim.fn.stdpath("cache") .. "/boilerplate/workdir", data.cwd)
  eq("test", data.env)
  assert(data.prompt:find(literal, 1, true))
end)

test("configuration, executable, input, and range errors are reported", function()
  setup()
  eq(false, ai.generate(nil))
  eq(false, ai.generate("   "))
  eq(false, ai.generate("question", { line1 = 0, line2 = 5 }))
  notified("Invalid line range")
  ai.setup()
  eq(false, ai.generate("question"))
  notified("Configure your AI")
  ai.setup({ command = { "/nonexistent/prompt-test-ai" } })
  eq(false, ai.generate("question"))
  notified("executable not found")
  for _, opts in ipairs({ { command = "ai --print" }, { command = {} }, { timeout_ms = 0 }, { env = { X = 5 } } }) do
    eq(false, pcall(ai.setup, opts))
  end
end)

test("CRLF fences are stripped and indentation is preserved", function()
  eq({ "  code" }, require("boilerplate.prompt").parse("```lua\r\n  code\r\n\r\n```\r\n"))
end)

test("agent chatter and terminal colours are removed from answers", function()
  local parse = require("boilerplate.prompt").parse
  local chatty = "\27[1mSure! Here it is:\27[0m\n\n```lua\n  code()\n```\n\nLet me know if you need more."
  eq({ "  code()" }, parse(chatty, "lua"))
  eq(vim.split(chatty:gsub("\27%[%d*m", ""), "\n"), parse(chatty, "markdown"))
end)

test("providers can add environment variables for their process", function()
  setup()
  ai.setup({ provider = {
    build = function(input)
      return { command = { "python3", fixture, "inspect" }, stdin = input, env = { BOILERPLATE_TEST_VALUE = "from provider" } }
    end,
  }, env = { BOILERPLATE_TEST_VALUE = "from config" } })
  ai.generate("question")
  eq("from provider", received().env)
  ai.cancel()
  ai.setup({ provider = { build = function() return { command = { "python3" }, env = { X = 1 } } end } })
  eq(false, ai.generate("question"))
end)

test("agent presets run read-only and take the prompt on stdin", function()
  local providers = require("boilerplate.providers")
  local codex = providers.codex({ model = "m", args = { "--x" } }).build("prompt")
  eq({ "codex", "exec", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral", "--color", "never",
    "--model", "m", "--x", "-" }, codex.command)
  eq("prompt", codex.stdin)
  local opencode = providers.opencode({ executable = "/bin/oc" }).build("prompt")
  eq({ "/bin/oc", "run", "--pure" }, opencode.command)
  eq({ bash = "deny", edit = "deny", webfetch = "deny", task = "deny" }, vim.json.decode(opencode.env.OPENCODE_PERMISSION))
  eq(false, pcall(providers.codex, { model = 5 }))
end)

test("argument-based CLI receives the prompt literally and stdin is closed", function()
  setup()
  ai.setup({ provider = require("boilerplate.providers").cli({
    command = function(input) return { "python3", fixture, "inspect", "--prompt", input } end,
    stdin = false,
  }) })
  ai.generate("why $(not-a-command) and `literal`?")
  local data = received()
  eq("", data.prompt)
  eq("--prompt", data.args[1])
  assert(data.args[2]:find("why $(not-a-command) and `literal`?", 1, true))
end)

test("JSON stdin and JSON output CLIs can adapt both sides", function()
  setup()
  ai.setup({ provider = require("boilerplate.providers").cli({
    command = { "python3", fixture, "inspect" },
    stdin = function(input) return vim.json.encode({ question = input }) end,
    parse = function(output)
      return vim.json.decode(vim.json.decode(output).prompt).question
    end,
  }) })
  ai.generate("JSON adapter works")
  response()
  assert(table.concat(lines(0), "\n"):find("User request: JSON adapter works", 1, true))
end)

test("custom providers support arbitrary request and response formats", function()
  setup()
  ai.setup({ provider = {
    build = function(input, env)
      return { command = { "python3", fixture, "inspect", env.EXTRA }, stdin = "CUSTOM:" .. input }
    end,
    parse = function(output)
      local data = vim.json.decode(output)
      assert(data.prompt:match("^CUSTOM:"))
      return data.args[1]
    end,
  }, env = { EXTRA = "custom response" } })
  ai.generate("question")
  response()
  eq({ "custom response" }, lines(0))
end)

test("provider build and parse failures release the request", function()
  local buf = setup()
  ai.setup({ provider = { build = function() error("adapter failure") end } })
  eq(false, ai.generate("question"))
  eq("idle", ai.status())
  notified("adapter failure")
  ai.setup({ provider = { build = function() return { command = "not-an-argv-list" } end } })
  eq(false, ai.generate("question"))
  notified("Provider build must return")
  ai.setup({ provider = require("boilerplate.providers").cli({
    command = { "python3", fixture, "ok" },
    parse = function() return {} end,
  }) })
  ai.generate("question")
  done()
  eq(buf, api.nvim_get_current_buf())
  notified("provider.parse must return a string")
end)

test("parsed output limits and provider configuration are validated", function()
  setup()
  local provider = require("boilerplate.providers").cli({
    command = { "python3", fixture, "ok" }, parse = function() return string.rep("x", 500) end,
  })
  eq(false, pcall(ai.setup, { command = { "python3" }, provider = provider }))
  eq(false, pcall(ai.setup, { provider = {} }))
  ai.setup({ provider = provider, max_output_bytes = 100 })
  ai.generate("question")
  done()
  notified("AI output exceeds max_output_bytes")
end)

test("the output limit applies to the answer, not a verbose event stream", function()
  setup()
  ai.setup({ provider = require("boilerplate.providers").cli({
    command = { "python3", fixture, "large" }, parse = function() return "short" end,
  }), max_output_bytes = 100 })
  ai.generate("question")
  response()
  eq({ "short" }, lines(0))
end)

test("saving the source during generation does not block acceptance", function()
  local buf = setup("slow")
  api.nvim_buf_set_name(buf, vim.fn.tempname())
  ai.generate("create a helper")
  api.nvim_buf_call(buf, function() vim.cmd("silent write") end)
  response()
  assert(ai.accept())
  eq("  return generated", lines(buf)[3])
end)

test("plain-text output streams into a read-only preview before the AI finishes", function()
  local buf = setup("stream")
  ai.generate("create a helper")
  local preview = streaming_preview()
  eq({ "  local first = true" }, lines(preview))
  eq(false, vim.bo[preview].modifiable)
  eq(false, ai.accept())
  eq(preview, response())
  eq({ "  local first = true", "  return first" }, lines(preview))
  eq(true, vim.bo[preview].modifiable)
  assert(ai.accept())
  eq({ "before", "  local first = true", "  return first", "TODO", "TODO", "after" }, lines(buf))
end)

test("q while streaming cancels the request and ignores later output", function()
  local buf = setup("stream")
  ai.generate("create a helper")
  local preview = streaming_preview()
  type_keys("q")
  eq("idle", ai.status())
  eq(false, api.nvim_buf_is_valid(preview))
  vim.wait(500, function() return false end, 10)
  eq(nil, vim.b.boilerplate_instruction)
  eq(4, #lines(buf))
end)

test("Claude Code stream-json is shown live and its final result is accepted", function()
  local buf = setup()
  ai.setup({ provider = require("boilerplate.providers").claude({
    executable = vim.fn.getcwd() .. "/tests/fake_claude.py", model = "haiku", effort = "low",
  }) })
  ai.generate("create a helper")
  local preview = streaming_preview()
  eq({ "  local streamed" }, lines(preview))
  response()
  eq({ "  local streamed = true", "  return streamed" }, lines(preview))
  assert(ai.accept())
  eq("  return streamed", lines(buf)[3])
end)

test("Claude Code ignores project settings in the working directory", function()
  local command = require("boilerplate.providers").claude().build("x").command
  assert(table.concat(command, " "):find("--setting-sources user", 1, true))
end)

test("Claude Code errors are reported instead of previewed", function()
  setup()
  ai.setup({ provider = require("boilerplate.providers").claude({ executable = vim.fn.getcwd() .. "/tests/fake_claude.py" }),
    env = { FAKE_CLAUDE_MODE = "error" } })
  ai.generate("create a helper")
  done()
  eq(nil, vim.b.boilerplate_instruction)
  notified("fixture not logged in")
end)

local suggest = require("boilerplate.suggest")
local suggest_ns = api.nvim_create_namespace("boilerplate_suggest")
local function suggesting(lines_before, cursor, extra)
  local buf = setup("suggest", vim.tbl_extend("force", { suggest_delay_ms = 20 }, extra or {}))
  api.nvim_buf_set_lines(buf, 0, -1, false, lines_before)
  -- Headless tests cannot wait inside Insert mode, so emulate its cursor and mode.
  vim.wo.virtualedit = "onemore"
  api.nvim_win_set_cursor(0, cursor)
  local mode = vim.fn.mode
  vim.fn.mode = function() return "i" end
  assert(suggest.enable())
  api.nvim_exec_autocmds("TextChangedI", {})
  return buf, function()
    vim.fn.mode = mode
    vim.wo.virtualedit = ""
    suggest.disable()
  end
end
local function ghost(buf)
  vim.wait(3000, function() return #api.nvim_buf_get_extmarks(buf, suggest_ns, 0, -1, {}) > 0 end, 10)
  local marks = api.nvim_buf_get_extmarks(buf, suggest_ns, 0, -1, { details = true })
  return marks[1] and marks[1][4]
end

test("suggestions show ghost text after a pause and Tab accepts them", function()
  local buf, restore = suggesting({ "local x = 1", "  call" }, { 2, 6 })
  local mark = ghost(buf)
  assert(mark, "No suggestion shown: " .. table.concat(messages, "\n"))
  eq({ { "_done()", "Comment" } }, mark.virt_text)
  eq({ { { "  next_line", "Comment" } } }, mark.virt_lines)
  eq({ "local x = 1", "  call" }, lines(buf))
  eq("Accept AI suggestion", vim.fn.maparg("<Tab>", "i", false, true).desc)
  suggest.accept()
  eq({ "local x = 1", "  call_done()", "  next_line" }, lines(buf))
  eq({ 3, 11 }, api.nvim_win_get_cursor(0))
  eq({}, api.nvim_buf_get_extmarks(buf, suggest_ns, 0, -1, {}))
  assert(vim.fn.maparg("<Tab>", "i", false, true).desc ~= "Accept AI suggestion")
  restore()
end)

test("typing drops a pending suggestion and stale results are ignored", function()
  local buf, restore = suggesting({ "call" }, { 1, 4 }, { suggest_delay_ms = 1 })
  vim.wait(20, function() return false end)
  api.nvim_buf_set_lines(buf, 0, -1, false, { "other" })
  api.nvim_win_set_cursor(0, { 1, 5 })
  vim.wait(500, function() return false end, 10)
  restore()
  eq({}, api.nvim_buf_get_extmarks(buf, suggest_ns, 0, -1, {}))
end)

test("suggestions only appear at the end of a line and turn off cleanly", function()
  local buf, restore = suggesting({ "call()" }, { 1, 4 })
  vim.wait(300, function() return false end, 10)
  eq({}, api.nvim_buf_get_extmarks(buf, suggest_ns, 0, -1, {}))
  api.nvim_win_set_cursor(0, { 1, 6 })
  api.nvim_exec_autocmds("CursorMovedI", {})
  assert(ghost(buf), "No suggestion at end of line")
  restore()
  eq(false, suggest.enabled())
  eq({}, api.nvim_get_autocmds({ group = "BoilerplateSuggest" }))
end)

test("completions that do not continue the typed line are discarded", function()
  local buf, restore = suggesting({ "call" }, { 1, 4 })
  ai.setup({ command = { "python3", fixture, "ok" }, suggest_delay_ms = 20 })
  api.nvim_exec_autocmds("TextChangedI", {})
  vim.wait(500, function() return false end, 10)
  restore()
  eq({}, api.nvim_buf_get_extmarks(buf, suggest_ns, 0, -1, {}))
end)

test("bps toggles suggestions and leaves bp alone", function()
  setup()
  type_keys(":bps on<CR>")
  eq(true, suggest.enabled())
  type_keys(":bps<CR>")
  eq(false, suggest.enabled())
  notified("Suggestions off")
  type_keys(":bp sort these<CR>")
  eq("running", ai.status())
end)

local failures = 0
for _, case in ipairs(tests) do
  local ok, err = xpcall(case.fn, debug.traceback)
  if ok then
    io.stdout:write("PASS " .. case.name .. "\n")
  else
    failures = failures + 1
    io.stderr:write("FAIL " .. case.name .. "\n" .. err .. "\n")
  end
  ai.cancel()
end
io.stdout:write(string.format("\n%d/%d tests passed\n", #tests - failures, #tests))
vim.cmd(failures > 0 and "cquit 1" or "qa!")

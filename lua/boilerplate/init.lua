local M = {}
local api = vim.api
local prompt = require("boilerplate.prompt")
local process = require("boilerplate.process")
local providers = require("boilerplate.providers")
local defaults = {
  timeout_ms = 120000,
  context_lines = 80,
  max_prompt_bytes = 100000,
  max_output_bytes = 100000,
  suggest_delay_ms = 1000,
}
local config = vim.deepcopy(defaults)
local active

local function notify(message, level)
  vim.notify("Boilerplate: " .. message, level or vim.log.levels.INFO)
end

function M.setup(opts)
  assert(not active, "Boilerplate: cancel the running request before changing configuration")
  opts = opts or {}
  assert(type(opts) == "table", "Boilerplate: setup expects a table")
  local next_config = vim.tbl_extend("force", vim.deepcopy(defaults), opts)
  assert(not (next_config.provider and next_config.command), "Boilerplate: choose provider or command, not both")
  if next_config.provider ~= nil then providers.validate(next_config.provider) end
  if next_config.command ~= nil then
    assert(providers.valid_command(next_config.command), "Boilerplate: command must be a nonempty argv list of strings")
  end
  for _, key in ipairs({ "timeout_ms", "context_lines", "max_prompt_bytes", "max_output_bytes", "suggest_delay_ms" }) do
    local value = next_config[key]
    assert(type(value) == "number" and value < math.huge and value == math.floor(value)
      and value >= (key == "context_lines" and 0 or 1), "Boilerplate: invalid " .. key)
  end
  if next_config.env ~= nil then
    assert(type(next_config.env) == "table", "Boilerplate: env must be a table")
    for key, value in pairs(next_config.env) do
      assert(type(key) == "string" and type(value) == "string", "Boilerplate: env must map strings to strings")
    end
  end
  config = vim.deepcopy(next_config)
end

function M.get_config()
  return vim.deepcopy(config)
end

function M.get_provider()
  if config.provider then return vim.deepcopy(config.provider) end
  if config.command then return providers.cli({ command = config.command }) end
end

function M.status()
  return active and active.phase or "idle"
end

local function discard(request)
  if active ~= request then return end
  active = nil -- Invalidate callbacks before killing a process or wiping its preview.
  if request.job then pcall(request.job.kill, request.job, 9) end
  if request.preview and api.nvim_buf_is_valid(request.preview) then
    pcall(api.nvim_buf_delete, request.preview, { force = true })
  end
end

function M.cancel()
  if active then
    discard(active)
    notify("Request discarded.")
  end
end

M.reject = M.cancel

function M.accept()
  local request = active
  if not request or request.phase ~= "preview" then
    notify("No suggestion to accept.", vim.log.levels.WARN)
    return false
  end
  if not api.nvim_buf_is_loaded(request.buf) then
    notify("The original buffer is gone. Copy the preview manually or discard it.", vim.log.levels.ERROR)
    return false
  end
  if not vim.deep_equal(api.nvim_buf_get_lines(request.buf, 0, -1, false), request.snapshot) then
    notify("The original buffer changed. Discard and regenerate, or copy the preview manually.", vim.log.levels.ERROR)
    return false
  end
  if not vim.bo[request.buf].modifiable then
    notify("The original buffer is not modifiable.", vim.log.levels.ERROR)
    return false
  end
  local lines = api.nvim_buf_get_lines(request.preview, 0, -1, false)
  local ok, err = pcall(api.nvim_buf_set_lines, request.buf, request.first, request.last, true, lines)
  if not ok then
    notify(tostring(err), vim.log.levels.ERROR)
    return false
  end
  discard(request)
  if api.nvim_win_is_valid(request.win) and api.nvim_win_get_buf(request.win) == request.buf then
    api.nvim_set_current_win(request.win)
    api.nvim_win_set_cursor(request.win, { request.first + 1, 0 })
  end
  notify("Boilerplate inserted. Use u to undo.")
  return true
end

local function open_preview(request, instruction)
  local buf = api.nvim_create_buf(false, true)
  request.preview = buf
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undolevels = -1 -- Streamed partial text is not an undo state.
  api.nvim_buf_set_name(buf, "boilerplate://preview/" .. buf)
  vim.bo[buf].filetype = request.filetype
  vim.b[buf].boilerplate_instruction = instruction
  api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      request.preview = nil
      discard(request)
    end,
  })
  vim.keymap.set("n", "<CR>", M.accept, { buffer = buf, desc = "Accept AI boilerplate" })
  vim.keymap.set("n", "q", M.reject, { buffer = buf, desc = "Discard AI boilerplate" })
  vim.cmd("botright vsplit")
  request.preview_win = api.nvim_get_current_win()
  api.nvim_win_set_buf(request.preview_win, buf)
  vim.wo[request.preview_win].wrap = false
end

-- Streaming previews are read-only; the final one is editable and accepted.
local function set_preview(request, lines, final)
  local buf = request.preview
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = final
  if final then
    vim.bo[buf].undolevels = -123456 -- Back to the global value.
    request.phase = "preview"
  end
  if api.nvim_win_is_valid(request.preview_win) then
    vim.wo[request.preview_win].winbar = final and " AI boilerplate | edit freely | <CR>: accept | q: discard"
      or " AI boilerplate | Loading... | q: cancel"
  end
end

-- Without a range, insert below the cursor; explicit ranges replace whole lines.
function M.generate(instruction, opts)
  opts = opts or {}
  if vim.fn.has("nvim-0.9") ~= 1 then
    notify("Neovim 0.9 or newer is required.", vim.log.levels.ERROR)
    return false
  end
  if active then
    notify("Accept or discard the current request first. Use :BoilerplateCancel to cancel.", vim.log.levels.WARN)
    return false
  end
  if type(instruction) ~= "string" or instruction:match("^%s*$") then
    notify("Type your instruction after :BP, for example :BP create a constructor.", vim.log.levels.WARN)
    return false
  end
  local provider = M.get_provider()
  if not provider then
    notify('Configure your AI with a provider or command in require("boilerplate").setup().', vim.log.levels.ERROR)
    return false
  end
  local buf = api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= "" or not vim.bo[buf].modifiable then
    notify("Choose a modifiable file buffer.", vim.log.levels.ERROR)
    return false
  end
  local count = api.nvim_buf_line_count(buf)
  local first = api.nvim_win_get_cursor(0)[1]
  local last = first
  local replace = opts.line1 ~= nil or opts.line2 ~= nil
  if replace then
    local a, b = opts.line1, opts.line2
    if type(a) ~= "number" or type(b) ~= "number" or a ~= math.floor(a) or b ~= math.floor(b)
      or a < 1 or b < a or b > count then
      notify("Invalid line range.", vim.log.levels.ERROR)
      return false
    end
    first, last = a - 1, b
  elseif count == 1 and api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "" then
    first, last = 0, 1
  end
  local request = {
    buf = buf, win = api.nvim_get_current_win(),
    snapshot = api.nvim_buf_get_lines(buf, 0, -1, false),
    first = first, last = last, replace = replace,
    filetype = vim.bo[buf].filetype, phase = "running",
  }
  local input = prompt.build(request, instruction, config.context_lines)
  if #input > config.max_prompt_bytes then
    notify("Prompt too large. Shorten the request or select fewer lines.", vim.log.levels.ERROR)
    return false
  end
  local built, invocation = pcall(provider.build, input, vim.deepcopy(config.env or {}))
  if not built then
    notify("Could not prepare AI request: " .. tostring(invocation), vim.log.levels.ERROR)
    return false
  end
  if not providers.valid_invocation(invocation) then
    notify("Provider build must return { command = argv, stdin = string or nil, env = table or nil }.", vim.log.levels.ERROR)
    return false
  end
  if vim.fn.executable(invocation.command[1]) ~= 1 then
    notify("AI executable not found: " .. invocation.command[1], vim.log.levels.ERROR)
    return false
  end
  active = request
  local pending, streamed = "", ""
  local function on_stdout(chunk)
    vim.schedule(function()
      if active ~= request or request.phase ~= "running" then return end
      pending = pending .. chunk
      local before = streamed
      for line in pending:gmatch("([^\n]*)\n") do
        local ok, text = pcall(provider.stream, line)
        if ok and type(text) == "string" then streamed = streamed .. text end
      end
      pending = pending:match("[^\n]*$")
      local lines = prompt.preview(streamed)
      if streamed == before or #lines == 0 then return end
      local shown, err = pcall(function()
        if not request.preview then open_preview(request, instruction) end
        set_preview(request, lines, false)
      end)
      if not shown then
        discard(request)
        notify("Could not open preview: " .. tostring(err), vim.log.levels.ERROR)
      end
    end)
  end
  local ok, job = pcall(process.start, invocation.command, {
    on_stdout = provider.stream and on_stdout or nil,
    stdin = invocation.stdin or nil,
    text = true,
    cwd = process.workdir(),
    env = vim.tbl_extend("force", config.env or {}, invocation.env or {}),
    timeout = config.timeout_ms,
  }, function(result)
    vim.schedule(function()
      if active ~= request then
        return
      end
      request.job = nil
      if result.code ~= 0 then
        discard(request)
        local reason = result.code == 124 and "AI command timed out." or ("AI command failed (exit " .. result.code .. ").")
        local detail = vim.trim(prompt.plain(result.stderr or ""))
        if result.code ~= 124 and provider.parse and vim.trim(result.stdout or "") ~= "" then
          local parsed, message = pcall(provider.parse, result.stdout)
          if not parsed then detail = vim.trim(tostring(message) .. "\n" .. detail) end
        end
        notify(reason .. (detail ~= "" and ("\n" .. detail:sub(-2000)) or ""), vim.log.levels.ERROR)
        return
      end
      local output = result.stdout or ""
      if provider.parse then
        local decoded, text = pcall(provider.parse, output)
        if not decoded or type(text) ~= "string" then
          discard(request)
          notify("Could not read AI response: " .. (decoded and "provider.parse must return a string" or tostring(text)), vim.log.levels.ERROR)
          return
        end
        output = text
      end
      if #output > config.max_output_bytes then
        discard(request)
        notify("AI output exceeds max_output_bytes.", vim.log.levels.ERROR)
        return
      end
      local parsed, lines = pcall(prompt.parse, output, request.filetype)
      if not parsed then
        discard(request)
        notify(tostring(lines), vim.log.levels.ERROR)
        return
      end
      local shown, err = pcall(function()
        if not request.preview then open_preview(request, instruction) end
        set_preview(request, lines, true)
      end)
      if not shown then
        discard(request)
        notify("Could not open preview: " .. tostring(err), vim.log.levels.ERROR)
      else
        vim.notify("Done", vim.log.levels.INFO)
      end
    end)
  end)
  if not ok then
    discard(request)
    notify("Could not start AI command: " .. tostring(job), vim.log.levels.ERROR)
    return false
  end
  request.job = job
  vim.notify("Loading...", vim.log.levels.INFO)
  return true
end

return M

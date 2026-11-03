local M = {}
local api = vim.api
local prompt = require("boilerplate.prompt")
local process = require("boilerplate.process")
local ns = api.nvim_create_namespace("boilerplate_suggest")
local group = api.nvim_create_augroup("BoilerplateSuggest", { clear = true })
local enabled, timer, job, shown, warned = false, nil, nil, nil, false
local generation = 0

local function clear()
  generation = generation + 1 -- Ignore any result still on its way.
  if timer then timer:stop() end
  if job then pcall(job.kill, job, 9) end
  job = nil
  if shown and api.nvim_buf_is_valid(shown.buf) then
    api.nvim_buf_clear_namespace(shown.buf, ns, 0, -1)
    pcall(vim.keymap.del, "i", "<Tab>", { buffer = shown.buf })
  end
  shown = nil
end

-- At the end of a line in a normal, editable buffer.
local function cursor_spot()
  local buf = api.nvim_get_current_buf()
  if vim.fn.mode() ~= "i" or vim.fn.pumvisible() == 1 or vim.bo[buf].buftype ~= "" or not vim.bo[buf].modifiable then
    return
  end
  local row, col = unpack(api.nvim_win_get_cursor(0))
  local line = api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  if col ~= #line then return end
  return { buf = buf, row = row - 1, col = col, line = line, tick = api.nvim_buf_get_changedtick(buf) }
end

-- The model returns the whole current line; keep only what comes after the cursor.
local function completion(output, line, filetype)
  local ok, lines = pcall(prompt.parse, output, filetype)
  if not ok then return end
  local first = lines[1]
  if first:sub(1, #line) == line then
    lines[1] = first:sub(#line + 1)
  else
    local typed = line:match("^%s*(.-)$")
    local returned = first:match("^%s*(.-)$")
    if returned:sub(1, #typed) ~= typed then return end
    lines[1] = returned:sub(#typed + 1)
  end
  if #lines == 1 and lines[1] == "" then return end
  return lines
end

function M.accept()
  local s = shown
  clear()
  if not s then return end
  api.nvim_buf_set_text(s.buf, s.row, s.col, s.row, s.col, s.lines)
  local last = s.lines[#s.lines]
  api.nvim_win_set_cursor(0, { s.row + #s.lines, (#s.lines == 1 and s.col or 0) + #last })
end

local function show(spot, lines)
  local virt_lines = {}
  for i = 2, #lines do virt_lines[#virt_lines + 1] = { { lines[i], "Comment" } } end
  api.nvim_buf_set_extmark(spot.buf, ns, spot.row, spot.col, {
    virt_text = lines[1] ~= "" and { { lines[1], "Comment" } } or nil,
    virt_text_pos = "overlay",
    virt_lines = #virt_lines > 0 and virt_lines or nil,
  })
  spot.lines = lines
  shown = spot
  vim.keymap.set("i", "<Tab>", M.accept, { buffer = spot.buf, desc = "Accept AI suggestion" })
end

local function warn(message)
  if warned then return end
  warned = true
  vim.notify("Boilerplate suggestions: " .. message, vim.log.levels.WARN)
end

local function request()
  local spot = cursor_spot()
  local boilerplate = require("boilerplate")
  local provider = boilerplate.get_provider()
  if not spot or not provider then return end
  local config = boilerplate.get_config()
  local input = prompt.suggestion(spot.buf, spot.row, config.context_lines)
  if #input > config.max_prompt_bytes then return end
  local built, invocation = pcall(provider.build, input, vim.deepcopy(config.env or {}))
  if not built or not require("boilerplate.providers").valid_invocation(invocation)
    or vim.fn.executable(invocation.command[1]) ~= 1 then
    return warn("could not start the AI command")
  end
  local current = generation
  local ok, started = pcall(process.start, invocation.command, {
    stdin = invocation.stdin or nil, text = true, cwd = process.workdir(),
    env = vim.tbl_extend("force", config.env or {}, invocation.env or {}), timeout = config.timeout_ms,
  }, function(result)
    vim.schedule(function()
      if current ~= generation then return end
      job = nil
      local output = result.stdout or ""
      if result.code ~= 0 then return warn("AI command failed (exit " .. result.code .. ")") end
      if provider.parse then
        local parsed, text = pcall(provider.parse, output)
        if not parsed or type(text) ~= "string" then return warn(tostring(text)) end
        output = text
      end
      local now = cursor_spot()
      if #output > config.max_output_bytes or not now or now.buf ~= spot.buf or now.row ~= spot.row
        or now.col ~= spot.col or now.tick ~= spot.tick then
        return
      end
      local lines = completion(output, spot.line, vim.bo[spot.buf].filetype)
      if lines then show(spot, lines) end
    end)
  end)
  if ok then job = started else warn(tostring(started)) end
end

-- Any typing or cursor movement drops the suggestion and waits for the next pause.
local function restart()
  clear()
  timer = timer or vim.loop.new_timer()
  timer:start(require("boilerplate").get_config().suggest_delay_ms, 0, vim.schedule_wrap(function()
    if enabled then request() end
  end))
end

function M.enable()
  if not require("boilerplate").get_provider() then
    vim.notify('Boilerplate: configure your AI in require("boilerplate").setup() first.', vim.log.levels.ERROR)
    return false
  end
  enabled, warned = true, false
  api.nvim_clear_autocmds({ group = group })
  api.nvim_create_autocmd({ "InsertEnter", "TextChangedI", "CursorMovedI" }, { group = group, callback = restart })
  api.nvim_create_autocmd({ "InsertLeave", "BufLeave" }, { group = group, callback = clear })
  return true
end

function M.disable()
  enabled = false
  api.nvim_clear_autocmds({ group = group })
  clear()
end

function M.enabled()
  return enabled
end

function M.command(arg)
  arg = vim.trim(arg or "")
  if arg == "" then arg = enabled and "off" or "on" end
  if arg == "on" then
    if M.enable() then vim.notify("Suggestions on") end
  elseif arg == "off" then
    M.disable()
    vim.notify("Suggestions off")
  else
    vim.notify("Boilerplate: use :bps on or :bps off", vim.log.levels.WARN)
  end
end

return M

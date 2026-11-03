local M = {}

-- AI commands run in an empty directory so a project's agent configuration
-- (.claude/, opencode.json, ...) cannot change where requests go.
function M.workdir()
  local dir = vim.fn.stdpath("cache") .. "/boilerplate/workdir"
  vim.fn.mkdir(dir, "p")
  return dir
end

-- Keep the same small process contract on Neovim 0.9, before vim.system.
-- opts.on_stdout(chunk) sees raw stdout as it arrives; on_exit still gets all of it.
function M.start(command, opts, on_exit)
  local on_stdout = opts.on_stdout
  if opts.env and next(opts.env) == nil then
    opts = vim.tbl_extend("force", {}, opts)
    opts.env = nil -- Neovim 0.9 rejects an empty env table.
  end
  if vim.system then
    local chunks = {}
    local system_opts = vim.tbl_extend("force", opts, {
      stdout = function(_, data)
        if not data then return end
        chunks[#chunks + 1] = data
        if on_stdout then on_stdout(data) end
      end,
    })
    system_opts.on_stdout = nil
    return vim.system(command, system_opts, function(result)
      result.stdout = table.concat(chunks)
      on_exit(result)
    end)
  end

  local stdout, stderr = "", ""
  local timer, finished, timed_out
  local job = vim.fn.jobstart(command, {
    cwd = opts.cwd,
    env = opts.env,
    stderr_buffered = true,
    on_stdout = function(_, data)
      local chunk = table.concat(data, "\n")
      stdout = stdout .. chunk
      if on_stdout and chunk ~= "" then on_stdout(chunk) end
    end,
    on_stderr = function(_, data)
      stderr = table.concat(data, "\n")
    end,
    on_exit = function(_, code)
      finished = true
      if timer then
        vim.fn.timer_stop(timer)
      end
      on_exit({ code = timed_out and 124 or code, stdout = stdout, stderr = stderr })
    end,
  })
  if job <= 0 then
    error("Could not start executable: " .. command[1])
  end

  local function stop()
    if timer then
      vim.fn.timer_stop(timer)
    end
    if not finished then
      vim.fn.jobstop(job)
    end
  end
  timer = vim.fn.timer_start(opts.timeout, function()
    if not finished then
      timed_out = true
      stop()
    end
  end)
  local sent, err = pcall(function()
    if opts.stdin ~= nil then vim.fn.chansend(job, opts.stdin) end
    vim.fn.chanclose(job, "stdin")
  end)
  if not sent then
    stop()
    error(err)
  end
  return { kill = stop }
end

return M

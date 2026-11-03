if vim.g.loaded_boilerplate then
  return
end
vim.g.loaded_boilerplate = true

-- Neovim reserves lowercase names; translate typed :bp on submission.
vim.api.nvim_create_autocmd("CmdlineLeave", {
  group = vim.api.nvim_create_augroup("BoilerplateCommand", { clear = true }),
  pattern = ":",
  callback = function() require("boilerplate.command").expand() end,
})

vim.api.nvim_create_user_command("Boilerplate", function(opts)
  if opts.args:match("^%s*$") then
    local prefix = opts.range > 0 and string.format("%d,%d", opts.line1, opts.line2) or ""
    vim.api.nvim_feedkeys(":" .. prefix .. "bp ", "ni", false)
    return
  end
  local range = opts.range > 0 and { line1 = opts.line1, line2 = opts.line2 } or nil
  require("boilerplate").generate(opts.args, range)
end, { nargs = "*", range = true, desc = "Generate AI boilerplate below the cursor or replace a line range" })

vim.api.nvim_create_user_command("BoilerplateSuggest", function(opts)
  require("boilerplate.suggest").command(opts.args)
end, { nargs = "?", complete = function() return { "on", "off" } end, desc = "Toggle AI suggestions while typing" })

for name, method in pairs({ Accept = "accept", Reject = "reject", Cancel = "cancel" }) do
  vim.api.nvim_create_user_command("Boilerplate" .. name, function()
    require("boilerplate")[method]()
  end, { desc = name .. " AI boilerplate" })
end

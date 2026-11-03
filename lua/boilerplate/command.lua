local M = {}

function M.expand()
  local line = vim.fn.getcmdline()
  if vim.fn.getcmdtype() ~= ":" or vim.v.event.abort then return end
  local prefix, args = line:match("^(%s*)bps(.*)$")
  if prefix and (args == "" or args:match("^%s")) then
    vim.fn.setcmdline(prefix .. "BoilerplateSuggest" .. args)
  end
end

return M

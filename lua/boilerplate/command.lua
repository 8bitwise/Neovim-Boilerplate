local M = {}

function M.expand()
  local line = vim.fn.getcmdline()
  if vim.fn.getcmdtype() ~= ":" or vim.v.event.abort then return end
  local range, suggest, args = line:match("^(.-)bp(s?)(.*)$")
  if range and (args == "" or args:match("^%s")) then
    local normalized = range:gsub("'[%a<>%[%]]", "0")
    if suggest == "s" and range:match("^%s*$") then
      vim.fn.setcmdline(range .. "BoilerplateSuggest" .. args)
    elseif suggest == "" and normalized:match("^[%s%d.$%%,;+%-]*$") then
      vim.fn.setcmdline(range .. "Boilerplate" .. args)
    end
  end
end

return M

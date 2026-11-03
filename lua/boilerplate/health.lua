local M = {}

function M.check()
  vim.health.start("boilerplate.nvim — AI code generation")
  if vim.fn.has("nvim-0.9") == 1 then
    vim.health.ok("Neovim 0.9+")
  else
    vim.health.error("Neovim 0.9 or newer is required")
    return
  end
  local config = require("boilerplate").get_config()
  local provider = require("boilerplate").get_provider()
  if not provider then
    vim.health.warn("No AI configured. Set provider or command in setup().")
    return
  elseif not provider.executable then
    vim.health.info("Custom provider: the executable is resolved when a request is made.")
  elseif vim.fn.executable(provider.executable) == 1 then
    vim.health.ok("AI executable found: " .. provider.executable)
    vim.health.info("The executable is available; health checks do not call the AI.")
  else
    vim.health.error("AI executable not found: " .. provider.executable)
  end
  vim.health.info("Provider: " .. (provider.name or "custom"))
  if provider.api_key_env then
    local key = (config.env or {})[provider.api_key_env] or vim.env[provider.api_key_env]
    if not key or key == "" then
      vim.health.warn("Missing environment variable: " .. provider.api_key_env)
    else
      vim.health.ok("API key environment variable is set (value hidden)")
    end
  end
  if provider.api_key_env ~= nil then
    vim.health.info("Built-in API providers require curl 7.76+; authentication and model access are not checked.")
  end
end

return M

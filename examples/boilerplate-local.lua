-- Installed by boilerplate.nvim/install.sh. Edit this file to choose your AI.
-- Claude uses your existing CLI login. See doc/providers.md for other providers.
require("boilerplate").setup({
  provider = require("boilerplate.providers").claude(),
})

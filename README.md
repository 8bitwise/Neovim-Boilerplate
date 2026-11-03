# Neovim-Boilerplate
Boilerplate is a simple Neovim plugin that allows users to generate boilerplate code with an in-editor command (:BP) with your agent of choice.

# Installation: 
git clone https://github.com/8bitwise/Neovim-Boilerplate.git ~/boilerplate.nvim
~/boilerplate.nvim/install.sh
# Setup 
To choose an agent:

1. Install and authenticate its CLI.
2. Open ~/.config/nvim/plugin/boilerplate-local.lua.
3. Replace its contents with this, then uncomment one provider:

```
local providers = require("boilerplate.providers")

require("boilerplate").setup({
  -- provider = providers.claude(),
  -- provider = providers.codex(),
  -- provider = providers.opencode(),
})
```
Save and restart Neovim, then run:

```:checkhealth boilerplate```
```:BP create a helper function```

For another CLI or an API provider, follow the provider guide.

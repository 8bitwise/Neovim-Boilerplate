#!/bin/sh
# Link this checkout into a Neovim configuration; keep existing settings.
set -eu

if [ "$#" -gt 1 ]; then
  echo "Usage: $0 [neovim-config-directory]" >&2
  exit 1
fi
if [ "${1-}" = "--help" ] || [ "${1-}" = "-h" ]; then
  echo "Usage: $0 [neovim-config-directory]"
  echo "Defaults to XDG_CONFIG_HOME/NVIM_APPNAME (usually ~/.config/nvim)."
  echo "Installs a symlink and a Claude config if none exists. No downloads."
  exit 0
fi

source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
config_dir=${1:-${XDG_CONFIG_HOME:-$HOME/.config}/${NVIM_APPNAME:-nvim}}
package_dir="$config_dir/pack/boilerplate/start"
destination="$package_dir/boilerplate.nvim"
settings="$config_dir/plugin/boilerplate-local.lua"

if [ -e "$destination" ] || [ -L "$destination" ]; then
  if [ ! -L "$destination" ] || [ "$(readlink "$destination")" != "$source_dir" ]; then
    echo "Already exists: $destination" >&2
    echo "Move it aside before installing this checkout." >&2
    exit 1
  fi
else
  mkdir -p "$package_dir"
  ln -s "$source_dir" "$destination"
fi

if [ -e "$settings" ] || [ -L "$settings" ]; then
  printf 'Kept existing config: %s\n' "$settings"
else
  mkdir -p "$config_dir/plugin"
  cp "$source_dir/examples/boilerplate-local.lua" "$settings"
  printf 'Created Claude config: %s\n' "$settings"
fi

printf 'Installed: %s -> %s\n' "$destination" "$source_dir"
printf '%s\n' 'Restart Neovim, then run :checkhealth boilerplate.'
printf '%s\n' 'Claude must be installed, on PATH, and authenticated separately.'

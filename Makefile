NVIM ?= nvim

.PHONY: test test-http
test:
	$(NVIM) --headless -u NONE -i NONE -n -l tests/run.lua

test-http:
	$(NVIM) --headless -u NONE -i NONE -n -l tests/providers.lua

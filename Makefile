# Run the test suite headlessly. Needs plenary.nvim and fzf-lua installed
# wherever your plugin manager keeps them (see tests/minimal_init.lua).
.PHONY: test
test:
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"

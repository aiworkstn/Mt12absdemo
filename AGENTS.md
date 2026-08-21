# AGENTS.md

## Cursor Cloud specific instructions

### What this repo is
MT12 Racing Lua v10 — an **EdgeTX** Lua script package that runs on RC transmitter
radios (an ABS/traction/brake physics engine for RC racing cars). It is not a
web/server app; there is nothing to "serve". The deliverables are:

- `abscore.lua` — the only source file. Physics-only shared engine (GVAR
  pack/unpack, the `process()` signal pipeline, demo-trial state, battery math).
- `absconf.luac`, `absmenu.luac`, `absmix.luac`, `absui.luac` — **compiled Lua 5.3
  bytecode** (the UI/mixer layers). These are shipped compiled; there is no source
  for them in this repo, so they are not editable and cannot be loaded by stock
  `lua5.3` (EdgeTX compiles bytecode with a different integer/number layout).
- `*.pdf` — installation guide and pit manual for end users.

### Toolchain (already installed by the update script)
- `lua5.3` + `luac5.3` (interpreter/compiler — bytecode here is Lua 5.3)
- `liblua5.3-dev` (headers, needed to build luarocks C modules)
- `luacheck` (installed via `luarocks --lua-version 5.3`)

### Lint / syntax-check / run
- Syntax check: `luac5.3 -p abscore.lua`
- Lint: `luacheck abscore.lua`
- Smoke test / run the engine: `lua5.3 tests/smoke_test.lua`

### Non-obvious gotchas
- **EdgeTX globals are provided by the radio, not by Lua.** `abscore.lua`
  references `model`, `getValue`, `getFieldInfo`, and `getTime`. Every use is
  nil-guarded, so the file loads and runs off-radio. `luacheck` will therefore
  report ~37 "accessing undefined variable" warnings for those names plus a
  couple of "unused value" notes — these are expected and are **not** errors
  (luacheck exits with warnings, `luac5.3 -p` exits clean).
- `tests/smoke_test.lua` is the only way to actually run the code in this
  environment. It `dofile`s the unmodified `abscore.lua` and checks GVAR
  round-trips, battery estimation, the ABS pulse-modulation pipeline (output
  `drive_mul` alternates between full-hold `1024` and the brake-floor value while
  braking), and the no-assist passthrough. It does not depend on any EdgeTX API.
- Do **not** try to `dofile`/`loadfile` the `.luac` files with stock `lua5.3`;
  they will fail to load because EdgeTX's bytecode format differs.
- LICENSE marks this as a DEMO with modification/redistribution prohibited; keep
  changes limited to dev tooling (do not alter the product `.lua`/`.luac` files).

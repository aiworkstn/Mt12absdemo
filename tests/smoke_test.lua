#!/usr/bin/env lua5.3
-- =============================================================================
-- Standalone smoke test for the ABS Core physics engine (abscore.lua).
--
-- This harness loads the UNMODIFIED abscore.lua and exercises its pure,
-- EdgeTX-independent functionality: GVAR pack/unpack round-trips and the
-- signal-processing pipeline (ABS pulse modulation during braking).
--
-- EdgeTX globals (model, getValue, getFieldInfo, getTime) are intentionally
-- NOT provided: abscore.lua guards every use of them, so it loads and runs
-- off-radio. Run with:  lua5.3 tests/smoke_test.lua
-- =============================================================================

local here = arg[0]:match("^(.*)[/\\]") or "."
local core_path = here .. "/../abscore.lua"

local ok, core = pcall(dofile, core_path)
assert(ok, "failed to load abscore.lua: " .. tostring(core))
assert(type(core) == "table", "abscore.lua did not return a table")

local passed, failed = 0, 0
local function check(name, cond, detail)
  if cond then
    passed = passed + 1
    print(string.format("  [PASS] %s", name))
  else
    failed = failed + 1
    print(string.format("  [FAIL] %s  %s", name, detail or ""))
  end
end

print(string.format("Loaded ABS Core v%s (DEMO=%s, max boots=%d)",
  core._ver, tostring(core.DEMO), core.DEMO_MAX_BOOTS))

-- ---------------------------------------------------------------------------
print("\n== GVAR pack/unpack round-trips ==")

do
  local mode, delay, cbc = 2, 60, 25
  local packed = core.packGv0(mode, delay, 0, 0, cbc)
  local m, d, _, _, cm = core.unpackGv0(packed)
  check("GVAR0 ABS mode/delay/cbc_min", m == mode and d == delay and cm == cbc,
    string.format("got mode=%d delay=%d cbc=%d", m, d, cm))
end

do
  local packed = core.packAbsFreqDyn(12, 20)
  local f, dyn = core.unpackAbsFreqDyn(packed)
  check("GVAR1 abs_freq/dyn_target", f == 12 and dyn == 20,
    string.format("got f=%d dyn=%d", f, dyn))
end

do
  local packed = core.packTcsDynMinShow(50, 40, 1)
  local tcs, dmin, show = core.unpackTcsDynMinShow(packed)
  check("GVAR3 tcs/dyn_min/show", tcs == 50 and dmin == 40 and show == 1,
    string.format("got tcs=%d dmin=%d show=%d", tcs, dmin, show))
end

do
  local packed = core.packSstcCbcHz(35, 15)
  local sstc, cbc = core.unpackSstcCbcHz(packed)
  check("GVAR4 sstc/cbc gain", sstc == 35 and cbc == 15,
    string.format("got sstc=%d cbc=%d", sstc, cbc))
end

do
  local packed = core.packTimer(12, 3, core.BATT_TYPE_LIHV)
  local mins, ch, chem = core.unpackTimer(packed)
  check("GVAR5 timer min/ch/chem", mins == 12 and ch == 3 and chem == core.BATT_TYPE_LIHV,
    string.format("got min=%d ch=%d chem=%d", mins, ch, chem))
end

do
  local packed = core.packDsrVib(40, 30)
  local gain, start = core.unpackDsrVib(packed)
  check("GVAR6 dsr gain/start", gain == 40 and start == 30,
    string.format("got gain=%d start=%d", gain, start))
end

do
  local packed = core.encodeLapVolt(1, 355, 4, 3)
  local alarm, thr, cells, hz = core.decodeLapVolt(packed)
  check("GVAR7 volt alarm/thr/cells/cbc_hz",
    alarm == 1 and thr == 355 and cells == 4 and hz == 3,
    string.format("got alarm=%d thr=%d cells=%d hz=%d", alarm, thr, cells, hz))
end

-- ---------------------------------------------------------------------------
print("\n== Battery estimation ==")
do
  check("estimateCells 4S LiPo @ 14.8V", core.estimateCells(14.8, core.BATT_TYPE_LIPO) == 4,
    "got " .. core.estimateCells(14.8, core.BATT_TYPE_LIPO))
  local p = core.cellPercent(4.20, core.BATT_TYPE_LIPO)
  check("cellPercent full LiPo cell == 100%", p == 100, "got " .. tostring(p))
  local pe = core.cellPercent(3.50, core.BATT_TYPE_LIPO)
  check("cellPercent empty LiPo cell == 0%", pe == 0, "got " .. tostring(pe))
end

-- ---------------------------------------------------------------------------
print("\n== ABS pipeline: pulse modulation under full braking ==")
-- Static (non-dynamic) ABS at 10 Hz, 30% brake floor, 20% trigger.
local params = {
  any_drive = true, brake_dir = 0, need_steer = false,
  tcs_ramp = 0, sstc_gain = 0, cbc_gain = 0,
  abs_enabled = true, abs_dynamic = false,
  abs_trig = 20, abs_freq = 10, brk_floor = 30,
  dyn_maxhz = 10, cbc_abs_hz = 0, abs_duty = 50,
  dyn_min_ms = 0, cbc_min_ms = 0, dsr_gain = 0, dsr_start = 0,
}
local state = core.newState()

local raw_thr = -1024            -- full brake (brake_dir=0 => negative)
local t = 0
local full_frames, floored_frames = 0, 0
local seen = {}
print(string.format("  %-6s %-10s %-10s %s", "frame", "t_ticks", "drive_mul", "abs_active"))
for frame = 1, 30 do
  t = t + 3                      -- ~30 ms per mixer frame (10 ms/tick)
  local drive_mul, _, flags = core.process(raw_thr, 0, params, state, t, false)
  seen[drive_mul] = true
  if flags.abs_active and drive_mul < 1024 then
    floored_frames = floored_frames + 1
  elseif flags.abs_active then
    full_frames = full_frames + 1
  end
  if frame <= 12 then
    print(string.format("  %-6d %-10d %-10d %s", frame, t, drive_mul, tostring(flags.abs_active)))
  end
end

local distinct = 0
for _ in pairs(seen) do distinct = distinct + 1 end

check("ABS engaged during braking", full_frames + floored_frames > 0,
  "no abs_active frames")
check("ABS modulates output (both full-hold and floor phases seen)",
  full_frames > 0 and floored_frames > 0,
  string.format("full=%d floored=%d", full_frames, floored_frames))
check("Output pulses between >=2 distinct drive levels", distinct >= 2,
  "distinct=" .. distinct)

-- No-drive passthrough: with all assists off, output must be neutral 1024.
do
  local p2 = { any_drive = false }
  local dm = core.process(-1024, 0, p2, core.newState(), 10, false)
  check("Passthrough when no assist active (drive_mul==1024)", dm == 1024,
    "got " .. dm)
end

-- ---------------------------------------------------------------------------
print("\n== Demo trial state ==")
do
  local st = core.getDemoState()
  check("getDemoState returns table with remaining/max",
    type(st) == "table" and st.max == core.DEMO_MAX_BOOTS and st.remaining ~= nil,
    "got " .. tostring(st))
end

-- ---------------------------------------------------------------------------
print(string.format("\n==== RESULT: %d passed, %d failed ====", passed, failed))
os.exit(failed == 0 and 0 or 1)

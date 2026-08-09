-- =============================================================================
-- ABS Core v10.0.0-demo — Physics-only shared engine (EdgeTX Lua, Option A)
-- Deploy: /SCRIPTS/TOOLS/abscore.lua  (delete old .luac after copy)
-- Loaded by absmix.lua (MIXES) and absconf.lua / absui.lua via loadfile()
-- DEMO flag only — trial counter lives in absmix/absui (keeps mixer RAM down).
--
-- Option A: UI param tables, get/setParamValue, voltage & lap/tmr triggers
-- live in absconf.lua so the mixer VM never carries UI-only bytecode.
--
-- HOT-PATH CONTRACT
--   Priority: mixer control > ABS/drive physics > UI scope > lap/telemetry
--   any_drive  — true if ABS/TCS/SSTC/CBC/DSR can affect signal
--   need_steer — true if SSTC or CBC needs steering
--   for_display— true only from UI scope path
--   Flags      — reuse M._flags via resetFlags(); never allocate per tick
--
-- GVAR map v10 (FM0 only; one format per slot — no legacy dual-decode).
--   GVAR0  ABS: mode + delay + cbc_min     u=m+3*d+63*cm  store u-1024
--   GVAR1  FREQ: abs_freq + dyn_target     (f-5)+29*(dyn-5)  non-neg 0..840
--   GVAR2  BRK:  floor + abs_trig          floor_i+21*trig_i  non-neg
--   GVAR3  TCS:  tcs + dyn_min + show_tmr  tcs_i+21*dmin+441*show  non-neg
--   GVAR4  GAIN: sstc + cbc                si+21*ci  step5  non-neg
--   GVAR5  TMR:  min + ch + chem           (m-1)+45*ch+360*chem
--   GVAR6  DSR:  gain + start              gi+21*si
--   GVAR7  VOLT: thr + alarm + cells + cbc_hz
--          thr 0..14 (3.20–3.90 step 0.05); u=thr+15*a+30*c+210*h store u-1024
--   GVAR8  HW:   dir|steer|lap|hap|tstart|strdir  bit pack
-- Fixed (not stored): min lap 3s, tmr vib ON.
-- Pipeline: TCS → SSTC → CBC → ABS (DYN Hz/Min Dly, CBC Hz/Min Dly independent) → DSR
-- =============================================================================

local ABSCORE_VER = "10.0.0-demo"

-- Same Lua state: share one core instance (mix+UI rarely share a state on EdgeTX,
-- but absconf + absui load chain and re-loads benefit).
do
  local existing = rawget(_G, "ABSCORE")
  if type(existing) == "table" and existing._ver == ABSCORE_VER and existing.process then
    return existing
  end
end

local M = {}
M._ver = ABSCORE_VER
M.DEMO = true
M.DEMO_MAX_BOOTS = 10
M.DEMO_EXPIRED_SENTINEL = 100

-- ---------------------------------------------------------------------------
-- GVAR Index Constants
-- ---------------------------------------------------------------------------
M.GV_ABS_MODE   = 0
M.GV_ABS_FREQ   = 1
M.ABS_DELAY_MS_MIN     = 0
M.ABS_DELAY_MS_MAX     = 100
M.ABS_DELAY_MS_DEFAULT = 50
-- CBC / DYN Min Delay: 0=OFF, else 5..100 ms step 5 (independent floors)
M.CBC_MIN_MS_OFF       = 0
M.CBC_MIN_MS_MIN       = 5
M.CBC_MIN_MS_MAX       = 100
M.CBC_MIN_MS_STEP      = 5
M.CBC_MIN_MS_SEL_MAX   = 20  -- sel 0=OFF, 1..20 → 5..100
M.DYN_MIN_MS_OFF       = 0
M.DYN_MIN_MS_MIN       = 5
M.DYN_MIN_MS_MAX       = 100
M.DYN_MIN_MS_STEP      = 5
M.DYN_MIN_MS_SEL_MAX   = 20
M.CBC_ABS_HZ_MAX       = 7
M.GAIN_STEP            = 5
M.GAIN_IDX_MAX         = 20  -- 0..20 → 0..100% step 5
M.TIMER_MIN_MIN        = 1
M.TIMER_MIN_MAX        = 45
M.TIMER_MIN_DEFAULT    = 5
M.GV_BRK_FLOOR  = 2

-- ---------------------------------------------------------------------------
-- Demo trial — SD file (MT12 FM1 inherits FM0, so GVAR trial was broken)
-- File: /SCRIPTS/TOOLS/absdemo.cnt   values 1..10, or 100=expired
-- Delete that file to reset the trial.
-- ---------------------------------------------------------------------------
local _demo = { boots = 0, remaining = 10, max = 10, expired = false }

-- EdgeTX io: io.read(f,n) / io.write(f,s) / io.close(f) — not f:read()
local function demoFileRead()
  if not io or not io.open or not io.read or not io.close then return nil end
  local paths = { "/SCRIPTS/TOOLS/absdemo.cnt", "SCRIPTS/TOOLS/absdemo.cnt" }
  for i = 1, #paths do
    local f = io.open(paths[i], "r")
    if f then
      local t = io.read(f, 16)
      io.close(f)
      local n = tonumber(t)
      if n then return math.floor(n) end
    end
  end
  return nil
end

local function demoFileWrite(n)
  if not io or not io.open or not io.write or not io.close then return false end
  local paths = { "/SCRIPTS/TOOLS/absdemo.cnt", "SCRIPTS/TOOLS/absdemo.cnt" }
  local s = tostring(n)
  for i = 1, #paths do
    local f = io.open(paths[i], "w")
    if f then
      io.write(f, s)
      io.close(f)
      return true
    end
  end
  return false
end

local function demoFill(raw)
  local expired = (raw >= M.DEMO_EXPIRED_SENTINEL) or (raw > M.DEMO_MAX_BOOTS)
  local boots = raw
  if expired then
    boots = M.DEMO_MAX_BOOTS
  elseif boots < 0 then
    boots = 0
  elseif boots > M.DEMO_MAX_BOOTS then
    boots = M.DEMO_MAX_BOOTS
  end
  -- Remaining cycles after this boot counts: boots 1 → 9 left on footer
  local remaining = 0
  if not expired then
    remaining = M.DEMO_MAX_BOOTS - boots
    if remaining < 0 then remaining = 0 end
    if boots == 0 then remaining = M.DEMO_MAX_BOOTS end
  end
  _demo.boots = boots
  _demo.remaining = remaining
  _demo.max = M.DEMO_MAX_BOOTS
  _demo.expired = expired
  return _demo
end

function M.getDemoState()
  local raw = demoFileRead()
  if raw == nil then raw = 0 end
  return demoFill(raw)
end

-- Call once per power cycle from absmix and/or absui (_G guards double bump).
function M.ensureDemoBoot()
  if rawget(_G, "ABS_DEMO_BOOTED") then
    return M.getDemoState()
  end
  rawset(_G, "ABS_DEMO_BOOTED", true)
  local raw = demoFileRead()
  if raw == nil then raw = 0 end
  if raw < M.DEMO_EXPIRED_SENTINEL then
    if raw > M.DEMO_MAX_BOOTS then
      raw = M.DEMO_EXPIRED_SENTINEL
    else
      raw = raw + 1
      if raw > M.DEMO_MAX_BOOTS then raw = M.DEMO_EXPIRED_SENTINEL end
    end
    demoFileWrite(raw)
  end
  return demoFill(raw)
end

function M.isDemoExpired()
  return M.getDemoState().expired == true
end

-- GVAR0: mode + delay + cbc_min. u = m+3*d+63*cm (max 1322), store u-1024.
-- Extra args ignored (call-site compat with older ensureNewGv0).
function M.packGv0(mode, delay_ms, _show_tmr, _tmr_vib, cbc_min_ms)
  mode = math.min(2, math.max(0, mode or 0))
  local d = math.min(M.ABS_DELAY_MS_MAX, math.max(M.ABS_DELAY_MS_MIN, delay_ms or M.ABS_DELAY_MS_DEFAULT))
  local delay_idx = math.floor(d / 5)
  if delay_idx > 20 then delay_idx = 20 end
  local cbc_sel = 0
  local cm = cbc_min_ms or M.CBC_MIN_MS_OFF
  if cm >= M.CBC_MIN_MS_MIN then
    cbc_sel = math.floor(cm / M.CBC_MIN_MS_STEP + 0.5)
    if cbc_sel < 1 then cbc_sel = 1 end
    if cbc_sel > M.CBC_MIN_MS_SEL_MAX then cbc_sel = M.CBC_MIN_MS_SEL_MAX end
  end
  local u = mode + 3 * delay_idx + 63 * cbc_sel
  return u - 1024
end

-- Returns mode, delay_ms, 0, 0, cbc_min_ms  (middle zeros = old show/vib slots)
function M.unpackGv0(gv0)
  local u = (gv0 or 0) + 1024
  if u < 0 then u = 0 end
  if u > 1322 then u = 1322 end
  local mode = u % 3
  local delay_idx = math.floor(u / 3) % 21
  local cbc_sel = math.floor(u / 63)
  if cbc_sel > M.CBC_MIN_MS_SEL_MAX then cbc_sel = M.CBC_MIN_MS_SEL_MAX end
  local cbc_min_ms = M.CBC_MIN_MS_OFF
  if cbc_sel >= 1 then
    cbc_min_ms = cbc_sel * M.CBC_MIN_MS_STEP
    if cbc_min_ms > M.CBC_MIN_MS_MAX then cbc_min_ms = M.CBC_MIN_MS_MAX end
  end
  return mode, delay_idx * 5, 0, 0, cbc_min_ms
end

-- GVAR4: SSTC + CBC step 5 only (non-neg). max 440. Hz is on VOLT pack.
function M.packSstcCbcHz(sstc_gain, cbc_gain, _cbc_hz)
  local step = M.GAIN_STEP
  local si = math.floor((sstc_gain or 0) / step + 0.5)
  if si < 0 then si = 0 end
  if si > M.GAIN_IDX_MAX then si = M.GAIN_IDX_MAX end
  local ci = math.floor((cbc_gain or 0) / step + 0.5)
  if ci < 0 then ci = 0 end
  if ci > M.GAIN_IDX_MAX then ci = M.GAIN_IDX_MAX end
  return si + 21 * ci
end

function M.unpackSstcCbcHz(raw)
  raw = math.max(0, raw or 0)
  local si = raw % 21
  local ci = math.floor(raw / 21) % 21
  if si > M.GAIN_IDX_MAX then si = M.GAIN_IDX_MAX end
  if ci > M.GAIN_IDX_MAX then ci = M.GAIN_IDX_MAX end
  return si * M.GAIN_STEP, ci * M.GAIN_STEP, 0
end

-- GVAR7: DSR gain + start (max 20+20*21=440). Legacy *441 tmr_vib bit ignored.
function M.packDsrVib(dsr_gain, dsr_start)
  local gain_idx = math.floor((dsr_gain or 0) / 5)
  if gain_idx < 0 then gain_idx = 0 end
  if gain_idx > 20 then gain_idx = 20 end
  local start_idx = math.floor((dsr_start or 0) / 5)
  if start_idx < 0 then start_idx = 0 end
  if start_idx > 20 then start_idx = 20 end
  return gain_idx + start_idx * 21
end

function M.unpackDsrVib(raw)
  raw = math.max(0, raw or 0)
  local gain_idx = raw % 21
  local start_idx = math.floor(raw / 21) % 21
  return gain_idx * 5, start_idx * 5
end

function M.packTimer(minutes, tmr_ch, chem)
  local m = math.min(M.TIMER_MIN_MAX, math.max(M.TIMER_MIN_MIN, minutes or M.TIMER_MIN_DEFAULT))
  local ch = math.min(7, math.max(0, tmr_ch or 0))
  local c = (chem and chem ~= 0) and 1 or 0
  return (m - 1) + ch * 45 + c * 360
end

function M.unpackTimer(raw)
  raw = math.max(0, raw or 0)
  if raw > 719 then raw = M.TIMER_MIN_DEFAULT - 1 end
  local chem = math.floor(raw / 360)
  if chem > 1 then chem = 1 end
  local rem = raw % 360
  local min_idx = rem % 45
  if min_idx > 44 then min_idx = 44 end
  local tmr_ch = math.floor(rem / 45) % 8
  return min_idx + 1, tmr_ch, chem
end

M.GV_TCS_RAMP   = 3
M.GV_SSTC_GAIN  = 4
M.GV_TIMER_CFG  = 5
M.GV_DSR_GAIN   = 6
M.GV_LAP_CONFIG = 7
M.GV_HW_CONFIG  = 8

-- Battery chemistry (user setting; packed in GV_TIMER_CFG)
M.BATT_TYPE_LIPO = 0
M.BATT_TYPE_LIHV = 1
M.LIPO_FULL  = 4.20
M.LIPO_EMPTY = 3.50
M.LIHV_FULL  = 4.35
M.LIHV_EMPTY = 3.50
M.ABSOLUTE_MIN = 3.00

M.VOLT_ALARM_DELAY_S = 5
-- Alm Cell: 3.20–3.90 V step 0.05 (15 levels)
M.VOLT_THR_CV_MIN     = 320
M.VOLT_THR_CV_MAX     = 390
M.VOLT_THR_CV_STEP    = 5
M.VOLT_THR_CV_DEFAULT = 350
M.VOLT_THR_IDX_MAX    = 14

-- Min lap gate is fixed at 3 s (not stored in GVAR — saves pack bits / RAM)
M.MIN_LAP_SEC = 3

-- cells_mode: 0=Auto, 1–6 = fixed S
M.CELLS_MODE_AUTO = 0
M.CELLS_MODE_MAX  = 6

M.TELEM_LOSS_RESET_S = 5

M.BRAKE_HYSTERESIS = 2
M.ACCEL_DEADZONE   = 50
M.DSR_MAX_REDUCTION = 0.60
M.SSTEER_MIN       = 0.10
M.ABS_FREQ_MIN     = 5
M.ABS_FREQ_MAX     = 33
M.TCS_RISE_MIN_S   = 0.06
M.TCS_RISE_MAX_S   = 0.80
M.TCS_DT_MIN       = 0.005
M.TCS_DT_MAX       = 0.05
M.MIXER_DT         = 1.0 / 30

M._pcache       = nil
M._pcache_frame = 0
M._pcache_ttl   = 30

M._flags = {
  tcs = false, sstc = false, cbc = false, abs_active = false, dsr = false,
  eff_floor = nil, abs_floor_pct = nil, output_thr = 0,
}

-- Prebuilt channel names (no per-tick string concat)
local CH_LO   = { "ch1", "ch2", "ch3", "ch4", "ch5", "ch6", "ch7", "ch8" }
local CH_HI   = { "CH1", "CH2", "CH3", "CH4", "CH5", "CH6", "CH7", "CH8" }
local CH_FULL = { "channel1", "channel2", "channel3", "channel4",
                  "channel5", "channel6", "channel7", "channel8" }

M._steer_src_cached = -1
M._steer_field_id   = nil
M._steer_fallback   = nil
M._ail_resolved = false
M._ail_field_id = nil
M._thr_field_id = nil
M._thr_resolved = false

function M.resetFlags()
  local f = M._flags
  f.tcs = false
  f.sstc = false
  f.cbc = false
  f.abs_active = false
  f.dsr = false
  f.eff_floor = nil
  f.abs_floor_pct = nil
  f.output_thr = 0
  return f
end

-- ---------------------------------------------------------------------------
-- GVAR Read/Write (FM0)
-- ---------------------------------------------------------------------------
function M.gvarGet(idx, fm)
  if model and model.getGlobalVariable then
    return model.getGlobalVariable(idx, fm or 0) or 0
  end
  return 0
end

function M.gvarSet(idx, val, fm)
  if model and model.setGlobalVariable then
    model.setGlobalVariable(idx, fm or 0, val)
  end
end

-- DYN Min Dly sel 0=OFF, 1..20 → 5..100 ms step 5
function M.packDynMinMs(ms)
  ms = ms or M.DYN_MIN_MS_OFF
  if ms < M.DYN_MIN_MS_MIN then return 0 end
  local sel = math.floor(ms / M.DYN_MIN_MS_STEP + 0.5)
  if sel < 1 then sel = 1 end
  if sel > M.DYN_MIN_MS_SEL_MAX then sel = M.DYN_MIN_MS_SEL_MAX end
  return sel
end

function M.unpackDynMinMs(raw)
  raw = math.max(0, raw or 0)
  if raw <= 0 then return M.DYN_MIN_MS_OFF end
  if raw > M.DYN_MIN_MS_SEL_MAX then raw = M.DYN_MIN_MS_SEL_MAX end
  return raw * M.DYN_MIN_MS_STEP
end

-- GVAR3: TCS step-5 + DYN Min sel 0..20 + show_tmr (non-neg, max 881)
function M.packTcsDynMinShow(tcs_gain, dyn_min_ms, show_tmr)
  local tcs_idx = math.floor((tcs_gain or 0) / 5 + 0.5)
  if tcs_idx < 0 then tcs_idx = 0 end
  if tcs_idx > 20 then tcs_idx = 20 end
  local dsel = M.packDynMinMs(dyn_min_ms)
  local s = (show_tmr and show_tmr ~= 0) and 1 or 0
  return tcs_idx + 21 * dsel + 441 * s
end

function M.unpackTcsDynMinShow(raw)
  raw = math.max(0, raw or 0)
  if raw > 881 then raw = 881 end
  local tcs_idx = raw % 21
  local dsel = math.floor(raw / 21) % 21
  local s = math.floor(raw / 441) % 2
  return tcs_idx * 5, M.unpackDynMinMs(dsel), s
end

function M.getDynMinMs()
  local _, dmin = M.unpackTcsDynMinShow(M.gvarGet(M.GV_TCS_RAMP))
  return dmin
end

function M.setDynMinMs(ms)
  local tcs, _, show = M.unpackTcsDynMinShow(M.gvarGet(M.GV_TCS_RAMP))
  M.gvarSet(M.GV_TCS_RAMP, M.packTcsDynMinShow(tcs, ms, show))
end

-- ---------------------------------------------------------------------------
-- GVAR7 VOLT+CBC_HZ (u-1024)
-- thr_i 0..14 (3.20–3.90 step 0.05) + 15*alarm + 30*cells + 210*cbc_hz
-- max u = 14+15+180+1470 = 1679 ≤ 2048
-- ---------------------------------------------------------------------------
function M.decodeLapVolt(raw)
  local u = (raw or 0) + 1024
  if u < 0 then u = 0 end
  if u > 1679 then u = 1679 end
  local thr_idx = u % 15
  if thr_idx > M.VOLT_THR_IDX_MAX then thr_idx = M.VOLT_THR_IDX_MAX end
  local alarm = math.floor(u / 15) % 2
  local cells_mode = math.floor(u / 30) % 7
  if cells_mode > M.CELLS_MODE_MAX then cells_mode = M.CELLS_MODE_MAX end
  local cbc_hz = math.floor(u / 210)
  if cbc_hz > M.CBC_ABS_HZ_MAX then cbc_hz = M.CBC_ABS_HZ_MAX end
  local thr_cV = M.VOLT_THR_CV_MIN + thr_idx * M.VOLT_THR_CV_STEP
  if thr_cV > M.VOLT_THR_CV_MAX then thr_cV = M.VOLT_THR_CV_MAX end
  return alarm, thr_cV, cells_mode, cbc_hz
end

function M.encodeLapVolt(alarm_en, thr_cV, cells_mode, cbc_hz)
  local a = (alarm_en and alarm_en ~= 0) and 1 or 0
  local thr_idx = math.floor(((thr_cV or M.VOLT_THR_CV_DEFAULT) - M.VOLT_THR_CV_MIN) / M.VOLT_THR_CV_STEP + 0.5)
  if thr_idx < 0 then thr_idx = 0 end
  if thr_idx > M.VOLT_THR_IDX_MAX then thr_idx = M.VOLT_THR_IDX_MAX end
  local cm = cells_mode or 0
  if cm < 0 then cm = 0 end
  if cm > M.CELLS_MODE_MAX then cm = M.CELLS_MODE_MAX end
  local h = cbc_hz or 0
  if h < 0 then h = 0 end
  if h > M.CBC_ABS_HZ_MAX then h = M.CBC_ABS_HZ_MAX end
  local u = thr_idx + a * 15 + cm * 30 + h * 210
  return u - 1024
end

-- GVAR1 FREQ: abs_freq + dyn_target (both 5..33), non-neg max 840
function M.packAbsFreqDyn(freq, dyn_hz)
  local f = math.min(M.ABS_FREQ_MAX, math.max(M.ABS_FREQ_MIN, freq or M.ABS_FREQ_MIN))
  local d = math.min(M.ABS_FREQ_MAX, math.max(M.ABS_FREQ_MIN, dyn_hz or 6))
  return (f - 5) + 29 * (d - 5)
end

function M.unpackAbsFreqDyn(raw)
  raw = math.max(0, raw or 0)
  if raw > 840 then raw = 840 end
  local fi = raw % 29
  local di = math.floor(raw / 29) % 29
  local f = fi + 5
  local d = di + 5
  if f > M.ABS_FREQ_MAX then f = M.ABS_FREQ_MAX end
  if d > M.ABS_FREQ_MAX then d = M.ABS_FREQ_MAX end
  return f, d
end

-- Round gain 0..100 to nearest GAIN_STEP (5)
function M.roundGain(g)
  g = g or 0
  local step = M.GAIN_STEP
  local v = math.floor(g / step + 0.5) * step
  if v < 0 then v = 0 end
  if v > 100 then v = 100 end
  return v
end

-- ---------------------------------------------------------------------------
-- Pack voltage + cell estimate (home shell needs these without absconf)
-- ---------------------------------------------------------------------------
local _pack_field_id = nil
local _pack_resolved = false
local PACK_NAMES = { "RxBt", "A1", "VFAS", "Cels" }

function M.readPackVoltage()
  if not _pack_resolved then
    _pack_resolved = true
    if getFieldInfo then
      for i = 1, #PACK_NAMES do
        local info = getFieldInfo(PACK_NAMES[i])
        if info and info.id then
          _pack_field_id = info.id
          break
        end
      end
    end
  end
  local v = 0
  if _pack_field_id and getValue then
    v = getValue(_pack_field_id) or 0
  elseif getValue then
    v = getValue("RxBt") or getValue("A1") or getValue("VFAS") or getValue("Cels") or 0
  end
  if v > 100 then v = v / 100 end
  if v < 0 then v = 0 end
  return v
end

-- Chemistry-aware pack → S estimate (used only for Auto before lock).
-- LiHV thresholds sit above LiHV nS full so e.g. 2S LiHV 8.70 V ≠ 3S.
function M.estimateCells(v, batt_type)
  if not v or v < 5.5 then return 0 end
  local lihv = (batt_type == M.BATT_TYPE_LIHV)
  if lihv then
    if v >= 19.2 then return 6 end
    if v >= 15.6 then return 5 end
    if v >= 12.0 then return 4 end
    if v >= 9.0 then return 3 end
    return 2
  end
  if v >= 18.5 then return 6 end
  if v >= 15.0 then return 5 end
  if v >= 11.5 then return 4 end
  if v >= 8.5 then return 3 end
  return 2
end

-- Linear SoC from cell voltage; empty=3.50 both chemistries.
function M.cellPercent(cell_v, batt_type)
  if not cell_v or cell_v <= 0 then return nil end
  local full = (batt_type == M.BATT_TYPE_LIHV) and M.LIHV_FULL or M.LIPO_FULL
  local empty = M.LIPO_EMPTY
  local p = (cell_v - empty) / (full - empty) * 100
  if p < 0 then p = 0 end
  if p > 100 then p = 100 end
  return math.floor(p + 0.5)
end

-- Lap / timer channel triggers (home + bg need these without conf)
local _lap_src_cached = -1
local _lap_field_id = nil
local _lap_fallback = nil
function M.readLapTrigger(lap_src)
  local src = lap_src or 0
  if src < 0 then src = 0 end
  if src > 7 then src = 7 end
  if src ~= _lap_src_cached then
    _lap_src_cached = src
    local ch = src + 1
    local info = getFieldInfo and (getFieldInfo(CH_LO[ch]) or getFieldInfo(CH_HI[ch]))
    _lap_field_id = info and info.id or nil
    if not _lap_field_id then
      _lap_fallback = CH_LO[ch]
    else
      _lap_fallback = nil
    end
  end
  if _lap_field_id and getValue then
    return getValue(_lap_field_id) or 0
  end
  if getValue then
    return getValue(_lap_fallback) or getValue(CH_HI[src + 1]) or 0
  end
  return 0
end

local _tmr_src_cached = -1
local _tmr_field_id = nil
local _tmr_fallback = nil
function M.readTmrTrigger(tmr_src)
  local src = tmr_src or 0
  if src < 0 then src = 0 end
  if src > 7 then src = 7 end
  if src ~= _tmr_src_cached then
    _tmr_src_cached = src
    local ch = src + 1
    local info = getFieldInfo and (getFieldInfo(CH_LO[ch]) or getFieldInfo(CH_HI[ch]))
    _tmr_field_id = info and info.id or nil
    if not _tmr_field_id then
      _tmr_fallback = CH_LO[ch]
    else
      _tmr_fallback = nil
    end
  end
  if _tmr_field_id and getValue then
    return getValue(_tmr_field_id) or 0
  end
  if getValue then
    return getValue(_tmr_fallback) or getValue(CH_HI[src + 1]) or 0
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- Parameter Read (TTL-cached) — v10 single-format, no migrate
-- ---------------------------------------------------------------------------
function M.readParams()
  local now = getTime and getTime() or 0
  if M._pcache and (now - M._pcache_frame) < M._pcache_ttl then
    return M._pcache
  end

  local p = M._pcache or {}

  local mode, delay_ms, _, _, cbc_min_ms = M.unpackGv0(M.gvarGet(M.GV_ABS_MODE))
  p.abs_mode    = mode
  p.abs_duty    = delay_ms
  p.cbc_min_ms  = cbc_min_ms or M.CBC_MIN_MS_OFF

  local abs_freq, dyn_maxhz = M.unpackAbsFreqDyn(M.gvarGet(M.GV_ABS_FREQ))
  p.abs_freq   = abs_freq
  p.dyn_maxhz  = dyn_maxhz

  local tcs_ramp, dyn_min_ms, show_tmr = M.unpackTcsDynMinShow(M.gvarGet(M.GV_TCS_RAMP))
  p.tcs_ramp   = math.min(100, math.max(0, tcs_ramp))
  p.dyn_min_ms = dyn_min_ms
  p.show_tmr   = show_tmr

  local sstc_gain, cbc_gain = M.unpackSstcCbcHz(M.gvarGet(M.GV_SSTC_GAIN))
  p.sstc_gain  = sstc_gain
  p.cbc_gain   = cbc_gain

  local bk_raw = math.max(0, M.gvarGet(M.GV_BRK_FLOOR))
  local bk_floor_idx = bk_raw % 21
  local bk_trig_idx  = math.floor(bk_raw / 21)
  p.brk_floor = math.min(100, math.max(0, bk_floor_idx * 5))
  p.abs_trig  = math.min(100, math.max(5, (bk_trig_idx + 1) * 5))

  local timer_min, tmr_ch, batt_type = M.unpackTimer(M.gvarGet(M.GV_TIMER_CFG))
  p.timer_min  = timer_min
  p.tmr_src    = tmr_ch
  p.batt_type  = batt_type or 0

  local dsr_gain, dsr_start = M.unpackDsrVib(M.gvarGet(M.GV_DSR_GAIN))
  p.dsr_gain  = dsr_gain
  p.dsr_start = dsr_start

  local volt_alarm, thr_cV, cells_mode, cbc_hz = M.decodeLapVolt(M.gvarGet(M.GV_LAP_CONFIG))
  p.volt_alarm   = volt_alarm
  p.volt_thr_cV  = thr_cV
  p.volt_delay_s = M.VOLT_ALARM_DELAY_S
  p.cells_mode   = cells_mode or 0
  p.cbc_abs_hz   = cbc_hz or 0

  local hw = math.max(0, M.gvarGet(M.GV_HW_CONFIG))
  p.brake_dir  = hw % 2
  p.steer_src  = math.floor(hw / 2) % 8
  p.lap_src    = math.floor(hw / 16) % 8
  p.lap_haptic = math.floor(hw / 128) % 2
  p.lap_tstart = math.floor(hw / 256) % 2
  p.str_dir    = math.floor(hw / 512) % 2

  p.abs_enabled = (p.abs_mode > 0)
  p.abs_dynamic = (p.abs_mode == 2)
  p.any_drive = p.abs_enabled
      or (p.tcs_ramp > 0)
      or (p.sstc_gain > 0)
      or (p.cbc_gain > 0)
      or (p.cbc_abs_hz > 0)
      or (p.cbc_min_ms > 0)
      or (p.dyn_min_ms > 0)
      or (p.dsr_gain > 0)
  p.need_steer = (p.sstc_gain > 0) or (p.cbc_gain > 0)
      or (p.cbc_abs_hz > 0) or (p.cbc_min_ms > 0)

  M._pcache = p
  M._pcache_frame = now
  return p
end

-- ---------------------------------------------------------------------------
-- Input readers (field-id cached; prebuilt CH name tables)
-- ---------------------------------------------------------------------------
local function gfi(name)
  if getFieldInfo then return getFieldInfo(name) end
  return nil
end

local function gv(id_or_name)
  if getValue then return getValue(id_or_name) end
  return nil
end

local function readAilStick()
  if not M._ail_resolved then
    M._ail_resolved = true
    local info = gfi("ail") or gfi("Ail") or gfi("AIL")
      or gfi("steering") or gfi("Steering")
    M._ail_field_id = info and info.id or nil
  end
  if M._ail_field_id then
    local v = gv(M._ail_field_id)
    if v ~= nil then return v end
  end
  local v = gv("ail") or gv("Ail") or gv("AIL")
  if v ~= nil then return v end
  return gv("steering") or gv("Steering")
end

local function readSteerChannel(steer_src)
  local src = steer_src or 0
  if src < 0 then src = 0 end
  if src > 7 then src = 7 end
  if src ~= M._steer_src_cached then
    M._steer_src_cached = src
    local ch = src + 1
    local info = gfi(CH_LO[ch]) or gfi(CH_HI[ch]) or gfi(CH_FULL[ch])
    M._steer_field_id = info and info.id or nil
    if not M._steer_field_id then
      M._steer_fallback = CH_LO[ch]
    else
      M._steer_fallback = nil
    end
  end
  if M._steer_field_id then
    local v = gv(M._steer_field_id)
    if v ~= nil then return v end
  end
  if M._steer_fallback then
    local v = gv(M._steer_fallback)
    if v ~= nil then return v end
  end
  local ch = (steer_src or 0) + 1
  if ch < 1 then ch = 1 end
  if ch > 8 then ch = 8 end
  return gv(CH_LO[ch]) or gv(CH_HI[ch])
end

function M.readSteer(steer_src)
  local stick = readAilStick()
  local ch_val = readSteerChannel(steer_src)
  local as = stick or 0
  local ac = ch_val or 0
  if math.abs(as) >= math.abs(ac) then
    return as
  end
  return ac
end

function M.readThr()
  if not M._thr_resolved then
    local info = gfi("Thr") or gfi("thr")
    M._thr_field_id = info and info.id or nil
    M._thr_resolved = true
  end
  if M._thr_field_id then return gv(M._thr_field_id) or 0 end
  return gv("Thr") or gv("thr") or 0
end

-- ---------------------------------------------------------------------------
-- Signal Processing Pipeline — UNCHANGED math vs v9.9.1
-- ---------------------------------------------------------------------------
function M.process(raw_thr, steer, params, state, t_ticks, for_display)
  local flags = M.resetFlags()

  if not raw_thr then
    return 1024, 1024, flags
  end

  if not params.any_drive then
    state.was_braking = false
    state.was_accel = false
    state.last_thr = raw_thr
    if t_ticks then state.last_ticks = t_ticks end
    flags.output_thr = raw_thr
    return 1024, 1024, flags
  end

  local abs = math.abs; local floor = math.floor
  local min = math.min; local max = math.max
  local ACCEL_DZ = M.ACCEL_DEADZONE; local FREQ_MIN = M.ABS_FREQ_MIN
  local FREQ_MAX = M.ABS_FREQ_MAX; local BRAKE_HYST = M.BRAKE_HYSTERESIS
  local SSTEER_MIN = M.SSTEER_MIN; local DSR_MAX_RED = M.DSR_MAX_REDUCTION
  local TCS_RISE_MIN = M.TCS_RISE_MIN_S; local TCS_RISE_MAX = M.TCS_RISE_MAX_S
  local TCS_DT_MIN = M.TCS_DT_MIN; local TCS_DT_MAX = M.TCS_DT_MAX
  local MIXER_DT = M.MIXER_DT

  local thr = raw_thr

  local is_accel
  if params.brake_dir == 1 then
    is_accel = (raw_thr < -ACCEL_DZ)
  else
    is_accel = (raw_thr > ACCEL_DZ)
  end

  if not state.was_accel and is_accel then
    if abs(state.last_thr) < ACCEL_DZ then
      state.last_thr = 0
    end
  end
  state.was_accel = is_accel

  local steer_factor = 0
  if params.need_steer then
    steer_factor = min(1.0, abs(steer) / 1024)
  end

  if params.tcs_ramp > 0 and is_accel then
    local dt = MIXER_DT
    if t_ticks and state.last_ticks and state.last_ticks > 0 then
      dt = (t_ticks - state.last_ticks) * 0.01
      if dt < TCS_DT_MIN then dt = TCS_DT_MIN end
      if dt > TCS_DT_MAX then dt = TCS_DT_MAX end
    end

    -- 1:4 strength: UI 100% behaves like previous 25% (weaker TCS)
    local tcs_effective = params.tcs_ramp * 0.25
    local t_full = TCS_RISE_MIN + (tcs_effective * 0.01) * (TCS_RISE_MAX - TCS_RISE_MIN)
    if t_full < 0.001 then t_full = 0.001 end
    local max_step = 1024 * dt / t_full
    local last = state.last_thr

    local more_throttle
    if params.brake_dir == 1 then
      more_throttle = (raw_thr < last)
    else
      more_throttle = (raw_thr > last)
    end

    if more_throttle then
      local delta = raw_thr - last
      local ad = abs(delta)
      if ad > max_step then
        if delta > 0 then
          thr = last + max_step
          if thr > raw_thr then thr = raw_thr end
        else
          thr = last - max_step
          if thr < raw_thr then thr = raw_thr end
        end
        if abs(thr - raw_thr) > 0.5 then
          flags.tcs = true
        end
      else
        thr = raw_thr
      end
    else
      thr = raw_thr
    end
  end
  state.last_thr = thr
  if t_ticks then state.last_ticks = t_ticks end

  if is_accel and params.sstc_gain > 0 and steer_factor > SSTEER_MIN then
    local reduction = steer_factor * (params.sstc_gain / 100)
    thr = floor(thr * (1.0 - reduction))
    flags.sstc = true
  end

  if not is_accel and params.cbc_gain > 0 and steer_factor > SSTEER_MIN then
    local reduction = steer_factor * (params.cbc_gain / 100)
    thr = floor(thr * (1.0 - reduction))
    flags.cbc = true
  end

  if params.abs_enabled then
    local prev_braking = state.was_braking
    local active_thresh = params.abs_trig
    if prev_braking then
      active_thresh = max(1, params.abs_trig - BRAKE_HYST)
    end
    local brake_threshold = active_thresh * 10.24

    local is_braking = false
    if params.brake_dir == 1 then
      is_braking = (raw_thr > ACCEL_DZ) and (raw_thr > brake_threshold)
    else
      is_braking = (raw_thr < -ACCEL_DZ) and (raw_thr < -brake_threshold)
    end

    if is_braking then
      flags.abs_active = true

      if not prev_braking then
        state.abs_phase = 0
        state.abs_t0 = t_ticks or 0
        state.abs_pwm_acc = 0
        state.abs_lock_freq = nil
        state.abs_lock_floor = nil
        state.abs_peak_i = 0
        state.last_abs_ticks = t_ticks or 0
      end

      local eff_freq = params.abs_freq
      local eff_floor = params.brk_floor

      if params.abs_dynamic then
        -- Lerp base ABS Freq → DYN End Hz by brake intensity (End may be lower or higher)
        local brake_pct = min(100, abs(thr) / 10.24)
        local intensity = brake_pct / 100
        local peak = state.abs_peak_i or 0
        if intensity > peak then
          peak = intensity
          state.abs_peak_i = peak
          state.abs_lock_freq = nil
        end
        if not state.abs_lock_freq then
          local i = state.abs_peak_i or intensity
          state.abs_lock_freq = floor(params.abs_freq + (params.dyn_maxhz - params.abs_freq) * i)
          state.abs_lock_floor = floor(params.brk_floor * (1.0 - i * 0.4))
        end
        eff_freq = state.abs_lock_freq
        eff_floor = state.abs_lock_floor
      end

      -- CBC ABS Hz: add boost proportional to steering (100% steer = full setting)
      if params.cbc_abs_hz and params.cbc_abs_hz > 0 and steer_factor > 0 then
        eff_freq = floor(eff_freq + steer_factor * params.cbc_abs_hz + 0.5)
      end

      eff_freq = min(FREQ_MAX, max(FREQ_MIN, eff_freq))
      eff_floor = min(100, max(0, eff_floor))

      -- Pulse Delay = baseline full-brake hold per cycle.
      -- DYN Min Dly and CBC Min Dly are independent (same lerp idea, different axes):
      --   1) DYNAMIC + peak intensity → toward dyn_min_ms (brake only; ignores steer)
      --   2) CBC Min + steer          → toward cbc_min_ms (steer only; ignores peak)
      -- Order matches Hz: DYN first, then CBC on top. Targets are never shared.
      local delay_ms = params.abs_duty or M.ABS_DELAY_MS_DEFAULT
      local dyn_min = params.dyn_min_ms or M.DYN_MIN_MS_OFF
      if params.abs_dynamic and dyn_min > 0 then
        local peak_i = state.abs_peak_i or 0
        if peak_i > 0 then
          local target = dyn_min
          if target > delay_ms then target = delay_ms end
          delay_ms = delay_ms + (target - delay_ms) * peak_i
        end
      end
      local cbc_min = params.cbc_min_ms or M.CBC_MIN_MS_OFF
      if cbc_min > 0 and steer_factor > 0 then
        local target = cbc_min
        if target > delay_ms then target = delay_ms end
        delay_ms = delay_ms + (target - delay_ms) * steer_factor
      end
      if delay_ms < M.ABS_DELAY_MS_MIN then delay_ms = M.ABS_DELAY_MS_MIN end
      if delay_ms > M.ABS_DELAY_MS_MAX then delay_ms = M.ABS_DELAY_MS_MAX end

      -- Cycle length in ms. getTime is 10 ms/tick; mixer is ~30 ms — high CBC Hz
      -- can make cycle ≤ one mixer frame, which used to lock phase at 0 (no pulse).
      local cycle_ms = floor((1000 / eff_freq) + 0.5)
      if cycle_ms < 1 then cycle_ms = 1 end

      local dt_ticks = 0
      if t_ticks and state.last_abs_ticks and state.last_abs_ticks > 0 then
        dt_ticks = t_ticks - state.last_abs_ticks
        if dt_ticks < 0 then dt_ticks = 0 end
      end
      local dt_ms = dt_ticks * 10
      if dt_ms <= 0 then
        dt_ms = floor(MIXER_DT * 1000 + 0.5)  -- ~33 ms first frame / no clock
      end
      if t_ticks then state.last_abs_ticks = t_ticks end
      if not state.abs_t0 then state.abs_t0 = t_ticks or 0 end

      -- Leave a minimum release window so duty never becomes 100% full lock.
      local full_ms = delay_ms
      if full_ms > 0 and full_ms >= cycle_ms then
        full_ms = cycle_ms * 0.75
      end

      -- Wall-clock phase only resolves FULL+FLOOR when we sample ≥2× per cycle.
      -- Otherwise use mixer-rate PWM so high CBC Hz still chatters.
      local use_pwm = (dt_ms * 2 >= cycle_ms)
      local apply_floor = false

      if delay_ms <= 0 then
        apply_floor = true
        state.abs_phase = 0
      elseif use_pwm then
        -- Bresenham-style PWM at mixer rate (max chatter ≈ mixer/2).
        local full_ratio = full_ms / cycle_ms
        if full_ratio > 0.85 then full_ratio = 0.85 end
        if full_ratio < 0 then full_ratio = 0 end
        local acc = (state.abs_pwm_acc or 0) + full_ratio
        if acc >= 1.0 then
          acc = acc - 1.0
          apply_floor = false
        else
          apply_floor = true
        end
        state.abs_pwm_acc = acc
        state.abs_phase = apply_floor and 1 or 0
      else
        local elapsed_ms = 0
        if t_ticks then
          elapsed_ms = (t_ticks - (state.abs_t0 or t_ticks)) * 10
          if elapsed_ms < 0 then elapsed_ms = 0 end
        end
        local pos_ms = elapsed_ms % cycle_ms
        apply_floor = (pos_ms >= full_ms)
        state.abs_phase = floor(pos_ms / 10)
      end

      if for_display then
        flags.eff_floor = eff_floor
        local pre_brake_pct = min(100, abs(thr) / 10.24)
        flags.abs_floor_pct = floor(pre_brake_pct * eff_floor / 100)
      end

      if apply_floor then
        thr = floor(thr * (eff_floor / 100))
      end
    else
      state.abs_phase = 0
      state.abs_t0 = nil
      state.abs_pwm_acc = 0
      state.abs_lock_freq = nil
      state.abs_lock_floor = nil
      state.abs_peak_i = 0
      if t_ticks then state.last_abs_ticks = t_ticks end
    end
    state.was_braking = is_braking
  else
    state.was_braking = false
    state.abs_phase = 0
    state.abs_t0 = nil
    state.abs_pwm_acc = 0
    state.abs_lock_freq = nil
    state.abs_lock_floor = nil
    state.abs_peak_i = 0
  end

  local str_mul = 1024
  if is_accel and params.dsr_gain > 0 and params.dsr_start < 100 then
    local thr_pct = min(100, abs(thr) / 10.24)
    if thr_pct > params.dsr_start then
      flags.dsr = true
      local speed_factor = (thr_pct - params.dsr_start) / (100 - params.dsr_start)
      local reduction = (params.dsr_gain / 100) * speed_factor * DSR_MAX_RED
      str_mul = floor(1024 * (1.0 - reduction))
      if str_mul < 0 then str_mul = 0 end
    end
  end

  local drive_mul = 1024
  if thr ~= raw_thr and raw_thr ~= 0 then
    drive_mul = floor((thr / raw_thr) * 1024)
    if drive_mul < 0 then drive_mul = 0 end
    if drive_mul > 1024 then drive_mul = 1024 end
  end

  flags.output_thr = thr
  return drive_mul, str_mul, flags
end

function M.initDefaults()
  -- v10: FREQ non-neg 0..840, TCS 0..881, GAIN 0..440.
  -- All-zero model (never configured) → write defaults.
  local f = M.gvarGet(M.GV_ABS_FREQ)
  local t = M.gvarGet(M.GV_TCS_RAMP)
  local g = M.gvarGet(M.GV_SSTC_GAIN)
  local valid = (f >= 0 and f <= 840) and (t >= 0 and t <= 881) and (g >= 0 and g <= 440)
  if valid and f == 0 and t == 0 and g == 0
      and M.gvarGet(M.GV_ABS_MODE) == 0 and M.gvarGet(M.GV_BRK_FLOOR) == 0 then
    valid = false
  end
  if not valid then
    M.gvarSet(M.GV_ABS_MODE, M.packGv0(0, M.ABS_DELAY_MS_DEFAULT, 0, 0, M.CBC_MIN_MS_OFF))
    M.gvarSet(M.GV_ABS_FREQ,  M.packAbsFreqDyn(5, 6))
    M.gvarSet(M.GV_BRK_FLOOR, 0)
    M.gvarSet(M.GV_TCS_RAMP,  M.packTcsDynMinShow(0, M.DYN_MIN_MS_OFF, 0))
    M.gvarSet(M.GV_SSTC_GAIN, M.packSstcCbcHz(0, 0))
    M.gvarSet(M.GV_TIMER_CFG, M.packTimer(M.TIMER_MIN_DEFAULT, 0, M.BATT_TYPE_LIPO))
    M.gvarSet(M.GV_DSR_GAIN,  M.packDsrVib(0, 0))
    M.gvarSet(M.GV_LAP_CONFIG, M.encodeLapVolt(0, M.VOLT_THR_CV_DEFAULT, M.CELLS_MODE_AUTO, 0))
    M.gvarSet(M.GV_HW_CONFIG, 0)
    M._pcache = nil
    M._pcache_frame = 0
  end
end

function M.newState()
  return {
    was_braking = false,
    last_thr = 0,
    was_accel = false,
    last_ticks = 0,
    abs_phase = 0,
    abs_t0 = nil,
    abs_pwm_acc = 0,
    last_abs_ticks = 0,
    abs_lock_freq = nil,
    abs_lock_floor = nil,
    abs_peak_i = 0,
  }
end

rawset(_G, "ABSCORE", M)
return M

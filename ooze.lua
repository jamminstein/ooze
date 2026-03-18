-- ooze.lua  –  v2
-- ───────────────────────────────────────────────────────────────────────────
-- Record a sound. Transform it into an infinite instrument.
--
-- GRID  (16 × 8)
--   rows 1–5  │  play zone: 16 scale-snapped pitches × 5 sonic characters
--   row  6    │  HARM: every press triggers 4 stacked harmonic partials
--   row  7    │  cols 1–8  → play bank selector  (hold 0.4s = set record bank)
--             │  cols 10–16 → scale selector (7 scales)
--   row  8    │  [REC] [GRN] [REV] [BIT] [THR] . . [LOOP] [DUB] . . . [CLR]
--
-- NORNS KEYS
--   K2  →  record / stop  (same as grid REC)
--   K3  →  advance record bank
--
-- ENCODERS
--   E1  →  transpose  (±12 semitones)
--   E2  →  select play bank
--   E3  →  global reverb add
--
-- LAYER RECORDING
--   play bank and record bank are independent.
--   switch play_bank with E2 / tap row 7.
--   switch record_bank with K3 / hold row 7.
--   record into bank 2 while playing bank 1 live.
--
-- LOOP MODE (col 10, row 8)
--   REC → start loop capture  →  STOP → loop locked, plays immediately
--   REC again → overdub  →  STOP → back to clean loop
--   grid rows 1–6 still trigger one-shots over the loop
-- ───────────────────────────────────────────────────────────────────────────

engine.name = "Ooze"
local musicutil = require "musicutil"

-- ─── grid ─────────────────────────────────────────────────────────────────
local g = grid.connect()

-- ─── constants ────────────────────────────────────────────────────────────
local NUM_BANKS  = 8
local NUM_COLS   = 16
local MAX_REC    = 20       -- one-shot max duration (seconds)
local NORNS_SR   = 48000    -- assumed sample rate for loop frame calc
local HOLD_TIME  = 0.40     -- row-7 hold threshold (seconds)
local GHOST_FPS  = 20       -- ghost echo update rate
local XFADE_MS   = 40       -- crossfade length at loop point (ms)
local SNAP_TOL   = 0.08     -- tempo snap tolerance (8% → max ~1.3 semitones shift)

-- brightness palette
local B = { off=0, ghost=1, dim=3, low=5, mid=8, high=11, full=15 }

-- ─── play rows ────────────────────────────────────────────────────────────
-- { rate_mult, atk, dec, rev, dist, label, base_brightness }
local ROWS = {
  { 1.00, 0.002, 0.18, 0.00, 0.00, "PUNCH", B.high },  -- 1: dry crack
  { 1.00, 0.07,  0.70, 0.14, 0.00, "WARM",  B.mid  },  -- 2: soft bloom
  { 1.00, 0.008, 0.50, 0.58, 0.00, "SPACE", B.low  },  -- 3: cavernous
  { 1.50, 0.12,  1.40, 0.82, 0.00, "CLOUD", B.dim  },  -- 4: 5th up, shimmer
  { 1.00, 0.003, 0.32, 0.04, 0.52, "GRIT",  B.mid  },  -- 5: saturation
  { 1.00, 0.010, 1.10, 0.22, 0.00, "HARM",  B.low  },  -- 6: harmonic stack
}

-- ─── scales (semitone intervals from root) ────────────────────────────────
local SCALES = {
  { name="CHROM",  intervals={0,1,2,3,4,5,6,7,8,9,10,11} },
  { name="MAJOR",  intervals={0,2,4,5,7,9,11}             },
  { name="MINOR",  intervals={0,2,3,5,7,8,10}             },
  { name="DORIAN", intervals={0,2,3,5,7,9,10}             },
  { name="PENTA",  intervals={0,2,4,7,9}                  },
  { name="BLUES",  intervals={0,3,5,6,7,10}               },
  { name="LYDIAN", intervals={0,2,4,6,7,9,11}             },
}
local current_scale = 2   -- start on MAJOR

-- ─── state ────────────────────────────────────────────────────────────────
local play_bank    = 1
local record_bank  = 1
local pitch_shift  = 0       -- semitones ±12
local global_rev   = 0.0     -- additive reverb 0–1

-- toggles (row 8)
local gran_on    = false   -- granular mode
local rev_on     = false   -- reverse
local bits_on    = false   -- bitcrush
local thresh_arm = false   -- threshold auto-record
local loop_mode  = false   -- loop mode for record bank

-- one-shot recording
local rec_state      = "idle"  -- "idle" | "recording" | "processing"
local rec_start_time = 0
local rec_clock_id   = nil
local blink_on       = false

-- per-bank data
local banks = {}
for i = 1, NUM_BANKS do
  banks[i] = {
    recorded    = false,
    duration    = 0.0,
    from_disk   = false,
    loop_state  = "empty",   -- "empty"|"recording"|"playing"|"overdubbing"
    loop_frames = 0,
    loop_rate   = 1.0,       -- tempo-correction rate (1.0 = no correction)
    loop_target = 0.0,       -- snapped musical duration (seconds)
  }
end

-- ghost echo tables  [row][col] → float brightness / decay-per-frame
local ghost_bri  = {}
local ghost_rate = {}
for y = 1, 8 do
  ghost_bri[y]  = {}
  ghost_rate[y] = {}
  for x = 1, 16 do ghost_bri[y][x] = 0; ghost_rate[y][x] = 0 end
end

-- row-7 hold detection
local r7_press_time = {}

-- clock IDs for cleanup
local ghost_echo_clock_id = nil
local blink_clock_id = nil

-- forward declarations
local redraw, grid_redraw

-- ─── helpers ──────────────────────────────────────────────────────────────

local function col_to_rate(col, row_mult)
  local ivs     = SCALES[current_scale].intervals
  local n       = #ivs
  local idx     = (col - 1) % n
  local oct     = math.floor((col - 1) / n)
  local st      = ivs[idx + 1] + (oct * 12) + pitch_shift
  return (2.0 ^ (st / 12.0)) * (row_mult or 1.0)
end

local function add_ghost(x, y, bri, decay_sec)
  ghost_bri[y][x]  = math.max(ghost_bri[y][x], bri)
  ghost_rate[y][x] = bri / math.max(0.05, decay_sec * GHOST_FPS)
end

local function save_bank(bank)
  local path = norns.state.data .. "bank_" .. bank .. ".wav"
  engine.save(bank - 1, path)
end

-- Given a recorded duration and current BPM, return the playback rate needed
-- to align the loop to the nearest musical grid point.
-- Returns 1.0 if the recording is too far from any target (> SNAP_TOL).
local function tempo_snap_rate(dur_sec, bpm)
  local beat = 60.0 / bpm
  -- candidates: half-beat up to 8 bars — covers most practical loop lengths
  local candidates = {
    beat * 0.5,
    beat,
    beat * 2,
    beat * 4,
    beat * 8,
    beat * 16,
    beat * 32,
  }
  local best_target = dur_sec
  local best_diff   = math.huge
  for _, c in ipairs(candidates) do
    local diff = math.abs(dur_sec - c)
    if diff < best_diff then
      best_diff   = diff
      best_target = c
    end
  end
  local rel_err = math.abs(best_target - dur_sec) / dur_sec
  if rel_err < SNAP_TOL then
    -- rate > 1 → loop plays slightly fast (recorded long)
    -- rate < 1 → loop plays slightly slow (recorded short)
    return dur_sec / best_target, best_target, rel_err
  end
  return 1.0, dur_sec, 0.0
end

-- ─── one-shot recording ───────────────────────────────────────────────────

local function finalize_rec(bank)
  rec_state = "processing"
  redraw(); grid_redraw()
  clock.run(function()
    clock.sleep(0.15)
    engine.normalize(bank - 1)
    clock.sleep(0.30)
    save_bank(bank)
    banks[bank].recorded  = true
    banks[bank].from_disk = false
    rec_state = "idle"
    redraw(); grid_redraw()
  end)
end

local function start_recording()
  if rec_state ~= "idle" then return end
  rec_state      = "recording"
  rec_start_time = util.time()
  engine.rec_start(record_bank - 1)
  -- auto-stop safety
  rec_clock_id = clock.run(function()
    clock.sleep(MAX_REC)
    if rec_state == "recording" then
      engine.rec_stop(record_bank - 1)
      banks[record_bank].duration = util.time() - rec_start_time
      finalize_rec(record_bank)
    end
  end)
  redraw(); grid_redraw()
end

local function stop_recording()
  if rec_state ~= "recording" then return end
  if rec_clock_id then clock.cancel(rec_clock_id); rec_clock_id = nil end
  engine.rec_stop(record_bank - 1)
  banks[record_bank].duration = util.time() - rec_start_time
  finalize_rec(record_bank)
end

-- ─── playback ─────────────────────────────────────────────────────────────

local function do_play(col, row_idx)
  if not banks[play_bank].recorded then return end
  local r     = ROWS[row_idx]
  local rate  = col_to_rate(col, r[1])
  local amp   = 0.76
  local atk   = r[2]
  local dec   = r[3]
  local rev   = math.min(1.0, r[4] + global_rev * 0.50)
  local dist  = r[5]
  local crush = bits_on and 0.78 or 0.0
  local rflag = rev_on  and 1    or 0

  if gran_on then
    engine.play_gran(play_bank-1, rate, amp*0.88, rev, dist, crush, dec * 1.6)
  else
    engine.play(play_bank-1, rate, amp, atk, dec, rev, dist, crush, rflag)
  end

  add_ghost(col, row_idx, B.full, atk + dec)
end

local function play_harmonics(col)
  if not banks[play_bank].recorded then return end
  local base   = col_to_rate(col, 1.0)
  local crush  = bits_on and 0.78 or 0.0
  local rflag  = rev_on  and 1    or 0
  local rev    = math.min(1.0, ROWS[6][4] + global_rev * 0.50)
  local dist   = ROWS[6][5]

  -- fundamental + 3 harmonic partials, diminishing amplitude
  local partials = {
    { mult=1.0,  amp=0.65 },
    { mult=2.0,  amp=0.36 },
    { mult=3.0,  amp=0.22 },
    { mult=4.0,  amp=0.13 },
  }
  for _, p in ipairs(partials) do
    if gran_on then
      engine.play_gran(play_bank-1, base*p.mult, p.amp, rev, dist, crush, 1.4)
    else
      engine.play(play_bank-1, base*p.mult, p.amp, 0.010, 1.30, rev, dist, crush, rflag)
    end
  end
  add_ghost(col, 6, B.full, 1.4)
end

-- ─── loop mode ────────────────────────────────────────────────────────────

local function loop_rec_toggle()
  local bank = record_bank
  local ls   = banks[bank].loop_state

  if ls == "empty" then
    banks[bank].loop_state = "recording"
    engine.loop_rec_start(bank - 1)
    rec_start_time = util.time()

  elseif ls == "recording" then
    engine.loop_rec_stop(bank - 1)
    local dur = util.time() - rec_start_time
    banks[bank].duration    = dur
    banks[bank].loop_frames = math.floor(dur * NORNS_SR)
    banks[bank].loop_state  = "processing_loop"
    clock.run(function()
      -- 1. normalize to peak
      clock.sleep(0.15)
      engine.normalize(bank - 1)

      -- 2. bake crossfade into buffer (eliminates loop-point click)
      local xfade_frames = math.floor(XFADE_MS * 0.001 * NORNS_SR)
      clock.sleep(0.10)
      engine.loop_xfade(bank - 1, banks[bank].loop_frames, xfade_frames)
      -- wait for xfade SynthDef to finish (duration + small margin)
      clock.sleep(XFADE_MS * 0.001 + 0.05)

      -- 3. tempo snap: find nearest musical target and get correction rate
      local bpm  = clock.get_tempo()
      local rate, target_sec, err = tempo_snap_rate(dur, bpm)
      banks[bank].loop_rate   = rate
      banks[bank].loop_target = target_sec

      -- 4. start playback with corrected rate
      engine.loop_play_start(bank - 1, banks[bank].loop_frames, rate)

      -- 5. save to disk
      clock.sleep(0.10)
      save_bank(bank)
      banks[bank].recorded   = true
      banks[bank].loop_state = "playing"
      redraw(); grid_redraw()
    end)

  elseif ls == "playing" then
    banks[bank].loop_state = "overdubbing"
    engine.loop_overdub_on(bank - 1)

  elseif ls == "overdubbing" then
    banks[bank].loop_state = "playing"
    engine.loop_overdub_off(bank - 1)
  end

  redraw(); grid_redraw()
end

local function loop_clear(bank)
  engine.loop_clear(bank - 1)
  banks[bank].loop_state  = "empty"
  banks[bank].recorded    = false
  banks[bank].duration    = 0.0
  banks[bank].loop_frames = 0
  banks[bank].from_disk   = false
  redraw(); grid_redraw()
end

-- ─── unified REC action ───────────────────────────────────────────────────

local function handle_rec()
  if loop_mode then
    loop_rec_toggle()
  else
    if rec_state == "recording" then
      stop_recording()
    elseif rec_state == "idle" then
      start_recording()
    end
  end
end

-- ─── grid rendering ─────────────────────────────────────────────────────────

grid_redraw = function()
  if not g then return end
  g:all(0)

  local has_sample = banks[play_bank].recorded

  -- rows 1–6: play zone
  for row = 1, 6 do
    local base = ROWS[row][7]
    for col = 1, NUM_COLS do
      local bri = B.ghost

      if has_sample then
        -- very subtle edge dimming for spatial feel
        local edge_dim = math.floor(math.abs(col - 8.5) / 5.5)
        bri = math.max(B.ghost, base - edge_dim)
        -- GRIT row: alternating texture
        if row == 5 and col % 2 == 0 then bri = math.max(B.ghost, bri - 2) end
      end

      -- ghost echo overlay (takes priority when active)
      local gbri = math.floor(ghost_bri[row][col])
      if gbri > bri then bri = gbri end

      g:led(col, row, bri)
    end
  end

  -- row 7: bank selector + scale selector
  for i = 1, NUM_BANKS do
    local bri = B.off
    if banks[i].recorded          then bri = B.low  end
    if i == play_bank             then bri = B.full  end
    -- record bank indicator when different
    if i == record_bank and i ~= play_bank then
      bri = math.max(bri, B.mid)
    end
    -- loop state blink
    local ls = banks[i].loop_state
    if ls == "recording" or ls == "processing_loop" then
      bri = blink_on and B.full or B.dim
    elseif ls == "overdubbing" then
      bri = blink_on and B.high or B.mid
    end
    g:led(i, 7, bri)
  end
  -- scale buttons: cols 10–16
  for i = 1, 7 do
    g:led(9 + i, 7, (i == current_scale) and B.high or B.dim)
  end

  -- row 8: controls
  -- col 1: REC
  local rec_bri = B.mid
  if rec_state == "recording" then
    rec_bri = blink_on and B.full or B.mid
  elseif rec_state == "processing" then
    rec_bri = B.dim
  elseif banks[record_bank].loop_state == "recording"
      or banks[record_bank].loop_state == "processing_loop" then
    rec_bri = blink_on and B.full or B.mid
  end
  g:led(1, 8, rec_bri)

  -- modifiers
  g:led(3,  8, gran_on    and B.full or B.dim)  -- GRN
  g:led(4,  8, rev_on     and B.full or B.dim)  -- REV
  g:led(5,  8, bits_on    and B.full or B.dim)  -- BIT
  g:led(7,  8, thresh_arm and B.full or B.dim)  -- THR
  g:led(10, 8, loop_mode  and B.full or B.dim)  -- LOOP
  -- DUB (only lit when loop playing or overdubbing)
  if loop_mode then
    local ls = banks[record_bank].loop_state
    g:led(12, 8, (ls == "overdubbing") and B.full or B.dim)
  end
  -- CLR
  if has_sample or banks[play_bank].loop_state ~= "empty" then
    g:led(16, 8, B.dim)
  end

  g:refresh()
end

-- ─── screen rendering ─────────────────────────────────────────────────────

redraw = function()
  screen.clear()

  -- title
  screen.level(15)
  screen.move(0, 9)
  screen.text("OOZE")
  screen.level(5)
  screen.move(128, 9)
  screen.text_right("P:" .. play_bank .. "  R:" .. record_bank)

  -- main status
  screen.level(10)
  screen.move(64, 21)
  local lb = banks[play_bank]

  if rec_state == "recording" then
    local el  = util.time() - rec_start_time
    local pct = math.min(1.0, el / MAX_REC)
    screen.text_center("● REC  " .. string.format("%.1f", el) .. "s → bank " .. record_bank)
    screen.level(3); screen.rect(4, 24, 120, 2); screen.fill()
    screen.level(12); screen.rect(4, 24, math.floor(120 * pct), 2); screen.fill()
  elseif rec_state == "processing" then
    screen.text_center("normalizing…")
  else
    local ls = lb.loop_state
    local label
    if     ls == "recording"       then label = "* loop rec"
    elseif ls == "processing_loop" then label = "normalizing + xfade…"
    elseif ls == "playing"         then
      local rate_str = ""
      if lb.loop_rate and math.abs(lb.loop_rate - 1.0) > 0.002 then
        local cents = math.floor(math.log(lb.loop_rate) / math.log(2) * 1200)
        rate_str = "  " .. (cents > 0 and "+" or "") .. cents .. "c"
      end
      label = "> loop  " .. string.format("%.2fs", lb.duration) .. rate_str
    elseif ls == "overdubbing"     then label = "* overdub"
    elseif lb.recorded then
      label = string.format("%.2fs", lb.duration)
      if lb.from_disk then label = label .. "  [disk]" end
    else
      label = "no sample – k2 or grid [REC]"
    end
    screen.text_center(label)
  end

  -- bank dot row
  for i = 1, NUM_BANKS do
    local lv
    if     i == play_bank   then lv = 15
    elseif i == record_bank and i ~= play_bank then lv = 9
    elseif banks[i].recorded then lv = 5
    else   lv = 2
    end
    screen.level(lv)
    screen.move(4 + (i-1)*15, 36)
    screen.text(banks[i].recorded and "#" or ".")
  end

  -- modifiers line
  local mods = {}
  if gran_on    then table.insert(mods, "GRN")  end
  if rev_on     then table.insert(mods, "REV")  end
  if bits_on    then table.insert(mods, "BIT")  end
  if loop_mode  then table.insert(mods, "LOOP") end
  if thresh_arm then table.insert(mods, "THR")  end
  if #mods > 0 then
    screen.level(8)
    screen.move(64, 45)
    screen.text_center(table.concat(mods, " · "))
  end

  -- bottom info bar
  screen.level(4)
  screen.move(4, 56)
  local shift_str = (pitch_shift >= 0 and "+" or "") .. pitch_shift
  screen.text(SCALES[current_scale].name .. "  " .. shift_str .. "st")
  screen.move(128, 56)
  screen.text_right("verb " .. math.floor(global_rev * 100) .. "%")

  screen.update()
end

-- ─── grid input ───────────────────────────────────────────────────────────

g.key = function(x, y, z)
  -- rows 1–5: one-shots
  if y >= 1 and y <= 5 then
    if z == 1 then do_play(x, y) end

  -- row 6: harmonics
  elseif y == 6 then
    if z == 1 then play_harmonics(x) end

  -- row 7: bank & scale selector
  elseif y == 7 then
    if x <= NUM_BANKS then
      if z == 1 then
        r7_press_time[x] = util.time()
      else
        if r7_press_time[x] then
          local held = util.time() - r7_press_time[x]
          if held >= HOLD_TIME then
            record_bank = x              -- hold → set record bank
          else
            play_bank = x                -- tap  → set play bank
          end
          r7_press_time[x] = nil
          redraw(); grid_redraw()
        end
      end
    elseif x >= 10 and x <= 16 and z == 1 then
      current_scale = x - 9            -- cols 10–16 → scales 1–7
      redraw(); grid_redraw()
    end

  -- row 8: controls
  elseif y == 8 and z == 1 then
    if x == 1 then
      handle_rec()

    elseif x == 3 then
      gran_on = not gran_on; redraw(); grid_redraw()

    elseif x == 4 then
      rev_on = not rev_on; redraw(); grid_redraw()

    elseif x == 5 then
      bits_on = not bits_on; redraw(); grid_redraw()

    elseif x == 7 then
      thresh_arm = not thresh_arm
      if thresh_arm then engine.thresh_start(0.04)
      else               engine.thresh_stop()
      end
      redraw(); grid_redraw()

    elseif x == 10 then
      loop_mode = not loop_mode
      redraw(); grid_redraw()

    elseif x == 12 and loop_mode then
      -- manual overdub toggle
      local ls = banks[record_bank].loop_state
      if     ls == "playing"     then
        banks[record_bank].loop_state = "overdubbing"
        engine.loop_overdub_on(record_bank - 1)
      elseif ls == "overdubbing" then
        banks[record_bank].loop_state = "playing"
        engine.loop_overdub_off(record_bank - 1)
      end
      redraw(); grid_redraw()

    elseif x == 16 then
      -- clear play bank
      if loop_mode or banks[play_bank].loop_state ~= "empty" then
        loop_clear(play_bank)
      else
        banks[play_bank].recorded  = false
        banks[play_bank].duration  = 0.0
        banks[play_bank].from_disk = false
        redraw(); grid_redraw()
      end
    end
  end
end

-- ─── encoders ─────────────────────────────────────────────────────────────

function enc(n, d)
  if     n == 1 then
    pitch_shift = util.clamp(pitch_shift + d, -12, 12); redraw()
  elseif n == 2 then
    play_bank = util.clamp(play_bank + d, 1, NUM_BANKS); redraw(); grid_redraw()
  elseif n == 3 then
    global_rev = util.clamp(global_rev + d * 0.04, 0.0, 1.0); redraw()
  end
end

-- ─── norns keys ───────────────────────────────────────────────────────────

function key(n, z)
  if z == 0 then return end
  if     n == 2 then handle_rec()
  elseif n == 3 then
    record_bank = (record_bank % NUM_BANKS) + 1
    redraw(); grid_redraw()
  end
end

-- ─── OSC — threshold hit from SC ──────────────────────────────────────────

osc.event = function(path, args, from)
  if path == "/ooze_thresh" and thresh_arm and rec_state == "idle" then
    thresh_arm = false
    engine.thresh_stop()
    start_recording()
    redraw(); grid_redraw()
  end
end

-- ─── init ─────────────────────────────────────────────────────────────────

function init()
  util.make_dir(norns.state.data)
  audio.level_adc(1)
  audio.level_monitor(0)

  params:add_separator("OOZE")
  params:add_number("transpose", "Transpose", -12, 12, 0)
  params:set_action("transpose", function(v) pitch_shift = v; redraw() end)
  params:add_number("scale_idx", "Scale", 1, #SCALES, 2)
  params:set_action("scale_idx", function(v) current_scale = v; redraw(); grid_redraw() end)

  -- restore saved banks
  for i = 1, NUM_BANKS do
    local path = norns.state.data .. "bank_" .. i .. ".wav"
    if util.file_exists(path) then
      engine.load(i - 1, path)
      banks[i].recorded  = true
      banks[i].from_disk = true
      banks[i].duration  = 0.0
    end
  end

  -- ghost echo decay — 20fps
  ghost_echo_clock_id = clock.run(function()
    while true do
      clock.sleep(1 / GHOST_FPS)
      local any = false
      for y = 1, 6 do
        for x = 1, 16 do
          if ghost_bri[y][x] > 0 then
            ghost_bri[y][x] = math.max(0, ghost_bri[y][x] - ghost_rate[y][x])
            any = true
          end
        end
      end
      if any then grid_redraw() end
    end
  end)

  -- blink clock for recording / loop indicators
  blink_clock_id = clock.run(function()
    while true do
      clock.sleep(0.28)
      blink_on = not blink_on
      -- only refresh screen/grid if something needs blinking
      local needs = rec_state == "recording" or rec_state == "processing"
      if not needs then
        for i = 1, NUM_BANKS do
          local ls = banks[i].loop_state
          if ls == "recording" or ls == "processing_loop" or ls == "overdubbing" then
            needs = true; break
          end
        end
      end
      if needs then redraw(); grid_redraw() end
    end
  end)

  redraw()
  grid_redraw()
end

function cleanup()
  -- Cancel all clock runs
  if rec_clock_id then clock.cancel(rec_clock_id) end
  if ghost_echo_clock_id then clock.cancel(ghost_echo_clock_id) end
  if blink_clock_id then clock.cancel(blink_clock_id) end
  -- SC engine frees all synths and buffers on unload
end

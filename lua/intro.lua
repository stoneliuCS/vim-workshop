--- Cold open for the deck:
---   1. Rain: columns of Vim command letters fall down the screen.
---   2. Paint: the rain stops everywhere except over the logo, and each drop
---      that passes a logo cell can lock it in, so the logo gets painted.
---   3. Title: the workshop name types itself out under the logo.
---   4. Reel: a small editor under the title loops through Vim tricks
---      (lua/tricks.lua), executed live in a real buffer, until you press `n`.
---   5. Outro: `ggdG` appears in the showcmd corner and the screen deletes
---      line by line like a real buffer, ending on "--No lines in buffer--".
--- `n` is the only key that moves things along, just like advancing a slide;
--- everything else is swallowed so a stray key can't edit the deck. <C-c>
--- bails out without starting the deck.
local M = {}

--- Shown under the logo. Edit freely; the layout re-centres on its own.
M.subtitle = {
  { text = "The Ultimate (Neo)VIM Workshop", hl = "IntroTitle" },
  { text = "with Stone Liu", hl = "IntroDim" },
}

--- Rain glyphs are real Normal-mode keys, so anyone who squints at a column
--- is reading Vim. ASCII only, so every rain cell is exactly one byte.
local POOL = "hjklwbeWBEdcyxpPuioaAIOGgv0$^%*#nN.;,ftFT:/?@m~<>="

--- The keys that "run" at the end: go to top, then delete to bottom.
local KEYS = { "g", "g", "d", "G" }

--- Timings in seconds.
local T = {
  rain = 2.4, -- pure rain before the logo starts locking in
  paint = 2.0, -- rain paints the logo; anything unlocked by the end snaps in
  char = 0.03, -- per typed subtitle character
  pause = 0.6, -- title finished, before the reel (or the outro) starts
  key = 0.2, -- per key of `ggdG` in the showcmd corner
  beat = 0.25, -- last key shown, then the delete runs
  delete = 0.55, -- every line gets deleted
  hold = 0.9, -- "--No lines in buffer--" sits for a moment
}

--- Reel pacing, in seconds.
local REEL = {
  token = 0.09, -- per key appearing in the footer
  step = 0.5, -- after a step runs, before the next one starts typing
  trick = 1.8, -- finished trick stays up so people can read the result
}

--- Size of the reel's editor window, borders not included.
local DEMO_W, DEMO_H = 44, 6

--- Odds that a drop's head locks a logo cell as it passes. Below 1 so the
--- logo fills in grain by grain instead of in solid column wipes.
local LOCK_CHANCE = 0.35

--- How long a freshly locked cell flashes white before settling to green.
local FLASH = 0.12

--- Same greens as vim_logo.lua, ordered from head of the drop to its tail.
local TRAIL = { "#43d17a", "#19c65e", "#2fa84f", "#45854a", "#3a5c3d", "#2e332e" }

local LEVEL_HL = { "IntroHead" }
for i = 1, #TRAIL do
  LEVEL_HL[i + 1] = "IntroTrail" .. i
end

--- Redefined on every play: a colorscheme change between runs clears user
--- groups, and stale names would render uncoloured.
local function define_highlights()
  local set = vim.api.nvim_set_hl
  set(0, "IntroHead", { fg = "#e8ffe8", bold = true })
  for i, color in ipairs(TRAIL) do
    set(0, "IntroTrail" .. i, { fg = color })
  end
  set(0, "IntroLogo", { fg = "#43d17a", bold = true })
  set(0, "IntroFlash", { fg = "#ffffff", bold = true })
  set(0, "IntroTitle", { fg = "#e6e6e6", bold = true })
  set(0, "IntroDim", { fg = "#6f806f" })
  set(0, "IntroKeys", { fg = "#43d17a", bold = true })
  -- The reel's window isn't focused, so Vim draws no cursor in it; this
  -- highlight stands in for one.
  set(0, "IntroCursor", { fg = "#1f1f28", bg = "#43d17a" })
  -- A fully blended cursor is the usual trick to hide it in the TUI.
  set(0, "IntroHiddenCursor", { blend = 100, nocombine = true })
end

local function chars(s)
  return vim.fn.split(s, "\\zs")
end

local function rand_glyph()
  local i = math.random(#POOL)
  return POOL:sub(i, i)
end

local function clamp(x, lo, hi)
  return math.max(lo, math.min(hi, x))
end

--- Split key notation into what a person would press: `<Esc>` is one key.
local function tokens(notation)
  local out, i = {}, 1
  while i <= #notation do
    local special = notation:match("^<[^<>]+>", i)
    local tok = special or notation:sub(i, i)
    out[#out + 1] = tok
    i = i + #tok
  end
  return out
end

--- Turn one row of cells into a line plus highlight runs. Adjacent cells with
--- the same group share one extmark, and columns are tracked in bytes because
--- the logo's box-drawing glyphs are three bytes each.
local function serialize(chs, hls, row0, marks)
  local parts, byte = {}, 0
  local run_hl, run_start = nil, 0
  for c = 1, #chs do
    local ch, hl = chs[c], hls[c]
    if hl ~= run_hl then
      if run_hl then
        marks[#marks + 1] = { row0, run_start, byte, run_hl }
      end
      run_hl, run_start = hl, byte
    end
    parts[c] = ch
    byte = byte + #ch
  end
  if run_hl then
    marks[#marks + 1] = { row0, run_start, byte, run_hl }
  end
  return table.concat(parts)
end

local ns = vim.api.nvim_create_namespace("workshop_intro")

--- The trick reel: a small real buffer in its own float, driven by the
--- intro's clock. Returns an object with `tick(now)` and `close()`.
local function new_reel(row, col, zindex)
  local tricks = require("tricks")
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = row,
    col = col,
    width = DEMO_W,
    height = DEMO_H,
    style = "minimal",
    border = "rounded",
    focusable = false,
    zindex = zindex,
    noautocmd = true,
  })
  vim.wo[win].winhighlight = "NormalFloat:Normal,FloatBorder:IntroDim,FloatTitle:IntroTitle,FloatFooter:IntroKeys"
  vim.wo[win].number = true

  -- Where the reel is: trick index, step index, how many of that step's keys
  -- are showing, and when the next thing happens.
  local s = { trick = 0, step = 0, shown = 0, toks = {}, next_at = 0 }

  local function paint_cursor()
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    local r, c = unpack(vim.api.nvim_win_get_cursor(win))
    local line = vim.api.nvim_buf_get_lines(buf, r - 1, r, false)[1] or ""
    if c < #line then
      vim.api.nvim_buf_set_extmark(buf, ns, r - 1, c, { end_col = c + 1, hl_group = "IntroCursor" })
    else
      vim.api.nvim_buf_set_extmark(buf, ns, r - 1, 0, { virt_text = { { " ", "IntroCursor" } }, virt_text_win_col = #line })
    end
  end

  local function set_chrome(label, keys)
    vim.api.nvim_win_set_config(win, {
      title = " " .. label .. " ",
      title_pos = "center",
      footer = keys ~= "" and (" " .. keys .. " ") or "",
      footer_pos = "center",
    })
  end

  local function load_trick(i)
    local t = tricks[i]
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, t.lines)
    vim.api.nvim_win_set_cursor(win, t.cursor)
    s.trick, s.step = i, 0
    set_chrome(t.label, "")
    paint_cursor()
  end

  --- Run one step for real. Recording a macro doesn't work inside :normal,
  --- so `qa...q` runs its body and then stores it in the register by hand;
  --- the `@a` steps after it replay that register like normal.
  local function run(notation)
    local keys = vim.keycode(notation)
    local reg, body = keys:match("^q(%l)(.*)q$")
    vim.api.nvim_win_call(win, function()
      -- silent: with cmdheight=0, messages like "3 fewer lines" would
      -- otherwise raise a hit-enter prompt mid-intro.
      vim.cmd.normal({ args = { body or keys }, bang = true, mods = { silent = true } })
    end)
    if reg then
      vim.fn.setreg(reg, body)
    end
  end

  local reel = {}

  function reel.tick(now)
    if now < s.next_at or not vim.api.nvim_win_is_valid(win) then
      return
    end
    local t = tricks[s.trick]
    if not t or (s.step >= #t.steps and s.shown >= #s.toks) then
      -- Trick over (or first tick): load the next one, wrapping forever.
      load_trick(s.trick % #tricks + 1)
      s.toks, s.shown = {}, 0
      s.next_at = now + REEL.step
      return
    end
    if s.shown < #s.toks then
      -- Reveal the next key of the current step.
      s.shown = s.shown + 1
      -- Spaces show as ␣ so they read as a keypress, and long steps (the
      -- macro) scroll so the newest keys stay visible in the footer.
      local shown = {}
      for j = 1, s.shown do
        shown[j] = s.toks[j] == " " and "␣" or s.toks[j]
      end
      local text = table.concat(shown, " ")
      while vim.fn.strdisplaywidth(text) > DEMO_W - 6 and #shown > 1 do
        table.remove(shown, 1)
        text = "… " .. table.concat(shown, " ")
      end
      set_chrome(t.label, text)
      if s.shown < #s.toks then
        s.next_at = now + REEL.token
        return
      end
      run(t.steps[s.step])
      paint_cursor()
      s.next_at = now + (s.step == #t.steps and REEL.trick or REEL.step)
      return
    end
    -- Start the next step of this trick.
    s.step = s.step + 1
    s.toks, s.shown = tokens(t.steps[s.step]), 0
    s.next_at = now
    reel.tick(now)
  end

  function reel.close()
    pcall(vim.api.nvim_win_close, win, true)
  end

  return reel
end

---@param opts? table `loop` (play the trick reel until `n`, default true), `fps`, and an `on_done` callback
function M.play(opts)
  opts = opts or {}
  local loop = opts.loop ~= false
  local interval = math.floor(1000 / (opts.fps or 30))
  define_highlights()

  local W, H = vim.o.columns, vim.o.lines
  local rows = H - 1 -- the last row is a fake command line

  local art = require("vim_logo").art
  local logo_w, logo_h = #chars(art[1]), #art

  -- The block is logo, blank, title, blank, subtitle, then (if it fits) a
  -- blank and the reel window with its border. Centred as one unit.
  local text_h = logo_h + 4
  local reel_h = DEMO_H + 2
  local with_reel = loop and rows >= text_h + 1 + reel_h + 2 and W >= DEMO_W + 4
  local block_h = with_reel and (text_h + 1 + reel_h) or text_h
  local top = math.max(1, math.floor((rows - block_h) / 2) + 1)
  local left = math.floor((W - logo_w) / 2)

  -- logo[r][c] = glyph for every non-space art cell; `pending[c]` counts the
  -- unlocked ones per column so the paint phase knows where to keep raining.
  local logo, pending, locked, remaining = {}, {}, {}, 0
  for i, line in ipairs(art) do
    for j, ch in ipairs(chars(line)) do
      if ch ~= " " then
        local r, c = top + i - 1, left + j
        logo[r] = logo[r] or {}
        logo[r][c] = ch
        pending[c] = (pending[c] or 0) + 1
        remaining = remaining + 1
      end
    end
  end

  local function lock(r, c, now)
    locked[r] = locked[r] or {}
    locked[r][c] = now
    pending[c] = pending[c] - 1
    if pending[c] == 0 then
      pending[c] = nil
    end
    remaining = remaining - 1
  end

  local function lock_all(now)
    for r, row in pairs(logo) do
      for c in pairs(row) do
        if not (locked[r] and locked[r][c]) then
          lock(r, c, now)
        end
      end
    end
  end

  -- Subtitle lines sit under the logo with a blank row between each.
  local lines_typed, total_chars = {}, 0
  for i, sub in ipairs(M.subtitle) do
    local cs = chars(sub.text)
    lines_typed[i] = {
      chars = cs,
      hl = sub.hl,
      row = top + logo_h + i * 2 - 1,
      col = math.floor((W - #cs) / 2),
    }
    total_chars = total_chars + #cs
  end

  -- The timeline, as absolute times from the start. The outro times stay
  -- unset in loop mode until `n` is pressed.
  local t_paint = T.rain
  local t_type = t_paint + T.paint
  local t_typed = t_type + total_chars * T.char
  local t_reel = t_typed + T.pause
  local t_keys, t_delete, t_end = math.huge, math.huge, math.huge
  local typed_all = false -- set when `n` cuts the typing short

  local function schedule_outro(at)
    t_keys = at
    t_delete = t_keys + #KEYS * T.key + T.beat
    t_end = t_delete + T.delete + T.hold
  end
  if not loop then
    schedule_outro(t_reel)
  end

  -- Every rain cell owns a glyph that occasionally flickers to a new one.
  local glyph = {}
  for r = 1, rows do
    glyph[r] = {}
    for c = 1, W do
      glyph[r][c] = rand_glyph()
    end
  end

  -- Staggered first spawns so the rain arrives from the top instead of
  -- appearing as one flat line.
  local drops, next_spawn = {}, {}
  for c = 1, W do
    next_spawn[c] = math.random() * 1.2
  end

  local function spawn(c, now)
    local d = { col = c, y = 0, speed = 25 + math.random() * 35, len = math.random(6, 16) }
    drops[#drops + 1] = d
    next_spawn[c] = now + d.len / d.speed + math.random() * 0.6
  end

  --- Advance the simulation by `dt` seconds.
  local function step(now, dt)
    for c = 1, W do
      -- During paint, only columns that still owe the logo a cell keep raining,
      -- so the rest of the screen drains away around it.
      if now >= next_spawn[c] and (now < t_paint or (now < t_type and pending[c])) and now < t_keys then
        spawn(c, now)
      end
    end

    for i = #drops, 1, -1 do
      local d = drops[i]
      local prev = d.y
      d.y = d.y + d.speed * dt
      if now >= t_paint and pending[d.col] then
        -- Fast drops cross several rows per frame; check every row the head
        -- entered, or they would tunnel straight past logo cells.
        for r = math.floor(prev) + 1, math.floor(d.y) do
          local hit = logo[r] and logo[r][d.col]
          if hit and not (locked[r] and locked[r][d.col]) and math.random() < LOCK_CHANCE then
            lock(r, d.col, now)
          end
        end
      end
      if d.y - d.len > rows then
        table.remove(drops, i)
      end
    end

    -- Whatever the rain missed snaps in together, a final flash before typing.
    if now >= t_type - 0.2 and remaining > 0 then
      lock_all(now)
    end

    for _ = 1, math.floor(rows * W * 0.03) do
      glyph[math.random(rows)][math.random(W)] = rand_glyph()
    end
  end

  --- Compose the current frame as per-cell characters and highlight groups.
  local function compose(now)
    local chs, hls = {}, {}
    for r = 1, rows do
      local cr = {}
      for c = 1, W do
        cr[c] = " "
      end
      chs[r], hls[r] = cr, {}
    end

    -- Rain: the head is level 1, the tail fades through the trail greens.
    -- Overlapping drops keep the brightest level.
    local level = {}
    for _, d in ipairs(drops) do
      local head = math.floor(d.y)
      for k = 0, d.len - 1 do
        local r = head - k
        if r >= 1 and r <= rows then
          local lv = k == 0 and 1 or 2 + math.floor((k - 1) * #TRAIL / (d.len - 1))
          level[r] = level[r] or {}
          local cur = level[r][d.col]
          if not cur or lv < cur then
            level[r][d.col] = lv
          end
        end
      end
    end
    for r, row in pairs(level) do
      for c, lv in pairs(row) do
        chs[r][c], hls[r][c] = glyph[r][c], LEVEL_HL[lv]
      end
    end

    for r, row in pairs(locked) do
      for c, t0 in pairs(row) do
        chs[r][c] = logo[r][c]
        hls[r][c] = now - t0 < FLASH and "IntroFlash" or "IntroLogo"
      end
    end

    -- Typed subtitle, plus a block cursor where the next character would go.
    if now >= t_type or typed_all then
      local budget = typed_all and total_chars or clamp(math.floor((now - t_type) / T.char), 0, total_chars)
      local cursor
      for _, line in ipairs(lines_typed) do
        local n = math.min(budget, #line.chars)
        for j = 1, n do
          if line.chars[j] ~= " " then
            chs[line.row][line.col + j], hls[line.row][line.col + j] = line.chars[j], line.hl
          end
        end
        budget = budget - n
        cursor = { line.row, line.col + n + 1 }
        if n < #line.chars then
          break
        end
      end
      -- Once the reel is running, the cursor lives in the reel instead.
      local typing = not typed_all and now < t_typed
      local blinking = not (with_reel and now >= t_reel) and math.floor(now * 2.5) % 2 == 0
      if now < t_delete and (typing or blinking) then
        chs[cursor[1]][cursor[2]], hls[cursor[1]][cursor[2]] = "█", "IntroTitle"
      end
    end

    -- The delete: in Vim, deleting from the top pulls every line below it up,
    -- so row r shows what used to be row r + k. Past the end of the buffer
    -- you get Vim's "~" filler, and line 1 always exists, empty.
    local k = 0
    if now >= t_delete then
      k = math.floor(clamp((now - t_delete) / T.delete, 0, 1) * rows)
    end
    local lines, marks = {}, {}
    for r = 1, rows do
      local src = r + k
      if src <= rows then
        lines[r] = serialize(chs[src], hls[src], r - 1, marks)
      elseif r == 1 then
        lines[r] = ""
      else
        lines[r] = "~"
        marks[#marks + 1] = { r - 1, 0, 1, "IntroDim" }
      end
    end

    -- Fake command line: showcmd keys on the right while they're "typed",
    -- then Vim's real message once the buffer is empty.
    local cmd = string.rep(" ", W)
    if k >= rows then
      local msg = "--No lines in buffer--"
      cmd = msg .. cmd:sub(#msg + 1)
      marks[#marks + 1] = { rows, 0, #msg, "IntroDim" }
    elseif now >= t_keys and now < t_delete then
      local shown = table.concat(KEYS, "", 1, clamp(math.floor((now - t_keys) / T.key) + 1, 1, #KEYS))
      local at = W - 11 -- roughly where Vim draws 'showcmd'
      cmd = cmd:sub(1, at) .. shown .. cmd:sub(at + #shown + 1)
      marks[#marks + 1] = { rows, at, at + #shown, "IntroTitle" }
    elseif with_reel and now >= t_reel and now < t_keys then
      local hint = "press n to begin"
      marks[#marks + 1] = { rows, 1, 1 + #hint, "IntroDim" }
      cmd = " " .. hint .. cmd:sub(#hint + 2)
    end
    lines[rows + 1] = cmd

    return lines, marks
  end

  -- One full-screen float above everything, including the command line.
  local saved = { guicursor = vim.o.guicursor, cmdheight = vim.o.cmdheight }
  vim.o.cmdheight = 0
  vim.o.guicursor = "a:IntroHiddenCursor"

  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = W,
    height = H,
    style = "minimal",
    focusable = false,
    zindex = 250,
    noautocmd = true,
  })
  vim.wo[win].winhighlight = "NormalFloat:Normal"
  vim.wo[win].wrap = false

  local reel -- opened once the title is typed

  local timer = vim.uv.new_timer()
  local start = vim.uv.hrtime()
  local last, done = 0, false

  --- Single exit path for finishing, bailing out, errors, or the window being
  --- closed. Options are restored *before* on_done, because present.nvim
  --- snapshots cmdheight and guicursor when it starts and restores them on exit.
  local function finish(start_deck)
    if done then
      return
    end
    done = true
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    vim.on_key(nil, ns)
    if reel then
      reel.close()
    end
    pcall(vim.api.nvim_win_close, win, true)
    vim.o.guicursor, vim.o.cmdheight = saved.guicursor, saved.cmdheight
    if start_deck and opts.on_done then
      opts.on_done()
    end
  end

  local function elapsed()
    return (vim.uv.hrtime() - start) / 1e9
  end

  --- `n`: the first press starts the outro from wherever the intro is; a
  --- second press during the outro jumps straight to the deck.
  local function advance()
    local now = elapsed()
    if t_keys ~= math.huge then
      return finish(true)
    end
    lock_all(now)
    typed_all = true
    schedule_outro(now)
  end

  vim.on_key(function(_, typed)
    -- Keys the reel feeds through :normal arrive untyped; let those through.
    if not typed or typed == "" then
      return
    end
    if typed == "\3" then
      vim.schedule(function()
        finish(false)
      end)
    elseif typed == "n" then
      vim.schedule(advance)
    end
    -- Returning "" discards the key, so nothing reaches the buffer underneath.
    return ""
  end, ns)

  timer:start(0, interval, vim.schedule_wrap(function()
    if done then
      return
    end
    if not vim.api.nvim_win_is_valid(win) then
      return finish(true)
    end
    -- Any error tears the intro down; otherwise the key swallowing above
    -- would outlive it and leave the editor unresponsive.
    local ok, err = pcall(function()
      local now = elapsed()
      -- Clamped so a stall (GC, a slow redraw) can't teleport the drops.
      local dt = math.min(now - last, 0.1)
      last = now
      if now >= t_end then
        return finish(true)
      end
      step(now, dt)

      if with_reel and now >= t_reel and now < t_delete then
        reel = reel or new_reel(top + text_h, math.floor((W - DEMO_W - 2) / 2), 260)
        reel.tick(now)
      elseif reel and now >= t_delete then
        reel.close()
      end

      local lines, marks = compose(now)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      for _, m in ipairs(marks) do
        vim.api.nvim_buf_set_extmark(buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
      end
    end)
    if not ok then
      finish(true)
      vim.notify("intro: " .. tostring(err), vim.log.levels.ERROR)
    end
  end))

  return win
end

return M

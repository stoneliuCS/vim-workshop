local M = {}

--- Split a string into a list of single characters, respecting UTF-8.
--- `vim.split(s, "")` would cut "█" into three broken bytes; `\zs` matches
--- the zero-width position between characters, so Vim splits per glyph.
local function chars(s)
  return vim.fn.split(s, "\\zs")
end

--- Stages a cell passes through while developing: sparse grain, then denser
--- block shading, then (past the last stage) the real character from the art.
local RAMP = { ".", ":", "░", "▒", "▓" }

--- Background cells run the ramp backwards, so the grain around the logo
--- thins out and disappears instead of solidifying.
local RAMP_OUT = { "▒", "░", ":", ".", " " }

--- One colour per ramp stage, plus a sixth for the resolved character.
--- Starts a hair above the background so early grain reads as texture, not text.
local GRADIENT = { "#2e332e", "#3a5c3d", "#45854a", "#2fa84f", "#19c65e", "#43d17a" }

--- Extmarks take a highlight *group name*, not a colour, so the gradient has
--- to exist as real groups. Redefined on every play: a colorscheme change
--- between runs clears user groups, and stale names would render uncoloured.
local function define_highlights()
  for i, color in ipairs(GRADIENT) do
    vim.api.nvim_set_hl(0, "VimLogoDev" .. i, { fg = color })
  end
end

--- The finished image the animation develops toward.
--- Every row is the same display width (25) so the grid stays rectangular.
M.art = {
  "██╗   ██╗ ██╗ ███╗   ███╗",
  "██║   ██║ ██║ ████╗ ████║",
  "██║   ██║ ██║ ██╔████╔██║",
  "╚██╗ ██╔╝ ██║ ██║╚██╔╝██║",
  " ╚████╔╝  ██║ ██║ ╚═╝ ██║",
  "  ╚═══╝   ╚═╝ ╚═╝     ╚═╝",
}

--- Fraction of the total runtime a single cell spends going grain -> resolved.
--- Smaller = crisper individual pops; larger = mushier, more overlapping.
local DEVELOP = 0.35

--- Explode the art into a grid of cells, each with its own random start time.
--- That per-cell `delay` is the entire effect: with a shared clock the image
--- would fade in uniformly, which looks like opacity, not development.
local function build_grid(art)
  local grid = {}
  for r, line in ipairs(art) do
    local row = {}
    for c, ch in ipairs(chars(line)) do
      -- Capped at 1 - DEVELOP so even the latest-starting cell is finished
      -- by the time the global clock reaches 1.
      row[c] = { ch = ch, delay = math.random() * (1 - DEVELOP) }
    end
    grid[r] = row
  end
  return grid
end

--- The character to draw for one cell at global time `t`, plus which gradient
--- step to colour it with. `t` runs 0 -> 1 across the whole animation.
local function cell_state(cell, t)
  local p = (t - cell.delay) / DEVELOP
  if p >= 1 then
    -- Developed: the real art character at the brightest colour.
    return cell.ch, #GRADIENT
  end
  -- Before its delay a cell sits at stage 1 rather than going negative.
  local stage = math.floor(math.max(p, 0) * #RAMP) + 1
  if cell.ch == " " then
    -- Background grain thins out at one fixed dim colour, so it reads as film
    -- grain burning off instead of a second image trying to appear.
    return RAMP_OUT[stage], 2
  end
  return RAMP[stage], stage
end

--- Build the buffer lines and the highlight ranges for one frame.
--- Returns marks as { row, start_byte, end_byte, gradient_level }.
local function render(grid, t)
  local lines, marks = {}, {}
  for r, row in ipairs(grid) do
    local parts, byte = {}, 0
    for c = 1, #row do
      local ch, level = cell_state(row[c], t)
      -- Extmark columns are *byte* offsets and "█" is three bytes, so the
      -- running byte count is tracked separately from the column index.
      marks[#marks + 1] = { r - 1, byte, byte + #ch, level }
      parts[c] = ch
      byte = byte + #ch
    end
    lines[r] = table.concat(parts)
  end
  return lines, marks
end

local ns = vim.api.nvim_create_namespace("vim_logo")

--- A borderless scratch float sized exactly to the art and centred on screen.
local function open_window(width, height)
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    -- Never take the cursor: the animation plays *over* whatever is open,
    -- and stealing focus would break present.nvim's buffer-local keymaps.
    focusable = false,
    -- present.nvim's own floats top out at zindex 3, so sit well above them.
    zindex = 200,
    noautocmd = true,
  })
  -- Drop the float's own background so only the glyphs read against the slide.
  vim.wo[win].winhighlight = "NormalFloat:Normal"
  return buf, win
end

--- Write one frame: replace the text, then repaint the gradient.
local function draw(buf, grid, t)
  local lines, marks = render(grid, t)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  -- Highlights must be cleared first; extmarks survive set_lines when the
  -- byte ranges still exist, so stale colours would stack up frame on frame.
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, m[1], m[2], {
      end_col = m[3],
      hl_group = "VimLogoDev" .. m[4],
    })
  end
end

--- Play the develop animation over whatever is currently on screen.
---@param opts? table `duration`/`hold` in ms, `fps`, and an `on_done` callback
function M.play(opts)
  opts = opts or {}
  local duration = opts.duration or 2200 -- grain -> fully resolved
  local hold = opts.hold or 1200 -- how long the finished logo lingers
  local interval = math.floor(1000 / (opts.fps or 30))

  define_highlights()
  local grid = build_grid(M.art)
  -- Width from the first row's glyph count, not #string: the art is
  -- multi-byte, so #M.art[1] would be ~3x too wide.
  local buf, win = open_window(#chars(M.art[1]), #M.art)

  local timer = vim.uv.new_timer()
  -- hrtime is monotonic nanoseconds; uv.now() is a cached loop timestamp and
  -- can sit still across ticks, which would stall the animation.
  local start = vim.uv.hrtime()

  -- Guarded because the loop can reach the end and the window can be closed
  -- out from under us; closing a libuv handle twice aborts Neovim.
  local function stop_timer()
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end

  -- schedule_wrap: the timer fires on the libuv thread, where nvim_* API
  -- calls are not allowed. This defers each tick onto the main loop.
  timer:start(0, interval, vim.schedule_wrap(function()
    if not vim.api.nvim_win_is_valid(win) then
      return stop_timer() -- someone closed it; abandon the run
    end
    local t = (vim.uv.hrtime() - start) / 1e6 / duration
    draw(buf, grid, math.min(t, 1))
    if t < 1 then
      return
    end
    stop_timer()
    vim.defer_fn(function()
      pcall(vim.api.nvim_win_close, win, true)
      if opts.on_done then
        opts.on_done()
      end
    end, hold)
  end))

  return win
end

return M

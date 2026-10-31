--- `:Practice <name>` opens exercises/<name>.txt in a float on top of the
--- deck, so drills and Vim Golf run live without leaving the presentation.
---
--- The float's footer shows the current mode and the last keys pressed, since
--- the audience can't see your hands and present.nvim hides the command line.
--- If exercises/<name>.target.txt exists, it's a golf round: the target is
--- shown above the editor, keys are counted, and the footer announces the
--- score the moment the text matches.
---
--- Edits happen on a scratch copy, so every run starts fresh. `:q` closes it
--- and drops you back on the same slide.
local M = {}

local ns = vim.api.nvim_create_namespace("workshop_practice")

--- Keys shown in the footer; older ones scroll off the left.
local SHOWN = 14

local function read(path)
  return vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or nil
end

---@param root string the workshop directory
---@param name string exercise name, without .txt
function M.open(root, name)
  local dir = root .. "/exercises/"
  local lines = read(dir .. name .. ".txt")
  if not lines then
    return vim.notify("No exercise named " .. name, vim.log.levels.ERROR)
  end
  local target = read(dir .. name .. ".target.txt")

  vim.api.nvim_set_hl(0, "PracticeKeys", { fg = "#43d17a", bold = true })
  vim.api.nvim_set_hl(0, "PracticeSolved", { fg = "#ffffff", bg = "#2fa84f", bold = true })

  local width = math.floor(vim.o.columns * 0.8)
  local height = math.floor(vim.o.lines * 0.8)
  local col = math.floor((vim.o.columns - width) / 2)
  local row = math.floor((vim.o.lines - height) / 2)
  -- present.nvim's floats top out at zindex 3; sit above them.
  local base = { relative = "editor", style = "minimal", border = "rounded", zindex = 50, noautocmd = true }

  local target_win
  if target then
    local tbuf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(tbuf, 0, -1, false, target)
    vim.bo[tbuf].modifiable = false
    local th = #target
    target_win = vim.api.nvim_open_win(tbuf, false, vim.tbl_extend("force", base, {
      width = width,
      height = th,
      row = row,
      col = col,
      focusable = false,
      title = " target ",
      title_pos = "center",
    }))
    -- The editor goes below the target, with room for both borders.
    row, height = row + th + 2, height - th - 2
  end

  local buf = vim.api.nvim_create_buf(false, true)
  -- Filled with undo off, so `u` can't undo the exercise itself into nothing.
  -- -123456 is Vim's sentinel for "use the global value" again.
  vim.bo[buf].undolevels = -1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].undolevels = -123456
  -- No completion popups covering the demo text.
  pcall(function()
    require("cmp").setup.buffer({ enabled = false })
  end)

  -- noautocmd matters: entering a new window normally fires BufLeave on the
  -- slide buffer, and present.nvim tears the whole deck down on BufLeave.
  local prev = vim.api.nvim_get_current_win()
  local win = vim.api.nvim_open_win(buf, true, vim.tbl_extend("force", base, {
    width = width,
    height = height,
    row = row,
    col = col,
    title = " " .. name .. " ",
    title_pos = "center",
  }))
  vim.wo[win].number = true
  vim.wo[win].relativenumber = true

  -- present.nvim hides the cursor for slides; a Vim demo needs it back.
  local saved_cursor = vim.o.guicursor
  vim.o.guicursor = vim.api.nvim_get_option_info2("guicursor", {}).default

  local keys, count, solved = {}, 0, false

  local function refresh()
    if not vim.api.nvim_win_is_valid(win) then
      return
    end
    local mode = vim.api.nvim_get_mode().mode
    local label = ({ i = "INSERT", v = "VISUAL", V = "V-LINE", ["\22"] = "V-BLOCK", R = "REPLACE" })[mode:sub(1, 1)]
      or "NORMAL"
    local footer = {
      { " " .. label .. " ", "PracticeSolved" },
      { "  " .. table.concat(keys, " ") .. " ", "PracticeKeys" },
    }
    if target then
      if solved then
        table.insert(footer, { " SOLVED in " .. count .. " keys ", "PracticeSolved" })
      else
        table.insert(footer, { " " .. count .. " keys ", "PracticeKeys" })
      end
    end
    vim.api.nvim_win_set_config(win, { footer = footer, footer_pos = "center" })
  end

  -- `typed` is what was physically pressed, before mappings expand it, which
  -- is the honest number for golf scoring.
  vim.on_key(function(_, typed)
    if not typed or typed == "" or vim.api.nvim_get_current_win() ~= win then
      return
    end
    if not solved then
      count = count + 1
    end
    table.insert(keys, vim.fn.keytrans(typed))
    if #keys > SHOWN then
      table.remove(keys, 1)
    end
    vim.schedule(refresh)
  end, ns)

  local group = vim.api.nvim_create_augroup("workshop_practice", { clear = true })
  vim.api.nvim_create_autocmd("ModeChanged", { group = group, callback = vim.schedule_wrap(refresh) })
  if target then
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = group,
      buffer = buf,
      callback = function()
        if not solved and vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), target) then
          solved = true
          refresh()
        end
      end,
    })
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    once = true,
    callback = function()
      vim.on_key(nil, ns)
      vim.api.nvim_del_augroup_by_id(group)
      vim.o.guicursor = saved_cursor
      vim.schedule(function()
        if target_win then
          pcall(vim.api.nvim_win_close, target_win, true)
        end
        if vim.api.nvim_win_is_valid(prev) then
          vim.api.nvim_set_current_win(prev)
        end
      end)
    end,
  })

  refresh()
end

--- Exercise names for :Practice completion, minus the golf target files.
function M.names(root)
  local names = {}
  for _, path in ipairs(vim.fn.glob(root .. "/exercises/*.txt", false, true)) do
    local name = vim.fn.fnamemodify(path, ":t:r")
    if not name:match("%.target$") then
      names[#names + 1] = name
    end
  end
  return names
end

return M

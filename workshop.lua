-- Entry point for the workshop.  Load it with:  :luafile workshop.lua
-- (exrc is off in this nvim config, so nothing here is picked up on its own.)

-- Resolve this file's own directory instead of relying on cwd, so the
-- commands work no matter where nvim was started from.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
vim.opt.runtimepath:prepend(root)

--- Drop the cached module so edits to lua/<name>.lua (art, colours, timing)
--- take effect on the next command without restarting nvim.
local function fresh(name)
  package.loaded[name] = nil
  return require(name)
end

-- present.nvim renders each slide into an *unnamed* scratch buffer, so
-- snacks.image has no file path to resolve `![](img/x.png)` against and falls
-- back to the cwd. Pin it to the deck's own directory instead, so images work
-- no matter where nvim was started. Returning nil = defer to snacks' default.
local ok_snacks, Snacks = pcall(require, "snacks")
if ok_snacks then
  Snacks.image.config.resolve = function(_, src)
    if src:find("^%w%w+://") or vim.startswith(src, "/") then
      return nil -- already a URL or absolute path; leave it alone
    end
    local path = root .. "/" .. src
    return vim.fn.filereadable(path) == 1 and path or nil
  end
end

vim.api.nvim_create_user_command("VimLogo", function()
  fresh("vim_logo").play()
end, { desc = "Play the Vim logo develop animation" })

vim.api.nvim_create_user_command("Intro", function()
  fresh("vim_logo") -- intro.lua borrows the logo art
  fresh("intro").play()
end, { desc = "Play the cold-open intro on its own" })

vim.api.nvim_create_user_command("Workshop", function()
  vim.cmd.edit(root .. "/presentation.md")
  -- Chain off on_done rather than sleeping: the deck opens the instant the
  -- intro ends, with no gap and no blocked UI.
  fresh("vim_logo")
  fresh("intro").play({ on_done = vim.cmd.PresentStart })
end, { desc = "Cold open: intro animation, then start the presentation" })

vim.api.nvim_create_user_command("Practice", function(cmd)
  fresh("practice").open(root, cmd.args)
end, {
  nargs = 1,
  complete = function()
    return require("practice").names(root)
  end,
  desc = "Open an exercise (or Vim Golf round) in a float over the deck",
})

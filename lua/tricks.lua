--- The demo reel the intro loops under the logo while people walk in.
---
--- Each trick runs in a real buffer: every step is handed to `:normal!`, so
--- what the audience sees is genuinely what those keys do, not an imitation.
--- A step is one complete command; its keys appear one at a time on screen,
--- then the whole step executes when the last key lands.
---
--- Fields: `label` (window title), `lines`, `cursor` as {row, col} (1-based
--- row, 0-based col), and `steps` in key notation (`<Esc>`, `<C-v>`, `<CR>`).
return {
  {
    label = 'ci"  change inside quotes',
    lines = { 'local editor = "vscode"', "", "print(editor)" },
    cursor = { 1, 0 },
    steps = { 'ci"neovim<Esc>' },
  },
  {
    label = "xp  swap two letters",
    lines = { "vim is teh best editor" },
    cursor = { 1, 8 },
    steps = { "xp" },
  },
  {
    label = "*  ciw  n  .  rename, one at a time",
    lines = { "local old = 1", "print(old + old)", "return old" },
    cursor = { 1, 6 },
    steps = { "*N", "ciwnew<Esc>", "n", ".", "n", ".", "n", "." },
  },
  {
    label = "<C-v>  block insert on every line",
    lines = { "spindrift", "laptop", "curiosity" },
    cursor = { 1, 0 },
    steps = { "<C-v>2jI- [ ] <Esc>" },
  },
  {
    label = "g<C-a>  count up a selection",
    lines = { "step 0", "step 0", "step 0", "step 0", "step 0" },
    cursor = { 1, 0 },
    steps = { "VGg<C-a>" },
  },
  {
    label = ":g  delete every match",
    lines = { "TODO learn hjkl", "DONE open vim", "TODO learn ciw", "DONE quit vim", "TODO teach a friend" },
    cursor = { 1, 0 },
    steps = { ":g/^DONE/d<CR>" },
  },
  {
    label = "gUiw  shout a word",
    lines = { "vim is quietly the best" },
    cursor = { 1, 7 },
    steps = { "gUiw", "w", "." },
  },
  {
    label = "qa ... q  record a macro, @a replay",
    lines = { "ada,1815", "alan,1912", "grace,1906", "linus,1969" },
    cursor = { 1, 0 },
    steps = { 'qa0~I{ "<Esc>f,s": <Esc>A },<Esc>jq', "@a", "@@", "@@" },
  },
  {
    label = ":sort  alphabetize lines",
    lines = { "vim", "emacs", "helix", "nano", "kakoune" },
    cursor = { 1, 0 },
    steps = { ":sort<CR>" },
  },
  {
    label = "ddp  swap two lines",
    lines = { "second", "first", "third" },
    cursor = { 1, 0 },
    steps = { "ddp" },
  },
}

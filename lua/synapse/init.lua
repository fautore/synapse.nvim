local M = {}

local uv = vim.uv or vim.loop
local source = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))

local defaults = {
  executable = plugin_root .. "/target/synapse",
  odin = "odin",
  glslc = "glslc",
  make = "make",
  hide_title_bar = false,
  font = nil, -- font file or Fontconfig family; nil detects the terminal
  font_size = nil,
  root_markers = { ".obsidian", ".git", ".jj" },
  highlight_groups = {
    background = "Normal",
    foreground = "Normal",
    node = "Function",
    edge = "Comment",
    muted = "NonText",
    current = "DiagnosticWarn",
    ghost = "LineNr",
  },
}

local config = vim.deepcopy(defaults)
local state = {
  process = nil,
  building = false,
  theme_file = vim.fn.stdpath("cache") .. "/synapse-theme-" .. vim.fn.getpid(),
  font_path = nil,
  font_size = nil,
}

local function notify(message, level)
  vim.schedule(function()
    vim.notify(message, level or vim.log.levels.INFO, { title = "synapse.nvim" })
  end)
end

local function exists(path)
  return uv.fs_stat(path) ~= nil
end

local function vault_for_buffer(bufnr)
  local file = vim.api.nvim_buf_get_name(bufnr or 0)
  local start = file ~= "" and file or vim.fn.getcwd()
  local root
  if type(config.root) == "function" then
    root = config.root(start)
  elseif type(config.root) == "string" then
    root = config.root
  end
  root = root or vim.fs.root(start, config.root_markers)
  if not root then
    root = file ~= "" and vim.fs.dirname(file) or vim.fn.getcwd()
  end

  local current = ""
  if file ~= "" and file:sub(1, #root) == root then
    current = file:sub(#root + 1):gsub("^[/\\]", "")
  end
  return vim.fs.normalize(root), current
end

local function highlight_color(group, attribute, fallback)
  local ok, highlight = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
  if ok and highlight[attribute] then
    return highlight[attribute]
  end
  return fallback
end

local function write_theme_file()
  local normal_fg = highlight_color("Normal", "fg", 0xcdd6f4)
  local colors = {
    highlight_color(config.highlight_groups.background, "bg", 0x11111b),
    highlight_color(config.highlight_groups.foreground, "fg", normal_fg),
    highlight_color(config.highlight_groups.node, "fg", normal_fg),
    highlight_color(config.highlight_groups.edge, "fg", normal_fg),
    highlight_color(config.highlight_groups.muted, "fg", normal_fg),
    highlight_color(config.highlight_groups.current, "fg", 0xf9e2af),
    highlight_color(config.highlight_groups.ghost, "fg", 0x585b70),
  }
  local temporary = state.theme_file .. ".tmp"
  local file = assert(io.open(temporary, "w"))
  for _, color in ipairs(colors) do
    file:write(string.format("%06x\n", color))
  end
  file:close()
  assert(os.rename(temporary, state.theme_file))
end

local function read_font_setting(path, family_pattern, size_pattern)
  if vim.fn.filereadable(path) ~= 1 then
    return nil, nil
  end
  local family, size
  for _, line in ipairs(vim.fn.readfile(path)) do
    line = line:gsub("%s*#.*$", "")
    family = line:match(family_pattern) or family
    size = tonumber(line:match(size_pattern)) or size
  end
  return family, size
end

local function terminal_font()
  if state.font_path then
    return state.font_path, state.font_size
  end

  local family, size
  if vim.env.KITTY_WINDOW_ID or vim.env.TERM == "xterm-kitty" then
    family, size = read_font_setting(
      vim.fn.expand("~/.config/kitty/kitty.conf"),
      "^%s*font_family%s+(.+)%s*$",
      "^%s*font_size%s+([%d%.]+)"
    )
  elseif vim.env.TERM_PROGRAM == "ghostty" or vim.env.GHOSTTY_RESOURCES_DIR then
    family, size = read_font_setting(
      vim.fn.expand("~/.config/ghostty/config"),
      '^%s*font%-family%s*=%s*"?([^"%s]+.-)"?%s*$',
      "^%s*font%-size%s*=%s*([%d%.]+)"
    )
  end

  local requested = config.font or family or "monospace"
  size = config.font_size or size or 10
  if uv.fs_stat(vim.fn.expand(requested)) then
    state.font_path = vim.fn.expand(requested)
  elseif vim.fn.executable("fc-match") == 1 then
    local result = vim.system({ "fc-match", "-f", "%{file}", requested }, { text = true }):wait()
    state.font_path = result.code == 0 and vim.trim(result.stdout or "") or nil
  end
  state.font_size = size
  return state.font_path, state.font_size
end

local function launch(root, current)
  if state.process then
    notify("A Synapse window is already running (use :Synapse! to restart)", vim.log.levels.WARN)
    return
  end

  write_theme_file()
  local font_path, font_size = terminal_font()
  local args = { config.executable, "--root", root, "--theme-file", state.theme_file }
  if config.hide_title_bar then
    table.insert(args, "--hide-title-bar")
  end
  if font_path then
    vim.list_extend(args, { "--font", font_path, "--font-size", tostring(font_size) })
  end
  if current ~= "" then
    vim.list_extend(args, { "--current", current })
  end

  local process
  process = vim.system(args, { cwd = root, text = true, detach = true }, function(result)
    if state.process == process then
      state.process = nil
    end
    if result.code ~= 0 and result.code ~= 143 and result.signal ~= 15 then
      local detail = (result.stderr or ""):gsub("%s+$", "")
      notify("Renderer exited with code " .. result.code .. (detail ~= "" and (": " .. detail) or ""), vim.log.levels.ERROR)
    end
  end)
  state.process = process
  notify("Opened graph for " .. root)
end

local function run_steps(steps, done)
  local index = 1
  local function next_step()
    local step = steps[index]
    if not step then
      done(true)
      return
    end
    vim.system(step, { cwd = plugin_root, text = true }, function(result)
      if result.code ~= 0 then
        local detail = (result.stderr or result.stdout or ""):gsub("%s+$", "")
        notify("Build failed: " .. detail, vim.log.levels.ERROR)
        done(false)
        return
      end
      index = index + 1
      next_step()
    end)
  end
  next_step()
end

local function build(callback)
  if state.building then
    notify("A build is already in progress", vim.log.levels.WARN)
    return
  end
  if vim.fn.executable(config.odin) ~= 1 then
    notify("Odin was not found. Set require('synapse').setup { odin = '/path/to/odin' }", vim.log.levels.ERROR)
    return
  end
  if vim.fn.executable(config.glslc) ~= 1 then
    notify("glslc was not found (install the Vulkan SDK)", vim.log.levels.ERROR)
    return
  end
  if vim.fn.executable(config.make) ~= 1 then
    notify("make was not found", vim.log.levels.ERROR)
    return
  end

  state.building = true
  vim.fn.mkdir(vim.fs.dirname(config.executable), "p")
  notify("Building the Odin/Vulkan renderer…")
  run_steps({
    {
      config.make,
      "ODIN=" .. config.odin,
      "GLSLC=" .. config.glslc,
      "OUT=" .. config.executable,
      "all",
    },
  }, function(ok)
    state.building = false
    if ok then
      notify("Renderer built")
      if callback then vim.schedule(callback) end
    end
  end)
end

function M.open(opts)
  opts = opts or {}
  if opts.restart then
    M.close()
  end
  local root, current = vault_for_buffer()
  local start = function() launch(root, current) end
  if not exists(config.executable) then
    notify("Renderer is missing; reinstall the plugin or run :SynapseBuild", vim.log.levels.ERROR)
    return
  end
  start()
end

function M.close()
  if state.process then
    state.process:kill(15)
    state.process = nil
  end
end

function M.update_theme()
  if state.process then
    write_theme_file()
  end
end

function M.build()
  build(nil)
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  state.font_path = nil
  state.font_size = nil
end

M._state = state
return M

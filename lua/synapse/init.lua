local M = {}

local uv = vim.uv or vim.loop
local source = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))

local defaults = {
  executable = plugin_root .. "/target/synapse",
  odin = "odin",
  glslc = "glslc",
  auto_build = true,
  root_markers = { ".obsidian", ".git", ".jj" },
}

local config = vim.deepcopy(defaults)
local state = { process = nil, building = false }

local function notify(message, level)
  vim.schedule(function()
    vim.notify(message, level or vim.log.levels.INFO, { title = "synapse.nvim" })
  end)
end

local function exists(path)
  return uv.fs_stat(path) ~= nil
end

local function newer_than(path, timestamp)
  local stat = uv.fs_stat(path)
  return stat and stat.mtime.sec > timestamp
end

local function needs_build()
  local binary = uv.fs_stat(config.executable)
  if not binary then
    return true
  end
  local source_time = binary.mtime.sec
  for name, kind in vim.fs.dir(plugin_root .. "/app") do
    if kind == "file" and (name:match("%.odin$") or name:match("%.vert$") or name:match("%.frag$")) then
      if newer_than(plugin_root .. "/app/" .. name, source_time) then
        return true
      end
    end
  end
  return false
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

local function launch(root, current)
  if state.process then
    notify("A Synapse window is already running (use :Synapse! to restart)", vim.log.levels.WARN)
    return
  end

  local args = { config.executable, "--root", root }
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

  state.building = true
  vim.fn.mkdir(vim.fs.dirname(config.executable), "p")
  notify("Building the Odin/Vulkan renderer…")
  run_steps({
    { config.glslc, "app/graph.vert", "-o", "app/vert.spv" },
    { config.glslc, "app/graph.frag", "-o", "app/frag.spv" },
    { config.odin, "build", "app", "-out:" .. config.executable, "-o:speed" },
  }, function(ok)
    state.building = false
    if ok then
      notify("Renderer built")
      if callback then callback() end
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
  if not exists(config.executable) or (config.auto_build and needs_build()) then
    if not config.auto_build then
      notify("Renderer is missing; run :SynapseBuild", vim.log.levels.ERROR)
      return
    end
    build(start)
  else
    start()
  end
end

function M.close()
  if state.process then
    state.process:kill(15)
    state.process = nil
  end
end

function M.build()
  build(nil)
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

M._state = state
return M

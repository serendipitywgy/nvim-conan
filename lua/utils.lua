local M = {}

function M.file_exists(path)
  return vim.loop.fs_stat(path) ~= nil
end

local function conan_config_abspath()
  local cwd = vim.fn.getcwd()
  return cwd .. "/.nvim-conan.json"
end

function M.write_json_file(path, tbl)
  local file = io.open(path, "w")
  if not file then
    vim.notify("❌ Failed to open " .. path .. " for writing", vim.log.levels.ERROR)
    return false
  end

  file:write(M.encode_json(tbl, 0))
  file:close()
  return true
end

function M.encode_json(tbl, indent)
  indent = indent or 0
  local indent_str = string.rep("  ", indent + 1)
  local lines = { "{" }
  local i, n = 0, 0
  for _ in pairs(tbl) do n = n + 1 end

  for k, v in pairs(tbl) do
    i = i + 1
    local key = string.format('"%s"', tostring(k))
    local val
    if type(v) == "string" then
      val = string.format("%q", v)
    elseif type(v) == "number" or type(v) == "boolean" then
      val = tostring(v)
    elseif type(v) == "table" and (k == "options" or k == "conf") then
      local opts_lines = { "{" }
      local oi, on = 0, 0
      for _ in pairs(v) do on = on + 1 end
      for ok, ov in pairs(v) do
        oi = oi + 1
        local opt_key = string.format('"%s"', tostring(ok))
        local opt_val = type(ov) == "number" or type(ov) == "boolean" and tostring(ov) or
            string.format("%q", tostring(ov))
        local opt_comma = (oi < on) and "," or ""
        table.insert(opts_lines, string.format('%s  %s: %s%s', indent_str, opt_key, opt_val, opt_comma))
      end
      table.insert(opts_lines, indent_str .. "}")
      val = table.concat(opts_lines, "\n")
    elseif type(v) == "table" then
      val = vim.fn.json_encode(v)
    end

    local comma = (i < n) and "," or ""
    table.insert(lines, string.format('%s%s: %s%s', indent_str, key, val, comma))
  end

  table.insert(lines, string.rep("  ", indent) .. "}")
  return table.concat(lines, "\n")
end

function M.ensure_config(path, default_table)
  if M.file_exists(path) then
    vim.notify("🟢 Config exists at " .. path, vim.log.levels.DEBUG)
    return
  end

  if M.write_json_file(path, default_table) then
    vim.notify("✅ Created config: " .. path, vim.log.levels.INFO)
  end
end

function M.get_major_version(version)
  if type(version) ~= "string" then return 0 end
  return tonumber(version:match("^(%d+)")) or 0
end

function M.check_version_compat(config_version, plugin_version)
  if not config_version then return end
  local config_major = M.get_major_version(config_version)
  local plugin_major = M.get_major_version(plugin_version)

  if config_major ~= plugin_major then
    vim.notify(string.format(
      "⚠️ Config version (%s) might not be compatible with plugin version (%s).\nPlease review your config file.",
      config_version, plugin_version
    ), vim.log.levels.INFO)
  end
end

-- 全局标记当前 conan terminal buffer，避免重复打开
local _term_buf = nil

function M.get_term_buf()
  return _term_buf
end

function M.open_floating_terminal(cmd, title, close_term, opts)
  assert(type(cmd) == "string", "cmd must be a string")

  if close_term == nil then
    close_term = true
  end
  opts = opts or {}

  -- 若已有 conan terminal buffer 存在，先关闭对应窗口
  if _term_buf and vim.api.nvim_buf_is_valid(_term_buf) then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == _term_buf then
        vim.api.nvim_win_close(win, true)
        break
      end
    end
  end
  _term_buf = nil

  -- 记录触发 build 的原始窗口，build 结束后焦点回来
  local origin_win = vim.api.nvim_get_current_win()

  local buf = vim.api.nvim_create_buf(false, true)
  _term_buf = buf

  -- 设置 buffer 名称（带序号避免重复）
  local buf_name = "ConanBuild[" .. buf .. "]"
  pcall(vim.api.nvim_buf_set_name, buf, buf_name)

  -- 底部横跨全宽 split
  local height = math.max(12, math.min(20, math.floor(vim.o.lines * 0.25)))
  vim.cmd("botright split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_height(win, height)

  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "terminal"
  vim.bo[buf].buftype = "nofile"

  -- 防止进入 insert 模式
  vim.api.nvim_create_autocmd({ "TermEnter", "InsertEnter" }, {
    buffer = buf,
    callback = function() vim.cmd("stopinsert") end,
  })

  -- 自动滚动：用户手动滚动后暂停，exit 时恢复滚到底
  local user_scrolled = false
  vim.api.nvim_create_autocmd("WinScrolled", {
    buffer = buf,
    callback = function()
      if vim.api.nvim_win_is_valid(win) then
        local cur = vim.api.nvim_win_get_cursor(win)[1]
        local last = vim.api.nvim_buf_line_count(buf)
        if cur < last - 2 then
          user_scrolled = true
        end
      end
    end,
  })

  local function scroll_to_bottom()
    if user_scrolled then return end
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(buf) then
      local line_count = vim.api.nvim_buf_line_count(buf)
      vim.api.nvim_win_set_cursor(win, { line_count, 0 })
    end
  end

  local function populate_quickfix(exit_code)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local raw_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    -- 去除 ANSI 转义码，保证 errorformat 正确匹配
    local lines = {}
    for _, line in ipairs(raw_lines) do
      local clean = (line:gsub("\27%[[%d;]*m", ""):gsub("\27%[[%d;]*[A-Za-z]", ""))
      table.insert(lines, clean)
    end

    local saved_efm = vim.o.errorformat
    vim.o.errorformat = table.concat({
      "%f:%l:%c: %trror: %m",
      "%f:%l:%c: %tarning: %m",
      "%f:%l:%c: %tnfo: %m",
      "%f:%l:%c: note: %m",
      "%f:%l: %trror: %m",
      "%f:%l: %tarning: %m",
      "%-G%.%#",
    }, ",")

    vim.fn.setqflist({}, " ", { title = title or cmd, lines = lines })
    vim.o.errorformat = saved_efm

    -- 只在构建失败时打开 quickfix，且有实际错误条目
    if exit_code ~= 0 then
      local qf = vim.fn.getqflist()
      local has_errors = false
      for _, item in ipairs(qf) do
        if item.valid == 1 then has_errors = true; break end
      end
      if has_errors then
        -- 先关闭终端窗口（保留 buffer 供 <leader>bl 呼出），再打开 quickfix，最后在主窗口跳转
        if vim.api.nvim_win_is_valid(win) then
          vim.bo[buf].bufhidden = "hide"  -- 改为 hide，关窗口时不销毁 buffer
          vim.api.nvim_win_close(win, false)
        end
        vim.cmd("botright copen 10")
        -- 回到主编辑窗口执行 cfirst，避免在 quickfix 窗口中触发新 split
        vim.cmd("wincmd p")
        vim.cmd("cfirst")
      end
    end
  end

  local _ = vim.fn.termopen(cmd, {
    env = { COLUMNS = tostring(vim.o.columns) },
    on_exit = function(_, code, _)
      vim.schedule(function()
        populate_quickfix(code)

        if type(opts.on_exit) == "function" then
          pcall(opts.on_exit, code, { win = win, buf = buf, cmd = cmd, title = title })
        end

        -- 追加结果提示行，绑定 q 手动关闭（仅构建成功时终端仍可见）
        if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_is_valid(win) then
          vim.bo[buf].modifiable = true
          local msg = code == 0
            and "  [Build succeeded — press q to close]"
            or  "  [Build failed — press q to close]"
          vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", msg })
          vim.bo[buf].modifiable = false
          user_scrolled = false
          scroll_to_bottom()
        end

        vim.keymap.set("n", "q", function()
          if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
          end
        end, { buffer = buf, nowait = true, desc = "关闭 Conan 构建终端" })
      end)
    end,
    on_stdout = function() vim.schedule(scroll_to_bottom) end,
    on_stderr = function() vim.schedule(scroll_to_bottom) end,
  })

  vim.bo[buf].modifiable = false

  -- termopen 完成后归还焦点（termopen 必须在目标窗口激活时调用）
  if vim.api.nvim_win_is_valid(origin_win) then
    vim.api.nvim_set_current_win(origin_win)
  end
end

function M.get_conan_remotes_from_cli()
  local output = vim.fn.systemlist("conan remote list")
  if vim.v.shell_error ~= 0 then
    return {}
  end

  local remotes = {}
  for _, line in ipairs(output) do
    local name = line:match("^(.-):%s")
    if name then
      table.insert(remotes, name)
    end
  end
  return remotes
end

function M.get_cached_package_refs()
  local output_lines = vim.fn.systemlist("conan list --format=json")
  if vim.v.shell_error ~= 0 then
    vim.notify("Failed to run `conan list`", vim.log.levels.ERROR)
    return {}
  end

  local json_start = nil
  for i, line in ipairs(output_lines) do
    if line:match("^%s*{") then
      json_start = i
      break
    end
  end

  if not json_start then
    vim.notify("Could not locate JSON in Conan list output", vim.log.levels.ERROR)
    return {}
  end

  local json = table.concat(vim.list_slice(output_lines, json_start), "\n")
  local ok, parsed = pcall(vim.fn.json_decode, json)
  if not ok or type(parsed) ~= "table" then
    vim.notify("Failed to parse Conan list JSON block", vim.log.levels.ERROR)
    return {}
  end

  local refs = {}
  local cache = parsed["Local Cache"]
  if not cache then
    vim.notify("No 'Local Cache' section found in parsed output", vim.log.levels.WARN)
    return {}
  end

  for ref, _ in pairs(cache) do
    table.insert(refs, ref)
  end

  table.sort(refs)
  return refs
end

function M.get_conan_profiles()
  local lines = vim.fn.systemlist("conan profile list")
  if vim.v.shell_error ~= 0 then
    vim.notify("Failed to run `conan profile list`", vim.log.levels.ERROR)
    return {}
  end

  local profiles = {}
  for _, line in ipairs(lines) do
    if not line:match("Profiles found") and line:match("%S") then
      table.insert(profiles, vim.trim(line))
    end
  end

  return profiles
end

function M.pick_conan_profile(prompt, callback)
  local profiles = M.get_conan_profiles()
  if #profiles == 0 then
    vim.notify("No Conan profiles found", vim.log.levels.WARN)
    return
  end

  local items = {}
  for _, p in ipairs(profiles) do
    items[#items + 1] = { text = p }
  end

  Snacks.picker.pick({
    title = prompt,
    items = items,
    format = function(item) return { { item.text } } end,
    confirm = function(picker, item)
      picker:close()
      if item then callback(item.text) end
    end,
  })
end

function M.pick_build_policy(callback)
  local options = { "missing", "never", "always" }
  local items = {}
  for _, o in ipairs(options) do
    items[#items + 1] = { text = o }
  end

  Snacks.picker.pick({
    title = "Select Build Policy",
    items = items,
    format = function(item) return { { item.text } } end,
    confirm = function(picker, item)
      picker:close()
      if item then callback(item.text) end
    end,
  })
end

function M.pick_recipe(prompt, callback)
  local recipes = vim.fn.glob(vim.fn.getcwd() .. "/conanfile*.py", false, true)
  local items = {}
  for _, r in ipairs(recipes) do
    items[#items + 1] = { text = r }
  end

  Snacks.picker.pick({
    title = prompt,
    items = items,
    format = function(item) return { { item.text } } end,
    confirm = function(picker, item)
      picker:close()
      if item then callback(item.text) end
    end,
  })
end

function M.find_latest_compile_commands()
  local cwd = vim.fn.getcwd()
  local files = vim.fn.glob(cwd .. "/**/compile_commands.json", true, true)
  if type(files) ~= "table" or #files == 0 then
    return nil
  end

  local newest, newest_mtime = nil, -1
  for _, p in ipairs(files) do
    local st = vim.loop.fs_stat(p)
    if st and st.mtime and st.mtime.sec and st.mtime.sec > newest_mtime then
      newest = p
      newest_mtime = st.mtime.sec
    end
  end
  return newest
end

function M.link_compile_commands(path)
  if type(path) ~= "string" or path == "" then return end

  local cwd = vim.fn.getcwd()
  local target = cwd .. "/compile_commands.json"

  vim.system({ "ln", "-sf", path, target }, { text = true }, function(res)
    vim.schedule(function()
      if res.code == 0 then
        vim.notify("🔗 Linked compile_commands.json", vim.log.levels.INFO)
      else
        vim.notify(res.stderr or "Failed to link compile_commands.json", vim.log.levels.WARN)
      end
    end)
  end)
end

local function prompt_for(what, callback)
  local options = {}
  local function prompt()
    vim.ui.input({
        prompt = "Enter " .. what .. " (key=value), enter with blank field to finish: " },
      function(input)
        if input and input ~= "" then
          local k, v = input:match("^%s*(.-)%s*=%s*(.-)%s*$")
          if k and v and k ~= "" and v ~= "" then
            options[k] = v
          else
            vim.notify("Invalid input. Use key=value format.", vim.log.levels.WARN)
          end
          prompt()
        else
          callback(options)
        end
      end)
  end
  prompt()
end

function M.reconfigure()
  local version = require("version")
  local config_path = conan_config_abspath()

  if M.file_exists(config_path) then
    vim.loop.fs_unlink(config_path)
    vim.notify("✅ Removed old config", vim.log.levels.INFO)
  end

  M.pick_recipe("Select Conan Recipe", function(recipe)
    M.pick_conan_profile("Select Host Profile", function(host_profile)
      M.pick_conan_profile("Select Build Profile", function(build_profile)
        M.pick_build_policy(function(build_policy)
          prompt_for("options", function(options)
            prompt_for("conf", function(conf)
              M.ensure_config(config_path, {
                recipe = recipe,
                version = version,
                profile_build = build_profile,
                profile_host = host_profile,
                build_policy = build_policy,
                options = options or {},
                conf = conf or {},
              })

              vim.notify(string.format(
                "🎯 Configured with host: %s, build: %s, policy: %s",
                host_profile, build_profile, build_policy
              ), vim.log.levels.INFO)

              local ok, config = pcall(function()
                local file = io.open(config_path, "r")
                if not file then return nil end
                local content = file:read("*a")
                file:close()
                return vim.json.decode(content)
              end)

              if ok and config then
                M.check_version_compat(config.version, version)
              else
                vim.notify("⚠️ Failed to read config after reconfigure", vim.log.levels.WARN)
              end
            end)
          end)
        end)
      end)
    end)
  end)
end

return M

# nvim-conan

Neovim 的 Conan C/C++ 包管理器集成插件，纯 Lua 实现。

本项目 fork 自 [mm4cN/nvim-conan](https://github.com/mm4cN/nvim-conan)，将 Telescope 依赖替换为 [snacks.nvim](https://github.com/folke/snacks.nvim) picker。

---

## 功能

**`:Conan <子命令>`** — 所有操作通过统一命令入口执行，支持 Tab 补全。

| 子命令 | 等价 shell 命令 | 说明 |
|---|---|---|
| `install` | `conan install` | 安装依赖，生成 CMake 集成文件 |
| `build` | `conan build` | 完整构建项目 |
| `create` | `conan create` | 将项目打包为 conan 包 |
| `export` | `conan export` | 导出 recipe 到本地缓存 |
| `export_package` | `conan export-pkg` | 导出预编译包 |
| `lock` | `conan lock create` | 生成或更新 lockfile |
| `search` | `conan search` | 搜索 conan 包，带 remote 分布预览 |
| `upload` | `conan upload` | 上传包到 remote |
| `reconfigure` | — | 重新生成项目配置文件 |

**首次打开 conan 项目**时，插件自动引导完成配置（选择 profile、build policy 等），结果写入项目根目录的 `.nvim-conan.json`。

**构建时状态栏显示 spinner**，构建成功后自动软链接 `compile_commands.json` 到项目根目录。

---

## 依赖

- Neovim 0.10+
- Conan 2.x（全局安装，或通过 pip 安装）
- [snacks.nvim](https://github.com/folke/snacks.nvim)

---

## 安装

以 [vim.pack](https://neovim.io/doc/user/pi_pack.html)（Neovim 0.12 原生包管理）为例：

```lua
-- pack/plugins.lua
{ src = "https://github.com/serendipitywgy/nvim-conan" }
```

```lua
-- plugins/conan.lua
vim.api.nvim_create_autocmd("VimEnter", {
    once = true,
    callback = function()
        vim.cmd.packadd("nvim-conan")
        local ok, conan = pcall(require, "conan")
        if ok then conan.setup() end
    end,
})
```

其他包管理器（lazy.nvim 等）：

```lua
{
    "serendipitywgy/nvim-conan",
    dependencies = { "folke/snacks.nvim" },
    config = function()
        require("conan").setup()
    end,
}
```

---

## 项目配置文件

每个 conan 项目根目录下需要一个 `.nvim-conan.json`，所有 `:Conan` 命令从这里读取参数。

**首次打开项目时插件会自动引导创建**，也可以手动建立：

```json
{
  "recipe": ".",
  "profile_build": "default",
  "profile_host": "default",
  "build_policy": "missing",
  "options": {},
  "conf": {}
}
```

| 字段 | 说明 |
|---|---|
| `recipe` | conanfile 路径，通常为 `"."` |
| `profile_host` | 目标平台 profile（`-pr:h`），描述运行环境 |
| `profile_build` | 编译机器 profile（`-pr:b`），本机编译时与 host 相同 |
| `build_policy` | `missing` / `never` / `always`，控制哪些包需要从源码编译 |
| `options` | 传给 conanfile options 字段的参数，如 `{"with_asan": "True"}` |
| `conf` | conan 配置项，如 `{"tools.build:jobs": "8"}` |

建议将 `.nvim-conan.json` 加入项目的 `.gitignore`，该文件是开发者本地配置。

需要切换 profile（如 debug/release）时，修改此文件后执行 `:Conan build` 即可，或运行 `:Conan reconfigure` 重新引导配置。

---

## 典型工作流

```
# 首次进入项目
打开 Neovim → 自动引导配置 → 生成 .nvim-conan.json

# 安装依赖（依赖有变动时）
:Conan install

# 日常构建
:Conan build

# 切换到 debug 构建
修改 .nvim-conan.json 中 profile 为 "debug" → :Conan build
# 或
:Conan reconfigure
```

---

## License

MIT

-- LeetCode practice.
--
-- Two things have to be fixed before Rust is usable here.
--
-- The snippet LeetCode hands out is a fragment, not a program: no main, and
-- Solution, ListNode and TreeNode are never declared. rust-analyzer reports
-- them as missing types no matter how it is configured, which buries the
-- diagnostics that matter. The injector below supplies them. Injected code
-- lands outside the `@leet start` / `@leet end` markers, which is what the
-- plugin submits, so none of it reaches LeetCode.
--
-- The other half is that a lone .rs file in the storage directory is no cargo
-- project. rust-analyzer falls back to treating it as a cargo script, and cargo
-- then passes `-Z crate-attr=feature(frontmatter)` to a stable rustc, which
-- rejects it: "the option `Z` is only accepted on the nightly compiler",
-- followed by "Failed to discover workspace". Writing a Cargo.toml that lists
-- each solution as its own bin gives rust-analyzer a real workspace and cargo
-- something it can check. It is regenerated as solutions appear.

local storage = vim.fn.stdpath("data") .. "/leetcode"

-- Declarations LeetCode provides on its side but the downloaded snippet omits.
-- Declarations LeetCode provides on its side but the downloaded snippet omits.
--
-- Wrapped in a module so only the three types reach the solution's scope. The
-- submitted region is what sits between the `@leet` markers and nothing else --
-- not this preamble, not an imports section -- so anything the solution relies
-- on has to be imported inside it, exactly as on LeetCode. A top-level
-- `use std::collections::*` here would resolve HashMap locally and let a
-- submission fail on their compiler for a missing import that never showed up
-- in the editor.
local preamble = {
  "#![allow(dead_code, unused_variables, unused_mut, unused_imports)]",
  "",
  "mod leet_prelude {",
  "    use std::cell::RefCell;",
  "    use std::rc::Rc;",
  "",
  "    pub struct Solution;",
  "",
  "    #[derive(PartialEq, Eq, Clone, Debug)]",
  "    pub struct ListNode {",
  "        pub val: i32,",
  "        pub next: Option<Box<ListNode>>,",
  "    }",
  "",
  "    impl ListNode {",
  "        #[inline]",
  "        pub fn new(val: i32) -> Self {",
  "            ListNode { next: None, val }",
  "        }",
  "    }",
  "",
  "    #[derive(Debug, PartialEq, Eq)]",
  "    pub struct TreeNode {",
  "        pub val: i32,",
  "        pub left: Option<Rc<RefCell<TreeNode>>>,",
  "        pub right: Option<Rc<RefCell<TreeNode>>>,",
  "    }",
  "",
  "    impl TreeNode {",
  "        #[inline]",
  "        pub fn new(val: i32) -> Self {",
  "            TreeNode { val, left: None, right: None }",
  "        }",
  "    }",
  "}",
  "use leet_prelude::*;",
}

--- rust-analyzer inserts an import at the top level of the file, and the top
--- level is outside the `@leet` markers -- only what sits between them is
--- submitted. So `<leader>ca` on a missing HashMap fixes the buffer and leaves
--- the submission still failing on LeetCode's compiler for the same import.
---
--- Moving those lines into the code section on save keeps the two in step. Only
--- `use` statements between the preamble and `@leet start` are touched;
--- anything inside the prelude module or the section itself is left alone.
local function relocate_imports(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local start_i, end_i
  for i, l in ipairs(lines) do
    if not start_i and l:match("^//%s*@leet start") then
      start_i = i
    elseif not end_i and l:match("^//%s*@leet end") then
      end_i = i
    end
  end
  if not (start_i and end_i) then
    return
  end

  local moved, kept = {}, {}
  local depth = 0
  for i = 1, start_i - 1 do
    local l = lines[i]
    -- Track braces so the prelude module's own imports stay where they are.
    local open = select(2, l:gsub("{", ""))
    local close = select(2, l:gsub("}", ""))
    local at_top = depth == 0
    depth = depth + open - close
    if at_top and l:match("^use%s") and not l:match("^use%s+leet_prelude") then
      moved[#moved + 1] = l
    else
      kept[#kept + 1] = l
    end
  end
  if #moved == 0 then
    return
  end

  local out = {}
  vim.list_extend(out, kept)
  out[#out + 1] = lines[start_i]
  vim.list_extend(out, moved)
  for i = start_i + 1, #lines do
    out[#out + 1] = lines[i]
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
  vim.notify(
    ("leetcode: moved %d import%s inside the submitted section"):format(#moved, #moved > 1 and "s" or ""),
    vim.log.levels.INFO
  )
end

--- One bin target per solution file. Names come from the filename, which
--- contains dots and so cannot be a target name as is.
local function target_name(file)
  local stem = file:gsub("%.rs$", "")
  local name = stem:gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  -- A target name may not start with a digit, and every file here does.
  if name:match("^%d") then
    name = "p" .. name
  end
  return name
end

local function write_manifest()
  if vim.fn.isdirectory(storage) == 0 then
    return
  end
  local files = vim.fn.readdir(storage, function(f)
    return f:match("%.rs$") ~= nil
  end)
  table.sort(files)
  if #files == 0 then
    return
  end

  local lines = {
    "# Generated by lua/plugins/leetcode.lua. Edits are overwritten.",
    "[package]",
    'name = "leetcode"',
    'version = "0.0.0"',
    -- 2021 rather than the 2024 cargo defaults to: the snippets are plain
    -- enough that the older edition avoids surprises, and nothing here needs
    -- 2024 features.
    'edition = "2021"',
    "",
    "# No src/ layout, so the automatic target discovery finds nothing.",
    "autobins = false",
    "autoexamples = false",
    "autotests = false",
    "autobenches = false",
    "",
  }
  for _, f in ipairs(files) do
    lines[#lines + 1] = "[[bin]]"
    lines[#lines + 1] = ('name = "%s"'):format(target_name(f))
    lines[#lines + 1] = ('path = "%s"'):format(f)
    lines[#lines + 1] = ""
  end

  local path = storage .. "/Cargo.toml"
  local existing = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
  if table.concat(existing, "\n") == table.concat(lines, "\n") then
    return false
  end
  vim.fn.writefile(lines, path)
  return true
end

--- rust-analyzer decides how to treat a file when it attaches. Opening a
--- solution before the manifest existed leaves it checking that one .rs as a
--- standalone cargo script forever, which is where the "Cargo watcher failed"
--- and "-Z is only accepted on the nightly compiler" errors come from. A new
--- problem has the same effect in reverse: the bin target is added to the
--- manifest but the running server knows nothing about it.
local function reload_workspace()
  for _, client in ipairs(vim.lsp.get_clients({ name = "rust-analyzer" })) do
    client:request("rust-analyzer/reloadWorkspace", nil, function() end)
  end
end

return {
  {
    "kawre/leetcode.nvim",
    build = function()
      pcall(vim.cmd, "TSUpdate html")
    end,
    dependencies = {
      "nvim-telescope/telescope.nvim",
      "nvim-lua/plenary.nvim",
      "MunifTanjim/nui.nvim",
      "nvim-tree/nvim-web-devicons",
    },
    config = function(_, opts)
      require("leetcode").setup(opts)

      -- plenary.curl gives every request 10 seconds. A cross-border call to
      -- leetcode.com, especially one that lands on a Cloudflare check, runs
      -- past that often enough to matter, and when it does plenary raises from
      -- inside the job. Two things go wrong then: the failure arrives as a
      -- stack traceback rather than a message, and the traceback prints the
      -- whole curl command, LEETCODE_SESSION and csrftoken included. Those are
      -- live credentials and they end up in the message history.
      --
      -- Wrapping plenary rather than leetcode.api.utils: requiring the latter
      -- from here runs before setup has filled in config.storage, and its
      -- cookie module indexes that at load time.
      local curl = require("plenary.curl")
      for _, method in ipairs({ "get", "post", "put" }) do
        local uncaught = curl[method]
        curl[method] = function(a, b)
          -- plenary takes either (url, opts) or (opts)
          local o = type(a) == "table" and a or b
          local url = type(a) == "string" and a or (type(o) == "table" and o.url or nil)
          local ours = type(url) == "string" and url:match("leetcode%.") ~= nil
          if not ours then
            return uncaught(a, b)
          end
          if type(o) == "table" then
            o.timeout = o.timeout or 30000
          end
          local ok, res = pcall(uncaught, a, b)
          if ok then
            return res
          end
          -- Shaped so the plugin's own error handling can read it. Status 400
          -- rather than a 5xx on purpose: its retry check fires at 500 and
          -- would spend another five timeouts getting nowhere. exit stays 0
          -- because the check compares err.status without a nil guard, and the
          -- non-zero branch never sets one.
          return {
            exit = 0,
            status = 400,
            body = vim.json.encode({
              errors = { { message = "leetcode.com did not answer within 30s" } },
            }),
          }
        end
      end
    end,
    opts = {
      lang = "rust",
      injector = {
        rust = {
          -- No `imports` field on purpose. leetcode.nvim merges it with the
          -- per-language defaults in config/imports.lua, which covers python,
          -- java and cpp but not rust, and the merge calls ipairs on that nil
          -- without a guard. Supplying imports for rust crashes the picker
          -- before a question ever opens.
          before = preamble,
          -- Solutions have no entry point of their own.
          after = { "fn main() {}" },
        },
      },
    },
    init = function()
      local group = vim.api.nvim_create_augroup("leetcode_cargo", { clear = true })
      -- Written at startup, not only when a solution is opened: the manifest
      -- has to be on disk before rust-analyzer attaches to the first one.
      pcall(write_manifest)

      -- BufReadPre rather than BufReadPost, for the same reason.
      vim.api.nvim_create_autocmd("BufWritePre", {
        group = group,
        pattern = storage .. "/*.rs",
        callback = function(a)
          pcall(relocate_imports, a.buf)
        end,
      })

      vim.api.nvim_create_autocmd({ "BufReadPre", "BufWritePost" }, {
        group = group,
        pattern = storage .. "/*.rs",
        callback = function()
          local ok, changed = pcall(write_manifest)
          if ok and changed then
            vim.schedule(reload_workspace)
          end
        end,
      })

      -- `cargo run` with no argument works only while a single solution
      -- exists; the second one makes it ask which binary to run. This picks the
      -- target belonging to the current buffer.
      vim.api.nvim_create_user_command("LeetRun", function(a)
        local file = vim.api.nvim_buf_get_name(0)
        if vim.fs.dirname(file) ~= storage or not file:match("%.rs$") then
          vim.notify("LeetRun: not a LeetCode solution buffer", vim.log.levels.WARN)
          return
        end
        write_manifest()
        local bin = target_name(vim.fs.basename(file))
        local cmd = { "cargo", "run", "--quiet", "--bin", bin }
        if a.args ~= "" then
          vim.list_extend(cmd, { "--", a.args })
        end
        vim.notify("LeetRun: " .. table.concat(cmd, " "), vim.log.levels.INFO)
        vim.system(cmd, { cwd = storage, text = true }, function(res)
          vim.schedule(function()
            local body = (res.stdout or "") .. (res.stderr or "")
            if body:match("%S") then
              vim.notify(body, res.code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR)
            else
              vim.notify("LeetRun: exit " .. res.code, vim.log.levels.INFO)
            end
          end)
        end)
      end, { nargs = "*", desc = "cargo run the solution in this buffer" })

      vim.api.nvim_create_user_command("LeetCargo", function()
        local changed = write_manifest()
        reload_workspace()
        vim.notify(
          changed and ("LeetCargo: wrote " .. storage .. "/Cargo.toml") or "LeetCargo: manifest already current",
          vim.log.levels.INFO
        )
      end, { desc = "Regenerate the LeetCode Cargo.toml and reload rust-analyzer" })
    end,
  },
}

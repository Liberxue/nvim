-- rustaceanvim exposes rust-analyzer's own requests, which LazyVim leaves
-- mostly unbound. The ones below answer questions plain LSP cannot.
--
-- Macros are the reason this file exists. gd on a macro invocation lands on the
-- macro definition, which for anything derive- or proc-macro based is not where
-- the generated code is. expandMacro asks rust-analyzer to run the expansion
-- and shows the result.
return {
  {
    "mrcjkb/rustaceanvim",
    opts = function(_, opts)
      -- LazyVim's rust extra already sets on_attach. Merging opts would drop it,
      -- so keep a reference and call it first.
      local prev = vim.tbl_get(opts, "server", "on_attach")
      opts.server = opts.server or {}
      opts.server.on_attach = function(client, bufnr)
        if prev then
          prev(client, bufnr)
        end
        local function map(lhs, cmd, desc)
          vim.keymap.set("n", lhs, function()
            vim.cmd.RustLsp(cmd)
          end, { buffer = bufnr, desc = desc })
        end
        map("<leader>cx", "expandMacro", "Expand Macro")
        map("<leader>cp", "parentModule", "Parent Module")
        map("<leader>cD", "openDocs", "Open docs.rs")
        map("<leader>cT", "openCargo", "Open Cargo.toml")
        map("<leader>cy", "syntaxTree", "Syntax Tree")
        map("<leader>cI", "view mir", "View MIR")
        map("<leader>cH", "view hir", "View HIR")
        map("<leader>cj", "joinLines", "Join Lines")
        map("<leader>cP", "rebuildProcMacros", "Rebuild Proc Macros")
      end
      return opts
    end,
  },
}

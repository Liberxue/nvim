-- During a debug session K answers with rust-analyzer's view: the type of the
-- expression, its size and alignment. That is the wrong question while stopped
-- at a breakpoint, where what matters is the value the variable holds right
-- now.
--
-- K routes to the debugger while a session is running and falls back to the LSP
-- otherwise. dapui.eval opens a float that can be expanded with <CR>, which is
-- how a Vec shows its elements rather than just size=6.
return {
  {
    "rcarriga/nvim-dap-ui",
    keys = {
      {
        "K",
        function()
          if require("dap").session() then
            require("dapui").eval(nil, { enter = true })
          else
            vim.lsp.buf.hover()
          end
        end,
        desc = "Hover (debug value while stopped)",
      },
      {
        "<leader>dv",
        function()
          require("dapui").eval(vim.fn.input("Expression: "), { enter = true })
        end,
        desc = "Eval Expression",
      },
      {
        "K",
        function()
          require("dapui").eval(nil, { enter = true })
        end,
        mode = "v",
        desc = "Eval Selection",
      },
    },
  },
}

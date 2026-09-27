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
      {
        -- A wrapper prints its bookkeeping, not its contents: an Arc shows
        -- strong/weak counts and a MutexGuard shows the lock address, while the
        -- number sits several levels below. Expanding that far by hand takes
        -- three clicks per variable. `frame variable --depth` prints the whole
        -- chain at once, down to `data = (value = 1)`.
        --
        -- Field paths do not reach there: the Rust formatters expose synthetic
        -- children that an expression cannot address, so `counter.data.data`
        -- answers "Attribute 'data' is not defined".
        "<leader>dV",
        function()
          local session = require("dap").session()
          if not session then
            vim.notify("no debug session", vim.log.levels.WARN)
            return
          end
          local word = vim.fn.expand("<cword>")
          if word == "" then
            return
          end
          require("dap").repl.open()
          session:evaluate("frame variable --depth 5 " .. word, function() end)
        end,
        desc = "Inspect Deeply (unwrap Arc/Mutex)",
      },
    },
  },
}

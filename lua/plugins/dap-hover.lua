-- During a debug session K answers with rust-analyzer's view: the type of the
-- expression, its size and alignment. That is the wrong question while stopped
-- at a breakpoint, where what matters is the value the variable holds.
--
-- It also answers badly for wrappers. An Arc reports strong/weak counts, a
-- MutexGuard reports a lock address, and the number underneath takes several
-- expansions to reach. dapunwrap descends for you, so one key covers both the
-- plain and the wrapped case.
return {
  {
    "rcarriga/nvim-dap-ui",
    -- stylua: ignore
    keys = {
      { "K", function() require("dapunwrap").hover() end, desc = "Hover (unwrapped value while debugging)" },
      { "K", function() require("dapui").eval(nil, { enter = true }) end, mode = "v", desc = "Eval Selection" },
      { "<leader>dv", function() require("dapui").eval(vim.fn.input("Expression: "), { enter = true }) end, desc = "Eval Expression" },
    },
  },
}

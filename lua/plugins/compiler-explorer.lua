-- Compile the buffer on godbolt.org and read the assembly next to it.
--
-- This is the only way to compile CUDA on this machine: macOS dropped NVIDIA
-- support after 10.13, and there is no NVIDIA GPU here anyway. godbolt exposes
-- 156 CUDA compilers and accepts .cu, so PTX and SASS are still readable even
-- though nvcc cannot run locally.
--
-- Needs curl, which macOS ships.
return {
  {
    "krady21/compiler-explorer.nvim",
    cmd = {
      "CECompile",
      "CECompileLive",
      "CEFormat",
      "CEAddLibrary",
      "CELoadExample",
      "CEOpenWebsite",
      "CEDeleteCache",
      "CEShowTooltip",
      "CEGotoLabel",
    },
    opts = {
      url = "https://godbolt.org",
      infer_lang = true,
      line_match = {
        -- Highlight the assembly that belongs to the source line under the
        -- cursor. Off upstream; it is most of the point of reading assembly
        -- beside the source.
        highlight = true,
        jump = true,
      },
      open_qflist = false,
      split = "split",
      job_timeout_ms = 25000,
    },
    -- stylua: ignore
    keys = {
      { "<leader>ce", "<cmd>CECompile<cr>", desc = "Compiler Explorer" },
      { "<leader>cE", "<cmd>CECompileLive<cr>", desc = "Compiler Explorer (live)" },
      { "<leader>cw", "<cmd>CEOpenWebsite<cr>", desc = "Compiler Explorer (browser)" },
    },
  },
}

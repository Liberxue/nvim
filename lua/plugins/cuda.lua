-- CUDA editing support. Nothing here compiles or runs: this machine has Intel
-- graphics, and macOS has had no NVIDIA support since 10.13. :CECompile sends
-- the buffer to godbolt, which does have nvcc, when the generated PTX matters.
--
-- .cu and .cuh already map to the cuda filetype, and LazyVim's lang.clangd
-- extra already lists cuda among clangd's filetypes with usable flags, so
-- neither is repeated here.
--
-- What is missing is the CUDA headers. Without them clangd reports __global__,
-- blockIdx, threadIdx and every runtime call as undeclared -- seven errors on a
-- fifteen-line kernel, which buries any real diagnostic. stubs/cuda_stub.h
-- declares enough to get a clean parse; :CudaInit points a project at it.
--
-- A project with a real toolkit ships its own compile_commands.json, which
-- clangd prefers over compile_flags.txt, so :CudaInit does not get in its way.
return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { ensure_installed = { "cuda", "cpp", "cmake" } },
  },

  {
    "neovim/nvim-lspconfig",
    optional = true,
    init = function()
      vim.api.nvim_create_user_command("CudaInit", function()
        local buf = vim.api.nvim_buf_get_name(0)
        local dir = buf ~= "" and vim.fs.dirname(buf) or vim.uv.cwd()
        local root = vim.fs.root(dir, { ".git", "Makefile", "CMakeLists.txt" }) or dir

        local existing = vim.fs.find({ "compile_commands.json", ".clangd" }, {
          path = dir,
          upward = true,
          stop = vim.uv.os_homedir(),
        })
        if #existing > 0 then
          vim.notify(
            "CudaInit: " .. existing[1] .. " already describes this project, leaving it alone",
            vim.log.levels.WARN
          )
          return
        end

        local path = root .. "/compile_flags.txt"
        if vim.fn.filereadable(path) == 1 then
          vim.notify("CudaInit: " .. path .. " exists already", vim.log.levels.WARN)
          return
        end
        local lines = {
          "-xcuda",
          "--cuda-gpu-arch=sm_75",
          -- No toolkit here, so tell clang not to look for one. Without both of
          -- these it fails before it reaches the stub.
          "-nocudalib",
          "-nocudainc",
          "-std=c++17",
          "-D__CUDA_STUB__",
          "-include",
          vim.fn.stdpath("config") .. "/stubs/cuda_stub.h",
        }
        vim.fn.writefile(lines, path)
        vim.notify("CudaInit: wrote " .. path .. ", restart the LSP to pick it up", vim.log.levels.INFO)
      end, { desc = "Write compile_flags.txt so clangd can parse CUDA without a toolkit" })
    end,
  },
}

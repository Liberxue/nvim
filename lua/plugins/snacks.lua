-- ~/.config/nvim/lua/plugins/snacks.lua

return {
  {
    "folke/snacks.nvim",
    opts = {
      image = {
        enabled = true,
        force = true,

        doc = {
          enabled = true,
          inline = false,
          float = true,
        },
      },
    },
  },
}

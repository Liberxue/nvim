-- Inline blame at the end of the current line, the way GitLens annotates.
-- gitsigns ships this; LazyVim leaves it off.
--
-- This overlaps with the mouseblame popup, which fires on the same CursorHold.
-- The two carry different amounts: this line is glanceable and stays out of the
-- way, the popup adds the commit body. Drop either with :MouseBlameToggle or
-- :Gitsigns toggle_current_line_blame.
return {
  {
    "lewis6991/gitsigns.nvim",
    opts = {
      current_line_blame = true,
      current_line_blame_opts = {
        virt_text = true,
        virt_text_pos = "eol",
        -- Longer than mouseblame's 120ms so the annotation settles after the
        -- popup rather than racing it.
        delay = 400,
        ignore_whitespace = false,
      },
      current_line_blame_formatter = "  <author>, <author_time:%Y-%m-%d> - <summary>",
      current_line_blame_formatter_nc = "  uncommitted",
    },
  },
}

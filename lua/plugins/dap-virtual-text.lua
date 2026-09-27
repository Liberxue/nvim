-- The end-of-line values come straight from the adapter, so a wrapper reports
-- its bookkeeping there too: an Arc shows strong/weak counts and a MutexGuard
-- shows a lock address, while the number the code is working on stays out of
-- sight. dapunwrap walks the scopes tree once per stop and caches what each
-- wrapper holds, and the callback below reports that instead. No key to press.
return {
  {
    "theHamsta/nvim-dap-virtual-text",
    opts = {
      enabled = true,
      enabled_commands = true,
      -- Changed values are the signal worth catching while stepping.
      highlight_changed_variables = true,
      highlight_new_as_changed = false,
      show_stop_reason = true,
      commented = false,
      only_first_definition = true,
      all_references = false,
      virt_text_pos = "eol",
      display_callback = function(variable, buf, stackframe, node, options)
        return require("dapunwrap").display_callback(variable, buf, stackframe, node, options)
      end,
    },
  },
}

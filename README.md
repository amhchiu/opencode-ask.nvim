# opencode-ask.nvim

Ask OpenCode about a visual selection without leaving Neovim.

Select some lines, run `:OpencodeAsk` or press `<leader>oq`, type a question,
and the plugin sends it with the selected file and line range to a chosen
OpenCode session. Answers appear in the OpenCode TUI.

The plugin remembers the session per project, so follow-up questions continue
the same conversation across Neovim restarts.

## Status

Early development. Documentation and the full workflow are still being built.

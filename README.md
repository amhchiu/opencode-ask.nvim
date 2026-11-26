# opencode-ask.nvim

Ask OpenCode about a visual selection without leaving Neovim. The plugin
captures the selected file and line range, opens a floating question prompt,
and sends the question to the OpenCode session selected or created for the
project. Answers are still read in the OpenCode TUI.

The chosen session is remembered per project, so follow-up questions continue
the same conversation across Neovim restarts.

## Requirements

- Neovim 0.10 or newer. Developed and tested on Neovim 0.12.6.
- OpenCode V2 with its background service running. The plugin shells out to
  `opencode api`; it does not speak HTTP itself.
- macOS. Tested there; Linux is likely to work but is unsupported.
- Optional: [fzf-lua](https://github.com/ibhagwan/fzf-lua) for the session
  picker. Without it, the plugin uses `vim.ui.select`.

## Installation

The plugin is loaded eagerly from its checkout through lazy.nvim. Eager
loading avoids losing the visual selection while a lazy key handler loads the
plugin.

```lua
-- ~/.dotfiles/nvim/.config/nvim/lua/plugins/opencode-ask.lua
return {
  dir = "~/projects/nvim-plugins/opencode-ask.nvim",
  name = "opencode-ask",
  main = "opencode_ask",
  lazy = false,
  opts = {},
}
```

A customized configuration:

```lua
return {
  dir = "~/projects/nvim-plugins/opencode-ask.nvim",
  name = "opencode-ask",
  main = "opencode_ask",
  lazy = false,
  opts = {
    -- Pin one session instead of using the per-project session picker.
    -- session = "ses_...",

    keymap = "<leader>oa",
    save = false,

    -- Any other value falls back to vim.ui.select.
    picker = "fzf-lua",

    state_path = vim.fn.stdpath("state") .. "/opencode-ask/sessions.json",
    api = {
      command = "/opt/homebrew/bin/opencode",
      timeout = 15000,
    },
  },
}
```

`opts` is deep-merged with the defaults, so `api = { command = ... }` keeps the
default `api.timeout`.

## Configuration

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `session` | `string` or `nil` | `nil` | Pin every question to this OpenCode session ID. When `nil`, the plugin uses the stored project session or opens the picker. |
| `keymap` | `string` or `false` | `"<leader>oq"` | Visual-mode only mapping (`x` mode, not select mode) installed by `setup()`. Set to `false` to install nothing. |
| `save` | `boolean` | `true` | Save a modified file buffer before sending. The send is aborted when saving fails. |
| `picker` | `string` | `"fzf-lua"` | Use `fzf-lua` when it is set to `"fzf-lua"` and available; otherwise use `vim.ui.select`. |
| `state_path` | `string` | `vim.fn.stdpath("state") .. "/opencode-ask/sessions.json"` | JSON file that remembers one session per project. |
| `api.command` | `string` | `"opencode"` | OpenCode executable name or absolute path. Must support `opencode api` and `opencode session list`. |
| `api.timeout` | `number` | `15000` | Timeout in milliseconds for OpenCode CLI calls. Health checks cap their own timeout at 5000ms. |

`<leader>` resolves to Neovim's default `\` until `vim.g.mapleader` is set.
This configuration does not set a leader, so the default mapping is `\oq`.

## Commands and keymaps

| Name | Mode | Description |
| --- | --- | --- |
| `<leader>oq` | Visual (`x`) | Ask about the selected lines. |
| `:OpencodeAsk [range]` | Command | Ask about the given range, or the current line without a range. |
| `:OpencodeSession` | Command | Choose an existing session or create a new one for the current project. |
| `:OpencodeSessionClear` | Command | Forget the stored session for the current project. |
| `:checkhealth opencode_ask` | Command | Check the CLI, OpenCode service, session listing, state directory, state file, and picker. |

Prompt controls:

| Key | Action |
| --- | --- |
| `<CR>` | Submit the question. Whitespace-only input is rejected and the prompt stays open. |
| `<C-j>` | Insert a newline without submitting. |
| `<Esc>` | Cancel and close the prompt. |

## Workflow

### First-time session selection or creation

1. In Neovim, run `:OpencodeSession`.
2. With the fzf-lua picker, start typing. Selecting a matching session chooses
   it. Type a new title and press Enter when there are no matches to create a
   session with that title.
3. Without fzf-lua, `vim.ui.select` lists the sessions plus a
   **Create new session…** entry. Choose that entry and enter a title.
4. The chosen or created session is stored for the project, keyed by its
   normalized project root (the Git root, or the current directory when there
   is no `.git`).

You can also create or start a session in the OpenCode TUI and then select it
here. If no session is stored and `session` is not pinned, asking opens the
same picker automatically, so you can create and use a session in one flow.
Cancelling the picker quietly does nothing.

### Asking about a selection

1. Open a normal, named file buffer.
2. Select lines in visual mode.
3. Press `<leader>oq` (or run `:'<,'>OpencodeAsk`).
4. Type the question. `<C-j>` adds a newline; `<CR>` submits; `<Esc>` cancels.
5. The plugin saves the buffer when `save` is enabled, sends the question, and
   notifies `Sent to <session> (<file>:<range>)`.
6. Switch to the OpenCode TUI to read the answer.

The request includes the question, an `@relative/path#start-end` mention, and
a file attachment URI with the line range.

### Follow-up questions

Ask again from the same project. The stored session is reused without another
picker, so the question joins the same conversation. The selection can be in a
different file or line range. A stored session is never duplicated by a
follow-up question.

### Across Neovim restarts

The stored session lives on disk and is reused after restarting Neovim.

### Switching or clearing a session

- `:OpencodeSession` picks a different session for the project. Selecting a
  matching session never creates a duplicate; creation happens only when the
  typed query has no matches (or when you choose **Create new session…** in
  `vim.ui.select`).
- `:OpencodeSessionClear` removes the stored entry. The next question opens the
  picker again.
- Setting `session` pins one session for every project.

### Stale-session recovery

When OpenCode reports a deleted session (or an invalid session ID), the plugin
shows a warning. If the session came from the state file, the entry is cleared;
run `:OpencodeSession` to choose another. If `session` is pinned, the plugin
does not modify configuration: update or remove `session` in `opts`.

## State file

The default path is:

```text
vim.fn.stdpath("state") .. "/opencode-ask/sessions.json"
```

Print the effective path with:

```vim
:lua print(require("opencode_ask.sessions").state_path())
```

The file is keyed by normalized project root and stores only `id`, `title`,
`directory`, and `updated` for each project. It never stores prompts, file
contents, credentials, or API responses. The file is created when you choose
or create a session.

Reset one project with `:OpencodeSessionClear`. Reset everything by deleting
the file; the plugin recreates it the next time a session is chosen or created.
A corrupt state file is treated as empty and can be deleted or rewritten by
choosing or creating a session again. `:checkhealth opencode_ask` reports
corruption with the path.

## Limitations

- Answers are read in the OpenCode TUI. Nothing is streamed into Neovim, and
  Neovim only learns that the prompt was accepted.
- Prompts sent to an active session are delivered through OpenCode V2's
  session inbox/steering; the plugin does not queue, retry, or cancel them.
- OpenCode permission requests are approved in the TUI.
- The plugin can create a session from the session picker. It cannot rename or
  delete sessions, and it cannot create one when the OpenCode CLI or service is
  unavailable.
- OpenCode V1 and Windows are not supported.

## Troubleshooting

**`opencode` is missing or not executable**

`:checkhealth opencode_ask` reports an error. Install OpenCode, add it to
`PATH`, or set `api.command` to its absolute path.

**OpenCode service is stopped or unreachable**

Health reports that `opencode api get /api/info` timed out or exited non-zero,
and asks fail with a warning. Start OpenCode (its background service should
come up with it) and retry. You can test the service directly:

```sh
opencode api get /api/info
```

**No sessions for the project**

An empty session list is valid. Sessions are project-scoped, so a session
started in another directory may not appear. The primary recovery is to create
one from the picker: run `:OpencodeSession`, type a new title, and press Enter
when there are no matches. With `vim.ui.select`, choose
**Create new session…** and enter a title. You can also start a session for
this project in the OpenCode TUI and select it here.

**Session was deleted or the ID is invalid**

The plugin warns and clears the stored entry unless `session` is pinned. Run
`:OpencodeSession` to pick a current session, or fix `session` in `opts`.

**State file is corrupt**

`:checkhealth opencode_ask` names the path and suggests recovery. Delete the
file to reset all projects, or run `:OpencodeSession` to rewrite it.

**Empty, unnamed, or non-file buffer**

The plugin warns instead of asking. Save the buffer to a file first. Only
normal file buffers are supported; terminal, help, scratch, and other special
buffers are rejected.

**Saving a modified buffer fails**

The plugin warns before opening the prompt when the buffer is modified and
read-only or not modifiable. Save the changes or make the buffer writable, then
retry. If saving fails after the prompt, the question is not sent.

**API timeout**

Increase `api.timeout` and confirm the OpenCode service is responsive. A timed
out request is reported as a warning; the plugin does not retry it.

## Development

Run the headless test suite from the plugin repository:

```sh
nvim -u tests/minimal_init.lua -l tests/run.lua
```

Run the health check in a normal Neovim session:

```vim
:checkhealth opencode_ask
```

# opencode-ask.nvim

Ask OpenCode about a visual selection without leaving Neovim. The plugin
captures the selected file and line range, opens a floating question prompt,
and sends the question to the OpenCode session selected or created for the
project. Toggle the answer viewer from inside Neovim to read the reply through
`opencode mini --session <id>`.

The chosen session is remembered per project, so follow-up questions continue
the same conversation across Neovim restarts.

## Requirements

- Neovim 0.10 or newer. Developed and tested on Neovim 0.12.6.
- OpenCode V2 with its background service running. The plugin shells out to
  `opencode api`; it does not speak HTTP itself. The answer viewer runs the V2
  `opencode mini` subcommand inside a Neovim terminal buffer.
- macOS. Tested there; Linux is likely to work but is unsupported.
- Optional: [fzf-lua](https://github.com/ibhagwan/fzf-lua) for the session
  picker. Without it, the plugin uses `vim.ui.select`.

## Installation

The plugin is loaded eagerly from GitHub through lazy.nvim. Eager loading
avoids losing the visual selection while a lazy key handler loads the plugin.

```lua
-- ~/.config/nvim/lua/plugins/opencode-ask.lua
return {
  "amhchiu/opencode-ask.nvim",
  main = "opencode_ask",
  lazy = false,
  opts = {},
}
```

A customized configuration:

```lua
return {
  "amhchiu/opencode-ask.nvim",
  main = "opencode_ask",
  lazy = false,
  opts = {
    -- Pin one session instead of using the per-project session picker.
    -- session = "ses_...",

    keymap = "<leader>oa",
    save = false,

    -- Floating prompt sizing and placement.
    ui = {
      width = 80,
      height = 4,
      border = "rounded", -- "none" omits the title and border cells.
      position = "selection", -- "selection" or "center".
      winblend = 0,
    },

    -- Toggleable opencode mini answer viewer.
    viewer = {
      keymap = "<leader>ot", -- Normal-mode toggle; false disables it.
      layout = "float", -- "float", "right", or "bottom".
      width = 0.8, -- Fraction in (0, 1] or an integer > 1 columns.
      height = 0.8, -- Fraction in (0, 1] or an integer > 1 rows.
      border = "rounded", -- Floating viewer only.
      winblend = 0, -- Floating viewer only.
      auto_open = false, -- Open after a question is sent.
      start_insert = false, -- Enter terminal mode on open.
    },

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
| `ui.width` | `number` | `80` | Width of the floating prompt in columns. The prompt is at least 20 columns wide when the editor is wide enough, and never wider than the editor. |
| `ui.height` | `number` | `4` | Height of the floating prompt in lines. |
| `ui.border` | `string` or border list | `"rounded"` | Any `nvim_open_win` border name (`"none"`, `"single"`, `"double"`, `"rounded"`, `"solid"`, `"shadow"`) or a list of 1, 2, 4, or 8 border strings. `"none"` omits the float title and border cells. |
| `ui.position` | `string` | `"selection"` | `"selection"` opens the prompt above the selected lines when there is room, below them when there is not, and centered when neither fits. `"center"` always centers the prompt. |
| `ui.winblend` | `number` | `0` | Transparency of the floating prompt, from 0 (opaque) to 100 (fully transparent). |
| `viewer.keymap` | `string` or `false` | `"<leader>ot"` | Normal-mode toggle mapping installed by `setup()`. Set to `false` to install nothing. |
| `viewer.layout` | `string` | `"float"` | `"float"`, `"right"`, or `"bottom"`. |
| `viewer.width` | `number` | `0.8` | Width of a floating or right-split viewer: a fraction in `(0, 1]` (`1` = 100%) or an integer above 1 in columns. |
| `viewer.height` | `number` | `0.8` | Height of a floating or bottom-split viewer: a fraction in `(0, 1]` (`1` = 100%) or an integer above 1 in rows. |
| `viewer.border` | `string` or border list | `"rounded"` | Border of the floating viewer, using the same values as `ui.border`. Applies only when `viewer.layout` is `"float"`. |
| `viewer.winblend` | `number` | `0` | Transparency of the floating viewer, from 0 to 100. Applies only when `viewer.layout` is `"float"`. |
| `viewer.auto_open` | `boolean` | `false` | Open the viewer after a question is sent successfully. |
| `viewer.start_insert` | `boolean` | `false` | Enter terminal mode when the viewer opens, so keystrokes go to `opencode mini`. |

`<leader>` resolves to Neovim's default `\` until `vim.g.mapleader` is set.
This configuration does not set a leader, so the defaults are `\oq` and `\ot`.

### Theming

The floating prompt uses four plugin-scoped highlight groups. They are defined
with default links, so your own definitions win and colorschemes can still
override them. The prompt and border follow the editor background by default,
so they blend in with transparent colorschemes.

| Group | Default link | Used for |
| --- | --- | --- |
| `OpencodeAskNormal` | `Normal` | Prompt text and background (matches the editor). |
| `OpencodeAskBorder` | `Normal` | Border glyphs with a transparent background. |
| `OpencodeAskTitle` | `FloatTitle` | Float title (the selection reference). |
| `OpencodeAskSelection` | `Visual` | Selected lines in the source buffer while the prompt is open. |

To restore float-specific colors instead, link the groups back:

```lua
vim.api.nvim_set_hl(0, "OpencodeAskNormal", { link = "NormalFloat" })
vim.api.nvim_set_hl(0, "OpencodeAskBorder", { link = "FloatBorder" })
```

For example, to give the prompt a red border:

```lua
vim.api.nvim_set_hl(0, "OpencodeAskBorder", { fg = "#ff0000" })
```

## Commands and keymaps

| Name | Mode | Description |
| --- | --- | --- |
| `<leader>oq` | Visual (`x`) | Ask about the selected lines. |
| `<leader>ot` | Normal (`n`) | Toggle the answer viewer for the current project's session. |
| `:OpencodeAsk [range]` | Command | Ask about the given range, or the current line without a range. |
| `:OpencodeToggle` | Command | Toggle the answer viewer for the current project's session. |
| `:OpencodeSession` | Command | Choose an existing session or create a new one for the current project. |
| `:OpencodeSessionClear` | Command | Forget the stored session for the current project. |
| `:checkhealth opencode_ask` | Command | Check the CLI, OpenCode service, session listing, state directory, state file, and picker. |

Prompt controls:

| Key | Action |
| --- | --- |
| `<CR>` | Submit the question. Whitespace-only input is rejected and the prompt stays open. |
| `<C-j>` | Insert a newline without submitting. |
| `<Esc>` | Cancel and close the prompt. |

Viewer controls:

| Key | Action |
| --- | --- |
| `q` | Hide the viewer in Normal mode. The OpenCode session keeps running. |
| `<C-\><C-n>` | Leave terminal mode when typing inside `opencode mini`. |

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
3. Press `<leader>oq` (or run `:'<,'>OpencodeAsk`). The selected lines stay
   highlighted, and the prompt opens directly above the selection when there is
   room, below it otherwise, and centered when neither fits.
4. Type the question. `<C-j>` adds a newline; `<CR>` submits; `<Esc>` cancels.
5. The plugin saves the buffer when `save` is enabled, sends the question, and
   notifies `Sent to <session> (<file>:<range>)`.
6. Press `<leader>ot` (or run `:OpencodeToggle`) to read and answer in the
   viewer. The OpenCode TUI also works.

The request includes the question, an `@relative/path#start-end` mention, and
a file attachment URI with the line range.

### Reading answers and approving permissions

Press `<leader>ot` or run `:OpencodeToggle` to open `opencode mini --session
<id>` for the project's session. The viewer appears as a floating window by
default, or as a right or bottom split when `viewer.layout` says so, and
attaches to the same session so the answer appears there.

Use it to read the answer and to approve OpenCode permission requests without
leaving Neovim. Setting `viewer.auto_open = true` opens the viewer as soon as a
question is sent successfully; `viewer.start_insert = true` enters terminal mode
straight away.

Press `<leader>ot` (anywhere) or `q` inside the viewer in Normal mode to hide
the window. The terminal buffer and the `opencode mini` process stay alive, so
opening it again is instant and the OpenCode session stays connected. Switching projects hides the other
project's viewer window without stopping it.

To type inside `opencode mini`, enter terminal mode with `i`, then press
`<C-\><C-n>` to return to Normal mode before pressing `q`. Re-selecting the same
session keeps the viewer. Choosing another session, clearing it, or recovering
from a deleted session invalidates the old buffer, so the next toggle attaches
to the current session.

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

- Prompts are sent to the session asynchronously; Neovim only learns that the
  request was accepted, and nothing is parsed or streamed into a native markdown
  buffer. Press `<leader>ot` or run `:OpencodeToggle` to embed `opencode mini
  --session <id>` in a toggleable Neovim terminal window instead. Answers stream
  into that terminal buffer and are read there.
- Prompts sent to an active session are delivered through OpenCode V2's
  session inbox/steering; the plugin does not queue, retry, or cancel them.
- OpenCode permission requests can be approved in the viewer.
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

**Viewer will not open**

The viewer warns when `api.command` is missing or not executable. Install
OpenCode, add it to `PATH`, or set `api.command` to its absolute path. Toggling
also needs a resolved session; run `:OpencodeSession` if the picker was
cancelled or no session is stored.

**Viewer text is stale**

The viewer attaches to the project's stored session. Choosing another session
with `:OpencodeSession`, clearing it with `:OpencodeSessionClear`, or recovering
from a deleted session invalidates the cached buffer, so the next toggle
re-attaches to the current session and shows fresh output.

**`opencode mini` fails to start**

`opencode mini` needs OpenCode V2 and a real TTY. The viewer runs it in a Neovim
terminal buffer, which provides the TTY; confirm that `opencode --version`
reports `2.x`. Startup errors stay visible in the open viewer window.

## Development

Run the headless test suite from the plugin repository:

```sh
nvim -u tests/minimal_init.lua -l tests/run.lua
```

Run the health check in a normal Neovim session:

```vim
:checkhealth opencode_ask
```

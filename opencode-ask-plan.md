# opencode-ask.nvim: ask OpenCode about a visual selection

[OpenCode API reference](https://opencode.ai/docs/api/) · [OpenCode TUI references](https://opencode.ai/docs/cli/tui/)

Create a standalone Neovim plugin that captures a visual selection, opens a floating question prompt, and sends the question with the selected file and line range to a chosen OpenCode session. The plugin stores the chosen session per project so follow-up questions continue the same conversation. Answers are read in the OpenCode TUI.

## Context

- Target: Neovim 0.12.6 on macOS with a minimal config at `~/.dotfiles/nvim/.config/nvim`.
- The config uses lazy.nvim directly. It does not load LazyVim; `lazyvim.json` is unused.
- `fzf-lua` and `blink.cmp` are installed. No snacks, no noice, and no dressing.
- OpenCode V2 runs against a shared background service. `opencode api` finds and authenticates to that service.
- The session API is marked experimental. Keep all API coupling in one module.
- `vim.g.mapleader` is not set in this config. `<leader>oq` therefore resolves to the default `\oq` until a leader is configured.

## Decisions

| Topic | Decision |
| --- | --- |
| Plugin location | `~/projects/nvim-plugins/opencode-ask.nvim`, a standalone git repository. |
| Lua namespace | `opencode_ask`. |
| Loading | Load eagerly through lazy.nvim's `dir` option. The plugin is small, and eager loading avoids losing the visual selection while a lazy key handler loads the plugin. |
| Scope | Solid personal tool. Send the question to OpenCode and read the answer in the OpenCode TUI. No answer streaming in Neovim. |
| Prompt UI | Floating scratch buffer. `<CR>` submits, `<C-j>` inserts a newline, and `<Esc>` cancels. |
| Backend | Shell out to `opencode api post /api/session/{id}/prompt`. Do not implement an HTTP client. |
| Attachment | Send `files[].uri = file://<encoded absolute path>?start=N&end=M`. Include `@relative/path#N-M` in the text for readability. |
| Session resolution | Fixed `config.session` wins. Otherwise use the stored session for the project. Otherwise open an fzf-lua picker, with `vim.ui.select` as the fallback. |
| Session state | Store metadata in `stdpath("state")/opencode-ask/sessions.json`, keyed by normalized project root. Write atomically. |
| Buffer saving | Save a modified file buffer before sending. Abort the send if saving fails. |
| Keymap | Default `<leader>oq` in visual mode (`"x"` only, excluding select mode), installed by `setup()`. Allow `keymap = false` or a custom mapping. |
| Tests | Headless Lua assertions run via `nvim -u tests/minimal_init.lua -l tests/run.lua`. No test framework dependency. |
| Compatibility | Neovim 0.10 or newer, OpenCode V2, and macOS. |

## Out of scope

- Streaming the assistant reply into a Neovim window.
- Queueing UI, cancelling, or retrying prompts (OpenCode V2 handles inbox delivery/steering server-side).
- Auto-approving OpenCode permissions. Approve them in the TUI.
- tmux integration or terminal `send-keys` integration.
- Detecting which session the OpenCode TUI is currently displaying. The user selects or configures the session explicitly.
- Creating a session when none exists. The error message tells the user to start one in OpenCode.
- OpenCode V1 compatibility.
- Windows support.
- Publishing the plugin to a registry.
- Changing the user's leader key.

## Phases

Complete the phases in order. After finishing and verifying each phase, commit the changes in `~/projects/nvim-plugins/opencode-ask.nvim` as one reviewable commit before starting the next phase. Every phase must leave the plugin loadable and the existing tests passing.

### Phase 1: Scaffold the plugin and lazy.nvim spec

**Intent:** Create the standalone package boundary and prove that lazy.nvim can load it from the new directory.

**Outcome:** `opencode-ask.nvim` exists as a git repository with a configuration module, a setup entry point, and a minimal test harness. Neovim loads it from `~/.dotfiles/nvim/.config/nvim` without errors.

**Depends on:** None.

**Steps:**

1. Inside `~/projects/nvim-plugins/opencode-ask.nvim`, create the `lua/opencode_ask/` and `tests/` directories.
2. Add `.gitignore` with `.DS_Store` and `*.log`.
3. Add `lua/opencode_ask/config.lua`. Define `M.defaults` with `session = nil`, `keymap = "<leader>oq"`, `save = true`, `picker = "fzf-lua"`, `state_path = vim.fn.stdpath("state") .. "/opencode-ask/sessions.json"`, and `api = { command = "opencode", timeout = 15000 }`. Add `M.merge(opts)` that deep-merges into a fresh copy of `M.defaults` (never mutating `M.defaults`) and validates that `session` is a string or `nil`.
4. Add `lua/opencode_ask/init.lua`. Initialize `M.options = config.merge({})` at module load time so callers and tests work before `setup()`. Define `M.setup(opts)` to merge `opts` into defaults. Defer keymap installation to Phase 6 when `M.ask()` exists.
5. Add a brief placeholder `README.md` describing the plugin's purpose (full documentation is added in Phase 7).
6. Add `tests/minimal_init.lua`. Prepend the plugin repository root to `runtimepath`, disable swap files, and set `vim.opt.shadafile = "NONE"` so tests do not write state.
7. Add `~/.dotfiles/nvim/.config/nvim/lua/plugins/opencode-ask.lua`:

   ```lua
   return {
     dir = "~/projects/nvim-plugins/opencode-ask.nvim",
     name = "opencode-ask",
     main = "opencode_ask",
     lazy = false,
     opts = {},
   }
   ```

   Do not change `lua/config/lazy.lua:25-31`; it already imports every file in `lua/plugins`.
8. Do not add the plugin keymap to `lua/keymaps.lua`. The plugin owns the mapping so the plugin remains self-contained.

**Verification:**

1. Run `cd ~/projects/nvim-plugins/opencode-ask.nvim && nvim --headless -u tests/minimal_init.lua -c "lua print(vim.inspect(require('opencode_ask').options))" -c "qa!"`. Expect the defaults table.
2. Run `nvim --headless -u ~/.dotfiles/nvim/.config/nvim/init.lua -c "lua print(vim.inspect(require('opencode_ask').options))" -c "qa!"`. Expect the merged defaults and no load errors.
3. Open Neovim and run `:Lazy`. Expect `opencode-ask` in the plugin list with no errors.
4. Once verification passes, commit the Phase 1 changes in `~/projects/nvim-plugins/opencode-ask.nvim` (and commit `~/.dotfiles/nvim/.config/nvim/lua/plugins/opencode-ask.lua` in `~/.dotfiles` if tracked there).

### Phase 2: Capture the visual selection

**Intent:** Turn the visual selection into a stable context object containing the absolute path, relative path, line range, and API-ready file URI.

**Outcome:** `selection.capture()` returns a context object for a normal named file buffer, returns a descriptive error for unsupported buffers, and has unit tests for range normalization and URI construction.

**Depends on:** Phase 1.

**Steps:**

1. Add `lua/opencode_ask/selection.lua` with these functions:
   - `M.project_root(bufnr)` resolves `vim.fs.root(bufnr, { ".git" }) or vim.fn.getcwd()` and normalizes the path (`vim.uv.fs_realpath(root) or vim.fs.normalize(root)`) so `selection`, `sessions`, and `init` always derive the exact same project key.
   - `M.normalize(first, last)` returns `min, max`.
   - `M.relative(absolute, root)` returns `vim.fs.relpath(root, absolute) or absolute` (avoiding naive prefix matching bugs on sibling directories).
   - `M.file_uri(absolute, first, last)` returns `vim.uri_from_fname(absolute) .. "?start=" .. first .. "&end=" .. last`.
   - `M.capture(opts)` reads `opts.first` and `opts.last`, or the visual endpoints using `vim.fn.line("v")` and `vim.fn.line(".")`. Use the current buffer when `opts.bufnr` is absent.
   - `M.save(context)` saves the buffer when `config.save` is true and the buffer is valid and modified.
2. In `M.capture()`:
   - Reject buffers where `vim.bo[bufnr].buftype ~= ""`.
   - Reject unnamed buffers (`vim.api.nvim_buf_get_name(bufnr) == ""`).
   - Normalize `absolute` via `vim.fn.fnamemodify(name, ":p")`.
   - Resolve `project_root` via `M.project_root(bufnr)`.
   - Build `ref = relative .. ":" .. first` for one line, or `relative .. ":" .. first .. "-" .. last` for a range.
   - Build `mention = "@" .. relative .. "#" .. first` or `"@" .. relative .. "#" .. first .. "-" .. last`.
   - Return `{ bufnr, absolute, relative, project_root, first, last, ref, mention, uri }`.
3. In `M.save(context)`, wrap `vim.cmd("silent update")` in `pcall` inside `nvim_buf_call()` so read-only or permission failures do not throw uncaught Lua errors. Return `true` on success and `nil, err` when saving fails.
4. Add `tests/run.lua` with a small assertion harness that prints a clear pass/fail summary and exits with a non-zero status (`os.exit(1)`) when any assertion fails.
5. Add tests for reversed ranges, single-line ranges, paths containing spaces, relative paths inside and outside the project (including sibling prefix edge cases like `/proj` vs `/proj-2`), and the `mention` format. Keep buffer-independent logic in pure functions so the tests do not require a full editor session.

**Verification:**

1. Run `cd ~/projects/nvim-plugins/opencode-ask.nvim && nvim -u tests/minimal_init.lua -l tests/run.lua`. Expect exit status 0 and the test summary.
2. Open a named file, select lines 3–7, and run `:lua print(vim.inspect(require("opencode_ask.selection").capture({ first = 3, last = 7 })))`. Expect a populated context object with a `file://` URI.
3. Once verification passes, commit the Phase 2 changes.

### Phase 3: Build the floating question prompt

**Intent:** Provide a focused popup for the question without leaving Neovim or touching the OpenCode API.

**Outcome:** `ui.prompt()` opens a floating input, returns the entered text through a callback, and cleans up its buffer and window on submit or cancel.

**Depends on:** Phase 1.

**Steps:**

1. Add `lua/opencode_ask/ui.lua` with `M.prompt(opts, on_submit)`.
2. Accept `opts.title`, `opts.default`, `opts.width`, and `opts.height`. Clamp dimensions safely for small terminals:
   - `width = math.max(20, math.min(opts.width or 80, vim.o.columns - 10))` (falling back to `math.max(1, vim.o.columns - 2)` if the terminal is narrower than 20 columns).
   - `height = math.min(opts.height or 4, math.max(1, vim.o.lines - 4))`.
   - Clamp `row` and `col` to `>= 0`.
   - Default title to `"Ask OpenCode"` and truncate it to `width - 4` so long file paths do not clip awkwardly.
3. Create a scratch buffer with `buftype = "nofile"`, `bufhidden = "wipe"`, `swapfile = false`, `filetype = "markdown"`, and `vim.b[buf].completion = false` (so completion engines such as `blink.cmp` do not hijack `<CR>`). Populate it with `opts.default` when present.
4. Open the buffer in a centered floating window with `relative = "editor"`, `style = "minimal"`, `border = "rounded"`, `title`, and `title_pos = "center"`. Enable `vim.wo[win].wrap = true` and `vim.wo[win].linebreak = true`. Enter insert mode after the window opens.
5. Add buffer-local mappings:
   - `<CR>` in insert and normal mode submits.
   - `<C-j>` in insert mode inserts a newline.
   - `<Esc>` in insert and normal mode cancels.
6. On submit, collect the buffer lines and trim whitespace first. If the text is empty, notify the user and keep the prompt open.
7. When closing (on valid submit or cancel):
   - Call `vim.cmd("stopinsert")` so closing from insert mode does not leave the user in insert mode in the underlying source buffer.
   - Close the window if valid, delete the buffer if valid, and guard against double cleanup.
   - On valid submit, invoke `on_submit(text)` **after** closing the float so follow-up pickers (such as `fzf-lua`) are not obscured by the prompt window.
8. Keep all prompt code independent of sessions and OpenCode. The callback is the only integration point.

**Verification:**

1. Run `:lua require("opencode_ask.ui").prompt({ title = "test" }, function(text) print("SUBMIT: " .. text) end)`.
2. Type `hello`, press `<C-j>`, type `world`, and press `<CR>`. Expect `SUBMIT: hello\nworld`, and confirm Neovim returns to normal mode.
3. Open the prompt again and press `<Esc>`. Expect the float to close, Neovim to return to normal mode, and `:ls!` to show no scratch buffer.
4. Resize Neovim to a small window and reopen the prompt. Expect the float to remain inside the editor without errors.
5. Once verification passes, commit the Phase 3 changes.

### Phase 4: Resolve and persist sessions

**Intent:** Give the tool continuity by resolving a session once per project and reusing it across Neovim restarts.

**Outcome:** The plugin lists sessions through the OpenCode CLI, offers a picker, stores the choice, and resolves the stored session without prompting on later runs.

**Depends on:** Phases 1 and 2.

**Steps:**

1. Add `lua/opencode_ask/sessions.lua` with these functions:
   - `M.state_path()` returns the configured state path.
   - `M.read_state()` returns a decoded state table, or an empty state table when the file is missing or invalid.
   - `M.write_state(state)` creates the parent directory and writes JSON to a temporary file in the **same directory** (e.g., `state_path .. ".tmp." .. vim.fn.getpid()`), renames it atomically via `vim.uv.fs_rename`, and cleans up the temp file on error. When updating or clearing a single project entry, re-read the latest state file right before writing so concurrent Neovim instances do not clobber each other's entries.
   - `M.parse(json)` decodes `opencode session list --format json` output and validates the array shape.
   - `M.label(session)` formats the title (falling back to `"Untitled"` if missing/empty) and `updated` timestamp. Convert OpenCode's millisecond epoch timestamp to seconds (`math.floor(session.updated / 1000)`) before calling `os.date()`. Append a short session ID suffix so duplicate titles remain distinguishable.
   - `M.list(cwd, callback)` checks `vim.fn.executable` (or wraps `vim.system` in `pcall`) and runs `opencode session list --format json` with `cwd` and `timeout`. Return a descriptive error on missing executable, timeout (`code == 124`), non-zero exit, or invalid JSON.
   - `M.choose(cwd, callback)` lists sessions, returns an actionable error when the list is empty (telling the user to start a session in OpenCode), opens the picker, and stores the selected session under the normalized project key.
   - `M.resolve(cwd, callback)` uses `{ id = config.session }` directly when `config.session` is a string (avoiding an extra `session list` round-trip and avoiding project/count limits; invalid or missing IDs surface cleanly from `client.send()`), otherwise uses the stored session for the project, otherwise calls `M.choose()`.
   - `M.clear(cwd)` removes the stored entry.
2. Use the `fzf-lua` picker when `config.picker == "fzf-lua"` and `pcall(require, "fzf-lua")` succeeds. Use `fzf_exec` with an `actions["enter"]` callback (matching `selected[1]`). Fall back to `vim.ui.select` when `fzf-lua` is unavailable. Align cancellation behavior across both pickers (cancelling with `<Esc>`/`<C-c>` or `choice == nil` is a clean no-op without calling `callback`). Wrap picker calls from `vim.system` callbacks in `vim.schedule`.
3. Store state under `{ version = 1, projects = { [project_root] = { id, title, directory, updated } } }`. Reuse `selection.project_root()` so project keys always match across commands and selections.
4. Do not store prompts, file contents, credentials, or API responses in the state file.
5. Add tests for parsing a sample session list (including millisecond timestamps and missing titles), label formatting, state round-tripping in a temporary directory, and recovery from corrupt JSON. Allow tests to override the state path.

**Verification:**

1. Run `nvim -u tests/minimal_init.lua -l tests/run.lua` and confirm tests pass.
2. From a project with sessions, run `:lua require("opencode_ask.sessions").list(vim.fn.getcwd(), function(err, sessions) print(err, vim.inspect(sessions)) end)` and inspect `:messages`.
3. Run `:lua require("opencode_ask.sessions").resolve(vim.fn.getcwd(), function(err, session) print(err, vim.inspect(session)) end)`. Select a session and inspect the state file at `:lua print(require("opencode_ask.sessions").state_path())`.
4. Restart Neovim and resolve again. Expect the stored session without a picker.
5. Run `:lua require("opencode_ask.sessions").clear(vim.fn.getcwd())` and confirm the entry disappears.
6. Once verification passes, commit the Phase 4 changes.

### Phase 5: Build the OpenCode API client

**Intent:** Isolate the experimental OpenCode API behind one module and prove that it can send a queued question with a file range.

**Outcome:** `client.build_payload()` and `client.send()` work independently of the UI. Payload tests cover single lines and ranges. A manual Lua call sends a question to a chosen session and returns a typed error for a missing session.

**Depends on:** Phases 2 and 4.

**Steps:**

1. Add `lua/opencode_ask/client.lua` with:
   - `M.build_payload(question, context)` returns `{ text = question .. "\n\n" .. context.mention, files = { { uri = context.uri } } }` (optionally adding `mention = { start = ..., end = ..., text = context.mention }` offsets on `files[1]` so the TUI links the `@path#range` span directly to the attachment).
   - `M.send(session, question, context, callback)` checks `vim.fn.executable` (or wraps `vim.system` in `pcall`) and runs `opencode api post /api/session/<id>/prompt --data <json>` with `vim.system`. Set `cwd = session.directory or context.project_root`, `text = true`, and the configured timeout.
   - Parse the result in a `vim.schedule` callback:
     - Return success when `res.code == 0`.
     - Return a clear timeout error when `res.code == 124`.
     - Note that `opencode api` prints the JSON error body to `stdout` and `HTTP <status>` to `stderr`. Decode `res.stdout` when possible and return a typed `session_not_found` error when `_tag == "SessionNotFoundError"` (404) or when `_tag == "InvalidRequestError"` with `field == "sessionID"` (400).
     - Return the parsed error `message`, falling back to `stderr` or `stdout`, for other failures.
2. Add tests for the API payload (single line, range, file URI query parameters, and `@path#range` mention) and error classification (404 `SessionNotFoundError`, 400 invalid `sessionID`, timeout, and generic error) without contacting OpenCode.
3. Do not wire the keymap or user commands in this phase.
4. Do not add response streaming. The API call returns when the message is accepted into the session inbox; the TUI handles execution and permissions.

**Verification:**

1. Run the headless tests and confirm they pass.
2. Start OpenCode in a project with an existing session. In Neovim, select a few lines, resolve the session with `sessions.resolve()`, then call `client.send()` with a test question. Expect the question in the OpenCode TUI with the correct file and range.
3. Run `client.send()` with a missing `ses_...` session ID (e.g., `ses_00000000000000000000000000`). Expect a typed `session_not_found` result and no Lua error.
4. Once verification passes, commit the Phase 5 changes.

### Phase 6: Wire the ask flow, commands, and keymap

**Intent:** Connect the selection, prompt, session, and API modules into the user-facing workflow and add the custom keymap.

**Outcome:** Selecting lines and pressing `<leader>oq` opens the prompt, sends the question with the correct file and line range to the chosen session, and notifies the user. The session survives restart. `:OpencodeAsk`, `:OpencodeSession`, and `:OpencodeSessionClear` work.

**Depends on:** Phases 2, 3, 4, and 5.

**Steps:**

1. Add `M.ask(opts)` to `lua/opencode_ask/init.lua`:
   - Capture the selection through `selection.capture(opts)`. Exit visual mode cleanly before opening the prompt.
   - If `M.options.save` is true and the buffer is modified and read-only, notify and abort before opening the prompt so the user does not lose typed text.
   - Open `ui.prompt({ title = context.ref }, function(question) ... end)`.
   - On submit, call `selection.save(context)`. Abort with a notification when saving fails.
   - Resolve the session through `sessions.resolve(context.project_root, ...)`.
   - Send through `client.send(...)`. Notify `Sent to <title or id>` on success.
   - On `session_not_found`, if `M.options.session` is pinned, notify the user to update `config.session`; otherwise clear the stored session and tell the user to run `:OpencodeSession`.
   - Notify other errors without closing Neovim or leaving windows open.
2. Add `M.select_session()` and `M.clear_session()` to `init.lua`, using `selection.project_root(0)`.
3. Install the visual-only (`"x"`) keymap in `setup()` when `M.options.keymap` is truthy, with a `desc` option.
4. Create `plugin/opencode_ask.lua` guarded with `vim.g.loaded_opencode_ask` and these user commands (each with a `desc`):
   - `:OpencodeAsk` with `range = true`, calling `require("opencode_ask").ask({ first = args.line1, last = args.line2 })`.
   - `:OpencodeSession`, calling `require("opencode_ask").select_session()`.
   - `:OpencodeSessionClear`, calling `require("opencode_ask").clear_session()`.

**Verification:**

1. Run the headless tests and confirm they pass.
2. Start OpenCode in a project and note an existing session, or create one in the TUI.
3. In Neovim, run `:OpencodeSession` and select that session. Confirm the state file contains the ID.
4. Open a source file, select five lines, press `<leader>oq`, ask `What does this code do?`, and press `<CR>`. Expect a `Sent to ...` notification.
5. Switch to the OpenCode TUI. Expect the question in the chosen session with the correct file and line range, and an answer that uses the selected code.
6. Ask a follow-up from a different selection. Expect it to use the same session.
7. Restart Neovim and repeat step 4. Expect the same session without a picker.
8. Replace the stored ID with a missing `ses_...` ID (e.g., `ses_00000000000000000000000000`), send another question, and expect a notification plus a cleared state entry.
9. Once verification passes, commit the Phase 6 changes.

### Phase 7: Health, documentation, and hardening

**Intent:** Make the tool diagnosable and predictable when the environment or a session changes.

**Outcome:** `:checkhealth opencode_ask` reports actionable status, the README documents installation and behavior, and the edge cases produce notifications instead of errors.

**Depends on:** Phase 6.

**Steps:**

1. Add `lua/opencode_ask/health.lua` using `vim.health.start("opencode_ask")`. Run CLI checks synchronously via `vim.system(...):wait()` with a short timeout (not async callbacks). Check:
   - `vim.fn.executable("opencode") == 1`.
   - `opencode api get /api/info` exits successfully.
   - `opencode session list --format json` returns valid JSON.
   - The state directory is writable (and the state file parses as valid JSON if it exists).
   - `fzf-lua` availability (`vim.health.ok` if present, `vim.health.info` noting `vim.ui.select` fallback otherwise).
2. Update `README.md` with:
   - Requirements.
   - `lazy.nvim` `dir` installation and configuration examples (both minimal `opts = {}` and customized `opts`).
   - Full configuration options table (`session`, `keymap`, `save`, `picker`, `state_path`, `api.command`, `api.timeout` with types, defaults, and descriptions), plus a note that `<leader>` resolves to Neovim's default `\` until `vim.g.mapleader` is set.
   - Commands & keymaps reference table (`<leader>oq`, `:OpencodeAsk`, `:OpencodeSession`, `:OpencodeSessionClear`, `:checkhealth opencode_ask`, and prompt controls `<CR>`, `<C-j>`, `<Esc>`).
   - Step-by-step user workflow (first-time use in a project, follow-up questions across Neovim restarts, switching/clearing sessions, and stale-session recovery).
   - The state file path and how to reset a session.
   - The limitation that answers appear in the OpenCode TUI and that prompts sent to an active session are delivered via OpenCode V2's session inbox.
   - Troubleshooting for a missing CLI, stopped service, no sessions, and deleted/invalid sessions.
3. Harden the error paths:
   - Unnamed buffers, non-file buffers, and read-only save failures.
   - Missing `opencode` executable (`pcall` / `executable` guard before `vim.system`).
   - No sessions returned by the CLI.
   - Invalid JSON and corrupt state files.
   - Empty questions.
   - Deleted sessions (`404` `SessionNotFoundError`) and invalid session IDs (`400` `InvalidRequestError` on `sessionID`).
   - API timeouts (`code == 124`) and non-zero exits.
   - Permission requests left for the TUI to resolve.
   - Any UI update from a `vim.system` callback wrapped in `vim.schedule`.
4. Add tests for empty input handling, unnamed buffers, client error classification, and corrupt state recovery where feasible without a UI.

**Verification:**

1. Run `nvim -u tests/minimal_init.lua -l tests/run.lua`. Expect exit status 0.
2. Run `:checkhealth opencode_ask` in Neovim. Expect all checks to pass or show an actionable warning (and confirm plain `:checkhealth` runs it only once).
3. Run the manual end-to-end flow from Phase 6 once more.
4. Run the edge-case checks:
   - Open an unnamed buffer and press the keymap. Expect a notification.
   - Clear the state file and send a question. Expect the picker.
   - Use a deleted `ses_...` session ID. Expect a notification and a cleared entry.
   - Stop the OpenCode service and send a question. Expect a notification, not a Lua error.
5. Confirm the plugin leaves no scratch buffers or floating windows open after success, cancel, or failure.
6. Once verification passes, commit the Phase 7 changes.

## Acceptance

- The plugin lives in its own repository and the dotfiles contain only the lazy.nvim spec.
- A visual selection plus `<leader>oq` collects a question and sends the correct file and line range to the chosen OpenCode session.
- The same session is reused after a Neovim restart.
- Session selection, clearing, and stale-session recovery work.
- The popup closes cleanly on submit, cancel, and failure, leaving Neovim in normal mode.
- Headless tests pass and `:checkhealth opencode_ask` is useful.
- Answers are read in the OpenCode TUI; no response streaming is implemented.

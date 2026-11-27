local config = require("opencode_ask.config")
local selection = require("opencode_ask.selection")
local sessions = require("opencode_ask.sessions")
local client = require("opencode_ask.client")
local ui = require("opencode_ask.ui")

local M = {}

M.options = config.merge({})

local PREFIX = "opencode-ask: "

--- The keymaps installed by the most recent setup() call, if any.
local installed_keymaps = {}

local function describe(err)
  if type(err) == "table" then
    local message = err.message
    if type(message) == "string" and message ~= "" then
      return message
    end
    return vim.inspect(err)
  end
  if type(err) == "string" and err ~= "" then
    return err
  end
  return tostring(err)
end

local function with_prefix(message)
  message = describe(message)
  if message:sub(1, #PREFIX) == PREFIX then
    return message
  end
  return PREFIX .. message
end

local function notify(message, level)
  vim.notify(with_prefix(message), level)
end

local function session_label(session)
  if type(session) ~= "table" then
    return "session"
  end

  local title = type(session.title) == "string" and vim.trim(session.title) or ""
  if title ~= "" then
    return title
  end

  return type(session.id) == "string" and session.id ~= "" and session.id or "session"
end

--- Exit visual mode before opening a prompt, so the prompt is not obscured by
--- the still-active visual selection and the selection marks stay usable.
local function leave_visual_mode()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode:sub(1, 1) == "\22" then
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  end
end

--- Abort before opening the prompt when saving the captured buffer is possible
--- but would fail. Otherwise typed question text would be lost on submit.
local function unsavable_buffer(context)
  if not M.options.save then
    return false
  end

  local bufnr = context.bufnr or 0
  local ok, current = pcall(function()
    return {
      modified = vim.bo[bufnr].modified,
      readonly = vim.bo[bufnr].readonly,
      modifiable = vim.bo[bufnr].modifiable,
    }
  end)
  if not ok then
    return false
  end

  return current.modified and (current.readonly or current.modifiable == false)
end

local function handle_session_not_found(err, context)
  local detail = describe(err)

  if type(M.options.session) == "string" then
    notify(
      ("%s The session is pinned by config.session; update config.session to use another session."):format(detail),
      vim.log.levels.WARN
    )
    return
  end

  local cleared, clear_err = sessions.clear(context.project_root)
  local message
  if cleared then
    message = ("%s The stored session was cleared; run :OpencodeSession to choose another."):format(detail)
  else
    message = ("%s Could not clear the stored session (%s); run :OpencodeSession to choose another."):format(
      detail,
      describe(clear_err or "unknown error")
    )
  end
  notify(message, vim.log.levels.WARN)
end

local function handle_send_error(err, context)
  if type(err) == "table" and err.kind == "session_not_found" then
    handle_session_not_found(err, context)
    return
  end

  notify(err, vim.log.levels.WARN)
end

--- Ask OpenCode about the selected lines.
---
--- opts may contain bufnr, first, and last (see selection.capture). The
--- selection is captured immediately so the mapping can be invoked from visual
--- mode; the prompt and all later work happen after leaving visual mode.
function M.ask(opts)
  local context, capture_err = selection.capture(opts)
  if not context then
    notify(capture_err or "could not capture the selection", vim.log.levels.WARN)
    return
  end

  leave_visual_mode()

  local src_win = vim.api.nvim_get_current_win()

  if unsavable_buffer(context) then
    notify(
      "the buffer is read-only or not modifiable and has unsaved changes; save the changes before asking",
      vim.log.levels.WARN
    )
    return
  end

  local ui_opts = M.options.ui or {}
  local anchor = nil
  if ui_opts.position ~= "center" and vim.api.nvim_win_is_valid(src_win) then
    local buf_ok, src_bufnr = pcall(vim.api.nvim_win_get_buf, src_win)
    if buf_ok and src_bufnr == context.bufnr then
      anchor = ui._measure_anchor(src_win, context.first, context.last)
    end
  end

  local prompt_opts = {
    title = context.ref,
    width = ui_opts.width,
    height = ui_opts.height,
    border = ui_opts.border,
    position = ui_opts.position,
    winblend = ui_opts.winblend,
    anchor = anchor,
    highlight = {
      bufnr = context.bufnr,
      first = context.first,
      last = context.last,
    },
  }

  local prompted, prompt_err = pcall(ui.prompt, prompt_opts, function(question)
    local saved, save_err = selection.save(context)
    if not saved then
      notify(save_err or "could not save the buffer", vim.log.levels.WARN)
      return
    end

    sessions.resolve(context.project_root, function(resolve_err, session)
      if resolve_err then
        notify(resolve_err, vim.log.levels.WARN)
        return
      end
      if type(session) ~= "table" then
        notify("could not resolve an OpenCode session", vim.log.levels.WARN)
        return
      end

      client.send(session, question, context, function(send_err)
        if send_err then
          handle_send_error(send_err, context)
          return
        end
        notify(
          ("Sent to %s (%s)"):format(session_label(session), context.ref),
          vim.log.levels.INFO
        )
      end)
    end)
  end)

  if not prompted then
    notify("could not open the question prompt: " .. describe(prompt_err), vim.log.levels.WARN)
  end
end

--- Pick and store the OpenCode session for the current project.
function M.select_session()
  local root = selection.project_root(0)

  sessions.choose(root, function(err, session)
    if err then
      notify(err, vim.log.levels.WARN)
      return
    end
    if type(session) ~= "table" then
      return
    end

    notify(("Selected OpenCode session: %s"):format(session_label(session)), vim.log.levels.INFO)
  end)
end

--- Remove the stored OpenCode session for the current project.
function M.clear_session()
  local root = selection.project_root(0)
  local cleared, clear_err = sessions.clear(root)

  if not cleared then
    notify(clear_err or "could not clear the stored session", vim.log.levels.WARN)
    return
  end

  notify(("Cleared the stored OpenCode session for %s"):format(root), vim.log.levels.INFO)
end

--- Toggle the OpenCode session viewer for the current project.
---
--- The viewer is wired up in a later phase; this entry point exists so the
--- toggle command and keymap can be registered now.
function M.toggle()
  return nil
end

--- Remove the mappings installed by a previous setup() call.
---
--- Only delete a mapping when it is still the callback this plugin
--- installed, so a mapping the user has since replaced is left alone.
local function uninstall_keymaps()
  local installed = installed_keymaps
  installed_keymaps = {}

  for _, entry in ipairs(installed) do
    local ok, mapping = pcall(vim.fn.maparg, entry.lhs, entry.mode, false, true)
    if ok and type(mapping) == "table" and mapping.callback == entry.callback then
      pcall(vim.keymap.del, entry.mode, entry.lhs)
    end
  end
end

--- Apply configuration and install the ask and viewer toggle keymaps.
function M.setup(opts)
  local merged = config.merge(opts)

  uninstall_keymaps()
  M.options = merged

  local keymaps = {}

  if M.options.keymap then
    local callback = function()
      M.ask()
    end
    vim.keymap.set("x", M.options.keymap, callback, {
      desc = "Ask OpenCode about the visual selection",
    })
    keymaps[#keymaps + 1] = { mode = "x", lhs = M.options.keymap, callback = callback }
  end

  local viewer_opts = M.options.viewer or {}
  if viewer_opts.keymap then
    local callback = function()
      M.toggle()
    end
    vim.keymap.set("n", viewer_opts.keymap, callback, {
      desc = "Toggle the OpenCode session viewer",
    })
    keymaps[#keymaps + 1] = { mode = "n", lhs = viewer_opts.keymap, callback = callback }
  end

  installed_keymaps = keymaps
  return M.options
end

return M

local client = require("opencode_ask.client")

local MISSING_SESSION_JSON =
  '{"_tag":"SessionNotFoundError","sessionID":"ses_missing","message":"Session not found: ses_missing"}'

local function with_options(changes, fn)
  local options = require("opencode_ask").options
  local saved = {}
  for key in pairs(changes) do
    saved[key] = options[key]
  end
  for key, value in pairs(changes) do
    options[key] = value
  end

  local ok, err = pcall(fn)

  for key in pairs(changes) do
    options[key] = saved[key]
  end
  if not ok then
    error(err, 0)
  end
end

local function with_stub(owner, key, value, fn)
  local original = owner[key]
  owner[key] = value
  local ok, err = pcall(fn)
  owner[key] = original
  if not ok then
    error(err, 0)
  end
end

local function project_context()
  return {
    bufnr = 1,
    absolute = "/tmp/project/src/ask.lua",
    relative = "src/ask.lua",
    project_root = "/tmp/project",
    first = 3,
    last = 7,
    ref = "src/ask.lua:3-7",
    mention = "@src/ask.lua#3-7",
    uri = "file:///tmp/project/src/ask.lua?start=3&end=7",
  }
end

--- Run client.send with a stubbed vim.system and wait for its callback.
--- Returns calls, err, response, argv, system_opts.
local function run_send(session, question, context, system_stub, api)
  local calls = 0
  local got_err, got_response
  local argv, system_opts
  local finished = false

  with_options({ api = api }, function()
    with_stub(vim, "system", function(cmd, opts, on_exit)
      argv = cmd
      system_opts = opts
      return system_stub(cmd, opts, on_exit)
    end, function()
      local ok, call_err = pcall(client.send, session, question, context, function(err, response)
        calls = calls + 1
        got_err = err
        got_response = response
        finished = true
      end)

      if not ok then
        error("send threw: " .. tostring(call_err), 0)
      end
      if not vim.wait(2000, function()
        return finished
      end, 10) then
        error("send callback did not run", 0)
      end

      -- Give a mistakenly queued second callback a chance to surface.
      vim.wait(20)
    end)
  end)

  return calls, got_err, got_response, argv, system_opts
end

--- Run client.create_session with a stubbed vim.system and wait for its callback.
--- Returns calls, err, session, argv, system_opts.
local function run_create(cwd, title, system_stub, api)
  local calls = 0
  local got_err, got_session
  local argv, system_opts
  local finished = false

  with_options({ api = api }, function()
    with_stub(vim, "system", function(cmd, opts, on_exit)
      argv = cmd
      system_opts = opts
      return system_stub(cmd, opts, on_exit)
    end, function()
      local ok, call_err = pcall(client.create_session, cwd, title, function(err, session)
        calls = calls + 1
        got_err = err
        got_session = session
        finished = true
      end)

      if not ok then
        error("create_session threw: " .. tostring(call_err), 0)
      end
      if not vim.wait(2000, function()
        return finished
      end, 10) then
        error("create_session callback did not run", 0)
      end

      -- Give a mistakenly queued second callback a chance to surface.
      vim.wait(20)
    end)
  end)

  return calls, got_err, got_session, argv, system_opts
end

local function expect_build_error(question, context)
  local ok, payload, err = pcall(client.build_payload, question, context)
  return ok, payload, err
end

return function(t)
  t.test("build_payload builds a single-line request", function()
    local context = {
      project_root = "/tmp/project",
      mention = "@init.lua#7",
      uri = "file:///tmp/project/init.lua?start=7&end=7",
    }
    local question = "What does this do?"

    local payload, err = client.build_payload(question, context)

    t.equal(nil, err)
    t.equal("What does this do?\n\n@init.lua#7", payload.text)
    t.equal(1, #payload.files)
    t.equal("file:///tmp/project/init.lua?start=7&end=7", payload.files[1].uri)
    t.equal("@init.lua#7", payload.files[1].mention.text)
    t.equal(#question + 2, payload.files[1].mention.start)
    t.equal(#question + 2 + #context.mention, payload.files[1].mention["end"])
  end)

  t.test("build_payload builds a range request with an encoded URI", function()
    local context = {
      project_root = "/tmp/my project",
      mention = "@src/a file.lua#3-9",
      uri = "file:///tmp/my%20project/src/a%20file.lua?start=3&end=9",
    }
    local question = "Explain lines 3 through 9"

    local payload, err = client.build_payload(question, context)

    t.equal(nil, err)
    t.equal("Explain lines 3 through 9\n\n@src/a file.lua#3-9", payload.text)
    t.equal("file:///tmp/my%20project/src/a%20file.lua?start=3&end=9", payload.files[1].uri)
    t.equal("@src/a file.lua#3-9", payload.files[1].mention.text)
    local expected_start = #question + 2
    t.equal(expected_start, payload.files[1].mention.start)
    t.equal(expected_start + #context.mention, payload.files[1].mention["end"])
  end)

  t.test("build_payload counts multibyte text in UTF-16 code units", function()
    local question = "Why 😀?"
    local mention = "@src/é.lua#1-2"
    local context = {
      project_root = "/tmp/project",
      mention = mention,
      uri = "file:///tmp/project/src/%C3%A9.lua?start=1&end=2",
    }

    local payload, err = client.build_payload(question, context)

    local _, question16 = vim.str_utfindex(question)
    local _, mention16 = vim.str_utfindex(mention)
    local expected_start = question16 + 2

    t.equal(nil, err)
    t.equal(question .. "\n\n" .. mention, payload.text)
    t.equal(expected_start, payload.files[1].mention.start)
    t.equal(expected_start + mention16, payload.files[1].mention["end"])
    t.equal(mention, payload.files[1].mention.text)
  end)

  t.test("build_payload rejects invalid inputs without throwing", function()
    local valid_context = {
      mention = "@a.lua#1",
      uri = "file:///tmp/a.lua?start=1&end=1",
    }
    local cases = {
      { question = nil, context = valid_context, pattern = "question" },
      { question = 42, context = valid_context, pattern = "question" },
      { question = "", context = valid_context, pattern = "empty" },
      { question = "   ", context = valid_context, pattern = "empty" },
      { question = "Why?", context = nil, pattern = "context" },
      { question = "Why?", context = {}, pattern = "URI" },
      { question = "Why?", context = { uri = "file:///tmp/a.lua" }, pattern = "mention" },
      { question = "Why?", context = { mention = "@a.lua#1" }, pattern = "URI" },
      { question = "Why?", context = { uri = 42, mention = "@a.lua#1" }, pattern = "URI" },
      { question = "Why?", context = { uri = "file:///tmp/a.lua", mention = 42 }, pattern = "mention" },
    }

    for _, case in ipairs(cases) do
      local ok, payload, err = expect_build_error(case.question, case.context)
      t.assert(ok, "build_payload should not throw")
      t.equal(nil, payload)
      t.matches(case.pattern, err)
      t.matches("^opencode%-ask: ", err)
    end
  end)

  t.test("classify returns the decoded body on success", function()
    local err, body = client.classify({
      code = 0,
      stdout = '{"data":{"id":"msg_queued"},"accepted":true}',
      stderr = "",
    })
    t.equal(nil, err)
    t.equal("msg_queued", body.data.id)
    t.equal(true, body.accepted)
  end)

  t.test("classify treats empty and malformed success output as true", function()
    for _, stdout in ipairs({ "", "   ", "not json" }) do
      local err, body = client.classify({ code = 0, stdout = stdout, stderr = "" })
      t.equal(nil, err)
      t.equal(true, body)
    end
  end)

  t.test("classify reports timeouts with the configured timeout", function()
    with_options({ api = { command = "opencode", timeout = 4321 } }, function()
      local err, body = client.classify({ code = 124, stdout = "", stderr = "" })

      t.equal(nil, body)
      t.equal("timeout", err.kind)
      t.equal(124, err.code)
      t.equal(4321, err.timeout)
      t.matches("timed out", err.message)
      t.matches("4321", err.message)

      -- Without a configured timeout the message still identifies the failure.
      with_options({ api = { command = "opencode", timeout = nil } }, function()
        local no_timeout, _ = client.classify({ code = 124, stdout = "", stderr = "" })
        t.equal("timeout", no_timeout.kind)
        t.matches("timed out", no_timeout.message)
      end)
    end)
  end)

  t.test("classify maps SessionNotFoundError to session_not_found", function()
    local err, body = client.classify({
      code = 1,
      stdout = MISSING_SESSION_JSON,
      stderr = "HTTP 404 Not Found",
    })

    t.equal(nil, body)
    t.equal("session_not_found", err.kind)
    t.equal(1, err.code)
    t.equal("ses_missing", err.session_id)
    t.equal("SessionNotFoundError", err.body._tag)
    t.matches("Session not found: ses_missing", err.message)
  end)

  t.test("classify maps an invalid sessionID to session_not_found", function()
    local err, body = client.classify({
      code = 1,
      stdout = '{"_tag":"InvalidRequestError","field":"sessionID","message":"Invalid sessionID"}',
      stderr = "HTTP 400 Bad Request",
    })

    t.equal(nil, body)
    t.equal("session_not_found", err.kind)
    t.equal("InvalidRequestError", err.body._tag)
    t.equal("sessionID", err.body.field)
    t.matches("Invalid sessionID", err.message)
  end)

  t.test("classify reports generic JSON errors from parsed messages", function()
    local err, body = client.classify({
      code = 1,
      stdout = '{"_tag":"BadRequestError","message":"text must not be empty"}',
      stderr = "HTTP 400 Bad Request",
    })

    t.equal(nil, body)
    t.equal("api_error", err.kind)
    t.equal("text must not be empty", err.message)
    t.equal("BadRequestError", err.body._tag)

    err, body = client.classify({
      code = 1,
      stdout = '{"message":"upstream exploded"}',
      stderr = "HTTP 500 Internal Server Error",
    })
    t.equal(nil, body)
    t.equal("api_error", err.kind)
    t.equal("upstream exploded", err.message)
    t.equal("upstream exploded", err.body.message)
  end)

  t.test("classify falls back to stderr, stdout, then the exit code", function()
    local err = client.classify({
      code = 1,
      stdout = "not json",
      stderr = "HTTP 500 Internal Server Error\n",
    })
    t.equal("api_error", err.kind)
    t.equal("HTTP 500 Internal Server Error", err.message)

    err = client.classify({ code = 1, stdout = "plain output", stderr = "" })
    t.equal("api_error", err.kind)
    t.equal("plain output", err.message)

    err = client.classify({ code = 1, stdout = "", stderr = "" })
    t.equal("api_error", err.kind)
    t.equal("opencode api exited with code 1", err.message)
  end)

  t.test("classify rejects malformed results without throwing", function()
    for _, result in ipairs({ {}, { code = "1" }, { code = nil, stdout = "{}" } }) do
      local ok, err = pcall(client.classify, result)
      t.assert(ok, "classify should not throw")
      t.equal("invalid_result", err.kind)
      t.matches("invalid result", err.message)
    end

    local ok, err = pcall(client.classify, nil)
    t.assert(ok, "classify should not throw for nil")
    t.equal("invalid_result", err.kind)
  end)

  t.test("send posts the payload with the session directory and configured options", function()
    local context = project_context()
    local question = "Explain this range"
    local expected_payload = client.build_payload(question, context)

    local calls, err, response, argv, opts = run_send(
      { id = "ses_test", directory = "/session/dir" },
      question,
      context,
      function(_, _, on_exit)
        on_exit({ code = 0, stdout = '{"accepted":true,"data":{"id":"msg_queued"}}', stderr = "" })
        return { pid = 0 }
      end,
      { command = vim.v.progpath, timeout = 1234 }
    )

    t.equal(1, calls, "the callback should run exactly once")
    t.equal(nil, err)
    t.equal(true, response.accepted)
    t.equal("msg_queued", response.data.id)
    t.equal(6, #argv)
    t.equal(vim.v.progpath, argv[1])
    t.equal("api", argv[2])
    t.equal("post", argv[3])
    t.equal("/api/session/ses_test/prompt", argv[4])
    t.equal("--data", argv[5])
    t.equal(expected_payload, vim.json.decode(argv[6]))
    t.equal("/session/dir", opts.cwd)
    t.equal(true, opts.text)
    t.equal(1234, opts.timeout)
  end)

  t.test("send falls back to context.project_root for cwd", function()
    local calls, err, _, _, opts = run_send(
      { id = "ses_test" },
      "Why?",
      project_context(),
      function(_, _, on_exit)
        on_exit({ code = 0, stdout = "{}", stderr = "" })
        return { pid = 0 }
      end,
      { command = vim.v.progpath, timeout = 1234 }
    )

    t.equal(1, calls)
    t.equal(nil, err)
    t.equal("/tmp/project", opts.cwd)
  end)

  t.test("send returns a typed timeout error exactly once", function()
    local calls, err, response = run_send(
      { id = "ses_test" },
      "Why?",
      project_context(),
      function(_, _, on_exit)
        on_exit({ code = 124, stdout = "", stderr = "" })
        return { pid = 0 }
      end,
      { command = vim.v.progpath, timeout = 5555 }
    )

    t.equal(1, calls)
    t.equal(nil, response)
    t.equal("timeout", err.kind)
    t.equal(5555, err.timeout)
    t.matches("5555", err.message)
  end)

  t.test("send returns session_not_found for a missing session", function()
    local calls, err, response = run_send(
      { id = "ses_missing" },
      "Why?",
      project_context(),
      function(_, _, on_exit)
        on_exit({
          code = 1,
          stdout = MISSING_SESSION_JSON,
          stderr = "HTTP 404 Not Found",
        })
        return { pid = 0 }
      end,
      { command = vim.v.progpath, timeout = 1234 }
    )

    t.equal(1, calls)
    t.equal(nil, response)
    t.equal("session_not_found", err.kind)
    t.equal("ses_missing", err.session_id)
    t.equal("SessionNotFoundError", err.body._tag)
  end)

  t.test("send reports a missing executable as a typed error", function()
    local calls, err = run_send(
      { id = "ses_test" },
      "Why?",
      project_context(),
      function()
        error("vim.system should not be called when the command is missing")
      end,
      { command = "opencode-ask-missing-cli-for-tests", timeout = 1234 }
    )

    t.equal(1, calls)
    t.equal("executable_not_found", err.kind)
    t.equal("opencode-ask-missing-cli-for-tests", err.command)
    t.matches("not executable", err.message)
  end)

  t.test("send reports a spawn failure as a typed error without throwing", function()
    local calls, err = run_send(
      { id = "ses_test" },
      "Why?",
      project_context(),
      function()
        error("spawn exploded")
      end,
      { command = vim.v.progpath, timeout = 1234 }
    )

    t.equal(1, calls)
    t.equal("spawn_error", err.kind)
    t.matches("spawn exploded", err.message)
  end)

  t.test("send validates the question, context, and session before spawning", function()
    local cases = {
      {
        session = { id = "ses_test" },
        question = nil,
        context = project_context(),
        pattern = "question",
      },
      {
        session = { id = "ses_test" },
        question = "Why?",
        context = nil,
        pattern = "context",
      },
      {
        session = {},
        question = "Why?",
        context = project_context(),
        pattern = "session id",
      },
      {
        session = nil,
        question = "Why?",
        context = project_context(),
        pattern = "session",
      },
    }

    for _, case in ipairs(cases) do
      local calls, err = run_send(case.session, case.question, case.context, function()
        error("vim.system should not be called for invalid input")
      end, { command = vim.v.progpath, timeout = 1234 })

      t.equal(1, calls, "invalid input should still call back exactly once")
      t.matches(case.pattern, err)
    end
  end)

  t.test("create_session posts the trimmed payload with configured options", function()
    local expected_payload = {
      title = "New session",
      location = { directory = "/tmp/my project" },
    }
    local expected_encoded = vim.json.encode(expected_payload)

    local calls, err, session, argv, opts = run_create(
      "/tmp/my project",
      "  New session  ",
      function(_, _, on_exit)
        on_exit({
          code = 0,
          stdout = '{"data":{"id":"ses_created","title":"New session","location":{"directory":"/tmp/my project"},"time":{"updated":1700000000123}}}',
          stderr = "",
        })
        return { pid = 0 }
      end,
      { command = vim.v.progpath, timeout = 4321 }
    )

    t.equal(1, calls, "the callback should run exactly once")
    t.equal(nil, err)
    t.equal("ses_created", session.id)
    t.equal("New session", session.title)
    t.equal("/tmp/my project", session.directory)
    t.equal(1700000000123, session.updated)

    t.equal(6, #argv)
    t.equal(vim.v.progpath, argv[1])
    t.equal("api", argv[2])
    t.equal("post", argv[3])
    t.equal("/api/session", argv[4])
    t.equal("--data", argv[5])
    t.equal(expected_encoded, argv[6])
    t.equal(expected_payload, vim.json.decode(argv[6]))
    t.equal("/tmp/my project", opts.cwd)
    t.equal(true, opts.text)
    t.equal(4321, opts.timeout)
  end)

  t.test("create_session falls back to the request values for missing response metadata", function()
    local before = os.time() * 1000

    local calls, err, session = run_create(
      "/tmp/project",
      "Fallback title",
      function(_, _, on_exit)
        on_exit({ code = 0, stdout = '{"data":{"id":"ses_created"}}', stderr = "" })
        return { pid = 0 }
      end,
      { command = vim.v.progpath, timeout = 1234 }
    )

    local after = os.time() * 1000

    t.equal(1, calls)
    t.equal(nil, err)
    t.equal("ses_created", session.id)
    t.equal("Fallback title", session.title)
    t.equal("/tmp/project", session.directory)
    t.assert(session.updated >= before, "updated should fall back to the current time")
    t.assert(session.updated <= after, "updated should fall back to the current time")

    calls, err, session = run_create(
      "/tmp/project",
      "Fallback title",
      function(_, _, on_exit)
        on_exit({
          code = 0,
          stdout = '{"data":{"id":"ses_created","title":"   ","location":{"directory":"  "}}}',
          stderr = "",
        })
        return { pid = 0 }
      end,
      { command = vim.v.progpath, timeout = 1234 }
    )

    t.equal(1, calls)
    t.equal(nil, err)
    t.equal("Fallback title", session.title)
    t.equal("/tmp/project", session.directory)
  end)

  t.test("create_session rejects responses without a usable session id", function()
    local outputs = {
      "{}",
      '{"data":{}}',
      '{"data":{"id":""}}',
      '{"data":{"id":"   "}}',
      '{"data":{"title":"No id"}}',
      "not json",
      "",
    }

    for _, stdout in ipairs(outputs) do
      local calls, err, session = run_create(
        "/tmp/project",
        "Title",
        function(_, _, on_exit)
          on_exit({ code = 0, stdout = stdout, stderr = "" })
          return { pid = 0 }
        end,
        { command = vim.v.progpath, timeout = 1234 }
      )

      t.equal(1, calls, "invalid responses should call back exactly once")
      t.equal(nil, session)
      t.equal("invalid_response", err.kind)
      t.equal("opencode api post /api/session did not return a session id", err.message)
    end
  end)

  t.test("create_session returns a typed timeout error exactly once", function()
    local calls, err, session = run_create(
      "/tmp/project",
      "Title",
      function(_, _, on_exit)
        on_exit({ code = 124, stdout = "", stderr = "" })
        return { pid = 0 }
      end,
      { command = vim.v.progpath, timeout = 5555 }
    )

    t.equal(1, calls)
    t.equal(nil, session)
    t.equal("timeout", err.kind)
    t.equal(5555, err.timeout)
    t.matches("5555", err.message)
  end)

  t.test("create_session returns API errors with the decoded message", function()
    local calls, err, session = run_create(
      "/tmp/project",
      "Title",
      function(_, _, on_exit)
        on_exit({
          code = 1,
          stdout = '{"message":"title is invalid"}',
          stderr = "HTTP 400 Bad Request",
        })
        return { pid = 0 }
      end,
      { command = vim.v.progpath, timeout = 1234 }
    )

    t.equal(1, calls)
    t.equal(nil, session)
    t.equal("api_error", err.kind)
    t.equal("title is invalid", err.message)
  end)

  t.test("create_session reports a missing executable as a typed error", function()
    local calls, err = run_create(
      "/tmp/project",
      "Title",
      function()
        error("vim.system should not be called when the command is missing")
      end,
      { command = "opencode-ask-missing-cli-for-tests", timeout = 1234 }
    )

    t.equal(1, calls)
    t.equal("executable_not_found", err.kind)
    t.equal("opencode-ask-missing-cli-for-tests", err.command)
    t.matches("not executable", err.message)
  end)

  t.test("create_session reports a spawn failure as a typed error without throwing", function()
    local calls, err = run_create(
      "/tmp/project",
      "Title",
      function()
        error("spawn exploded")
      end,
      { command = vim.v.progpath, timeout = 1234 }
    )

    t.equal(1, calls)
    t.equal("spawn_error", err.kind)
    t.matches("spawn exploded", err.message)
  end)

  t.test("create_session validates cwd and title before spawning", function()
    local cases = {
      { cwd = nil, title = "Title", pattern = "cwd" },
      { cwd = 42, title = "Title", pattern = "cwd" },
      { cwd = "", title = "Title", pattern = "cwd" },
      { cwd = "   ", title = "Title", pattern = "cwd" },
      { cwd = "/tmp/project", title = nil, pattern = "title" },
      { cwd = "/tmp/project", title = 42, pattern = "title" },
      { cwd = "/tmp/project", title = "", pattern = "title" },
      { cwd = "/tmp/project", title = "   ", pattern = "title" },
    }

    for _, case in ipairs(cases) do
      local calls, err = run_create(case.cwd, case.title, function()
        error("vim.system should not be called for invalid input")
      end, { command = vim.v.progpath, timeout = 1234 })

      t.equal(1, calls, "invalid input should still call back exactly once")
      t.matches(case.pattern, err)
      t.matches("^opencode%-ask: ", err)
    end
  end)

  t.test("create_session does not throw for a non-function callback", function()
    for _, callback in ipairs({ true, "callback" }) do
      with_options({ api = { command = vim.v.progpath, timeout = 1234 } }, function()
        with_stub(vim, "system", function(_, _, on_exit)
          on_exit({ code = 0, stdout = '{"data":{"id":"ses_created"}}', stderr = "" })
          return { pid = 0 }
        end, function()
          local ok, call_err = pcall(client.create_session, "/tmp/project", "Title", callback)
          t.assert(ok, "create_session should not throw: " .. tostring(call_err))
          vim.wait(20)
        end)
      end)
    end

    with_options({ api = { command = vim.v.progpath, timeout = 1234 } }, function()
      with_stub(vim, "system", function(_, _, on_exit)
        on_exit({ code = 0, stdout = '{"data":{"id":"ses_created"}}', stderr = "" })
        return { pid = 0 }
      end, function()
        local ok, call_err = pcall(client.create_session, "/tmp/project", "Title")
        t.assert(ok, "create_session should not throw without a callback: " .. tostring(call_err))
        vim.wait(20)
      end)
    end)
  end)
end

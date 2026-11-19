local here = (debug.getinfo(1, "S").source or ""):gsub("^@", ""):match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local t = require("helper")
local json = require("json")
local fake = require("fake_rex").install()

local MAIN, FIX, FEAT = "/src/app", "/src/app.fix", "/src/app.feat"

local SMALL_LIST = [[{
  "schema": 2,
  "items": [
    {
      "branch": "main",
      "worktree": {
        "path": "/src/app",
        "main": true,
        "current": true,
        "changes": { "modified": true }
      }
    },
    {
      "branch": "fix/login",
      "worktree": {
        "path": "/src/app.fix/",
        "main": false,
        "current": false,
        "prunable": { "reason": "gone" },
        "changes": null
      }
    },
    {
      "branch": "feat/diff",
      "worktree": {
        "path": "/src/app.feat",
        "main": false,
        "current": false,
        "changes": { "diff": { "added": 2, "deleted": 0 } }
      }
    },
    {
      "branch": null,
      "worktree": { "path": "/src/detached", "detached": true }
    }
  ]
}]]

local function fresh(opts)
  fake:reset()
  fake.dirs = { [MAIN] = true, [FIX] = true, [FEAT] = true }
  fake.cwd = MAIN
  return t.load_plugin(opts)
end

local function ctx(session_id)
  return { origin = "key", session_id = session_id, block_id = "block:1" }
end

local function answer(value, why, detail)
  return { value = value, why = why, detail = detail }
end

local function is_wt(argv)
  local prog = argv and argv[1]
  return prog == "wt" or (type(prog) == "string" and prog:match("/wt$") ~= nil)
end

local function wt_calls()
  local found = {}
  for _, call in ipairs(fake:calls_to("exec")) do
    if is_wt(call.args.argv) then found[#found + 1] = call end
  end
  return found
end

local function has(argv, value)
  for _, v in ipairs(argv) do
    if v == value then return true end
  end
  return false
end

local function effects()
  local names = {}
  for _, call in ipairs(fake.calls) do
    if call.name == "exec" and is_wt(call.args.argv) then
      names[#names + 1] = "wt " .. tostring(call.args.argv[2])
    elseif call.name == "ui.pick" or call.name == "ui.input"
      or call.name == "session.create" or call.name == "client.queue" then
      names[#names + 1] = call.name
    end
  end
  return names
end

local function stub(list_stdout, switch)
  fake.wt = function(argv)
    if argv[2] == "list" then
      return { ok = true, code = 0, stdout = list_stdout, stderr = "" }
    end
    if type(switch) == "function" then return switch(argv) end
    return switch
  end
end

local function run(session_id)
  return fake.actions.worktree.run(ctx(session_id))
end

t.section("the json stand-in used for wt output")

do
  local value, err = json.decode('{"ok":false,"n":null,"row":[1,null,2],"esc":"\\u001bX"}')
  t.check("drops nulls and decodes unicode escapes",
    value and value.ok == false and value.n == nil and value.row[1] == 1 and value.row[2] == 2
      and value.esc == "\027X", err)
  local sample, serr = json.decode(assert(io.open(here .. "/fixtures/wt-list-sample.json", "r")):read("*a"))
  t.check("decodes the schema 2 list fixture",
    sample and sample.schema == 2 and #sample.items == 6, serr)
end

t.section("listing worktrees")

do
  fresh()
  stub(SMALL_LIST, { ok = true, code = 0, stdout = "", stderr = "" })
  fake.ui_answers = { answer(nil, "cancelled") }
  run(fake:add_session("home"))
  local pick = fake:calls_to("ui.pick")[1]
  local items = pick.args.items
  t.check("asks with the worktree picker",
    pick.args.title == "Worktree" and pick.args.placeholder == "Filter worktrees")
  t.check("lists switchable rows, then New worktree",
    #items == 4
      and items[1].id == MAIN and items[1].title == "main" and items[1].icon == "folder"
      and items[1].detail == "current, dirty" and items[1].subtitle == MAIN
      and items[1].selected == true
      and items[2].id == FIX and items[2].title == "fix/login" and items[2].icon == "branch"
      and items[2].detail == "prunable" and items[2].selected == nil
      and items[3].id == FEAT and items[3].title == "feat/diff" and items[3].detail == "dirty"
      and items[4].id == "new" and items[4].title == "New worktree…" and items[4].icon == "plus",
    items[4] and items[4].title)
  t.check("runs wt list in the focused terminal",
    wt_calls()[1].args.cwd == MAIN and has(wt_calls()[1].args.argv, "--format=json")
      and wt_calls()[1].args.argv[2] == "list")
end

do
  fresh()
  fake.env.HOME = "/Users/athulramesh"
  local sample = assert(io.open(here .. "/fixtures/wt-list-sample.json", "r")):read("*a")
  stub(sample, { ok = true, code = 0, stdout = "", stderr = "" })
  fake.ui_answers = { answer(nil, "cancelled") }
  run(fake:add_session("home"))
  fake.env.HOME = nil
  local items = fake:calls_to("ui.pick")[1].args.items
  t.check("shows the sample list with the home directory shortened",
    #items == 7
      and items[1].title == "main" and items[1].icon == "folder" and items[1].detail == "current"
      and items[1].subtitle == "~/projects/rexproject/rex-agent.nvim"
      and items[2].title == "fix/open-seed-ready" and items[2].detail == "prunable"
      and items[2].subtitle == "/private/tmp/rex-agent-open-seed-ready"
      and items[7].title == "New worktree…" and items[7].icon == "plus")
end

do
  fresh()
  stub('{"schema":2,"items":[]}', { ok = true, code = 0, stdout = "", stderr = "" })
  fake.ui_answers = { answer(nil, "cancelled") }
  run(fake:add_session("home"))
  local items = fake:calls_to("ui.pick")[1].args.items
  t.check("an empty repo still offers New worktree",
    #items == 1 and items[1].id == "new")
end

do
  fresh()
  local dup = [[{"schema":2,"items":[
    {"branch":"one","worktree":{"path":"/src/app.fix","main":false,"current":false}},
    {"branch":"two","worktree":{"path":"/src/app.fix","main":false,"current":false}}
  ]}]]
  stub(dup, { ok = true, code = 0, stdout = "", stderr = "" })
  fake.ui_answers = { answer(nil, "cancelled") }
  run(fake:add_session("home"))
  local items = fake:calls_to("ui.pick")[1].args.items
  t.check("keeps one row when two items share a path",
    #items == 2 and items[1].id == FIX and items[1].title == "one")
end

t.section("switching to the chosen worktree")

do
  fresh()
  fake.cwd = "/src/app/src"
  stub(SMALL_LIST, {
    ok = true, code = 0,
    stdout = '{"action":"existing","branch":"fix/login","path":"/src/app.fix"}\n',
    stderr = "directory change disabled\n",
  })
  fake.ui_answers = { answer(FIX) }
  local home = fake:add_session("home")
  local result = run(home)
  local switch = wt_calls()[2]
  t.check("switches by branch in the terminal's directory",
    result and result.path == FIX and result.created
      and switch.args.cwd == "/src/app/src"
      and switch.args.argv[#switch.args.argv] == "fix/login"
      and has(switch.args.argv, "--format=json") and has(switch.args.argv, "--no-cd")
      and not has(switch.args.argv, "--create") and not has(switch.args.argv, "--yes"))
  t.check("ignores the status line wt writes on success", #fake:warnings() == 0, t.show(fake:warnings()))
  t.check("lists, asks, switches, then opens the session",
    t.same_list(effects(), { "wt list", "ui.pick", "wt switch", "session.create", "client.queue" }),
    t.show(effects()))
  t.check("adopts the current worktree, not the terminal subdirectory",
    t.same_list(fake:registry_lines(), {
      MAIN .. "\t" .. home .. "\t\tadopted",
      FIX .. "\t" .. result.session_id .. "\t" .. home,
    }), t.show(fake:registry_lines()))
end

do
  fresh()
  stub(SMALL_LIST, {
    ok = true, code = 0,
    stdout = '{"action":"existing","branch":"main","path":"/src/app"}',
    stderr = "",
  })
  fake.ui_answers = { answer(MAIN), answer(MAIN) }
  local home = fake:add_session("home")
  local first = run(home)
  local again = run(home)
  t.check("picking the worktree you are in reuses your session",
    first.session_id == home and not first.created and again.session_id == home
      and #fake:calls_to("session.create") == 0)
end

do
  fresh()
  local made = "/src/app.made"
  fake.dirs[made] = true
  stub(SMALL_LIST, {
    ok = false, code = 1,
    stdout = '{"action":"created","branch":"fix/login","path":"/src/app.made"}\n',
    stderr = "hook failed\n",
  })
  fake.ui_answers = { answer(FIX) }
  local result = run(fake:add_session("home"))
  t.check("still opens the session when wt prints a path and then fails",
    result and result.path == made and #fake:warnings() == 1
      and fake:warnings()[1]:find("hook failed", 1, true), t.show(fake:warnings()))
end

do
  fresh()
  stub(SMALL_LIST, {
    ok = false, code = 1, stdout = "",
    stderr = "No branch named fix/login\n",
  })
  fake.ui_answers = { answer(FIX) }
  local err = t.error_of(run, fake:add_session("home"))
  t.check("reports wt's error when the switch has no path",
    err and err:find("No branch named fix/login", 1, true) and #fake.sessions == 1, err)
end

t.section("creating a worktree")

do
  fresh()
  local created_path = "/src/app.feature-x"
  fake.dirs[created_path] = true
  stub(SMALL_LIST, {
    ok = true, code = 0,
    stdout = '{"action":"created","branch":"feature/x","path":"/src/app.feature-x","created_branch":true}\n',
    stderr = "Created branch feature/x\n",
  })
  fake.ui_answers = { answer("new"), answer("  feature/x  ") }
  local result = run(fake:add_session("home"))
  local switch = wt_calls()[2].args.argv
  local base_at
  for i, v in ipairs(switch) do if v == "--base" then base_at = i end end
  t.check("creates from the trimmed name and the default base",
    result and result.path == created_path and result.created
      and has(switch, "--create") and not has(switch, "--yes")
      and base_at and switch[base_at + 1] == "@" and switch[#switch] == "feature/x")
  local input = fake:calls_to("ui.input")[1].args
  t.check("asks for the branch name",
    input.title == "New worktree" and input.confirm == "Create" and input.placeholder == "branch name")
  t.check("does not warn about wt's success message", #fake:warnings() == 0, t.show(fake:warnings()))
end

do
  fresh{ base = false }
  local created_path = "/src/app.feature-x"
  fake.dirs[created_path] = true
  stub('{"schema":2,"items":[]}', {
    ok = true, code = 0,
    stdout = '{"action":"created","branch":"feature/x","path":"/src/app.feature-x"}',
    stderr = "",
  })
  fake.ui_answers = { answer("new"), answer("feature/x") }
  run(fake:add_session("home"))
  local switch = wt_calls()[2].args.argv
  t.check("omits --base when base is false",
    has(switch, "--create") and not has(switch, "--base") and switch[#switch] == "feature/x")
end

do
  fresh{ base = "develop" }
  stub(SMALL_LIST, { ok = false, code = 1, stdout = "", stderr = "Branch feature/x already exists\n" })
  fake.ui_answers = { answer("new"), answer("feature/x") }
  local err = t.error_of(run, fake:add_session("home"))
  local switch = wt_calls()[2].args.argv
  local base_at
  for i, v in ipairs(switch) do if v == "--base" then base_at = i end end
  t.check("passes a configured base and surfaces a refused create",
    base_at and switch[base_at + 1] == "develop"
      and err and err:find("Branch feature/x already exists", 1, true)
      and #fake:calls_to("session.create") == 0, err)
end

t.section("leaving the prompt")

do
  fresh()
  stub(SMALL_LIST, { ok = true, code = 0, stdout = "", stderr = "" })
  fake.ui_answers = { answer(nil, "cancelled") }
  local home = fake:add_session("home")
  t.check("a cancelled list does nothing",
    run(home) == nil and #wt_calls() == 1 and #fake:calls_to("ui.input") == 0
      and #fake.sessions == 1 and #fake:warnings() == 0)
end

do
  fresh()
  stub(SMALL_LIST, { ok = true, code = 0, stdout = "", stderr = "" })
  fake.ui_answers = { answer("new"), answer(nil, "cancelled") }
  t.check("a cancelled name does nothing",
    run(fake:add_session("home")) == nil and #wt_calls() == 1 and #fake:warnings() == 0)
end

do
  fresh()
  stub(SMALL_LIST, { ok = true, code = 0, stdout = "", stderr = "" })
  fake.ui_answers = { answer("new"), answer("   ") }
  t.check("an empty name does nothing, with a warning",
    run(fake:add_session("home")) == nil and #wt_calls() == 1
      and fake:warnings()[1]:find("branch name is empty", 1, true))
end

do
  fresh()
  stub(SMALL_LIST, { ok = true, code = 0, stdout = "", stderr = "" })
  fake.ui_answers = { answer(nil, "busy") }
  t.check("a prompt that cannot be shown warns and returns",
    run(fake:add_session("home")) == nil and #wt_calls() == 1
      and fake:warnings()[1]:find("prompt busy", 1, true))
end

t.section("resolving wt without PATH")

do
  fake:reset()
  fake.cwd = MAIN
  fake.env.HOMEBREW_PREFIX = ""
  fake.executables["/opt/homebrew/bin/wt"] = true
  dofile(t.root .. "/init.lua").setup{ base = "@" }
  stub(SMALL_LIST, { ok = true, code = 0, stdout = "", stderr = "" })
  fake.ui_answers = { answer(nil, "cancelled") }
  run(fake:add_session("home"))
  local list = wt_calls()[1]
  t.check("uses /opt/homebrew/bin/wt when HOMEBREW_PREFIX is unset",
    list and list.args.argv[1] == "/opt/homebrew/bin/wt" and list.args.argv[2] == "list",
    list and list.args.argv[1])
end

t.section("failures before a choice")

do
  fresh()
  fake.cwd = nil
  local err = t.error_of(run, fake:add_session("home"))
  t.check("refuses to guess a repo when the terminal cwd is unknown",
    err and err:find("working directory", 1, true) and #wt_calls() == 0, err)
end

do
  fresh()
  local err = t.error_of(fake.actions.worktree.run, { origin = "key", session_id = "session:1" })
  t.check("refuses when no terminal is focused",
    err and err:find("working directory", 1, true) and #fake:calls_to("ui.pick") == 0, err)
end

do
  fresh()
  fake.wt_missing = "No such file or directory"
  local err = t.error_of(run, fake:add_session("home"))
  t.check("reports a missing wt",
    err and err:find("can't run wt: No such file or directory", 1, true)
      and #fake:calls_to("ui.pick") == 0, err)
end

do
  fresh()
  fake.wt = function(argv)
    if argv[2] == "list" then
      return { ok = false, code = 1, stdout = "", stderr = "fatal: not a git repository\n" }
    end
  end
  local err = t.error_of(run, fake:add_session("home"))
  t.check("reports a directory that is not a repo",
    err and err:find("not a git repository", 1, true) and #fake:calls_to("ui.pick") == 0, err)
end

do
  fresh()
  fake.wt = function()
    return { ok = true, code = 0, stdout = "{", stderr = "" }
  end
  local err = t.error_of(run, fake:add_session("home"))
  t.check("reports list output that is not JSON",
    err and err:find("invalid JSON", 1, true) and #fake:calls_to("ui.pick") == 0, err)
end

do
  fresh()
  fake.wt = function()
    return { ok = true, code = 0, stdout = '{"schema":1,"items":[]}', stderr = "" }
  end
  local err = t.error_of(run, fake:add_session("home"))
  t.check("refuses a wt list schema other than 2",
    err and err:find("unsupported schema 1", 1, true) and #fake:calls_to("ui.pick") == 0, err)
end

t.section("actions")

do
  local M = fresh{ remotes = true, base = 1 }
  t.check("registers switch, go, and close",
    fake.actions.worktree and fake.actions.worktree_go and fake.actions.worktree_close
      and fake.actions.worktree_remove == nil)
  t.check("warns on options this version does not take",
    #fake:warnings() == 2 and M.options.base == "@", t.show(fake:warnings()))
  local home = fake:add_session("home")
  local opened = fake.actions.worktree_go.run(ctx(home), { path = FIX })
  t.check("worktree_go opens a session", opened.created and opened.path == FIX)
  local closed = fake.actions.worktree_close.run(ctx(home), { path = FIX, main = MAIN })
  t.check("worktree_close closes it", closed.closed and fake:session(opened.session_id) == nil)
end

t.done(function() fake:cleanup() end)

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

local function argv_index(argv, flag)
  for i, v in ipairs(argv) do
    if v == flag then return i end
  end
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
  t.check("lists live rows, then dead, new, customize, and remove",
    #items == 6
      and items[1].id == MAIN and items[1].title == "main" and items[1].icon == "folder"
      and items[1].detail == "current, dirty" and items[1].subtitle == MAIN
      and items[1].selected == true
      and items[2].id == FEAT and items[2].title == "feat/diff" and items[2].icon == "branch"
      and items[2].detail == "dirty" and items[2].selected == nil
      and items[3].id == "dead" and items[3].title == "Show dead worktrees…"
      and items[4].id == "new" and items[4].title == "New worktree…" and items[4].icon == "plus"
      and items[5].id == "customize" and items[5].title == "Customize worktree…"
      and items[6].id == "remove" and items[6].title == "🗑️ Remove worktree…",
    items[6] and items[6].title)
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
  t.check("hides prunable rows and shows the commit on the live row",
    #items == 5
      and items[1].title == "main" and items[1].icon == "folder"
      and items[1].detail == "current · 6e42508 Merge pull request #7 from athul-ramesh/fix/private-forward-ready"
      and items[1].subtitle == "~/projects/rexproject/rex-agent.nvim"
      and items[2].id == "dead" and items[2].title == "Show dead worktrees…"
      and items[3].id == "new" and items[3].title == "New worktree…" and items[3].icon == "plus"
      and items[4].id == "customize" and items[4].title == "Customize worktree…"
      and items[5].id == "remove" and items[5].title == "🗑️ Remove worktree…")
end

do
  fresh()
  local sample = assert(io.open(here .. "/fixtures/wt-list-sample.json", "r")):read("*a")
  stub(sample, { ok = true, code = 0, stdout = "", stderr = "" })
  fake.ui_answers = { answer("dead"), answer(nil, "cancelled") }
  run(fake:add_session("home"))
  local dead = fake:calls_to("ui.pick")[2]
  local items = dead.args.items
  t.check("Show dead worktrees lists only prunable rows, then Remove",
    dead.args.title == "Dead worktrees"
      and #items == 6
      and items[1].title == "fix/open-seed-ready"
      and items[1].id == "/private/tmp/rex-agent-open-seed-ready"
      and items[1].detail == "prunable, mismatch · 643b168"
      and items[1].subtitle == "/private/tmp/rex-agent-open-seed-ready"
      and items[6].id == "remove" and items[6].title == "🗑️ Remove worktree…"
      and items[5].title == "arena/float-seed-2")
end

do
  fresh()
  stub('{"schema":2,"items":[]}', { ok = true, code = 0, stdout = "", stderr = "" })
  fake.ui_answers = { answer(nil, "cancelled") }
  run(fake:add_session("home"))
  local items = fake:calls_to("ui.pick")[1].args.items
  t.check("an empty repo still offers new, customize, and remove",
    #items == 3 and items[1].id == "new" and items[2].id == "customize" and items[3].id == "remove")
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
    #items == 4 and items[1].id == FIX and items[1].title == "one"
      and items[2].id == "new" and items[3].id == "customize" and items[4].id == "remove")
end

t.section("switching to the chosen worktree")

do
  fresh()
  fake.cwd = "/src/app/src"
  stub(SMALL_LIST, {
    ok = true, code = 0,
    stdout = '{"action":"existing","branch":"feat/diff","path":"/src/app.feat"}\n',
    stderr = "directory change disabled\n",
  })
  fake.ui_answers = { answer(FEAT) }
  local home = fake:add_session("home")
  local result = run(home)
  local switch = wt_calls()[2]
  t.check("switches by path in the terminal's directory",
    result and result.path == FEAT and result.created
      and switch.args.cwd == "/src/app/src"
      and switch.args.argv[#switch.args.argv] == FEAT
      and has(switch.args.argv, "--format=json") and has(switch.args.argv, "--no-cd")
      and not has(switch.args.argv, "--create") and not has(switch.args.argv, "--yes")
      and not has(switch.args.argv, "feat/diff"))
  t.check("ignores the status line wt writes on success", #fake:warnings() == 0, t.show(fake:warnings()))
  t.check("lists, asks, switches, then opens the session",
    t.same_list(effects(), { "wt list", "ui.pick", "wt switch", "session.create", "client.queue" }),
    t.show(effects()))
  t.check("adopts the current worktree, not the terminal subdirectory",
    t.same_list(fake:registry_lines(), {
      MAIN .. "\t" .. home .. "\t\tadopted",
      FEAT .. "\t" .. result.session_id .. "\t" .. home,
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
  stub(SMALL_LIST, {
    ok = false, code = 1,
    stdout = '{"action":"created","branch":"feat/diff","path":"/src/app.made"}\n',
    stderr = "hook failed\n",
  })
  fake.ui_answers = { answer(FEAT) }
  local err = t.error_of(run, fake:add_session("home"))
  t.check("does not open a session when wt switch fails",
    err and err:find("hook failed", 1, true)
      and #fake:calls_to("session.create") == 0 and #fake.sessions == 1, err)
end

do
  fresh()
  stub(SMALL_LIST, {
    ok = false, code = 1, stdout = "",
    stderr = "No branch named fix/login\n",
  })
  fake.ui_answers = { answer(FEAT) }
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
      and has(switch, "--create") and not has(switch, "--yes") and not has(switch, "--path")
      and base_at and switch[base_at + 1] == "@" and switch[#switch] == "feature/x")
  local input = fake:calls_to("ui.input")[1].args
  t.check("asks for the branch name",
    input.title == "New worktree" and input.confirm == "Create" and input.placeholder == "branch name"
      and input.value == nil)
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

t.section("customizing a new worktree")

do
  fresh()
  local created_path = "/src/app.feature-x"
  fake.dirs[created_path] = true
  stub(SMALL_LIST, {
    ok = true, code = 0,
    stdout = '{"action":"created","branch":"feature/x","path":"/src/app.feature-x","created_branch":true}\n',
    stderr = "",
  })
  fake.ui_answers = { answer("customize"), answer("feature/x"), answer(created_path) }
  local result = run(fake:add_session("home"))
  local switch = wt_calls()[2].args.argv
  local path_at = argv_index(switch, "--path")
  local base_at = argv_index(switch, "--base")
  t.check("customize creates with --path and the branch",
    result and result.path == created_path and result.created
      and has(switch, "--create") and not has(switch, "--yes")
      and path_at and switch[path_at + 1] == created_path
      and base_at and switch[base_at + 1] == "@"
      and switch[#switch] == "feature/x")
  local inputs = fake:calls_to("ui.input")
  t.check("asks for the branch, then a directory prefilled beside the current worktree",
    #inputs == 2
      and inputs[1].args.title == "Customize worktree"
      and inputs[1].args.placeholder == "branch name"
      and inputs[1].args.confirm == "Next"
      and inputs[1].args.value == nil
      and inputs[2].args.title == "Worktree directory"
      and inputs[2].args.placeholder == "directory"
      and inputs[2].args.confirm == "Create"
      and inputs[2].args.value == "/src/app.feature-x")
  t.check("lists, asks twice, creates, then opens the session",
    t.same_list(effects(), {
      "wt list", "ui.pick", "ui.input", "ui.input", "wt switch", "session.create", "client.queue",
    }), t.show(effects()))
end

do
  fresh()
  local edited = "/tmp/custom-wt"
  fake.dirs[edited] = true
  stub(SMALL_LIST, {
    ok = true, code = 0,
    stdout = '{"action":"created","branch":"feature/x","path":"/tmp/custom-wt"}\n',
    stderr = "",
  })
  fake.ui_answers = { answer("customize"), answer("  feature/x  "), answer("  " .. edited .. "  ") }
  local result = run(fake:add_session("home"))
  local switch = wt_calls()[2].args.argv
  local path_at = argv_index(switch, "--path")
  t.check("passes the trimmed directory the user typed",
    result and result.path == edited
      and path_at and switch[path_at + 1] == edited
      and switch[#switch] == "feature/x")
end

do
  fresh()
  fake.dirs["/src/repo.feature-x"] = true
  stub(SMALL_LIST, {
    ok = true, code = 0,
    stdout = '{"action":"created","branch":"feature/x","path":"/src/repo.feature-x"}\n',
    stderr = "",
  })
  fake.ui_answers = { answer("customize"), answer("feature/x"), answer("repo.feature-x") }
  local result = run(fake:add_session("home"))
  local switch = wt_calls()[2].args.argv
  local path_at = argv_index(switch, "--path")
  t.check("passes a relative directory as entered",
    result and result.path == "/src/repo.feature-x"
      and path_at and switch[path_at + 1] == "repo.feature-x")
end

do
  fresh()
  fake.env.HOME = "/Users/athul"
  local created_path = "/Users/athul/work/app.feature-x"
  fake.dirs[created_path] = true
  stub(SMALL_LIST, {
    ok = true, code = 0,
    stdout = '{"action":"created","branch":"feature/x","path":"/Users/athul/work/app.feature-x"}\n',
    stderr = "",
  })
  fake.ui_answers = {
    answer("customize"),
    answer("feature/x"),
    answer("~/work/app.feature-x/"),
  }
  local result = run(fake:add_session("home"))
  local switch = wt_calls()[2].args.argv
  local path_at = argv_index(switch, "--path")
  t.check("expands ~/ and strips a trailing slash on the directory",
    result and result.path == created_path
      and path_at and switch[path_at + 1] == created_path)
end

do
  fresh{ base = false }
  local created_path = "/src/app.feature-x"
  fake.dirs[created_path] = true
  stub(SMALL_LIST, {
    ok = true, code = 0,
    stdout = '{"action":"created","branch":"feature/x","path":"/src/app.feature-x"}\n',
    stderr = "",
  })
  fake.ui_answers = { answer("customize"), answer("feature/x"), answer(created_path) }
  run(fake:add_session("home"))
  local switch = wt_calls()[2].args.argv
  t.check("customize omits --base when base is false",
    has(switch, "--create") and has(switch, "--path") and not has(switch, "--base")
      and switch[#switch] == "feature/x")
end

do
  fresh()
  fake.cwd = "/other/app.feat"
  local listed = [[{
    "schema": 2,
    "items": [
      {"branch": "main", "worktree": {"path": "/src/app", "main": true}},
      {"branch": "feat/diff", "worktree": {"path": "/other/app.feat", "current": true}}
    ]
  }]]
  stub(listed, { ok = true, code = 0, stdout = "", stderr = "" })
  fake.ui_answers = { answer("customize"), answer("feat/deep/name"), answer(nil, "cancelled") }
  run(fake:add_session("home"))
  local directory = fake:calls_to("ui.input")[2].args.value
  t.check("prefill is the current worktree's parent and the main checkout's name",
    directory == "/other/app.feat-deep-name" and #wt_calls() == 1, directory)
end

do
  fresh()
  fake.cwd = "/work/repo"
  local listed = [[{
    "schema": 2,
    "items": [
      {"branch": "main", "worktree": {"path": "/src/app", "main": true}}
    ]
  }]]
  stub(listed, { ok = true, code = 0, stdout = "", stderr = "" })
  fake.ui_answers = { answer("customize"), answer("feature/x"), answer(nil, "cancelled") }
  run(fake:add_session("home"))
  local directory = fake:calls_to("ui.input")[2].args.value
  t.check("prefill uses the terminal directory when no worktree is current",
    directory == "/work/app.feature-x", directory)
end

do
  fresh()
  stub(SMALL_LIST, { ok = true, code = 0, stdout = "", stderr = "" })
  fake.ui_answers = { answer("customize"), answer(nil, "cancelled") }
  t.check("cancelling the customize branch creates nothing",
    run(fake:add_session("home")) == nil and #wt_calls() == 1
      and #fake:calls_to("ui.input") == 1 and #fake:warnings() == 0)
end

do
  fresh()
  stub(SMALL_LIST, { ok = true, code = 0, stdout = "", stderr = "" })
  fake.ui_answers = { answer("customize"), answer("   ") }
  t.check("an empty customize branch does not ask for a directory",
    run(fake:add_session("home")) == nil and #wt_calls() == 1
      and #fake:calls_to("ui.input") == 1
      and fake:warnings()[1]:find("branch name is empty", 1, true))
end

do
  fresh()
  stub(SMALL_LIST, { ok = true, code = 0, stdout = "", stderr = "" })
  fake.ui_answers = { answer("customize"), answer("feature/x"), answer(nil, "cancelled") }
  t.check("cancelling the directory creates nothing",
    run(fake:add_session("home")) == nil and #wt_calls() == 1
      and #fake:calls_to("ui.input") == 2 and #fake:warnings() == 0)
end

do
  fresh()
  stub(SMALL_LIST, { ok = true, code = 0, stdout = "", stderr = "" })
  fake.ui_answers = { answer("customize"), answer("feature/x"), answer("   ") }
  t.check("an empty directory creates nothing, with a warning",
    run(fake:add_session("home")) == nil and #wt_calls() == 1
      and #fake:calls_to("ui.input") == 2
      and fake:warnings()[1]:find("directory is empty", 1, true))
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

t.section("the row detail")

do
  fresh()
  local home = fake:add_session("home")
  fake.actions.worktree_go.run(ctx(home), { path = FEAT, branch = "feat/diff" })
  stub(SMALL_LIST, { ok = true, code = 0, stdout = "", stderr = "" })
  fake.ui_answers = { answer(nil, "cancelled") }
  run(home)
  local feat
  for _, item in ipairs(fake:calls_to("ui.pick")[1].args.items) do
    if item.id == FEAT then feat = item end
  end
  t.check("marks a worktree that already has a session",
    feat and feat.detail == "session, dirty", feat and feat.detail)
end

do
  fresh()
  local signal = [[{
    "schema": 2,
    "items": [{
      "branch": "fix/login",
      "head": { "short_sha": "abc1234", "subject": "Fix login" },
      "worktree": {
        "path": "/src/app.fix",
        "previous": true,
        "duplicate_branch": true,
        "branch_mismatch": true
      }
    }]
  }]]
  stub(signal, { ok = true, code = 0, stdout = "", stderr = "" })
  fake.ui_answers = { answer(nil, "cancelled") }
  run(fake:add_session("home"))
  local row = fake:calls_to("ui.pick")[1].args.items[1]
  t.check("shows previous, duplicate, mismatch, and the commit",
    row.detail == "previous, duplicate, mismatch · abc1234 Fix login"
      and row.subtitle == FIX, row.detail)
end

t.section("removing a worktree")

local function remove_ok(argv)
  if argv[2] == "remove" then
    return { ok = true, code = 0, stdout = "{}", stderr = "" }
  end
  return { ok = false, code = 1, stdout = "", stderr = "unexpected wt " .. tostring(argv[2]) .. "\n" }
end

local function remove_call()
  for _, call in ipairs(wt_calls()) do
    if call.args.argv[2] == "remove" then return call end
  end
end

do
  fresh()
  stub(SMALL_LIST, remove_ok)
  fake.ui_answers = { answer("remove"), answer(nil, "cancelled") }
  run(fake:add_session("home"))
  local items = fake:calls_to("ui.pick")[2].args.items
  t.check("the remove list leaves out main and prunable rows",
    fake:calls_to("ui.pick")[2].args.title == "Remove worktree"
      and #items == 1 and items[1].id == FEAT and items[1].title == "feat/diff")
  t.check("cancelling remove does not run wt remove", remove_call() == nil)
end

do
  fresh()
  local home = fake:add_session("home")
  local opened = fake.actions.worktree_go.run(ctx(home), { path = FEAT })
  stub(SMALL_LIST, function(argv)
    if argv[2] == "remove" and has(argv, "--force") then return remove_ok(argv) end
    if argv[2] == "remove" then
      return { ok = false, code = 1, stdout = "", stderr = "worktree is dirty\n" }
    end
    return remove_ok(argv)
  end)
  fake.ui_answers = { answer("remove"), answer(FEAT), answer(nil, "cancelled") }
  t.check("a dirty worktree asks before forcing, and cancel removes nothing",
    run(home) == nil and remove_call() == nil and fake:session(opened.session_id) ~= nil)
  local force_item = fake:calls_to("ui.pick")[3].args.items[1]
  t.check("the force remove option shows a trash can",
    force_item.id == "force" and force_item.title == "🗑️ Force remove")
  fake.ui_answers = { answer("remove"), answer(FEAT), answer("force") }
  local closed = run(home)
  local argv = remove_call().args.argv
  t.check("force remove passes --force and the path, then closes the session",
    closed and closed.closed and closed.session_id == opened.session_id
      and fake:session(opened.session_id) == nil
      and has(argv, "--format=json") and has(argv, "--force") and argv[#argv] == FEAT
      and not has(argv, "feat/diff"),
    argv and table.concat(argv, " "))
end

do
  fresh()
  local home = fake:add_session("home")
  local opened = fake.actions.worktree_go.run(ctx(home), { path = FIX })
  stub(SMALL_LIST, remove_ok)
  fake.ui_answers = { answer("dead"), answer("remove"), answer(FIX) }
  local closed = run(home)
  local argv = remove_call().args.argv
  t.check("remove from the dead list uses the path and skips force when clean",
    closed and closed.closed and argv[#argv] == FIX and not has(argv, "--force")
      and fake:session(opened.session_id) == nil,
    argv and table.concat(argv, " "))
end

do
  fresh()
  local home = fake:add_session("home")
  local opened = fake.actions.worktree_go.run(ctx(home), { path = FEAT })
  stub(SMALL_LIST, function(argv)
    if argv[2] == "remove" then
      return { ok = false, code = 1, stdout = "", stderr = "remove refused\n" }
    end
    return remove_ok(argv)
  end)
  fake.ui_answers = { answer("remove"), answer(FEAT), answer("force") }
  local err = t.error_of(run, home)
  t.check("a failed remove leaves the session open",
    err and err:find("remove refused", 1, true) and fake:session(opened.session_id) ~= nil, err)
end

do
  fresh()
  stub(SMALL_LIST, {
    ok = true, code = 0,
    stdout = '{"action":"existing","branch":"fix/login","path":"/src/app.fix"}',
    stderr = "",
  })
  fake.ui_answers = { answer("dead"), answer(FIX) }
  local result = run(fake:add_session("home"))
  local switch = wt_calls()[2]
  t.check("a dead row switches by its path",
    result and result.path == FIX and switch.args.argv[#switch.args.argv] == FIX)
end

t.section("previous and main")

do
  fresh()
  fake.cwd = "/src/app/src"
  stub(SMALL_LIST, function(argv)
    if argv[#argv] == "-" then
      return { ok = true, code = 0, stdout = '{"branch":"feat/diff","path":"/src/app.feat"}', stderr = "" }
    end
    return { ok = false, code = 1, stdout = "", stderr = "unexpected\n" }
  end)
  local result = fake.actions.worktree_previous.run(ctx(fake:add_session("home")))
  local switch = wt_calls()[2]
  t.check("worktree_previous runs wt switch -",
    result and result.path == FEAT and result.created
      and switch.args.cwd == "/src/app/src"
      and switch.args.argv[#switch.args.argv] == "-"
      and has(switch.args.argv, "--format=json") and has(switch.args.argv, "--no-cd")
      and switch.args.argv[2] == "switch")
end

do
  fresh()
  stub(SMALL_LIST, {
    ok = false, code = 1,
    stdout = '{"branch":"feat/diff","path":"/src/app.feat"}',
    stderr = "no previous worktree\n",
  })
  local err = t.error_of(fake.actions.worktree_previous.run, ctx(fake:add_session("home")))
  t.check("worktree_previous does not open a session when wt switch fails",
    err and err:find("no previous worktree", 1, true) and #fake:calls_to("session.create") == 0, err)
end

do
  fresh()
  stub(SMALL_LIST, function(argv)
    if argv[2] == "switch" then
      return { ok = true, code = 0, stdout = '{"branch":"main","path":"/src/app"}', stderr = "" }
    end
    return { ok = false, code = 1, stdout = "", stderr = "unexpected\n" }
  end)
  local home = fake:add_session("home")
  local result = fake.actions.worktree_main.run(ctx(home))
  local argv = wt_calls()[2].args.argv
  t.check("worktree_main switches to the main path",
    result and result.path == MAIN and result.session_id == home and not result.created
      and argv[#argv] == MAIN and not has(argv, "main") and not has(argv, "^"))
end

do
  fresh()
  local no_main = '{"schema":2,"items":[{"branch":"fix/login","worktree":{"path":"/src/app.fix"}}]}'
  stub(no_main, function(argv)
    if argv[#argv] == "^" then
      return { ok = true, code = 0, stdout = '{"branch":"main","path":"/src/app"}', stderr = "" }
    end
    return { ok = false, code = 1, stdout = "", stderr = "unexpected\n" }
  end)
  local result = fake.actions.worktree_main.run(ctx(fake:add_session("home")))
  t.check("worktree_main uses wt switch ^ when the list has no main path",
    result and result.path == MAIN and wt_calls()[2].args.argv[#wt_calls()[2].args.argv] == "^")
end

do
  fresh()
  local home = fake:add_session("home")
  local opened = fake.actions.worktree_go.run(ctx(home), { path = FIX })
  stub(SMALL_LIST, remove_ok)
  local closed = fake.actions.worktree_remove.run(ctx(home), { path = FIX })
  local argv = remove_call().args.argv
  t.check("worktree_remove removes by path and closes the session",
    closed and closed.closed and closed.session_id == opened.session_id
      and argv[2] == "remove" and has(argv, "--format=json") and not has(argv, "--force")
      and argv[#argv] == FIX and fake:session(opened.session_id) == nil)
end

do
  fresh()
  stub(SMALL_LIST, remove_ok)
  local home = fake:add_session("home")
  fake.actions.worktree_remove.run(ctx(home), { path = FIX .. "/", force = true })
  local argv = remove_call().args.argv
  t.check("worktree_remove passes --force when asked",
    has(argv, "--force") and argv[#argv] == FIX)
end

do
  fresh()
  stub(SMALL_LIST, remove_ok)
  local err = t.error_of(fake.actions.worktree_remove.run, ctx(fake:add_session("home")), { path = MAIN })
  t.check("worktree_remove refuses the main worktree",
    err and err:find("can't remove the main worktree", 1, true) and remove_call() == nil, err)
end

do
  fresh()
  local home = fake:add_session("home")
  local opened = fake.actions.worktree_go.run(ctx(home), { path = FIX })
  stub(SMALL_LIST, function(argv)
    if argv[2] == "remove" then
      return { ok = false, code = 1, stdout = "{}", stderr = "still checked out\n" }
    end
    return remove_ok(argv)
  end)
  local err = t.error_of(fake.actions.worktree_remove.run, ctx(home), { path = FIX })
  t.check("worktree_remove does not close the session when wt remove fails",
    err and err:find("still checked out", 1, true) and fake:session(opened.session_id) ~= nil, err)
end

t.section("actions")

do
  local M = fresh{ remotes = true, base = 1 }
  t.check("registers switch, go, close, previous, main, and remove",
    fake.actions.worktree and fake.actions.worktree_go and fake.actions.worktree_close
      and fake.actions.worktree_previous and fake.actions.worktree_main
      and fake.actions.worktree_remove
      and fake.actions.worktree_remove.args.force == "boolean?")
  t.check("warns on options this version does not take",
    #fake:warnings() == 2 and M.options.base == "@", t.show(fake:warnings()))
  local home = fake:add_session("home")
  local opened = fake.actions.worktree_go.run(ctx(home), { path = FIX })
  t.check("worktree_go opens a session", opened.created and opened.path == FIX)
  local closed = fake.actions.worktree_close.run(ctx(home), { path = FIX, main = MAIN })
  t.check("worktree_close closes it", closed.closed and fake:session(opened.session_id) == nil)
end

t.done(function() fake:cleanup() end)

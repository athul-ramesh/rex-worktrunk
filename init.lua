local M = {}

M.version = "1.0.0"

M.options = {
  base = "@",
  -- Absolute path of the wt binary, or "wt" to look it up on PATH. Rex actions
  -- often see a short PATH without Homebrew, so the default probes common
  -- install locations with test -x.
  wt = nil,
  layout = nil,
  label = nil,
}

local OPTION_TYPES = {
  base   = { "string", "boolean" },
  wt     = { "string" },
  layout = { "function" },
  label  = { "function" },
}

local wt_program = nil

local SHELL_FLAVOR     = "com.superlogical.terminal.shell"
local TERMINAL_CREATOR = "com.superlogical.terminal"
local NEW_ID    = "new"
local DEAD_ID   = "dead"
local REMOVE_ID = "remove"
local FORCE_ID  = "force"

local function raise(message)
  error("worktrunk: " .. message, 0)
end

local function warn(message)
  rex.log("warn", "rex-worktrunk: " .. message)
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function text_or_nil(value)
  if type(value) == "string" and value ~= "" then return value end
end

local function expand_home(path)
  if path:sub(1, 2) == "~/" then return (os.getenv("HOME") or "") .. path:sub(2) end
  return path
end

local function normalize_path(path)
  path = expand_home(trim(path or ""))
  if #path > 1 then path = path:gsub("/+$", "") end
  return path
end

local function is_trackable(path)
  return path:sub(1, 1) == "/" and not path:find("%c")
end

local function basename(path)
  return path:match("([^/]+)/*$") or path
end

local function display_path(path)
  local home = os.getenv("HOME")
  if not home or home == "" then return path end
  if path == home then return "~" end
  local prefix = home .. "/"
  if path:sub(1, #prefix) == prefix then return "~/" .. path:sub(#prefix + 1) end
  return path
end

local function dirty_changes(changes)
  if type(changes) ~= "table" then return false end
  if changes.staged == true or changes.modified == true or changes.untracked == true
    or changes.renamed == true or changes.deleted == true or changes.conflicted == true then
    return true
  end
  local diff = changes.diff
  if type(diff) == "table" then
    if (tonumber(diff.added) or 0) > 0 or (tonumber(diff.deleted) or 0) > 0 then
      return true
    end
  end
  return false
end

local function parse_list(decoded)
  if type(decoded) ~= "table" then return nil, "expected an object" end
  if decoded.schema ~= 2 then
    return nil, "unsupported schema " .. tostring(decoded.schema)
  end
  local rows, seen = {}, {}
  local main, current
  for _, item in ipairs(decoded.items or {}) do
    if type(item) == "table" and type(item.worktree) == "table" then
      local wt = item.worktree
      local path = normalize_path(wt.path or "")
      if is_trackable(path) then
        if wt.main == true and not main then main = path end
        if wt.current == true and not current then current = path end
        local branch = item.branch
        if type(branch) == "string" and branch ~= "" and not seen[path] then
          seen[path] = true
          local head = type(item.head) == "table" and item.head or {}
          rows[#rows + 1] = {
            branch           = branch,
            path             = path,
            main             = wt.main == true,
            current          = wt.current == true,
            previous         = wt.previous == true,
            dirty            = dirty_changes(wt.changes),
            prunable         = type(wt.prunable) == "table",
            duplicate_branch = wt.duplicate_branch == true,
            branch_mismatch  = wt.branch_mismatch == true,
            subject          = text_or_nil(head.subject),
            short_sha        = text_or_nil(head.short_sha),
          }
        end
      end
    end
  end
  return { rows = rows, main = main, current = current }
end

local function parse_switch(decoded)
  if type(decoded) ~= "table" then return nil, "expected an object" end
  local path = normalize_path(decoded.path or "")
  if not is_trackable(path) then return nil, "missing worktree path" end
  if type(decoded.branch) ~= "string" or decoded.branch == "" then
    return nil, "missing branch"
  end
  return { path = path, branch = decoded.branch }
end

local function row_detail(row, entries)
  local parts = {}
  if row.current then parts[#parts + 1] = "current" end
  if entries and entries[row.path] then parts[#parts + 1] = "session" end
  if row.previous then parts[#parts + 1] = "previous" end
  if row.dirty then parts[#parts + 1] = "dirty" end
  if row.prunable then parts[#parts + 1] = "prunable" end
  if row.duplicate_branch then parts[#parts + 1] = "duplicate" end
  if row.branch_mismatch then parts[#parts + 1] = "mismatch" end
  if row.short_sha then parts[#parts + 1] = row.short_sha end
  if row.subject then parts[#parts + 1] = row.subject end
  if #parts == 0 then return nil end
  return table.concat(parts, ", ")
end

local function row_item(row, entries)
  return {
    id       = row.path,
    title    = row.branch,
    subtitle = display_path(row.path),
    icon     = row.main and "folder" or "branch",
    detail   = row_detail(row, entries),
    selected = row.current or nil,
  }
end

local function items_for(rows, entries, extras)
  local items = {}
  for _, row in ipairs(rows) do items[#items + 1] = row_item(row, entries) end
  for _, extra in ipairs(extras) do items[#items + 1] = extra end
  return items
end

local NEW_ITEM = { id = NEW_ID, title = "New worktree…", icon = "plus" }
local REMOVE_ITEM = { id = REMOVE_ID, title = "Remove worktree…", icon = "trash" }
local DEAD_ITEM = { id = DEAD_ID, title = "Show dead worktrees…", icon = "trash" }

local function split_rows(rows)
  local live, dead = {}, {}
  for _, row in ipairs(rows) do
    if row.prunable then dead[#dead + 1] = row else live[#live + 1] = row end
  end
  return live, dead
end

local function removable_rows(rows)
  local out = {}
  for _, row in ipairs(rows) do
    if not row.main then out[#out + 1] = row end
  end
  return out
end

local function row_by_path(rows, path)
  for _, row in ipairs(rows) do
    if row.path == path then return row end
  end
end

local function intent_switch(row)
  return { kind = "switch", path = row.path, branch = row.branch }
end

local function intent_create(branch, base)
  return { kind = "create", branch = branch, base = base }
end

local function intent_remove(path, force)
  return { kind = "remove", path = path, force = force == true }
end

local function create_base()
  local base = M.options.base
  if type(base) == "string" and base ~= "" then return base end
  return nil
end

local function is_executable(path)
  local result = rex.exec({ "test", "-x", path })
  return result ~= nil and result.ok
end

-- Rex actions often run with PATH=/usr/bin:/bin:/usr/sbin:/sbin, which does not
-- include Homebrew. Prefer an absolute wt the server can exec without PATH.
local function resolve_wt()
  if wt_program then return wt_program end
  if type(M.options.wt) == "string" and M.options.wt ~= "" then
    local path = expand_home(M.options.wt)
    if path ~= "wt" and not is_executable(path) then
      raise("wt is not executable: " .. path)
    end
    wt_program = path
    return wt_program
  end
  local candidates = {}
  local homebrew = os.getenv("HOMEBREW_PREFIX")
  if homebrew and homebrew ~= "" then
    candidates[#candidates + 1] = homebrew .. "/bin/wt"
  end
  candidates[#candidates + 1] = "/opt/homebrew/bin/wt"
  candidates[#candidates + 1] = "/usr/local/bin/wt"
  for _, path in ipairs(candidates) do
    if is_executable(path) then
      wt_program = path
      return wt_program
    end
  end
  local probe = rex.exec({ "wt", "--version" })
  if probe ~= nil then
    wt_program = "wt"
    return wt_program
  end
  raise("wt not found; install worktrunk or set setup{ wt = \"/path/to/wt\" }")
end

local function switch_argv(intent)
  local argv = { resolve_wt(), "switch", "--format=json", "--no-cd" }
  if intent.kind == "create" then
    argv[#argv + 1] = "--create"
    if intent.base then
      argv[#argv + 1] = "--base"
      argv[#argv + 1] = intent.base
    end
    argv[#argv + 1] = intent.branch
  else
    argv[#argv + 1] = intent.path
  end
  return argv
end

local function remove_argv(intent)
  local argv = { resolve_wt(), "remove", "--format=json" }
  if intent.force then argv[#argv + 1] = "--force" end
  argv[#argv + 1] = intent.path
  return argv
end

local function failure_text(result)
  local detail = trim(result.stderr or "")
  if detail == "" then detail = trim(result.stdout or "") end
  if detail == "" then detail = "exit " .. tostring(result.code) end
  return detail
end

local function decode_object(stdout, what)
  local text = trim(stdout or "")
  if text == "" then raise(what .. " returned no JSON") end
  local value, err = rex.json.decode(text)
  if err ~= nil then raise(what .. " returned invalid JSON: " .. tostring(err)) end
  if type(value) ~= "table" then raise(what .. " returned invalid JSON") end
  return value
end

local function exec_wt(argv, cwd)
  local result, err = rex.exec(argv, { cwd = cwd })
  if result == nil then raise("can't run wt: " .. tostring(err)) end
  return result
end

local function list_worktrees(cwd)
  local result = exec_wt({ resolve_wt(), "list", "--format=json" }, cwd)
  if not result.ok then raise("wt list: " .. failure_text(result)) end
  local listed, err = parse_list(decode_object(result.stdout, "wt list"))
  if not listed then raise("wt list: " .. err) end
  return listed
end

local function switch_worktree(cwd, intent)
  local result = exec_wt(switch_argv(intent), cwd)
  if not result.ok then raise("wt switch: " .. failure_text(result)) end
  local outcome, err = parse_switch(decode_object(result.stdout, "wt switch"))
  if not outcome then raise("wt switch: " .. err) end
  return outcome
end

local function remove_worktree(cwd, intent)
  local result = exec_wt(remove_argv(intent), cwd)
  if not result.ok then raise("wt remove: " .. failure_text(result)) end
end

local function prompt_declined(value, why, detail)
  if value ~= nil then return false end
  if why ~= nil and why ~= "cancelled" then
    local extra = (detail and detail ~= "") and (": " .. detail) or ""
    warn("prompt " .. why .. extra)
  end
  return true
end

local function is_directory(path)
  local result = rex.exec{ "test", "-d", path }
  return result ~= nil and result.ok
end

local function focused_terminal_cwd(block_id)
  if not block_id then return nil end
  local process = rex.block.call(TERMINAL_CREATOR, "process", { block_id = block_id })
  if not process then return nil end
  local foreground, child = process.foreground or {}, process.child or {}
  local cwd = foreground.cwd or child.cwd
  if cwd and cwd ~= "" then return cwd end
  return nil
end

local function live_session_ids()
  local list, err = rex.call("session.list")
  if list == nil then raise(tostring(err)) end
  local ids = {}
  for _, s in ipairs(list.sessions or {}) do ids[s.session_id] = true end
  return ids
end

local Registry = {}

function Registry.file()
  local base = os.getenv("XDG_STATE_HOME")
  if not base or base == "" then base = (os.getenv("HOME") or "") .. "/.local/state" end
  return base .. "/rex-worktrunk/sessions"
end

function Registry.load()
  local entries = {}
  local f = io.open(Registry.file(), "r")
  if not f then return entries end
  for line in f:lines() do
    local fields = {}
    for field in (line .. "\t"):gmatch("([^\t]*)\t") do fields[#fields + 1] = field end
    local path, session, origin, kind = fields[1], fields[2], fields[3], fields[4]
    if path ~= "" and session and session ~= "" then
      entries[path] = {
        session = session,
        origin  = origin ~= "" and origin or nil,
        adopted = kind == "adopted" or nil,
      }
    end
  end
  f:close()
  return entries
end

function Registry.save(entries)
  local file = Registry.file()
  local tmp = file .. ".tmp." .. os.time() .. "." .. tostring({}):match("(%x+)$")
  local f = io.open(tmp, "w")
  if not f then
    rex.exec{ "mkdir", "-p", (file:match("^(.*)/")) }
    local err
    f, err = io.open(tmp, "w")
    if not f then raise("can't save the session registry: " .. tostring(err)) end
  end
  local paths = {}
  for path in pairs(entries) do paths[#paths + 1] = path end
  table.sort(paths)
  for _, path in ipairs(paths) do
    local entry = entries[path]
    local line = { path, entry.session }
    if entry.origin or entry.adopted then line[3] = entry.origin or "" end
    if entry.adopted then line[4] = "adopted" end
    f:write(table.concat(line, "\t"), "\n")
  end
  f:close()
  local ok, err = os.rename(tmp, file)
  if not ok then
    os.remove(tmp)
    raise("can't save the session registry: " .. tostring(err))
  end
end

function Registry.load_live()
  local entries, live, pruned = Registry.load(), live_session_ids(), false
  for path, entry in pairs(entries) do
    if not live[entry.session] then
      entries[path] = nil
      pruned = true
    end
  end
  if pruned then Registry.save(entries) end
  return entries, live
end

function Registry.adopt(entries, path, session_id)
  if entries[path] then return false end
  for _, entry in pairs(entries) do
    if entry.session == session_id then return false end
  end
  entries[path] = { session = session_id, adopted = true }
  return true
end

local function session_label(worktree)
  local default = basename(worktree.path)
  if not M.options.label then return default end
  local ok, label = pcall(M.options.label, worktree.path, worktree)
  if not ok then
    warn("label function failed: " .. tostring(label))
    return default
  end
  if label == nil then return default end
  if type(label) ~= "string" then
    warn("label function returned a " .. type(label) .. ", not a string")
    return default
  end
  label = trim(label:gsub("%c+", " "))
  return label ~= "" and label or default
end

local function default_layout(_label, path)
  return rex.layout.block{ flavor = SHELL_FLAVOR, options = { cwd = path } }
end

local function session_layout(label, worktree)
  if not M.options.layout then return default_layout(label, worktree.path) end
  local ok, layout = pcall(M.options.layout, label, worktree.path, worktree)
  if not ok then raise("layout function failed: " .. tostring(layout)) end
  return layout
end

local function create_session(worktree)
  local label = session_label(worktree)
  local windows = { { layout = session_layout(label, worktree) } }
  local created, err = rex.call("session.create", { label = label, initial_windows = windows })
  local default = basename(worktree.path)
  if created == nil and label ~= default then
    warn("could not create a session labelled \"" .. label .. "\" (" .. tostring(err)
      .. "); trying \"" .. default .. "\"")
    created, err = rex.call("session.create", { label = default, initial_windows = windows })
  end
  if created == nil then raise(tostring(err)) end
  return created.session_id
end

local function return_destination(entry, main, entries, live)
  local function usable(id) return id ~= nil and id ~= entry.session and live[id] == true end
  if usable(entry.origin) then return entry.origin end
  local main_entry = main and entries[main]
  if main_entry and usable(main_entry.session) then return main_entry.session end
  return nil
end

local function destroy_session(session_id)
  local _, err = rex.call("session.attach", { session_id = session_id })
  if err == nil then
    _, err = rex.call("session.destroy", { session_id = session_id })
  end
  if err ~= nil and live_session_ids()[session_id] then raise(tostring(err)) end
end

local function show_session_in_app(ctx, session_id)
  if ctx.origin == "key" or ctx.origin == "palette" then
    rex.client.queue("session.select", { session_id = session_id })
    return
  end
  local apps = rex.call("client.list", { kinds = { "app" }, session_id = ctx.session_id })
  if apps == nil or #(apps.clients or {}) == 0 then
    apps = rex.call("client.list", { kinds = { "app" } })
  end
  local last_err
  for _, client in ipairs(apps and apps.clients or {}) do
    local _, err = rex.call("client.perform", {
      client_id = client.client_id,
      action    = "session.select",
      args      = { session_id = session_id },
      origin    = ctx.origin,
    })
    if err == nil then return end
    last_err = err
  end
  error(last_err or "no Rex app is connected", 0)
end

function M.go(ctx, path, request)
  request = request or {}
  path = normalize_path(path)
  if not is_trackable(path) then raise("not an absolute path: " .. path) end
  if not is_directory(path) then raise("not a directory: " .. path) end

  local entries, live = Registry.load_live()
  local here = live[ctx.session_id] and ctx.session_id or nil
  local changed, created = false, false

  local from = request.from and normalize_path(request.from)
  if here and from and is_trackable(from) then
    changed = Registry.adopt(entries, from, here)
  end

  local entry = entries[path]
  if entry == nil then
    local worktree = {
      path   = path,
      branch = request.branch,
      main   = request.main and normalize_path(request.main),
    }
    entry = { session = create_session(worktree), origin = here }
    entries[path] = entry
    changed, created = true, true
  elseif here and here ~= entry.session and not live[entry.origin] then
    entry.origin = here
    changed = true
  end
  if changed then Registry.save(entries) end

  local ok, err = pcall(show_session_in_app, ctx, entry.session)
  if not ok then
    raise("session for " .. path .. " is ready, but the app would not show it: " .. tostring(err))
  end
  return { session_id = entry.session, path = path, created = created }
end

function M.close(ctx, path, main)
  path = normalize_path(path)
  if main then main = normalize_path(main) end
  local entries, live = Registry.load_live()
  local entry = entries[path]
  if entry == nil then return { closed = false } end

  local moved_to
  if not entry.adopted then
    if ctx.session_id == entry.session then
      moved_to = return_destination(entry, main, entries, live)
      if moved_to then
        local ok, err = pcall(show_session_in_app, ctx, moved_to)
        if not ok then
          warn("could not move the app to " .. moved_to .. ": " .. tostring(err))
          moved_to = nil
        end
      end
    end
    destroy_session(entry.session)
  end
  entries[path] = nil
  Registry.save(entries)
  return { closed = not entry.adopted, session_id = entry.session, moved_to = moved_to }
end

local function repo_cwd(ctx)
  local cwd = focused_terminal_cwd(ctx.block_id)
  if cwd == nil then raise("can't tell the working directory of the focused terminal") end
  return cwd
end

local function pick(title, items)
  return rex.ui.pick{
    title       = title,
    placeholder = "Filter worktrees",
    items       = items,
  }
end

local function ask(title, items)
  local value, why, detail = pick(title, items)
  if prompt_declined(value, why, detail) then return nil end
  if type(value) ~= "string" then raise("unexpected pick result") end
  return value
end

local function open_switched(ctx, listed, outcome)
  return M.go(ctx, outcome.path, {
    from   = listed and listed.current,
    branch = outcome.branch,
    main   = listed and listed.main,
  })
end

local function create_worktree(ctx, cwd, listed)
  local name, why, detail = rex.ui.input{
    title       = "New worktree",
    placeholder = "branch name",
    confirm     = "Create",
  }
  if prompt_declined(name, why, detail) then return end
  if type(name) ~= "string" then raise("unexpected input result") end
  name = trim(name)
  if name == "" then
    warn("branch name is empty")
    return
  end
  local outcome = switch_worktree(cwd, intent_create(name, create_base()))
  return open_switched(ctx, listed, outcome)
end

local function confirm_force()
  local choice, why, detail = rex.ui.pick{
    title       = "Remove dirty worktree",
    placeholder = "Uncommitted changes",
    items       = { { id = FORCE_ID, title = "Force remove", icon = "trash" } },
  }
  if prompt_declined(choice, why, detail) then return nil end
  if choice ~= FORCE_ID then raise("unexpected pick result") end
  return true
end

local function remove_chosen(ctx, cwd, listed, rows, entries)
  if #rows == 0 then
    warn("no worktree to remove")
    return
  end
  local picked = ask("Remove worktree", items_for(rows, entries, {}))
  if not picked then return end
  local row = row_by_path(rows, picked)
  if not row then raise("unknown worktree: " .. picked) end
  local force = false
  if row.dirty then
    force = confirm_force()
    if not force then return end
  end
  remove_worktree(cwd, intent_remove(row.path, force))
  return M.close(ctx, row.path, listed.main)
end

local function open_worktree(ctx)
  local cwd = repo_cwd(ctx)
  local listed = list_worktrees(cwd)
  local entries = Registry.load_live()
  local live, dead = split_rows(listed.rows)
  local extras = {}
  if #dead > 0 then extras[#extras + 1] = DEAD_ITEM end
  extras[#extras + 1] = NEW_ITEM
  extras[#extras + 1] = REMOVE_ITEM

  local picked = ask("Worktree", items_for(live, entries, extras))
  if not picked then return end

  local scope = live
  if picked == DEAD_ID then
    picked = ask("Dead worktrees", items_for(dead, entries, { REMOVE_ITEM }))
    if not picked then return end
    scope = dead
  end

  if picked == NEW_ID then return create_worktree(ctx, cwd, listed) end
  if picked == REMOVE_ID then
    return remove_chosen(ctx, cwd, listed, removable_rows(scope), entries)
  end

  local row = row_by_path(scope, picked)
  if not row then raise("unknown worktree: " .. picked) end
  return open_switched(ctx, listed, switch_worktree(cwd, intent_switch(row)))
end

local function previous_worktree(ctx)
  local cwd = repo_cwd(ctx)
  local listed = list_worktrees(cwd)
  local outcome = switch_worktree(cwd, { kind = "switch", path = "-" })
  return open_switched(ctx, listed, outcome)
end

local function main_worktree(ctx)
  local cwd = repo_cwd(ctx)
  local listed = list_worktrees(cwd)
  local intent
  if listed.main then
    local row = row_by_path(listed.rows, listed.main)
    intent = row and intent_switch(row) or { kind = "switch", path = listed.main }
  else
    intent = { kind = "switch", path = "^" }
  end
  return open_switched(ctx, listed, switch_worktree(cwd, intent))
end

local function remove_at(ctx, args)
  args = args or {}
  local path = normalize_path(args.path or "")
  if not is_trackable(path) then raise("not an absolute path: " .. tostring(args.path)) end
  local cwd = focused_terminal_cwd(ctx.block_id)
  local main
  local probe = cwd or (is_directory(path) and path or nil)
  if probe then
    local ok, listed = pcall(list_worktrees, probe)
    if ok and listed.main == path then raise("can't remove the main worktree") end
    if ok then main = listed.main end
  end
  remove_worktree(cwd, intent_remove(path, args.force == true))
  return M.close(ctx, path, main)
end

function M.setup(opts)
  for name, value in pairs(opts or {}) do
    local types = OPTION_TYPES[name]
    local fits = false
    for _, t in ipairs(types or {}) do fits = fits or type(value) == t end
    if not types then
      warn("ignoring unknown option " .. tostring(name))
    elseif not fits then
      warn("ignoring option " .. name .. ": expected a " .. table.concat(types, " or ")
        .. ", got a " .. type(value))
    else
      M.options[name] = value
    end
  end
  wt_program = nil

  rex.action{
    name        = "worktree",
    title       = "Switch or create a worktree",
    description = "List worktrees of the repo in the focused terminal. Choose one to open its session, create a worktree, or remove one.",
    category    = "Worktree",
    keywords    = "git worktree branch worktrunk wt",
    run = function(ctx) return open_worktree(ctx) end,
  }

  rex.action{
    name        = "worktree_go",
    title       = "Open Worktree Session",
    description = "Switch to the session for a worktree directory, creating it if needed.",
    category    = "Worktree",
    args        = { path = "string", from = "string?", branch = "string?", main = "string?" },
    run = function(ctx, args) return M.go(ctx, args.path, args) end,
  }

  rex.action{
    name        = "worktree_close",
    title       = "Close Worktree Session",
    description = "Close the session opened for a removed worktree. If the app is viewing it, it first goes back to the session the worktree was opened from.",
    category    = "Worktree",
    args        = { path = "string", main = "string?" },
    run = function(ctx, args) return M.close(ctx, args.path, args.main) end,
  }

  rex.action{
    name        = "worktree_previous",
    title       = "Switch to the previous worktree",
    description = "Run wt switch - in the focused terminal and open that worktree's session.",
    category    = "Worktree",
    run = function(ctx) return previous_worktree(ctx) end,
  }

  rex.action{
    name        = "worktree_main",
    title       = "Switch to the main worktree",
    description = "Open the session for the main worktree path from wt list.",
    category    = "Worktree",
    run = function(ctx) return main_worktree(ctx) end,
  }

  rex.action{
    name        = "worktree_remove",
    title       = "Remove a worktree",
    description = "Run wt remove on a worktree path, then close its session. Pass force when the worktree is dirty.",
    category    = "Worktree",
    args        = { path = "string", force = "boolean?" },
    run = function(ctx, args) return remove_at(ctx, args) end,
  }

  return M
end

return M

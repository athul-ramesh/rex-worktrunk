local json = require("json")

local MAX_LABEL = 128

local Fake = {}
Fake.__index = Fake

local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function temp_dir()
  math.randomseed(os.time())
  local base = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
  local dir = base .. "/rex-worktrunk-test." .. os.time() .. "." .. math.random(1, 1e9)
  os.execute("mkdir -p " .. shell_quote(dir))
  return dir
end

function Fake.install()
  local fake = setmetatable({ tmp = temp_dir() }, Fake)
  fake.env = { XDG_STATE_HOME = fake.tmp .. "/state" }

  local getenv = os.getenv
  os.getenv = function(name)
    if fake.env[name] ~= nil then return fake.env[name] or nil end
    return getenv(name)
  end

  rex = fake:api()
  fake:reset()
  return fake
end

function Fake:reset()
  self.dirs = {}
  self.sessions = {}
  self.apps = {}
  self.cwd = nil
  self.calls = {}
  self.logs = {}
  self.actions = {}
  self.queue_fails = nil
  self.intercept = {}
  self.ui_answers = {}
  self.wt = nil
  self.wt_missing = nil
  self.executables = {}
  self.next_id = 0
  os.execute("rm -rf " .. shell_quote(self.env.XDG_STATE_HOME))
end

function Fake:cleanup()
  os.execute("rm -rf " .. shell_quote(self.tmp))
end

function Fake:new_id(kind)
  self.next_id = self.next_id + 1
  return kind .. ":" .. self.next_id
end

function Fake:add_session(label)
  local id = self:new_id("session")
  self.sessions[#self.sessions + 1] = { session_id = id, label = label }
  return id
end

function Fake:session(id)
  for i, s in ipairs(self.sessions) do
    if s.session_id == id then return s, i end
  end
  return nil
end

function Fake:remove_session(id)
  local _, i = self:session(id)
  if i then table.remove(self.sessions, i) end
end

function Fake:labels()
  local labels = {}
  for _, s in ipairs(self.sessions) do labels[#labels + 1] = s.label end
  return labels
end

function Fake:add_app(attached, refuses)
  local app = { client_id = self:new_id("client"), attached = {}, refuses = refuses }
  for _, id in ipairs(attached or {}) do app.attached[id] = true end
  self.apps[#self.apps + 1] = app
  return app
end

function Fake:record(name, args)
  self.calls[#self.calls + 1] = { name = name, args = args }
end

function Fake:calls_to(name)
  local found = {}
  for _, call in ipairs(self.calls) do
    if call.name == name then found[#found + 1] = call end
  end
  return found
end

function Fake:first(name)
  for i, call in ipairs(self.calls) do
    if call.name == name then return i end
  end
  return nil
end

function Fake:selected()
  local ids = {}
  for _, call in ipairs(self.calls) do
    if call.name == "client.queue" and call.args.action == "session.select" then
      ids[#ids + 1] = call.args.args.session_id
    elseif call.name == "client.perform" and call.args.action == "session.select" then
      ids[#ids + 1] = call.args.args.session_id
    end
  end
  return ids
end

function Fake:warnings()
  local found = {}
  for _, log in ipairs(self.logs) do
    if log.level == "warn" then found[#found + 1] = log.message end
  end
  return found
end

function Fake:registry_lines()
  local lines = {}
  local f = io.open(self.env.XDG_STATE_HOME .. "/rex-worktrunk/sessions", "r")
  if not f then return lines end
  for line in f:lines() do lines[#lines + 1] = line end
  f:close()
  return lines
end

function Fake:write_registry(lines)
  local dir = self.env.XDG_STATE_HOME .. "/rex-worktrunk"
  os.execute("mkdir -p " .. shell_quote(dir))
  local f = assert(io.open(dir .. "/sessions", "w"))
  for _, line in ipairs(lines) do f:write(line, "\n") end
  f:close()
end

local methods = {}

function methods.session_list(fake)
  local list = {}
  for _, s in ipairs(fake.sessions) do list[#list + 1] = { session_id = s.session_id, label = s.label } end
  return { sessions = list }
end

function methods.session_create(fake, args)
  if #(args.label or "") > MAX_LABEL then return nil, "label is too long" end
  local id = fake:add_session(args.label)
  return { session_id = id }
end

function methods.session_attach(fake, args)
  if not fake:session(args.session_id) then return nil, "session_not_found" end
  return {}
end

function methods.session_destroy(fake, args)
  if not fake:session(args.session_id) then return nil, "session_not_found" end
  fake:remove_session(args.session_id)
  return {}
end

function methods.client_list(fake, args)
  local clients = {}
  for _, app in ipairs(fake.apps) do
    if args.session_id == nil or app.attached[args.session_id] then
      clients[#clients + 1] = { client_id = app.client_id }
    end
  end
  return { clients = clients }
end

function methods.client_perform(fake, args)
  for _, app in ipairs(fake.apps) do
    if app.client_id == args.client_id then
      if app.refuses then return nil, app.refuses end
      return {}
    end
  end
  return nil, "client_not_found"
end

function Fake:api()
  local fake = self
  return {
    log = function(level, message)
      fake.logs[#fake.logs + 1] = { level = level, message = message }
    end,

    exec = function(argv, opts)
      fake:record("exec", { argv = argv, cwd = opts and opts.cwd })
      if argv[1] == "test" and argv[2] == "-d" then
        local exists = fake.dirs[argv[3]] == true
        return { ok = exists, code = exists and 0 or 1, stdout = "", stderr = "" }
      end
      if argv[1] == "test" and argv[2] == "-x" then
        local path = argv[3]
        local ok = fake.executables and fake.executables[path] == true
        return { ok = ok, code = ok and 0 or 1, stdout = "", stderr = "" }
      end
      if argv[1] == "mkdir" then os.execute("mkdir -p " .. shell_quote(argv[3])) end
      local prog = argv[1]
      if prog == "wt" or (type(prog) == "string" and prog:match("/wt$")) then
        if fake.wt_missing then return nil, fake.wt_missing end
        if fake.wt then return fake.wt(argv, opts) end
        return { ok = false, code = 1, stdout = "", stderr = "wt not stubbed" }
      end
      return { ok = true, code = 0, stdout = "", stderr = "" }
    end,

    json = { decode = json.decode },

    ui = {
      pick = function(spec)
        fake:record("ui.pick", spec)
        local answer = table.remove(fake.ui_answers, 1)
        if not answer then return nil, "cancelled" end
        return answer.value, answer.why, answer.detail
      end,
      input = function(spec)
        fake:record("ui.input", spec)
        local answer = table.remove(fake.ui_answers, 1)
        if not answer then return nil, "cancelled" end
        return answer.value, answer.why, answer.detail
      end,
    },

    call = function(method, args)
      args = args or {}
      fake:record(method, args)
      local intercept = fake.intercept[method]
      if intercept then
        local handled, result, err = intercept(args)
        if handled then return result, err end
      end
      local handler = methods[method:gsub("%.", "_")]
      if not handler then return nil, "unknown method " .. method end
      return handler(fake, args)
    end,

    client = {
      queue = function(action, args)
        if fake.queue_fails then error(fake.queue_fails, 0) end
        fake:record("client.queue", { action = action, args = args })
      end,
    },

    session = {
      new_layer = function(args)
        local id = fake:new_id("layer")
        fake:record("session.new_layer", args)
        return { layer_id = id }
      end,
      close_layer = function(args)
        fake:record("session.close_layer", args)
        return {}
      end,
    },

    block = {
      call = function(creator, method, args)
        fake:record("block." .. method, args)
        if creator == "com.superlogical.terminal" and method == "process" then
          if fake.cwd == nil then return nil, "not_found" end
          return { foreground = { cwd = fake.cwd } }
        end
        return nil, "unknown block method " .. method
      end,
    },

    layout = {
      block = function(block) return { block = block } end,
    },

    action = function(definition)
      fake.actions[definition.name] = definition
    end,
  }
end

return Fake

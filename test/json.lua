local NULL = {}

local function utf8_char(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
  elseif cp < 0x10000 then
    return string.char(
      0xE0 + math.floor(cp / 0x1000),
      0x80 + (math.floor(cp / 0x40) % 0x40),
      0x80 + (cp % 0x40))
  elseif cp < 0x110000 then
    return string.char(
      0xF0 + math.floor(cp / 0x40000),
      0x80 + (math.floor(cp / 0x1000) % 0x40),
      0x80 + (math.floor(cp / 0x40) % 0x40),
      0x80 + (cp % 0x40))
  end
  return nil, "bad code point"
end

local function decode(text)
  if type(text) ~= "string" then return nil, "expected a string" end
  local i, n = 1, #text

  local function skip_ws()
    while i <= n do
      local c = text:sub(i, i)
      if c == " " or c == "\t" or c == "\n" or c == "\r" then i = i + 1 else break end
    end
  end

  local parse_value

  local function fail(message)
    return nil, message .. " at " .. i
  end

  local function parse_string()
    i = i + 1
    local parts = {}
    while i <= n do
      local c = text:sub(i, i)
      if c == '"' then
        i = i + 1
        return table.concat(parts)
      elseif c == "\\" then
        local e = text:sub(i + 1, i + 1)
        local simple = {
          ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
          b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
        }
        if simple[e] then
          parts[#parts + 1] = simple[e]
          i = i + 2
        elseif e == "u" then
          local hex = text:sub(i + 2, i + 5)
          if not hex:match("^%x%x%x%x$") then return fail("bad unicode escape") end
          local ch, err = utf8_char(tonumber(hex, 16))
          if not ch then return nil, err end
          parts[#parts + 1] = ch
          i = i + 6
        else
          return fail("bad escape")
        end
      else
        if c:byte() < 32 then return fail("control character in string") end
        parts[#parts + 1] = c
        i = i + 1
      end
    end
    return fail("unterminated string")
  end

  local function parse_number()
    local token = text:sub(i):match("^-?%d+%.?%d*[eE][+-]?%d+")
      or text:sub(i):match("^-?%d+%.?%d*")
    if not token or token == "-" then return fail("bad number") end
    local value = tonumber(token)
    if value == nil then return fail("bad number") end
    i = i + #token
    return value
  end

  local function parse_keyword()
    if text:sub(i, i + 3) == "true" then i = i + 4; return true end
    if text:sub(i, i + 4) == "false" then i = i + 5; return false end
    if text:sub(i, i + 3) == "null" then i = i + 4; return NULL end
    return fail("bad keyword")
  end

  local function parse_object()
    i = i + 1
    local obj = {}
    skip_ws()
    if text:sub(i, i) == "}" then i = i + 1; return obj end
    while true do
      skip_ws()
      if text:sub(i, i) ~= '"' then return fail("expected a key") end
      local key, err = parse_string()
      if err then return nil, err end
      skip_ws()
      if text:sub(i, i) ~= ":" then return fail("expected a colon") end
      i = i + 1
      local val, verr = parse_value()
      if verr then return nil, verr end
      if val ~= NULL then obj[key] = val end
      skip_ws()
      local c = text:sub(i, i)
      if c == "," then
        i = i + 1
      elseif c == "}" then
        i = i + 1
        return obj
      else
        return fail("expected , or }")
      end
    end
  end

  local function parse_array()
    i = i + 1
    local arr = {}
    skip_ws()
    if text:sub(i, i) == "]" then i = i + 1; return arr end
    while true do
      local val, err = parse_value()
      if err then return nil, err end
      if val ~= NULL then arr[#arr + 1] = val end
      skip_ws()
      local c = text:sub(i, i)
      if c == "," then
        i = i + 1
      elseif c == "]" then
        i = i + 1
        return arr
      else
        return fail("expected , or ]")
      end
    end
  end

  function parse_value()
    skip_ws()
    local c = text:sub(i, i)
    if c == '"' then return parse_string() end
    if c == "{" then return parse_object() end
    if c == "[" then return parse_array() end
    if c == "t" or c == "f" or c == "n" then return parse_keyword() end
    if c == "-" or c:match("%d") then return parse_number() end
    return fail("unexpected character")
  end

  local value, err = parse_value()
  if err then return nil, err end
  skip_ws()
  if i <= n then return nil, "trailing data at " .. i end
  if value == NULL then return nil end
  return value
end

return { decode = decode }

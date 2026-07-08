--[[
  json.lua — a tiny JSON decoder for the PhotoScribe Lightroom plugin.

  Decode-only, no dependencies, Lua 5.1 compatible (Lightroom Classic's
  runtime). Enough to parse the {title, caption, keywords} objects the model
  returns under structured output. Not a full validator — it's forgiving of
  trailing whitespace and handles standard escapes incl. \uXXXX (BMP + surrogate
  pairs) encoded to UTF-8.

  Usage:  local json = require 'json'
          local ok, value = pcall(json.decode, str)
]]

local json = {}

local function decodeError(str, i, msg)
  error(string.format("json: %s at position %d", msg, i))
end

local escapes = {
  ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
  b = '\b', f = '\f', n = '\n', r = '\r', t = '\t',
}

-- Encode a Unicode code point as UTF-8 (Lua 5.1 has no utf8 library).
local function utf8_encode(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40),
                       0x80 + (cp % 0x40))
  elseif cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000),
                       0x80 + (math.floor(cp / 0x40) % 0x40),
                       0x80 + (cp % 0x40))
  else
    return string.char(0xF0 + math.floor(cp / 0x40000),
                       0x80 + (math.floor(cp / 0x1000) % 0x40),
                       0x80 + (math.floor(cp / 0x40) % 0x40),
                       0x80 + (cp % 0x40))
  end
end

local parseValue  -- forward declaration

local function skipWhitespace(str, i)
  local _, j = string.find(str, "^[ \t\r\n]*", i)
  return (j or i - 1) + 1
end

local function parseString(str, i)
  -- str:sub(i,i) == '"'
  local buf, k = {}, i + 1
  while k <= #str do
    local c = string.sub(str, k, k)
    if c == '"' then
      return table.concat(buf), k + 1
    elseif c == '\\' then
      local n = string.sub(str, k + 1, k + 1)
      if escapes[n] then
        buf[#buf + 1] = escapes[n]
        k = k + 2
      elseif n == 'u' then
        local hex = string.sub(str, k + 2, k + 5)
        local cp = tonumber(hex, 16)
        if not cp then decodeError(str, k, "bad \\u escape") end
        k = k + 6
        -- Handle a UTF-16 surrogate pair
        if cp >= 0xD800 and cp <= 0xDBFF
            and string.sub(str, k, k + 1) == '\\u' then
          local lo = tonumber(string.sub(str, k + 2, k + 5), 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
            k = k + 6
          end
        end
        buf[#buf + 1] = utf8_encode(cp)
      else
        decodeError(str, k, "bad escape \\" .. n)
      end
    else
      buf[#buf + 1] = c
      k = k + 1
    end
  end
  decodeError(str, i, "unterminated string")
end

local function parseNumber(str, i)
  local s, e = string.find(str, "^%-?%d+%.?%d*[eE]?[+%-]?%d*", i)
  local num = tonumber(string.sub(str, s, e))
  if not num then decodeError(str, i, "bad number") end
  return num, e + 1
end

local function parseArray(str, i)
  local arr, k = {}, skipWhitespace(str, i + 1)
  if string.sub(str, k, k) == ']' then return arr, k + 1 end
  while true do
    local val
    val, k = parseValue(str, k)
    arr[#arr + 1] = val
    k = skipWhitespace(str, k)
    local c = string.sub(str, k, k)
    if c == ']' then return arr, k + 1 end
    if c ~= ',' then decodeError(str, k, "expected ',' or ']'") end
    k = skipWhitespace(str, k + 1)
  end
end

local function parseObject(str, i)
  local obj, k = {}, skipWhitespace(str, i + 1)
  if string.sub(str, k, k) == '}' then return obj, k + 1 end
  while true do
    if string.sub(str, k, k) ~= '"' then
      decodeError(str, k, "expected string key")
    end
    local key
    key, k = parseString(str, k)
    k = skipWhitespace(str, k)
    if string.sub(str, k, k) ~= ':' then decodeError(str, k, "expected ':'") end
    local val
    val, k = parseValue(str, skipWhitespace(str, k + 1))
    obj[key] = val
    k = skipWhitespace(str, k)
    local c = string.sub(str, k, k)
    if c == '}' then return obj, k + 1 end
    if c ~= ',' then decodeError(str, k, "expected ',' or '}'") end
    k = skipWhitespace(str, k + 1)
  end
end

parseValue = function(str, i)
  i = skipWhitespace(str, i)
  local c = string.sub(str, i, i)
  if c == '{' then return parseObject(str, i)
  elseif c == '[' then return parseArray(str, i)
  elseif c == '"' then return parseString(str, i)
  elseif c == 't' and string.sub(str, i, i + 3) == 'true' then return true, i + 4
  elseif c == 'f' and string.sub(str, i, i + 4) == 'false' then return false, i + 5
  elseif c == 'n' and string.sub(str, i, i + 3) == 'null' then return nil, i + 4
  else return parseNumber(str, i) end
end

function json.decode(str)
  if type(str) ~= 'string' then error("json.decode: expected string") end
  local value = parseValue(str, 1)
  return value
end

return json

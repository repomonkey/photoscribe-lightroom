--[[
  GenerateMetadata.lua — the PhotoScribe menu action.

  For each selected photo:
    1. Get JPEG bytes via requestJpegThumbnail (no export session).
    2. Build a prompt from the user's settings + the photo's own context
       (capture date, location, existing keywords), and POST to the local
       model asking for structured JSON {title, caption, keywords}.
    3. Snap keywords to the user's vocabulary, then write title/caption/
       keywords into the catalog (honouring the skip/write settings).

  No ExifTool — Lightroom owns its metadata. Same structured-output schema as
  the desktop app, so the model can't ramble instead of returning JSON.
]]

local LrApplication     = import 'LrApplication'
local LrTasks           = import 'LrTasks'
local LrHttp            = import 'LrHttp'
local LrDialogs         = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope   = import 'LrProgressScope'

local json  = require 'json'
local Core  = require 'PhotoScribeCore'
local Prefs = require 'PhotoScribePrefs'

-- Structured-output schema — grammar-constrains the reply to our shape.
local SCHEMA_JSON =
  '{"name":"photo_metadata","strict":true,"schema":{"type":"object",' ..
  '"properties":{"title":{"type":"string"},"caption":{"type":"string"},' ..
  '"keywords":{"type":"array","items":{"type":"string"}}},' ..
  '"required":["title","caption","keywords"]}}'

-- ── Small helpers ─────────────────────────────────────────────────

local function jsonEscape(s)
  s = tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"')
  s = s:gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
  return s
end

local function base64Encode(data)
  local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  return ((data:gsub('.', function(x)
    local r, byte = '', x:byte()
    for i = 8, 1, -1 do r = r .. (byte % 2^i - byte % 2^(i-1) > 0 and '1' or '0') end
    return r
  end) .. '0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
    if #x < 6 then return '' end
    local c = 0
    for i = 1, 6 do c = c + (x:sub(i, i) == '1' and 2^(6 - i) or 0) end
    return b:sub(c + 1, c + 1)
  end) .. ({ '', '==', '=' })[#data % 3 + 1])
end

-- Non-empty formatted metadata field, or nil.
local function meta(photo, key)
  local v = photo:getFormattedMetadata(key)
  if v and v ~= '' then return v end
  return nil
end

-- Read a photo's keywords, split into person keywords (named faces, from
-- Lightroom's People feature — keywordType == 'person') and regular keywords.
local function readKeywords(photo)
  local persons, regular, dbg = {}, {}, {}
  local ok, list = pcall(function() return photo:getRawMetadata('keywords') end)
  if ok and list then
    for _, kw in ipairs(list) do
      local name = select(2, pcall(function() return kw:getName() end))
      if name and name ~= '' then
        local _, attrs = pcall(function() return kw:getAttributes() end)
        local ktype = (type(attrs) == 'table' and attrs.keywordType) or 'nil'
        dbg[#dbg + 1] = name .. '[' .. tostring(ktype) .. ']'
        if ktype == 'person' then
          persons[#persons + 1] = name
        else
          regular[#regular + 1] = name
        end
      end
    end
  end
  return persons, regular, table.concat(dbg, ', ')
end

-- Reverse-geocode GPS to a readable place via OpenStreetMap Nominatim.
-- Returns (label, addressTable) or nil. Only called when enabled and needed,
-- so we stay well within Nominatim's usage policy (1 req/sec).
local function reverseGeocode(lat, lon)
  local url = string.format(
    'https://nominatim.openstreetmap.org/reverse?format=json&lat=%.6f&lon=%.6f&zoom=13&addressdetails=1',
    lat, lon)
  local headers = { {
    field = 'User-Agent',
    value = 'PhotoScribe-Lightroom/0.3 (+https://github.com/repomonkey/photoscribe-lightroom)',
  } }
  local resp = LrHttp.get(url, headers, 15)
  if not resp or resp == '' then return nil end
  local ok, data = pcall(json.decode, resp)
  if not ok or type(data) ~= 'table' or type(data.address) ~= 'table' then return nil end
  local a = data.address
  -- Prefer the most specific settlement-like name. `locality`/`neighbourhood`
  -- matter for rural/coastal AU spots (e.g. "Shoalhaven Heads" comes back as
  -- locality, not town).
  local place = a.suburb or a.town or a.village or a.hamlet or a.locality
             or a.neighbourhood or a.city or a.municipality or a.county
  local out = {}
  if place then out[#out + 1] = place end
  if a.state then out[#out + 1] = a.state end
  if a.country then out[#out + 1] = a.country end
  local label = table.concat(out, ', ')
  if label == '' then return nil end
  return label, a
end

-- Determine a location string for the photo. Prefers existing catalog fields;
-- if there are none and GPS reverse-geocoding is enabled, looks it up.
-- Returns (label, geoAddress) where geoAddress is non-nil only when we looked
-- it up (so the caller can optionally write it back).
-- Returns (label, geoAddress, diag). geoAddress is non-nil only when looked up
-- (for optional write-back); diag explains the outcome for the summary.
local function resolveLocation(photo, settings)
  local place = {}
  for _, key in ipairs({ 'location', 'city', 'stateProvince', 'country' }) do
    local v = meta(photo, key)
    if v then place[#place + 1] = v end
  end
  if #place > 0 then
    return table.concat(place, ', '), nil, 'from catalog location fields'
  end
  if not settings.geocode then
    return nil, nil, '"Look up place names from GPS" is OFF in Settings'
  end
  local gps = photo:getRawMetadata('gps')
  if not gps or not gps.latitude or not gps.longitude then
    return nil, nil, 'no GPS coordinates readable on this photo'
  end
  -- Never let a geocode hiccup fail the photo. LrTasks.pcall (reverseGeocode
  -- yields on the HTTP call, so a plain pcall can't wrap it).
  local ok, label, addr = LrTasks.pcall(reverseGeocode, gps.latitude, gps.longitude)
  if not ok then
    return nil, nil, 'GPS lookup errored: ' .. tostring(label)
  end
  if not label then
    return nil, nil, string.format(
      'OpenStreetMap returned no place for %.5f, %.5f', gps.latitude, gps.longitude)
  end
  return label, addr, 'from GPS lookup'
end

-- Assemble the non-location context string (date + extra notes). Location is
-- passed to the prompt separately so it can be framed as usable ground truth.
local function buildContext(photo, settings)
  local parts = {}
  local extra = Core.trim(settings.extraContext or '')
  if extra ~= '' then parts[#parts + 1] = extra end
  if settings.useContext then
    local date = meta(photo, 'dateCreated')
    if date then parts[#parts + 1] = 'Date: ' .. date end
  end
  return table.concat(parts, '; ')
end

-- Get JPEG bytes for a photo (thumbnail render; ample for a vision model).
local function getJpegBytes(photo, maxEdge)
  local done, jpeg, errMsg = false, nil, nil
  photo:requestJpegThumbnail(maxEdge, maxEdge, function(data, err)
    jpeg, errMsg, done = data, err, true
  end)
  local waited = 0
  while not done and waited < 30 do
    LrTasks.sleep(0.1)
    waited = waited + 0.1
  end
  if not done then return nil, 'timed out rendering thumbnail' end
  if not jpeg then return nil, tostring(errMsg or 'no thumbnail data') end
  return jpeg
end

-- Ask the model. Returns a {title,caption,keywords} table or (nil, errMsg).
local function generateFor(photo, settings)
  local bytes, err = getJpegBytes(photo, settings.maxLongEdge or 1024)
  if not bytes then return nil, 'render failed: ' .. tostring(err) end

  local locationLabel, geoAddr, locDiag = resolveLocation(photo, settings)

  local persons, regularKeywords, kwDebug = {}, {}, ''
  if settings.useContext or settings.describePeople then
    persons, regularKeywords, kwDebug = readKeywords(photo)
  end

  local prompt = Core.buildPrompt({
    basePrompt       = settings.promptText,
    context          = buildContext(photo, settings),
    location         = settings.useContext and locationLabel or nil,
    existingKeywords = settings.useContext and regularKeywords or {},
    persons          = settings.describePeople and persons or {},
    describePeople   = settings.describePeople,
    vocab            = settings._vocabList,
    density          = settings.keywordDensity,
  })

  local b64 = base64Encode(bytes)
  local body =
    '{"model":"' .. jsonEscape(settings.model) .. '",' ..
    '"messages":[{"role":"user","content":[' ..
    '{"type":"text","text":"' .. jsonEscape(prompt) .. '"},' ..
    '{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,' .. b64 .. '"}}' ..
    ']}],' ..
    '"response_format":{"type":"json_schema","json_schema":' .. SCHEMA_JSON .. '},' ..
    '"temperature":0.3,"max_tokens":1024,"stream":false}'

  local headers = { { field = 'Content-Type', value = 'application/json' } }
  local response, respHeaders = LrHttp.post(settings.endpoint, body, headers)
  if not response then
    local detail = respHeaders and respHeaders.error and respHeaders.error.name or 'no response'
    return nil, 'request failed (' .. tostring(detail) .. ') — is the model server running at ' .. settings.endpoint .. '?'
  end

  local ok, envelope = pcall(json.decode, response)
  if not ok or type(envelope) ~= 'table' then
    return nil, 'could not parse server response'
  end
  local choice = envelope.choices and envelope.choices[1]
  local content = choice and choice.message and choice.message.content
  if not content or content == '' then
    return nil, 'empty response from model'
  end

  local ok2, m = pcall(json.decode, content)
  if not ok2 or type(m) ~= 'table' then
    return nil, 'model reply was not valid JSON'
  end
  -- Stash the geocode result (if any) for optional write-back, and the
  -- resolved location for the diagnostic summary.
  if geoAddr then m.__geo = geoAddr end
  m.__loc = locationLabel
  m.__locDiag = locDiag
  m.__persons = table.concat(persons, ', ')
  m.__kwDebug = kwDebug
  -- Probe alternate accessors for person/keyword data (diagnostic).
  local function fmt(key)
    local okf, v = pcall(function() return photo:getFormattedMetadata(key) end)
    return (okf and v and v ~= '' and v) or '(empty)'
  end
  m.__kwTags   = fmt('keywordTags')
  m.__kwExport = fmt('keywordTagsForExport')
  return m
end

-- Write generated metadata into the catalog for one photo.
local function writeMetadata(catalog, photo, m, settings)
  local keywords = Core.cleanKeywords(m.keywords or {}, settings._vocabList)
  local existingTitle   = meta(photo, 'title')
  local existingCaption = meta(photo, 'caption')

  catalog:withWriteAccessDo('PhotoScribe: write metadata', function()
    if settings.writeTitle and type(m.title) == 'string' and m.title ~= ''
        and not (settings.skipExisting and existingTitle) then
      photo:setRawMetadata('title', m.title)
    end
    if settings.writeCaption and type(m.caption) == 'string' and m.caption ~= ''
        and not (settings.skipExisting and existingCaption) then
      photo:setRawMetadata('caption', m.caption)
    end
    for _, kw in ipairs(keywords) do
      if kw ~= '' then
        local keyword = catalog:createKeyword(kw, {}, false, nil, true)
        if keyword then photo:addKeyword(keyword) end
      end
    end

    -- Optionally write the reverse-geocoded place into the catalog fields.
    if settings.writeGeocode and type(m.__geo) == 'table' then
      local a = m.__geo
      local city = a.suburb or a.town or a.village or a.hamlet or a.locality
                or a.neighbourhood or a.city or a.municipality
      if city then photo:setRawMetadata('city', city) end
      if a.state then photo:setRawMetadata('stateProvince', a.state) end
      if a.country then photo:setRawMetadata('country', a.country) end
    end
  end, { timeout = 30 })
end

-- ── Entry point ───────────────────────────────────────────────────

LrTasks.startAsyncTask(function()
  LrFunctionContext.callWithContext('PhotoScribe', function(context)
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()
    if not photos or #photos == 0 then
      LrDialogs.message('PhotoScribe', 'Select one or more photos first.', 'info')
      return
    end

    local settings = Prefs.get()
    settings._vocabList = Core.parseVocab(settings.vocabulary)

    local progress = LrProgressScope({
      title = 'PhotoScribe: generating metadata',
      functionContext = context,
    })
    progress:setCancelable(true)

    local done, failed, firstError, lastLoc, lastDiag = 0, 0, nil, nil, nil
    local lastPersons, lastKwDebug, lastKwTags, lastKwExport = nil, nil, nil, nil
    for i, photo in ipairs(photos) do
      if progress:isCanceled() then break end
      local name = meta(photo, 'fileName') or ('photo ' .. i)
      progress:setPortionComplete(i - 1, #photos)
      progress:setCaption('Processing ' .. name)

      -- LrTasks.pcall (not plain pcall): these yield (sleep/HTTP/catalog write)
      -- and Lua 5.1 can't yield across a plain pcall's C boundary.
      -- Capture err too: on a graceful (nil, msg) return pcall gives
      -- (true, nil, msg); on a thrown error it gives (false, errObj).
      local ok, m, err = LrTasks.pcall(generateFor, photo, settings)
      if ok and m then
        lastLoc = m.__loc
        lastDiag = m.__locDiag
        lastPersons = m.__persons
        lastKwDebug = m.__kwDebug
        lastKwTags = m.__kwTags
        lastKwExport = m.__kwExport
        local wrote, werr = LrTasks.pcall(writeMetadata, catalog, photo, m, settings)
        if wrote then done = done + 1
        else failed = failed + 1; firstError = firstError or (name .. ' write: ' .. tostring(werr)) end
      else
        failed = failed + 1
        firstError = firstError or (name .. ': ' .. tostring(err or m))
      end
    end

    progress:done()

    local summary = string.format('Done: %d written, %d failed.', done, failed)
    if #photos == 1 and done == 1 then
      if lastLoc and lastLoc ~= '' then
        summary = summary .. '\n\nLocation fed to model: ' .. lastLoc ..
          '\n(' .. tostring(lastDiag) .. ')'
      else
        summary = summary .. '\n\nNo location fed to model: ' .. tostring(lastDiag)
      end
      summary = summary .. '\n\nPeople found: ' ..
        (lastPersons and lastPersons ~= '' and lastPersons or '(none)')
      summary = summary .. '\ngetRawMetadata keywords: ' ..
        (lastKwDebug and lastKwDebug ~= '' and lastKwDebug or '(none)')
      summary = summary .. '\nkeywordTags: ' .. tostring(lastKwTags)
      summary = summary .. '\nkeywordTagsForExport: ' .. tostring(lastKwExport)
    end
    if firstError then summary = summary .. '\n\nFirst error:\n' .. firstError end
    LrDialogs.message('PhotoScribe', summary, failed > 0 and 'warning' or 'info')
  end)
end)

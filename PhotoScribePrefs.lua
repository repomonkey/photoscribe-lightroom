--[[
  PhotoScribePrefs.lua — plugin preferences (persisted by Lightroom).

  Wraps LrPrefs so the rest of the plugin reads settings with sensible
  defaults, whether or not the user has opened the Settings dialog yet.
]]

local LrPrefs = import 'LrPrefs'
local prefs = LrPrefs.prefsForPlugin()

local M = {}

M.DEFAULTS = {
  endpoint       = 'http://localhost:1234/v1/chat/completions',
  model          = 'google/gemma-4-12b',
  maxLongEdge    = 1024,
  keywordDensity = 'standard',   -- 'fewer' | 'standard' | 'more'
  describePeople = true,
  skipExisting   = false,
  writeTitle     = true,
  writeCaption   = true,
  useContext     = true,         -- feed capture date / location / existing keywords
  geocode        = false,        -- reverse-geocode GPS via OpenStreetMap when no location fields
  writeGeocode   = false,        -- write the looked-up place back into the catalog
  vocabulary     = '',           -- newline/comma-separated preferred keywords
  extraContext   = '',           -- freeform text added to every prompt
}

-- The live, persisted prefs table (write to this to save).
function M.raw()
  return prefs
end

-- A plain table of current values, filling in defaults for anything unset.
function M.get()
  local out = {}
  for k, default in pairs(M.DEFAULTS) do
    local v = prefs[k]
    if v == nil then v = default end
    out[k] = v
  end
  return out
end

return M

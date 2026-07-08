--[[
  PhotoScribeSettings.lua — the Settings dialog (Plug-in Extras > PhotoScribe
  Settings…). Edits the persisted preferences used by GenerateMetadata.
]]

local LrView            = import 'LrView'
local LrDialogs         = import 'LrDialogs'
local LrBinding         = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'

local Prefs = require 'PhotoScribePrefs'

LrFunctionContext.callWithContext('PhotoScribeSettings', function(context)
  local prefs = Prefs.raw()
  local current = Prefs.get()

  local props = LrBinding.makePropertyTable(context)
  for k in pairs(Prefs.DEFAULTS) do
    props[k] = current[k]
  end

  local f = LrView.osFactory()
  local bind = LrView.bind
  local labelWidth = 130

  local contents = f:column {
    bind_to_object = props,
    spacing = f:control_spacing(),

    f:row {
      f:static_text { title = 'Model server URL:', width = labelWidth },
      f:edit_field  { value = bind 'endpoint', width_in_chars = 42 },
    },
    f:static_text {
      title = 'LM Studio: http://localhost:1234/v1/chat/completions   ·   Ollama: http://localhost:11434/v1/chat/completions',
      font = '<system/small>',
    },

    f:row {
      f:static_text { title = 'Model name:', width = labelWidth },
      f:edit_field  { value = bind 'model', width_in_chars = 32 },
    },

    f:row {
      f:static_text { title = 'Keyword density:', width = labelWidth },
      f:popup_menu {
        value = bind 'keywordDensity',
        items = {
          { title = 'Fewer (5-8)',     value = 'fewer' },
          { title = 'Standard (10-15)', value = 'standard' },
          { title = 'More (15-25)',    value = 'more' },
        },
      },
    },

    f:spacer { height = 6 },

    f:checkbox { title = 'Describe people generically (never invent names)', value = bind 'describePeople' },
    f:checkbox { title = 'Use photo context (capture date, location, existing keywords)', value = bind 'useContext' },
    f:checkbox { title = 'Skip title/caption if the photo already has one', value = bind 'skipExisting' },

    f:checkbox {
      title = 'Look up place names from GPS when no location is set (uses OpenStreetMap — an external request)',
      value = bind 'geocode',
    },
    f:row {
      f:spacer { width = 20 },
      f:checkbox { title = 'Also write the looked-up place into the catalog (Sublocation/City/State/Country)', value = bind 'writeGeocode' },
    },

    f:row {
      f:checkbox { title = 'Write title', value = bind 'writeTitle' },
      f:checkbox { title = 'Write caption', value = bind 'writeCaption' },
    },

    f:spacer { height = 6 },

    f:static_text {
      title = 'Keyword vocabulary (one per line or comma-separated).\nGenerated keywords are snapped to this spelling and these terms are preferred:',
    },
    f:edit_field {
      value = bind 'vocabulary',
      width_in_chars = 52,
      height_in_lines = 6,
    },

    f:static_text { title = 'Extra context added to every prompt (optional):' },
    f:edit_field {
      value = bind 'extraContext',
      width_in_chars = 52,
      height_in_lines = 2,
    },
  }

  local result = LrDialogs.presentModalDialog {
    title = 'PhotoScribe Settings',
    contents = contents,
    resizable = true,
  }

  if result == 'ok' then
    for k in pairs(Prefs.DEFAULTS) do
      prefs[k] = props[k]
    end
  end
end)

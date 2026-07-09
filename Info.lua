--[[
  PhotoScribe for Lightroom Classic — plugin manifest.

  Proof-of-concept: adds one menu item under Library > Plug-in Extras that
  generates a title, caption, and keywords for the selected photos using a
  LOCAL model (LM Studio / Ollama) and writes them into the catalog.

  This is deliberately minimal — no options UI, hard-coded endpoint/model in
  GenerateMetadata.lua. It exists to prove the round-trip in Lua.
]]

return {
  LrSdkVersion = 13.0,
  LrSdkMinimumVersion = 6.0,  -- runs on any reasonably recent LrC

  LrToolkitIdentifier = 'au.com.andyhutchinson.photoscribe',
  LrPluginName = 'PhotoScribe',

  VERSION = { major = 0, minor = 4, revision = 8, build = 0 },

  -- File > Plug-in Extras (where DxO, ON1, Peakto, etc. appear).
  LrExportMenuItems = {
    {
      title = 'Generate Metadata with PhotoScribe',
      file = 'GenerateMetadata.lua',
    },
    {
      title = 'PhotoScribe Settings…',
      file = 'PhotoScribeSettings.lua',
    },
  },

  -- Also Library > Plug-in Extras and the right-click "Plug-in Extras"
  -- context submenu when photos are selected.
  LrLibraryMenuItems = {
    {
      title = 'Generate Metadata with PhotoScribe',
      file = 'GenerateMetadata.lua',
    },
    {
      title = 'PhotoScribe Settings…',
      file = 'PhotoScribeSettings.lua',
    },
  },
}

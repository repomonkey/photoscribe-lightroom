--[[
  PhotoScribeCore.lua — pure-Lua helpers (no Lightroom imports).

  Prompt assembly and keyword normalisation, kept dependency-free so they can
  be unit-tested outside Lightroom. Mirrors the desktop app's behaviour:
  vocabulary preference + spelling-snap, existing-tag awareness, and the
  anti-confabulation instruction.
]]

local M = {}

local function trim(s)
  return (tostring(s):gsub('^%s+', ''):gsub('%s+$', ''))
end
M.trim = trim

-- Split a vocabulary blob (newlines and/or commas) into a de-duplicated list,
-- preserving first-seen order and original spelling.
function M.parseVocab(blob)
  local out, seen = {}, {}
  for token in tostring(blob or ''):gmatch('[^,\n\r]+') do
    local t = trim(token)
    if t ~= '' and not seen[t:lower()] then
      seen[t:lower()] = true
      out[#out + 1] = t
    end
  end
  return out
end

-- Normalise the model's keywords: coerce to strings, drop blanks, snap to the
-- vocabulary's spelling (case-insensitive), and drop case-insensitive dupes.
function M.cleanKeywords(raw, vocabList)
  local canon = {}
  for _, v in ipairs(vocabList or {}) do
    canon[v:lower()] = v
  end
  local out, seen = {}, {}
  for _, kw in ipairs(raw or {}) do
    -- Normalise snake_case the model sometimes emits ("golden_hour") to
    -- spaces, so it reads naturally and can snap to a spaced vocabulary term.
    local k = trim(tostring(kw):gsub('_', ' '))
    if k ~= '' then
      local final = canon[k:lower()] or k
      local key = final:lower()
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = final
      end
    end
  end
  return out
end

local DENSITY = {
  fewer    = '5 to 8',
  standard = '10 to 15',
  more     = '15 to 25',
}

function M.densityPhrase(density)
  return DENSITY[density] or DENSITY.standard
end

-- Editable base-prompt presets (the "style"). Genre steer only — the keyword
-- count comes from the density setting, and context/location/people/tags/JSON
-- scaffolding is added by buildPrompt, so presets stay short and editable.
M.PRESET_ORDER = { 'Default', 'Landscape', 'Event', 'Product' }

M.PRESETS = {
  Default =
    'You are a photo metadata generator. Look at the image and write a short, ' ..
    'descriptive title (5-10 words) and a caption of 1-3 sentences, plus a set ' ..
    'of relevant keywords.',
  Landscape =
    'You are writing metadata for a landscape or nature photograph. Write a ' ..
    'short, evocative title (5-10 words) and a caption of 1-3 sentences that ' ..
    'convey the setting, light, weather and mood, plus a set of relevant ' ..
    'keywords. Emphasise natural features, terrain, conditions and time of day.',
  Event =
    'You are writing metadata for an event or documentary photograph. Write a ' ..
    'short, descriptive title (5-10 words) and a caption of 1-3 sentences that ' ..
    'convey the activity, atmosphere and setting, plus a set of relevant ' ..
    'keywords. Describe what is happening and the roles of any people.',
  Product =
    'You are writing metadata for a product or commercial photograph. Write a ' ..
    'short, clean title (5-10 words) and a caption of 1-3 sentences describing ' ..
    'the product, its materials, colour, form and setting, plus a set of ' ..
    'relevant keywords. Keep the tone neutral and commercial.',
}

function M.presetNames()
  return M.PRESET_ORDER
end

function M.presetText(name)
  return M.PRESETS[name] or M.PRESETS.Default
end

-- Build the prompt text from a plain options table:
--   context         string  (may be '')
--   existingKeywords table   (list of strings)
--   describePeople  boolean
--   vocab           table   (list of preferred keyword strings)
--   density         string  ('fewer'|'standard'|'more')
function M.buildPrompt(opts)
  opts = opts or {}
  local parts = {}

  -- Base prompt: the user's editable style text (falls back to Default).
  local base = trim(opts.basePrompt or '')
  if base == '' then base = M.PRESETS.Default end
  parts[#parts + 1] = base
  parts[#parts + 1] = 'Aim for about ' .. M.densityPhrase(opts.density) .. ' keywords.'

  local context = trim(opts.context or '')
  if context ~= '' then
    parts[#parts + 1] = 'Context for this photo: ' .. context .. '.'
  end

  -- A provided location is ground truth, not a guess — invite the model to
  -- name it in the title/caption (this is what lets "Kiama" reach the prose,
  -- not just the keywords).
  local location = trim(opts.location or '')
  if location ~= '' then
    parts[#parts + 1] =
      'This photo was taken at: ' .. location .. '. This is accurate, provided ' ..
      'information. Include this place name in the title and in the caption, ' ..
      'and add it to the keywords. Do not name a more specific spot than this ' ..
      'unless it is legible in the image.'
  end

  if opts.describePeople then
    local persons = opts.persons or {}
    if #persons > 0 then
      parts[#parts + 1] =
        'People identified in this photo: ' .. table.concat(persons, ', ') ..
        '. Use these exact names when referring to them in the title and ' ..
        'caption, and include them in the keywords. Never invent names; refer ' ..
        'to any other, unnamed people neutrally (e.g. "another person").'
    else
      parts[#parts + 1] =
        'If people are visible, describe their positions, roles and actions ' ..
        'generically (e.g. "a group of hikers"); do not invent names.'
    end
  end

  local existing = opts.existingKeywords or {}
  if #existing > 0 then
    parts[#parts + 1] =
      'This photo is already tagged with: ' .. table.concat(existing, ', ') ..
      '. These tags are accurate — use the specific ones (species, place ' ..
      'names, events) in the title and caption where they fit, and keep them ' ..
      'in the keywords.'
  end

  local vocab = opts.vocab or {}
  if #vocab > 0 then
    parts[#parts + 1] =
      'Prefer these keywords where they genuinely apply: ' ..
      table.concat(vocab, ', ') .. '.'
  end

  parts[#parts + 1] =
    'Aside from the location, people and tags provided above (which are ' ..
    'accurate), only state a specific place, species, landmark, or person ' ..
    'name if you are certain from the image; otherwise stay general (e.g. "a ' ..
    'bridge over a river"). Better general and correct than specific and wrong.'

  return table.concat(parts, ' ')
end

return M

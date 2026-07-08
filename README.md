# PhotoScribe for Lightroom Classic — proof of concept

A minimal Lightroom Classic plugin that generates a **title, caption, and
keywords** for the selected photos using a **local** model (LM Studio or
Ollama) and writes them straight into the catalog — no cloud, no ExifTool,
no export/import round-trip.

This is a **proof of concept**: one menu item, hard-coded endpoint/model, a
simplified prompt. It exists to prove the round-trip works in Lua before
building it out. The genuinely hard parts (the local model, the structured
output that forces clean JSON) are shared with the standalone PhotoScribe app
and carry over unchanged because they're just HTTP.

## What it does

For each selected photo:

1. Renders a downsized JPEG (Lightroom's own render) to a temp file.
2. Base64-encodes it and POSTs it to the local model, requesting structured
   JSON (`{title, caption, keywords}`) — the same schema the desktop app uses,
   which stops the model rambling in prose instead of answering.
3. Parses the reply and writes `title`, `caption`, and `keywords` into the
   catalog.

## Requirements

- Lightroom Classic 6 or newer.
- A local model server running, with a **vision** model loaded:
  - **LM Studio** — OpenAI-compatible server on `http://localhost:1234`
    (the default). Load a vision model, e.g. `google/gemma-4-12b`.
  - **Ollama** — set `ENDPOINT` to `http://localhost:11434/v1/chat/completions`.

## Install

1. In Lightroom Classic: **File → Plug-in Manager… → Add**.
2. Select this `PhotoScribe.lrdevplugin` folder.
3. It appears in the list as **PhotoScribe**.

## Use

1. Select one or more photos in the Library.
2. **Library → Plug-in Extras → Generate Metadata with PhotoScribe**
   (also in the right-click **Plug-in Extras** submenu).
3. Watch the progress bar; a summary dialog reports how many were written.

## Configuration (edit `GenerateMetadata.lua`)

```lua
local ENDPOINT = 'http://localhost:1234/v1/chat/completions'
local MODEL    = 'google/gemma-4-12b'
local MAX_LONG_EDGE = 1024   -- size of the render sent to the model
```

## Status — what's verified vs not

Validated outside Lightroom (via the Lua interpreter + the live model):

- ✅ The JSON decoder (`json.lua`) — objects, arrays, escapes, UTF-8.
- ✅ The base64 encoder — against RFC 4648 test vectors.
- ✅ The **full request/response round-trip** against LM Studio + Gemma-4-12B:
  the exact payload this plugin builds is accepted, structured output returns
  clean JSON, and our decoder extracts title/caption/keywords correctly.

Needs Lightroom itself to exercise:

- ⏳ `photo:requestJpegThumbnail` to get the image bytes (replaced an earlier
  `LrExportSession` approach, which hit the SDK's "must not call on main UI
  task" rule for renditions).
- ⏳ Writing `title` / `caption` / `keywords` into the catalog
  (`setRawMetadata`, `createKeyword`, `addKeyword`).

## Not in the POC (obvious follow-ups)

- Options UI (endpoint, model, prompt, keyword density) via `LrView`.
- Porting the desktop app's fuller prompt: batch/context, person-aware and
  existing-tag awareness, keyword vocabulary snapping.
- "Skip if already has a title/caption" and append-vs-replace keyword modes.
- Ollama tested (only LM Studio's OpenAI shape is verified so far).
- Packaging as a signed `.lrplugin` / Adobe Exchange listing.

## Layout

- `Info.lua` — plugin manifest + menu item.
- `GenerateMetadata.lua` — the action (render → model → write).
- `json.lua` — dependency-free JSON decoder (Lua 5.1 compatible).

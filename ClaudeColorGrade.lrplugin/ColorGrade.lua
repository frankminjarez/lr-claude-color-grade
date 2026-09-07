--[[
  Claude AI Color Grade for Lightroom Classic
  ColorGrade.lua — Main action

  Flow for each selected photo:
    1. Read current develop settings (WB, Tone, Presence, Curve, HSL, Color Grading)
    2. Request a JPEG thumbnail from Lightroom's preview cache
    3. Base64-encode the JPEG bytes
    4. POST image + current settings + style target to Anthropic Messages API
    5. Parse JSON response — full set of develop adjustments + reasoning
    6. Apply via catalog write access
    7. Show per-photo summary dialog with before→after and Claude's reasoning

  Scope: White Balance, Tone, Presence, Parametric Tone Curve,
         HSL Color Mixer, Color Grading (shadows/midtones/highlights).
--]]

local LrApplication      = import 'LrApplication'
local LrBinding          = import 'LrBinding'
local LrDialogs          = import 'LrDialogs'
local LrFunctionContext  = import 'LrFunctionContext'
local LrHttp             = import 'LrHttp'
local LrPrefs            = import 'LrPrefs'
local LrProgressScope    = import 'LrProgressScope'
local LrTasks            = import 'LrTasks'
local LrStringUtils      = import 'LrStringUtils'
local LrView             = import 'LrView'

local json          = require 'json'
local CANNED_STYLES = require 'Styles'

local pluginPrefs = LrPrefs.prefsForPlugin()

-- ─────────────────────────────────────────────────────────
-- Base64 encoder (pure Lua)
-- ─────────────────────────────────────────────────────────
local B64_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

local function base64Encode(data)
    local result  = {}
    local dataLen = #data
    local padding = (3 - (dataLen % 3)) % 3

    for i = 1, dataLen + padding, 3 do
        local b1 = data:byte(i)     or 0
        local b2 = data:byte(i + 1) or 0
        local b3 = data:byte(i + 2) or 0
        local n  = b1 * 65536 + b2 * 256 + b3
        result[#result + 1] = B64_CHARS:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
        result[#result + 1] = B64_CHARS:sub(math.floor(n / 4096)   % 64 + 1, math.floor(n / 4096)   % 64 + 1)
        result[#result + 1] = B64_CHARS:sub(math.floor(n / 64)     % 64 + 1, math.floor(n / 64)     % 64 + 1)
        result[#result + 1] = B64_CHARS:sub(n % 64 + 1,                      n % 64 + 1)
    end

    local encoded = table.concat(result)
    if padding == 2 then encoded = encoded:sub(1, #encoded - 2) .. '=='
    elseif padding == 1 then encoded = encoded:sub(1, #encoded - 1) .. '='
    end
    return encoded
end

-- ─────────────────────────────────────────────────────────
-- JPEG dimension reader (pure Lua — parses SOF marker)
-- ─────────────────────────────────────────────────────────
local function getJpegDimensions(data)
    if not data or #data < 4 then return nil, nil end
    if data:byte(1) ~= 0xFF or data:byte(2) ~= 0xD8 then return nil, nil end
    local i = 3
    while i <= #data - 8 do
        if data:byte(i) ~= 0xFF then break end
        local marker = data:byte(i + 1)
        if marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC
           and marker >= 0xC0 and marker <= 0xCF then
            local h = data:byte(i + 5) * 256 + data:byte(i + 6)
            local w = data:byte(i + 7) * 256 + data:byte(i + 8)
            return w, h
        end
        local segLen = data:byte(i + 2) * 256 + data:byte(i + 3)
        if segLen < 2 then break end
        i = i + 2 + segLen
    end
    return nil, nil
end

local MAX_IMAGE_DIM   = 7999
local MAX_IMAGE_BYTES = 9 * 1024 * 1024

-- ─────────────────────────────────────────────────────────
-- Async thumbnail retrieval
--
-- When Lightroom marks a preview stale (e.g. after develop settings change),
-- requestJpegThumbnail returns an error on every attempt regardless of how
-- long you wait.  The only reliable reset is for the user to click away to
-- another photo and back — this resets Lightroom's internal preview state.
--
-- catalog:setSelectedPhotos() cannot be called from inside an async task
-- while a progress scope is active (Lightroom asserts).  So after exhausting
-- retries we surface a clear instruction instead.
-- ─────────────────────────────────────────────────────────
local function getPhotoThumbnail(photo, size)
    local MAX_ATTEMPTS = 3

    for attempt = 1, MAX_ATTEMPTS do
        local jpegData, thumbError, done = nil, nil, false

        photo:requestJpegThumbnail(size, size, function(data, errorMsg)
            if data and #data > 0 then jpegData = data
            else thumbError = errorMsg or 'unknown' end
            done = true
        end)

        local deadline = os.time() + 30
        while not done do
            LrTasks.yield()
            if os.time() > deadline then
                return nil, 'Timed out waiting for preview. Go to Library \226\150\184 Previews \226\150\184 Build Standard-Sized Previews and retry.'
            end
        end

        if jpegData then
            if #jpegData > MAX_IMAGE_BYTES then
                return nil, string.format(
                    'Preview is too large to send (%.1f MB \226\128\148 limit is 9 MB). ' ..
                    'Go to Library \226\150\184 Previews \226\150\184 Build Standard-Sized Previews and retry.',
                    #jpegData / (1024 * 1024))
            end
            local w, h = getJpegDimensions(jpegData)
            if w and h and (w > MAX_IMAGE_DIM or h > MAX_IMAGE_DIM) then
                return nil, string.format(
                    'Preview too large (%d\195\151%d px, limit 8000 px). ' ..
                    'Go to Library \226\150\184 Previews \226\150\184 Build Standard-Sized Previews and retry.',
                    w, h)
            end
            return jpegData, nil
        end

        -- Brief yield between attempts before giving up
        LrTasks.yield()
    end

    return nil, 'Preview appears stale. Click a different photo and then ' ..
        're-select this one to reset the preview, then run Grade again. ' ..
        'Or go to Library \226\150\184 Previews \226\150\184 Build Standard-Sized Previews.'
end

-- ─────────────────────────────────────────────────────────
-- Read all relevant develop settings
-- ─────────────────────────────────────────────────────────
local HSL_COLORS = { 'Red', 'Orange', 'Yellow', 'Green', 'Aqua', 'Blue', 'Purple', 'Magenta' }

local function readCurrentSettings(photo)
    local ds = photo:getDevelopSettings()
    if not ds then return {} end
    local s = {}

    -- White Balance
    s.WhiteBalance  = ds.WhiteBalance  or 'Custom'
    s.Temperature   = ds.Temperature   or 5500
    s.Tint          = ds.Tint          or 0

    -- Basic Tone
    s.Exposure2012   = ds.Exposure2012   or 0
    s.Contrast2012   = ds.Contrast2012   or 0
    s.Highlights2012 = ds.Highlights2012 or 0
    s.Shadows2012    = ds.Shadows2012    or 0
    s.Whites2012     = ds.Whites2012     or 0
    s.Blacks2012     = ds.Blacks2012     or 0

    -- Presence
    s.Clarity2012 = ds.Clarity2012 or 0
    s.Vibrance    = ds.Vibrance    or 0
    s.Saturation  = ds.Saturation  or 0

    -- Parametric Tone Curve
    s.ParametricShadows    = ds.ParametricShadows    or 0
    s.ParametricDarks      = ds.ParametricDarks      or 0
    s.ParametricLights     = ds.ParametricLights     or 0
    s.ParametricHighlights = ds.ParametricHighlights or 0

    -- HSL
    for _, color in ipairs(HSL_COLORS) do
        s['HueAdjustment'        .. color] = ds['HueAdjustment'        .. color] or 0
        s['SaturationAdjustment' .. color] = ds['SaturationAdjustment' .. color] or 0
        s['LuminanceAdjustment'  .. color] = ds['LuminanceAdjustment'  .. color] or 0
    end

    -- Color Grading (LR 10+ keys; fall back to Split Toning keys)
    s.CGShadowHue    = ds.ColorGradeShadowHue    or ds.ShadowHue          or 0
    s.CGShadowSat    = ds.ColorGradeShadowSat    or ds.ShadowSaturation   or 0
    s.CGMidtoneHue   = ds.ColorGradeMidtoneHue   or 0
    s.CGMidtoneSat   = ds.ColorGradeMidtoneSat   or 0
    s.CGHighlightHue = ds.ColorGradeHighlightHue or ds.HighlightHue       or 0
    s.CGHighlightSat = ds.ColorGradeHighlightSat or ds.HighlightSaturation or 0
    s.CGBalance      = ds.ColorGradeBalance      or ds.SplitToningBalance  or 0

    return s
end

-- ─────────────────────────────────────────────────────────
-- Build a readable summary of current settings for Claude
-- ─────────────────────────────────────────────────────────
local function settingsSummary(s)
    local lines = {
        string.format('White Balance: %s  Temperature: %dK  Tint: %+d', s.WhiteBalance, s.Temperature, s.Tint),
        string.format('Tone: Exposure %+.2f  Contrast %+d  Highlights %+d  Shadows %+d  Whites %+d  Blacks %+d',
            s.Exposure2012, s.Contrast2012, s.Highlights2012, s.Shadows2012, s.Whites2012, s.Blacks2012),
        string.format('Presence: Clarity %+d  Vibrance %+d  Saturation %+d',
            s.Clarity2012, s.Vibrance, s.Saturation),
        string.format('Tone Curve (parametric): Shadows %+d  Darks %+d  Lights %+d  Highlights %+d',
            s.ParametricShadows, s.ParametricDarks, s.ParametricLights, s.ParametricHighlights),
        '',
        'HSL Color Mixer:',
        '  Color    | Hue | Sat | Lum',
        '  ---------|-----|-----|----',
    }
    for _, color in ipairs(HSL_COLORS) do
        lines[#lines + 1] = string.format('  %-8s | %+4d | %+4d | %+4d',
            color,
            s['HueAdjustment'        .. color] or 0,
            s['SaturationAdjustment' .. color] or 0,
            s['LuminanceAdjustment'  .. color] or 0)
    end
    lines[#lines + 1] = string.format(
        'Color Grading: Shadows H:%d S:%d  Midtones H:%d S:%d  Highlights H:%d S:%d  Balance %+d',
        s.CGShadowHue, s.CGShadowSat,
        s.CGMidtoneHue, s.CGMidtoneSat,
        s.CGHighlightHue, s.CGHighlightSat,
        s.CGBalance)
    return table.concat(lines, '\n')
end

-- ─────────────────────────────────────────────────────────
-- Clamp helpers
-- ─────────────────────────────────────────────────────────
local function clampInt(v, lo, hi)
    v = math.floor((tonumber(v) or 0) + 0.5)
    return math.max(lo, math.min(hi, v))
end

local function clampFloat(v, lo, hi, decimals)
    v = tonumber(v) or 0
    v = math.max(lo, math.min(hi, v))
    local factor = 10 ^ (decimals or 2)
    return math.floor(v * factor + 0.5) / factor
end

-- ─────────────────────────────────────────────────────────
-- Anthropic API call
-- ─────────────────────────────────────────────────────────
local SYSTEM_PROMPT = [[You are an expert cinematographer and colour grading specialist with deep knowledge of Lightroom Classic develop settings and photographic aesthetics.

Your task is to analyse a photo and apply a creative colour grade that matches the requested style target. You have access to both the image and the photo's current develop settings.

Guidelines:
- Study the image's dominant colours, lighting quality, mood, and subject matter before deciding on adjustments
- Your grade should feel intentional and cohesive — every adjustment should serve the overall look
- Respect the image's inherent character; enhance it rather than fighting it
- All integer slider values must be within their documented Lightroom ranges
- Exposure adjustments should be conservative (±1.5 EV max) unless the style demands drama
- Color Grading hue values are in degrees (0–360); saturation values are 0–100]]

local function buildUserPrompt(settingsText, styleTarget, isAdaptive)
    if isAdaptive then
        -- Adaptive Color profile is active: Basic panel and tone curve are managed
        -- by the profile — restrict Claude to HSL + Color Grading only.
        return string.format([[Analyse this photo and apply a colour grade matching the style target below.

IMPORTANT: This photo uses Lightroom's Adaptive Color profile, which already handles exposure and tone optimisation. Do NOT touch White Balance, Basic tone (exposure/contrast/highlights/shadows/whites/blacks), Presence (clarity/vibrance/saturation), or the Tone Curve. Adjust ONLY the HSL Color Mixer and Color Grading panels.

STYLE TARGET: %s

CURRENT LIGHTROOM SETTINGS:
%s

Respond with ONLY valid JSON — no markdown, no code fences, no extra text. Use exactly this structure:
{
  "style_applied": "brief label for the grade you applied",
  "hsl": {
    "hue":        { "Red": 0, "Orange": 0, "Yellow": 0, "Green": 0, "Aqua": 0, "Blue": 0, "Purple": 0, "Magenta": 0 },
    "saturation": { "Red": 0, "Orange": 0, "Yellow": 0, "Green": 0, "Aqua": 0, "Blue": 0, "Purple": 0, "Magenta": 0 },
    "luminance":  { "Red": 0, "Orange": 0, "Yellow": 0, "Green": 0, "Aqua": 0, "Blue": 0, "Purple": 0, "Magenta": 0 }
  },
  "color_grading": {
    "shadows_hue": 0, "shadows_sat": 0,
    "midtones_hue": 0, "midtones_sat": 0,
    "highlights_hue": 0, "highlights_sat": 0,
    "balance": 0
  },
  "reasoning": "2-3 sentences describing what you saw in the image and the specific choices you made to achieve the requested style"
}

Value ranges:
- hsl hue/saturation/luminance: -100 to +100 (integer)
- color_grading shadows_hue / midtones_hue / highlights_hue: 0–360 (integer)
- color_grading shadows_sat / midtones_sat / highlights_sat: 0–100 (integer)
- color_grading balance: -100 to +100 (integer)]], styleTarget, settingsText)
    else
        return string.format([[Analyse this photo and apply a colour grade matching the style target below.

STYLE TARGET: %s

CURRENT LIGHTROOM SETTINGS:
%s

Respond with ONLY valid JSON — no markdown, no code fences, no extra text. Use exactly this structure:
{
  "style_applied": "brief label for the grade you applied",
  "white_balance": { "temperature": 5500, "tint": 0 },
  "tone": {
    "exposure": 0.00, "contrast": 0,
    "highlights": 0, "shadows": 0, "whites": 0, "blacks": 0
  },
  "presence": { "clarity": 0, "vibrance": 0, "saturation": 0 },
  "tone_curve": { "shadows": 0, "darks": 0, "lights": 0, "highlights": 0 },
  "hsl": {
    "hue":        { "Red": 0, "Orange": 0, "Yellow": 0, "Green": 0, "Aqua": 0, "Blue": 0, "Purple": 0, "Magenta": 0 },
    "saturation": { "Red": 0, "Orange": 0, "Yellow": 0, "Green": 0, "Aqua": 0, "Blue": 0, "Purple": 0, "Magenta": 0 },
    "luminance":  { "Red": 0, "Orange": 0, "Yellow": 0, "Green": 0, "Aqua": 0, "Blue": 0, "Purple": 0, "Magenta": 0 }
  },
  "color_grading": {
    "shadows_hue": 0, "shadows_sat": 0,
    "midtones_hue": 0, "midtones_sat": 0,
    "highlights_hue": 0, "highlights_sat": 0,
    "balance": 0
  },
  "reasoning": "2-3 sentences describing what you saw in the image and the specific choices you made to achieve the requested style"
}

Value ranges:
- temperature: 2000–50000 (integer)
- tint: -150 to +150 (integer)
- exposure: -5.00 to +5.00 (float, 2 decimal places)
- contrast / highlights / shadows / whites / blacks: -100 to +100 (integer)
- clarity / vibrance / saturation: -100 to +100 (integer)
- tone_curve values: -100 to +100 (integer)
- hsl hue/saturation/luminance: -100 to +100 (integer)
- color_grading shadows_hue / midtones_hue / highlights_hue: 0–360 (integer)
- color_grading shadows_sat / midtones_sat / highlights_sat: 0–100 (integer)
- color_grading balance: -100 to +100 (integer)]], styleTarget, settingsText)
    end
end

local function callClaudeAPI(jpegData, currentSettings, apiKey, model, styleTarget, isAdaptive)
    local b64          = base64Encode(jpegData)
    local settingsText = settingsSummary(currentSettings)
    local userPrompt   = buildUserPrompt(settingsText, styleTarget, isAdaptive)

    local requestBody = json.encode({
        model      = model,
        max_tokens = 2048,
        system     = SYSTEM_PROMPT,
        messages   = {
            {
                role    = 'user',
                content = {
                    { type = 'image', source = { type = 'base64', media_type = 'image/jpeg', data = b64 } },
                    { type = 'text',  text   = userPrompt },
                },
            },
        },
    })

    local headers = {
        { field = 'Content-Type',      value = 'application/json' },
        { field = 'x-api-key',         value = apiKey             },
        { field = 'anthropic-version', value = '2023-06-01'       },
    }

    local responseBody, responseHeaders = LrHttp.post(
        'https://api.anthropic.com/v1/messages', requestBody, headers)

    if not responseBody then
        return nil, 'Network error: no response received from Anthropic'
    end

    if responseHeaders and responseHeaders.status ~= 200 then
        local detail  = ''
        local errData = json.decode(responseBody)
        if errData and errData.error then
            detail = '\n' .. (errData.error.message or errData.error.type or '')
        elseif responseBody and #responseBody > 0 then
            detail = '\nRaw response: ' .. responseBody:sub(1, 500)
        end
        return nil, 'API error ' .. tostring(responseHeaders.status) .. detail
    end

    local apiResp = json.decode(responseBody)
    if not apiResp then return nil, 'Could not parse API response as JSON' end
    if not (apiResp.content and apiResp.content[1] and apiResp.content[1].text) then
        return nil, 'Unexpected API response structure'
    end

    local claudeText = apiResp.content[1].text

    -- Strip code fences
    claudeText = claudeText:match('```json%s*(.-)%s*```')
              or claudeText:match('```%s*(.-)%s*```')
              or claudeText
    claudeText = claudeText:match('^%s*(.-)%s*$')

    -- Strip leading '+' from positive numbers (not valid JSON)
    claudeText = claudeText:gsub('([:%[,]%s*)%+(%d)', '%1%2')

    -- Extract outermost { … } if Claude prepended prose
    local result = json.decode(claudeText)
    if not result then
        local s = claudeText:find('{', 1, true)
        local e = claudeText:match('.*()%}')
        if s and e and e >= s then result = json.decode(claudeText:sub(s, e)) end
    end
    if not result then
        return nil, 'Could not parse grade JSON from Claude.\nRaw: ' .. claudeText:sub(1, 400)
    end

    -- Validate top-level keys
    local requiredKeys = isAdaptive
        and { 'hsl', 'color_grading' }
        or  { 'white_balance', 'tone', 'presence', 'tone_curve', 'hsl', 'color_grading' }
    for _, key in ipairs(requiredKeys) do
        if type(result[key]) ~= 'table' then
            return nil, 'Missing "' .. key .. '" in Claude response'
        end
    end

    return result, nil
end

-- ─────────────────────────────────────────────────────────
-- Apply all settings
-- No pcall — Lua 5.1 forbids yield inside pcall and catalog
-- ops yield internally. Use a boolean flag instead.
-- ─────────────────────────────────────────────────────────
local function applySettings(catalog, photo, result, isAdaptive)
    local ns = {}  -- newSettings

    if not isAdaptive then
        -- White Balance
        ns.WhiteBalance = 'Custom'
        ns.Temperature  = clampInt(result.white_balance.temperature, 2000, 50000)
        ns.Tint         = clampInt(result.white_balance.tint,        -150, 150)

        -- Basic Tone
        ns.Exposure2012   = clampFloat(result.tone.exposure,   -5,   5, 2)
        ns.Contrast2012   = clampInt(result.tone.contrast,    -100, 100)
        ns.Highlights2012 = clampInt(result.tone.highlights,  -100, 100)
        ns.Shadows2012    = clampInt(result.tone.shadows,     -100, 100)
        ns.Whites2012     = clampInt(result.tone.whites,      -100, 100)
        ns.Blacks2012     = clampInt(result.tone.blacks,      -100, 100)

        -- Presence
        ns.Clarity2012 = clampInt(result.presence.clarity,    -100, 100)
        ns.Vibrance    = clampInt(result.presence.vibrance,   -100, 100)
        ns.Saturation  = clampInt(result.presence.saturation, -100, 100)

        -- Parametric Tone Curve
        ns.ParametricShadows    = clampInt(result.tone_curve.shadows,    -100, 100)
        ns.ParametricDarks      = clampInt(result.tone_curve.darks,      -100, 100)
        ns.ParametricLights     = clampInt(result.tone_curve.lights,     -100, 100)
        ns.ParametricHighlights = clampInt(result.tone_curve.highlights, -100, 100)
    end

    -- HSL
    for _, color in ipairs(HSL_COLORS) do
        ns['HueAdjustment'        .. color] = clampInt(result.hsl.hue        and result.hsl.hue[color],        -100, 100)
        ns['SaturationAdjustment' .. color] = clampInt(result.hsl.saturation and result.hsl.saturation[color], -100, 100)
        ns['LuminanceAdjustment'  .. color] = clampInt(result.hsl.luminance  and result.hsl.luminance[color],  -100, 100)
    end

    -- Color Grading — set both new (LR 10+) and legacy Split Toning keys
    local cg = result.color_grading
    ns.ColorGradeShadowHue    = clampInt(cg.shadows_hue,    0, 360)
    ns.ColorGradeShadowSat    = clampInt(cg.shadows_sat,    0, 100)
    ns.ColorGradeMidtoneHue   = clampInt(cg.midtones_hue,   0, 360)
    ns.ColorGradeMidtoneSat   = clampInt(cg.midtones_sat,   0, 100)
    ns.ColorGradeHighlightHue = clampInt(cg.highlights_hue, 0, 360)
    ns.ColorGradeHighlightSat = clampInt(cg.highlights_sat, 0, 100)
    ns.ColorGradeBalance      = clampInt(cg.balance,       -100, 100)
    -- Legacy Split Toning keys (LR < 10)
    ns.ShadowHue              = ns.ColorGradeShadowHue
    ns.ShadowSaturation       = ns.ColorGradeShadowSat
    ns.HighlightHue           = ns.ColorGradeHighlightHue
    ns.HighlightSaturation    = ns.ColorGradeHighlightSat
    ns.SplitToningBalance     = ns.ColorGradeBalance

    local writeOk = false
    catalog:withWriteAccessDo('Claude AI: Color Grade', function()
        photo:applyDevelopSettings(ns)
        writeOk = true
    end)

    return writeOk, ns
end

-- ─────────────────────────────────────────────────────────
-- Build a before→after summary for the result dialog
-- ─────────────────────────────────────────────────────────
local function buildSummary(old, new, result, isAdaptive)
    local lines = {}

    local function diff(label, oldVal, newVal, fmt)
        fmt = fmt or '%g'
        if oldVal ~= newVal then
            lines[#lines + 1] = string.format(
                '  %-28s ' .. fmt .. ' \226\134\146 ' .. fmt .. '  (%+g)',
                label, oldVal, newVal, newVal - oldVal)
        end
    end

    lines[#lines + 1] = 'STYLE: ' .. (result.style_applied or 'Custom')
    if isAdaptive then
        lines[#lines + 1] = '(Adaptive Color profile active — Basic, WB, and Tone Curve unchanged)'
    end
    lines[#lines + 1] = ''

    if not isAdaptive then
        lines[#lines + 1] = 'WHITE BALANCE'
        diff('Temperature (K)', old.Temperature,   new.Temperature,   '%d')
        diff('Tint',            old.Tint,           new.Tint,           '%+d')

        lines[#lines + 1] = ''
        lines[#lines + 1] = 'BASIC TONE'
        diff('Exposure',    old.Exposure2012,   new.Exposure2012,   '%.2f')
        diff('Contrast',    old.Contrast2012,   new.Contrast2012,   '%+d')
        diff('Highlights',  old.Highlights2012, new.Highlights2012, '%+d')
        diff('Shadows',     old.Shadows2012,    new.Shadows2012,    '%+d')
        diff('Whites',      old.Whites2012,     new.Whites2012,     '%+d')
        diff('Blacks',      old.Blacks2012,     new.Blacks2012,     '%+d')

        lines[#lines + 1] = ''
        lines[#lines + 1] = 'PRESENCE'
        diff('Clarity',    old.Clarity2012, new.Clarity2012, '%+d')
        diff('Vibrance',   old.Vibrance,    new.Vibrance,    '%+d')
        diff('Saturation', old.Saturation,  new.Saturation,  '%+d')

        lines[#lines + 1] = ''
        lines[#lines + 1] = 'TONE CURVE'
        diff('Shadows',    old.ParametricShadows,    new.ParametricShadows,    '%+d')
        diff('Darks',      old.ParametricDarks,      new.ParametricDarks,      '%+d')
        diff('Lights',     old.ParametricLights,     new.ParametricLights,     '%+d')
        diff('Highlights', old.ParametricHighlights, new.ParametricHighlights, '%+d')
    end  -- not isAdaptive

    -- HSL — only list colours that changed
    local hslChanged = {}
    for _, color in ipairs(HSL_COLORS) do
        local hO = old['HueAdjustment'        .. color] or 0
        local sO = old['SaturationAdjustment' .. color] or 0
        local lO = old['LuminanceAdjustment'  .. color] or 0
        local hN = new['HueAdjustment'        .. color] or 0
        local sN = new['SaturationAdjustment' .. color] or 0
        local lN = new['LuminanceAdjustment'  .. color] or 0
        if hO ~= hN or sO ~= sN or lO ~= lN then
            hslChanged[#hslChanged + 1] = string.format(
                '  %-8s  H:%+d\226\134\146%+d  S:%+d\226\134\146%+d  L:%+d\226\134\146%+d',
                color, hO, hN, sO, sN, lO, lN)
        end
    end
    if #hslChanged > 0 then
        lines[#lines + 1] = ''
        lines[#lines + 1] = 'HSL (changed channels)'
        for _, l in ipairs(hslChanged) do lines[#lines + 1] = l end
    end

    -- Color Grading
    local cgChanged = (old.CGShadowHue    ~= new.ColorGradeShadowHue)    or
                      (old.CGShadowSat    ~= new.ColorGradeShadowSat)    or
                      (old.CGMidtoneHue   ~= new.ColorGradeMidtoneHue)   or
                      (old.CGMidtoneSat   ~= new.ColorGradeMidtoneSat)   or
                      (old.CGHighlightHue ~= new.ColorGradeHighlightHue) or
                      (old.CGHighlightSat ~= new.ColorGradeHighlightSat) or
                      (old.CGBalance      ~= new.ColorGradeBalance)
    if cgChanged then
        lines[#lines + 1] = ''
        lines[#lines + 1] = 'COLOR GRADING'
        lines[#lines + 1] = string.format(
            '  Shadows   H:%d\226\134\146%d  S:%d\226\134\146%d',
            old.CGShadowHue,    new.ColorGradeShadowHue,
            old.CGShadowSat,    new.ColorGradeShadowSat)
        lines[#lines + 1] = string.format(
            '  Midtones  H:%d\226\134\146%d  S:%d\226\134\146%d',
            old.CGMidtoneHue,   new.ColorGradeMidtoneHue,
            old.CGMidtoneSat,   new.ColorGradeMidtoneSat)
        lines[#lines + 1] = string.format(
            '  Highlights H:%d\226\134\146%d  S:%d\226\134\146%d',
            old.CGHighlightHue, new.ColorGradeHighlightHue,
            old.CGHighlightSat, new.ColorGradeHighlightSat)
        lines[#lines + 1] = string.format(
            '  Balance   %+d\226\134\146%+d', old.CGBalance, new.ColorGradeBalance)
    end

    -- Reasoning
    if type(result.reasoning) == 'string' and #result.reasoning > 0 then
        lines[#lines + 1] = ''
        lines[#lines + 1] = 'CLAUDE\'S REASONING'
        lines[#lines + 1] = result.reasoning
    end

    return table.concat(lines, '\n')
end

-- ─────────────────────────────────────────────────────────
-- Run dialog — asks for the style target for THIS run
--
-- The style target is a creative decision that changes shot to shot, so it
-- belongs here rather than in Settings.  The last style used is remembered and
-- pre-filled, so repeating a grade is still one keystroke.
--
-- Must be called before the LrProgressScope is created: Lightroom will not
-- present a modal dialog while a progress scope is active.
-- ─────────────────────────────────────────────────────────
local function promptForRun(photoCount, model, isAdaptive)
    local chosen

    LrFunctionContext.callWithContext('claudeColorGradeRun', function(context)
        local f     = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)

        props.styleTarget = pluginPrefs.lastStyleTarget
                         or pluginPrefs.styleTarget
                         or 'Natural / Balanced'
        props.saveAsDefault = false

        local scopeDesc = isAdaptive
            and 'HSL Color Mixer + Color Grading only (Adaptive Color mode)'
            or  'White Balance, Tone, Presence, Tone Curve, HSL, Color Grading'

        local contents = f:column {
            bind_to_object = props,
            spacing        = f:dialog_spacing(),

            f:static_text {
                title = string.format('Grading %d photo%s with %s.',
                    photoCount, photoCount == 1 and '' or 's', model),
                font  = '<system/bold>',
            },

            f:group_box {
                title           = 'Style target for this run',
                fill_horizontal = 1,
                f:column {
                    spacing         = f:label_spacing(),
                    fill_horizontal = 1,

                    f:combo_box {
                        value           = LrView.bind 'styleTarget',
                        items           = CANNED_STYLES,
                        fill_horizontal = 1,
                        width_in_chars  = 52,
                        immediate       = true,
                        tooltip         = 'Pick a canned style or type your own description',
                    },
                    f:static_text {
                        title = 'Choose a preset or type any description, e.g.\n' ..
                                '"moody blue hour with lifted shadows and teal split toning"',
                        font  = '<system/small>',
                    },
                    f:spacer { height = 2 },
                    f:checkbox {
                        title = 'Remember this as my default',
                        value = LrView.bind 'saveAsDefault',
                    },
                },
            },

            f:static_text {
                title = 'Adjusts: ' .. scopeDesc,
                font  = '<system/small>',
            },
            f:static_text {
                title = 'Use Develop \226\150\184 History to undo.',
                font  = '<system/small>',
            },
        }

        local result = LrDialogs.presentModalDialog({
            title      = 'Claude AI Color Grade',
            contents   = contents,
            actionVerb = 'Apply Grade',
            cancelVerb = 'Cancel',
        })

        if result == 'ok' then
            -- combo_box hands back whatever the user typed, so trim it and
            -- fall back rather than sending an empty brief to the API.
            local style = tostring(props.styleTarget or ''):match('^%s*(.-)%s*$')
            if style == '' then style = 'Natural / Balanced' end
            chosen = style

            pluginPrefs.lastStyleTarget = style
            if props.saveAsDefault == true then
                pluginPrefs.styleTarget = style
            end
        end
    end)

    return chosen
end

-- ─────────────────────────────────────────────────────────
-- Entry point
-- ─────────────────────────────────────────────────────────
LrTasks.startAsyncTask(function()

    local apiKey = pluginPrefs.claudeApiKey
    if not apiKey or LrStringUtils.trimWhitespace(apiKey) == '' then
        LrDialogs.message(
            'Claude AI Color Grade',
            'No API key found.\n\nGo to  File \226\150\184 Plug-in Extras \226\150\184 Claude Color Grade Settings  to enter your Anthropic API key.',
            'critical')
        return
    end

    local catalog    = LrApplication.activeCatalog()
    local photos     = catalog:getTargetPhotos()

    if not photos or #photos == 0 then
        LrDialogs.message('Claude AI Color Grade',
            'No photos selected. Select one or more photos and try again.', 'info')
        return
    end

    local model        = pluginPrefs.claudeModel    or 'claude-opus-4-5'
    local thumbSize    = tonumber(pluginPrefs.thumbnailSize) or 1024
    local isAdaptive   = pluginPrefs.adaptiveMode == true
    local photoCount   = #photos

    -- Ask for this run's style target (doubles as the confirmation step)
    local styleTarget = promptForRun(photoCount, model, isAdaptive)
    if not styleTarget then return end     -- cancelled

    LrFunctionContext.callWithContext('claudeColorGradeProgress', function(context)

        local progress = LrProgressScope({
            title           = 'Claude AI: Applying colour grade',
            functionContext = context,
        })

        local successCount = 0
        local errors       = {}
        local summaries    = {}

        for i, photo in ipairs(photos) do
            if progress:isCanceled() then break end

            local fileName = photo:getFormattedMetadata('fileName') or ('photo ' .. i)
            progress:setPortionComplete(i - 1, photoCount)
            progress:setCaption(string.format('%s  (%d / %d)', fileName, i, photoCount))
            LrTasks.yield()

            -- Read current settings (outside write access — may yield)
            local currentSettings = readCurrentSettings(photo)
            local isAdaptive = pluginPrefs.adaptiveMode == true

            -- Get thumbnail
            local jpegData, thumbErr = getPhotoThumbnail(photo, thumbSize)
            if not jpegData then
                errors[#errors + 1] = string.format('%-40s  preview error: %s', fileName, thumbErr or '?')
            else
                -- Call Claude
                local result, apiErr = callClaudeAPI(jpegData, currentSettings, apiKey, model, styleTarget, isAdaptive)
                if not result then
                    errors[#errors + 1] = string.format('%-40s  API error: %s', fileName, apiErr or '?')
                else
                    -- Apply (no pcall — catalog ops yield internally in Lua 5.1)
                    local written, newSettings = applySettings(catalog, photo, result, isAdaptive)
                    if written then
                        successCount = successCount + 1
                        summaries[#summaries + 1] = {
                            fileName = fileName,
                            summary  = buildSummary(currentSettings, newSettings, result, isAdaptive),
                        }
                    else
                        errors[#errors + 1] = string.format('%-40s  write failed', fileName)
                    end
                end
            end

            if i < photoCount and not progress:isCanceled() then
                LrTasks.sleep(0.3)
            end
        end

        progress:done()

        -- Results dialog
        local resultTitle = 'Claude AI Color Grade \226\128\148 Done'
        local parts       = {}

        parts[#parts + 1] = string.format(
            '%d of %d photo%s graded successfully.',
            successCount, photoCount, photoCount == 1 and '' or 's')

        for _, s in ipairs(summaries) do
            parts[#parts + 1] = '\n\226\148\128\226\148\128\226\148\128 ' .. s.fileName .. ' \226\148\128\226\148\128\226\148\128'
            parts[#parts + 1] = s.summary
        end

        if #errors > 0 then
            parts[#parts + 1] = '\nFailed (' .. #errors .. '):'
            parts[#parts + 1] = table.concat(errors, '\n')
        end

        LrDialogs.message(resultTitle, table.concat(parts, '\n'),
            #errors > 0 and 'warning' or 'info')

    end)
end)

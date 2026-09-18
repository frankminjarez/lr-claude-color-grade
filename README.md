# Claude AI Color Grade — Lightroom Classic Plugin

Prompt driven editing in Lightroom CC! Applies a complete, AI-driven colour grade to selected photos using Anthropic's Claude vision models. Choose from 12 canned cinematic styles or type any free-form description; Claude analyses each image and returns a cohesive set of Lightroom develop adjustments covering every major panel.

[![Watch the video](https://img.youtube.com/vi/RTsmX7HH-kg/0.jpg)](https://www.youtube.com/watch?v=RTsmX7HH-kg)

---

## How it works

For each selected photo the plugin:

1. Reads the photo's current develop settings from Lightroom
2. Fetches a JPEG preview from Lightroom's cache
3. Sends both the image and the current settings to Claude via the Anthropic API, along with the requested style target
4. Claude analyses the photo's dominant colours, lighting quality, mood, and subject, then returns a full set of develop adjustments
5. Lightroom writes the new values across all covered panels
6. A summary dialog shows exactly what changed, with before → after values and Claude's reasoning

---

## Requirements

| Item | Minimum |
|------|---------|
| Lightroom Classic | 6.0 / CC 2015 or newer |
| Operating system | macOS or Windows |
| Anthropic account | API key from [console.anthropic.com](https://console.anthropic.com) |
| Internet access | Required at generation time |

---

## Installation

1. **Download** the latest `ClaudeColorGrade-vX.X.zip` from the [Releases](../../releases) page and unzip it. You should end up with a folder named `ClaudeColorGrade.lrplugin`.

2. In Lightroom Classic, go to **File → Plug-in Manager…**

3. Click **Add** (bottom-left), navigate to the `ClaudeColorGrade.lrplugin` folder, select it, and click **Add Plug-in**.

4. The plugin should appear in the list with status **Installed and running**. Click **Done**.

> **Reinstalling or updating?** Always remove the old plugin first (select it → Remove), quit Lightroom completely, delete the old plugin folder, then reinstall fresh. Lightroom caches plugin state and a simple file overwrite may not take effect.

---

## Setup

1. Go to **File → Plug-in Extras → Claude Color Grade Settings…**

2. Paste your **Anthropic API key** (starts with `sk-ant-`). Get one at [console.anthropic.com](https://console.anthropic.com).

3. Choose a **model**:

| Model | Characteristic |
|-------|---------------|
| `claude-opus-4-5` | Best colour analysis — recommended for demanding grades |
| `claude-sonnet-4-5` | Faster, lower cost per image |
| `claude-haiku-4-5` | Fastest, cheapest — good for bulk preview runs |

4. Choose a **Default Style Target** from the dropdown, or type any custom description.

5. Set the **Preview size** (see [Settings reference](#settings-reference) below).

6. If you are using Lightroom's **Adaptive Color** camera profile, enable **Adaptive Color Mode** (see [Adaptive Color mode](#adaptive-color-mode) below).

7. Click **Save**.

---

## Usage

1. In the **Library** or **Develop** module, select one or more photos.

2. Go to **File → Plug-in Extras → Color Grade with Claude AI**.

3. Review the confirmation dialog — it shows the active style target, model, and which panels will be adjusted — then click **Apply Grade**.

4. A progress bar appears while each photo is processed.

5. When complete, a summary dialog shows the before → after values for every changed parameter and Claude's reasoning. Use **Develop → History** to undo if you prefer the original.

---

## What gets adjusted

### Standard mode (full grade)

| Panel | Fields |
|-------|--------|
| White Balance | Temperature, Tint |
| Basic — Tone | Exposure, Contrast, Highlights, Shadows, Whites, Blacks |
| Basic — Presence | Clarity, Vibrance, Saturation |
| Tone Curve | Parametric: Shadows, Darks, Lights, Highlights |
| HSL Color Mixer | Hue, Saturation, Luminance for Red / Orange / Yellow / Green / Aqua / Blue / Purple / Magenta |
| Color Grading | Shadows, Midtones, Highlights (hue + saturation); Balance |

### Adaptive Color mode (restricted grade)

When **Adaptive Color Mode** is enabled in Settings, only these panels are touched:

| Panel | Fields |
|-------|--------|
| HSL Color Mixer | Hue, Saturation, Luminance — all 8 colour channels |
| Color Grading | Shadows, Midtones, Highlights (hue + saturation); Balance |

White Balance, Basic tone, Presence, and the Tone Curve are left exactly as they were.

---

## Style targets

The plugin ships with 12 canned presets selectable from the dropdown:

| Style | Character |
|-------|-----------|
| Natural / Balanced | Faithful, well-balanced grade with minimal creative push |
| Warm Film | Warm midtones, elevated shadows, analogue feel |
| Cool & Moody | Desaturated blues and cyans, lifted blacks |
| Cinematic (Teal & Orange) | Hollywood split-tone: teal shadows, orange skin |
| Bright & Airy | High key, open shadows, clean whites |
| Dark & Dramatic | Crushed blacks, punchy contrast, rich shadows |
| Golden Hour | Warm amber cast, glowing highlights |
| Vintage Film | Faded colours, slight colour shifts, grain-ready |
| Faded Matte | Lifted blacks, reduced saturation, Instagram-style matte |
| High Contrast | Strong blacks and whites, punchy midtones |
| Soft & Dreamy | Hazy highlights, pastel palette, low contrast |
| Desaturated Editorial | Near-monochrome with selective hue pops |

You can also **type any custom description** in the Style field, for example:

- `moody blue hour with lifted shadows and teal split toning`
- `sun-bleached desert heat with faded greens`
- `rich jewel tones, high contrast, for luxury product photography`

---

## Adaptive Color mode

Lightroom's Adaptive Color camera profile (Lightroom Classic 12+) applies AI-driven exposure and tone adjustments at the raw processing stage. Grading on top of this with a full develop-panel pass can fight the profile's own corrections.

When **Adaptive Color Mode** is enabled in Settings, the plugin restricts Claude to the **HSL Color Mixer** and **Color Grading** panels only, so the colour character of the grade is applied without disturbing the profile's tone work. Claude is also explicitly instructed not to return White Balance, tone, or curve values.

**How to use:** enable the checkbox in Settings before grading a session shot with Adaptive Color, then disable it when returning to standard profiles.

---

## Settings reference

### Model

Controls the Claude model used for analysis.

- `claude-opus-4-5` gives the most nuanced colour reasoning and is recommended when quality is the priority.
- `claude-haiku-4-5` is significantly cheaper and faster, useful for bulk preview runs where a rough grade is enough.

### Default Style Target

Sets the style target pre-filled when the plugin runs. You can type any free-form description here or choose from the dropdown. The plugin uses whatever text is in this field as the creative brief sent to Claude.

### Preview size

The longest edge (in pixels) of the JPEG preview sent to Claude. Higher values give Claude more detail but increase API payload and cost.

| Size | Typical use |
|------|-------------|
| 512 px | Fast preview, bulk runs |
| 768 px | Good balance for most images |
| **1024 px** | **Recommended default** |
| 1536 px | Complex lighting, fine colour detail |
| 2048 px | Maximum detail — slowest, highest cost |

> **Important:** Lightroom sometimes returns a full-resolution cached preview regardless of the requested size. If you see a preview-size error, go to **Library → Previews → Build Standard-Sized Previews**, wait for it to finish, then retry.

### Adaptive Color Mode

When checked, restricts every grade to the HSL Color Mixer and Color Grading panels only. Enable when shooting with the Adaptive Color camera profile. See [Adaptive Color mode](#adaptive-color-mode) above.

---

## Tips for best results

- **Run on one photo first** before processing a large batch so you can evaluate Claude's interpretation of the style and choose the right model.

- **Use History to compare.** After the plugin runs, click the state just before the plugin's History entry in the Develop module to A/B the before and after.

- **Build standard-sized previews first** for any photo that shows a preview error. Go to **Library → Previews → Build Standard-Sized Previews**.

- **Re-grading the same photo** invalidates Lightroom's cached preview. The plugin automatically retries the thumbnail request several times with short pauses to wait for the preview to rebuild.

- **RAW files** (ARW, CR3, NEF, etc.) are analysed via their JPEG preview, not the raw sensor data. Make sure the preview reflects your current crop and any basic develop adjustments before running the grade.

- **Batch runs** add a short pause between photos to stay within Anthropic's rate limits.

- **Custom style descriptions** work best when they describe mood, colour palette, and contrast together. "Faded blue-green shadows with warm skin and lifted blacks for a fashion editorial look" will produce a more deliberate grade than just "cool".

---

## API cost (approximate)

Anthropic charges per token. A typical 1024 px image call costs roughly:

| Model | Approx. cost per photo |
|-------|------------------------|
| claude-opus-4-5 | ~$0.03 – $0.07 |
| claude-sonnet-4-5 | ~$0.004 – $0.010 |
| claude-haiku-4-5 | ~$0.001 – $0.003 |

Monitor your usage at [console.anthropic.com/usage](https://console.anthropic.com/usage).

---

## Troubleshooting

**Plugin does not appear in File → Plug-in Extras**
→ Make sure the folder is named exactly `ClaudeColorGrade.lrplugin` and that Lightroom shows it as "Installed and running" in the Plug-in Manager. If you recently updated the plugin, do a full remove → quit Lightroom → delete old folder → reinstall.

**"No preview available / Timed out waiting for preview"**
→ Build previews first: **Library → Previews → Build Standard-Sized Previews**.

**"Preview too large (NNNN × NNNN px)"**
→ Lightroom returned a full-res cached preview. Build Standard-Sized Previews as above, then retry.

**"Preview not available after several attempts"**
→ The plugin retries automatically after each grade since Lightroom invalidates the preview cache when develop settings change. If this persists, wait 10–15 seconds for Lightroom to finish rebuilding the preview and try again.

**"API error 401"**
→ Your API key is invalid or revoked. Check it in **Claude Color Grade Settings…**

**"API error 429"**
→ You've hit Anthropic's rate limit. Wait a minute and try again, or process a smaller batch.

**"Could not parse grade JSON from Claude response"**
→ Claude returned an unexpected response format. Re-running the photo usually fixes it. If it persists, the raw response text is shown in the error — check whether the API key has access to the selected model.

**Adaptive Color mode enabled but Basic/WB still changing**
→ Make sure you saved the Settings dialog after checking the box and that you are running v1.5 or later of the plugin.

**Settings are not saved after clicking Save**
→ Make sure the API key field is not empty and the Preview size is a number between 256 and 4096.

---

## License

MIT License — free to use, modify, and distribute.

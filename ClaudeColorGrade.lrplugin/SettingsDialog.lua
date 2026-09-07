--[[
  Claude AI Color Grade for Lightroom Classic
  SettingsDialog.lua — Preferences UI
--]]

local LrBinding         = import 'LrBinding'
local LrDialogs         = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrPrefs           = import 'LrPrefs'
local LrTasks           = import 'LrTasks'
local LrView            = import 'LrView'

local pluginPrefs = LrPrefs.prefsForPlugin()

local MODELS = {
    'claude-opus-4-5',
    'claude-sonnet-4-5',
    'claude-haiku-4-5',
}

local THUMB_SIZES = { '512', '768', '1024', '1536', '2048' }

-- The style target is chosen per run in the Color Grade dialog, not here:
-- it is a creative decision that changes shot to shot.  Styles.lua holds the
-- canned list for that dialog.

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext('claudeColorGradeSettings', function(context)

        local f     = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)

        props.apiKey        = pluginPrefs.claudeApiKey   or ''
        props.model         = pluginPrefs.claudeModel    or 'claude-opus-4-5'
        props.thumbnailSize = tostring(pluginPrefs.thumbnailSize or 1024)
        props.adaptiveMode  = pluginPrefs.adaptiveMode   or false

        local contents = f:column {
            bind_to_object = props,
            spacing        = f:dialog_spacing(),

            -- API Configuration
            f:group_box {
                title           = 'API Configuration',
                fill_horizontal = 1,
                f:column {
                    spacing         = f:label_spacing(),
                    fill_horizontal = 1,

                    f:row {
                        spacing = f:label_spacing(),
                        f:static_text {
                            title     = 'API Key:',
                            width     = LrView.share 'lbl',
                            alignment = 'right',
                        },
                        f:password_field {
                            value           = LrView.bind 'apiKey',
                            fill_horizontal = 1,
                            width_in_chars  = 48,
                            tooltip         = 'Your Anthropic API key (sk-ant-...)',
                        },
                    },
                    f:row {
                        f:static_text { title = '', width = LrView.share 'lbl' },
                        f:static_text {
                            title      = 'Get your key at console.anthropic.com',
                            text_color = LrView.blue,
                            font       = '<system/small>',
                        },
                    },

                    f:spacer { height = 4 },

                    f:row {
                        spacing = f:label_spacing(),
                        f:static_text {
                            title     = 'Model:',
                            width     = LrView.share 'lbl',
                            alignment = 'right',
                        },
                        f:combo_box {
                            value          = LrView.bind 'model',
                            items          = MODELS,
                            width_in_chars = 30,
                        },
                    },
                    f:row {
                        f:static_text { title = '', width = LrView.share 'lbl' },
                        f:static_text {
                            title = 'Opus = best quality  |  Sonnet = faster & cheaper  |  Haiku = fastest',
                            font  = '<system/small>',
                        },
                    },
                },
            },

            -- Image Quality
            f:group_box {
                title           = 'Image Analysis Quality',
                fill_horizontal = 1,
                f:column {
                    spacing = f:label_spacing(),
                    f:row {
                        spacing = f:label_spacing(),
                        f:static_text {
                            title     = 'Preview size:',
                            width     = LrView.share 'lbl',
                            alignment = 'right',
                        },
                        f:combo_box {
                            value          = LrView.bind 'thumbnailSize',
                            items          = THUMB_SIZES,
                            width_in_chars = 8,
                        },
                        f:static_text { title = 'px  (longer edge sent to Claude)' },
                    },
                    f:row {
                        f:static_text { title = '', width = LrView.share 'lbl' },
                        f:static_text {
                            title = '1024 px recommended. Build Standard-Sized Previews first if photos show preview errors.',
                            font  = '<system/small>',
                        },
                    },
                },
            },

            -- Adaptive Color mode
            f:group_box {
                title           = 'Adaptive Color Mode',
                fill_horizontal = 1,
                f:column {
                    spacing         = f:label_spacing(),
                    fill_horizontal = 1,
                    f:row {
                        f:checkbox {
                            title = 'Restrict grading to HSL + Color Grading panels only',
                            value = LrView.bind 'adaptiveMode',
                        },
                    },
                    f:row {
                        f:static_text {
                            title = 'Enable when using the Adaptive Color camera profile. Prevents Claude from\n' ..
                                    'touching White Balance, Basic tone, Presence, or the Tone Curve.',
                            font  = '<system/small>',
                        },
                    },
                },
            },

            -- Scope note
            f:group_box {
                title           = 'What gets adjusted',
                fill_horizontal = 1,
                f:static_text {
                    title = 'White Balance \226\128\162 Tone (Exposure / Contrast / Highlights / Shadows / Whites / Blacks)\n' ..
                            'Presence (Clarity / Vibrance / Saturation) \226\128\162 Parametric Tone Curve\n' ..
                            'HSL Color Mixer (all 24 sliders) \226\128\162 Color Grading (Shadows / Midtones / Highlights)\n' ..
                            'When Adaptive Color mode is on: HSL + Color Grading only.',
                    font  = '<system/small>',
                },
            },
        }

        local result = LrDialogs.presentModalDialog({
            title      = 'Claude AI Color Grade \226\128\148 Settings',
            contents   = contents,
            actionVerb = 'Save',
            cancelVerb = 'Cancel',
        })

        if result == 'ok' then
            local key = props.apiKey:match('^%s*(.-)%s*$')
            if key == '' then
                LrDialogs.message('Settings not saved', 'Please enter your Anthropic API key.', 'warning')
                return
            end

            local sz = tonumber(props.thumbnailSize)
            if not sz or sz < 256 or sz > 4096 then
                LrDialogs.message('Settings not saved', 'Preview size must be between 256 and 4096.', 'warning')
                return
            end

            pluginPrefs.claudeApiKey   = key
            pluginPrefs.claudeModel    = props.model
            pluginPrefs.thumbnailSize  = sz
            pluginPrefs.adaptiveMode   = props.adaptiveMode == true

            LrDialogs.message('Claude AI Color Grade', 'Settings saved.', 'info')
        end

    end)
end)

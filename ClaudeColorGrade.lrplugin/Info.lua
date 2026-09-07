--[[
  Claude AI Color Grade for Lightroom Classic
  Info.lua — Plugin manifest
--]]

return {

    LrSdkVersion        = 6.0,
    LrSdkMinimumVersion = 6.0,

    LrToolkitIdentifier = 'net.advertize.claudecolorgrade',
    LrPluginName        = LOC '$$$/ClaudeColorGrade/PluginName=Claude AI Color Grade',
    LrPluginInfoUrl     = 'https://advertize.net',

    LrExportMenuItems = {
        {
            title       = LOC '$$$/ClaudeColorGrade/Menu/Grade=Color Grade with Claude AI',
            file        = 'ColorGrade.lua',
            enabledWhen = 'photosSelected',
        },
        {
            title = LOC '$$$/ClaudeColorGrade/Menu/Settings=Claude Color Grade Settings\226\128\166',
            file  = 'SettingsDialog.lua',
        },
    },

    VERSION = { major = 1, minor = 1, revision = 0, build = 1 },
}

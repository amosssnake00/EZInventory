local M = {}

M.Defaults = {
    showAug1             = true,
    showAug2             = true,
    showAug3             = true,
    showAug4             = false,
    show.Aug5             = false,
    showAug6             = false,
    showAC               = false,
    showHP               = false,
    showMana             = false,
    showClicky           = false,
    comparisonShowSvMagic         = false,
    comparisonShowSvFire          = false,
    comparisonShowSvCold          = false,
    comparisonShowSvDisease       = false,
    comparisonShowSvPoison        = false,
    comparisonShowFocusEffects    = false,
    comparisonShowMod2s           = false,
    comparisonShowClickies        = false,
    loadBasicStats       = true,
    loadDetailedStats    = false,
    enableStatsFiltering = true,
    autoRefreshInventory = true,
    statsLoadingMode     = "minimal",
    showEQPath           = true,
    showScriptPath       = true,
    showDetailedStats    = false,
    autoExchangeEnabled  = true,
}

M.Settings = {}

function M.LoadSettings(settingsFile)
    local needSave = false

    if not mq.File.Exists(settingsFile) then
        M.Settings = {}
        for k, v in pairs(M.Defaults) do
            M.Settings[k] = v
        end
        mq.pickle(settingsFile, M.Settings)
    else
        local success, loadedSettings = pcall(dofile, settingsFile)
        if success and type(loadedSettings) == "table" then
            M.Settings = loadedSettings
        else
            M.Settings = {}
            for k, v in pairs(M.Defaults) do
                M.Settings[k] = v
            end
            needSave = true
        end
    end

    for setting, value in pairs(M.Defaults) do
        if M.Settings[setting] == nil then
            M.Settings[setting] = value
            needSave = true
        end
    end

    if needSave then
        mq.pickle(settingsFile, M.Settings)
    end
end

return M

-- ezinventory.lua
-- developed by psatty82
-- updated 07/20/2025
local mq    = require("mq")
local ImGui = require("ImGui")
local icons = require("mq.icons")
local Files = require("mq.Utils")

local function getModuleName()
    local info = debug.getinfo(1, "S")
    if info and info.source then
        local scriptPath = info.source:sub(2) -- Remove @ prefix

        -- If this is init.lua, try to get the directory name instead
        if scriptPath:match("init%.lua$") then
            local directory = scriptPath:match("([^/\\]+)[/\\]init%.lua$")
            if directory then
                return directory
            end
        end

        -- Otherwise get the filename without extension
        local filename = scriptPath:match("([^/\\]+)%.lua$")
        if filename and filename ~= "init" then
            return filename
        end
    end

    if _G.EZINV_MODULE then
        return _G.EZINV_MODULE
    end

    return "EZInventory"
end

local original_module_name = getModuleName()
local module_name = original_module_name:lower()
_G.EZINV_MODULE = module_name
_G.EZINV_BROADCAST_NAME = original_module_name
print(string.format("[EZInventory] Internal module name: %s, Broadcast name: %s", module_name, original_module_name))

local inventory_actor     = require("EZInventory.modules.inventory_actor")
local peerCache           = {}
local lastCacheTime       = 0
local lastPathRequestTime = 0
local json                = require("dkjson")
local Suggestions         = require("EZInventory.modules.suggestions")
local bot_inventory       = nil
local isEMU               = mq.TLO.MacroQuest.BuildName() == "Emu"

if isEMU then
    bot_inventory = require("EZInventory.modules.bot_inventory")
end

local Config = require("EZInventory.modules.config")
local server = string.gsub(mq.TLO.MacroQuest.Server(), ' ', '_')
local SettingsFile = string.format('%s/EZInventory/%s/%s.lua', mq.configDir, server, mq.TLO.Me.CleanName())
Config.LoadSettings(SettingsFile)
local Settings = Config.Settings

function UpdateInventoryActorConfig()
    if inventory_actor and inventory_actor.update_config then
        inventory_actor.update_config({
            loadBasicStats = Settings.loadBasicStats,
            loadDetailedStats = Settings.loadDetailedStats,
            enableStatsFiltering = Settings.enableStatsFiltering or true,
            statsLoadingMode = Settings.statsLoadingMode,
        })
    end
end

UpdateInventoryActorConfig()

---@tag InventoryUI
local UI = require("EZInventory.modules.ui")
local inventoryUI = UI.inventoryUI
for k, v in pairs(Settings) do
    inventoryUI[k] = v
end

local function SyncSettingsToUI()
    inventoryUI.statsLoadingMode = Settings.statsLoadingMode
    inventoryUI.loadBasicStats = Settings.loadBasicStats
    inventoryUI.loadDetailedStats = Settings.loadDetailedStats
    inventoryUI.enableStatsFiltering = Settings.enableStatsFiltering
    inventoryUI.autoRefreshInventory = Settings.autoRefreshInventory
    inventoryUI.enableNetworkBroadcast = Settings.enableNetworkBroadcast
    for k, v in pairs(Settings) do
        if Config.Defaults[k] ~= nil then
            inventoryUI[k] = v
        end
    end
end

SyncSettingsToUI()

local EQ_ICON_OFFSET           = 500
local ICON_WIDTH               = 20
local ICON_HEIGHT              = 20
local animItems                = mq.FindTextureAnimation("A_DragItem")
local animBox                  = mq.FindTextureAnimation("A_RecessedBox")
local server                   = mq.TLO.MacroQuest.Server()
local CBB_ICON_WIDTH           = 40
local CBB_ICON_HEIGHT          = 40
local CBB_COUNT_X_OFFSET       = 39
local CBB_COUNT_Y_OFFSET       = 23
local CBB_BAG_ITEM_SIZE        = 40
local CBB_MAX_SLOTS_PER_BAG    = 10
local show_item_background_cbb = true

local function broadcastLuaRun(connectionMethod)
    local command = "/lua run ezinventory"

    if connectionMethod == "MQ2Mono" then
        mq.cmd("/e3bcaa " .. command)
        print("Broadcasting via MQ2Mono: " .. command)
    elseif connectionMethod == "DanNet" then
        mq.cmd("/dgaexecute " .. command)
        print("Broadcasting via DanNet: " .. command)
    elseif connectionMethod == "EQBC" then
        mq.cmd("/bca /" .. command)
        print("Broadcasting via EQBC: " .. command)
    else
        print("No valid connection method available for broadcasting")
    end
end

local function sendLuaRunToPeer(peerName, connectionMethod)
    local command = "/lua run ezinventory"

    if connectionMethod == "DanNet" then
        mq.cmdf("/dgt %s %s", peerName, command)
        printf("Sent to %s via DanNet: %s", peerName, command)
    elseif connectionMethod == "EQBC" then
        mq.cmdf("/bct %s /%s", peerName, command)
        printf("Sent to %s via EQBC: %s", peerName, command)
    elseif connectionMethod == "MQ2Mono" then
        mq.cmdf("/e3bct %s %s", peerName, command)
        printf("Sent to %s via MQ2Mono: %s", peerName, command)
    else
        printf("Cannot send to %s - no valid connection method", peerName)
    end
end

local function refreshPeerCache()
    local now = os.time()
    if now - lastCacheTime > 2 then
        peerCache = {}

        for peerID, inv in pairs(inventory_actor.peer_inventories) do
            local server = inv.server or "Unknown"
            peerCache[server] = peerCache[server] or {}
            table.insert(peerCache[server], inv)
        end

        lastCacheTime = now
    end
end

local function requestPeerPaths()
    local now = os.time()
    if now - lastPathRequestTime < 10 then -- Don't spam requests
        return
    end

    lastPathRequestTime = now

    -- Use inventory_actor to request paths and script paths from all peers
    inventory_actor.request_all_paths()
    inventory_actor.request_all_script_paths()
end

local function extractCharacterName(dannetPeerName)
    if not dannetPeerName or dannetPeerName == "" then
        return dannetPeerName
    end

    local charName = dannetPeerName

    -- If it's a DanNet format with underscores, extract the character name
    if dannetPeerName:find("_") then
        local parts = {}
        for part in dannetPeerName:gmatch("[^_]+") do
            table.insert(parts, part)
        end
        charName = parts[#parts] or dannetPeerName
    end

    -- Always normalize to Title Case
    if charName and #charName > 0 then
        return charName:sub(1, 1):upper() .. charName:sub(2):lower()
    end

    return charName
end

local function getPeerConnectionStatus()
    local connectionMethod = "None"
    local connectedPeers = {}

    local function string_trim(s)
        return s:match("^%s*(.-)%s*$")
    end

    if mq.TLO.Plugin("MQ2Mono") and mq.TLO.Plugin("MQ2Mono").IsLoaded() then
        connectionMethod = "MQ2Mono"
        local e3Query = "e3,E3Bots.ConnectedClients"
        local peersStr = mq.TLO.MQ2Mono.Query(e3Query)()

        if peersStr and type(peersStr) == "string" and peersStr:lower() ~= "null" and peersStr ~= "" then
            for peer in string.gmatch(peersStr, "([^,]+)") do
                peer = string_trim(peer)
                local normalizedPeer = extractCharacterName(peer)
                if peer ~= "" and normalizedPeer ~= extractCharacterName(mq.TLO.Me.CleanName()) then
                    table.insert(connectedPeers, {
                        name = normalizedPeer,
                        displayName = peer,
                        method = "MQ2Mono",
                        online = true,
                    })
                end
            end
        end
    elseif mq.TLO.Plugin("MQ2DanNet") and mq.TLO.Plugin("MQ2DanNet").IsLoaded() then
        connectionMethod = "DanNet"
        local peersStr = mq.TLO.DanNet.Peers() or ""

        if peersStr and peersStr ~= "" then
            for peer in string.gmatch(peersStr, "([^|]+)") do
                peer = string_trim(peer)
                if peer ~= "" then
                    local charName = extractCharacterName(peer)
                    local myNormalizedName = extractCharacterName(mq.TLO.Me.CleanName())
                    if charName ~= myNormalizedName then
                        table.insert(connectedPeers, {
                            name = charName,
                            displayName = peer,
                            method = "DanNet",
                            online = true,
                        })
                    end
                end
            end
        end
    elseif mq.TLO.Plugin("MQ2EQBC") and mq.TLO.Plugin("MQ2EQBC").IsLoaded() and mq.TLO.EQBC.Connected() then
        connectionMethod = "EQBC"
        local names = mq.TLO.EQBC.Names() or ""
        if names ~= "" then
            for name in names:gmatch("([^%s]+)") do
                local normalizedName = extractCharacterName(name)
                local myNormalizedName = extractCharacterName(mq.TLO.Me.CleanName())
                if normalizedName ~= myNormalizedName then
                    table.insert(connectedPeers, {
                        name = normalizedName,
                        displayName = name,
                        method = "EQBC",
                        online = true,
                    })
                end
            end
        end
    end
    return connectionMethod, connectedPeers
end

local function toggleItemSelection(item, uniqueKey, sourcePeer)
    if not inventoryUI.selectedItems[uniqueKey] then
        inventoryUI.selectedItems[uniqueKey] = {
            item = item,
            key = uniqueKey,
            source = sourcePeer or mq.TLO.Me.Name(),
        }
    else
        inventoryUI.selectedItems[uniqueKey] = nil
    end
end

local function drawSelectionIndicator(uniqueKey, isHovered)
    if inventoryUI.multiSelectMode and inventoryUI.selectedItems[uniqueKey] then
        local drawList = ImGui.GetWindowDrawList()
        local min_x, min_y = ImGui.GetItemRectMin()
        local max_x, max_y = ImGui.GetItemRectMax()
        drawList:AddRectFilled(ImVec2(min_x, min_y), ImVec2(max_x, max_y), 0x5000FF00)
    elseif inventoryUI.multiSelectMode and isHovered then
        local drawList = ImGui.GetWindowDrawList()
        local min_x, min_y = ImGui.GetItemRectMin()
        local max_x, max_y = ImGui.GetItemRectMax()
        drawList:AddRectFilled(ImVec2(min_x, min_y), ImVec2(max_x, max_y), 0x300080FF)
    end
end

local function drawItemIcon(iconID, width, height)
    width = width or ICON_WIDTH
    height = height or ICON_HEIGHT
    if iconID and iconID > 0 then
        animItems:SetTextureCell(iconID - EQ_ICON_OFFSET)
        ImGui.DrawTextureAnimation(animItems, width, height)
    else
        ImGui.Text("N/A")
    end
end

local function draw_empty_slot_cbb(cell_id)
    local cursor_x, cursor_y = ImGui.GetCursorPos()
    if show_item_background_cbb and animBox then
        ImGui.DrawTextureAnimation(animBox, CBB_ICON_WIDTH, CBB_ICON_HEIGHT)
    end
    ImGui.SetCursorPos(cursor_x, cursor_y)
    ImGui.PushStyleColor(ImGuiCol.Button, 0, 0, 0, 0)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0, 0.3, 0, 0.2)
    ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0, 0.3, 0, 0.3)
    ImGui.Button("##empty_" .. cell_id, CBB_ICON_WIDTH, CBB_ICON_HEIGHT)
    ImGui.PopStyleColor(3)

    if mq.TLO.Cursor.ID() and ImGui.IsItemClicked(ImGuiMouseButton.Left) then
        local cursorItemTLO = mq.TLO.Cursor
        local pack_number_str, slotIndex_str = cell_id:match("bag_(%d+)_slot_(%d+)")
        if pack_number_str and slotIndex_str then
            -- Convert strings to numbers
            local pack_number = tonumber(pack_number_str)
            local slotIndex = tonumber(slotIndex_str)

            if not pack_number then
                print("[ERROR] Invalid pack number")
                return
            end
            --printf("[DEBUG] Drop Attempt: pack_number=%s, slotIndex=%s", tostring(pack_number), tostring(slotIndex))
            if pack_number >= 1 and pack_number <= 12 and slotIndex >= 1 then
                if inventoryUI.selectedPeer == extractCharacterName(mq.TLO.Me.Name()) then
                    mq.cmdf("/itemnotify in pack%d %d leftmouseup", pack_number, slotIndex)
                    local newItem = {
                        name = cursorItemTLO.Name(),
                        id = cursorItemTLO.ID(),
                        icon = cursorItemTLO.Icon(),
                        qty = cursorItemTLO.StackCount(),
                        bagid = pack_number,
                        slotid = slotIndex,
                        nodrop = cursorItemTLO.NoDrop() and 1 or 0,
                    }

                    if not inventoryUI.inventoryData.bags[pack_number] then
                        inventoryUI.inventoryData.bags[pack_number] = {}
                    end

                    local replaced = false
                    local bagItems = inventoryUI.inventoryData.bags[pack_number]
                    for i = #bagItems, 1, -1 do
                        if tonumber(bagItems[i].slotid) == slotIndex then
                            --printf("[DEBUG] Optimistically replacing existing item in UI data: Bag %d, Slot %d", pack_number, slotIndex)
                            bagItems[i] = newItem
                            replaced = true
                            break
                        end
                    end

                    if not replaced then
                        --printf("[DEBUG] Optimistically adding new item to UI data: Bag %d, Slot %d", pack_number, slotIndex)
                        table.insert(inventoryUI.inventoryData.bags[pack_number], newItem)
                    end
                else
                    print("Cannot directly place items in another character's bag.")
                end
            else
                printf("[ERROR] Invalid pack/slot ID derived from cell_id: %s (pack_number=%s, slotIndex=%s)",
                    cell_id, tostring(pack_number), tostring(slotIndex))
            end
        else
            print("[ERROR] Could not parse pack/slot ID from cell_id: " .. cell_id)
        end
    end
end

local function draw_live_item_icon_cbb(item_tlo, cell_id)
    local cursor_x, cursor_y = ImGui.GetCursorPos()

    if show_item_background_cbb and animBox then
        ImGui.DrawTextureAnimation(animBox, CBB_ICON_WIDTH, CBB_ICON_HEIGHT)
    end

    if item_tlo.Icon() and item_tlo.Icon() > 0 and animItems then
        ImGui.SetCursorPos(cursor_x, cursor_y)
        animItems:SetTextureCell(item_tlo.Icon() - EQ_ICON_OFFSET)
        ImGui.DrawTextureAnimation(animItems, CBB_ICON_WIDTH, CBB_ICON_HEIGHT)
    end

    local stackCount = item_tlo.Stack() or 1
    if stackCount > 1 then
        ImGui.SetWindowFontScale(0.68)
        local stackStr = tostring(stackCount)
        local textSize = ImGui.CalcTextSize(stackStr)
        local text_x = cursor_x + CBB_COUNT_X_OFFSET - textSize
        local text_y = cursor_y + CBB_COUNT_Y_OFFSET
        ImGui.SetCursorPos(text_x, text_y)
        ImGui.TextUnformatted(stackStr)
        ImGui.SetWindowFontScale(1.0)
    end

    ImGui.SetCursorPos(cursor_x, cursor_y)
    ImGui.PushStyleColor(ImGuiCol.Button, 0, 0, 0, 0)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0, 0.3, 0, 0.2)
    ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0, 0.3, 0, 0.3)
    ImGui.Button("##live_item_" .. cell_id, CBB_ICON_WIDTH, CBB_ICON_HEIGHT)
    ImGui.PopStyleColor(3)

    if ImGui.IsItemHovered() then
        ImGui.BeginTooltip()
        ImGui.Text(item_tlo.Name() or "Unknown Item")
        ImGui.Text("Qty: " .. tostring(stackCount))
        ImGui.EndTooltip()
    end

    if ImGui.IsItemClicked(ImGuiMouseButton.Left) then
        local mainSlot = item_tlo.ItemSlot()
        local subSlot = item_tlo.ItemSlot2()

        --printf("[DEBUG] Live Pickup Click: mainSlot=%s, subSlot=%s", tostring(mainSlot), tostring(subSlot))

        if mainSlot >= 23 and mainSlot <= 34 then -- It's in a bag slot
            local pack_number = mainSlot - 22
            if subSlot == -1 then
                mq.cmdf('/shift /itemnotify "%s" leftmouseup', item_tlo.Name())
                print(' [WARN] Pickup fallback: Used item name for item not in subslot.')
            else
                local command_slotid = subSlot + 1
                mq.cmdf("/shift /itemnotify in pack%d %d leftmouseup", pack_number, command_slotid)
            end
        else
            print("[ERROR] Cannot perform standard bag pickup for item in slot " .. tostring(mainSlot))
        end
    end

    if ImGui.IsItemClicked(ImGuiMouseButton.Right) then
        mq.cmdf('/useitem "%s"', item_tlo.Name())
    end
end

local function draw_item_icon_cbb(item, cell_id)
    local cursor_x, cursor_y = ImGui.GetCursorPos()

    if show_item_background_cbb and animBox then
        ImGui.DrawTextureAnimation(animBox, CBB_ICON_WIDTH, CBB_ICON_HEIGHT)
    end

    -- Draw the item's icon (using the existing animItems)
    if item.icon and item.icon > 0 and animItems then
        ImGui.SetCursorPos(cursor_x, cursor_y)
        animItems:SetTextureCell(item.icon - EQ_ICON_OFFSET)
        ImGui.DrawTextureAnimation(animItems, CBB_ICON_WIDTH, CBB_ICON_HEIGHT)
    else
    end

    -- Draw stack count (using item.qty from database)
    local stackCount = tonumber(item.qty) or 1
    if stackCount > 1 then
        ImGui.SetWindowFontScale(0.68)
        local stackStr = tostring(stackCount)
        local textSize = ImGui.CalcTextSize(stackStr)
        local text_x = cursor_x + CBB_COUNT_X_OFFSET - textSize -- Right align
        local text_y = cursor_y + CBB_COUNT_Y_OFFSET
        ImGui.SetCursorPos(text_x, text_y)
        ImGui.TextUnformatted(stackStr)
        ImGui.SetWindowFontScale(1.0)
    end

    -- Transparent button for interaction
    ImGui.SetCursorPos(cursor_x, cursor_y)
    ImGui.PushStyleColor(ImGuiCol.Button, 0, 0, 0, 0)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0, 0.3, 0, 0.2)
    ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0, 0.3, 0, 0.3)
    ImGui.Button("##item_" .. cell_id, CBB_ICON_WIDTH, CBB_ICON_HEIGHT)
    ImGui.PopStyleColor(3)

    if ImGui.IsItemHovered() then
        ImGui.BeginTooltip()
        ImGui.Text(item.name or "Unknown Item")
        ImGui.Text("Qty: " .. tostring(stackCount))
        for i = 1, 6 do
            local augField = "aug" .. i .. "Name"
            if item[augField] and item[augField] ~= "" then
                ImGui.Text(string.format("Aug %d: %s", i, item[augField]))
            end
        end
        ImGui.EndTooltip()
    end

    if ImGui.IsItemClicked(ImGuiMouseButton.Left) then
        local bagid_raw = item.bagid
        local slotid_raw = item.slotid
        --printf("[DEBUG] Clicked '%s': DB bagid=%s, DB slotid=%s", item.name, tostring(bagid_raw), tostring(slotid_raw))

        local pack_number = tonumber(bagid_raw)
        local command_slotid = tonumber(slotid_raw)

        if not pack_number or not command_slotid then
            printf(
                "[ERROR] Missing or non-numeric bagid/slotid in database item: %s (bagid_raw=%s, slotid_raw=%s)",
                item.name, tostring(bagid_raw), tostring(slotid_raw))
        else
            --printf("[DEBUG] Interpreted: pack_number=%s, command_slotid=%s", tostring(pack_number), tostring(command_slotid))

            if pack_number >= 1 and pack_number <= 12 and command_slotid >= 1 then
                if inventoryUI.selectedPeer == extractCharacterName(mq.TLO.Me.Name()) then
                    mq.cmdf("/itemnotify in pack%d %d leftmouseup", pack_number, command_slotid)

                    if inventoryUI.inventoryData.bags[pack_number] then
                        local bagItems = inventoryUI.inventoryData.bags[pack_number]
                        for i = #bagItems, 1, -1 do
                            if tonumber(bagItems[i].slotid) == command_slotid then
                                --printf("[DEBUG] Optimistically removing item from UI data: Bag %d, Slot %d", pack_number, command_slotid)
                                table.remove(bagItems, i)
                                break
                            end
                        end
                    end
                else
                    print("Cannot directly pick up items from another character's bag.")
                end
            else
                printf(
                    "[ERROR] Invalid pack/slot ID check failed for item: %s (pack_number=%s, command_slotid=%s)",
                    item.name, tostring(pack_number),
                    tostring(command_slotid))
            end
        end
    end
end

local function renderLoadingScreen(message, subMessage, tipMessage)
    message = message or "Loading Inventory Data..."
    subMessage = subMessage or "Scanning items"
    tipMessage = tipMessage or "This may take a moment for large inventories"
    local windowWidth = ImGui.GetWindowWidth()
    local availableHeight = ImGui.GetContentRegionAvail()
    local totalContentHeight = 120
    local startY = math.max(0, (availableHeight - totalContentHeight) * 0.3)

    ImGui.SetCursorPosY(ImGui.GetCursorPosY() + startY)
    local spinnerRadius = 12
    local spinnerSize = spinnerRadius * 2
    ImGui.SetCursorPosX((windowWidth - spinnerSize) * 0.5)

    local time = mq.gettime() / 1000
    local spinnerThickness = 3
    local drawList = ImGui.GetWindowDrawList()
    local cursorScreenX, cursorScreenY = ImGui.GetCursorScreenPos()
    local center = ImVec2(cursorScreenX + spinnerRadius, cursorScreenY + spinnerRadius)
    for i = 0, 7 do
        local angle = (time * 8 + i) * (math.pi * 2 / 8)
        local alpha = math.max(0.1, 1.0 - (i / 8.0))
        local color = ImGui.GetColorU32(0.3, 0.7, 1.0, alpha)
        local x1 = center.x + math.cos(angle) * (spinnerRadius - spinnerThickness)
        local y1 = center.y + math.sin(angle) * (spinnerRadius - spinnerThickness)
        local x2 = center.x + math.cos(angle) * spinnerRadius
        local y2 = center.y + math.sin(angle) * spinnerRadius
        drawList:AddLine(ImVec2(x1, y1), ImVec2(x2, y2), color, spinnerThickness)
    end
    ImGui.Dummy(spinnerSize, spinnerSize)
    ImGui.Spacing()
    local loadingWidth = ImGui.CalcTextSize(message)
    ImGui.SetCursorPosX((windowWidth - loadingWidth) * 0.5)
    ImGui.PushStyleColor(ImGuiCol.Text, 0.3, 0.7, 1.0, 1.0)
    ImGui.Text(message)
    ImGui.PopStyleColor()
    ImGui.Spacing()
    local dots = ""
    local dotCount = math.floor((time * 2) % 4)
    for i = 1, dotCount do
        dots = dots .. "."
    end
    local statusText = subMessage .. dots
    local statusWidth = ImGui.CalcTextSize(statusText)
    ImGui.SetCursorPosX((windowWidth - statusWidth) * 0.5)
    ImGui.PushStyleColor(ImGuiCol.Text, 0.7, 0.7, 0.7, 1.0)
    ImGui.Text(statusText)
    ImGui.PopStyleColor()
    ImGui.Spacing()
    ImGui.Spacing()
    local tipWidth = ImGui.CalcTextSize(tipMessage)
    ImGui.SetCursorPosX((windowWidth - tipWidth) * 0.5)
    ImGui.PushStyleColor(ImGuiCol.Text, 0.5, 0.5, 0.5, 1.0)
    ImGui.Text(tipMessage)
    ImGui.PopStyleColor()
end

local function requestDetailedStatsForComparison(availableItem, currentlyEquipped, callback)
    inventoryUI.isLoadingComparison = true
    inventoryUI.comparisonError = nil

    local statsCollected = {}
    local requestsCompleted = 0
    local totalRequests = 0

    -- Count total requests needed
    if availableItem then totalRequests = totalRequests + 1 end
    if currentlyEquipped then totalRequests = totalRequests + 1 end

    if totalRequests == 0 then
        inventoryUI.isLoadingComparison = false
        callback(nil, nil)
        return
    end

    local function checkCompletion()
        requestsCompleted = requestsCompleted + 1
        if requestsCompleted >= totalRequests then
            inventoryUI.isLoadingComparison = false
            callback(statsCollected.available, statsCollected.equipped)
        end
    end

    -- Request stats for available item
    if availableItem then
        Suggestions.requestDetailedStats(
            availableItem.source,
            availableItem.name,
            availableItem.location,
            function(detailedStats)
                if detailedStats then
                    -- Merge basic and detailed stats
                    statsCollected.available = {}
                    for k, v in pairs(availableItem.item) do
                        statsCollected.available[k] = v
                    end
                    for k, v in pairs(detailedStats) do
                        statsCollected.available[k] = v
                    end
                else
                    inventoryUI.comparisonError = "Failed to get stats for " .. (availableItem.name or "selected item")
                    statsCollected.available = availableItem.item -- fallback to basic stats
                end
                checkCompletion()
            end
        )
    end

    -- Request stats for currently equipped item
    if currentlyEquipped then
        -- Determine location for equipped item
        local equipLocation = "Equipped"

        Suggestions.requestDetailedStats(
            inventoryUI.itemSuggestionsTarget,
            currentlyEquipped.name,
            equipLocation,
            function(detailedStats)
                if detailedStats then
                    statsCollected.equipped = detailedStats
                else
                    inventoryUI.comparisonError = "Failed to get stats for equipped item"
                    statsCollected.equipped = currentlyEquipped -- fallback to basic stats
                end
                checkCompletion()
            end
        )
    else
        checkCompletion()
    end
end

local buttonWinFlags = bit32.bor(
    ImGuiWindowFlags.NoTitleBar,
    ImGuiWindowFlags.NoResize,
    ImGuiWindowFlags.NoScrollbar,
    ImGuiWindowFlags.NoFocusOnAppearing,
    ImGuiWindowFlags.AlwaysAutoResize,
    ImGuiWindowFlags.NoBackground
)

local function InventoryToggleButton()
    ImGui.PushStyleColor(ImGuiCol.WindowBg, ImVec4(0, 0, 0, 0))
    ImGui.Begin("EZInvToggle", nil, buttonWinFlags)

    local time = mq.gettime() / 1000
    local pulse = (math.sin(time * 3) + 1) * 0.5
    local base_color = inventoryUI.visible and { 0.2, 0.8, 0.2, 1.0 } or { 0.7, 0.2, 0.2, 1.0 }
    local hover_color = {
        base_color[1] + 0.2 * pulse,
        base_color[2] + 0.2 * pulse,
        base_color[3] + 0.2 * pulse,
        1.0,
    }

    ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, 10)
    ImGui.PushStyleColor(ImGuiCol.Button, ImVec4(base_color[1], base_color[2], base_color[3], 0.85))
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, ImVec4(hover_color[1], hover_color[2], hover_color[3], 1.0))
    ImGui.PushStyleColor(ImGuiCol.ButtonActive,
        ImVec4(base_color[1] * 0.8, base_color[2] * 0.8, base_color[3] * 0.8, 1.0))

    local icon = icons.FA_ITALIC or "Inv"
    if ImGui.Button(icon, 50, 50) then
        inventoryUI.visible = not inventoryUI.visible
    end

    if ImGui.IsItemHovered() then
        ImGui.SetTooltip(inventoryUI.visible and "Hide Inventory" or "Show Inventory")
    end

    ImGui.PopStyleColor(3)
    ImGui.PopStyleVar()
    ImGui.End()
    ImGui.PopStyleColor()
end

--------------------------------------------------
-- Helper: Update List of Connected Peers
--------------------------------------------------
local function updatePeerList()
    inventoryUI.peers = {}
    inventoryUI.servers = {}

    local myName = extractCharacterName(mq.TLO.Me.Name())
    local selfEntry = {
        name = myName,
        server = server,
        isMailbox = true,
        isBotCharacter = false,
        data = inventory_actor.gather_inventory(),
    }
    table.insert(inventoryUI.peers, selfEntry)

    -- Add regular player peers
    for _, invData in pairs(inventory_actor.peer_inventories) do
        if invData.name ~= myName then
            local peerEntry = {
                name = invData.name or "Unknown",
                server = invData.server,
                isMailbox = true,
                isBotCharacter = false,
                data = invData,
            }
            table.insert(inventoryUI.peers, peerEntry)

            if not inventoryUI.servers[invData.server] then
                inventoryUI.servers[invData.server] = {}
            end
            table.insert(inventoryUI.servers[invData.server], peerEntry)
        end
    end

    table.sort(inventoryUI.peers, function(a, b)
        return a.name:lower() < b.name:lower()
    end)
end

--------------------------------------------------
--- Function: Check Database Lock Status
--------------------------------------------------
local function refreshInventoryData()
    inventoryUI.inventoryData = { equipped = {}, bags = {}, bank = {}, }

    for _, peer in ipairs(inventoryUI.peers) do
        if peer.name == inventoryUI.selectedPeer then
            if peer.data then
                inventoryUI.inventoryData = peer.data
            elseif peer.name == extractCharacterName(mq.TLO.Me.Name()) then
                inventoryUI.inventoryData = inventory_actor.gather_inventory()
            end
            break
        end
    end
end

--------------------------------------------------
-- Helper: Load inventory data from the mailbox.
--------------------------------------------------
local function loadInventoryData(peer)
    inventoryUI.inventoryData = { equipped = {}, bags = {}, bank = {}, }

    if peer and peer.data then
        inventoryUI.inventoryData.equipped = peer.data.equipped or {}
        inventoryUI.inventoryData.bags = peer.data.bags or {}
        inventoryUI.inventoryData.bank = peer.data.bank or {}
    elseif peer.name == extractCharacterName(mq.TLO.Me.Name()) then
        local gathered = inventory_actor.gather_inventory()
        inventoryUI.inventoryData.equipped = gathered.equipped or {}
        inventoryUI.inventoryData.bags = gathered.bags or {}
        inventoryUI.inventoryData.bank = gathered.bank or {}
    end
end

function OnStatsLoadingModeChanged(newMode)
    local validModes = { minimal = true, selective = true, full = true }
    if not validModes[newMode] then
        newMode = "minimal"
    end

    Settings.statsLoadingMode = newMode
    if newMode == "minimal" then
        Settings.loadBasicStats = false
        Settings.loadDetailedStats = false
    elseif newMode == "selective" then
        Settings.loadBasicStats = true
        Settings.loadDetailedStats = false
    elseif newMode == "full" then
        Settings.loadBasicStats = true
        Settings.loadDetailedStats = true
    end

    inventoryUI.statsLoadingMode = Settings.statsLoadingMode
    inventoryUI.loadBasicStats = Settings.loadBasicStats
    inventoryUI.loadDetailedStats = Settings.loadDetailedStats

    UpdateInventoryActorConfig()
    mq.pickle(SettingsFile, Settings)
end

function SaveConfigWithStatsUpdate()
    for key, value in pairs(inventoryUI) do
        if Config.Defaults[key] ~= nil then
            Settings[key] = value
        end
    end

    local success, err = pcall(mq.pickle, SettingsFile, Settings)
    if success then
        print(string.format("\ag[EZInventory]\ax Config saved to \ay%s", SettingsFile))
    else
        print(string.format("\ar[EZInventory]\ax Error saving config: %s", tostring(err)))
    end
    UpdateInventoryActorConfig()
end

--------------------------------------------------
-- Helper: Get the slot name from slot ID
--------------------------------------------------
local Utils = require("EZInventory.modules.utils")
local getSlotNameFromID = Utils.get_slot_name_from_id

--------------------------------------------------
-- Function: Compare slot across all peers
--------------------------------------------------
local function compareSlotAcrossPeers(slotID)
    local results = {}

    for _, invData in pairs(inventory_actor.peer_inventories) do
        local peerName = invData.name or "Unknown"
        local peerServer = invData.server or "Unknown"

        for _, item in ipairs(invData.equipped or {}) do
            if tonumber(item.slotid) == slotID then
                table.insert(results, {
                    peerName = peerName,
                    peerServer = peerServer,
                    item = item,
                })
                break
            end
        end
    end

    table.sort(results, function(a, b) return (a.peerName or "") < (b.peerName or "") end)
    return results
end

--------------------------------------------------
-- Function: Get Class Armor Type
--------------------------------------------------
local function getArmorTypeByClass(class)
    if class == "WAR" or class == "CLR" or class == "PAL" or class == "SHD" or class == "BRD" then
        return "Plate"
    elseif class == "RNG" or class == "ROG" or class == "SHM" or class == "BER" then
        return "Chain"
    elseif class == "NEC" or class == "WIZ" or class == "MAG" or class == "ENC" then
        return "Cloth"
    elseif class == "DRU" or class == "MNK" or class == "BST" then
        return "Leather"
    else
        return "Unknown"
    end
end

local itemGroups = {
    Weapon = { "1H Blunt", "1H Slashing", "2H Blunt", "2H Slashing", "Bow", "Throwing", "Wind Instrument" },
    Armor = { "Armor", "Shield" },
    Jewelry = { "Jewelry" },
    Consumable = { "Drink", "Food", "Potion" },
    Scrolls = { "Scroll", "Spell" }
}

local function itemMatchesGroup(itemType, selectedGroup)
    if selectedGroup == "All" then return true end
    local groupList = itemGroups[selectedGroup]
    if not groupList then return false end
    for _, groupType in ipairs(groupList) do
        if itemType == groupType then return true end
    end
    return false
end

--------------------------------------------------
-- Function: Search Across All Peers
--------------------------------------------------
local function searchAcrossPeers()
    local results = {}
    local searchTerm = (searchText or ""):lower()

    local function itemMatches(item)
        if searchTerm == "" then return true end
        if (item.name or ""):lower():find(searchTerm) then return true end
        for i = 1, 6 do
            local aug = item["aug" .. i .. "Name"]
            if aug and aug:lower():find(searchTerm) then return true end
        end
        return false
    end
    for _, invData in pairs(inventory_actor.peer_inventories) do
        local function searchItems(items, sourceLabel)
            if sourceLabel == "Equipped" or sourceLabel == "Bank" then
                for _, item in ipairs(items or {}) do
                    if itemMatches(item) then
                        local itemCopy = {}
                        for k, v in pairs(item) do
                            itemCopy[k] = v
                        end
                        itemCopy.peerName = invData.name or "unknown"
                        itemCopy.peerServer = invData.server or "unknown"
                        itemCopy.source = sourceLabel
                        table.insert(results, itemCopy)
                    end
                end
            elseif sourceLabel == "Inventory" then
                for bagId, bagItems in pairs(items or {}) do
                    for _, item in ipairs(bagItems or {}) do
                        if itemMatches(item) then
                            local itemCopy = {}
                            for k, v in pairs(item) do
                                itemCopy[k] = v
                            end
                            itemCopy.peerName = invData.name or "unknown"
                            itemCopy.peerServer = invData.server or "unknown"
                            itemCopy.source = sourceLabel
                            table.insert(results, itemCopy)
                        end
                    end
                end
            end
        end
        searchItems(invData.equipped, "Equipped")
        searchItems(invData.bags, "Inventory")
        searchItems(invData.bank, "Bank")
    end
    return results
end

local function getSelectedItemCount()
    local count = 0
    for _ in pairs(inventoryUI.selectedItems) do
        count = count + 1
    end
    return count
end

local function clearItemSelection()
    inventoryUI.selectedItems = {}
end

local function clearComparisonCache()
    Suggestions.clearStatsCache()
    inventoryUI.detailedAvailableStats = nil
    inventoryUI.detailedEquippedStats = nil
    inventoryUI.comparisonError = nil
end

--------------------------------------------------
-- Context Menu Functions
--------------------------------------------------

function showContextMenu(item, sourceChar, mouseX, mouseY)
    if not item then
        print("[ERROR] Cannot show context menu for nil item")
        return
    end

    if not sourceChar then
        print("[ERROR] Cannot show context menu - source character is nil")
        return
    end

    if not mouseX or not mouseY then
        mouseX, mouseY = ImGui.GetMousePos()
    end

    local itemCopy = {}
    for k, v in pairs(item) do
        itemCopy[k] = v
    end

    inventoryUI.contextMenu.visible = true
    inventoryUI.contextMenu.item = itemCopy
    inventoryUI.contextMenu.source = sourceChar
    inventoryUI.contextMenu.x = mouseX
    inventoryUI.contextMenu.y = mouseY

    inventoryUI.contextMenu.peers = {}

    local seenPeers = {}
    local serverPeers = peerCache[mq.TLO.MacroQuest.Server()] or {}

    for _, peer in ipairs(serverPeers) do
        if peer.name ~= sourceChar and not seenPeers[peer.name] then
            table.insert(inventoryUI.contextMenu.peers, peer.name)
            seenPeers[peer.name] = true
        end
    end

    table.sort(inventoryUI.contextMenu.peers)
    inventoryUI.contextMenu.selectedPeer = nil

    --printf("[DEBUG] Context menu opened for %s from %s", (itemCopy.name or "Unknown Item"), (sourceChar or "Unknown Source"))
end

function hideContextMenu()
    inventoryUI.contextMenu.visible = false
    inventoryUI.contextMenu.item = nil
    inventoryUI.contextMenu.source = nil
    inventoryUI.contextMenu.selectedPeer = nil
    inventoryUI.contextMenu.peers = {}
    inventoryUI.contextMenu.x = 0
    inventoryUI.contextMenu.y = 0
end

function renderContextMenu()
    if not inventoryUI.contextMenu.visible then return end
    if not inventoryUI.contextMenu.item then
        print("[DEBUG] Context menu item is nil, closing menu")
        hideContextMenu()
        return
    end

    ImGui.SetNextWindowPos(inventoryUI.contextMenu.x, inventoryUI.contextMenu.y)

    if ImGui.Begin("##ItemContextMenu", nil, ImGuiWindowFlags.NoTitleBar + ImGuiWindowFlags.NoResize + ImGuiWindowFlags.AlwaysAutoResize + ImGuiWindowFlags.NoSavedSettings) then
        local itemName = "Unknown Item"
        if inventoryUI.contextMenu.item and inventoryUI.contextMenu.item.name then
            itemName = inventoryUI.contextMenu.item.name
        end
        ImGui.Text(itemName)
        ImGui.Separator()
        if ImGui.MenuItem(inventoryUI.multiSelectMode and "Exit Multi-Select" or "Enter Multi-Select") then
            inventoryUI.multiSelectMode = not inventoryUI.multiSelectMode
            if not inventoryUI.multiSelectMode then
                clearItemSelection()
            end
            hideContextMenu()
        end
        if inventoryUI.multiSelectMode then
            ImGui.Separator()
            local uniqueKey = string.format("%s_%s_%s",
                inventoryUI.contextMenu.source or "unknown",
                (inventoryUI.contextMenu.item and inventoryUI.contextMenu.item.name) or "unnamed",
                (inventoryUI.contextMenu.item and inventoryUI.contextMenu.item.slotid) or "noslot")

            local isSelected = inventoryUI.selectedItems[uniqueKey] ~= nil

            if ImGui.MenuItem(isSelected and "Deselect Item" or "Select Item") then
                if inventoryUI.contextMenu.item then
                    toggleItemSelection(inventoryUI.contextMenu.item, uniqueKey)
                end
                hideContextMenu()
            end

            local selectedCount = getSelectedItemCount()
            if selectedCount > 0 then
                if ImGui.MenuItem(string.format("Trade Selected (%d items)", selectedCount)) then
                    inventoryUI.showMultiTradePanel = true
                    hideContextMenu()
                end

                if ImGui.MenuItem("Clear All Selections") then
                    clearItemSelection()
                    hideContextMenu()
                end
            end
            ImGui.Separator()
        end
        if ImGui.MenuItem("Examine") then
            if inventoryUI.contextMenu.item and inventoryUI.contextMenu.item.itemlink then
                local links = mq.ExtractLinks(inventoryUI.contextMenu.item.itemlink)
                if links and #links > 0 then
                    mq.ExecuteTextLink(links[1])
                else
                    print(' No item link found in the database.')
                end
            else
                print(' No item data available for examination.')
            end
            hideContextMenu()
        end

        -- Only show Compare Equipment for equippable items
        local item = inventoryUI.contextMenu.item
        local canEquip = false
        if item then
            canEquip = (item.slots and #item.slots > 0) or item.slotid
        end

        if canEquip and ImGui.MenuItem("Compare Equipment") then
            showEquipmentComparison(item)
            hideContextMenu()
        end
        if not inventoryUI.multiSelectMode then
            local isNoDrop = false
            if inventoryUI.contextMenu.item and inventoryUI.contextMenu.item.nodrop and inventoryUI.contextMenu.item.nodrop == 1 then
                isNoDrop = true
            end

            if not isNoDrop then
                if ImGui.BeginMenu("Trade To") then
                    for _, peerName in ipairs(inventoryUI.contextMenu.peers or {}) do
                        if ImGui.MenuItem(peerName) then
                            -- Only initiate trade if we have valid item data
                            if inventoryUI.contextMenu.item then
                                initiateProxyTrade(inventoryUI.contextMenu.item, inventoryUI.contextMenu.source, peerName)
                            else
                                print(' Cannot trade - item data is missing.')
                            end
                            hideContextMenu()
                        end
                    end
                    ImGui.EndMenu()
                end
            else
                ImGui.PushStyleColor(ImGuiCol.Text, 0.5, 0.5, 0.5, 1.0)
                ImGui.MenuItem("Trade To (No Drop Item)", false, false)
                ImGui.PopStyleColor()
            end
        end

        ImGui.Separator()

        if ImGui.MenuItem("Cancel") then
            hideContextMenu()
        end

        ImGui.End()
    end

    if ImGui.IsMouseClicked(ImGuiMouseButton.Left) and not ImGui.IsWindowHovered(ImGuiHoveredFlags.AnyWindow) then
        hideContextMenu()
    end
end

---------------------------------------------------
-- Equipment Comparison Functions
---------------------------------------------------

function showEquipmentComparison(item)
    if not item then
        print("Cannot compare - no item provided")
        return
    end

    -- Determine available slots for this item
    local availableSlots = {}

    if item.slots and #item.slots > 0 then
        -- Use the item's defined slots
        for _, slotID in ipairs(item.slots) do
            table.insert(availableSlots, tonumber(slotID))
        end
    elseif item.slotid then
        -- Fallback to single slotid if available
        table.insert(availableSlots, tonumber(item.slotid))
    else
        print("Cannot compare - item has no slot information")
        return
    end

    if #availableSlots == 0 then
        print("Cannot compare - item has no valid slots")
        return
    end

    -- If multiple slots, show selection; if one slot, auto-select
    if #availableSlots == 1 then
        -- Auto-select the only available slot
        inventoryUI.equipmentComparison = {
            visible = true,
            compareItem = item,
            slotID = availableSlots[1],
            availableSlots = availableSlots,
            results = {}
        }
        generateEquipmentComparison(item, availableSlots[1])
    else
        -- Show slot selection interface
        inventoryUI.equipmentComparison = {
            visible = true,
            compareItem = item,
            slotID = nil, -- Will be selected by user
            availableSlots = availableSlots,
            showSlotSelection = true,
            results = {}
        }
    end
end

function generateEquipmentComparison(compareItem, slotID)
    local results = {}
    slotID = slotID or compareItem.slotid

    -- Get stats from the comparison item
    local compareStats = {
        ac = compareItem.ac or 0,
        hp = compareItem.hp or 0,
        mana = compareItem.mana or 0,
        svMagic = compareItem.svMagic or 0,
        svFire = compareItem.svFire or 0,
        svCold = compareItem.svCold or 0,
        svDisease = compareItem.svDisease or 0,
        svPoison = compareItem.svPoison or 0,
        clickySpell = compareItem.clickySpell or "None"
    }

    -- Compare against each character's equipped item in that slot
    for peerID, invData in pairs(inventory_actor.peer_inventories) do
        if invData and invData.name and invData.equipped then
            -- Check if this character's class can use the comparison item
            local characterClass = invData.class

            -- Fallback: Try to get class from spawn data if not in inventory data
            if not characterClass or characterClass == "UNK" then
                local spawn = mq.TLO.Spawn("pc = " .. invData.name)
                if spawn() then
                    characterClass = spawn.Class()
                end
            end

            -- Final fallback: If it's the current character, use Me.Class
            if (not characterClass or characterClass == "UNK") and invData.name == mq.TLO.Me.CleanName() then
                characterClass = mq.TLO.Me.Class()
            end

            -- Skip if we still don't have a class or if the class can't use the item
            if not characterClass or characterClass == "UNK" or not Suggestions.canClassUseItem(compareItem, characterClass) then
                goto continue -- Skip this character
            end

            local equippedItem = nil

            -- Find the equipped item in this slot
            for _, item in ipairs(invData.equipped) do
                if item.slotid == slotID then
                    equippedItem = item
                    break
                end
            end

            local currentStats = {
                ac = 0,
                hp = 0,
                mana = 0,
                svMagic = 0,
                svFire = 0,
                svCold = 0,
                svDisease = 0,
                svPoison = 0,
                clickySpell = "None"
            }

            if equippedItem then
                currentStats.ac = equippedItem.ac or 0
                currentStats.hp = equippedItem.hp or 0
                currentStats.mana = equippedItem.mana or 0
                currentStats.svMagic = equippedItem.svMagic or 0
                currentStats.svFire = equippedItem.svFire or 0
                currentStats.svCold = equippedItem.svCold or 0
                currentStats.svDisease = equippedItem.svDisease or 0
                currentStats.svPoison = equippedItem.svPoison or 0
                currentStats.clickySpell = equippedItem.clickySpell or "None"
            end

            -- Calculate net changes
            local netChange = {
                ac = compareStats.ac - currentStats.ac,
                hp = compareStats.hp - currentStats.hp,
                mana = compareStats.mana - currentStats.mana,
                svMagic = compareStats.svMagic - currentStats.svMagic,
                svFire = compareStats.svFire - currentStats.svFire,
                svCold = compareStats.svCold - currentStats.svCold,
                svDisease = compareStats.svDisease - currentStats.svDisease,
                svPoison = compareStats.svPoison - currentStats.svPoison
            }

            table.insert(results, {
                characterName = invData.name,
                currentItem = equippedItem,
                netChange = netChange,
                currentStats = currentStats,
                newStats = compareStats
            })
        end
        ::continue::
    end

    -- Sort by character name
    table.sort(results, function(a, b)
        return a.characterName < b.characterName
    end)

    inventoryUI.equipmentComparison.results = results
end

function renderEquipmentComparison()
    if not inventoryUI.equipmentComparison or not inventoryUI.equipmentComparison.visible then
        return
    end

    local comparison = inventoryUI.equipmentComparison
    if not comparison.compareItem then
        inventoryUI.equipmentComparison.visible = false
        return
    end

    ImGui.SetNextWindowSize(800, 400, ImGuiCond.FirstUseEver)
    local windowTitle = string.format("Equipment Comparison: %s", comparison.compareItem.name or "Unknown Item")

    if ImGui.Begin(windowTitle, true) then
        -- Show slot selection if needed
        if comparison.showSlotSelection then
            ImGui.Text("Select slot to compare against:")

            -- Create slot name mapping
            local slotNames = {
                [0] = "Charm",
                [1] = "Left Ear",
                [2] = "Head",
                [3] = "Face",
                [4] = "Right Ear",
                [5] = "Neck",
                [6] = "Shoulders",
                [7] = "Arms",
                [8] = "Back",
                [9] = "Left Wrist",
                [10] = "Right Wrist",
                [11] = "Range",
                [12] = "Hands",
                [13] = "Primary",
                [14] = "Secondary",
                [15] = "Left Ring",
                [16] = "Right Ring",
                [17] = "Chest",
                [18] = "Legs",
                [19] = "Feet",
                [20] = "Waist",
                [21] = "Ammo",
                [22] = "Power Source"
            }

            for _, slotID in ipairs(comparison.availableSlots) do
                local slotName = slotNames[slotID] or ("Slot " .. slotID)
                if ImGui.Button(string.format("%s (Slot %d)", slotName, slotID)) then
                    comparison.slotID = slotID
                    comparison.showSlotSelection = false
                    generateEquipmentComparison(comparison.compareItem, slotID)
                    break
                end
            end

            ImGui.Separator()
            if ImGui.Button("Cancel") then
                inventoryUI.equipmentComparison.visible = false
            end
        else
            -- Show comparison results
            local slotNames = {
                [0] = "Charm",
                [1] = "Left Ear",
                [2] = "Head",
                [3] = "Face",
                [4] = "Right Ear",
                [5] = "Neck",
                [6] = "Shoulders",
                [7] = "Arms",
                [8] = "Back",
                [9] = "Left Wrist",
                [10] = "Right Wrist",
                [11] = "Range",
                [12] = "Hands",
                [13] = "Primary",
                [14] = "Secondary",
                [15] = "Left Ring",
                [16] = "Right Ring",
                [17] = "Chest",
                [18] = "Legs",
                [19] = "Feet",
                [20] = "Waist",
                [21] = "Ammo",
                [22] = "Power Source"
            }
            local slotName = slotNames[comparison.slotID] or ("Slot " .. (comparison.slotID or 0))

            ImGui.Text(string.format("Comparing %s vs %s", comparison.compareItem.name or "Unknown", slotName))
            ImGui.Text(string.format("New Item Stats - AC: %d, HP: %d, Mana: %d",
                comparison.compareItem.ac or 0,
                comparison.compareItem.hp or 0,
                comparison.compareItem.mana or 0))

            -- Show class restrictions and filtering info
            local classInfo = Suggestions.getItemClassInfo(comparison.compareItem)
            ImGui.TextColored(0.7, 0.7, 1.0, 1.0, string.format("Classes: %s", classInfo))
            ImGui.TextColored(0.6, 0.8, 0.6, 1.0, "Note: Only showing characters whose class can use this item")

            -- Show slot selection button if multiple slots available
            if comparison.availableSlots and #comparison.availableSlots > 1 then
                if ImGui.Button("Change Slot") then
                    comparison.showSlotSelection = true
                end
                ImGui.SameLine()
            end

            -- Column visibility checkboxes
            ImGui.Text("Show Columns:")
            ImGui.SameLine()
            inventoryUI.comparisonShowSvMagic = ImGui.Checkbox("SvMagic", inventoryUI.comparisonShowSvMagic)
            ImGui.SameLine()
            inventoryUI.comparisonShowSvFire = ImGui.Checkbox("SvFire", inventoryUI.comparisonShowSvFire)
            ImGui.SameLine()
            inventoryUI.comparisonShowSvCold = ImGui.Checkbox("SvCold", inventoryUI.comparisonShowSvCold)
            ImGui.SameLine()
            inventoryUI.comparisonShowSvDisease = ImGui.Checkbox("SvDisease", inventoryUI.comparisonShowSvDisease)
            ImGui.SameLine()
            inventoryUI.comparisonShowSvPoison = ImGui.Checkbox("SvPoison", inventoryUI.comparisonShowSvPoison)
            ImGui.SameLine()
            inventoryUI.comparisonShowClickies = ImGui.Checkbox("Clickies", inventoryUI.comparisonShowClickies)

            ImGui.Separator()

            -- Calculate dynamic column count
            local baseColumns = 5 -- Character, Current Item, AC Change, HP Change, Mana Change
            local optionalColumns = 0
            if inventoryUI.comparisonShowSvMagic then optionalColumns = optionalColumns + 1 end
            if inventoryUI.comparisonShowSvFire then optionalColumns = optionalColumns + 1 end
            if inventoryUI.comparisonShowSvCold then optionalColumns = optionalColumns + 1 end
            if inventoryUI.comparisonShowSvDisease then optionalColumns = optionalColumns + 1 end
            if inventoryUI.comparisonShowSvPoison then optionalColumns = optionalColumns + 1 end
            if inventoryUI.comparisonShowClickies then optionalColumns = optionalColumns + 1 end
            local totalColumns = baseColumns + optionalColumns

            if ImGui.BeginTable("ComparisonTable", totalColumns, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.Resizable) then
                ImGui.TableSetupColumn("Character", ImGuiTableColumnFlags.WidthFixed, 100)
                ImGui.TableSetupColumn("Current Item", ImGuiTableColumnFlags.WidthStretch)
                ImGui.TableSetupColumn("AC Change", ImGuiTableColumnFlags.WidthFixed, 80)
                ImGui.TableSetupColumn("HP Change", ImGuiTableColumnFlags.WidthFixed, 80)
                ImGui.TableSetupColumn("Mana Change", ImGuiTableColumnFlags.WidthFixed, 80)

                -- Dynamic optional columns
                if inventoryUI.comparisonShowSvMagic then
                    ImGui.TableSetupColumn("SvMagic Change", ImGuiTableColumnFlags.WidthFixed, 80)
                end
                if inventoryUI.comparisonShowSvFire then
                    ImGui.TableSetupColumn("SvFire Change", ImGuiTableColumnFlags.WidthFixed, 80)
                end
                if inventoryUI.comparisonShowSvCold then
                    ImGui.TableSetupColumn("SvCold Change", ImGuiTableColumnFlags.WidthFixed, 80)
                end
                if inventoryUI.comparisonShowSvDisease then
                    ImGui.TableSetupColumn("SvDisease Change", ImGuiTableColumnFlags.WidthFixed, 80)
                end
                if inventoryUI.comparisonShowSvPoison then
                    ImGui.TableSetupColumn("SvPoison Change", ImGuiTableColumnFlags.WidthFixed, 80)
                end
                if inventoryUI.comparisonShowClickies then
                    ImGui.TableSetupColumn("Clicky Effect", ImGuiTableColumnFlags.WidthStretch)
                end
                ImGui.TableHeadersRow()

                for _, result in ipairs(comparison.results) do
                    ImGui.TableNextRow()

                    -- Character name
                    ImGui.TableNextColumn()
                    ImGui.Text(result.characterName)

                    -- Current item
                    ImGui.TableNextColumn()
                    if result.currentItem then
                        local itemName = result.currentItem.name or "Unknown"
                        local uniqueID = string.format("%s_%s", result.characterName, result.currentItem.slotid or "0")
                        if ImGui.Selectable(itemName .. "##" .. uniqueID) then
                            local links = mq.ExtractLinks(result.currentItem.itemlink)
                            if links and #links > 0 then
                                mq.ExecuteTextLink(links[1])
                            else
                                print(' No item link found in the database.')
                            end
                        end
                    else
                        ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "(empty slot)")
                    end

                    -- AC Change
                    ImGui.TableNextColumn()
                    local acChange = result.netChange.ac
                    if acChange > 0 then
                        ImGui.TextColored(0.0, 1.0, 0.0, 1.0, string.format("+%d", acChange))
                    elseif acChange < 0 then
                        ImGui.TextColored(1.0, 0.0, 0.0, 1.0, string.format("%d", acChange))
                    else
                        ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "0")
                    end

                    -- HP Change
                    ImGui.TableNextColumn()
                    local hpChange = result.netChange.hp
                    if hpChange > 0 then
                        ImGui.TextColored(0.0, 1.0, 0.0, 1.0, string.format("+%d", hpChange))
                    elseif hpChange < 0 then
                        ImGui.TextColored(1.0, 0.0, 0.0, 1.0, string.format("%d", hpChange))
                    else
                        ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "0")
                    end

                    -- Mana Change
                    ImGui.TableNextColumn()
                    local manaChange = result.netChange.mana
                    if manaChange > 0 then
                        ImGui.TextColored(0.0, 1.0, 0.0, 1.0, string.format("+%d", manaChange))
                    elseif manaChange < 0 then
                        ImGui.TextColored(1.0, 0.0, 0.0, 1.0, string.format("%d", manaChange))
                    else
                        ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "0")
                    end

                    -- Optional resist columns
                    if inventoryUI.comparisonShowSvMagic then
                        ImGui.TableNextColumn()
                        local svMagicChange = (result.newStats.svMagic or 0) - (result.currentStats.svMagic or 0)
                        if svMagicChange > 0 then
                            ImGui.TextColored(0.0, 1.0, 0.0, 1.0, string.format("+%d", svMagicChange))
                        elseif svMagicChange < 0 then
                            ImGui.TextColored(1.0, 0.0, 0.0, 1.0, string.format("%d", svMagicChange))
                        else
                            ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "0")
                        end
                    end

                    if inventoryUI.comparisonShowSvFire then
                        ImGui.TableNextColumn()
                        local svFireChange = (result.newStats.svFire or 0) - (result.currentStats.svFire or 0)
                        if svFireChange > 0 then
                            ImGui.TextColored(0.0, 1.0, 0.0, 1.0, string.format("+%d", svFireChange))
                        elseif svFireChange < 0 then
                            ImGui.TextColored(1.0, 0.0, 0.0, 1.0, string.format("%d", svFireChange))
                        else
                            ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "0")
                        end
                    end

                    if inventoryUI.comparisonShowSvCold then
                        ImGui.TableNextColumn()
                        local svColdChange = (result.newStats.svCold or 0) - (result.currentStats.svCold or 0)
                        if svColdChange > 0 then
                            ImGui.TextColored(0.0, 1.0, 0.0, 1.0, string.format("+%d", svColdChange))
                        elseif svColdChange < 0 then
                            ImGui.TextColored(1.0, 0.0, 0.0, 1.0, string.format("%d", svColdChange))
                        else
                            ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "0")
                        end
                    end

                    if inventoryUI.comparisonShowSvDisease then
                        ImGui.TableNextColumn()
                        local svDiseaseChange = (result.newStats.svDisease or 0) - (result.currentStats.svDisease or 0)
                        if svDiseaseChange > 0 then
                            ImGui.TextColored(0.0, 1.0, 0.0, 1.0, string.format("+%d", svDiseaseChange))
                        elseif svDiseaseChange < 0 then
                            ImGui.TextColored(1.0, 0.0, 0.0, 1.0, string.format("%d", svDiseaseChange))
                        else
                            ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "0")
                        end
                    end

                    if inventoryUI.comparisonShowSvPoison then
                        ImGui.TableNextColumn()
                        local svPoisonChange = (result.newStats.svPoison or 0) - (result.currentStats.svPoison or 0)
                        if svPoisonChange > 0 then
                            ImGui.TextColored(0.0, 1.0, 0.0, 1.0, string.format("+%d", svPoisonChange))
                        elseif svPoisonChange < 0 then
                            ImGui.TextColored(1.0, 0.0, 0.0, 1.0, string.format("%d", svPoisonChange))
                        else
                            ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "0")
                        end
                    end

                    if inventoryUI.comparisonShowClickies then
                        ImGui.TableNextColumn()
                        local newClicky = result.newStats.clickySpell or "None"
                        local currentClicky = result.currentStats.clickySpell or "None"
                        if newClicky ~= "None" and newClicky ~= currentClicky then
                            ImGui.TextColored(0.3, 1.0, 0.3, 1.0, newClicky)
                        elseif currentClicky ~= "None" and newClicky ~= currentClicky then
                            ImGui.TextColored(1.0, 0.3, 0.3, 1.0, "Lost: " .. currentClicky)
                        else
                            ImGui.TextColored(0.6, 0.6, 0.6, 1.0, newClicky)
                        end
                    end
                end

                ImGui.EndTable()
            end

            ImGui.Separator()
            if ImGui.Button("Close") then
                inventoryUI.equipmentComparison.visible = false
            end
        end

        ImGui.End()
    else
        inventoryUI.equipmentComparison.visible = false
    end
end

local itemSuggestionsCache = {
    equippedItem = nil,
    lastPeerName = nil,
    lastSlotID = nil
}

function renderItemSuggestions()
    if not inventoryUI.showItemSuggestions then return end


    local function getEquippedItemForPeerSlot(peerName, slotID)
        if not peerName or not slotID then return nil end

        -- Check if we can use cached result (parameters haven't changed)
        if itemSuggestionsCache.equippedItem and
            itemSuggestionsCache.lastPeerName == peerName and
            itemSuggestionsCache.lastSlotID == slotID then
            return itemSuggestionsCache.equippedItem
        end


        local equippedItem = nil
        if peerName == extractCharacterName(mq.TLO.Me.Name()) then
            local equipped = inventory_actor.gather_inventory().equipped or {}
            for _, item in ipairs(equipped) do
                if tonumber(item.slotid) == tonumber(slotID) then
                    equippedItem = item
                    break
                end
            end
        else
            for _, peer in pairs(inventory_actor.peer_inventories) do
                if peer.name == peerName and peer.equipped then
                    for _, item in ipairs(peer.equipped) do
                        if tonumber(item.slotid) == tonumber(slotID) then
                            equippedItem = item
                            break
                        end
                    end
                    if equippedItem then break end
                end
            end
        end

        -- Cache the result with the parameters used
        itemSuggestionsCache.equippedItem = equippedItem
        itemSuggestionsCache.lastPeerName = peerName
        itemSuggestionsCache.lastSlotID = slotID
        return equippedItem
    end

    local currentlyEquipped = getEquippedItemForPeerSlot(inventoryUI.itemSuggestionsTarget,
        inventoryUI.itemSuggestionsSlot)
    local numItems = #inventoryUI.availableItems
    local baseHeight = 200
    local comparisonHeight = (inventoryUI.selectedComparisonItem and inventoryUI.selectedComparisonItemId ~= "") and 250 or
        0
    local rowHeight = 25
    local maxTableHeight = 300
    local minWindowHeight = 350

    local tableHeight = math.min(maxTableHeight, math.max(100, (numItems + 1) * rowHeight + 30))
    local windowHeight = math.max(minWindowHeight, baseHeight + tableHeight + comparisonHeight)

    ImGui.SetNextWindowSize(900, windowHeight, ImGuiCond.Once)

    -- FIXED: Properly handle the window open/close state
    local isOpen, shouldShow = ImGui.Begin("Available Items for " .. inventoryUI.itemSuggestionsTarget, true)

    -- Check if user clicked the X button to close
    if not isOpen then
        inventoryUI.showItemSuggestions = false
    end

    -- Only render content if the window should be shown (not minimized)
    if shouldShow then
        ImGui.Text(string.format("Finding %s items for %s:",
            inventoryUI.itemSuggestionsSlotName,
            inventoryUI.itemSuggestionsTarget))

        ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.8, 0.8, 1.0)
        if inventoryUI.selectedPeer and inventoryUI.selectedPeer ~= inventoryUI.itemSuggestionsTarget then
            ImGui.Text(string.format("(Right-clicked %s slot while viewing %s's inventory)",
                inventoryUI.itemSuggestionsSlotName, inventoryUI.selectedPeer))
        else
            ImGui.Text(string.format("(Right-clicked %s slot on visual equipment display)",
                inventoryUI.itemSuggestionsSlotName))
        end
        ImGui.PopStyleColor()

        if currentlyEquipped then
            ImGui.Spacing()
            ImGui.Text("Currently Equipped:")
            ImGui.SameLine()
            ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.6, 1.0)
            ImGui.Text(currentlyEquipped.name or "Unknown")
            ImGui.PopStyleColor()
        else
            ImGui.Spacing()
            ImGui.PushStyleColor(ImGuiCol.Text, 0.7, 0.7, 0.7, 1.0)
            ImGui.Text("Currently Equipped: (empty slot)")
            ImGui.PopStyleColor()
        end

        ImGui.Separator()

        if #inventoryUI.availableItems == 0 then
            ImGui.Text("No suitable tradeable items found for this slot.")
            ImGui.Spacing()
            ImGui.PushStyleColor(ImGuiCol.Text, 0.7, 0.7, 0.7, 1.0)
            ImGui.Text("This could mean:")
            ImGui.Text("No other characters have items for this slot")
            ImGui.Text("All available items are No Drop")
            ImGui.Text("Items don't match class/level requirements")
            ImGui.PopStyleColor()
        else
            ImGui.Text(string.format("Found %d available items:", #inventoryUI.availableItems))

            -- Filter controls
            ImGui.Spacing()
            ImGui.Text("Filters:")
            ImGui.SameLine()

            -- Source character filter
            local sources = {}
            local sourceMap = {}
            for _, availableItem in ipairs(inventoryUI.availableItems) do
                if not sourceMap[availableItem.source] then
                    sourceMap[availableItem.source] = true
                    table.insert(sources, availableItem.source)
                end
            end
            table.sort(sources)

            inventoryUI.itemSuggestionsSourceFilter = inventoryUI.itemSuggestionsSourceFilter or "All"
            ImGui.SetNextItemWidth(120)
            if ImGui.BeginCombo("##SourceFilter", inventoryUI.itemSuggestionsSourceFilter) then
                if ImGui.Selectable("All", inventoryUI.itemSuggestionsSourceFilter == "All") then
                    inventoryUI.itemSuggestionsSourceFilter = "All"
                end
                for _, source in ipairs(sources) do
                    if ImGui.Selectable(source, inventoryUI.itemSuggestionsSourceFilter == source) then
                        inventoryUI.itemSuggestionsSourceFilter = source
                    end
                end
                ImGui.EndCombo()
            end

            ImGui.SameLine()
            -- Location filter
            inventoryUI.itemSuggestionsLocationFilter = inventoryUI.itemSuggestionsLocationFilter or "All"
            ImGui.SetNextItemWidth(100)
            if ImGui.BeginCombo("##LocationFilter", inventoryUI.itemSuggestionsLocationFilter) then
                local locations = { "All", "Equipped", "Bags", "Bank", }
                for _, location in ipairs(locations) do
                    if ImGui.Selectable(location, inventoryUI.itemSuggestionsLocationFilter == location) then
                        inventoryUI.itemSuggestionsLocationFilter = location
                    end
                end
                ImGui.EndCombo()
            end

            -- Add sorting controls
            ImGui.SameLine()
            ImGui.Text("Sort by:")
            ImGui.SameLine()

            -- Initialize sorting state
            inventoryUI.itemSuggestionsSortColumn = inventoryUI.itemSuggestionsSortColumn or "none"
            inventoryUI.itemSuggestionsSortDirection = inventoryUI.itemSuggestionsSortDirection or "asc"

            ImGui.SetNextItemWidth(120)
            if ImGui.BeginCombo("##SuggestionsSortColumn", inventoryUI.itemSuggestionsSortColumn) then
                local sortOptions = {
                    { "none", "None" },
                    { "name", "Item Name" },
                    { "source", "Source" },
                    { "location", "Location" }
                }

                -- Add detailed stat sorting options if enabled
                if Settings.showDetailedStats then
                    table.insert(sortOptions, { "hp", "HP" })
                    table.insert(sortOptions, { "mana", "Mana" })
                    table.insert(sortOptions, { "ac", "AC" })
                    table.insert(sortOptions, { "str", "STR" })
                    table.insert(sortOptions, { "agi", "AGI" })
                end

                for _, option in ipairs(sortOptions) do
                    local selected = (inventoryUI.itemSuggestionsSortColumn == option[1])
                    if ImGui.Selectable(option[2], selected) then
                        inventoryUI.itemSuggestionsSortColumn = option[1]
                    end
                end
                ImGui.EndCombo()
            end

            if inventoryUI.itemSuggestionsSortColumn ~= "none" then
                ImGui.SameLine()
                if ImGui.Button(inventoryUI.itemSuggestionsSortDirection == "asc" and "Asc" or "Desc") then
                    inventoryUI.itemSuggestionsSortDirection = inventoryUI.itemSuggestionsSortDirection == "asc" and "desc" or "asc"
                    inventoryUI.filteredItemsCache.lastFilterKey = ""  -- Invalidate cache
                end
            end

            -- Cached filtering system to avoid re-filtering every frame
            local filteredItems = {}
            local filterKey = string.format("%s_%s_%s_%s_%s_%d",
                inventoryUI.itemSuggestionsTarget or "nil",
                inventoryUI.itemSuggestionsSourceFilter or "nil",
                inventoryUI.itemSuggestionsLocationFilter or "nil",
                currentlyEquipped and currentlyEquipped.name or "nil",
                inventoryUI.itemSuggestionsSortColumn or "nil",
                #inventoryUI.availableItems)

            -- Only rebuild filtered items if something changed
            if inventoryUI.filteredItemsCache.lastFilterKey ~= filterKey then
                local newFilteredItems = {}

                for _, availableItem in ipairs(inventoryUI.availableItems) do
                    local includeItem = true

                    -- Check if item is an augment (do this first)
                    local isAugment = availableItem.item and availableItem.item.itemtype and
                                     tostring(availableItem.item.itemtype):lower():find("augment")

                    -- Filter out augments if they belong to the target character
                    if isAugment and availableItem.source == inventoryUI.itemSuggestionsTarget then
                        includeItem = false
                    end

                    -- Filter nodrop items: only show nodrop items if they belong to the target character
                    if includeItem and availableItem.item and availableItem.item.nodrop == 1 and
                       availableItem.source ~= inventoryUI.itemSuggestionsTarget then
                        includeItem = false
                    end

                    -- Filter out items that are currently equipped in the same slot
                    if includeItem and availableItem.source == inventoryUI.itemSuggestionsTarget and
                       currentlyEquipped and availableItem.name == currentlyEquipped.name and
                       availableItem.location == "Equipped" then
                        includeItem = false
                    end

                    if includeItem and inventoryUI.itemSuggestionsSourceFilter ~= "All" and
                        availableItem.source ~= inventoryUI.itemSuggestionsSourceFilter then
                        includeItem = false
                    end

                    if includeItem and inventoryUI.itemSuggestionsLocationFilter ~= "All" and
                        availableItem.location ~= inventoryUI.itemSuggestionsLocationFilter then
                        includeItem = false
                    end

                    -- Additional class/race filtering for target character
                    if includeItem then
                        local targetClass = "UNK"
                        local targetRace = "UNK"

                        -- Get target character's class and race
                        local function getRaceCode(raceName)
                            local raceMap = {
                                ["Human"] = "HUM", ["Barbarian"] = "BAR", ["Erudite"] = "ERU",
                                ["Wood Elf"] = "ELF", ["High Elf"] = "HIE", ["Dark Elf"] = "DEF",
                                ["Half Elf"] = "HEL", ["Dwarf"] = "DWF", ["Troll"] = "TRL",
                                ["Ogre"] = "OGR", ["Halfling"] = "HFL", ["Gnome"] = "GNM",
                                ["Iksar"] = "IKS", ["Vah Shir"] = "VAH", ["Froglok"] = "FRG",
                                ["Drakkin"] = "DRK"
                            }
                            return raceMap[raceName] or raceName or "UNK"
                        end

                        if inventoryUI.itemSuggestionsTarget == mq.TLO.Me.CleanName() then
                            targetClass = mq.TLO.Me.Class() or "UNK"
                            local raceObj = mq.TLO.Me.Race
                            local raceName = tostring(raceObj) or "UNK"
                            targetRace = getRaceCode(raceName)
                        else
                            local spawn = mq.TLO.Spawn("pc = " .. inventoryUI.itemSuggestionsTarget)
                            if spawn() then
                                targetClass = spawn.Class() or "UNK"
                                local raceObj = spawn.Race
                                local raceName = tostring(raceObj) or "UNK"
                                targetRace = getRaceCode(raceName)
                            else
                                -- Fallback to peer inventory data
                                for peerID, invData in pairs(inventory_actor.peer_inventories or {}) do
                                    if invData.name == inventoryUI.itemSuggestionsTarget then
                                        targetClass = invData.class or "UNK"
                                        -- Note: race not stored in peer data, will remain "UNK"
                                        break
                                    end
                                end
                            end
                        end


                        -- Class filtering
                        if targetClass ~= "UNK" and availableItem.item then
                            local canUseClass = false
                            if availableItem.item.allClasses then
                                canUseClass = true
                            elseif availableItem.item.classes and #availableItem.item.classes > 0 then
                                for _, allowedClass in ipairs(availableItem.item.classes) do
                                    if allowedClass == targetClass then
                                        canUseClass = true
                                        break
                                    end
                                end
                            else
                                -- Fallback: assume usable if no class restrictions found
                                canUseClass = true
                            end

                            if not canUseClass then
                                includeItem = false
                            end
                        end

                        -- Race filtering
                        if includeItem and targetRace ~= "UNK" and availableItem.item then
                            local races = availableItem.item.races
                            if races and type(races) == "string" and races ~= "" then
                                if races == "ALL" then
                                    -- all good
                                elseif not races:find(targetRace) then
                                    includeItem = false
                                end
                            end
                        end
                    end

                    if includeItem then
                        table.insert(newFilteredItems, availableItem)
                    end
                end

                -- Apply sorting to the filtered items before caching
                if inventoryUI.itemSuggestionsSortColumn ~= "none" and #newFilteredItems > 0 then
                    table.sort(newFilteredItems, function(a, b)
                        if not a or not b then return false end

                        local valueA, valueB

                        if inventoryUI.itemSuggestionsSortColumn == "name" then
                            valueA = (a.name or ""):lower()
                            valueB = (b.name or ""):lower()
                        elseif inventoryUI.itemSuggestionsSortColumn == "source" then
                            valueA = (a.source or ""):lower()
                            valueB = (b.source or ""):lower()
                        elseif inventoryUI.itemSuggestionsSortColumn == "location" then
                            valueA = (a.location or ""):lower()
                            valueB = (b.location or ""):lower()
                        elseif inventoryUI.itemSuggestionsSortColumn == "hp" then
                            valueA = tonumber(a.item.hp) or 0
                            valueB = tonumber(b.item.hp) or 0
                        elseif inventoryUI.itemSuggestionsSortColumn == "mana" then
                            valueA = tonumber(a.item.mana) or 0
                            valueB = tonumber(b.item.mana) or 0
                        elseif inventoryUI.itemSuggestionsSortColumn == "ac" then
                            valueA = tonumber(a.item.ac) or 0
                            valueB = tonumber(b.item.ac) or 0
                        elseif inventoryUI.itemSuggestionsSortColumn == "str" then
                            valueA = tonumber(a.item.str) or 0
                            valueB = tonumber(b.item.str) or 0
                        elseif inventoryUI.itemSuggestionsSortColumn == "agi" then
                            valueA = tonumber(a.item.agi) or 0
                            valueB = tonumber(b.item.agi) or 0
                        else
                            return false
                        end

                        if inventoryUI.itemSuggestionsSortDirection == "asc" then
                            return valueA < valueB
                        else
                            return valueA > valueB
                        end
                    end)
                end

                -- Cache the filtered and sorted results
                inventoryUI.filteredItemsCache.items = newFilteredItems
                inventoryUI.filteredItemsCache.lastFilterKey = filterKey
            end

            -- Use cached filtered and sorted items
            filteredItems = inventoryUI.filteredItemsCache.items

            ImGui.Spacing()

            inventoryUI.itemSuggestionsPage = inventoryUI.itemSuggestionsPage or 1
            local itemsPerPage = 20
            local totalPages = math.max(1, math.ceil(#filteredItems / itemsPerPage))

            if inventoryUI.itemSuggestionsPage > totalPages then
                inventoryUI.itemSuggestionsPage = totalPages
            end

            local startIdx = (inventoryUI.itemSuggestionsPage - 1) * itemsPerPage + 1
            local endIdx = math.min(startIdx + itemsPerPage - 1, #filteredItems)
            local pagedItems = {}
            for i = startIdx, endIdx do
                if filteredItems[i] then
                    table.insert(pagedItems, filteredItems[i])
                end
            end

            if #filteredItems ~= #inventoryUI.availableItems then
                ImGui.Text(string.format("Showing %d-%d of %d items (filtered, page %d/%d)",
                    startIdx, endIdx, #filteredItems, inventoryUI.itemSuggestionsPage, totalPages))
            else
                ImGui.Text(string.format("Showing %d-%d of %d items (page %d/%d)",
                    startIdx, endIdx, #filteredItems, inventoryUI.itemSuggestionsPage, totalPages))
            end

            if totalPages > 1 then
                ImGui.SameLine()
                if ImGui.Button("Prev") and inventoryUI.itemSuggestionsPage > 1 then
                    inventoryUI.itemSuggestionsPage = inventoryUI.itemSuggestionsPage - 1
                end
                ImGui.SameLine()
                if ImGui.Button("Next") and inventoryUI.itemSuggestionsPage < totalPages then
                    inventoryUI.itemSuggestionsPage = inventoryUI.itemSuggestionsPage + 1
                end
            end

            -- Show all details checkbox
            ImGui.Spacing()
            local showDetailedStats, detailedChanged = ImGui.Checkbox("Show All Details", Settings.showDetailedStats)
            if detailedChanged then
                Settings.showDetailedStats = showDetailedStats
                mq.pickle(SettingsFile, Settings)
            end

            ImGui.SameLine()
            local autoExchangeEnabled, autoExchangeChanged = ImGui.Checkbox("Auto Exchange", Settings.autoExchangeEnabled)
            if autoExchangeChanged then
                Settings.autoExchangeEnabled = autoExchangeEnabled
                mq.pickle(SettingsFile, Settings)
            end
            ImGui.Spacing()

            -- FIXED: Better table height calculation and error handling
            local calculatedTableHeight = math.min(maxTableHeight, math.max(100, (itemsPerPage + 1) * rowHeight + 30))

            -- Determine number of columns based on detailed view
            local numColumns = Settings.showDetailedStats and 12 or 6
            if ImGui.BeginTable("AvailableItemsTable", numColumns, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.ScrollY, 0, calculatedTableHeight) then
                ImGui.TableSetupColumn("Select", ImGuiTableColumnFlags.WidthFixed, 50)
                ImGui.TableSetupColumn("Icon", ImGuiTableColumnFlags.WidthFixed, 40)
                ImGui.TableSetupColumn("Item Name", ImGuiTableColumnFlags.WidthStretch)
                ImGui.TableSetupColumn("Source", ImGuiTableColumnFlags.WidthFixed, 100)
                ImGui.TableSetupColumn("Location", ImGuiTableColumnFlags.WidthFixed, 100)

                if Settings.showDetailedStats then
                    ImGui.TableSetupColumn("HP", ImGuiTableColumnFlags.WidthFixed, 60)
                    ImGui.TableSetupColumn("MANA", ImGuiTableColumnFlags.WidthFixed, 60)
                    ImGui.TableSetupColumn("AC", ImGuiTableColumnFlags.WidthFixed, 50)
                    ImGui.TableSetupColumn("STR", ImGuiTableColumnFlags.WidthFixed, 50)
                    ImGui.TableSetupColumn("AGI", ImGuiTableColumnFlags.WidthFixed, 50)
                    ImGui.TableSetupColumn("Combat", ImGuiTableColumnFlags.WidthFixed, 80)
                end

                ImGui.TableSetupColumn("Action", ImGuiTableColumnFlags.WidthFixed, 80)

                ImGui.TableHeadersRow()

                if inventoryUI.selectedComparisonItemId == nil then
                    inventoryUI.selectedComparisonItemId = ""
                end
                if inventoryUI.selectedComparisonItem == nil then
                    inventoryUI.selectedComparisonItem = nil
                end

                for idx, availableItem in ipairs(pagedItems) do
                    ImGui.TableNextRow()
                    ImGui.PushID("available_item_" .. idx)

                    -- Create unique identifier for this item
                    local itemId = string.format("%s_%s_%s_%d",
                        availableItem.source or "unknown",
                        availableItem.name or "unnamed",
                        availableItem.location or "nowhere",
                        idx)
                    local isSelected = (inventoryUI.selectedComparisonItemId == itemId)

                    ImGui.TableNextColumn()
                    if ImGui.RadioButton("##radio_" .. idx, isSelected) then
                        inventoryUI.selectedComparisonItemId = itemId
                        inventoryUI.selectedComparisonItem = availableItem

                        if not itemSuggestionsCache.statsRequested or itemSuggestionsCache.lastStatsItemId ~= itemId then
                            inventoryUI.detailedAvailableStats = nil
                            inventoryUI.detailedEquippedStats = nil
                            itemSuggestionsCache.statsRequested = true
                            itemSuggestionsCache.lastStatsItemId = itemId

                            requestDetailedStatsForComparison(
                                availableItem,
                                currentlyEquipped,
                                function(availableStats, equippedStats)
                                    inventoryUI.detailedAvailableStats = availableStats
                                    inventoryUI.detailedEquippedStats = equippedStats
                                    itemSuggestionsCache.statsRequested = false
                                end
                            )
                        end
                    end

                    ImGui.TableNextColumn()
                    if availableItem.icon and availableItem.icon > 0 then
                        drawItemIcon(availableItem.icon)
                    else
                        ImGui.Text("N/A")
                    end

                    ImGui.TableNextColumn()
                    ImGui.Text(availableItem.name)

                    if ImGui.IsItemHovered() then
                        ImGui.BeginTooltip()
                        ImGui.Text(availableItem.name or "Unknown Item")
                        ImGui.Text("Select to compare with equipped item")
                        if availableItem.item.ac and availableItem.item.ac > 0 then
                            ImGui.Text("AC: " .. tostring(availableItem.item.ac))
                        end
                        if availableItem.item.hp and availableItem.item.hp > 0 then
                            ImGui.Text("HP: " .. tostring(availableItem.item.hp))
                        end
                        if availableItem.item.mana and availableItem.item.mana > 0 then
                            ImGui.Text("Mana: " .. tostring(availableItem.item.mana))
                        end
                        ImGui.EndTooltip()
                    end

                    ImGui.TableNextColumn()
                    if ImGui.Selectable(availableItem.source) then
                        inventory_actor.send_inventory_command(availableItem.source, "foreground", {})
                        printf("Bringing %s to the foreground...", availableItem.source)
                    end

                    ImGui.TableNextColumn()
                    ImGui.Text(availableItem.location)

                    -- Add detailed stat columns if enabled
                    if Settings.showDetailedStats then
                        -- HP Column
                        ImGui.TableNextColumn()
                        local hp = availableItem.item.hp or 0
                        if hp > 0 then
                            ImGui.Text(tostring(hp))
                        else
                            ImGui.PushStyleColor(ImGuiCol.Text, 0.5, 0.5, 0.5, 1.0)
                            ImGui.Text("-")
                            ImGui.PopStyleColor()
                        end

                        -- MANA Column
                        ImGui.TableNextColumn()
                        local mana = availableItem.item.mana or 0
                        if mana > 0 then
                            ImGui.Text(tostring(mana))
                        else
                            ImGui.PushStyleColor(ImGuiCol.Text, 0.5, 0.5, 0.5, 1.0)
                            ImGui.Text("-")
                            ImGui.PopStyleColor()
                        end

                        -- AC Column
                        ImGui.TableNextColumn()
                        local ac = availableItem.item.ac or 0
                        if ac > 0 then
                            ImGui.Text(tostring(ac))
                        else
                            ImGui.PushStyleColor(ImGuiCol.Text, 0.5, 0.5, 0.5, 1.0)
                            ImGui.Text("-")
                            ImGui.PopStyleColor()
                        end

                        -- STR Column
                        ImGui.TableNextColumn()
                        local str = availableItem.item.str or 0
                        if str > 0 then
                            ImGui.Text("+" .. tostring(str))
                        elseif str < 0 then
                            ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.3, 0.3, 1.0)
                            ImGui.Text(tostring(str))
                            ImGui.PopStyleColor()
                        else
                            ImGui.PushStyleColor(ImGuiCol.Text, 0.5, 0.5, 0.5, 1.0)
                            ImGui.Text("-")
                            ImGui.PopStyleColor()
                        end

                        -- AGI Column
                        ImGui.TableNextColumn()
                        local agi = availableItem.item.agi or 0
                        if agi > 0 then
                            ImGui.Text("+" .. tostring(agi))
                        elseif agi < 0 then
                            ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.3, 0.3, 1.0)
                            ImGui.Text(tostring(agi))
                            ImGui.PopStyleColor()
                        else
                            ImGui.PushStyleColor(ImGuiCol.Text, 0.5, 0.5, 0.5, 1.0)
                            ImGui.Text("-")
                            ImGui.PopStyleColor()
                        end

                        -- Combat Column (simplified - could show ATK, haste, etc.)
                        ImGui.TableNextColumn()
                        local hasEffect = (availableItem.item.effect and availableItem.item.effect ~= "")
                        if hasEffect then
                            ImGui.PushStyleColor(ImGuiCol.Text, 0.3, 0.8, 0.3, 1.0)
                            ImGui.Text("Effect")
                            ImGui.PopStyleColor()
                        else
                            ImGui.PushStyleColor(ImGuiCol.Text, 0.5, 0.5, 0.5, 1.0)
                            ImGui.Text("-")
                            ImGui.PopStyleColor()
                        end
                    end

                    ImGui.TableNextColumn()
                    -- Check if this is an augment (special handling)
                    local isAugment = availableItem.item and availableItem.item.itemtype and
                                     tostring(availableItem.item.itemtype):lower():find("augment")

                    if isAugment then
                        -- Augments: only show "Trade" button, never exchange logic
                        if ImGui.Button("Trade##" .. idx) then
                            inventoryUI.showGiveItemPanel = true
                            inventoryUI.selectedGiveItem = availableItem.name
                            inventoryUI.selectedGiveTarget = inventoryUI.itemSuggestionsTarget
                            inventoryUI.selectedGiveSource = availableItem.source
                        end
                    elseif availableItem.source == inventoryUI.itemSuggestionsTarget then
                        -- Determine if this is a swap (item equipped in different slot) or equip (unequipped item)
                        local isSwap = (availableItem.location == "Equipped")
                        local buttonText = isSwap and "Swap##" .. idx or "Equip##" .. idx
                        local actionText = isSwap and "swap" or "equip"

                        -- Use different colors for Swap vs Equip
                        if isSwap then
                            -- Orange colors for Swap
                            ImGui.PushStyleColor(ImGuiCol.Button, 1.0, 0.6, 0.2, 1.0)
                            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 1.0, 0.7, 0.3, 1.0)
                            ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.9, 0.5, 0.1, 1.0)
                        else
                            -- Purple colors for Equip
                            ImGui.PushStyleColor(ImGuiCol.Button, 0.8, 0.2, 0.8, 1.0)
                            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.9, 0.3, 0.9, 1.0)
                            ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.7, 0.1, 0.7, 1.0)
                        end

                        if ImGui.Button(buttonText) then
                            -- Send exchange command directly to the target character
                            if inventory_actor and inventory_actor.send_inventory_command then
                                local exchangeData = {
                                    itemName = availableItem.name,
                                    targetSlot = inventoryUI.itemSuggestionsSlot,
                                    targetSlotName = inventoryUI.itemSuggestionsSlotName
                                }
                                inventory_actor.send_inventory_command(availableItem.source, "perform_auto_exchange",
                                    { json.encode(exchangeData) })
                                printf("Sent %s command to %s for %s -> %s",
                                    actionText, availableItem.source, availableItem.name, inventoryUI.itemSuggestionsSlotName)
                            end
                            inventoryUI.showItemSuggestions = false
                        end
                        ImGui.PopStyleColor(3)
                    else
                        -- Show Trade button for items from other characters
                        local tradeButtonText = Settings.autoExchangeEnabled and "Trade and Equip##" .. idx or "Trade##" .. idx
                        if ImGui.Button(tradeButtonText) then
                            local peerRequest = {
                                name = availableItem.name,
                                to = inventoryUI.itemSuggestionsTarget,
                                fromBank = availableItem.location == "Bank",
                                bagid = availableItem.item.bagid,
                                slotid = availableItem.item.slotid,
                                bankslotid = availableItem.item.bankslotid,
                                -- Add auto-exchange information
                                autoExchange = Settings.autoExchangeEnabled,
                                targetSlot = inventoryUI.itemSuggestionsSlot,
                                targetSlotName = inventoryUI.itemSuggestionsSlotName
                            }

                            inventory_actor.send_inventory_command(availableItem.source, "proxy_give",
                                { json.encode(peerRequest), })
                            if Settings.autoExchangeEnabled then
                                printf("Requesting %s to give %s to %s for auto-exchange to %s",
                                    availableItem.source,
                                    availableItem.name,
                                    inventoryUI.itemSuggestionsTarget,
                                    inventoryUI.itemSuggestionsSlotName)
                            else
                                printf("Requesting %s to give %s to %s",
                                    availableItem.source,
                                    availableItem.name,
                                    inventoryUI.itemSuggestionsTarget)
                            end
                            inventoryUI.showItemSuggestions = false
                        end
                    end

                    ImGui.PopID()
                end

                ImGui.EndTable()
            else
                -- Table failed to begin - show fallback
                ImGui.Text("Table display error. Available items: " .. tostring(#filteredItems))
            end
        end

        -- Rest of the comparison code would go here...
        if inventoryUI.selectedComparisonItem and inventoryUI.selectedComparisonItemId ~= "" then
            ImGui.Separator()
            ImGui.Text("Stat Comparison:")
            ImGui.SameLine()
            ImGui.PushStyleColor(ImGuiCol.Text, 0.3, 1.0, 0.3, 1.0)
            ImGui.Text(inventoryUI.selectedComparisonItem.name)
            ImGui.PopStyleColor()
            ImGui.SameLine()
            ImGui.Text(" vs ")
            ImGui.SameLine()
            if currentlyEquipped then
                ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.6, 1.0)
                ImGui.Text(currentlyEquipped.name)
                ImGui.PopStyleColor()
            else
                ImGui.PushStyleColor(ImGuiCol.Text, 0.7, 0.7, 0.7, 1.0)
                ImGui.Text("(empty slot)")
                ImGui.PopStyleColor()
            end

            if inventoryUI.isLoadingComparison then
                ImGui.Spacing()
                ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 1.0, 0.0, 1.0)
                ImGui.Text("Loading detailed stats for comparison...")
                ImGui.PopStyleColor()
                local time = mq.gettime() / 1000
                local dots = ""
                local dotCount = math.floor((time * 2) % 4)
                for i = 1, dotCount do
                    dots = dots .. "."
                end
                ImGui.SameLine()
                ImGui.Text(dots)
            elseif inventoryUI.comparisonError then
                ImGui.Spacing()
                ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.3, 0.3, 1.0)
                ImGui.Text("Error: " .. inventoryUI.comparisonError)
                ImGui.PopStyleColor()
                ImGui.SameLine()
                if ImGui.Button("Retry") then
                    inventoryUI.comparisonError = nil
                    -- Trigger comparison again
                    if inventoryUI.selectedComparisonItem then
                        requestDetailedStatsForComparison(
                            inventoryUI.selectedComparisonItem,
                            currentlyEquipped,
                            function(availableStats, equippedStats)
                                inventoryUI.detailedAvailableStats = availableStats
                                inventoryUI.detailedEquippedStats = equippedStats
                            end
                        )
                    end
                end
            elseif inventoryUI.detailedAvailableStats and inventoryUI.detailedEquippedStats then
                local selectedItem = inventoryUI.detailedAvailableStats
                local equippedItem = inventoryUI.detailedEquippedStats or {}
                local function showStatComparisonColumn(statList, selectedItem, equippedItem)
                    if ImGui.BeginTable("StatColumn", 2, ImGuiTableFlags.SizingFixedFit) then
                        ImGui.TableSetupColumn("Stat", ImGuiTableColumnFlags.WidthFixed, 100)
                        ImGui.TableSetupColumn("Value", ImGuiTableColumnFlags.WidthFixed, 50)

                        for _, stat in ipairs(statList) do
                            local label = stat.label
                            local fieldName = stat.field or label:lower()
                            local suffix = stat.suffix or ""
                            local newVal = tonumber(selectedItem[fieldName]) or 0
                            local oldVal = tonumber(equippedItem[fieldName]) or 0
                            local diff = newVal - oldVal

                            if diff ~= 0 then
                                ImGui.TableNextRow()
                                ImGui.TableSetColumnIndex(0)
                                ImGui.Text(label .. ":")

                                ImGui.TableSetColumnIndex(1)
                                if diff > 0 then
                                    ImGui.PushStyleColor(ImGuiCol.Text, 0.3, 1.0, 0.3, 1.0)
                                    ImGui.Text(string.format("+%d%s", diff, suffix))
                                else
                                    ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.3, 0.3, 1.0)
                                    ImGui.Text(string.format("%d%s", diff, suffix))
                                end
                                ImGui.PopStyleColor()
                            end
                        end

                        ImGui.EndTable()
                    end
                end

                if ImGui.BeginTable("StatComparisonTable", 3, ImGuiTableFlags.BordersInnerV + ImGuiTableFlags.RowBg) then
                    ImGui.TableSetupColumn("Primary Stats")
                    ImGui.TableSetupColumn("Attributes")
                    ImGui.TableSetupColumn("Resists / Combat")
                    ImGui.TableHeadersRow()
                    ImGui.TableNextRow()

                    ImGui.TableSetColumnIndex(0)
                    showStatComparisonColumn({
                        { label = "AC", field = "ac" }, { label = "HP", field = "hp" }, { label = "Mana", field = "mana" }, { label = "Endurance", field = "endurance" },
                    }, selectedItem, equippedItem)

                    ImGui.TableSetColumnIndex(1)
                    showStatComparisonColumn({
                        { label = "STR", field = "str" }, { label = "STA", field = "sta" }, { label = "AGI", field = "agi" }, { label = "DEX", field = "dex" },
                        { label = "WIS", field = "wis" }, { label = "INT", field = "int" }, { label = "CHA", field = "cha" },
                    }, selectedItem, equippedItem)

                    ImGui.TableSetColumnIndex(2)
                    showStatComparisonColumn({
                        { label = "SvMagic", field = "svMagic" }, { label = "SvFire", field = "svFire" }, { label = "SvCold", field = "svCold" },
                        { label = "SvDisease", field = "svDisease" }, { label = "SvPoison", field = "svPoison" },
                        { label = "Attack", field = "attack" }, { label = "Haste", field = "haste", suffix = "%", },
                    }, selectedItem, equippedItem)

                    ImGui.EndTable()
                end
            end
        end

        ImGui.Separator()
        if ImGui.Button("Refresh") then
            local targetChar = inventoryUI.itemSuggestionsTarget
            local slotID = inventoryUI.itemSuggestionsSlot
            clearComparisonCache()
            Suggestions.clearStatsCache()
            itemSuggestionsCache.equippedItem = nil
            itemSuggestionsCache.lastPeerName = nil
            itemSuggestionsCache.lastSlotID = nil
            inventory_actor.request_all_inventories()
            inventoryUI.availableItems = Suggestions.getAvailableItemsForSlot(targetChar, slotID)
            inventoryUI.filteredItemsCache.lastFilterKey = ""  -- Invalidate cache
            inventoryUI.selectedComparisonItem = nil
            inventoryUI.selectedComparisonItemId = ""
        end
        ImGui.SameLine()
        if ImGui.Button("Clear Selection") then
            inventoryUI.selectedComparisonItem = nil
            inventoryUI.selectedComparisonItemId = ""
        end
        ImGui.SameLine()
        if ImGui.Button("Close") then
            inventoryUI.showItemSuggestions = false
            inventoryUI.selectedComparisonItem = nil
            inventoryUI.selectedComparisonItemId = ""
        end
    end

    -- CRITICAL: Always call ImGui.End() if ImGui.Begin() was called, regardless of return values
    ImGui.End()
end

function initiateProxyTrade(item, sourceChar, targetChar)
    printf("Initiating trade: %s from %s to %s", item.name, sourceChar, targetChar)

    local peerRequest = {
        name = item.name,
        to = targetChar,
        fromBank = item.bankslotid ~= nil,
        bagid = item.bagid,
        slotid = item.slotid,
        bankslotid = item.bankslotid,
    }

    inventory_actor.send_inventory_command(sourceChar, "proxy_give", { json.encode(peerRequest), })
    printf("Trade request sent: %s will give %s to %s", sourceChar, item.name, targetChar)
end

function initiateMultiItemTrade(targetChar)
    --printf("[DEBUG] initiateMultiItemTrade called for target: %s", tostring(targetChar))
    local tradableItems = {}
    local noDropItems = {}
    local sourceChar = nil
    local sourceCounts = {}

    for _, selectedData in pairs(inventoryUI.selectedItems) do
        local item = selectedData.item
        local itemSource = selectedData.source or inventoryUI.selectedPeer or extractCharacterName(mq.TLO.Me.Name())
        sourceCounts[itemSource] = (sourceCounts[itemSource] or 0) + 1

        if item.nodrop == 0 then
            table.insert(tradableItems, {
                item = item,
                source = itemSource,
            })
        else
            table.insert(noDropItems, item)
        end
    end

    local maxCount = 0
    for source, count in pairs(sourceCounts) do
        if count > maxCount then
            maxCount = count
            sourceChar = source
        end
    end
    if not sourceChar then
        sourceChar = inventoryUI.contextMenu.source or inventoryUI.selectedPeer or extractCharacterName(mq.TLO.Me.Name())
    end

    if #noDropItems > 0 then
        printf("Warning: %d selected items are No Drop and cannot be traded", #noDropItems)
    end

    if #tradableItems > 0 and sourceChar and targetChar then
        printf("Initiating multi-item trade: %d items from %s to %s", #tradableItems, sourceChar, targetChar)
        local itemsBySource = {}
        for _, tradableItem in ipairs(tradableItems) do
            local source = tradableItem.source
            if not itemsBySource[source] then
                itemsBySource[source] = {}
            end
            table.insert(itemsBySource[source], tradableItem.item)
        end

        for source, items in pairs(itemsBySource) do
            if #items > 0 then
                local batchRequest = {
                    target = targetChar,
                    items = {},
                }

                for _, item in ipairs(items) do
                    table.insert(batchRequest.items, {
                        name = item.name,
                        fromBank = item.bankslotid ~= nil,
                        bagid = item.bagid,
                        slotid = item.slotid,
                        bankslotid = item.bankslotid,
                    })
                end

                inventory_actor.send_inventory_command(source, "proxy_give_batch", { json.encode(batchRequest), })
                printf("Multi-trade request sent: %d items from %s to %s", #items, source, targetChar)
            end
        end
    else
        if #tradableItems == 0 then
            print("No tradable items selected")
        elseif not sourceChar then
            print("Cannot determine source character for trade")
        elseif not targetChar then
            print("No target character specified")
        end
    end

    clearItemSelection()
end

function renderMultiTradePanel()
    if not inventoryUI.showMultiTradePanel then return end

    ImGui.SetNextWindowSize(500, 400, ImGuiCond.Once)
    local isOpen, isShown = ImGui.Begin("Multi-Item Trade Panel", true, ImGuiWindowFlags.None)
    if not isOpen then inventoryUI.showMultiTradePanel = false end
    if isShown then
        local selectedCount = getSelectedItemCount()
        ImGui.Text(string.format("Selected Items: %d", selectedCount))
        ImGui.Separator()
        if ImGui.BeginChild("SelectedItemsList", 0, 250) then
            if selectedCount == 0 then
                ImGui.Text("No items selected")
            else
                if ImGui.BeginTable("SelectedItemsTable", 4, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg) then
                    ImGui.TableSetupColumn("Icon", ImGuiTableColumnFlags.WidthFixed, 30)
                    ImGui.TableSetupColumn("Item", ImGuiTableColumnFlags.WidthStretch)
                    ImGui.TableSetupColumn("Source", ImGuiTableColumnFlags.WidthFixed, 100)
                    ImGui.TableSetupColumn("Action", ImGuiTableColumnFlags.WidthFixed, 60)
                    ImGui.TableHeadersRow()

                    local itemsToRemove = {}
                    for key, selectedData in pairs(inventoryUI.selectedItems) do
                        local item = selectedData.item
                        local itemSource = selectedData.source or "Unknown"

                        ImGui.TableNextRow()

                        ImGui.TableNextColumn()
                        if item.icon and item.icon > 0 then
                            drawItemIcon(item.icon)
                        else
                            ImGui.Text("N/A")
                        end

                        ImGui.TableNextColumn()
                        ImGui.Text(item.name or "Unknown")
                        if item.nodrop == 1 then
                            ImGui.SameLine()
                            ImGui.TextColored(1, 0, 0, 1, "(No Drop)")
                        end

                        ImGui.TableNextColumn()
                        ImGui.Text(itemSource)

                        ImGui.TableNextColumn()
                        if ImGui.Button("Remove##" .. key) then
                            table.insert(itemsToRemove, key)
                        end
                    end

                    -- Remove items marked for removal
                    for _, key in ipairs(itemsToRemove) do
                        inventoryUI.selectedItems[key] = nil
                    end

                    ImGui.EndTable()
                end
            end
        end
        ImGui.EndChild()

        ImGui.Separator()

        -- Target selection
        ImGui.Text("Trade To:")
        ImGui.SameLine()
        if ImGui.BeginCombo("##MultiTradeTarget", inventoryUI.multiTradeTarget ~= "" and inventoryUI.multiTradeTarget or "Select Target") then
            local peers = peerCache[inventoryUI.selectedServer] or {}
            table.sort(peers, function(a, b)
                return (a.name or ""):lower() < (b.name or ""):lower()
            end)
            for _, peer in ipairs(peers) do
                -- Don't allow trading to any of the source characters
                local isSourceChar = false
                for _, selectedData in pairs(inventoryUI.selectedItems) do
                    if selectedData.source == peer.name then
                        isSourceChar = true
                        break
                    end
                end

                if not isSourceChar then
                    if ImGui.Selectable(peer.name, inventoryUI.multiTradeTarget == peer.name) then
                        inventoryUI.multiTradeTarget = peer.name
                    end
                end
            end
            ImGui.EndCombo()
        end

        ImGui.Separator()

        -- Action buttons
        if selectedCount > 0 and inventoryUI.multiTradeTarget ~= "" then
            if ImGui.Button("Execute Multi-Trade") then
                printf("[UI] Execute Multi-Trade for %s", inventoryUI.multiTradeTarget)
                initiateMultiItemTrade(inventoryUI.multiTradeTarget)
                inventoryUI.showMultiTradePanel = false
                inventoryUI.multiSelectMode = false
                clearItemSelection()
                clearItemSelection()
            end
            ImGui.SameLine()
        end

        if ImGui.Button("Clear All") then
            clearItemSelection()
        end
        ImGui.SameLine()
        if ImGui.Button("Close") then
            inventoryUI.showMultiTradePanel = false
            inventoryUI.multiSelectMode = false
            clearItemSelection()
            inventoryUI.multiSelectMode = false
            clearItemSelection()
        end
    end
    ImGui.End()
end

function renderMultiSelectIndicator()
    if inventoryUI.multiSelectMode then
        local selectedCount = getSelectedItemCount()
        inventoryUI.showMultiTradePanel = true
    end
end

if isEMU then
    function inventoryUI.drawBotInventoryWindow()
        if not inventoryUI.showBotInventory or not inventoryUI.selectedBotInventory then return end

        ImGui.SetNextWindowSize(ImVec2(600, 400), ImGuiCond.FirstUseEver)

        local isOpen, shouldShow = ImGui.Begin("Bot Inventory Viewer", true, ImGuiWindowFlags.None)

        if not isOpen then
            inventoryUI.showBotInventory = false
            inventoryUI.selectedBotInventory = nil
            ImGui.End()
            return
        end

        if shouldShow then
            ImGui.Text("Viewing bot: " .. (inventoryUI.selectedBotInventory.name or "Unknown"))

            ImGui.SameLine()
            local windowWidth = ImGui.GetWindowWidth()
            local buttonWidth = 60
            ImGui.SetCursorPosX(windowWidth - buttonWidth - 10)

            if ImGui.Button("Close") then
                inventoryUI.showBotInventory = false
                inventoryUI.selectedBotInventory = nil
                ImGui.End()
                return
            end

            ImGui.Separator()

            local equippedItems = {}
            if inventoryUI.selectedBotInventory.data and inventoryUI.selectedBotInventory.data.equipped then
                equippedItems = inventoryUI.selectedBotInventory.data.equipped
            end

            -- Updated table with Unequip column
            if ImGui.BeginTable("BotEquippedTable", 3, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.Resizable) then
                ImGui.TableSetupColumn("Slot", ImGuiTableColumnFlags.WidthFixed, 100)
                ImGui.TableSetupColumn("Item Name", ImGuiTableColumnFlags.WidthStretch)
                ImGui.TableSetupColumn("Action", ImGuiTableColumnFlags.WidthFixed, 80)
                ImGui.TableHeadersRow()

                for _, item in ipairs(equippedItems) do
                    ImGui.TableNextRow()

                    local uniqueId = string.format("bot_item_%s_%s",
                        inventoryUI.selectedBotInventory.name or "unknown",
                        item.slotid or "unknown")
                    ImGui.PushID(uniqueId)

                    local ok, err = pcall(function()
                        ImGui.TableNextColumn()
                        local slotName = getSlotNameFromID(item.slotid) or "Unknown"
                        ImGui.Text(slotName)

                        ImGui.TableNextColumn()
                        local itemName = item.name or "Unknown Item"
                        if ImGui.Selectable(itemName) then
                            local links = mq.ExtractLinks(item.itemlink)
                            if links and #links > 0 then
                                mq.ExecuteTextLink(links[1])
                            else
                                print(' No item link found in the database.')
                            end
                        end
                        if ImGui.IsItemHovered() then
                            ImGui.BeginTooltip()
                            ImGui.Text("Item: " .. itemName)
                            ImGui.Text("Slot ID: " .. tostring(item.slotid))
                            if item.itemlink and item.itemlink ~= "" then
                                ImGui.Text("Has Link: YES")
                            else
                                ImGui.Text("Has Link: NO")
                            end
                            if item.rawline then
                                ImGui.Text("Has Raw Line: YES")
                            else
                                ImGui.Text("Has Raw Line: NO")
                            end
                            ImGui.Text("Click to inspect item")
                            ImGui.EndTooltip()
                        end
                        -- New Action column with Unequip button
                        ImGui.TableNextColumn()
                        if ImGui.Button("Unequip##" .. uniqueId) then
                            if inventoryUI.selectedBotInventory and inventoryUI.selectedBotInventory.name and item.slotid then
                                -- Queue the unequip operation for processing in main thread
                                local botName = inventoryUI.selectedBotInventory.name
                                local slotId = item.slotid

                                -- Add to deferred tasks queue for main thread processing
                                table.insert(inventory_actor.deferred_tasks, function()
                                    local botSpawn = mq.TLO.Spawn(string.format("= %s", botName))
                                    if botSpawn.ID() and botSpawn.ID() > 0 then
                                        mq.cmdf("/target id %d", botSpawn.ID())
                                        printf("Targeting %s for unequip...", botName)

                                        -- Set up a targeting check task
                                        local targetCheckTask = function()
                                            if mq.TLO.Target.Name() == botName then
                                                bot_inventory.requestBotUnequip(botName, slotId)
                                                return true -- Task completed
                                            elseif mq.TLO.Target.ID() == 0 then
                                                mq.cmdf('/target "%s"', botName)
                                                return false
                                            elseif mq.TLO.Target.Name() ~= botName then
                                                print('Could not target bot')
                                                return true
                                            end
                                            return false -- Keep trying
                                        end

                                        -- Add targeting check with timeout
                                        local attempts = 0
                                        local maxAttempts = 10
                                        table.insert(inventory_actor.deferred_tasks, function()
                                            attempts = attempts + 1
                                            local completed = targetCheckTask()
                                            if not completed and attempts < maxAttempts then
                                                -- Re-queue the task to try again
                                                table.insert(inventory_actor.deferred_tasks, function()
                                                    attempts = attempts + 1
                                                    local completed = targetCheckTask()
                                                    if not completed and attempts < maxAttempts then
                                                        -- Keep trying...
                                                        table.insert(inventory_actor.deferred_tasks, function()
                                                            return targetCheckTask()
                                                        end)
                                                    elseif attempts >= maxAttempts then
                                                        print("Timeout targeting bot for unequip")
                                                    end
                                                end)
                                            end
                                        end)
                                    else
                                        print("Could not find bot spawn for unequip command")
                                    end
                                end)

                                printf("Queued unequip request for %s slot %s", botName, slotId)
                            end
                        end

                        if ImGui.IsItemHovered() then
                            ImGui.SetTooltip("Unequip this item from the bot")
                        end
                    end)

                    ImGui.PopID()

                    if not ok then
                        ImGui.TextColored(1, 0, 0, 1, "Error rendering item: " .. tostring(err))
                    end
                end
                ImGui.EndTable()
            end

            ImGui.Separator()
            if ImGui.Button("Refresh Inventory") then
                if inventoryUI.selectedBotInventory and inventoryUI.selectedBotInventory.name then
                    bot_inventory.requestBotInventory(inventoryUI.selectedBotInventory.name)
                    printf("Refreshing inventory for bot: %s", inventoryUI.selectedBotInventory.name)
                end
            end

            ImGui.SameLine()

            if ImGui.Button("Close Window") then
                inventoryUI.showBotInventory = false
                inventoryUI.selectedBotInventory = nil
            end

            -- Show stats
            ImGui.Spacing()
            ImGui.Text(string.format("Items: %d", #equippedItems))
            local withLinks = 0
            local withoutLinks = 0
            for _, item in ipairs(equippedItems) do
                if item.itemlink and item.itemlink ~= "" then
                    withLinks = withLinks + 1
                else
                    withoutLinks = withoutLinks + 1
                end
            end

            ImGui.SameLine()
            ImGui.Text(string.format("Links: %d/%d", withLinks, withLinks + withoutLinks))
        end
        ImGui.End()
    end
end
mq.imgui.init("InventoryWindow", function()
    if inventoryUI.showToggleButton then
        InventoryToggleButton()
    end
    if inventoryUI.visible then
        UI.render()
    end
end)

--------------------------------------------------------
--- Item Exchange Popup
--------------------------------------------------------

function renderItemExchange()
    inventoryUI.showGiveItemPanel = inventoryUI.showGiveItemPanel or false

    if inventoryUI.showGiveItemPanel then
        ImGui.SetNextWindowSize(400, 0, ImGuiCond.Once)
        local isOpen, isDrawn = ImGui.Begin("Give Item Panel", nil, ImGuiWindowFlags.AlwaysAutoResize)
        if isDrawn then
            ImGui.Text("Select an item and peer to give it to.")
            ImGui.Separator()

            inventoryUI.selectedGiveItem = inventoryUI.selectedGiveItem or ""
            local localItems = {}
            for _, bagItems in pairs(inventoryUI.inventoryData.bags or {}) do
                for _, item in ipairs(bagItems) do
                    table.insert(localItems, item.name)
                end
            end
            table.sort(localItems)

            ImGui.Text("Item:")
            ImGui.SameLine()
            if ImGui.BeginCombo("##GiveItemCombo", inventoryUI.selectedGiveItem ~= "" and inventoryUI.selectedGiveItem or "Select Item") then
                for _, itemName in ipairs(localItems) do
                    if ImGui.Selectable(itemName, inventoryUI.selectedGiveItem == itemName) then
                        inventoryUI.selectedGiveItem = itemName
                    end
                end
                ImGui.EndCombo()
            end

            inventoryUI.selectedGiveTarget = inventoryUI.selectedGiveTarget or ""
            ImGui.Text("To Peer:")
            ImGui.SameLine()
            if ImGui.BeginCombo("##GivePeerCombo", inventoryUI.selectedGiveTarget ~= "" and inventoryUI.selectedGiveTarget or "Select Peer") then
                local peers = peerCache[inventoryUI.selectedServer] or {}
                table.sort(peers, function(a, b)
                    return (a.name or ""):lower() < (b.name or ""):lower()
                end)
                for i, peer in ipairs(peers) do
                    local isSelected = inventoryUI.selectedGiveTarget == peer.name
                    ImGui.PushID("give_peer_" .. peer.name)
                    if ImGui.Selectable(peer.name, isSelected) then
                        inventoryUI.selectedGiveTarget = peer.name
                    end
                    if isSelected then
                        ImGui.SetItemDefaultFocus()
                    end
                    ImGui.PopID()
                end
                ImGui.EndCombo()
            end

            ImGui.Separator()
            if inventoryUI.showGiveItemPanel and ImGui.Button("Give") then
                if inventoryUI.selectedGiveItem ~= "" and inventoryUI.selectedGiveTarget ~= "" then
                    local peerRequest = {
                        name = inventoryUI.selectedGiveItem,
                        to = inventoryUI.selectedGiveTarget,
                        fromBank = false,
                    }

                    inventory_actor.send_inventory_command(inventoryUI.selectedGiveSource, "proxy_give",
                        { json.encode(peerRequest), })

                    printf("Requesting %s to give %s to %s",
                        inventoryUI.selectedGiveSource,
                        inventoryUI.selectedGiveItem,
                        inventoryUI.selectedGiveTarget)

                    inventoryUI.showGiveItemPanel = false
                else
                    mq.cmd("/popcustom 5 Please select an item and a peer first.")
                end
            end
            ImGui.SameLine()
            if ImGui.Button("Close Panel") then
                inventoryUI.showGiveItemPanel = false
            end
        end
        if not isOpen then
            inventoryUI.showGiveItemPanel = false
            isDrawn = false
        end
        ImGui.End()
    end
end

mq.imgui.init("InventoryWindow", function()
    if inventoryUI.showToggleButton then
        InventoryToggleButton()
    end
    if inventoryUI.visible then
        inventoryUI.render()
    end
end)

local helpInfo = {
    { binding = "/ezinventory_ui",              description = "Toggles the visibility of the inventory window." },
    { binding = "/ezinventory_help",            description = "Displays this help information." },
    { binding = "/ezinventory_stats_mode",      description = "Changes stats loading mode: minimal/selective/full" },
    { binding = "/ezinventory_toggle_basic",    description = "Toggles basic stats loading on/off" },
    { binding = "/ezinventory_toggle_detailed", description = "Toggles detailed stats loading on/off" },
}

local function displayHelp()
    print("=== Inventory Script Help ===")
    for _, info in ipairs(helpInfo) do
        printf("%s: %s", info.binding, info.description)
    end
    print("============================")
end

mq.bind("/ezinventory_help", function()
    displayHelp()
end)

mq.bind("/ezinventory_ui", function()
    inventoryUI.visible = not inventoryUI.visible
end)

mq.bind("/ezinventory_cmd", function(peer, command, ...)
    if not peer or not command then
        print("Usage: /ezinventory_cmd <peer> <command> [args...]")
        return
    end
    local args = { ..., }
    inventory_actor.send_inventory_command(peer, command, args)
end)

mq.bind("/ezinventory_stats_mode", function(mode)
    if not mode or mode == "" then
        print("Usage: /ezinventory_stats_mode <minimal|selective|full>")
        print("Current mode: " .. (Settings.statsLoadingMode or "selective"))
        return
    end

    local validModes = { minimal = true, selective = true, full = true }
    if validModes[mode] then
        Settings.statsLoadingMode = mode
        OnStatsLoadingModeChanged(mode)
    else
        print("Invalid mode. Use: minimal, selective, or full")
    end
end)

mq.bind("/ezinventory_toggle_basic", function()
    Settings.loadBasicStats = not Settings.loadBasicStats
    UpdateInventoryActorConfig()
    print(string.format("[EZInventory] Basic stats loading: %s", Settings.loadBasicStats and "ENABLED" or "DISABLED"))
end)

mq.bind("/ezinventory_toggle_detailed", function()
    Settings.loadDetailedStats = not Settings.loadDetailedStats
    UpdateInventoryActorConfig()
    print(string.format("[EZInventory] Detailed stats loading: %s",
        Settings.loadDetailedStats and "ENABLED" or "DISABLED"))
end)

if isEMU then
    function inventoryUI.toggleBotInventoryWindow()
        inventoryUI.showBotInventory = not inventoryUI.showBotInventory
        if not inventoryUI.showBotInventory then
            inventoryUI.selectedBotInventory = nil
        end
    end
end

local function main()
    displayHelp()

    local isForeground = mq.TLO.EverQuest.Foreground()

    inventoryUI.visible = isForeground

    if not inventory_actor.init() then
        print("\ar[EZInventory] Failed to initialize inventory actor\ax")
        return
    end

    if isEMU and bot_inventory then
        if not bot_inventory.init() then
            print("\ar[EZInventory] Failed to initialize bot inventory system\ax")
        else
            print("\ag[EZInventory] Bot inventory system initialized\ax")
        end
    end

    UpdateInventoryActorConfig()

    mq.delay(200)
    if isForeground then
        local broadcast_name = _G.EZINV_BROADCAST_NAME or "EZInventory"
        if mq.TLO.Plugin("MQ2Mono").IsLoaded() then
            mq.cmdf("/e3bca /lua run %s", broadcast_name)
            print("Broadcasting inventory startup via MQ2Mono to all connected clients...")
        elseif mq.TLO.Plugin("MQ2DanNet").IsLoaded() then
            mq.cmdf("/dgaexecute /lua run %s", broadcast_name)
            print("Broadcasting inventory startup via DanNet to all connected clients...")
        elseif mq.TLO.Plugin("MQ2EQBC").IsLoaded() and mq.TLO.EQBC.Connected() then
            mq.cmdf("/bca //lua run %s", broadcast_name)
            print("Broadcasting inventory startup via EQBC to all connected clients...")
        else
            print("\ar[EZInventory] Warning: Neither DanNet nor EQBC is available for broadcasting\ax")
        end
    end

    mq.delay(500)
    inventory_actor.request_all_inventories()

    local myName = extractCharacterName(mq.TLO.Me.Name())
    inventoryUI.selectedPeer = myName
    mq.delay(200)
    local selfPeer = {
        name = myName,
        server = server,
        isMailbox = true,
        data = inventory_actor.gather_inventory(),
    }
    loadInventoryData(selfPeer)
    inventoryUI.isLoadingData = false

    while true do
        mq.doevents()
        if isEMU and bot_inventory then
            bot_inventory.process()
        end

        local currentTime = os.time()
        if currentTime - inventoryUI.lastPublishTime > inventoryUI.PUBLISH_INTERVAL then
            inventory_actor.publish_inventory()
            inventoryUI.lastPublishTime = currentTime
        end

        updatePeerList()

        inventory_actor.process_pending_requests()

        -- Auto-exchange is now handled directly after successful trades

        if #inventory_actor.deferred_tasks > 0 then
            local task = table.remove(inventory_actor.deferred_tasks, 1)
            local ok, err = pcall(task)
            if not ok then
                printf("[EZInventory ERROR] Deferred task failed: %s", tostring(err))
            end
        end
        mq.delay(100)
    end
end

main()

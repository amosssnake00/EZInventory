local ImGui = require("ImGui")
local icons = require("mq.icons")
local M = {}

M.inventoryUI = {
    visible                       = true,
    showToggleButton              = true,
    selectedPeer                  = mq.TLO.Me.Name(),
    peers                         = {},
    inventoryData                 = { equipped = {}, bags = {}, bank = {}, },
    expandBags                    = false,
    bagOpen                       = {},
    showAug1                      = true,
    showAug2                      = true,
    showAug3                      = true,
    showAug4                      = false,
    showAug5                      = false,
    showAug6                      = false,
    showAC                        = false,
    showHP                        = false,
    showMana                      = false,
    showClicky                    = false,
    comparisonShowSvMagic         = false,
    comparisonShowSvFire          = false,
    comparisonShowSvCold          = false,
    comparisonShowSvDisease       = false,
    comparisonShowSvPoison        = false,
    comparisonShowFocusEffects    = false,
    comparisonShowMod2s           = false,
    comparisonShowClickies        = false,
    windowLocked                  = false,
    equipView                     = "table",
    selectedSlotID                = nil,
    selectedSlotName              = nil,
    compareResults                = {},
    enableHover                   = false,
    needsRefresh                  = false,
    bagsView                      = "table",
    PUBLISH_INTERVAL              = 30,
    lastPublishTime               = 0,
    contextMenu                   = { visible = false, item = nil, source = nil, x = 0, y = 0, peers = {}, selectedPeer = nil, },
    multiSelectMode               = false,
    selectedItems                 = {},
    showMultiTradePanel           = false,
    multiTradeTarget              = "",
    showItemSuggestions           = false,
    itemSuggestionsTarget         = "",
    itemSuggestionsSlot           = nil,
    itemSuggestionsSlotName       = "",
    availableItems                = {},
    filteredItemsCache            = { items = {}, lastFilterKey = "" },
    selectedComparisonItemId      = "",
    selectedComparisonItem        = nil,
    itemSuggestionsSourceFilter   = "All",
    itemSuggestionsLocationFilter = "All",
    isLoadingData                 = true,
    pendingStatsRequests          = {},
    statsRequestTimeout           = 5,
    isLoadingComparison           = false,
    comparisonError               = nil,
    showBotInventory              = false,
    selectedBotInventory          = nil,
    loadBasicStats                = true,
    loadDetailedStats             = false,
    enableStatsFiltering          = true,
    autoRefreshInventory          = true,
    statsLoadingMode              = "minimal",
}

function M.render()
    if not M.inventoryUI.visible then return end

    local windowFlags = ImGuiWindowFlags.None
    if M.inventoryUI.windowLocked then
        windowFlags = windowFlags + ImGuiWindowFlags.NoMove + ImGuiWindowFlags.NoResize
    end

    local open, show = ImGui.Begin("Inventory Window##EzInventory", true, windowFlags)
    if not open then
        M.inventoryUI.visible = false
        show = false
    end
    if show then
        M.inventoryUI.selectedServer = M.inventoryUI.selectedServer or server
        ImGui.Text("Select Server:")
        ImGui.SameLine()
        ImGui.SetNextItemWidth(150)
        if ImGui.BeginCombo("##ServerCombo", M.inventoryUI.selectedServer or "None") then
            local serverList = {}
            for srv, _ in pairs(M.inventoryUI.servers) do
                table.insert(serverList, srv)
            end
            table.sort(serverList)
            for i, srv in ipairs(serverList) do
                ImGui.PushID(string.format("server_%s_%d", srv, i))
                if ImGui.Selectable(srv, M.inventoryUI.selectedServer == srv) then
                    M.inventoryUI.selectedServer = srv
                    local validPeer = false
                    for _, peer in ipairs(M.inventoryUI.servers[srv] or {}) do
                        if peer.name == M.inventoryUI.selectedPeer then
                            validPeer = true
                            break
                        end
                    end
                    if not validPeer then
                        M.inventoryUI.selectedPeer = nil
                    end
                end
                if M.inventoryUI.selectedServer == srv then
                    ImGui.SetItemDefaultFocus()
                end
                ImGui.PopID()
            end
            ImGui.EndCombo()
        end
        ImGui.SameLine()
        ImGui.Text("Select Peer:")
        ImGui.SameLine()
        ImGui.SetNextItemWidth(350)
        refreshPeerCache()
        local displayPeer = M.inventoryUI.selectedPeer or "Select Peer"
        if M.inventoryUI.selectedServer and ImGui.BeginCombo("##PeerCombo", displayPeer) then
            local peers = peerCache[M.inventoryUI.selectedServer] or {}
            local botPeers = {}
            local regularPeers = {}
            for _, invData in pairs(inventory_actor.peer_inventories) do
                if invData.server == M.inventoryUI.selectedServer then
                    table.insert(regularPeers, {
                        name = invData.name or "Unknown",
                        server = invData.server,
                        isMailbox = true,
                        isBotCharacter = false,
                        data = invData,
                    })
                end
            end
            if bot_inventory ~= nil then
                for botName, botData in pairs(bot_inventory.bot_inventories or {}) do
                    table.insert(botPeers, {
                        name = botName,
                        server = server,
                        isMailbox = false,
                        isBotCharacter = true,
                        data = botData,
                    })
                end
            end
            table.sort(regularPeers, function(a, b)
                return (a.name or ""):lower() < (b.name or ""):lower()
            end)
            table.sort(botPeers, function(a, b)
                return (a.name or ""):lower() < (b.name or ""):lower()
            end)
            if #regularPeers > 0 then
                ImGui.TextColored(0.7, 0.7, 1.0, 1.0, "Players:")
                for i, peer in ipairs(regularPeers) do
                    ImGui.PushID(string.format("peer_%s_%s_%d", peer.name, peer.server, i))
                    local isSelected = M.inventoryUI.selectedPeer == peer.name
                    if ImGui.Selectable("  " .. peer.name, isSelected) then
                        M.inventoryUI.selectedPeer = peer.name
                        loadInventoryData(peer)

                        -- If there's a selected slot, refresh available items for the new character
                        if M.inventoryUI.selectedSlotID and M.inventoryUI.showItemSuggestions then
                            M.inventoryUI.availableItems = Suggestions.getAvailableItemsForSlot(
                                peer.name, M.inventoryUI.selectedSlotID)
                            M.inventoryUI.filteredItemsCache.lastFilterKey = ""  -- Invalidate cache
                            M.inventoryUI.itemSuggestionsTarget = peer.name
                            M.inventoryUI.itemSuggestionsSlotName = M.inventoryUI.selectedSlotName or "Unknown Slot"
                        end
                    end
                    if isSelected then
                        ImGui.SetItemDefaultFocus()
                    end
                    ImGui.PopID()
                end
            end
            ImGui.EndCombo()
        end
        ImGui.SameLine()
        if ImGui.Button("Give Item") then
            M.inventoryUI.showGiveItemPanel = not M.inventoryUI.showGiveItemPanel
        end
        local cursorPosX = ImGui.GetCursorPosX()
        local iconSpacing = 10
        local iconSize = 22
        local totalIconWidth = (iconSize + iconSpacing) * 5 + 75
        local rightAlignX = ImGui.GetWindowWidth() - totalIconWidth - 10
        ImGui.SameLine(rightAlignX)
        local floatIcon = M.inventoryUI.showToggleButton and icons.FA_EYE or icons.FA_EYE_SLASH
        local eyeColor = M.inventoryUI.showToggleButton and ImVec4(0.2, 0.6, 0.8, 1.0) or ImVec4(0.6, 0.6, 0.6, 1.0)
        local eyeHoverColor = M.inventoryUI.showToggleButton and ImVec4(0.4, 0.8, 1.0, 1.0) or ImVec4(0.8, 0.8, 0.8, 1.0)
        local eyeActiveColor = M.inventoryUI.showToggleButton and ImVec4(0.1, 0.4, 0.6, 1.0) or ImVec4(0.4, 0.4, 0.4, 1.0)
        ImGui.PushStyleColor(ImGuiCol.Button, eyeColor)
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, eyeHoverColor)
        ImGui.PushStyleColor(ImGuiCol.ButtonActive, eyeActiveColor)
        ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, 6.0)
        if ImGui.Button(floatIcon, iconSize, iconSize) then
            M.inventoryUI.showToggleButton = not M.inventoryUI.showToggleButton
        end
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip(M.inventoryUI.showToggleButton and "Hide Floating Button" or "Show Floating Button")
        end
        ImGui.PopStyleVar()
        ImGui.PopStyleColor(3)
        ImGui.SameLine()
        ImGui.PushStyleColor(ImGuiCol.Button, ImVec4(0.2, 0.5, 0.8, 1.0))
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, ImVec4(0.4, 0.7, 1.0, 1.0))
        ImGui.PushStyleColor(ImGuiCol.ButtonActive, ImVec4(0.1, 0.3, 0.6, 1.0))
        ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, 6.0)
        if ImGui.Button("Save Config") then
            SaveConfigWithStatsUpdate()
        end
        if ImGui.IsItemHovered() then
            ImGui.BeginTooltip()
            ImGui.Text("Save visible column settings for this character.")
            ImGui.EndTooltip()
        end
        ImGui.PopStyleVar()
        ImGui.PopStyleColor(3)
        ImGui.SameLine()
        local lockIcon = M.inventoryUI.windowLocked and icons.FA_LOCK or icons.FA_UNLOCK
        local lockColor = M.inventoryUI.windowLocked and ImVec4(0.8, 0.6, 0.2, 1.0) or ImVec4(0.6, 0.6, 0.6, 1.0)
        local lockHoverColor = M.inventoryUI.windowLocked and ImVec4(1.0, 0.8, 0.4, 1.0) or ImVec4(0.8, 0.8, 0.8, 1.0)
        local lockActiveColor = M.inventoryUI.windowLocked and ImVec4(0.6, 0.4, 0.1, 1.0) or ImVec4(0.4, 0.4, 0.4, 1.0)
        ImGui.PushStyleColor(ImGuiCol.Button, lockColor)
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, lockHoverColor)
        ImGui.PushStyleColor(ImGuiCol.ButtonActive, lockActiveColor)
        ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, 6.0)
        if ImGui.Button(lockIcon, iconSize, iconSize) then
            M.inventoryUI.windowLocked = not M.inventoryUI.windowLocked
        end
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip(M.inventoryUI.windowLocked and "Unlock window" or "Lock window")
        end
        ImGui.PopStyleVar()
        ImGui.PopStyleColor(3)
        ImGui.SameLine()
        ImGui.PushStyleColor(ImGuiCol.Button, ImVec4(0.2, 0.8, 0.2, 1.0))
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, ImVec4(0.4, 1.0, 0.4, 1.0))
        ImGui.PushStyleColor(ImGuiCol.ButtonActive, ImVec4(0.1, 0.6, 0.1, 1.0))
        ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, 6.0)
        if ImGui.Button("Close") then
            M.inventoryUI.visible = false
        end
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip("Minimizes the UI")
        end
        ImGui.PopStyleVar()
        ImGui.PopStyleColor(3)
        ImGui.SameLine()
        ImGui.PushStyleColor(ImGuiCol.Button, ImVec4(0.8, 0.2, 0.2, 1.0))
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, ImVec4(1.0, 0.4, 0.4, 1.0))
        ImGui.PushStyleColor(ImGuiCol.ButtonActive, ImVec4(0.6, 0.1, 0.1, 1.0))
        ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, 6.0)
        if ImGui.Button("Exit") then
            mq.exit()
        end
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip("Exits the Script On This Screen")
        end
        ImGui.PopStyleVar()
        ImGui.PopStyleColor(3)
        ImGui.Separator()
        ImGui.Text("Search Items:")
        ImGui.SameLine()
        searchText = ImGui.InputText("##Search", searchText or "")
        ImGui.SameLine()
        if ImGui.Button("Clear") then
            searchText = ""
        end
        ImGui.Separator()
        local matchingBags = {}
        local function matchesSearch(item)
            if not searchText or searchText == "" then
                return true
            end
            local searchTerm = searchText:lower()
            local itemName = (item.name or ""):lower()
            if itemName:find(searchTerm) then
                return true
            end
            for i = 1, 6 do
                local augField = "aug" .. i .. "Name"
                if item[augField] and item[augField] ~= "" then
                    local augName = item[augField]:lower()
                    if augName:find(searchTerm) then
                        return true
                    end
                end
            end
            return false
        end
        renderMultiSelectIndicator()
        ------------------------------
        --- @tag Inventory UI
        --- @category UI.Equipped
        -- Equipped Items Section
        ------------------------------
        local avail = ImGui.GetContentRegionAvail()
        ImGui.BeginChild("TabbedContentRegion", 0, 0, ImGuiChildFlags.Border)
        if ImGui.BeginTabBar("InventoryTabs", ImGuiTabBarFlags.Reorderable) then
            if ImGui.BeginTabItem("Equipped") then
                if ImGui.BeginTabBar("EquippedViewTabs", ImGuiTabBarFlags.Reorderable) then
                    if ImGui.BeginTabItem("Table View") then
                        M.inventoryUI.equipView = "table"
                        if ImGui.BeginChild("EquippedScrollRegion", 0, 0) then
                            ImGui.Text("Show Columns:")
                            ImGui.SameLine()
                            M.inventoryUI.showAug1 = ImGui.Checkbox("Aug 1", M.inventoryUI.showAug1)
                            ImGui.SameLine()
                            M.inventoryUI.showAug2 = ImGui.Checkbox("Aug 2", M.inventoryUI.showAug2)
                            ImGui.SameLine()
                            M.inventoryUI.showAug3 = ImGui.Checkbox("Aug 3", M.inventoryUI.showAug3)
                            ImGui.SameLine()
                            M.inventoryUI.showAug4 = ImGui.Checkbox("Aug 4", M.inventoryUI.showAug4)
                            ImGui.SameLine()
                            M.inventoryUI.showAug5 = ImGui.Checkbox("Aug 5", M.inventoryUI.showAug5)
                            ImGui.SameLine()
                            M.inventoryUI.showAug6 = ImGui.Checkbox("Aug 6", M.inventoryUI.showAug6)
                            ImGui.SameLine()
                            M.inventoryUI.showAC = ImGui.Checkbox("AC", M.inventoryUI.showAC)
                            ImGui.SameLine()
                            M.inventoryUI.showHP = ImGui.Checkbox("HP", M.inventoryUI.showHP)
                            ImGui.SameLine()
                            M.inventoryUI.showMana = ImGui.Checkbox("Mana", M.inventoryUI.showMana)
                            ImGui.SameLine()
                            M.inventoryUI.showClicky = ImGui.Checkbox("Clicky", M.inventoryUI.showClicky)
                            -- Base visible columns
                            local numColumns = 3 -- Slot Name, Icon, Item Name

                            -- Count visible augs
                            local visibleAugs = 0
                            local augVisibility = {
                                M.inventoryUI.showAug1,
                                M.inventoryUI.showAug2,
                                M.inventoryUI.showAug3,
                                M.inventoryUI.showAug4,
                                M.inventoryUI.showAug5,
                                M.inventoryUI.showAug6,
                            }
                            for _, isVisible in ipairs(augVisibility) do
                                if isVisible then
                                    visibleAugs = visibleAugs + 1
                                end
                            end
                            numColumns = numColumns + visibleAugs

                            -- Count extra stat columns
                            local extraStats = {
                                M.inventoryUI.showAC,
                                M.inventoryUI.showHP,
                                M.inventoryUI.showMana,
                                M.inventoryUI.showClicky,
                            }
                            local visibleStats = 0
                            for _, isVisible in ipairs(extraStats) do
                                if isVisible then
                                    visibleStats = visibleStats + 1
                                end
                            end
                            numColumns = numColumns + visibleStats

                            -- Width calculation
                            local availableWidth = ImGui.GetWindowContentRegionWidth()
                            local slotNameWidth = 100
                            local iconWidth = 30
                            local itemWidth = 150
                            local statsWidth = visibleStats * 50 -- 50px per stat column
                            local remainingForAugs = availableWidth - slotNameWidth - iconWidth - itemWidth - statsWidth

                            local augWidth = 0
                            if visibleAugs > 0 then
                                augWidth = math.max(80, remainingForAugs / visibleAugs)
                            end
                            if M.inventoryUI.isLoadingData then
                                renderLoadingScreen("Loading Inventory Data", "Scanning items",
                                    "This may take a moment for large inventories")
                            else
                                if ImGui.BeginTable("EquippedTable", numColumns, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.Resizable + ImGuiTableFlags.SizingStretchProp) then
                                    ImGui.TableSetupColumn("Slot", ImGuiTableColumnFlags.WidthFixed, slotNameWidth)
                                    ImGui.TableSetupColumn("Icon", ImGuiTableColumnFlags.WidthFixed, iconWidth)
                                    ImGui.TableSetupColumn("Item", ImGuiTableColumnFlags.WidthFixed, itemWidth)
                                    for i = 1, 6 do
                                        if augVisibility[i] then
                                            ImGui.TableSetupColumn("Aug " .. i, ImGuiTableColumnFlags.WidthStretch, 1.0)
                                        end
                                    end
                                    if M.inventoryUI.showAC then
                                        ImGui.TableSetupColumn("AC", ImGuiTableColumnFlags.WidthFixed, 50)
                                    end
                                    if M.inventoryUI.showHP then
                                        ImGui.TableSetupColumn("HP", ImGuiTableColumnFlags.WidthFixed, 60)
                                    end
                                    if M.inventoryUI.showMana then
                                        ImGui.TableSetupColumn("Mana", ImGuiTableColumnFlags.WidthFixed, 60)
                                    end
                                    if M.inventoryUI.showClicky then
                                        ImGui.TableSetupColumn("Clicky", ImGuiTableColumnFlags.WidthStretch, 1.0)
                                    end
                                    ImGui.TableHeadersRow()
                                    local function renderEquippedTableRow(item, augVisibility)
                                        ImGui.TableNextColumn()
                                        local slotName = getSlotNameFromID(item.slotid) or "Unknown"
                                        ImGui.Text(slotName)
                                        ImGui.TableNextColumn()
                                        if item.icon and item.icon ~= 0 then
                                            drawItemIcon(item.icon)
                                        else
                                            ImGui.Text("N/A")
                                        end
                                        ImGui.TableNextColumn()
                                        if ImGui.Selectable(item.name) then
                                            local links = mq.ExtractLinks(item.itemlink)
                                            if links and #links > 0 then
                                                mq.ExecuteTextLink(links[1])
                                            else
                                                print(' No item link found in the database.')
                                            end
                                        end
                                        -- Aug columns
                                        for i = 1, 6 do
                                            if augVisibility[i] then
                                                ImGui.TableNextColumn()
                                                local augField = "aug" .. i .. "Name"
                                                local augLinkField = "aug" .. i .. "link"
                                                if item[augField] and item[augField] ~= "" then
                                                    if ImGui.Selectable(string.format("%s", item[augField])) then
                                                        local links = mq.ExtractLinks(item[augLinkField])
                                                        if links and #links > 0 then
                                                            mq.ExecuteTextLink(links[1])
                                                        else
                                                            print(' No aug link found in the database.')
                                                        end
                                                    end
                                                end
                                            end
                                        end
                                        if M.inventoryUI.showAC then
                                            ImGui.TableNextColumn()
                                            ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.85, 0.2, 0.7)
                                            ImGui.Text(tostring(item.ac or "--"))
                                            ImGui.PopStyleColor()
                                        end
                                        if M.inventoryUI.showHP then
                                            ImGui.TableNextColumn()
                                            ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.2, 0.2, 0.7)
                                            ImGui.Text(tostring(item.hp or "--"))
                                            ImGui.PopStyleColor()
                                        end
                                        if M.inventoryUI.showMana then
                                            ImGui.TableNextColumn()
                                            ImGui.PushStyleColor(ImGuiCol.Text, 0.4, 0.6, 1.0, 0.7)
                                            ImGui.Text(tostring(item.mana or "--"))
                                            ImGui.PopStyleColor()
                                        end
                                        if M.inventoryUI.showClicky then
                                            ImGui.TableNextColumn()
                                            ImGui.PushStyleColor(ImGuiCol.Text, 0.3, 1.0, 0.3, 0.7)
                                            ImGui.Text(item.clickySpell or "None")
                                            ImGui.PopStyleColor()
                                        end
                                    end
                                    local sortedEquippedItems = {}
                                    for _, item in ipairs(M.inventoryUI.inventoryData.equipped) do
                                        if matchesSearch(item) then
                                            table.insert(sortedEquippedItems, item)
                                        end
                                    end
                                    table.sort(sortedEquippedItems, function(a, b)
                                        local slotNameA = getSlotNameFromID(a.slotid) or "Unknown"
                                        local slotNameB = getSlotNameFromID(b.slotid) or "Unknown"
                                        return slotNameA < slotNameB
                                    end)
                                    for _, item in ipairs(sortedEquippedItems) do
                                        ImGui.TableNextRow()
                                        ImGui.PushID(item.name or "unknown_item")
                                        local ok, err = pcall(renderEquippedTableRow, item, augVisibility)
                                        ImGui.PopID()
                                        if not ok then
                                            printf("Error rendering item row: %s", err)
                                        end
                                    end
                                end
                                ImGui.EndTable()
                            end
                        end
                        ImGui.EndChild()
                        ImGui.EndTabItem()
                    end
                    if M.inventoryUI.isLoadingData then
                        renderLoadingScreen("Loading Inventory Data", "Scanning items",
                            "This may take a moment for large inventories")
                    else
                        -- Visual Layout Tab
                        if ImGui.BeginTabItem("Visual") then
                            ImGui.Dummy(235, 0)
                            local armorTypes = { "All", "Plate", "Chain", "Cloth", "Leather", }
                            M.inventoryUI.armorTypeFilter = M.inventoryUI.armorTypeFilter or "All"

                            ImGui.SameLine()
                            ImGui.Text("Armor Type:")
                            ImGui.SameLine()
                            ImGui.SetNextItemWidth(100)
                            if ImGui.BeginCombo("##ArmorTypeFilter", M.inventoryUI.armorTypeFilter) then
                                for _, armorType in ipairs(armorTypes) do
                                    if ImGui.Selectable(armorType, M.inventoryUI.armorTypeFilter == armorType) then
                                        M.inventoryUI.armorTypeFilter = armorType
                                    end
                                end
                                ImGui.EndCombo()
                            end
                            ImGui.Separator()
                            local slotLayout = {
                                { 1,  2,  3,  4, },  -- Row 1: Left Ear, Face, Neck, Shoulders
                                { 17, "", "", 5, },  -- Row 2: Primary, Empty, Empty, Ear 1
                                { 7,  "", "", 8, },  -- Row 3: Arms, Empty, Empty, Wrist 1
                                { 20, "", "", 6, },  -- Row 4: Range, Empty, Empty, Ear 2
                                { 9,  "", "", 10, }, -- Row 5: Back, Empty, Empty, Wrist 2
                                { 18, 12, 0,  19, }, -- Row 6: Secondary, Chest, Ammo, Waist
                                { "", 15, 16, 21, }, -- Row 7: Empty, Legs, Feet, Charm
                                { 13, 14, 11, 22, }, -- Row 8: Finger 1, Finger 2, Hands, Power Source
                            }
                            local equippedItems = {}
                            for _, item in ipairs(M.inventoryUI.inventoryData.equipped) do
                                equippedItems[item.slotid] = item
                            end
                            M.inventoryUI.selectedItem = M.inventoryUI.selectedItem or nil
                            M.inventoryUI.hoverStates = {}
                            M.inventoryUI.openItemWindow = M.inventoryUI.openItemWindow or nil
                            local hoveringAnyItem = false
                            local function calculateEquippedTableWidth()
                                local contentWidth = 4 * 50
                                local borderWidth = 1
                                local borders = borderWidth * (4 + 1)
                                local padding = 30
                                local extraMargin = 8

                                return contentWidth + borders + padding + extraMargin
                            end
                            ImGui.Columns(2, "EquippedColumns", true)
                            local equippedTableWidth = calculateEquippedTableWidth()
                            ImGui.SetColumnWidth(0, equippedTableWidth)
                            local ok, err = pcall(function()
                                if ImGui.BeginTable("EquippedTable", 4, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.SizingFixedFit) then
                                    ImGui.TableSetupColumn(" ", ImGuiTableColumnFlags.WidthFixed, 45)
                                    ImGui.TableSetupColumn(" ", ImGuiTableColumnFlags.WidthFixed, 45)
                                    ImGui.TableSetupColumn(" ", ImGuiTableColumnFlags.WidthFixed, 45)
                                    ImGui.TableSetupColumn(" ", ImGuiTableColumnFlags.WidthFixed, 45)
                                    ImGui.TableHeadersRow()
                                    local function renderEquippedSlot(slotID, item, slotName)
                                        local slotButtonID = "slot_" .. tostring(slotID)
                                        if item and item.icon and item.icon ~= 0 then
                                            local clicked = ImGui.InvisibleButton("##" .. slotButtonID, 45, 45)
                                            local rightClicked = ImGui.IsItemClicked(ImGuiMouseButton.Right)
                                            local buttonMinX, buttonMinY = ImGui.GetItemRectMin()
                                            ImGui.SetCursorScreenPos(buttonMinX, buttonMinY)
                                            drawItemIcon(item.icon, 40, 40)
                                            if clicked then
                                                if mq.TLO.Window("ItemDisplayWindow").Open() then
                                                    mq.TLO.Window("ItemDisplayWindow").DoClose()
                                                    M.inventoryUI.openItemWindow = nil
                                                end
                                                M.inventoryUI.selectedSlotID = slotID
                                                M.inventoryUI.selectedSlotName = slotName
                                                M.inventoryUI.compareResults = compareSlotAcrossPeers(slotID)
                                            end
                                            if rightClicked then
                                                local targetChar = M.inventoryUI.selectedPeer or extractCharacterName(mq.TLO.Me.Name())
                                                M.inventoryUI.availableItems = Suggestions.getAvailableItemsForSlot(
                                                    targetChar, slotID)
                                                M.inventoryUI.filteredItemsCache.lastFilterKey = ""  -- Invalidate cache
                                                M.inventoryUI.showItemSuggestions = true
                                                M.inventoryUI.itemSuggestionsTarget = targetChar
                                                M.inventoryUI.itemSuggestionsSlot = slotID
                                                M.inventoryUI.itemSuggestionsSlotName = slotName
                                                M.inventoryUI.selectedComparisonItemId = ""
                                                M.inventoryUI.selectedComparisonItem = nil
                                            end
                                            if ImGui.IsItemHovered() then
                                                ImGui.BeginTooltip()
                                                ImGui.Text(item.name or "Unknown Item")
                                                ImGui.Text("Left-click: Compare across characters")
                                                ImGui.Text("Right-click: Find alternative items")
                                                ImGui.EndTooltip()
                                            end
                                        else
                                            local clicked = ImGui.InvisibleButton("##" .. slotButtonID, 45, 45)
                                            local rightClicked = ImGui.IsItemClicked(ImGuiMouseButton.Right)
                                            local buttonMinX, buttonMinY = ImGui.GetItemRectMin()
                                            local buttonMaxX, buttonMaxY = ImGui.GetItemRectMax()
                                            local buttonWidth = buttonMaxX - buttonMinX
                                            local buttonHeight = buttonMaxY - buttonMinY

                                            local textSize = ImGui.CalcTextSize(slotName)
                                            local textX = buttonMinX + (buttonWidth - textSize) * 0.5
                                            local textY = buttonMinY + (buttonHeight - ImGui.GetTextLineHeight()) * 0.5
                                            ImGui.SetCursorScreenPos(textX, textY)
                                            ImGui.PushStyleColor(ImGuiCol.Text, 0.7, 0.7, 0.7, 1.0)
                                            ImGui.Text(slotName)
                                            ImGui.PopStyleColor()
                                            if clicked then
                                                if mq.TLO.Window("ItemDisplayWindow").Open() then
                                                    mq.TLO.Window("ItemDisplayWindow").DoClose()
                                                    M.inventoryUI.openItemWindow = nil
                                                end
                                                M.inventoryUI.selectedSlotID = slotID
                                                M.inventoryUI.selectedSlotName = slotName
                                                M.inventoryUI.compareResults = compareSlotAcrossPeers(slotID)
                                            end

                                            if rightClicked then
                                                local targetChar = M.inventoryUI.selectedPeer or extractCharacterName(mq.TLO.Me.Name())
                                                M.inventoryUI.availableItems = Suggestions.getAvailableItemsForSlot(
                                                    targetChar, slotID)
                                                M.inventoryUI.filteredItemsCache.lastFilterKey = ""  -- Invalidate cache
                                                M.inventoryUI.showItemSuggestions = true
                                                M.inventoryUI.itemSuggestionsTarget = targetChar
                                                M.inventoryUI.itemSuggestionsSlot = slotID
                                                M.inventoryUI.itemSuggestionsSlotName = slotName
                                                M.inventoryUI.selectedComparisonItemId = ""
                                                M.inventoryUI.selectedComparisonItem = nil
                                            end

                                            if ImGui.IsItemHovered() then
                                                local drawList = ImGui.GetWindowDrawList()
                                                drawList:AddRect(ImVec2(buttonMinX, buttonMinY),
                                                    ImVec2(buttonMaxX, buttonMaxY),
                                                    ImGui.GetColorU32(0.5, 0.5, 0.5, 0.3), 2.0)
                                                ImGui.BeginTooltip()
                                                ImGui.Text(slotName .. " (Empty)")
                                                ImGui.Text("Left-click: Compare across characters")
                                                ImGui.Text("Right-click: Find items for this slot")
                                                ImGui.EndTooltip()
                                            end
                                        end
                                    end

                                    for rowIndex, row in ipairs(slotLayout) do
                                        ImGui.TableNextRow(ImGuiTableRowFlags.None, 40)
                                        for colIndex, slotID in ipairs(row) do
                                            ImGui.TableNextColumn()
                                            if slotID ~= "" then
                                                local slotButtonID = "slot_" .. tostring(slotID)
                                                local slotName = getSlotNameFromID(slotID)
                                                local item = equippedItems[slotID]
                                                ImGui.PushID(slotButtonID)
                                                local success, err = pcall(renderEquippedSlot, slotID, item, slotName)
                                                ImGui.PopID()
                                                if not success then
                                                    printf("Error drawing slot %s: %s", tostring(slotID), err)
                                                end
                                            else
                                                ImGui.Text("")
                                            end
                                        end
                                    end
                                    ImGui.EndTable()
                                end
                            end)
                            ImGui.NextColumn()
                            if M.inventoryUI.selectedSlotID then
                                ImGui.Text("Comparing " .. M.inventoryUI.selectedSlotName .. " slot across all characters:")
                                ImGui.Separator()
                                if #M.inventoryUI.compareResults == 0 then
                                    ImGui.Text("No data available for comparison.")
                                else
                                    local peerMap = {}
                                    for _, result in ipairs(M.inventoryUI.compareResults) do
                                        if result.peerName then
                                            peerMap[result.peerName] = true
                                        end
                                    end
                                    local allConnectedPeers = {}
                                    for peerID, invData in pairs(inventory_actor.peer_inventories) do
                                        if invData and invData.name then
                                            table.insert(allConnectedPeers, invData.name)
                                        end
                                    end
                                    local processedResults = {}
                                    local currentSlotID = M.inventoryUI.selectedSlotID
                                    for idx, result in ipairs(M.inventoryUI.compareResults) do
                                        if result.peerName then
                                            table.insert(processedResults, result)
                                        end
                                    end
                                    for _, peerName in ipairs(allConnectedPeers) do
                                        if not peerMap[peerName] then
                                            table.insert(processedResults, {
                                                peerName = peerName,
                                                item = nil,
                                                slotid = currentSlotID,
                                            })
                                        end
                                    end

                                    table.sort(processedResults, function(a, b)
                                        return (a.peerName or "zzz") < (b.peerName or "zzz")
                                    end)
                                    local equippedResults = {}
                                    local emptyResults = {}

                                    for _, result in ipairs(processedResults) do
                                        local showRow = true
                                        if result.peerName then
                                            local peerSpawn = mq.TLO.Spawn("pc = " .. result.peerName)
                                            if peerSpawn.ID() then
                                                local peerClass = peerSpawn.Class.ShortName() or "UNK"
                                                local armorType = getArmorTypeByClass(peerClass)
                                                showRow = (M.inventoryUI.armorTypeFilter == "All" or armorType == M.inventoryUI.armorTypeFilter)
                                            end
                                        end

                                        if showRow then
                                            if result.item then
                                                table.insert(equippedResults, result)
                                            else
                                                table.insert(emptyResults, result)
                                            end
                                        end
                                    end
                                    if #equippedResults > 0 then
                                        ImGui.Text("Characters with " .. M.inventoryUI.selectedSlotName .. " equipped:")
                                        if ImGui.BeginTable("EquippedComparisonTable", 6, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.Resizable) then
                                            ImGui.TableSetupColumn("Character", ImGuiTableColumnFlags.WidthFixed, 100)
                                            ImGui.TableSetupColumn("Icon", ImGuiTableColumnFlags.WidthFixed, 40)
                                            ImGui.TableSetupColumn("Item", ImGuiTableColumnFlags.WidthStretch)
                                            ImGui.TableSetupColumn("AC", ImGuiTableColumnFlags.WidthFixed, 50)
                                            ImGui.TableSetupColumn("HP", ImGuiTableColumnFlags.WidthFixed, 50)
                                            ImGui.TableSetupColumn("Mana", ImGuiTableColumnFlags.WidthFixed, 50)
                                            ImGui.TableHeadersRow()

                                            for idx, result in ipairs(equippedResults) do
                                                local safePeerName = result.peerName or "UnknownPeer"
                                                ImGui.PushID(safePeerName .. "_equipped_" .. tostring(idx))

                                                ImGui.TableNextRow()

                                                ImGui.TableNextColumn()
                                                if ImGui.Selectable(result.peerName) then
                                                    inventory_actor.send_inventory_command(result.peerName, "foreground",
                                                        {})
                                                    printf("Bringing %s to the foreground...", result.peerName)
                                                end

                                                ImGui.TableNextColumn()
                                                if result.item and result.item.icon and result.item.icon > 0 then
                                                    drawItemIcon(result.item.icon)
                                                else
                                                    ImGui.Text("--")
                                                end

                                                ImGui.TableNextColumn()
                                                if result.item then
                                                    if ImGui.Selectable(result.item.name) then
                                                        if result.item.itemlink and result.item.itemlink ~= "" then
                                                            local links = mq.ExtractLinks(result.item.itemlink)
                                                            if links and #links > 0 then
                                                                mq.ExecuteTextLink(links[1])
                                                            end
                                                        end
                                                    end
                                                    if ImGui.IsItemClicked(ImGuiMouseButton.Right) then
                                                        M.inventoryUI.itemSuggestionsTarget = result.peerName
                                                        M.inventoryUI.itemSuggestionsSlot = result.item.slotid
                                                        M.inventoryUI.showItemSuggestions = true
                                                        M.inventoryUI.availableItems = Suggestions.getAvailableItemsForSlot(result.peerName, result.item.slotid)
                                                        M.inventoryUI.filteredItemsCache.lastFilterKey = ""  -- Invalidate cache

                                                    end
                                                end

                                                -- AC Column (Gold)
                                                ImGui.TableNextColumn()
                                                if result.item and result.item.ac then
                                                    ImGui.TextColored(1.0, 0.84, 0.0, 1.0, tostring(result.item.ac))
                                                else
                                                    ImGui.TextColored(0.5, 0.5, 0.5, 1.0, "--")
                                                end

                                                -- HP Column (Green)
                                                ImGui.TableNextColumn()
                                                if result.item and result.item.hp then
                                                    ImGui.TextColored(0.0, 0.8, 0.0, 1.0, tostring(result.item.hp))
                                                else
                                                    ImGui.TextColored(0.5, 0.5, 0.5, 1.0, "--")
                                                end

                                                -- Mana Column (Blue)
                                                ImGui.TableNextColumn()
                                                if result.item and result.item.mana then
                                                    ImGui.TextColored(0.2, 0.4, 1.0, 1.0, tostring(result.item.mana))
                                                else
                                                    ImGui.TextColored(0.5, 0.5, 0.5, 1.0, "--")
                                                end

                                                ImGui.PopID()
                                            end
                                            ImGui.EndTable()
                                        end
                                    end
                                    if #emptyResults > 0 then
                                        if #equippedResults > 0 then
                                            ImGui.Spacing()
                                            ImGui.Separator()
                                            ImGui.Spacing()
                                        end

                                        ImGui.Text("Characters with empty " .. M.inventoryUI.selectedSlotName .. " slot:")
                                        if ImGui.BeginTable("EmptyComparisonTable", 2, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.Resizable) then
                                            ImGui.TableSetupColumn("Character", ImGuiTableColumnFlags.WidthFixed, 100)
                                            ImGui.TableSetupColumn("Status", ImGuiTableColumnFlags.WidthStretch)
                                            ImGui.TableHeadersRow()
                                            for idx, result in ipairs(emptyResults) do
                                                local safePeerName = result.peerName or "UnknownPeer"
                                                ImGui.PushID(safePeerName .. "_empty_" .. tostring(idx))
                                                ImGui.TableNextRow()
                                                ImGui.TableSetBgColor(ImGuiTableBgTarget.RowBg0,
                                                    ImGui.GetColorU32(0.3, 0.1, 0.1, 0.3))
                                                ImGui.TableNextColumn()
                                                if ImGui.Selectable(result.peerName) then
                                                    inventory_actor.send_inventory_command(result.peerName, "foreground",
                                                        {})
                                                    printf("Bringing %s to the foreground...", result.peerName)
                                                end
                                                ImGui.TableNextColumn()
                                                ImGui.PushStyleColor(ImGuiCol.Text, 0.6, 0.6, 0.6, 1.0)
                                                if ImGui.Selectable("(empty slot) - Click to find items") then
                                                    local slotID = result.slotid
                                                    local targetChar = result.peerName
                                                    M.inventoryUI.availableItems = Suggestions.getAvailableItemsForSlot(
                                                        targetChar, slotID)
                                                    M.inventoryUI.filteredItemsCache.lastFilterKey = ""  -- Invalidate cache
                                                    M.inventoryUI.showItemSuggestions = true
                                                    M.inventoryUI.itemSuggestionsTarget = targetChar
                                                    M.inventoryUI.itemSuggestionsSlot = slotID
                                                    M.inventoryUI.itemSuggestionsSlotName = getSlotNameFromID(slotID) or
                                                        tostring(slotID)
                                                end
                                                ImGui.PopStyleColor()

                                                ImGui.PopID()
                                            end
                                            ImGui.EndTable()
                                        end
                                    end
                                end
                            else
                                ImGui.Text("Click on a slot to compare it across all characters.")
                            end
                            ImGui.Columns(1)
                            if not hoveringAnyItem and M.inventoryUI.openItemWindow then
                                if mq.TLO.Window("ItemDisplayWindow").Open() then
                                    mq.TLO.Window("ItemDisplayWindow").DoClose()
                                end
                                M.inventoryUI.openItemWindow = nil
                            end
                            ImGui.EndTabItem()
                        end
                    end
                    ImGui.EndTabBar()
                end
                ImGui.EndTabItem()
            end
        end

        ------------------------------
        -- Bags Section
        ------------------------------
        local BAG_ICON_SIZE = 32

        if ImGui.BeginTabItem("Bags") then
            if ImGui.BeginTabBar("BagsViewTabs") then
                if ImGui.BeginTabItem("Table View") then
                    M.inventoryUI.bagsView = "table"
                    matchingBags = {}
                    for bagid, bagItems in pairs(M.inventoryUI.inventoryData.bags) do
                        for _, item in ipairs(bagItems) do
                            if matchesSearch(item) then
                                matchingBags[bagid] = true
                                break
                            end
                        end
                    end
                    M.inventoryUI.globalExpandAll = M.inventoryUI.globalExpandAll or false
                    M.inventoryUI.bagOpen = M.inventoryUI.bagOpen or {}
                    local searchChanged = searchText ~= (M.inventoryUI.previousSearchText or "")
                    M.inventoryUI.previousSearchText = searchText

                    if M.inventoryUI.multiSelectMode then
                        local selectedCount = getSelectedItemCount()
                        ImGui.PushStyleColor(ImGuiCol.Text, 0, 1, 0, 1)
                        ImGui.Text(string.format("Multi-Select Mode: %d items selected", selectedCount))
                        ImGui.PopStyleColor()
                        ImGui.SameLine()
                        if ImGui.Button("Exit Multi-Select") then
                            M.inventoryUI.multiSelectMode = false
                            clearItemSelection()
                        end
                        if selectedCount > 0 then
                            ImGui.SameLine()
                            if ImGui.Button("Show Trade Panel") then
                                M.inventoryUI.showMultiTradePanel = true
                            end
                            ImGui.SameLine()
                            if ImGui.Button("Clear Selection") then
                                clearItemSelection()
                            end
                        end
                        ImGui.Separator()
                    end

                    local checkboxLabel = M.inventoryUI.globalExpandAll and "Collapse All Bags" or "Expand All Bags"
                    if ImGui.Checkbox(checkboxLabel, M.inventoryUI.globalExpandAll) ~= M.inventoryUI.globalExpandAll then
                        M.inventoryUI.globalExpandAll = not M.inventoryUI.globalExpandAll
                        for bagid, _ in pairs(M.inventoryUI.inventoryData.bags) do
                            M.inventoryUI.bagOpen[bagid] = M.inventoryUI.globalExpandAll
                        end
                    end

                    local bagColumns = {}
                    for bagid, bagItems in pairs(M.inventoryUI.inventoryData.bags) do
                        table.insert(bagColumns, { bagid = bagid, items = bagItems, })
                    end
                    table.sort(bagColumns, function(a, b) return a.bagid < b.bagid end)

                    for _, bag in ipairs(bagColumns) do
                        local bagid = bag.bagid
                        local bagName = bag.items[1] and bag.items[1].bagname or ("Bag " .. tostring(bagid))
                        bagName = string.format("%s (%d)", bagName, bagid)
                        local hasMatchingItem = matchingBags[bagid] or false
                        if searchChanged and hasMatchingItem and searchText ~= "" then
                            M.inventoryUI.bagOpen[bagid] = true
                        end
                        if M.inventoryUI.bagOpen[bagid] ~= nil then
                            ImGui.SetNextItemOpen(M.inventoryUI.bagOpen[bagid])
                        end
                        local isOpen = ImGui.CollapsingHeader(bagName)
                        M.inventoryUI.bagOpen[bagid] = isOpen
                        if isOpen then
                            if ImGui.BeginTable("BagTable_" .. bagid, 5, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg) then
                                ImGui.TableSetupColumn("Icon", ImGuiTableColumnFlags.WidthFixed, 32)
                                ImGui.TableSetupColumn("Item Name", ImGuiTableColumnFlags.WidthStretch)
                                ImGui.TableSetupColumn("Quantity", ImGuiTableColumnFlags.WidthFixed, 80)
                                ImGui.TableSetupColumn("Slot #", ImGuiTableColumnFlags.WidthFixed, 60)
                                ImGui.TableSetupColumn("Action", ImGuiTableColumnFlags.WidthFixed, 80)
                                ImGui.TableHeadersRow()

                                for i, item in ipairs(bag.items) do
                                    if matchesSearch(item) then
                                        ImGui.TableNextRow()

                                        local uniqueKey = string.format("%s_%s_%s_%s",
                                            M.inventoryUI.selectedPeer or "unknown",
                                            item.name or "unnamed",
                                            bagid,
                                            item.slotid or "noslot")

                                        ImGui.TableNextColumn()
                                        if item.icon and item.icon > 0 then
                                            drawItemIcon(item.icon)
                                        else
                                            ImGui.Text("N/A")
                                        end

                                        ImGui.TableNextColumn()
                                        local itemClicked = false

                                        if M.inventoryUI.multiSelectMode then
                                            if M.inventoryUI.selectedItems[uniqueKey] then
                                                ImGui.PushStyleColor(ImGuiCol.Text, 0, 1, 0, 1)
                                                itemClicked = ImGui.Selectable(item.name .. "##" .. bagid .. "_" .. i)
                                                ImGui.PopStyleColor()
                                            else
                                                itemClicked = ImGui.Selectable(item.name .. "##" .. bagid .. "_" .. i)
                                            end

                                            if itemClicked then
                                                toggleItemSelection(item, uniqueKey, M.inventoryUI.selectedPeer)
                                            end

                                            -- Draw selection indicator
                                            drawSelectionIndicator(uniqueKey, ImGui.IsItemHovered())
                                        else
                                            -- Normal mode - examine item
                                            if ImGui.Selectable(item.name .. "##" .. bagid .. "_" .. i) then
                                                local links = mq.ExtractLinks(item.itemlink)
                                                if links and #links > 0 then
                                                    mq.ExecuteTextLink(links[1])
                                                else
                                                    print(' No item link found in the database.')
                                                end
                                            end
                                        end

                                        if ImGui.IsItemClicked(ImGuiMouseButton.Right) then
                                            local mouseX, mouseY = ImGui.GetMousePos()
                                            showContextMenu(item, M.inventoryUI.selectedPeer, mouseX, mouseY)
                                        end

                                        if ImGui.IsItemHovered() then
                                            ImGui.BeginTooltip()
                                            ImGui.Text(item.name)
                                            ImGui.Text("Qty: " .. tostring(item.qty))
                                            if M.inventoryUI.multiSelectMode then
                                                ImGui.Text("Right-click for options")
                                                ImGui.Text("Left-click to select/deselect")
                                            end
                                            ImGui.EndTooltip()
                                        end

                                        -- Quantity column
                                        ImGui.TableNextColumn()
                                        ImGui.Text(tostring(item.qty or ""))

                                        -- Slot column
                                        ImGui.TableNextColumn()
                                        ImGui.Text(tostring(item.slotid or ""))

                                        -- Action column
                                        ImGui.TableNextColumn()
                                        if M.inventoryUI.multiSelectMode then
                                            if M.inventoryUI.selectedItems[uniqueKey] then
                                                ImGui.PushStyleColor(ImGuiCol.Text, 0, 1, 0, 1)
                                                ImGui.Text("Selected")
                                                ImGui.PopStyleColor()
                                            else
                                                ImGui.Text("--")
                                            end
                                        else
                                            if M.inventoryUI.selectedPeer == extractCharacterName(mq.TLO.Me.Name()) then
                                                if ImGui.Button("Pickup##" .. item.name .. "_" .. tostring(item.slotid or i)) then
                                                    mq.cmdf('/shift /itemnotify "%s" leftmouseup', item.name)
                                                end
                                            else
                                                if item.nodrop == 0 then
                                                    local itemName = item.name or "Unknown"
                                                    local peerName = M.inventoryUI.selectedPeer or "Unknown"
                                                    local uniqueID = string.format("%s_%s_%d", itemName, peerName, i)
                                                    if ImGui.Button("Trade##" .. uniqueID) then
                                                        M.inventoryUI.showGiveItemPanel = true
                                                        M.inventoryUI.selectedGiveItem = itemName
                                                        M.inventoryUI.selectedGiveTarget = peerName
                                                        M.inventoryUI.selectedGiveSource = M.inventoryUI.selectedPeer
                                                    end
                                                else
                                                    ImGui.Text("No Drop")
                                                end
                                            end
                                        end
                                    end
                                end
                                ImGui.EndTable()
                            end
                        end
                    end
                    ImGui.EndTabItem()
                end

                if ImGui.BeginTabItem("Visual Layout") then
                    M.inventoryUI.bagsView = "visual"

                    show_item_background_cbb = ImGui.Checkbox("Show Item Background", show_item_background_cbb)
                    ImGui.Separator()

                    local content_width = ImGui.GetWindowContentRegionWidth()

                    local horizontal_padding = 3
                    local item_width_plus_padding = CBB_BAG_ITEM_SIZE + horizontal_padding
                    local bag_cols = math.max(1,
                        math.floor((content_width + horizontal_padding) / item_width_plus_padding))

                    ImGui.PushStyleVar(ImGuiStyleVar.ItemSpacing, ImVec2(horizontal_padding, 3))
                    if M.inventoryUI.selectedPeer == extractCharacterName(mq.TLO.Me.Name()) then
                        local current_col = 1
                        for mainSlotIndex = 23, 34 do
                            local slot_tlo = mq.TLO.Me.Inventory(mainSlotIndex)
                            local pack_number = mainSlotIndex - 22
                            if slot_tlo.Container() and slot_tlo.Container() > 0 then
                                ImGui.TextUnformatted(string.format("%s (Pack %d)", slot_tlo.Name(), pack_number))
                                ImGui.Separator()
                                for insideIndex = 1, slot_tlo.Container() do
                                    local item_tlo = slot_tlo.Item(insideIndex)
                                    local cell_id = string.format("bag_%d_slot_%d", pack_number, insideIndex)
                                    local show_this_item = item_tlo.ID() and
                                        (not searchText or searchText == "" or string.match(string.lower(item_tlo.Name()), string.lower(searchText)))
                                    ImGui.PushID(cell_id)
                                    if show_this_item then
                                        draw_live_item_icon_cbb(item_tlo, cell_id)
                                    else
                                        draw_empty_slot_cbb(cell_id)
                                    end
                                    ImGui.PopID()
                                    if current_col < bag_cols then
                                        current_col = current_col + 1
                                        ImGui.SameLine()
                                    else
                                        current_col = 1
                                    end
                                end
                                ImGui.NewLine()
                                ImGui.Separator()
                                current_col = 1
                            end
                        end
                    else
                        local bagsMap = {}
                        local bagNames = {}
                        local bagOrder = {}
                        for bagid, bagItems in pairs(M.inventoryUI.inventoryData.bags) do
                            if not bagsMap[bagid] then
                                bagsMap[bagid] = {}
                                table.insert(bagOrder, bagid)
                            end
                            local currentBagName = "Bag " .. tostring(bagid)
                            for _, item in ipairs(bagItems) do
                                if item.slotid then
                                    bagsMap[bagid][tonumber(item.slotid)] = item
                                    if item.bagname and item.bagname ~= "" then
                                        currentBagName = item.bagname
                                    end
                                end
                            end
                            bagNames[bagid] = string.format("%s (%d)", currentBagName, bagid)
                        end
                        table.sort(bagOrder)
                        for _, bagid in ipairs(bagOrder) do
                            local bagMap = bagsMap[bagid]
                            local bagName = bagNames[bagid]
                            ImGui.TextUnformatted(bagName)
                            ImGui.Separator()
                            local current_col = 1
                            for slotIndex = 1, CBB_MAX_SLOTS_PER_BAG do
                                local item_db = bagMap[slotIndex]
                                local cell_id = string.format("bag_%d_slot_%d", bagid, slotIndex)
                                local show_this_item = item_db and matchesSearch(item_db)
                                ImGui.PushID(cell_id)
                                if show_this_item then
                                    draw_item_icon_cbb(item_db, cell_id)
                                else
                                    draw_empty_slot_cbb(cell_id)
                                end
                                ImGui.PopID()
                                if current_col < bag_cols then
                                    current_col = current_col + 1
                                    ImGui.SameLine()
                                else
                                    current_col = 1
                                end
                            end
                            ImGui.NewLine()
                            ImGui.Separator()
                        end
                    end
                    ImGui.PopStyleVar()

                    ImGui.EndTabItem()
                end
                ImGui.EndTabBar()
            end
            ImGui.EndTabItem()
        end

        ------------------------------
        -- Bank Items Section
        ------------------------------
        if ImGui.BeginTabItem("Bank") then
            if not M.inventoryUI.inventoryData.bank or #M.inventoryUI.inventoryData.bank == 0 then
                ImGui.Text("There's no loot here! Go visit a bank and re-sync!")
            else
                -- Add sorting controls
                M.inventoryUI.bankSortMode = M.inventoryUI.bankSortMode or "slot"          -- Default to slot sorting
                M.inventoryUI.bankSortDirection = M.inventoryUI.bankSortDirection or "asc" -- Default to ascending

                ImGui.Text("Sort by:")
                ImGui.SameLine()
                ImGui.SetNextItemWidth(120)
                if ImGui.BeginCombo("##BankSortMode", M.inventoryUI.bankSortMode == "slot" and "Slot Number" or "Item Name") then
                    if ImGui.Selectable("Slot Number", M.inventoryUI.bankSortMode == "slot") then
                        M.inventoryUI.bankSortMode = "slot"
                    end
                    if ImGui.Selectable("Item Name", M.inventoryUI.bankSortMode == "name") then
                        M.inventoryUI.bankSortMode = "name"
                    end
                    ImGui.EndCombo()
                end

                ImGui.SameLine()
                if ImGui.Button(M.inventoryUI.bankSortDirection == "asc" and "↑ Ascending" or "↓ Descending") then
                    M.inventoryUI.bankSortDirection = M.inventoryUI.bankSortDirection == "asc" and "desc" or "asc"
                end

                ImGui.Separator()

                -- Create a sorted copy of bank items
                local sortedBankItems = {}
                for i, item in ipairs(M.inventoryUI.inventoryData.bank) do
                    if matchesSearch(item) then
                        table.insert(sortedBankItems, item)
                    end
                end

                -- Sort the items based on selected criteria
                table.sort(sortedBankItems, function(a, b)
                    local valueA, valueB

                    if M.inventoryUI.bankSortMode == "name" then
                        valueA = (a.name or ""):lower()
                        valueB = (b.name or ""):lower()
                    else -- slot mode
                        -- Sort by bank slot first, then by item slot within the same bank slot
                        local bankSlotA = tonumber(a.bankslotid) or 0
                        local bankSlotB = tonumber(b.bankslotid) or 0
                        local itemSlotA = tonumber(a.slotid) or -1
                        local itemSlotB = tonumber(b.slotid) or -1

                        if bankSlotA ~= bankSlotB then
                            valueA = bankSlotA
                            valueB = bankSlotB
                        else
                            valueA = itemSlotA
                            valueB = itemSlotB
                        end
                    end

                    if M.inventoryUI.bankSortDirection == "asc" then
                        return valueA < valueB
                    else
                        return valueA > valueB
                    end
                end)

                if ImGui.BeginTable("BankTable", 4, bit.bor(ImGuiTableFlags.BordersInnerV, ImGuiTableFlags.RowBg)) then
                    ImGui.TableSetupColumn("Icon", ImGuiTableColumnFlags.WidthFixed, 40)
                    ImGui.TableSetupColumn("Item", ImGuiTableColumnFlags.WidthStretch)
                    ImGui.TableSetupColumn("Quantity", ImGuiTableColumnFlags.WidthFixed, 70)
                    ImGui.TableSetupColumn("Action", ImGuiTableColumnFlags.WidthFixed, 70)
                    ImGui.TableHeadersRow()

                    for i, item in ipairs(sortedBankItems) do
                        ImGui.TableNextRow()
                        local bankSlotId = item.bankslotid or "nobankslot"
                        local slotId = item.slotid or "noslot"
                        local itemName = item.name or "noname"
                        local uniqueID = string.format("%s_bank%s_slot%s_%d", itemName, bankSlotId, slotId, i)

                        ImGui.PushID(uniqueID)

                        ImGui.TableSetColumnIndex(0)
                        if item.icon and item.icon ~= 0 then
                            drawItemIcon(item.icon)
                        else
                            ImGui.Text("N/A")
                        end

                        ImGui.TableSetColumnIndex(1)
                        if ImGui.Selectable(item.name .. "##" .. uniqueID) then
                            local links = mq.ExtractLinks(item.itemlink)
                            if links and #links > 0 then
                                mq.ExecuteTextLink(links[1])
                            else
                                print(' No item link found in the database.')
                            end
                        end

                        -- Add hover tooltip for sorted items
                        if ImGui.IsItemHovered() then
                            ImGui.BeginTooltip()
                            ImGui.Text(item.name or "Unknown Item")
                            ImGui.Text("Click to examine item")
                            ImGui.Text(string.format("Bank Slot: %s, Item Slot: %s",
                                tostring(item.bankslotid or "N/A"),
                                tostring(item.slotid or "N/A")))
                            if M.inventoryUI.bankSortMode == "name" then
                                ImGui.Text("Sorted alphabetically")
                            else
                                ImGui.Text("Sorted by slot position")
                            end
                            ImGui.EndTooltip()
                        end

                        ImGui.TableSetColumnIndex(2)
                        local quantity = tonumber(item.qty) or tonumber(item.stack) or 1
                        if quantity > 1 then
                            ImGui.PushStyleColor(ImGuiCol.Text, 0.4, 0.8, 1.0, 1.0) -- Light blue for stacks
                            ImGui.Text(tostring(quantity))
                            ImGui.PopStyleColor()
                        else
                            ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.8, 0.8, 1.0) -- Gray for single items
                            ImGui.Text("1")
                            ImGui.PopStyleColor()
                        end

                        ImGui.TableSetColumnIndex(3)
                        if ImGui.Button("Pickup##" .. uniqueID) then
                            local BankSlotId = tonumber(item.bankslotid) or 0
                            local SlotId = tonumber(item.slotid) or -1

                            if BankSlotId >= 1 and BankSlotId <= 24 then
                                if SlotId == -1 then
                                    mq.cmdf("/shift /itemnotify bank%d leftmouseup", BankSlotId)
                                else
                                    mq.cmdf("/shift /itemnotify in bank%d %d leftmouseup", BankSlotId, SlotId)
                                end
                            elseif BankSlotId >= 25 and BankSlotId <= 26 then
                                local sharedSlot = BankSlotId - 24 -- Convert to 1-2
                                if SlotId == -1 then
                                    -- Direct shared bank slot
                                    mq.cmdf("/shift /itemnotify sharedbank%d leftmouseup", sharedSlot)
                                else
                                    -- Item in a shared bank bag
                                    mq.cmdf("/shift /itemnotify in sharedbank%d %d leftmouseup", sharedSlot, SlotId)
                                end
                            else
                                printf("Unknown bank slot ID: %d", BankSlotId)
                            end
                        end

                        if ImGui.IsItemHovered() then
                            ImGui.SetTooltip("You need to be near a banker to pick up this item")
                        end

                        ImGui.PopID()
                    end

                    ImGui.EndTable()
                end

                -- Display sorting info
                ImGui.Spacing()
                ImGui.PushStyleColor(ImGuiCol.Text, 0.7, 0.7, 0.7, 1.0)
                local sortInfo = string.format("Showing %d items sorted by %s (%s)",
                    #sortedBankItems,
                    M.inventoryUI.bankSortMode == "slot" and "slot number" or "item name",
                    M.inventoryUI.bankSortDirection == "asc" and "ascending" or "descending")
                ImGui.Text(sortInfo)
                ImGui.PopStyleColor()
            end
            ImGui.EndTabItem()
        end

        ------------------------------
        -- All Bots Search Results Tab
        ------------------------------
        if ImGui.BeginTabItem("All Characters - PC") then
            -- Enhanced filtering controls
            local filterOptions = { "All", "Equipped", "Inventory", "Bank", }
            M.inventoryUI.sourceFilter = M.inventoryUI.sourceFilter or "All"

            -- Initialize new filter states
            M.inventoryUI.filterNoDrop = M.inventoryUI.filterNoDrop or false
            M.inventoryUI.itemTypeFilter = M.inventoryUI.itemTypeFilter or "All"
            M.inventoryUI.minValueFilter = tonumber(M.inventoryUI.minValueFilter) or 0
            M.inventoryUI.maxValueFilter = tonumber(M.inventoryUI.maxValueFilter) or 999999999
            M.inventoryUI.minTributeFilter = tonumber(M.inventoryUI.minTributeFilter) or 0
            M.inventoryUI.showValueFilters = M.inventoryUI.showValueFilters or false
            M.inventoryUI.classFilter = M.inventoryUI.classFilter or "All"
            M.inventoryUI.raceFilter = M.inventoryUI.raceFilter or "All"
            M.inventoryUI.sortColumn = M.inventoryUI.sortColumn or "none"
            M.inventoryUI.sortDirection = M.inventoryUI.sortDirection or "asc"

            -- Pagination state
            M.inventoryUI.pcCurrentPage = M.inventoryUI.pcCurrentPage or 1
            M.inventoryUI.pcItemsPerPage = M.inventoryUI.pcItemsPerPage or 50
            M.inventoryUI.pcTotalPages = M.inventoryUI.pcTotalPages or 1

            -- Track filter state for page reset
            M.inventoryUI.pcPrevFilterState = M.inventoryUI.pcPrevFilterState or ""
            local currentFilterState = string.format("%s_%s_%s_%s_%s_%d_%d_%d_%s_%s",
                M.inventoryUI.sourceFilter,
                tostring(M.inventoryUI.filterNoDrop),
                M.inventoryUI.itemTypeFilter,
                M.inventoryUI.classFilter,
                M.inventoryUI.raceFilter,
                M.inventoryUI.minValueFilter,
                M.inventoryUI.maxValueFilter,
                M.inventoryUI.minTributeFilter,
                M.inventoryUI.sortColumn,
                M.inventoryUI.sortDirection
            )

            -- Reset to page 1 if filters changed
            if M.inventoryUI.pcPrevFilterState ~= currentFilterState then
                M.inventoryUI.pcCurrentPage = 1
                M.inventoryUI.pcPrevFilterState = currentFilterState
            end

            -- Enhanced search function with new filters
            local function enhancedSearchAcrossPeers()
                local results = {}
                local searchTerm = (searchText or ""):lower()

                local function itemMatches(item)
                    if not item then return false end

                    if searchTerm ~= "" then
                        local itemName = item.name or ""
                        if not itemName:lower():find(searchTerm) then
                            -- Check augments
                            local augMatch = false
                            for i = 1, 6 do
                                local aug = item["aug" .. i .. "Name"]
                                if aug and type(aug) == "string" and aug:lower():find(searchTerm) then
                                    augMatch = true
                                    break
                                end
                            end
                            if not augMatch then return false end
                        end
                    end
                    return true
                end

                local function passesFilters(item)
                    if not item then return false end

                    -- No Drop filter
                    if M.inventoryUI.filterNoDrop and item.nodrop == 1 then
                        return false
                    end

                    -- Value filters
                    if M.inventoryUI.showValueFilters then
                        local itemValue = tonumber(item.value) or 0
                        local itemTribute = tonumber(item.tribute) or 0

                        local minValue = tonumber(M.inventoryUI.minValueFilter) or 0
                        local maxValue = tonumber(M.inventoryUI.maxValueFilter) or 999999999
                        local minTribute = tonumber(M.inventoryUI.minTributeFilter) or 0

                        if itemValue < minValue or itemValue > maxValue then
                            return false
                        end

                        if itemTribute < minTribute then
                            return false
                        end
                    end

                    -- Item Type filter
                    local itemType = item.itemtype or item.type or ""
                    if not itemMatchesGroup(itemType, M.inventoryUI.itemTypeFilter) then
                        return false
                    end

                    -- Class filter
                    if M.inventoryUI.classFilter ~= "All" then
                        local classes = item.classes or ""
                        if type(classes) == "string" and not classes:find(M.inventoryUI.classFilter) then
                            return false
                        elseif type(classes) ~= "string" then
                            return false
                        end
                    end

                    -- Race filter
                    if M.inventoryUI.raceFilter ~= "All" then
                        local races = item.races or ""
                        if type(races) == "string" and not races:find(M.inventoryUI.raceFilter) then
                            return false
                        elseif type(races) ~= "string" then
                            return false
                        end
                    end

                    return true
                end

                -- Check if inventory_actor and peer_inventories exist
                if not inventory_actor or not inventory_actor.peer_inventories then
                    return results
                end

                for _, invData in pairs(inventory_actor.peer_inventories) do
                    if invData then
                        local function searchItems(items, sourceLabel)
                            if not items then return end

                            if sourceLabel == "Equipped" or sourceLabel == "Bank" then
                                for _, item in ipairs(items) do
                                    if item and itemMatches(item) and passesFilters(item) then
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
                                for bagId, bagItems in pairs(items) do
                                    if bagItems then
                                        for _, item in ipairs(bagItems) do
                                            if item and itemMatches(item) and passesFilters(item) then
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
                        end

                        -- Apply source filter
                        if M.inventoryUI.sourceFilter == "All" or M.inventoryUI.sourceFilter == "Equipped" then
                            searchItems(invData.equipped, "Equipped")
                        end
                        if M.inventoryUI.sourceFilter == "All" or M.inventoryUI.sourceFilter == "Inventory" then
                            searchItems(invData.bags, "Inventory")
                        end
                        if M.inventoryUI.sourceFilter == "All" or M.inventoryUI.sourceFilter == "Bank" then
                            searchItems(invData.bank, "Bank")
                        end
                    end
                end

                -- Apply sorting
                if M.inventoryUI.sortColumn ~= "none" and #results > 0 then
                    table.sort(results, function(a, b)
                        if not a or not b then return false end

                        local valueA, valueB

                        if M.inventoryUI.sortColumn == "name" then
                            valueA = (a.name or ""):lower()
                            valueB = (b.name or ""):lower()
                        elseif M.inventoryUI.sortColumn == "value" then
                            valueA = tonumber(a.value) or 0
                            valueB = tonumber(b.value) or 0
                        elseif M.inventoryUI.sortColumn == "tribute" then
                            valueA = tonumber(a.tribute) or 0
                            valueB = tonumber(b.tribute) or 0
                        elseif M.inventoryUI.sortColumn == "peer" then
                            valueA = (a.peerName or ""):lower()
                            valueB = (b.peerName or ""):lower()
                        elseif M.inventoryUI.sortColumn == "type" then
                            valueA = (a.itemtype or a.type or ""):lower()
                            valueB = (b.itemtype or b.type or ""):lower()
                        elseif M.inventoryUI.sortColumn == "qty" then
                            valueA = tonumber(a.qty) or 0
                            valueB = tonumber(b.qty) or 0
                        else
                            return false
                        end

                        if M.inventoryUI.sortDirection == "asc" then
                            return valueA < valueB
                        else
                            return valueA > valueB
                        end
                    end)
                end

                return results
            end

            local results = enhancedSearchAcrossPeers()
            local resultCount = #results

            -- Filter Panel
            if ImGui.BeginChild("FilterPanel", 0, 120, true, ImGuiChildFlags.Border) then
                ImGui.Text("Filters")
                ImGui.SameLine()
                ImGui.Text(string.format("Found %d items matching filters:", resultCount))

                -- Align "Hide No Drop" to the right
                local windowWidth = ImGui.GetWindowContentRegionWidth()
                local checkboxWidth = ImGui.CalcTextSize("Hide No Drop") + 20 -- Text width + checkbox size
                ImGui.SameLine(windowWidth - checkboxWidth)
                M.inventoryUI.filterNoDrop = ImGui.Checkbox("Hide No Drop", M.inventoryUI.filterNoDrop)

                ImGui.Separator()

                -- Row 1: Source, Item Type
                ImGui.PushItemWidth(120)
                ImGui.Text("Source:")
                ImGui.SameLine(100)
                ImGui.SetNextItemWidth(120)
                if ImGui.BeginCombo("##SourceFilter", M.inventoryUI.sourceFilter) then
                    for _, option in ipairs(filterOptions) do
                        local selected = (M.inventoryUI.sourceFilter == option)
                        if ImGui.Selectable(option, selected) then
                            M.inventoryUI.sourceFilter = option
                            M.inventoryUI.pcCurrentPage = 1 -- Reset to first page
                        end
                    end
                    ImGui.EndCombo()
                end

                ImGui.SameLine(250)
                ImGui.Text("Item Type:")
                ImGui.SameLine(340)
                ImGui.SetNextItemWidth(120)
                if ImGui.BeginCombo("##ItemTypeFilter", M.inventoryUI.itemTypeFilter) then
                    local itemGroupOptions = { "All", "Weapon", "Armor", "Jewelry", "Consumable", "Scrolls" }
                    for _, group in ipairs(itemGroupOptions) do
                        local selected = (M.inventoryUI.itemTypeFilter == group)
                        if ImGui.Selectable(group, selected) then
                            M.inventoryUI.itemTypeFilter = group
                        end
                    end
                    ImGui.EndCombo()
                end
                if M.inventoryUI.itemTypeFilter and M.inventoryUI.itemTypeFilter ~= "All" then
                    local groupList = itemGroups[M.inventoryUI.itemTypeFilter]
                    if groupList then
                        ImGui.SameLine()
                        ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.84, 0.0, 1.0) -- Gold RGBA
                        ImGui.Text("Item Types: " .. table.concat(groupList, ", "))
                        ImGui.PopStyleColor()
                    end
                end

                -- Row 2: Class, Race, Sort
                ImGui.Text("Class:")
                ImGui.SameLine(100)
                ImGui.SetNextItemWidth(120)
                if ImGui.BeginCombo("##ClassFilter", M.inventoryUI.classFilter) then
                    local classes = {
                        "All", "WAR", "CLR", "PAL", "RNG", "SHD", "DRU", "MNK", "BRD",
                        "ROG", "SHM", "NEC", "WIZ", "MAG", "ENC", "BST", "BER"
                    }
                    for _, class in ipairs(classes) do
                        local selected = (M.inventoryUI.classFilter == class)
                        if ImGui.Selectable(class, selected) then
                            M.inventoryUI.classFilter = class
                        end
                    end
                    ImGui.EndCombo()
                end

                ImGui.SameLine(250)
                ImGui.Text("Race:")
                ImGui.SameLine(340)
                ImGui.SetNextItemWidth(120)
                if ImGui.BeginCombo("##RaceFilter", M.inventoryUI.raceFilter) then
                    local races = {
                        "All", "HUM", "BAR", "ERU", "ELF", "HIE", "DEF", "HEL", "DWF",
                        "TRL", "OGR", "HFL", "GNM", "IKS", "VAH", "FRG", "DRK"
                    }
                    for _, race in ipairs(races) do
                        local selected = (M.inventoryUI.raceFilter == race)
                        if ImGui.Selectable(race, selected) then
                            M.inventoryUI.raceFilter = race
                        end
                    end
                    ImGui.EndCombo()
                end

                ImGui.SameLine(500)
                ImGui.Text("Sort by:")
                ImGui.SameLine(575)
                ImGui.SetNextItemWidth(120)
                if ImGui.BeginCombo("##SortColumn", M.inventoryUI.sortColumn) then
                    local sortOptions = {
                        { "none",    "None" },
                        { "name",    "Item Name" },
                        { "value",   "Value" },
                        { "tribute", "Tribute" },
                        { "peer",    "Character" },
                        { "type",    "Item Type" },
                        { "qty",     "Quantity" }
                    }
                    for _, option in ipairs(sortOptions) do
                        local selected = (M.inventoryUI.sortColumn == option[1])
                        if ImGui.Selectable(option[2], selected) then
                            M.inventoryUI.sortColumn = option[1]
                        end
                    end
                    ImGui.EndCombo()
                end

                if M.inventoryUI.sortColumn ~= "none" then
                    ImGui.SameLine()
                    if ImGui.Button(M.inventoryUI.sortDirection == "asc" and "Asc" or "Desc") then
                        M.inventoryUI.sortDirection = M.inventoryUI.sortDirection == "asc" and "desc" or "asc"
                    end
                end

                -- Row 3: Value Filters and Clear Button
                M.inventoryUI.showValueFilters = ImGui.Checkbox("Value Filters", M.inventoryUI.showValueFilters)

                if M.inventoryUI.showValueFilters then
                    ImGui.SameLine()
                    ImGui.Dummy(10, 0)
                    ImGui.SameLine()
                    ImGui.Text("Min Value:")
                    ImGui.SameLine()
                    ImGui.SetNextItemWidth(100)
                    M.inventoryUI.minValueFilter = ImGui.InputInt("##MinValue", M.inventoryUI.minValueFilter)

                    ImGui.SameLine()
                    ImGui.Text("Max Value:")
                    ImGui.SameLine()
                    ImGui.SetNextItemWidth(100)
                    M.inventoryUI.maxValueFilter = ImGui.InputInt("##MaxValue", M.inventoryUI.maxValueFilter)

                    ImGui.SameLine()
                    ImGui.Text("Min Tribute:")
                    ImGui.SameLine()
                    ImGui.SetNextItemWidth(100)
                    M.inventoryUI.minTributeFilter = ImGui.InputInt("##MinTribute", M.inventoryUI.minTributeFilter)
                end

                ImGui.SameLine()
                local windowWidth = ImGui.GetWindowContentRegionWidth()
                local buttonWidth = 100
                ImGui.SetCursorPosX(windowWidth - buttonWidth)
                if ImGui.Button("Clear All Filters", buttonWidth, 0) then
                    M.inventoryUI.sourceFilter = "All"
                    M.inventoryUI.filterNoDrop = false
                    M.inventoryUI.itemTypeFilter = "All"
                    M.inventoryUI.classFilter = "All"
                    M.inventoryUI.raceFilter = "All"
                    M.inventoryUI.minValueFilter = 0
                    M.inventoryUI.maxValueFilter = 999999999
                    M.inventoryUI.minTributeFilter = 0
                    M.inventoryUI.sortColumn = "none"
                    M.inventoryUI.showValueFilters = false
                    M.inventoryUI.pcCurrentPage = 1 -- Reset to first page
                end
            end
            ImGui.EndChild()

            if #results == 0 then
                ImGui.Text("No matching items found with current filters.")
            else
                ImGui.Text("Names Are Colored Based on Item Source -")
                ImGui.SameLine()
                ImGui.PushStyleColor(ImGuiCol.Text, 0.75, 0.0, 0.0, 1.0)
                ImGui.Text("Red = Equipped")
                ImGui.SameLine()
                ImGui.PopStyleColor()

                ImGui.PushStyleColor(ImGuiCol.Text, 0.3, 0.8, 0.3, 1.0)
                ImGui.Text("Green = Inventory")
                ImGui.SameLine()
                ImGui.PopStyleColor()

                ImGui.PushStyleColor(ImGuiCol.Text, 0.6, 0.6, 1.0, 1.0)
                ImGui.Text("Purple = Bank")
                ImGui.PopStyleColor()

                -- Calculate pagination
                local totalItems = #results
                M.inventoryUI.pcTotalPages = math.max(1, math.ceil(totalItems / M.inventoryUI.pcItemsPerPage))

                -- Reset to page 1 if current page is out of bounds
                if M.inventoryUI.pcCurrentPage > M.inventoryUI.pcTotalPages then
                    M.inventoryUI.pcCurrentPage = 1
                end

                -- Calculate page bounds
                local startIdx = ((M.inventoryUI.pcCurrentPage - 1) * M.inventoryUI.pcItemsPerPage) + 1
                local endIdx = math.min(startIdx + M.inventoryUI.pcItemsPerPage - 1, totalItems)

                -- Pagination controls
                ImGui.Separator()
                ImGui.Text(string.format("Page %d of %d | Showing items %d-%d of %d",
                    M.inventoryUI.pcCurrentPage, M.inventoryUI.pcTotalPages, startIdx, endIdx, totalItems))
                ImGui.SameLine()

                -- Previous button
                if M.inventoryUI.pcCurrentPage > 1 then
                    if ImGui.Button("< Previous") then
                        M.inventoryUI.pcCurrentPage = M.inventoryUI.pcCurrentPage - 1
                    end
                else
                    ImGui.BeginDisabled()
                    ImGui.Button("< Previous")
                    ImGui.EndDisabled()
                end

                ImGui.SameLine()

                -- Next button
                if M.inventoryUI.pcCurrentPage < M.inventoryUI.pcTotalPages then
                    if ImGui.Button("Next >") then
                        M.inventoryUI.pcCurrentPage = M.inventoryUI.pcCurrentPage + 1
                    end
                else
                    ImGui.BeginDisabled()
                    ImGui.Button("Next >")
                    ImGui.EndDisabled()
                end

                ImGui.SameLine()
                ImGui.SetNextItemWidth(100)
                M.inventoryUI.pcItemsPerPage, changed = ImGui.InputInt("Items/Page", M.inventoryUI.pcItemsPerPage)
                if changed then
                    M.inventoryUI.pcItemsPerPage = math.max(10, math.min(200, M.inventoryUI.pcItemsPerPage))
                    M.inventoryUI.pcCurrentPage = 1 -- Reset to first page when changing items per page
                end

                ImGui.Separator()

                local colors = {
                    -- Item type colors
                    itemTypes = {
                        ["Armor"] = { 0.4, 0.7, 1.0, 1.0 },       -- Light blue
                        ["Weapon"] = { 1.0, 0.4, 0.4, 1.0 },      -- Red
                        ["Shield"] = { 0.8, 0.6, 0.2, 1.0 },      -- Gold
                        ["Jewelry"] = { 0.9, 0.5, 0.9, 1.0 },     -- Purple
                        ["Misc"] = { 0.6, 0.8, 0.6, 1.0 },        -- Light green
                        ["Charm"] = { 1.0, 0.8, 0.4, 1.0 },       -- Orange
                        ["2H Slashing"] = { 0.8, 0.2, 0.2, 1.0 }, -- Dark red
                    },

                    -- Source colors
                    sources = {
                        ["Equipped"] = { 0.75, 0.0, 0.0, 1.0 }, -- Red
                        ["Inventory"] = { 0.3, 0.8, 0.3, 1.0 }, -- Green
                        ["Bank"] = { 0.4, 0.4, 0.8, 1.0 },      -- Blue
                    },

                    -- Value tier colors
                    valueTiers = {
                        high = { 1.0, 0.8, 0.0, 1.0 },   -- Gold for high value
                        medium = { 0.8, 0.8, 0.8, 1.0 }, -- Silver for medium value
                        low = { 0.6, 0.4, 0.2, 1.0 },    -- Bronze for low value
                    },

                    -- Special colors
                    nodrop = { 0.8, 0.3, 0.3, 1.0 },    -- Red for no drop
                    tradeable = { 0.3, 0.8, 0.3, 1.0 }, -- Green for tradeable
                    selected = { 0.2, 0.6, 1.0, 1.0 },  -- Blue for selections
                }

                -- Function to get value tier color
                local function getValueTierColor(value)
                    local copperValue = tonumber(value) or 0
                    local platValue = copperValue / 1000

                    if platValue >= 10000 then
                        return colors.valueTiers.high
                    elseif platValue >= 1000 then
                        return colors.valueTiers.medium
                    else
                        return colors.valueTiers.low
                    end
                end

                -- Enhanced table with new columns
                if ImGui.BeginTable("AllPeersEnhancedTable", 8, bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg, ImGuiTableFlags.Resizable, ImGuiTableFlags.ScrollX, ImGuiTableFlags.ScrollY), 0, 500) then
                    ImGui.TableSetupColumn("Peer", ImGuiTableColumnFlags.WidthFixed, 80)
                    ImGui.TableSetupColumn("Icon", ImGuiTableColumnFlags.WidthFixed, ImGuiTableColumnFlags.NoSort, 30) -- not sortable
                    ImGui.TableSetupColumn("Item", ImGuiTableColumnFlags.WidthStretch)
                    ImGui.TableSetupColumn("Type", ImGuiTableColumnFlags.WidthFixed, 30)
                    ImGui.TableSetupColumn("Value", ImGuiTableColumnFlags.WidthFixed, 70)
                    ImGui.TableSetupColumn("Tribute", ImGuiTableColumnFlags.WidthFixed, 70)
                    ImGui.TableSetupColumn("Qty", ImGuiTableColumnFlags.WidthFixed, 40)
                    ImGui.TableSetupColumn("Action", ImGuiTableColumnFlags.WidthStretch, ImGuiTableColumnFlags.NoSort) -- not sortable


                    -- Colored headers
                    ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 1.0, 0.8, 1.0) -- Light yellow headers
                    ImGui.TableHeadersRow()
                    local sortSpecs = ImGui.TableGetSortSpecs()
                    if sortSpecs and sortSpecs.SpecsDirty and sortSpecs.Specs and sortSpecs.SpecsCount > 0 then
                        local sortSpec = sortSpecs.Specs[1]
                        if sortSpec and sortSpec.ColumnIndex ~= nil and sortSpec.SortDirection ~= nil then
                            local columnIndex = sortSpec.ColumnIndex
                            local sortDirection = sortSpec.SortDirection == ImGuiSortDirection.Ascending and "asc" or
                                "desc"

                            local columnMap = {
                                [0] = "peer",
                                [2] = "name",
                                [3] = "type",
                                [4] = "value",
                                [5] = "tribute",
                                [6] = "qty"
                            }

                            local selectedSortColumn = columnMap[columnIndex]
                            if selectedSortColumn then
                                M.inventoryUI.sortColumn = selectedSortColumn
                                M.inventoryUI.sortDirection = sortDirection
                            end
                        end
                        sortSpecs.SpecsDirty = false
                    end

                    ImGui.PopStyleColor()

                    -- Only render items for the current page
                    for idx = startIdx, endIdx do
                        local item = results[idx]
                        if item then -- Additional safety check
                            ImGui.TableNextRow()

                            local uniqueID = string.format("%s_%s_%d",
                                item.peerName or "unknown",
                                item.name or "unnamed",
                                idx)
                            ImGui.PushID(uniqueID)

                            -- Peer column - colored by peer name
                            ImGui.TableNextColumn()
                            local peerColor = colors.sources[item.source] or { 0.8, 0.8, 0.8, 1.0 }
                            ImGui.PushStyleColor(ImGuiCol.Text, peerColor[1], peerColor[2], peerColor[3], peerColor[4])
                            if ImGui.Selectable(item.peerName or "unknown") then
                                if inventory_actor and inventory_actor.send_inventory_command then
                                    inventory_actor.send_inventory_command(item.peerName, "foreground", {})
                                end
                                if mq and mq.cmdf then
                                    printf("Bringing %s to the foreground...", item.peerName or "unknown")
                                end
                            end
                            ImGui.PopStyleColor()

                            --[[ Source column - colored by source type
                            ImGui.TableNextColumn()
                            local sourceColor = colors.sources[item.source] or {0.7, 0.7, 0.7, 1.0}
                            ImGui.PushStyleColor(ImGuiCol.Text, sourceColor[1], sourceColor[2], sourceColor[3], sourceColor[4])
                            ImGui.Text(item.source or "Unknown")
                            ImGui.PopStyleColor()]]

                            -- Icon column
                            ImGui.TableNextColumn()
                            if item.icon and item.icon ~= 0 and drawItemIcon then
                                drawItemIcon(item.icon)
                            else
                                ImGui.PushStyleColor(ImGuiCol.Text, 0.5, 0.5, 0.5, 1.0) -- Gray for N/A
                                ImGui.Text("N/A")
                                ImGui.PopStyleColor()
                            end

                            -- Item name column - colored by rarity or special properties
                            ImGui.TableNextColumn()
                            local itemClicked = false
                            local uniqueKey = string.format("%s_%s_%s_%s",
                                item.peerName or "unknown",
                                item.name or "unnamed",
                                item.bagid or item.bankslotid or "noloc",
                                item.slotid or "noslot")

                            -- Color item name based on value or special properties
                            local itemNameColor = { 0.8, 0.8, 1.0, 1.0 } -- Default light blue

                            if M.inventoryUI.multiSelectMode then
                                if M.inventoryUI.selectedItems and M.inventoryUI.selectedItems[uniqueKey] then
                                    ImGui.PushStyleColor(ImGuiCol.Text, colors.selected[1], colors.selected[2],
                                        colors.selected[3], colors.selected[4])
                                    itemClicked = ImGui.Selectable(tostring(item.name or "Unknown"))
                                    ImGui.PopStyleColor()
                                else
                                    ImGui.PushStyleColor(ImGuiCol.Text, itemNameColor[1], itemNameColor[2],
                                        itemNameColor[3], itemNameColor[4])
                                    itemClicked = ImGui.Selectable(tostring(item.name or "Unknown"))
                                    ImGui.PopStyleColor()
                                end
                                if itemClicked and toggleItemSelection then
                                    toggleItemSelection(item, uniqueKey, item.peerName)
                                end
                                if drawSelectionIndicator then
                                    drawSelectionIndicator(uniqueKey, ImGui.IsItemHovered())
                                end
                            else
                                ImGui.PushStyleColor(ImGuiCol.Text, itemNameColor[1], itemNameColor[2], itemNameColor[3],
                                    itemNameColor[4])
                                itemClicked = ImGui.Selectable(tostring(item.name or "Unknown"))
                                ImGui.PopStyleColor()
                                if itemClicked then
                                    if mq and mq.ExtractLinks and item.itemlink then
                                        local links = mq.ExtractLinks(item.itemlink)
                                        if links and #links > 0 and mq.ExecuteTextLink then
                                            mq.ExecuteTextLink(links[1])
                                        end
                                    elseif mq and mq.cmd then
                                        print(' No item link found.')
                                    end
                                end
                            end

                            if ImGui.IsItemClicked(ImGuiMouseButton.Right) and showContextMenu then
                                local mouseX, mouseY = ImGui.GetMousePos()
                                showContextMenu(item, item.peerName, mouseX, mouseY)
                            end
                            if ImGui.IsItemHovered() then
                                local src = item.source or "Unknown"
                                ImGui.SetTooltip(string.format("Source: %s", src))
                            end

                            -- Item Type column - colored by item type
                            ImGui.TableNextColumn()
                            local itemType = item.itemtype or item.type or "Unknown"
                            local typeColor = colors.itemTypes[itemType] or { 0.8, 0.8, 0.8, 1.0 }
                            ImGui.PushStyleColor(ImGuiCol.Text, typeColor[1], typeColor[2], typeColor[3], typeColor[4])
                            ImGui.Text(itemType)
                            ImGui.PopStyleColor()

                            -- Value column - colored by value tier
                            ImGui.TableNextColumn()
                            local copperValue = tonumber(item.value) or 0
                            local platValue = copperValue / 1000
                            local valueColor = getValueTierColor(item.value)

                            ImGui.PushStyleColor(ImGuiCol.Text, valueColor[1], valueColor[2], valueColor[3],
                                valueColor[4])
                            if platValue > 0 then
                                if platValue >= 1000000 then
                                    ImGui.Text(string.format("%.1fM", platValue / 1000000))
                                elseif platValue >= 10000 then
                                    ImGui.Text(string.format("%.1fK", platValue / 1000))
                                else
                                    ImGui.Text(string.format("%.0f", platValue))
                                end
                            else
                                ImGui.Text("--")
                            end
                            ImGui.PopStyleColor()

                            -- Tribute column - colored by tribute value
                            ImGui.TableNextColumn()
                            local tributeValue = tonumber(item.tribute) or 0
                            if tributeValue > 0 then
                                ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.4, 0.8, 1.0) -- Purple for tribute
                                ImGui.Text(tostring(tributeValue))
                                ImGui.PopStyleColor()
                            else
                                ImGui.PushStyleColor(ImGuiCol.Text, 0.5, 0.5, 0.5, 1.0) -- Gray for no tribute
                                ImGui.Text("--")
                                ImGui.PopStyleColor()
                            end

                            -- Quantity column
                            ImGui.TableNextColumn()
                            local qtyDisplay = tostring(item.qty or "?")
                            local qty = tonumber(item.qty) or 1
                            if qty > 1 then
                                ImGui.PushStyleColor(ImGuiCol.Text, 0.4, 0.8, 1.0, 1.0) -- Light blue for stacks
                            else
                                ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.8, 0.8, 1.0) -- Gray for single items
                            end
                            ImGui.Text(qtyDisplay)
                            ImGui.PopStyleColor()

                            if ImGui.IsItemHovered() then
                                ImGui.SetTooltip(string.format("qty: %s\nstack: %s",
                                    tostring(item.qty or "nil"),
                                    tostring(item.stack or "nil")))
                            end

                            -- Action column
                            ImGui.TableNextColumn()
                            local peerName = item.peerName or "Unknown"
                            local itemName = item.name or "Unnamed"

                            if mq and mq.TLO and mq.TLO.Me and mq.TLO.Me.Name and peerName == extractCharacterName(mq.TLO.Me.Name()) then
                                ImGui.PushStyleColor(ImGuiCol.Button, 0.2, 0.5, 0.8, 1.0)
                                ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.6, 0.9, 1.0)
                                ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.1, 0.4, 0.7, 1.0)
                                if ImGui.Button("Pickup##" .. uniqueID) then
                                    if item.source == "Bank" and mq and mq.cmdf then
                                        local BankSlotId = tonumber(item.bankslotid) or 0
                                        local SlotId = tonumber(item.slotid) or -1

                                        if BankSlotId >= 1 and BankSlotId <= 24 then
                                            local adjustedBankSlot = BankSlotId
                                            if SlotId == -1 then
                                                mq.cmdf("/shift /itemnotify bank%d leftmouseup", adjustedBankSlot)
                                            else
                                                mq.cmdf("/shift /itemnotify in bank%d %d leftmouseup", adjustedBankSlot,
                                                    SlotId)
                                            end
                                        elseif BankSlotId >= 25 and BankSlotId <= 26 then
                                            local sharedSlot = BankSlotId - 24
                                            if SlotId == -1 then
                                                mq.cmdf("/shift /itemnotify sharedbank%d leftmouseup", sharedSlot)
                                            else
                                                mq.cmdf("/shift /itemnotify in sharedbank%d %d leftmouseup", sharedSlot,
                                                    SlotId)
                                            end
                                        else
                                            printf("Unknown bank slot ID: %d", BankSlotId)
                                        end
                                    elseif mq and mq.cmdf then
                                        mq.cmdf('/shift /itemnotify "%s" leftmouseup', itemName)
                                    end
                                end
                                ImGui.PopStyleColor(3)
                            else
                                if item.nodrop == 0 then
                                    -- Trade button
                                    ImGui.PushStyleColor(ImGuiCol.Button, 0.6, 0.4, 0.2, 1.0)
                                    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.7, 0.5, 0.3, 1.0)
                                    ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.5, 0.3, 0.1, 1.0)
                                    if ImGui.Button("Trade##" .. uniqueID) then
                                        M.inventoryUI.showGiveItemPanel = true
                                        M.inventoryUI.selectedGiveItem = itemName
                                        M.inventoryUI.selectedGiveTarget = peerName
                                        M.inventoryUI.selectedGiveSource = item.peerName
                                    end
                                    ImGui.PopStyleColor(3)

                                    ImGui.SameLine()
                                    ImGui.PushStyleColor(ImGuiCol.Text, 0.5, 0.5, 0.5, 1.0)
                                    ImGui.Text("--")
                                    ImGui.PopStyleColor()
                                    ImGui.SameLine()

                                    -- Give button
                                    local buttonLabel = string.format("Give to %s##%s",
                                        M.inventoryUI.selectedPeer or "Unknown", uniqueID)
                                    ImGui.PushStyleColor(ImGuiCol.Button, 0, 0.6, 0, 1)
                                    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0, 0.8, 0, 1)
                                    ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0, 1.0, 0, 1)
                                    if ImGui.Button(buttonLabel) then
                                        local giveRequest = {
                                            name = itemName,
                                            to = M.inventoryUI.selectedPeer,
                                            fromBank = item.source == "Bank",
                                            bagid = item.bagid,
                                            slotid = item.slotid,
                                            bankslotid = item.bankslotid,
                                        }
                                        if inventory_actor and inventory_actor.send_inventory_command and json and json.encode then
                                            inventory_actor.send_inventory_command(item.peerName, "proxy_give",
                                                { json.encode(giveRequest), })
                                        end
                                        if mq and mq.cmdf then
                                            printf("Requested %s to give %s to %s", item.peerName, itemName,
                                                M.inventoryUI.selectedPeer)
                                        end
                                    end
                                    ImGui.PopStyleColor(3)
                                else
                                    -- No Drop items
                                    ImGui.PushStyleColor(ImGuiCol.Text, colors.nodrop[1], colors.nodrop[2],
                                        colors.nodrop[3], colors.nodrop[4])
                                    ImGui.Text("No Drop")
                                    ImGui.PopStyleColor()
                                end
                            end
                            ImGui.PopID()
                        end -- End of item safety check
                    end
                    ImGui.EndTable()
                end
            end
            ImGui.EndTabItem()
        end

        if isEMU and bot_inventory then
            if ImGui.BeginTabItem("^Bot Viewer - Emu") then
                ImGui.Text("Bot Inventory Management")
                ImGui.Separator()
                if ImGui.Button("Refresh Bot List") then
                    bot_inventory.refreshBotList()
                    print("Refreshing bot list...")
                end
                ImGui.SameLine()
                if ImGui.Button("Clear Bot Data") then
                    bot_inventory.bot_inventories = {}
                    bot_inventory.cached_bot_list = {}
                    print("Cleared all bot inventory data")
                end
                ImGui.Spacing()
                local availableBots = bot_inventory.getAllBots()
                if #availableBots > 0 then
                    ImGui.Text("Individual Bot Controls:")
                    if ImGui.BeginTable("BotControlTable", 4, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg) then
                        ImGui.TableSetupColumn("Bot Name", ImGuiTableColumnFlags.WidthStretch)
                        ImGui.TableSetupColumn("Class", ImGuiTableColumnFlags.WidthFixed, 100)
                        ImGui.TableSetupColumn("Status", ImGuiTableColumnFlags.WidthFixed, 100)
                        ImGui.TableSetupColumn("Actions", ImGuiTableColumnFlags.WidthFixed, 150)
                        ImGui.TableHeadersRow()

                        for _, botName in ipairs(availableBots) do
                            ImGui.TableNextRow()
                            ImGui.TableNextColumn()
                            ImGui.Text(botName)
                            ImGui.TableNextColumn()
                            local botData = bot_inventory.bot_list_capture_set[botName]
                            local className = botData and botData.Class or "Unknown"
                            ImGui.Text(className)
                            ImGui.TableNextColumn()
                            local hasData = bot_inventory.bot_inventories[botName] ~= nil
                            if hasData then
                                ImGui.PushStyleColor(ImGuiCol.Text, 0, 1, 0, 1)
                                ImGui.Text("Has Data")
                                ImGui.PopStyleColor()
                            else
                                ImGui.PushStyleColor(ImGuiCol.Text, 1, 1, 0, 1)
                                ImGui.Text("No Data")
                                ImGui.PopStyleColor()
                            end
                            ImGui.TableNextColumn()
                            if ImGui.Button("Refresh##" .. botName) then
                                bot_inventory.requestBotInventory(botName)
                                printf("Requesting inventory for bot: %s", botName)
                            end
                            if hasData then
                                ImGui.SameLine()
                                if ImGui.Button("View##" .. botName) then
                                    M.inventoryUI.selectedBotInventory = {
                                        name = botName,
                                        data = bot_inventory.getBotInventory(botName),
                                    }
                                    M.inventoryUI.showBotInventory = true
                                end
                            end
                        end
                        ImGui.EndTable()
                    end
                else
                    ImGui.Text("No bots detected. Make sure you have bots spawned.")
                end
                ImGui.EndTabItem()
            end
        end

        --------------------------------------------------------
        --- Peer Connection Tab
        --------------------------------------------------------
        if ImGui.BeginTabItem("Peer Management") then
            ImGui.Text("Connection Management and Peer Discovery")
            ImGui.Separator()
            local connectionMethod, connectedPeers = getPeerConnectionStatus()

            -- Request peer paths periodically
            if connectionMethod ~= "None" then
                requestPeerPaths()
            end

            ImGui.Text("Connection Method: ")
            ImGui.SameLine()
            if connectionMethod ~= "None" then
                ImGui.PushStyleColor(ImGuiCol.Text, 0, 1, 0, 1)
                ImGui.Text(connectionMethod)
                ImGui.PopStyleColor()
            else
                ImGui.PushStyleColor(ImGuiCol.Text, 1, 0, 0, 1)
                ImGui.Text("None Available")
                ImGui.PopStyleColor()
            end

            ImGui.Spacing()
            if connectionMethod ~= "None" then
                ImGui.Text("Broadcast Commands:")
                ImGui.SameLine()
                if ImGui.Button("Start EZInventory on All Peers") then
                    broadcastLuaRun(connectionMethod)
                end
                ImGui.SameLine()
                if ImGui.Button("Request All Inventories") then
                    inventory_actor.request_all_inventories()
                    print("Requested inventory updates from all peers")
                end
            else
                ImGui.PushStyleColor(ImGuiCol.Text, 0.7, 0.7, 0.7, 1.0)
                ImGui.Text("No connection method available - Load MQ2Mono, MQ2DanNet, or MQ2EQBC")
                ImGui.PopStyleColor()
            end

            ImGui.Separator()

            local peerStatus = {}
            local peerNames = {}

            for _, peer in ipairs(connectedPeers) do
                if not peerStatus[peer.name] then
                    peerStatus[peer.name] = {
                        name = peer.name,
                        displayName = peer.displayName,
                        connected = true,
                        hasInventory = false,
                        method = peer.method,
                        lastSeen = "Connected",
                    }
                    table.insert(peerNames, peer.name)
                end
            end
            for peerID, invData in pairs(inventory_actor.peer_inventories) do
                local peerName = invData.name or "Unknown"
                local myNormalizedName = extractCharacterName(mq.TLO.Me.CleanName())
                if peerName ~= myNormalizedName then
                    if peerStatus[peerName] then
                        peerStatus[peerName].hasInventory = true
                        peerStatus[peerName].lastSeen = "Has Inventory Data"
                    else
                        peerStatus[peerName] = {
                            name = peerName,
                            displayName = peerName,
                            connected = false,
                            hasInventory = true,
                            method = "Unknown",
                            lastSeen = "Has Inventory Data",
                        }
                        table.insert(peerNames, peerName)
                    end
                end
            end
            table.sort(peerNames, function(a, b)
                return a:lower() < b:lower()
            end)

            ImGui.Text(string.format("Peer Status (%d total):", #peerNames))

            -- Column visibility controls
            ImGui.Text("Column Visibility:")
            ImGui.SameLine()
            local showEQPath, changedEQPath = ImGui.Checkbox("EQ Path", Settings.showEQPath)
            if changedEQPath then
                Settings.showEQPath = showEQPath
                M.inventoryUI.showEQPath = showEQPath
                mq.pickle(SettingsFile, Settings)
            end
            ImGui.SameLine()
            local showScriptPath, changedScriptPath = ImGui.Checkbox("Script Path", Settings.showScriptPath)
            if changedScriptPath then
                Settings.showScriptPath = showScriptPath
                M.inventoryUI.showScriptPath = showScriptPath
                mq.pickle(SettingsFile, Settings)
            end

            -- Calculate number of columns dynamically
            local columnCount = 5 -- Base columns: Peer Name, Connected, Has Inventory, Method, Actions
            if Settings.showEQPath then columnCount = columnCount + 1 end
            if Settings.showScriptPath then columnCount = columnCount + 1 end

            if ImGui.BeginTable("PeerStatusTable", columnCount, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.Resizable) then
                ImGui.TableSetupColumn("Peer Name", ImGuiTableColumnFlags.WidthStretch)
                ImGui.TableSetupColumn("Connected", ImGuiTableColumnFlags.WidthFixed, 80)
                ImGui.TableSetupColumn("Has Inventory", ImGuiTableColumnFlags.WidthFixed, 100)
                ImGui.TableSetupColumn("Method", ImGuiTableColumnFlags.WidthFixed, 80)
                if Settings.showEQPath then
                    ImGui.TableSetupColumn("EQ Path", ImGuiTableColumnFlags.WidthFixed, 200)
                end
                if Settings.showScriptPath then
                    ImGui.TableSetupColumn("Script Path", ImGuiTableColumnFlags.WidthFixed, 180)
                end
                ImGui.TableSetupColumn("Actions", ImGuiTableColumnFlags.WidthFixed, 120)
                ImGui.TableHeadersRow()
                for _, peerName in ipairs(peerNames) do
                    local status = peerStatus[peerName]
                    if status then -- Safety check
                        ImGui.TableNextRow()
                        ImGui.TableNextColumn()
                        local nameToShow = status.displayName or status.name
                        if status.connected then
                            ImGui.PushStyleColor(ImGuiCol.Text, 0.3, 0.8, 1.0, 1.0)
                            if ImGui.Selectable(nameToShow .. "##peer_" .. peerName) then
                                inventory_actor.send_inventory_command(peerName, "foreground", {})
                                printf("Bringing %s to the foreground...", peerName)
                            end
                            ImGui.PopStyleColor()
                            if ImGui.IsItemHovered() then
                                ImGui.SetTooltip("Click to bring " .. peerName .. " to foreground")
                            end
                        else
                            ImGui.PushStyleColor(ImGuiCol.Text, 0.6, 0.6, 0.6, 1.0)
                            ImGui.Text(nameToShow)
                            ImGui.PopStyleColor()
                        end
                        ImGui.TableNextColumn()
                        if status.connected then
                            ImGui.PushStyleColor(ImGuiCol.Text, 0, 1, 0, 1)
                            ImGui.Text("Yes")
                            ImGui.PopStyleColor()
                        else
                            ImGui.PushStyleColor(ImGuiCol.Text, 1, 0, 0, 1)
                            ImGui.Text("No")
                            ImGui.PopStyleColor()
                        end
                        ImGui.TableNextColumn()
                        if status.hasInventory then
                            ImGui.PushStyleColor(ImGuiCol.Text, 0, 1, 0, 1)
                            ImGui.Text("Yes")
                            ImGui.PopStyleColor()
                        else
                            ImGui.PushStyleColor(ImGuiCol.Text, 1, 1, 0, 1)
                            ImGui.Text("No")
                            ImGui.PopStyleColor()
                        end
                        ImGui.TableNextColumn()
                        ImGui.Text(status.method)

                        -- EQ Path column - only show if enabled
                        if Settings.showEQPath then
                            ImGui.TableNextColumn()
                            local peerPaths = inventory_actor.get_peer_paths()
                            local eqPath = peerPaths[peerName] or "Requesting..."

                            -- Show our own path immediately
                            if peerName == extractCharacterName(mq.TLO.Me.CleanName()) then
                                eqPath = mq.TLO.EverQuest.Path() or "Unknown"
                            end

                            ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.8, 0.8, 1.0)
                            ImGui.Text(eqPath)
                            ImGui.PopStyleColor()
                            if ImGui.IsItemHovered() then
                                ImGui.SetTooltip("EverQuest Installation Path for " .. peerName .. ": " .. eqPath)
                            end
                        end

                        -- Script Path column - only show if enabled
                        if Settings.showScriptPath then
                            ImGui.TableNextColumn()
                            local peerScriptPaths = inventory_actor.get_peer_script_paths()
                            local scriptPath = peerScriptPaths[peerName] or "Requesting..."

                            -- Show our own script path immediately
                            if peerName == extractCharacterName(mq.TLO.Me.CleanName()) then
                                local eqPath = mq.TLO.EverQuest.Path() or ""
                                local currentScript = debug.getinfo(1, "S").source:sub(2) -- Remove @ prefix
                                if eqPath ~= "" and currentScript:find(eqPath, 1, true) == 1 then
                                    scriptPath = currentScript:sub(#eqPath + 1):gsub("\\", "/")
                                    if scriptPath:sub(1, 1) == "/" then
                                        scriptPath = scriptPath:sub(2)
                                    end
                                else
                                    scriptPath = currentScript:gsub("\\", "/")
                                end
                            end

                            ImGui.PushStyleColor(ImGuiCol.Text, 0.7, 0.9, 0.7, 1.0)
                            ImGui.Text(scriptPath)
                            ImGui.PopStyleColor()
                            if ImGui.IsItemHovered() then
                                ImGui.SetTooltip("Script Path for " .. peerName .. ": " .. scriptPath)
                            end
                        end

                        ImGui.TableNextColumn()
                        if status.connected and not status.hasInventory then
                            if ImGui.Button("Start Script##" .. peerName) then
                                sendLuaRunToPeer(peerName, connectionMethod)
                            end
                        elseif status.connected and status.hasInventory then
                            if ImGui.Button("Refresh##" .. peerName) then
                                inventory_actor.send_inventory_command(peerName, "echo",
                                    { "Requesting inventory refresh", })
                                printf("Sent refresh request to %s", peerName)
                            end
                        elseif not status.connected and status.hasInventory then
                            ImGui.PushStyleColor(ImGuiCol.Text, 0.7, 0.7, 0.7, 1.0)
                            ImGui.Text("Offline")
                            ImGui.PopStyleColor()
                        else
                            ImGui.Text("--")
                        end
                    end
                end
                ImGui.EndTable()
            end
            ImGui.Separator()
            if ImGui.CollapsingHeader("Debug Information") then
                ImGui.Text("Connection Method Details:")
                ImGui.Indent()
                if connectionMethod == "MQ2Mono" then
                    ImGui.Text("MQ2Mono Status: Loaded")
                    local e3Query = "e3,E3Bots.ConnectedClients"
                    local peersStr = mq.TLO.MQ2Mono.Query(e3Query)()
                    if peersStr and peersStr ~= "" and peersStr:lower() ~= "null" then
                        ImGui.Text(string.format("E3 Connected Clients: %s", peersStr))
                    else
                        ImGui.Text("E3 Connected Clients: None or query failed")
                    end
                elseif connectionMethod == "DanNet" then
                    ImGui.Text("DanNet Status: Loaded and Connected")
                    local peerCount = mq.TLO.DanNet.PeerCount() or 0
                    ImGui.Text(string.format("DanNet Peer Count: %d", peerCount))
                    local peersStr = mq.TLO.DanNet.Peers() or ""
                    ImGui.Text(string.format("Raw DanNet Peers: %s", peersStr))
                elseif connectionMethod == "EQBC" then
                    ImGui.Text("EQBC Status: Loaded and Connected")
                    local names = mq.TLO.EQBC.Names() or ""
                    ImGui.Text(string.format("EQBC Names: %s", names))
                end

                ImGui.Unindent()

                ImGui.Spacing()
                ImGui.Text("Inventory Actor Status:")
                ImGui.Indent()

                local inventoryPeerCount = 0
                for _ in pairs(inventory_actor.peer_inventories) do
                    inventoryPeerCount = inventoryPeerCount + 1
                end

                ImGui.Text(string.format("Known Inventory Peers: %d", inventoryPeerCount))
                ImGui.Text(string.format("Actor Initialized: %s", inventory_actor.is_initialized() and "Yes" or "No"))

                ImGui.Unindent()
            end

            ImGui.EndTabItem()
        end

        -----------------------------------
        ---Performance and Settings Tab
        -----------------------------------

        if ImGui.BeginTabItem("Performance & Loading") then
            ImGui.Text("Configure how inventory data is loaded and processed")
            ImGui.Separator()

            -- Stats Loading Mode Section
            if ImGui.BeginChild("StatsLoadingSection", 0, 200, true, ImGuiChildFlags.Border) then
                ImGui.Text("Statistics Loading Configuration")
                ImGui.Separator()

                -- Mode selector with descriptions
                ImGui.Text("Loading Mode:")
                ImGui.SameLine()
                ImGui.SetNextItemWidth(150)

                local statsLoadingModes = {
                    { id = "minimal",   name = "Minimal",   desc = "Essential data only (fastest)" },
                    { id = "selective", name = "Selective", desc = "Basic stats (balanced)" },
                    { id = "full",      name = "Full",      desc = "All statistics (complete)" }
                }

                local currentMode = Settings.statsLoadingMode or "selective"
                local currentModeDisplay = currentMode
                for _, mode in ipairs(statsLoadingModes) do
                    if mode.id == currentMode then
                        currentModeDisplay = mode.name
                        break
                    end
                end

                if ImGui.BeginCombo("##StatsLoadingMode", Settings.statsLoadingMode or "selective") then
                    for _, mode in ipairs(statsLoadingModes) do
                        local isSelected = (Settings.statsLoadingMode == mode.id)
                        if ImGui.Selectable(mode.name .. " - " .. mode.desc, isSelected) then
                            --print(string.format("[EZInventory] User selected mode: %s", mode.id))

                            -- Update settings immediately
                            OnStatsLoadingModeChanged(mode.id)
                        end
                        if isSelected then
                            ImGui.SetItemDefaultFocus()
                        end
                    end
                    ImGui.EndCombo()
                end
                ImGui.Spacing()
                if Settings.statsLoadingMode == "minimal" then
                    ImGui.PushStyleColor(ImGuiCol.Text, 0.3, 1.0, 0.3, 1.0)
                    ImGui.Text("* Fastest startup and lowest memory usage")
                    ImGui.Text("*  Only loads: Name, Icon, Quantity, No Drop status")
                    ImGui.Text("* Best for: Large inventories, slower systems")
                    ImGui.PopStyleColor()
                elseif Settings.statsLoadingMode == "selective" then
                    ImGui.PushStyleColor(ImGuiCol.Text, 0.3, 0.8, 1.0, 1.0)
                    ImGui.Text("* Balanced performance with essential stats")
                    ImGui.Text("* Includes: AC, HP, Mana, Value, Tribute, Clickies, Augments")
                    ImGui.Text("* Best for: Most users, medium-sized inventories")
                    ImGui.PopStyleColor()
                elseif Settings.statsLoadingMode == "full" then
                    ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.8, 0.3, 1.0)
                    ImGui.Text("* Complete item analysis with all statistics")
                    ImGui.Text("* Everything: Heroics, Resistances, Combat Stats, Requirements")
                    ImGui.Text("* Best for: Item analysis, smaller inventories")
                    ImGui.PopStyleColor()
                end
                if Settings.statsLoadingMode == "selective" then
                    ImGui.Spacing()
                    ImGui.Separator()
                    ImGui.Text("Fine-tune Selective Mode:")

                    local basicStatsChanged = ImGui.Checkbox("Load Basic Stats", Settings.loadBasicStats)
                    if basicStatsChanged ~= Settings.loadBasicStats then
                        Settings.loadBasicStats = basicStatsChanged
                        UpdateInventoryActorConfig()
                    end

                    ImGui.SameLine()
                    if ImGui.Button("?##BasicStatsHelp") then
                        M.inventoryUI.showBasicStatsHelp = not M.inventoryUI.showBasicStatsHelp
                    end

                    if M.inventoryUI.showBasicStatsHelp then
                        ImGui.Indent()
                        ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.8, 0.8, 1.0)
                        ImGui.Text("* AC, HP, Mana, Endurance")
                        ImGui.Text("* Item Type, Value, Tribute")
                        ImGui.Text("* Clicky spells and effects")
                        ImGui.Text("* Augment names and links")
                        ImGui.PopStyleColor()
                        ImGui.Unindent()
                    end

                    local detailedStatsChanged = ImGui.Checkbox("Load Detailed Stats", Settings.loadDetailedStats)
                    if detailedStatsChanged ~= Settings.loadDetailedStats then
                        Settings.loadDetailedStats = detailedStatsChanged
                        UpdateInventoryActorConfig()
                    end

                    ImGui.SameLine()
                    if ImGui.Button("?##DetailedStatsHelp") then
                        M.inventoryUI.showDetailedStatsHelp = not M.inventoryUI.showDetailedStatsHelp
                    end

                    if M.inventoryUI.showDetailedStatsHelp then
                        ImGui.Indent()
                        ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.8, 0.8, 1.0)
                        ImGui.Text("* All Attributes: STR, STA, AGI, DEX, WIS, INT, CHA")
                        ImGui.Text("* All Resistances: Magic, Fire, Cold, Disease, Poison, Corruption")
                        ImGui.Text("* Heroic Stats: Heroic STR, STA, etc.")
                        ImGui.Text("* Combat: Attack, Accuracy, Avoidance, Haste")
                        ImGui.Text("* Specialized: Spell Damage, Heal Amount, etc.")
                        ImGui.PopStyleColor()
                        ImGui.Unindent()
                    end
                end
            end
            ImGui.EndChild()

            -- Performance Metrics Section
            if ImGui.BeginChild("PerformanceSection", 0, 150, true, ImGuiChildFlags.Border) then
                ImGui.Text("Performance Metrics")
                ImGui.Separator()

                -- Calculate current inventory stats
                local itemCount = 0
                local peerCount = 0
                local totalNetworkItems = 0

                if M.inventoryUI.inventoryData then
                    itemCount = #(M.inventoryUI.inventoryData.equipped or {})
                    for _, bagItems in pairs(M.inventoryUI.inventoryData.bags or {}) do
                        itemCount = itemCount + #bagItems
                    end
                    itemCount = itemCount + #(M.inventoryUI.inventoryData.bank or {})
                end

                for _, invData in pairs(inventory_actor.peer_inventories) do
                    peerCount = peerCount + 1
                    if invData.equipped then totalNetworkItems = totalNetworkItems + #invData.equipped end
                    if invData.bags then
                        for _, bagItems in pairs(invData.bags) do
                            totalNetworkItems = totalNetworkItems + #bagItems
                        end
                    end
                    if invData.bank then totalNetworkItems = totalNetworkItems + #invData.bank end
                end

                -- Performance estimates
                local estimatedLoadTime = "Unknown"
                local memoryEstimate = "Unknown"
                local networkLoad = "Light"

                if Settings.statsLoadingMode == "minimal" then
                    estimatedLoadTime = string.format("~%.1fs", itemCount * 0.001)
                    memoryEstimate = string.format("~%.1f MB", itemCount * 0.0005)
                    networkLoad = "Light"
                elseif Settings.statsLoadingMode == "selective" then
                    estimatedLoadTime = string.format("~%.1fs", itemCount * 0.003)
                    memoryEstimate = string.format("~%.1f MB", itemCount * 0.002)
                    networkLoad = totalNetworkItems > 2000 and "Moderate" or "Light"
                elseif Settings.statsLoadingMode == "full" then
                    estimatedLoadTime = string.format("~%.1fs", itemCount * 0.008)
                    memoryEstimate = string.format("~%.1f MB", itemCount * 0.005)
                    networkLoad = totalNetworkItems > 1000 and "Heavy" or "Moderate"
                end

                -- Display metrics in a table
                if ImGui.BeginTable("PerformanceMetrics", 2, ImGuiTableFlags.Borders) then
                    ImGui.TableSetupColumn("Metric", ImGuiTableColumnFlags.WidthFixed, 120)
                    ImGui.TableSetupColumn("Value", ImGuiTableColumnFlags.WidthStretch)

                    ImGui.TableNextRow()
                    ImGui.TableNextColumn()
                    ImGui.Text("Local Items:")
                    ImGui.TableNextColumn()
                    ImGui.Text(tostring(itemCount))

                    ImGui.TableNextRow()
                    ImGui.TableNextColumn()
                    ImGui.Text("Network Peers:")
                    ImGui.TableNextColumn()
                    ImGui.Text(tostring(peerCount))

                    ImGui.TableNextRow()
                    ImGui.TableNextColumn()
                    ImGui.Text("Total Network Items:")
                    ImGui.TableNextColumn()
                    ImGui.Text(tostring(totalNetworkItems))

                    ImGui.TableNextRow()
                    ImGui.TableNextColumn()
                    ImGui.Text("Est. Load Time:")
                    ImGui.TableNextColumn()
                    ImGui.Text(estimatedLoadTime)

                    ImGui.TableNextRow()
                    ImGui.TableNextColumn()
                    ImGui.Text("Est. Memory:")
                    ImGui.TableNextColumn()
                    ImGui.Text(memoryEstimate)

                    ImGui.TableNextRow()
                    ImGui.TableNextColumn()
                    ImGui.Text("Network Load:")
                    ImGui.TableNextColumn()
                    if networkLoad == "Heavy" then
                        ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.3, 0.3, 1.0)
                    elseif networkLoad == "Moderate" then
                        ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.8, 0.3, 1.0)
                    else
                        ImGui.PushStyleColor(ImGuiCol.Text, 0.3, 1.0, 0.3, 1.0)
                    end
                    ImGui.Text(networkLoad)
                    ImGui.PopStyleColor()

                    ImGui.EndTable()
                end

                -- Warning for heavy loads
                if networkLoad == "Heavy" then
                    ImGui.Spacing()
                    ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.5, 0.0, 1.0)
                    ImGui.Text("*** Consider switching to Selective mode for better performance")
                    ImGui.PopStyleColor()
                end
            end
            ImGui.EndChild()

            -- Action Buttons Section
            if ImGui.BeginChild("ActionsSection", 0, 80, true, ImGuiChildFlags.Border) then
                ImGui.Text("* Actions")
                ImGui.Separator()

                -- Apply Settings button
                if ImGui.Button("Apply Settings", 120, 0) then
                    UpdateInventoryActorConfig()
                    SaveConfigWithStatsUpdate()
                    print("[EZInventory] Configuration applied and saved")
                end

                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip("Apply current settings and save to config file")
                end

                ImGui.SameLine()
                if ImGui.Button("Refresh Inventory", 120, 0) then
                    M.inventoryUI.isLoadingData = true
                    table.insert(inventory_actor.deferred_tasks, function()
                        inventory_actor.publish_inventory()
                        inventory_actor.request_all_inventories()
                        local myName = extractCharacterName(mq.TLO.Me.Name())
                        local selfPeer = {
                            name = myName,
                            server = server,
                            isMailbox = true,
                            data = inventory_actor.gather_inventory(),
                        }
                        loadInventoryData(selfPeer)
                        M.inventoryUI.isLoadingData = false

                        --print("[EZInventory] Inventory data refreshed")
                    end)
                end

                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip("Refresh all inventory data with current settings")
                end

                ImGui.SameLine()
                if ImGui.Button("Reset to Defaults", 120, 0) then
                    Settings.statsLoadingMode = "selective"
                    Settings.loadBasicStats = true
                    Settings.loadDetailedStats = false
                    OnStatsLoadingModeChanged("selective")
                    --print("[EZInventory] Settings reset to defaults")
                end

                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip("Reset all performance settings to recommended defaults")
                end
                if M.inventoryUI.isLoadingData then
                    ImGui.Spacing()
                    ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 1.0, 0.0, 1.0)
                    ImGui.Text("Loading inventory data...")
                    ImGui.PopStyleColor()
                end
            end
            ImGui.EndChild()
            if ImGui.CollapsingHeader("Advanced Settings") then
                ImGui.Indent()

                -- Auto-refresh settings
                local autoRefreshChanged = ImGui.Checkbox("Auto-refresh on config change",
                    Settings.autoRefreshInventory or true)
                if autoRefreshChanged ~= (Settings.autoRefreshInventory or true) then
                    Settings.autoRefreshInventory = autoRefreshChanged
                end

                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip("Automatically refresh inventory when performance settings change")
                end

                -- Network broadcasting
                local enableNetworkBroadcast = Settings.enableNetworkBroadcast or false
                local networkBroadcastChanged = ImGui.Checkbox("Broadcast config to network", enableNetworkBroadcast)
                if networkBroadcastChanged ~= enableNetworkBroadcast then
                    Settings.enableNetworkBroadcast = networkBroadcastChanged
                end

                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip("Automatically send configuration changes to other connected characters")
                end

                ImGui.SameLine()
                if ImGui.Button("Broadcast Now") then
                    if inventory_actor and inventory_actor.broadcast_config_update then
                        inventory_actor.broadcast_config_update()
                        --print("[EZInventory] Configuration broadcast to all connected peers")
                    end
                end

                -- Filtering options
                ImGui.Spacing()
                ImGui.Text("Filtering Options:")

                local enableStatsFilteringChanged = ImGui.Checkbox("Enable stats-based filtering",
                    Settings.enableStatsFiltering or true)
                if enableStatsFilteringChanged ~= (Settings.enableStatsFiltering or true) then
                    Settings.enableStatsFiltering = enableStatsFilteringChanged
                    UpdateInventoryActorConfig()
                end

                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip("Allow filtering items by statistics in the All Characters tab")
                end

                ImGui.Unindent()
            end

            ImGui.EndTabItem()
        end
        ImGui.EndTabBar()
        ImGui.EndChild()
    end


    ImGui.End()
    renderContextMenu()
    renderMultiSelectIndicator()
    renderMultiTradePanel()
    renderEquipmentComparison()
    renderItemSuggestions()

    renderItemExchange()
    if isEMU and M.inventoryUI.drawBotInventoryWindow then
        M.inventoryUI.drawBotInventoryWindow()
    end
end

return M

-- ezinventory.lua
-- developed by psatty82
local mq = require("mq")
local ImGui = require("ImGui")
local icons = require("mq.icons")
local inventory_actor = require('inventory_actor')
local peerCache = {}
local lastCacheTime = 0
local json = require("dkjson")

---@tag InventoryUI
local inventoryUI = {
    visible = true,
    showToggleButton = true,
    selectedPeer = mq.TLO.Me.Name(),
    peers = {},
    inventoryData = { equipped = {}, bags = {}, bank = {} },
    expandBags = false,
    bagOpen = {},
    showAug1 = true,
    showAug2 = true,
    showAug3 = true,
    showAug4 = false,
    showAug5 = false,
    showAug6 = false,
    windowLocked = false,
    equipView = "table",
    selectedSlotID = nil,
    selectedSlotName = nil,
    compareResults = {},
    enableHover = false,
    needsRefresh = false,
    bagsView = "table",
    PUBLISH_INTERVAL = 30,
    lastPublishTime = 0,
    contextMenu = { visible = false, item = nil, source = nil, x = 0, y = 0, peers = {}, selectedPeer = nil, },
    multiSelectMode = false,
    selectedItems = {},
    showMultiTradePanel = false,
    multiTradeTarget = "",
}

local EQ_ICON_OFFSET = 500
local ICON_WIDTH = 20
local ICON_HEIGHT = 20
local animItems = mq.FindTextureAnimation("A_DragItem")
local animBox   = mq.FindTextureAnimation("A_RecessedBox") -- Used for optional background
local server = mq.TLO.MacroQuest.Server()
local CBB_ICON_WIDTH       = 40
local CBB_ICON_HEIGHT      = 40
local CBB_COUNT_X_OFFSET   = 39 -- Offset for stack count text (X)
local CBB_COUNT_Y_OFFSET   = 23 -- Offset for stack count text (Y)
local CBB_BAG_ITEM_SIZE    = 40 -- Size of each item cell for layout calculation
local CBB_MAX_SLOTS_PER_BAG = 10 -- Assumption for bag size if not otherwise known
local show_item_background_cbb = true -- Toggle for the cbb style background

local function refreshPeerCache()
    local now = os.time()
    if now - lastCacheTime > 2 then  -- throttle updates every 2 seconds
        peerCache = {}

        for peerID, inv in pairs(inventory_actor.peer_inventories) do
            local server = inv.server or "Unknown"
            peerCache[server] = peerCache[server] or {}
            table.insert(peerCache[server], inv)
        end

        lastCacheTime = now
    end
end

local function toggleItemSelection(item, uniqueKey, sourcePeer)
    if not inventoryUI.selectedItems[uniqueKey] then
        inventoryUI.selectedItems[uniqueKey] = {
            item = item,
            key = uniqueKey,
            source = sourcePeer or mq.TLO.Me.Name() -- fallback
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

function drawItemIcon(iconID, width, height)
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
    ImGui.PushStyleColor(ImGuiCol.Button,       0, 0, 0, 0)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered,0, 0.3, 0, 0.2)
    ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0, 0.3, 0, 0.3)
    ImGui.Button("##empty_" .. cell_id, CBB_ICON_WIDTH, CBB_ICON_HEIGHT)
    ImGui.PopStyleColor(3)

    if mq.TLO.Cursor.ID() and ImGui.IsItemClicked(ImGuiMouseButton.Left) then
        local cursorItemTLO = mq.TLO.Cursor
        local pack_number, slotIndex = cell_id:match("bag_(%d+)_slot_(%d+)")
        if pack_number and slotIndex then
            pack_number = tonumber(pack_number)
            slotIndex = tonumber(slotIndex)
            --mq.cmdf("/echo [DEBUG] Drop Attempt: pack_number=%s, slotIndex=%s", tostring(pack_number), tostring(slotIndex))
            if pack_number >= 1 and pack_number <= 12 and slotIndex >= 1 then
                if inventoryUI.selectedPeer == mq.TLO.Me.Name() then
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
                            --mq.cmdf("/echo [DEBUG] Optimistically replacing existing item in UI data: Bag %d, Slot %d", pack_number, slotIndex)
                            bagItems[i] = newItem -- Replace existing entry
                            replaced = true
                            break
                        end
                    end

                    if not replaced then
                        --mq.cmdf("/echo [DEBUG] Optimistically adding new item to UI data: Bag %d, Slot %d", pack_number, slotIndex)
                        table.insert(inventoryUI.inventoryData.bags[pack_number], newItem)
                    end

                else
                    mq.cmd("/echo Cannot directly place items in another character's bag.")
                end
            else
                mq.cmdf("/echo [ERROR] Invalid pack/slot ID derived from cell_id: %s (pack_number=%s, slotIndex=%s)", cell_id, tostring(pack_number), tostring(slotIndex))
            end
        else
            mq.cmd("/echo [ERROR] Could not parse pack/slot ID from cell_id: " .. cell_id)
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
    ImGui.PushStyleColor(ImGuiCol.Button,       0, 0, 0, 0)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered,0, 0.3, 0, 0.2)
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

        --mq.cmdf("/echo [DEBUG] Live Pickup Click: mainSlot=%s, subSlot=%s", tostring(mainSlot), tostring(subSlot))

        if mainSlot >= 23 and mainSlot <= 34 then -- It's in a bag slot
            local pack_number = mainSlot - 22 -- Convert 23-34 to 1-12
            if subSlot == -1 then
                mq.cmdf('/shift /itemnotify "%s" leftmouseup', item_tlo.Name())
                mq.cmd('/echo [WARN] Pickup fallback: Used item name for item not in subslot.')
            else
                local command_slotid = subSlot + 1 -- Convert 0-based TLO subslot to 1-based command slot
                mq.cmdf("/shift /itemnotify in pack%d %d leftmouseup", pack_number, command_slotid)
            end
        else
            mq.cmd("/echo [ERROR] Cannot perform standard bag pickup for item in slot " .. tostring(mainSlot))
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
    ImGui.PushStyleColor(ImGuiCol.Button,       0, 0, 0, 0)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered,0, 0.3, 0, 0.2)
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
        --mq.cmdf("/echo [DEBUG] Clicked '%s': DB bagid=%s, DB slotid=%s", item.name, tostring(bagid_raw), tostring(slotid_raw))

        local pack_number = tonumber(bagid_raw)
        local command_slotid = tonumber(slotid_raw)

        if not pack_number or not command_slotid then
            mq.cmdf("/echo [ERROR] Missing or non-numeric bagid/slotid in database item: %s (bagid_raw=%s, slotid_raw=%s)", item.name, tostring(bagid_raw), tostring(slotid_raw))
        else
            --mq.cmdf("/echo [DEBUG] Interpreted: pack_number=%s, command_slotid=%s", tostring(pack_number), tostring(command_slotid))

            if pack_number >= 1 and pack_number <= 12 and command_slotid >= 1 then
                if inventoryUI.selectedPeer == mq.TLO.Me.Name() then
                    mq.cmdf("/itemnotify in pack%d %d leftmouseup", pack_number, command_slotid)

                    if inventoryUI.inventoryData.bags[pack_number] then
                        local bagItems = inventoryUI.inventoryData.bags[pack_number]
                        for i = #bagItems, 1, -1 do 
                            if tonumber(bagItems[i].slotid) == command_slotid then
                                --mq.cmdf("/echo [DEBUG] Optimistically removing item from UI data: Bag %d, Slot %d", pack_number, command_slotid)
                                table.remove(bagItems, i)
                                break
                            end
                        end
                    end
                else
                    mq.cmd("/echo Cannot directly pick up items from another character's bag.")
                end
            else
                mq.cmdf("/echo [ERROR] Invalid pack/slot ID check failed for item: %s (pack_number=%s, command_slotid=%s)", item.name, tostring(pack_number), tostring(command_slotid))
            end
        end
    end
end

local function InventoryToggleButton()
    ImGui.SetNextWindowSize(60, 60, ImGuiCond.Always)
    ImGui.Begin("EZInvToggle", nil, bit.bor(ImGuiWindowFlags.NoDecoration, ImGuiWindowFlags.AlwaysAutoResize, ImGuiWindowFlags.NoBackground))

    local time = mq.gettime() / 1000
    local pulse = (math.sin(time * 3) + 1) * 0.5
    local base_color = inventoryUI.visible and {0.2, 0.8, 0.2, 1.0} or {0.7, 0.2, 0.2, 1.0}
    local hover_color = {
        base_color[1] + 0.2 * pulse,
        base_color[2] + 0.2 * pulse,
        base_color[3] + 0.2 * pulse,
        1.0
    }

    ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, 10)
    ImGui.PushStyleColor(ImGuiCol.Button,        ImVec4(base_color[1], base_color[2], base_color[3], 0.85))
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, ImVec4(hover_color[1], hover_color[2], hover_color[3], 1.0))
    ImGui.PushStyleColor(ImGuiCol.ButtonActive,  ImVec4(base_color[1] * 0.8, base_color[2] * 0.8, base_color[3] * 0.8, 1.0))

    local icon = icons.FA_ITALIC or "Inv"
    if ImGui.Button(icon, 48, 48) then
        inventoryUI.visible = not inventoryUI.visible
    end

    if ImGui.IsItemHovered() then
        ImGui.SetTooltip(inventoryUI.visible and "Hide Inventory" or "Show Inventory")
    end

    ImGui.PopStyleColor(3)
    ImGui.PopStyleVar()
    ImGui.End()
end

--------------------------------------------------
-- Helper: Update List of Connected Peers
--------------------------------------------------
function updatePeerList()
    inventoryUI.peers = {}
    inventoryUI.servers = {}

    local myName = mq.TLO.Me.Name()
    local selfEntry = {
        name = myName,
        server = server,
        isMailbox = true,
        data = inventory_actor.gather_inventory()
    }
    table.insert(inventoryUI.peers, selfEntry)

    for _, invData in pairs(inventory_actor.peer_inventories) do
        if invData.name ~= myName then
            local peerEntry = {
                name = invData.name or "Unknown",
                server = invData.server,
                isMailbox = true,
                data = invData
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
function refreshInventoryData()
    inventoryUI.inventoryData = { equipped = {}, bags = {}, bank = {} }

    for _, peer in ipairs(inventoryUI.peers) do
        if peer.name == inventoryUI.selectedPeer then
            if peer.data then
                inventoryUI.inventoryData = peer.data
            elseif peer.name == mq.TLO.Me.Name() then
                inventoryUI.inventoryData = inventory_actor.gather_inventory()
            end
            break
        end
    end
end

--------------------------------------------------
-- Helper: Load inventory data from the mailbox.
--------------------------------------------------
function loadInventoryData(peer)
    inventoryUI.inventoryData = { equipped = {}, bags = {}, bank = {} }

    if peer.isMailbox and peer.data then
        inventoryUI.inventoryData = peer.data
    elseif peer.name == mq.TLO.Me.Name() then
        inventoryUI.inventoryData = inventory_actor.gather_inventory()
    end
end

--------------------------------------------------
-- Helper: Get the slot name from slot ID
--------------------------------------------------
local function getSlotNameFromID(slotID)
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
        [21] = "Power Source",
        [22] = "Ammo"
    }
    return slotNames[slotID] or "Unknown Slot"
end

--------------------------------------------------
-- Function: Compare slot across all peers
--------------------------------------------------
function compareSlotAcrossPeers(slotID)
    local results = {}

    for _, invData in pairs(inventory_actor.peer_inventories) do
        local peerName = invData.name or "Unknown"
        local peerServer = invData.server or "Unknown"

        for _, item in ipairs(invData.equipped or {}) do
            if tonumber(item.slotid) == slotID then
                table.insert(results, {
                    peerName = peerName,
                    peerServer = peerServer,
                    item = item
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

--------------------------------------------------
-- Function: Search Across All Peers
--------------------------------------------------
function searchAcrossPeers()
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
    
    -- Fix the typo here
    for _, invData in pairs(inventory_actor.peer_inventories) do
        local function searchItems(items, sourceLabel)
            -- For equipped and bank items (simple arrays)
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
            -- For inventory/bag items (nested structure)
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

--------------------------------------------------
-- Context Menu Functions
--------------------------------------------------

function showContextMenu(item, sourceChar, mouseX, mouseY)
    if not item then
        mq.cmd("/echo [ERROR] Cannot show context menu for nil item")
        return
    end

    if not sourceChar then
        mq.cmd("/echo [ERROR] Cannot show context menu - source character is nil")
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

    --mq.cmdf("/echo [DEBUG] Context menu opened for %s from %s", (itemCopy.name or "Unknown Item"), (sourceChar or "Unknown Source"))
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
        mq.cmd("/echo [DEBUG] Context menu item is nil, closing menu")
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
        
        -- Examine option
        if ImGui.MenuItem("Examine") then
            -- Safe access to item data
            if inventoryUI.contextMenu.item and inventoryUI.contextMenu.item.itemlink then
                local links = mq.ExtractLinks(inventoryUI.contextMenu.item.itemlink)
                if links and #links > 0 then
                    mq.ExecuteTextLink(links[1])
                else
                    mq.cmd('/echo No item link found in the database.')
                end
            else
                mq.cmd('/echo No item data available for examination.')
            end
            hideContextMenu()
        end
        
        -- Single item trade options (only if not in multi-select mode)
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
                                initiateProxyTrade(inventoryUI.contextMenu.item, 
                                                  inventoryUI.contextMenu.source, 
                                                  peerName)
                            else
                                mq.cmd('/echo Cannot trade - item data is missing.')
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
    
    -- Check for clicks outside the context menu to close it
    if ImGui.IsMouseClicked(ImGuiMouseButton.Left) and not ImGui.IsWindowHovered(ImGuiHoveredFlags.AnyWindow) then
        hideContextMenu()
    end
end

-- Function to initiate the proxy trade
function initiateProxyTrade(item, sourceChar, targetChar)
    mq.cmdf("/echo Initiating trade: %s from %s to %s", item.name, sourceChar, targetChar)
    
    local peerRequest = {
        name = item.name,
        to = targetChar,
        fromBank = item.bankslotid ~= nil,
        bagid = item.bagid,
        slotid = item.slotid,
        bankslotid = item.bankslotid,
    }
    
    inventory_actor.send_inventory_command(sourceChar, "proxy_give", {json.encode(peerRequest)})
    mq.cmdf("/echo Trade request sent: %s will give %s to %s", sourceChar, item.name, targetChar)
end

function initiateMultiItemTrade(targetChar)
    --mq.cmdf("/echo [DEBUG] initiateMultiItemTrade called for target: %s", tostring(targetChar))
    local tradableItems = {}
    local noDropItems = {}
    local sourceChar = nil
    local sourceCounts = {}  -- Track items per source character
    
    for _, selectedData in pairs(inventoryUI.selectedItems) do
        local item = selectedData.item
        local itemSource = selectedData.source or inventoryUI.selectedPeer or mq.TLO.Me.Name()
        sourceCounts[itemSource] = (sourceCounts[itemSource] or 0) + 1
        
        if item.nodrop == 0 then
            table.insert(tradableItems, {
                item = item,
                source = itemSource
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
        sourceChar = inventoryUI.contextMenu.source or inventoryUI.selectedPeer or mq.TLO.Me.Name()
    end
    
    if #noDropItems > 0 then
        mq.cmdf("/echo Warning: %d selected items are No Drop and cannot be traded", #noDropItems)
    end
    
    if #tradableItems > 0 and sourceChar and targetChar then
        mq.cmdf("/echo Initiating multi-item trade: %d items from %s to %s", #tradableItems, sourceChar, targetChar)
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
                    items = {}
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
                
                inventory_actor.send_inventory_command(source, "proxy_give_batch", {json.encode(batchRequest)})
                mq.cmdf("/echo Multi-trade request sent: %d items from %s to %s", #items, source, targetChar)
            end
        end
    else
        if #tradableItems == 0 then
            mq.cmd("/echo No tradable items selected")
        elseif not sourceChar then
            mq.cmd("/echo Cannot determine source character for trade")
        elseif not targetChar then
            mq.cmd("/echo No target character specified")
        end
    end
    
    clearItemSelection()
end

function renderMultiTradePanel()
    if not inventoryUI.showMultiTradePanel then return end
    
    ImGui.SetNextWindowSize(500, 400, ImGuiCond.Once)
    local isOpen = ImGui.Begin("Multi-Item Trade Panel", nil, ImGuiWindowFlags.None)
    
    if isOpen then
        local selectedCount = getSelectedItemCount()
        ImGui.Text(string.format("Selected Items: %d", selectedCount))
        ImGui.Separator()
        if ImGui.BeginChild("SelectedItemsList", 0, 250, true) then
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
                mq.cmdf("/echo [UI] Execute Multi-Trade for %s", inventoryUI.multiTradeTarget)
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
    
    if isOpen then ImGui.End() end
end

function renderMultiSelectIndicator()
    if inventoryUI.multiSelectMode then
        local selectedCount = getSelectedItemCount()
        inventoryUI.showMultiTradePanel = true
    end
end


--------------------------------------------------
-- Main render function.
--------------------------------------------------
function inventoryUI.render()
    if not inventoryUI.visible then return end

    local windowFlags = ImGuiWindowFlags.None
    if inventoryUI.windowLocked then
        windowFlags = windowFlags + ImGuiWindowFlags.NoMove + ImGuiWindowFlags.NoResize
    end

    if ImGui.Begin("Inventory Window", nil, windowFlags) then
        -- Server selection dropdown
        inventoryUI.selectedServer = inventoryUI.selectedServer or server
        ImGui.Text("Select Server:")
        ImGui.SameLine()
        ImGui.SetNextItemWidth(150)
        if ImGui.BeginCombo("##ServerCombo", inventoryUI.selectedServer or "None") then
            local serverList = {}
            for srv, _ in pairs(inventoryUI.servers) do
                table.insert(serverList, srv)
            end
            table.sort(serverList)
            for i, srv in ipairs(serverList) do
                ImGui.PushID(string.format("server_%s_%d", srv, i))
                if ImGui.Selectable(srv, inventoryUI.selectedServer == srv) then
                    inventoryUI.selectedServer = srv
                    -- Reset selectedPeer if not valid for the new server
                    local validPeer = false
                    for _, peer in ipairs(inventoryUI.servers[srv] or {}) do
                        if peer.name == inventoryUI.selectedPeer then
                            validPeer = true
                            break
                        end
                    end
                    if not validPeer then
                        inventoryUI.selectedPeer = nil
                    end
                end
                if inventoryUI.selectedServer == srv then
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
        local displayPeer = inventoryUI.selectedPeer or "Select Peer"
        
        if inventoryUI.selectedServer and ImGui.BeginCombo("##PeerCombo", displayPeer) then
            local peers = peerCache[inventoryUI.selectedServer] or {}
            table.sort(peers, function(a, b)
                return (a.name or ""):lower() < (b.name or ""):lower()
            end)
            for i, invData in ipairs(peers) do
                local peer = {
                    name = invData.name or "Unknown",
                    server = invData.server,
                    isMailbox = true,
                    data = invData,
                }
                ImGui.PushID(string.format("peer_%s_%s_%d", peer.name, peer.server, i))
                local isSelected = inventoryUI.selectedPeer == peer.name
                if ImGui.Selectable(peer.name, isSelected) then
                    inventoryUI.selectedPeer = peer.name
                    loadInventoryData(peer)
                end
                if isSelected then
                    ImGui.SetItemDefaultFocus()
                end
                ImGui.PopID()
            end
            ImGui.EndCombo()
        end        

        ImGui.SameLine()
        if ImGui.Button("Give Item") then
            inventoryUI.showGiveItemPanel = not inventoryUI.showGiveItemPanel
        end

        local cursorPosX = ImGui.GetCursorPosX()
        local iconSpacing = 10
        local iconSize = 24
        local totalIconWidth = (iconSize + iconSpacing) * 3 + 10

        local rightAlignX = ImGui.GetWindowWidth() - totalIconWidth - 10
        ImGui.SameLine(rightAlignX)

        local floatIcon = inventoryUI.showToggleButton and icons.FA_EYE or icons.FA_EYE_SLASH
        if ImGui.Button(floatIcon, iconSize, iconSize) then
            inventoryUI.showToggleButton = not inventoryUI.showToggleButton
        end
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip(inventoryUI.showToggleButton and "Hide Floating Button" or "Show Floating Button")
        end

        ImGui.SameLine()

        local lockIcon = inventoryUI.windowLocked and icons.FA_LOCK or icons.FA_UNLOCK
        if ImGui.Button(lockIcon, iconSize, iconSize) then
            inventoryUI.windowLocked = not inventoryUI.windowLocked
        end
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip(inventoryUI.windowLocked and "Unlock window" or "Lock window")
        end

        ImGui.SameLine()
        if ImGui.Button("Close") then
            inventoryUI.visible = false
        end


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
    -- Equipped Items Section
    ------------------------------
    
    local avail = ImGui.GetContentRegionAvail()
    ImGui.BeginChild("TabbedContentRegion", x, y, true, ImGuiChildFlags.Border)
    
    if ImGui.BeginTabBar("InventoryTabs") then

        if ImGui.BeginTabItem("Equipped") then
            if ImGui.BeginTabBar("EquippedViewTabs") then
                if ImGui.BeginTabItem("Table View") then
                    inventoryUI.equipView = "table"

                    if ImGui.BeginChild("EquippedScrollRegion", 0, 0, true, ImGuiChildFlags.HorizontalScrollbar) then

                        ImGui.Text("Show Columns:")
                        ImGui.SameLine()
                        inventoryUI.showAug1 = ImGui.Checkbox("Aug 1", inventoryUI.showAug1)
                        ImGui.SameLine()
                        inventoryUI.showAug2 = ImGui.Checkbox("Aug 2", inventoryUI.showAug2)
                        ImGui.SameLine()
                        inventoryUI.showAug3 = ImGui.Checkbox("Aug 3", inventoryUI.showAug3)
                        ImGui.SameLine()
                        inventoryUI.showAug4 = ImGui.Checkbox("Aug 4", inventoryUI.showAug4)
                        ImGui.SameLine()
                        inventoryUI.showAug5 = ImGui.Checkbox("Aug 5", inventoryUI.showAug5)
                        ImGui.SameLine()
                        inventoryUI.showAug6 = ImGui.Checkbox("Aug 6", inventoryUI.showAug6)

                        local numColumns = 2 -- Icon and Item Name are always visible
                        local visibleAugs = 0
                        local augVisibility = {
                            inventoryUI.showAug1,
                            inventoryUI.showAug2,
                            inventoryUI.showAug3,
                            inventoryUI.showAug4,
                            inventoryUI.showAug5,
                            inventoryUI.showAug6
                        }

                        for _, isVisible in ipairs(augVisibility) do
                            if isVisible then
                                visibleAugs = visibleAugs + 1
                                numColumns = numColumns + 1
                            end
                        end

                        local availableWidth = ImGui.GetWindowContentRegionWidth()
                        local iconWidth = 30 -- Fixed width for the icon column
                        local itemWidth = 150 -- Fixed width for the item name column
                        local augWidth = 0

                        if visibleAugs > 0 then
                            augWidth = math.max(80, (availableWidth - iconWidth - itemWidth) / visibleAugs)
                        end

                        if ImGui.BeginTable("EquippedTable", numColumns, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.Resizable + ImGuiTableFlags.SizingStretchProp) then
                            ImGui.TableSetupColumn("Icon", ImGuiTableColumnFlags.WidthFixed, iconWidth) -- First column for item icon
                            ImGui.TableSetupColumn("Item", ImGuiTableColumnFlags.WidthFixed, itemWidth) -- Second column for item name

                            for i = 1, 6 do
                                if augVisibility[i] then
                                    ImGui.TableSetupColumn("Aug " .. i, ImGuiTableColumnFlags.WidthStretch, 1.0)
                                end
                            end

                            ImGui.TableHeadersRow()

                            local function renderEquippedTableRow(item, augVisibility)
                                -- Column 1: Item Icon
                                ImGui.TableNextColumn()
                                if item.icon and item.icon ~= 0 then
                                    drawItemIcon(item.icon)
                                else
                                    ImGui.Text("N/A")
                                end
                            
                                -- Column 2: Item Name (Clickable)
                                ImGui.TableNextColumn()
                                if ImGui.Selectable(item.name) then
                                    local links = mq.ExtractLinks(item.itemlink)
                                    if links and #links > 0 then
                                        mq.ExecuteTextLink(links[1])
                                    else
                                        mq.cmd('/echo No item link found in the database.')
                                    end
                                end

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
                                                    mq.cmd('/echo No aug link found in the database.')
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                            
                            for _, item in ipairs(inventoryUI.inventoryData.equipped) do
                                if matchesSearch(item) then
                                    ImGui.TableNextRow()
                                    ImGui.PushID(item.name or "unknown_item")
                                    local ok, err = pcall(renderEquippedTableRow, item, augVisibility)
                                    ImGui.PopID()
                                    if not ok then
                                        mq.cmdf("/echo Error rendering item row: %s", err)
                                    end
                                end
                            end
                                                    
                            ImGui.EndTable()
                        end
                    end
                    ImGui.EndChild()
                    ImGui.EndTabItem()
                end

                        -- Visual Layout Tab
                        if ImGui.BeginTabItem("Visual") then

                            ImGui.Dummy(235, 0) 

                            -- Add armor type filter dropdown
                            local armorTypes = { "All", "Plate", "Chain", "Cloth", "Leather" }
                            inventoryUI.armorTypeFilter = inventoryUI.armorTypeFilter or "All"  -- Default filter
                            
                            ImGui.SameLine()  
                            ImGui.Text("Armor Type:")
                            ImGui.SameLine()
                            ImGui.SetNextItemWidth(100)
                            if ImGui.BeginCombo("##ArmorTypeFilter", inventoryUI.armorTypeFilter) then
                                for _, armorType in ipairs(armorTypes) do
                                    if ImGui.Selectable(armorType, inventoryUI.armorTypeFilter == armorType) then
                                        inventoryUI.armorTypeFilter = armorType
                                    end
                                end
                                ImGui.EndCombo()
                            end

                            ImGui.Separator()

                            -- Define the slot layout (unchanged)
                            local slotLayout = {
                                {1, 2, 3, 4},       -- Row 1: Left Ear, Face, Neck, Shoulders
                                {17, "", "", 5},    -- Row 2: Primary, Empty, Empty, Ear 1
                                {7, "", "", 8},     -- Row 3: Arms, Empty, Empty, Wrist 1
                                {20, "", "", 6},    -- Row 4: Range, Empty, Empty, Ear 2
                                {9, "", "", 10},    -- Row 5: Back, Empty, Empty, Wrist 2
                                {18, 12, 0, 19},    -- Row 6: Secondary, Chest, Ammo, Waist
                                {"", 15, 16, 21},   -- Row 7: Empty, Legs, Feet, Charm
                                {13, 14, 11, 22}    -- Row 8: Finger 1, Finger 2, Hands, Power Source
                            }

                            local equippedItems = {}
                            for _, item in ipairs(inventoryUI.inventoryData.equipped) do
                                equippedItems[item.slotid] = item
                            end

                            inventoryUI.selectedItem = inventoryUI.selectedItem or nil

                            inventoryUI.hoverStates = {}

                            inventoryUI.openItemWindow = inventoryUI.openItemWindow or nil

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

                            -- Column 1: Equipped Table
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
                                            -- Make sure button size matches column size
                                            local clicked = ImGui.InvisibleButton("##" .. slotButtonID, 45, 45)
                                            local buttonMinX, buttonMinY = ImGui.GetItemRectMin()
                                            ImGui.SetCursorScreenPos(buttonMinX, buttonMinY)
                                            drawItemIcon(item.icon, 40, 40)

                                            if clicked then
                                                if mq.TLO.Window("ItemDisplayWindow").Open() then
                                                    mq.TLO.Window("ItemDisplayWindow").DoClose()
                                                    inventoryUI.openItemWindow = nil
                                                end
                                                inventoryUI.selectedSlotID = slotID
                                                inventoryUI.selectedSlotName = slotName
                                                inventoryUI.compareResults = compareSlotAcrossPeers(slotID)
                                            end
                                        else
                                            -- Center text for empty slots
                                            local textWidth = ImGui.CalcTextSize(slotName)
                                            local cellWidth = 40
                                            local xOffset = (cellWidth - textWidth) * 0.5
                                            ImGui.SetCursorPosX(ImGui.GetCursorPosX() + xOffset)
                                            ImGui.Text(slotName)
                                            
                                            if ImGui.IsItemClicked() then
                                                if mq.TLO.Window("ItemDisplayWindow").Open() then
                                                    mq.TLO.Window("ItemDisplayWindow").DoClose()
                                                    inventoryUI.openItemWindow = nil
                                                end
                                                inventoryUI.selectedSlotID = slotID
                                                inventoryUI.selectedSlotName = slotName
                                                inventoryUI.compareResults = compareSlotAcrossPeers(slotID)
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
                                                    mq.cmdf("/echo Error drawing slot %s: %s", tostring(slotID), err)
                                                end
                                            else
                                                ImGui.Text("")
                                            end
                                        end
                                    end                                    
                                    ImGui.EndTable()
                                end
                            end)                            

                            -- Column 2: Comparison Table
                            ImGui.NextColumn()

                            if inventoryUI.selectedSlotID then
                                ImGui.Text("Comparing " .. inventoryUI.selectedSlotName .. " slot across all characters:")
                                ImGui.Separator()

                                if #inventoryUI.compareResults == 0 then
                                    ImGui.Text("No data available for comparison.")
                                else
                                    -- Create a table to display the comparison results
                                    if ImGui.BeginTable("ComparisonTable", 3, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.Resizable) then
                                        ImGui.TableSetupColumn("Character", ImGuiTableColumnFlags.WidthFixed, 100)
                                        ImGui.TableSetupColumn("Icon", ImGuiTableColumnFlags.WidthFixed, 40)
                                        ImGui.TableSetupColumn("Item", ImGuiTableColumnFlags.WidthStretch)
                                        ImGui.TableHeadersRow()

                                        local peerMap = {}
                                        for _, result in ipairs(inventoryUI.compareResults) do
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
                                        
                                        for idx, result in ipairs(inventoryUI.compareResults) do
                                            if result.peerName then
                                                table.insert(processedResults, result)
                                                --mq.cmdf("/echo [DEBUG] Added result for peer with item: %s", result.peerName)
                                            end
                                        end

                                        for _, peerName in ipairs(allConnectedPeers) do
                                            if not peerMap[peerName] then
                                                table.insert(processedResults, {
                                                    peerName = peerName,
                                                    item = nil
                                                })
                                                --mq.cmdf("/echo [DEBUG] Added empty result for peer: %s", peerName)
                                            end
                                        end
                                        
                                        table.sort(processedResults, function(a, b) 
                                            return (a.peerName or "zzz") < (b.peerName or "zzz") 
                                        end)

                                        for idx, result in ipairs(processedResults) do
                                            local safePeerName = result.peerName or "UnknownPeer"
                                            ImGui.PushID(safePeerName .. "_" .. tostring(idx))

                                            local showRow = true
                                            if result.peerName then
                                                local peerSpawn = mq.TLO.Spawn("pc = " .. result.peerName)
                                                if peerSpawn.ID() then
                                                    local peerClass = peerSpawn.Class.ShortName() or "UNK"
                                                    local armorType = getArmorTypeByClass(peerClass)
                                                    showRow = (inventoryUI.armorTypeFilter == "All" or armorType == inventoryUI.armorTypeFilter)
                                                end
                                            end

                                            if showRow then
                                                ImGui.TableNextRow()

                                                ImGui.TableNextColumn()
                                                if ImGui.Selectable(result.peerName) then
                                                    inventory_actor.send_inventory_command(result.peerName, "foreground", {})
                                                    mq.cmdf("/echo Bringing %s to the foreground...", result.peerName)
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
                                                else
                                                    ImGui.Text("(empty)")
                                                end
                                            end
                                            ImGui.PopID()
                                        end
                                        ImGui.EndTable()
                                    end
                                end
                            else
                                ImGui.Text("Click on a slot to compare it across all characters.")
                            end

                            ImGui.Columns(1)

                            if not hoveringAnyItem and inventoryUI.openItemWindow then
                                if mq.TLO.Window("ItemDisplayWindow").Open() then
                                    mq.TLO.Window("ItemDisplayWindow").DoClose()
                                end
                                inventoryUI.openItemWindow = nil
                            end

                            ImGui.EndTabItem()
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
                    inventoryUI.bagsView = "table"
                    matchingBags = {}
                    for bagid, bagItems in pairs(inventoryUI.inventoryData.bags) do
                        for _, item in ipairs(bagItems) do
                            if matchesSearch(item) then
                                matchingBags[bagid] = true
                                break
                            end
                        end
                    end
                    inventoryUI.globalExpandAll = inventoryUI.globalExpandAll or false
                    inventoryUI.bagOpen = inventoryUI.bagOpen or {}
                    local searchChanged = searchText ~= (inventoryUI.previousSearchText or "")
                    inventoryUI.previousSearchText = searchText
                    
                    -- Multi-select controls
                    if inventoryUI.multiSelectMode then
                        local selectedCount = getSelectedItemCount()
                        ImGui.PushStyleColor(ImGuiCol.Text, 0, 1, 0, 1) -- Green text
                        ImGui.Text(string.format("Multi-Select Mode: %d items selected", selectedCount))
                        ImGui.PopStyleColor()
                        ImGui.SameLine()
                        if ImGui.Button("Exit Multi-Select") then
                            inventoryUI.multiSelectMode = false
                            clearItemSelection()
                        end
                        if selectedCount > 0 then
                            ImGui.SameLine()
                            if ImGui.Button("Show Trade Panel") then
                                inventoryUI.showMultiTradePanel = true
                            end
                            ImGui.SameLine()
                            if ImGui.Button("Clear Selection") then
                                clearItemSelection()
                            end
                        end
                        ImGui.Separator()
                    end
                    
                    local checkboxLabel = inventoryUI.globalExpandAll and "Collapse All Bags" or "Expand All Bags"
                    if ImGui.Checkbox(checkboxLabel, inventoryUI.globalExpandAll) ~= inventoryUI.globalExpandAll then
                        inventoryUI.globalExpandAll = not inventoryUI.globalExpandAll
                        for bagid, _ in pairs(inventoryUI.inventoryData.bags) do
                            inventoryUI.bagOpen[bagid] = inventoryUI.globalExpandAll
                        end
                    end
                    
                    local bagColumns = {}
                    for bagid, bagItems in pairs(inventoryUI.inventoryData.bags) do
                        table.insert(bagColumns, { bagid = bagid, items = bagItems })
                    end
                    table.sort(bagColumns, function(a, b) return a.bagid < b.bagid end)
                    
                    for _, bag in ipairs(bagColumns) do
                        local bagid = bag.bagid
                        local bagName = bag.items[1] and bag.items[1].bagname or ("Bag " .. tostring(bagid))
                        bagName = string.format("%s (%d)", bagName, bagid)
                        local hasMatchingItem = matchingBags[bagid] or false
                        if searchChanged and hasMatchingItem and searchText ~= "" then
                            inventoryUI.bagOpen[bagid] = true
                        end
                        if inventoryUI.bagOpen[bagid] ~= nil then
                            ImGui.SetNextItemOpen(inventoryUI.bagOpen[bagid])
                        end
                        local isOpen = ImGui.CollapsingHeader(bagName)
                        inventoryUI.bagOpen[bagid] = isOpen
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
                                        
                                        -- Create unique key for this item
                                        local uniqueKey = string.format("%s_%s_%s_%s", 
                                            inventoryUI.selectedPeer or "unknown",
                                            item.name or "unnamed",
                                            bagid,
                                            item.slotid or "noslot")
                                        
                                        -- Icon column
                                        ImGui.TableNextColumn()
                                        if item.icon and item.icon > 0 then
                                            drawItemIcon(item.icon)
                                        else
                                            ImGui.Text("N/A")
                                        end
                                        
                                        -- Item Name column (with multi-select support)
                                        ImGui.TableNextColumn()
                                        local itemClicked = false
                                        
                                        if inventoryUI.multiSelectMode then
                                            -- Visual indication for selected items
                                            if inventoryUI.selectedItems[uniqueKey] then
                                                ImGui.PushStyleColor(ImGuiCol.Text, 0, 1, 0, 1) -- Green for selected
                                                itemClicked = ImGui.Selectable(item.name .. "##" .. bagid .. "_" .. i)
                                                ImGui.PopStyleColor()
                                            else
                                                itemClicked = ImGui.Selectable(item.name .. "##" .. bagid .. "_" .. i)
                                            end
                                            
                                            if itemClicked then
                                                toggleItemSelection(item, uniqueKey, inventoryUI.selectedPeer)
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
                                                    mq.cmd('/echo No item link found in the database.')
                                                end
                                            end
                                        end
                                        
                                        -- Right-click context menu
                                        if ImGui.IsItemClicked(ImGuiMouseButton.Right) then
                                            local mouseX, mouseY = ImGui.GetMousePos()
                                            showContextMenu(item, inventoryUI.selectedPeer, mouseX, mouseY)
                                        end
                                        
                                        -- Tooltip
                                        if ImGui.IsItemHovered() then
                                            ImGui.BeginTooltip()
                                            ImGui.Text(item.name)
                                            ImGui.Text("Qty: " .. tostring(item.qty))
                                            if inventoryUI.multiSelectMode then
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
                                        if inventoryUI.multiSelectMode then
                                            -- Show selection status in multi-select mode
                                            if inventoryUI.selectedItems[uniqueKey] then
                                                ImGui.PushStyleColor(ImGuiCol.Text, 0, 1, 0, 1)
                                                ImGui.Text("Selected")
                                                ImGui.PopStyleColor()
                                            else
                                                ImGui.Text("--")
                                            end
                                        else
                                            -- Normal action buttons
                                            if inventoryUI.selectedPeer == mq.TLO.Me.Name() then
                                                if ImGui.Button("Pickup##" .. item.name .. "_" .. tostring(item.slotid or i)) then
                                                    mq.cmdf('/shift /itemnotify "%s" leftmouseup', item.name)
                                                end
                                            else
                                                if item.nodrop == 0 then
                                                    local itemName = item.name or "Unknown"
                                                    local peerName = inventoryUI.selectedPeer or "Unknown"
                                                    local uniqueID = string.format("%s_%s_%d", itemName, peerName, i)
                                                    if ImGui.Button("Trade##" .. uniqueID) then
                                                        inventoryUI.showGiveItemPanel = true
                                                        inventoryUI.selectedGiveItem = itemName
                                                        inventoryUI.selectedGiveTarget = peerName
                                                        inventoryUI.selectedGiveSource = inventoryUI.selectedPeer
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
                    inventoryUI.bagsView = "visual"

                    show_item_background_cbb = ImGui.Checkbox("Show Item Background", show_item_background_cbb)
                    ImGui.Separator()

                    local content_width = ImGui.GetWindowContentRegionWidth()

                    local horizontal_padding = 3 
                    local item_width_plus_padding = CBB_BAG_ITEM_SIZE + horizontal_padding
                    local bag_cols = math.max(1, math.floor((content_width + horizontal_padding) / item_width_plus_padding))

                    ImGui.PushStyleVar(ImGuiStyleVar.ItemSpacing, ImVec2(horizontal_padding, 3)) -- Use the variable here too
                    if inventoryUI.selectedPeer == mq.TLO.Me.Name() then
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
                                    local show_this_item = item_tlo.ID() and (not searchText or searchText == "" or string.match(string.lower(item_tlo.Name()), string.lower(searchText)))
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
                        for bagid, bagItems in pairs(inventoryUI.inventoryData.bags) do
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
        if not inventoryUI.inventoryData.bank or #inventoryUI.inventoryData.bank == 0 then
            ImGui.Text("There's no loot here! Go visit a bank and re-sync!")
        else
            if ImGui.BeginTable("BankTable", 5, bit.bor(ImGuiTableFlags.BordersInnerV, ImGuiTableFlags.RowBg)) then
                ImGui.TableSetupColumn("Icon", ImGuiTableColumnFlags.WidthFixed, 40)
                ImGui.TableSetupColumn("Item", ImGuiTableColumnFlags.WidthStretch)
                ImGui.TableSetupColumn("Bank Slot", ImGuiTableColumnFlags.WidthFixed, 70)  -- bankslotid
                ImGui.TableSetupColumn("Item Slot", ImGuiTableColumnFlags.WidthFixed, 70)  -- slotid
                ImGui.TableSetupColumn("Action", ImGuiTableColumnFlags.WidthFixed, 70)     -- Pickup button
                ImGui.TableHeadersRow()

                for i, item in ipairs(inventoryUI.inventoryData.bank) do
                    if matchesSearch(item) then
                        ImGui.TableNextRow()
                        
                        -- Create a unique ID for this row using multiple attributes
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
                                mq.cmd('/echo No item link found in the database.')
                            end
                        end
                        ImGui.TableSetColumnIndex(2)
                        ImGui.Text(tostring(item.bankslotid or "N/A"))
                        ImGui.TableSetColumnIndex(3)
                        ImGui.Text(tostring(item.slotid or "N/A")) 
                        
                        ImGui.TableSetColumnIndex(4)
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
                                local sharedSlot = BankSlotId - 24  -- Convert to 1-2
                                if SlotId == -1 then
                                    -- Direct shared bank slot
                                    mq.cmdf("/shift /itemnotify sharedbank%d leftmouseup", sharedSlot)
                                else
                                    -- Item in a shared bank bag
                                    mq.cmdf("/shift /itemnotify in sharedbank%d %d leftmouseup", sharedSlot, SlotId)
                                end
                            else
                                mq.cmdf("/echo Unknown bank slot ID: %d", BankSlotId)
                            end
                        end
                        
                        if ImGui.IsItemHovered() then
                            ImGui.SetTooltip("You need to be near a banker to pick up this item")
                        end
                        
                        ImGui.PopID()
                    end
                end

                ImGui.EndTable()
            end
        end
        ImGui.EndTabItem()
    end

    ------------------------------
    -- All Bots Search Results Tab
    ------------------------------
        if ImGui.BeginTabItem("All Bots") then
            local filterOptions = { "All", "Equipped", "Inventory", "Bank" }
            inventoryUI.sourceFilter = inventoryUI.sourceFilter or "All"  -- Default filter

            ImGui.Text("Filter by Source:")
            ImGui.SameLine()
            if ImGui.BeginCombo("##SourceFilter", inventoryUI.sourceFilter) then
                for _, option in ipairs(filterOptions) do
                    if ImGui.Selectable(option, inventoryUI.sourceFilter == option) then
                        inventoryUI.sourceFilter = option  -- Update the filter
                    end
                end
                ImGui.EndCombo()
            end
            ImGui.SameLine()
            inventoryUI.filterNoDrop = inventoryUI.filterNoDrop or false
            inventoryUI.filterNoDrop = ImGui.Checkbox("Hide No Drop", inventoryUI.filterNoDrop)

            local results = searchAcrossPeers()
            if #results == 0 then
                ImGui.Text("No matching items found across all peers.")
            else
                
                local availableWidth = ImGui.GetContentRegionMax()
                local totalWidth = availableWidth

                local iconWidth = 30
                local qtyWidth = 40
                local actionWidth = 80

                local remainingWidth = totalWidth - iconWidth - qtyWidth - actionWidth
                local stretchTotalWeight = 60 + 50 + 60 + 200 
                local peerWidth = (remainingWidth * 60) / stretchTotalWeight
                local sourceWidth = (remainingWidth * 50) / stretchTotalWeight
                local slotWidth = (remainingWidth * 60) / stretchTotalWeight
                local itemWidth = (remainingWidth * 200) / stretchTotalWeight

                peerWidth = math.max(peerWidth, 60)
                sourceWidth = math.max(sourceWidth, 50)
                slotWidth = math.max(slotWidth, 60)
                itemWidth = math.max(itemWidth, 120)

                if ImGui.BeginTable("AllPeersTable", 7, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.Resizable + ImGuiTableFlags.ScrollX) then
                    ImGui.TableSetupColumn("Peer", ImGuiTableColumnFlags.WidthFixed, peerWidth)
                    ImGui.TableSetupColumn("Source", ImGuiTableColumnFlags.WidthFixed, sourceWidth)
                    ImGui.TableSetupColumn("Slot", ImGuiTableColumnFlags.WidthFixed, slotWidth)
                    ImGui.TableSetupColumn("Icon", ImGuiTableColumnFlags.WidthFixed, iconWidth)
                    ImGui.TableSetupColumn("Item", ImGuiTableColumnFlags.WidthStretch)
                    ImGui.TableSetupColumn("Qty", ImGuiTableColumnFlags.WidthFixed, qtyWidth)
                    ImGui.TableSetupColumn("Action", ImGuiTableColumnFlags.WidthFixed, actionWidth)
                    ImGui.TableHeadersRow()
                    local function getSlotInfo(item)
                        local searchTerm = (searchText or ""):lower()
                        if searchTerm ~= "" then
                            for i = 1, 6 do
                                local augField = "aug" .. i .. "Name"
                                if item[augField] and item[augField] ~= "" and item[augField]:lower():find(searchTerm) then
                                    return "Aug " .. i
                                end
                            end
                        end
                        if item.source == "Equipped" then
                            return getSlotNameFromID(item.slotid) or ("Slot " .. tostring(item.slotid))
                        elseif item.source == "Inventory" then
                            return "Bag " .. tostring(item.bagid) .. ", Slot " .. tostring(item.slotid)
                        elseif item.source == "Bank" then
                            return "Bank " .. tostring(item.bankslotid) .. ", Slot " .. tostring(item.slotid)
                        else
                            return tostring(item.slotid or "Unknown")
                        end
                    end
                    for idx, item in ipairs(results) do
                        if inventoryUI.sourceFilter == "All" or item.source == inventoryUI.sourceFilter then
                            if inventoryUI.filterNoDrop and item.nodrop == 1 then
                                goto continue
                            end
                            ImGui.TableNextRow()
                            local uniqueID = string.format("%s_%s_%d", 
                                item.peerName or "unknown", 
                                item.name or "unnamed", 
                                idx)
                            ImGui.PushID(uniqueID)
                            ImGui.TableNextColumn()
                            if ImGui.Selectable(item.peerName) then
                                inventory_actor.send_inventory_command(item.peerName, "foreground", {})
                                mq.cmdf("/echo Bringing %s to the foreground...", item.peerName)
                            end
                            ImGui.TableNextColumn()
                            ImGui.Text(item.source)
                            ImGui.TableNextColumn()
                            ImGui.Text(getSlotInfo(item))
                            ImGui.TableNextColumn()
                            if item.icon and item.icon ~= 0 then
                                drawItemIcon(item.icon)
                            else
                                ImGui.Text("N/A")
                            end
                            ImGui.TableNextColumn()
                            local itemClicked = false
                            local uniqueKey = string.format("%s_%s_%s_%s", 
                                item.peerName or "unknown",
                                item.name or "unnamed",
                                item.bagid or item.bankslotid or "noloc",
                                item.slotid or "noslot")
                            if inventoryUI.multiSelectMode then
                                if inventoryUI.selectedItems[uniqueKey] then
                                    ImGui.PushStyleColor(ImGuiCol.Text, 0, 1, 0, 1) 
                                    itemClicked = ImGui.Selectable(tostring(item.name or "Unknown"))
                                    ImGui.PopStyleColor()
                                else
                                    itemClicked = ImGui.Selectable(tostring(item.name or "Unknown"))
                                end
                                if itemClicked then
                                    toggleItemSelection(item, uniqueKey, item.peerName)
                                end
                                drawSelectionIndicator(uniqueKey, ImGui.IsItemHovered())
                            else
                                itemClicked = ImGui.Selectable(tostring(item.name or "Unknown"))
                                if itemClicked then
                                    local links = mq.ExtractLinks(item.itemlink)
                                    if links and #links > 0 then
                                        mq.ExecuteTextLink(links[1])
                                    else
                                        mq.cmd('/echo No item link found.')
                                    end
                                end
                            end
                            if ImGui.IsItemClicked(ImGuiMouseButton.Right) then
                                local mouseX, mouseY = ImGui.GetMousePos()
                                showContextMenu(item, item.peerName, mouseX, mouseY)
                            end
                            ImGui.TableNextColumn()
                            local qtyDisplay = tostring(item.qty or "?")
                            ImGui.Text(qtyDisplay)
                            if ImGui.IsItemHovered() then
                                ImGui.SetTooltip(string.format("qty: %s\nstack: %s\nraw: %s", 
                                    tostring(item.qty), 
                                    tostring(item.stack), 
                                    tostring(item.qty or item.stack or "nil")))
                            end
                            ImGui.TableNextColumn()
                            local peerName = item.peerName or "Unknown"
                            local itemName = item.name or "Unnamed"
                            
                            if peerName == mq.TLO.Me.Name() then
                                if ImGui.Button("Pickup##" .. uniqueID) then
                                    if item.source == "Bank" then
                                        local BankSlotId = tonumber(item.bankslotid) or 0
                                        local SlotId = tonumber(item.slotid) or -1
                                        
                                        --mq.cmdf("/echo [DEBUG] Bank pickup: Item=%s, BankSlot=%d, Slot=%d", itemName, BankSlotId, SlotId)
                                        
                                        if BankSlotId >= 1 and BankSlotId <= 24 then
                                            local adjustedBankSlot = BankSlotId
                                            if SlotId == -1 then
                                                mq.cmdf("/shift /itemnotify bank%d leftmouseup", adjustedBankSlot)
                                            else
                                                mq.cmdf("/shift /itemnotify in bank%d %d leftmouseup", adjustedBankSlot, SlotId)
                                            end
                                        elseif BankSlotId >= 25 and BankSlotId <= 26 then
                                            local sharedSlot = BankSlotId - 24
                                            if SlotId == -1 then
                                                mq.cmdf("/shift /itemnotify sharedbank%d leftmouseup", sharedSlot)
                                            else
                                                mq.cmdf("/shift /itemnotify in sharedbank%d %d leftmouseup", sharedSlot, SlotId)
                                            end
                                        else
                                            mq.cmdf("/echo Unknown bank slot ID: %d", BankSlotId)
                                        end
                                    else
                                        mq.cmdf('/shift /itemnotify "%s" leftmouseup', itemName)
                                    end
                                end
                            else
                                if item.nodrop == 0 then
                                    if ImGui.Button("Trade##" .. uniqueID) then
                                        inventoryUI.showGiveItemPanel = true
                                        inventoryUI.selectedGiveItem = itemName
                                        inventoryUI.selectedGiveTarget = peerName
                                        inventoryUI.selectedGiveSource = item.peerName
                                    end
                                    ImGui.SameLine()
                                    ImGui.Text("--")
                                    ImGui.SameLine()
                                    local buttonLabel = string.format("Give to %s##%s", inventoryUI.selectedPeer or "Unknown", uniqueID)
                                    ImGui.PushStyleColor(ImGuiCol.Button, 0, 0.6, 0, 1)        
                                    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0, 0.8, 0, 1) 
                                    ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0, 1.0, 0, 1) 
                                    if ImGui.Button(buttonLabel) then
                                        local giveRequest = {
                                            name = itemName,
                                            to = inventoryUI.selectedPeer,
                                            fromBank = item.source == "Bank",
                                            bagid = item.bagid,
                                            slotid = item.slotid,
                                            bankslotid = item.bankslotid,
                                        }
                                        inventory_actor.send_inventory_command(item.peerName, "proxy_give", {json.encode(giveRequest)})
                                        mq.cmdf("/echo Requested %s to give %s to %s", item.peerName, itemName, inventoryUI.selectedPeer)
                                    end
                                    ImGui.PopStyleColor(3)
                                else
                                    ImGui.Text("No Drop")
                                end
                            end                        
                            ImGui.PopID()
                            ::continue::
                        end
                    end
                    ImGui.EndTable()
                end
            end
            ImGui.EndTabItem()
        end
        ImGui.EndTabBar()
        ImGui.EndChild()
    end

        --------------------------------------------------------
        --- Item Exchange Popup
        --------------------------------------------------------
        
        inventoryUI.showGiveItemPanel = inventoryUI.showGiveItemPanel or false

    if inventoryUI.showGiveItemPanel then
        ImGui.SetNextWindowSize(400, 0, ImGuiCond.Once)
        local isOpen = ImGui.Begin("Give Item Panel", nil, ImGuiWindowFlags.AlwaysAutoResize)
        if isOpen then
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
                    fromBank = false,  -- Using inventory by default
                }
                
                -- Send the command to the SOURCE peer (owner of the item)
                inventory_actor.send_inventory_command(inventoryUI.selectedGiveSource, "proxy_give", {json.encode(peerRequest)})
                
                mq.cmdf("/echo Requesting %s to give %s to %s", 
                        inventoryUI.selectedGiveSource,
                        inventoryUI.selectedGiveItem, 
                        inventoryUI.selectedGiveTarget)
                
                inventoryUI.showGiveItemPanel = false -- Close the panel after sending
            else
                mq.cmd("/popcustom 5 Please select an item and a peer first.")
            end
        end
        ImGui.SameLine()
        if ImGui.Button("Close Panel") then
            inventoryUI.showGiveItemPanel = false
        end
            end
        if isOpen then ImGui.End() end
    end
    ImGui.End()
    renderContextMenu()
    renderMultiSelectIndicator()
    renderMultiTradePanel()
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
    { binding = "/ezinventory_ui", description = "Toggles the visibility of the inventory window." },
    { binding = "/ezinventory_help", description = "Displays this help information." },
}

local function displayHelp()
    mq.cmd("/echo === Inventory Script Help ===")
    for _, info in ipairs(helpInfo) do
        mq.cmdf("/echo %s: %s", info.binding, info.description)
    end
    mq.cmd("/echo ============================")
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
    local args = {...}
    inventory_actor.send_inventory_command(peer, command, args)
end)

-- Main function
local function main()
    displayHelp()

    local isForeground = mq.TLO.EverQuest.Foreground()

    inventoryUI.visible = isForeground

    if isForeground then
        if not inventory_actor.init() then
            print("\ar[EZInventory] Failed to initialize inventory actor\ax")
            return
        end
        
        mq.delay(10)
        
        if mq.TLO.Plugin("MQ2Mono").IsLoaded() then
            mq.cmd("/e3bcaa /lua run ezinventory")
            print("Broadcasting inventory startup via MQ2Mono to all connected clients...")
        elseif mq.TLO.Plugin("MQ2DanNet").IsLoaded() then
            mq.cmd("/dgaexecute /lua run ezinventory")
            print("Broadcasting inventory startup via DanNet to all connected clients...")
        elseif mq.TLO.Plugin("MQ2EQBC").IsLoaded() and mq.TLO.EQBC.Connected() then
            mq.cmd("/bca //lua run ezinventory")
            print("Broadcasting inventory startup via EQBC to all connected clients...")
        else
            print("\ar[EZInventory] Warning: Neither DanNet nor EQBC is available for broadcasting\ax")
        end
    else
        if not inventory_actor.init() then
            print("\ar[EZInventory] Failed to initialize inventory actor\ax")
            return
        end
    end
    
    inventory_actor.request_all_inventories()
    
    local myName = mq.TLO.Me.Name()
    inventoryUI.selectedPeer = myName

    local selfPeer = {
        name = myName,
        server = server,
        isMailbox = true,
        data = inventory_actor.gather_inventory()
    }
    loadInventoryData(selfPeer)

    while true do
        mq.doevents()

        local currentTime = os.time()
        if currentTime - inventoryUI.lastPublishTime > inventoryUI.PUBLISH_INTERVAL then
            inventory_actor.publish_inventory()
            inventoryUI.lastPublishTime = currentTime
        end

        updatePeerList()

        inventory_actor.process_pending_requests()
        if #inventory_actor.deferred_tasks > 0 then
            local task = table.remove(inventory_actor.deferred_tasks, 1)
            local ok, err = pcall(task)
            if not ok then
                mq.cmdf("/echo [EZInventory ERROR] Deferred task failed: %s", tostring(err))
            end
        end
        mq.delay(100)
    end
end

main()
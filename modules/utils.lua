local M = {}

function M.get_slot_name_from_id(slotID)
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
        [22] = "Ammo",
    }
    return slotNames[slotID] or "Unknown Slot"
end

return M

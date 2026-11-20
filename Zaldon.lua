_addon.name = 'Zaldon'
_addon.author = 'Sylphiana'
_addon.version = '1.7'
_addon.commands = {'zaldon', 'zal'}

require('strings')
require('tables')
local packets = require('packets')

-- Configuration
local TARGET_NAME = 'Zaldon'
local DELAY = 8 -- Seconds between trades
local ENTER_DELAY = 0.8 -- Delay after Zaldon's item-belly line before pressing Enter
local RESTOCK_DELAY = 0.8 -- Pause after pulling an item from a bag into main inventory
local ITEM_TRIGGER_PHRASE = 'look what this bugger had in his belly'
local DEBUG_TEXT = false

-- Bags to pull from when main inventory runs out: Case (7), Sack (6), Satchel (5)
local SOURCE_BAGS = {7, 6, 5}
local BAG_NAMES = {
    [5] = 'Satchel',
    [6] = 'Sack',
    [7] = 'Case',
}

-- State variables
local running = false
local target_item = nil
local enter_scheduled = false

-- Helper to send an Enter key press via Windower's setkey command
local function press_enter()
    enter_scheduled = false
    if not running then return end

    windower.send_command('setkey enter down')
    coroutine.schedule(function()
        windower.send_command('setkey enter up')
    end, 0.05)

    if DEBUG_TEXT then
        windower.add_to_chat(207, '[Zaldon] Sent Enter.')
    end
end

-- Helper to find Zaldon's ID and Index in the surrounding mob array
local function get_npc_info(name)
    local mob_array = windower.ffxi.get_mob_array()
    for _, mob in pairs(mob_array) do
        if mob and mob.name == name and mob.valid_target then
            if math.sqrt(mob.distance) <= 6 then
                return mob.id, mob.index
            else
                windower.add_to_chat(123, '[Zaldon] Found Zaldon, but he is too far away.')
                return nil, nil
            end
        end
    end
    windower.add_to_chat(123, '[Zaldon] Could not find Zaldon nearby.')
    return nil, nil
end

-- Helper to check if a specific item record matches the requested name
local function item_matches_name(item, search_name, res_items)
    if type(item) ~= 'table' or not item.id or item.id <= 0 then
        return false
    end
    if item.status and item.status ~= 0 then
        return false
    end
    local res = res_items[item.id]
    if not res then return false end

    local name_match = res.name and res.name:lower() == search_name
    local enl_match = res.enl and res.enl:lower() == search_name
    return name_match or enl_match
end

-- Helper to find the main inventory slot index of the specified item
local function find_item_slot(item_name)
    local items = windower.ffxi.get_items(0) -- 0 = Main Inventory
    if not items then return nil end

    local res_items = require('resources').items
    local search_name = item_name:lower()

    for slot, item in pairs(items) do
        local num_slot = tonumber(slot)
        if num_slot and item_matches_name(item, search_name, res_items) then
            return num_slot
        end
    end
    return nil
end

-- Helper to pull 1 matching item from Case, Sack, or Satchel into Main Inventory (bag 0)
local function restock_from_bags(item_name)
    local res_items = require('resources').items
    local search_name = item_name:lower()

    for _, bag_id in ipairs(SOURCE_BAGS) do
        local bag_items = windower.ffxi.get_items(bag_id)
        if bag_items then
            for slot, item in pairs(bag_items) do
                local num_slot = tonumber(slot)
                if num_slot and item_matches_name(item, search_name, res_items) then
                    local move_count = math.min(1, item.count or 1)
                    windower.ffxi.get_item(bag_id, num_slot, move_count)
                    local bag_label = BAG_NAMES[bag_id] or ('Bag ' .. tostring(bag_id))
                    windower.add_to_chat(207, '[Zaldon] Pulled ' .. move_count .. 'x ' .. item_name .. ' from ' .. bag_label .. ' (Slot ' .. num_slot .. ').')
                    return true
                end
            end
        end
    end

    return false
end

-- Core loop function
local function trade_loop()
    if not running then return end

    local npc_id, npc_index = get_npc_info(TARGET_NAME)
    if not npc_id then
        running = false
        return
    end

    local slot = find_item_slot(target_item)
    if not slot then
        if restock_from_bags(target_item) then
            coroutine.schedule(trade_loop, RESTOCK_DELAY)
            return
        end

        windower.add_to_chat(123, '[Zaldon] Out of "' .. target_item .. '" in inventory, case, sack, and satchel. Stopping.')
        running = false
        return
    end

    local player = windower.ffxi.get_player()
    if player and player.target_index ~= npc_index then
        packets.inject(packets.new('outgoing', 0x01A, {
            ['Target'] = npc_id,
            ['Target Index'] = npc_index,
            ['Category'] = 0x0F,
        }))
    end

    local trade_packet = packets.new('outgoing', 0x036, {
        ['Target'] = npc_id,
        ['Target Index'] = npc_index,
        ['Item Count 1'] = 1,
        ['Item Index 1'] = slot,
        ['Number of Items'] = 1,
    })

    packets.inject(trade_packet)
    windower.add_to_chat(207, '[Zaldon] Traded 1x ' .. target_item .. ' (Slot ' .. slot .. ').')

    coroutine.schedule(trade_loop, DELAY)
end

-- Listen for system/chat messages indicating trade failure, inventory limits, or item acquisition
windower.register_event('incoming text', function(original, modified, original_mode, modified_mode, blocked)
    if not running then return end

    -- Normalize whitespace and control bytes while keeping readable ASCII words/punctuation
    local clean = original:gsub('[\128-\255].', ''):gsub('%c', ' '):gsub('%s+', ' '):lower()

    if DEBUG_TEXT then
        windower.add_to_chat(205, '[Zaldon DBG mode=' .. tostring(original_mode) .. '] ' .. clean)
    end

    -- 1. Stop conditions on failure or full inventory
    if clean:find('trade failed') or clean:find('unable to trade') or clean:find('cannot trade') or clean:find('full') then
        windower.add_to_chat(123, '[Zaldon] Detected failure/full message: "' .. original .. '". Stopping.')
        running = false
        enter_scheduled = false
        return
    end

    -- 2. Trigger Enter when Zaldon finds an item in the fish
    if clean:find(ITEM_TRIGGER_PHRASE, 1, true) and not enter_scheduled then
        enter_scheduled = true
        coroutine.schedule(press_enter, ENTER_DELAY)
    end
end)

-- Handle addon commands
windower.register_event('addon command', function(cmd, ...)
    cmd = cmd and cmd:lower() or ''
    local args = {...}

    if cmd == 'start' then
        if #args == 0 then
            windower.add_to_chat(123, '[Zaldon] Usage: //zaldon start <item name>')
            return
        end
        target_item = table.concat(args, ' ')
        running = true
        enter_scheduled = false
        windower.add_to_chat(207, '[Zaldon] Starting loop for: ' .. target_item)
        trade_loop()

    elseif cmd == 'stop' then
        running = false
        enter_scheduled = false
        windower.add_to_chat(207, '[Zaldon] Stopped.')

    else
        windower.add_to_chat(207, '[Zaldon] Commands: //zaldon start <item name> | //zaldon stop')
    end
end)

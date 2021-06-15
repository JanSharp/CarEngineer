
---@class ScriptData
---@field version '"1.0.0"' @ used for migration
---@field players table<integer, PlayerData> @ indexed by player index
---@field car_lut table<integer, PlayerData> @ indexed by car unit_number
---@field next_updates table<integer, PlayerData[]> @ indexed by game tick
---@field wood_proto LuaItemPrototype @ cached wood item prototype
---@field car_max_energy_usage integer @ cached car entity prototype max energy usage

---@class PlayerData
---@field player LuaPlayer
---@field car LuaEntity|nil @ `nil` if the player is not a a character controller
---@field car_unit_number integer|nil @ `nil` if the player is not a a character controller
---@field is_auto_refueling boolean|nil @ is the current fuel fake fuel?
---@field car_burner LuaBurner|nil @ `car.burner`
---@field car_fuel_inv LuaInventory|nil @ `car.get_fuel_inventory()`
---@field next_update_tick integer|nil @ index used for `next_updates`

---in ticks
local shortest_update_delay = 10

local script_data ---@type ScriptData
local players
local car_lut

local next_updates

local wood_proto
local car_max_energy_usage

local function init()
  wood_proto = game.item_prototypes["wood"] ---@type LuaItemPrototype
  car_max_energy_usage = game.entity_prototypes["car"].max_energy_usage

  script_data.wood_proto = wood_proto
  script_data.car_max_energy_usage = car_max_energy_usage
end

local init_player

script.on_init(function()
  players = {}
  car_lut = {}
  next_updates = {}
  script_data = {
    version = "1.1.0",
    players = players,
    car_lut = car_lut,
    next_updates = next_updates,
  }
  init()
  global.script_data = script_data

  for _, player in pairs(game.players) do
    init_player(player)
  end
end)

script.on_load(function()
  if global.script_data and global.script_data.version == "1.1.0" then
    script_data = global.script_data
    players = script_data.players
    car_lut = script_data.car_lut
    next_updates = script_data.next_updates
    wood_proto = script_data.wood_proto
    car_max_energy_usage = script_data.car_max_energy_usage
  end
end)

local update_fuel

script.on_configuration_changed(function()
  if script_data then -- on config changed can run before on_init
    init()
    next_updates = {}
    script_data.next_updates = next_updates
    for _, player_data in next, players do
      update_fuel(player_data)
    end
  end
end)

---@param surface LuaSurface
---@param position Position
---@param force LuaForce
---@return LuaEntity car
local function create_car(surface, position, force)
  position = surface.find_non_colliding_position("car", position, 32, 0.5) or position
  local car = surface.create_entity{
    name = "car",
    position = position,
    force = force,
    raise_built = true,
  }
  if not car then
    error("Could not create a car.")
  end
  return car
end

---@param player_data PlayerData
local function remove_car_data(player_data)
  car_lut[player_data.car_unit_number] = nil
  local next_update_tick = player_data.next_update_tick
  local to_update = next_updates[next_update_tick]
  local c = #to_update
  if c == 1 then
    next_updates[next_update_tick] = nil
  else
    for i = 1, c do
      if to_update[i] == player_data then
        to_update[i] = to_update[c]
        to_update[c] = nil
      end
    end
  end
  player_data.car_unit_number = nil
  player_data.car = nil
  player_data.is_auto_refueling = nil
  player_data.car_burner = nil
  player_data.car_fuel_inv = nil
  player_data.next_update_tick = nil
end

---@param player_data PlayerData
local function car_died(player_data)
  remove_car_data(player_data)
  player_data.player.character.die()
end

---@param player_data PlayerData
local function check_car_validity(player_data)
  if player_data.car.valid then
    return true
  else
    car_died(player_data)
    return false
  end
end

---@param player_data PlayerData
function update_fuel(player_data)
  if check_car_validity(player_data) then
    local car = player_data.car
    local fuel_inv = car.get_fuel_inventory()
    local burner = car.burner

    local function do_auto_refuel()
      local game_tick = game.tick
      local next_update_tick = game_tick + shortest_update_delay
      while next_updates[next_update_tick] do
        next_update_tick = next_update_tick + 1
      end
      next_updates[next_update_tick] = {player_data}
      burner.remaining_burning_fuel =
        car_max_energy_usage * (next_update_tick - game_tick + 1)
      -- + 1 because otherwise we'd have to set `currently_burning` every time
      -- which is a waste of performance
      player_data.next_update_tick = next_update_tick
    end

    ---@param tick integer
    local function update_at(tick)
      local to_update = next_updates[tick]
      if not to_update then
        to_update = {}
        next_updates[tick] = to_update
      end
      to_update[#to_update+1] = player_data
      player_data.next_update_tick = tick
    end

    local is_empty = fuel_inv.is_empty()
    if is_empty and player_data.is_auto_refueling then
      do_auto_refuel()
    else
      local remaining = burner.remaining_burning_fuel
      if remaining == 0 then
        if is_empty then
          player_data.is_auto_refueling = true
          car.friction_modifier = 16
          burner.currently_burning = wood_proto
          do_auto_refuel()
        else
          update_at(game.tick + 1)
        end
      else
        if player_data.is_auto_refueling then
          player_data.is_auto_refueling = nil
          car.friction_modifier = 1
        end
        local remaining_fuel_ticks = remaining / car_max_energy_usage
        local next_update_tick = game.tick + math.ceil(remaining_fuel_ticks)
        update_at(next_update_tick)
      end
    end
  end
end

---@param player_data PlayerData
local function get_back_in_there(player_data)
  if check_car_validity(player_data) then
    player_data.car.set_driver(player_data.player)
  end
end

---@param player_data PlayerData
local function enter_car_mode(player_data)
  local player = player_data.player
  local car = create_car(player.surface, player.position, player.force)
  script.register_on_entity_destroyed(car)
  player_data.car = car
  player_data.car_burner = car.burner
  player_data.car_fuel_inv = car.get_fuel_inventory()
  local unit_number = car.unit_number
  player_data.car_unit_number = unit_number
  car_lut[unit_number] = player_data
  get_back_in_there(player_data)
  if player_data.car then
    update_fuel(player_data)
  end
end

---@param player_data PlayerData
local function leave_car_mode(player_data)
  local car = player_data.car
  remove_car_data(player_data)
  if car.valid then
    car.destroy{raise_destroy = true}
  end
end

---@param player_data PlayerData
local function check_switch_mode(player_data)
  if player_data.car then
    if player_data.player.controller_type ~= defines.controllers.character then
      leave_car_mode(player_data)
    end
  else
    if player_data.player.controller_type == defines.controllers.character then
      enter_car_mode(player_data)
    end
  end
end

script.on_event(defines.events.on_tick, function(event)
  local tick = event.tick
  local to_update = next_updates[tick]
  if to_update then
    for _, player_data in next, to_update do
      update_fuel(player_data)
    end
    next_updates[tick] = nil
  end
end)

---@param player LuaPlayer
function init_player(player)
  local player_data = {
    player = player,
  }
  if player.controller_type == defines.controllers.character then
    enter_car_mode(player_data)
  end
  players[player.index] = player_data
end

script.on_event(defines.events.on_player_created, function(event)
  local player = game.get_player(event.player_index)
  player.toggle_map_editor() -- HACK: just for testing
  init_player(player)
end)

script.on_event(defines.events.on_player_respawned, function(event)
  local player_data = players[event.player_index]
  if player_data then
    enter_car_mode(player_data)
  end
end)

script.on_event(defines.events.on_player_driving_changed_state, function(event)
  local player_data = players[event.player_index]
  if player_data then
    local player = player_data.player
    if not player.driving then
      get_back_in_there(player_data)
    end
  end
end)

local function on_death(event)
  ---@type integer
  local unit_number = event.unit_number or event.entity.unit_number or error("Unable to get unit_number.")
  local player_data = car_lut[unit_number]
  if player_data then
    car_died(player_data)
  end
end

local filters = {{filter = "name", name = "car"}}
script.on_event(defines.events.script_raised_destroy, on_death, filters)
script.on_event(defines.events.on_entity_destroyed, on_death)
script.on_event(defines.events.on_entity_died, on_death, filters)

local function handle_switch_event(event)
  local player_data = players[event.player_index]
  if player_data then
    check_switch_mode(player_data)
  end
end

script.on_event({
  defines.events.on_player_toggled_map_editor,
  defines.events.on_cutscene_waypoint_reached,
  defines.events.on_cutscene_cancelled,
}, handle_switch_event)

script.on_event(defines.events.on_player_removed, function(event)
  local player_data = players[event.player_index]
  players[event.player_index] = nil
  leave_car_mode(player_data)
end)

-- fix semantics
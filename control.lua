
local mod_gui = require("mod-gui")

---@class ScriptData
---@field version '"1.1.0"' @ used for migration
---@field players table<integer, PlayerData> @ indexed by player index
---@field car_lut table<integer, PlayerData> @ indexed by car unit_number
---@field next_updates table<integer, PlayerData[]> @ indexed by game tick
---@field cars_to_heal table<integer, PlayerData> @ indexed by unit_number
---@field cars_in_combat_until table<integer, PlayerData> @ indexed by tick at which they leave combat
---@field players_repairing_stuff table<integer, PlayerData> @ indexed by player_index
---@field wood_proto LuaItemPrototype @ cached wood item prototype
---@field car_max_energy_usage integer @ cached car entity prototype max energy usage

---@class PlayerData
---@field player_index integer
---@field player LuaPlayer
---@field car LuaEntity|nil @ `nil` if the player is not a a character controller
---@field car_unit_number integer|nil @ `nil` if the player is not a a character controller
---@field is_auto_refueling boolean|nil @ is the current fuel fake fuel?
---@field fuel_icon_id integer|nil @ the id of the out of fuel icon. always present when `is_auto_refueling` is `true`
---@field car_burner LuaBurner|nil @ `car.burner`
---@field car_fuel_inv LuaInventory|nil @ `car.get_fuel_inventory()`
---@field next_update_tick integer|nil @ index used for `next_updates`
---@field in_combat_until integer|nil @ tick at which this car leaves combat
---@field repair_state LuaControl.repair_state @ the current repair state when using repair packs
---@field mod_gui_btn LuaGuiElement|nil
---@field mod_gui_btn_enabled boolean|nil @ reflects the mod setting

---in ticks
local shortest_update_delay = 10

local script_data ---@type ScriptData
local players
local car_lut

local next_updates
local cars_to_heal
local cars_in_combat_until

local players_repairing_stuff

local wood_proto
local car_max_energy_usage

local function load_cache()
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
  cars_to_heal = {}
  cars_in_combat_until = {}
  players_repairing_stuff = {}
  script_data = {
    version = "1.1.0",
    players = players,
    car_lut = car_lut,
    cars_to_heal = cars_to_heal,
    cars_in_combat_until = cars_in_combat_until,
    players_repairing_stuff = players_repairing_stuff,
    next_updates = next_updates, ---@diagnostic disable-line: no-implicit-any
  }
  load_cache()
  global.script_data = script_data

  for _, player in pairs(game.players) do
    init_player(player)
  end
end)

local function on_load()
  script_data = global.script_data
  players = script_data.players
  car_lut = script_data.car_lut
  next_updates = script_data.next_updates
  cars_to_heal = script_data.cars_to_heal
  cars_in_combat_until = script_data.cars_in_combat_until
  wood_proto = script_data.wood_proto
  car_max_energy_usage = script_data.car_max_energy_usage
  players_repairing_stuff = script_data.players_repairing_stuff
end

script.on_load(function()
  if global.script_data and global.script_data.version == "1.1.0" then
    on_load()
  end
end)

local update_fuel

script.on_configuration_changed(function()
  if not script_data then -- only if on_load didn't run == migrating from different version of the mod
    load_cache()
    script_data.next_updates = {}
    for _, player_data in next, players do
      update_fuel(player_data)
    end
    on_load()
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

---since the full health state doesn't requrie any work
---this can also be used to clean up data
---@param player_data PlayerData
local function set_combat_state_full_health(player_data)
  cars_to_heal[player_data.car_unit_number] = nil
  if player_data.in_combat_until then
    cars_in_combat_until[player_data.in_combat_until] = nil
    player_data.in_combat_until = nil
  end
end

---@param player_data PlayerData
local function set_combat_state_healing(player_data)
  if player_data.car.get_health_ratio() == 1 then
    set_combat_state_full_health(player_data)
  else
    cars_to_heal[player_data.car_unit_number] = player_data
    if player_data.in_combat_until then
      cars_in_combat_until[player_data.in_combat_until] = nil
      player_data.in_combat_until = nil
    end
  end
end

---@param player_data PlayerData
local function set_combat_state_in_combat(player_data)
  if player_data.in_combat_until then
    cars_in_combat_until[player_data.in_combat_until] = nil
  end
  cars_to_heal[player_data.car_unit_number] = nil
  local in_combat_until = game.tick + 600
  while cars_in_combat_until[in_combat_until] do
    in_combat_until = in_combat_until + 1
  end
  cars_in_combat_until[in_combat_until] = player_data
  player_data.in_combat_until = in_combat_until
end

---@param player_data PlayerData
local function remove_car_data(player_data)
  car_lut[player_data.car_unit_number] = nil
  set_combat_state_full_health(player_data)
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
  players_repairing_stuff[player_data.player_index] = nil
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
  if player_data.player.controller_type == defines.controllers.character then
    -- the player could be in any character because of mods, but
    -- it could also be a ghost because the player also died before this function ran
    player_data.player.character.die()
  end
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
          player_data.fuel_icon_id = rendering.draw_sprite{
            sprite = "utility/fuel_icon",
            target = car,
            surface = car.surface,
            x_scale = 0.5,
            y_scale = 0.5,
            target_offset = car.prototype.alert_icon_shift,
          }
          car.friction_modifier = 16
          burner.currently_burning = wood_proto
          do_auto_refuel()
        else
          update_at(game.tick + 1)
        end
      else
        if player_data.is_auto_refueling then
          player_data.is_auto_refueling = nil
          rendering.destroy(player_data.fuel_icon_id)
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
local function show_mod_gui_button(player_data)
  if player_data.car
    and player_data.mod_gui_btn_enabled
    and (not player_data.mod_gui_btn)
  then
    ---@type LuaGuiElement
    local flow = mod_gui.get_button_flow(player_data.player)
    player_data.mod_gui_btn = flow.add{
      type = "sprite-button",
      style = mod_gui.button_style,
      sprite = "CarEngineer-suicide-icon",
      tags = {
        __CarEngineer = true,
        suicide = true,
      },
      tooltip = {"CarEngineer.who-knew"},
    }
  end
end

---@param player_data PlayerData
local function hide_mod_gui_button(player_data)
  local mod_gui_btn = player_data.mod_gui_btn
  if mod_gui_btn then
    local flow = mod_gui_btn.parent
    mod_gui_btn.destroy()
    if not next(flow.children) then
      flow.parent.destroy()
    end
    player_data.mod_gui_btn = nil
  end
end

---@param player_data PlayerData
local function update_mod_gui_button(player_data)
  if settings.get_player_settings(player_data.player)["CarEngineer-enable-mod-gui-btn"].value then
    player_data.mod_gui_btn_enabled = true
    show_mod_gui_button(player_data)
  else
    player_data.mod_gui_btn_enabled = nil
    hide_mod_gui_button(player_data)
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
    show_mod_gui_button(player_data)
  end
end

---@param player_data PlayerData
local function leave_car_mode(player_data)
  local car = player_data.car
  if car then
    remove_car_data(player_data)
    if car.valid then
      car.destroy{raise_destroy = true}
    end
    hide_mod_gui_button(player_data)
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
  do
    local to_update = next_updates[tick]
    if to_update then
      for _, player_data in next, to_update do
        update_fuel(player_data)
      end
      next_updates[tick] = nil
    end
  end

  do
    local player_data = cars_in_combat_until[tick]
    if player_data then
      set_combat_state_healing(player_data)
      cars_in_combat_until[tick] = nil
    end
  end

  for _, player_data in next, players_repairing_stuff do
    player_data.player.repair_state = player_data.repair_state
  end
end)

script.on_nth_tick(7, function()
  for _, player_data in next, cars_to_heal do
    local car = player_data.car
    if car.get_health_ratio() == 1 then
      set_combat_state_full_health(player_data)
    else
      car.health = car.health + 1
    end
  end
end)

---@param player_data PlayerData
local function check_is_repairing(player_data)
  local player = player_data.player
  local cursor_stack = player.cursor_stack
  if cursor_stack.valid_for_read and cursor_stack.type == "repair-tool" then
    local selected = player.selected
    if selected then
      player_data.repair_state.position = selected.position
      players_repairing_stuff[player_data.player_index] = player_data
      return
    end
  end
  players_repairing_stuff[player_data.player_index] = nil
end

---@param player LuaPlayer
function init_player(player)
  local player_data = {
    player = player,
    player_index = player.index,
    repair_state = {repairing = true},
  }
  if player.controller_type == defines.controllers.character then
    enter_car_mode(player_data)
    if player_data.car then
      check_is_repairing(player_data)
    end
  end
  update_mod_gui_button(player_data)
  players[player.index] = player_data
end

script.on_event(defines.events.on_player_created, function(event)
  local player = game.get_player(event.player_index)
  init_player(player)
end)

script.on_event(defines.events.on_player_respawned, function(event)
  local player_data = players[event.player_index]
  if player_data then
    enter_car_mode(player_data)
  end
end)

---@param player_data PlayerData
local function suicide(player_data)
  if player_data.car then
    if player_data.player.controller_type == defines.controllers.character then
      player_data.car.die(player_data.player.force, player_data.player.character)
    else
      player_data.car.die(player_data.player.force)
    end
  end
end

script.on_event(defines.events.on_player_driving_changed_state, function(event)
  local player_data = players[event.player_index]
  if player_data then
    local player = player_data.player
    if not player.driving then
      get_back_in_there(player_data)
    end
  end
end)

script.on_event(defines.events.on_lua_shortcut, function(event)
  if event.prototype_name == "CarEngineer-suicide" then
    local player_data = players[event.player_index]
    if player_data then
      suicide(player_data)
    end
  end
end)

script.on_event("CarEngineer-suicide", function(event)
  local player_data = players[event.player_index]
  if player_data then
    suicide(player_data)
  end
end)

---@param event script_raised_destroy|on_entity_destroyed|on_entity_died
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

---@param event table
local function handle_switch_event(event)
  local player_data = players[event.player_index]
  if player_data then
    check_switch_mode(player_data)
  end
end

script.on_event(defines.events.on_entity_damaged, function(event)
  local unit_number = event.entity.unit_number
  local player_data = car_lut[unit_number]
  if player_data then
    set_combat_state_in_combat(player_data)
  end
end, filters)

script.on_event(defines.events.on_player_used_capsule, function(event)
  local player_data = players[event.player_index]
  if player_data and event.item.name == "raw-fish" and check_car_validity(player_data) then
    local car = player_data.car
    car.health = car.health + 80
    if car.get_health_ratio() == 1 then
      set_combat_state_full_health(player_data)
    end
  end
end)

---@param event on_selected_entity_changed|on_player_cursor_stack_changed
local function handle_repairing_events(event)
  local player_data = players[event.player_index]
  if player_data and player_data.car then
    check_is_repairing(player_data)
  end
end

script.on_event({
  defines.events.on_selected_entity_changed,
  defines.events.on_player_cursor_stack_changed
}, handle_repairing_events)

script.on_event({
  defines.events.on_player_toggled_map_editor,
  defines.events.on_cutscene_waypoint_reached,
  defines.events.on_cutscene_cancelled,
}, handle_switch_event)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  if event.setting == "CarEngineer-enable-mod-gui-btn" then
    local player_data = players[event.player_index]
    if player_data then
      update_mod_gui_button(player_data)
    end
  end
end)

script.on_event(defines.events.on_gui_click, function(event)
  if (not (event.alt or event.control or event.shift))
    and event.button == defines.mouse_button_type.left
  then
    local tags = event.element.tags
    if tags.__CarEngineer and tags.suicide then
      local player_data = players[event.player_index]
      if player_data then
        suicide(player_data)
      end
    end
  end
end)

script.on_event(defines.events.on_player_removed, function(event)
  local player_data = players[event.player_index]
  players[event.player_index] = nil
  leave_car_mode(player_data)
end)

-- fix semantics
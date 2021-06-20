
data:extend{
  {
    type = "custom-input",
    name = "CarEngineer-suicide",
    localised_description = {"CarEngineer.who-knew"},
    key_sequence = "ALT + G",
    action = "lua",
  },
  {
    type = "sprite",
    name = "CarEngineer-suicide-icon",
    filename = "__CarEngineer__/graphics/suicide-x32.png",
    priority = "extra-high-no-scale",
    width = 32,
    height = 32,
    flags = {"icon"},
  },
}

if settings.startup["CarEngineer-enable-shortcut"].value then
  data:extend{
    {
      type = "shortcut",
      name = "CarEngineer-suicide",
      localised_name = {"CarEngineer.who-knew"},
      associated_control_input = "CarEngineer-suicide",
      action = "lua",
      icon =
      {
        filename = "__CarEngineer__/graphics/suicide-x32.png",
        priority = "extra-high-no-scale",
        size = 32,
        scale = 0.5,
        mipmap_count = 2,
        flags = {"gui-icon"},
      },
      small_icon =
      {
        filename = "__CarEngineer__/graphics/suicide-x24.png",
        priority = "extra-high-no-scale",
        size = 24,
        scale = 0.5,
        mipmap_count = 2,
        flags = {"gui-icon"},
      },
      disabled_small_icon =
      {
        filename = "__CarEngineer__/graphics/suicide-x24-white.png",
        priority = "extra-high-no-scale",
        size = 24,
        scale = 0.5,
        mipmap_count = 2,
        flags = {"gui-icon"},
      },
    },
  }
end

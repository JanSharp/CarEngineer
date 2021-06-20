
data:extend{
  {
    type = "bool-setting",
    name = "CarEngineer-enable-shortcut",
    setting_type = "startup",
    default_value = false,
  },
  {
    type = "bool-setting",
    name = "CarEngineer-enable-mod-gui-btn",
    setting_type = "runtime-per-user",
    default_value = false,
  },
  {
    type = "bool-setting",
    name = "CarEngineer-death-on-exit",
    setting_type = "runtime-per-user",
    default_value = false,
  },
  {
    type = "int-setting",
    name = "CarEngineer-max-random-spawn-distance",
    setting_type = "runtime-per-user",
    default_value = 0,
    minimum_value = 0,
    maximum_value = 128,
  },
}

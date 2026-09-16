# API

## Actions and text

- `report_action`, `push_action!`, and `rank_actions` construct and prioritize
  recommended actions.
- `print_action_list`, `print_section`, and `print_key_values` write stable text
  sections.
- `option_resolution_rows` and `print_option_resolution` report whether each
  option came from a default, a user override, or smart resolution.

## Parameter identities and updates

- `ParameterRowKey`, `parameter_key`, `initial_key`, and `constant_key` identify
  rows without conflating model sections.
- `ParameterUpdate`, `model_update`, `parameter_update`, and
  `optimization_update` normalize fitted or manually supplied values.
- `save_parameter_update` and `load_parameter_update` persist those updates as
  YAML.

## Tables and overlays

`ParameterOverlay`, `parameter_overlay`, `parameter_metadata_overlay`, and
`load_parameter_metadata` add values and annotations to report tables.

```@docs
parameter_table
```

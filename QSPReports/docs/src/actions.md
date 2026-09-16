# Actions and options

Action rows give report producers one consistent priority order and
deduplication key:

```julia
actions = NamedTuple[]
push_action!(actions, :high, :fit, :rerun,
             "Rerun the fit.", "The optimizer did not converge.")
push_action!(actions, :medium, :fit, :inspect,
             "Inspect diagnostics.", "Residual structure remains.")

print_action_list(stdout, rank_actions(actions))
```

`option_resolution_rows` labels selected fields as `:default`, `:user`, or
`:smart`. The smart label is caller-supplied; QSPReports does not infer which
defaults were replaced.

```julia
Base.@kwdef struct Options
    maxiters::Int = 1000
    solver::Symbol = :auto
end

defaults = Options()
resolved = Options(maxiters=5000)
print_option_resolution(stdout, "Options", resolved, defaults;
                        smart_replaced=Set([:solver]))
```

The low-level `print_section` and `print_key_values` helpers are useful when
assembling a larger plain-text report.

# TargKit: matching targets to simulation output (`Match`)

Status: accepted, 2026-09-24. The mapping is declared where a TargetSet meets a
simulation (`fit`, `setup`, `objective`, `score`), not on the TargetSet.

## Problem

A TargetSet is a table of observations, and a simulation naturally produces a
table (or a set of solutions labelled by scanned values). TargKit connected the
two only through a key lookup, `sim[condition][variable]`, so users had to
reshape their simulation output into nested Dicts or write a `predict` closure.

1. Targets were never matched against columns of the simulation output.
2. `variable` and `timepoint` had to be columns in the target data; there was no
   way to say "every row is `Conc` at 24 h".
3. A condition with no simulated counterpart became a `NaN` prediction, which
   the loss turned into a large penalty. The fit ran, and the target never
   improved.
4. Only one key dimension (`condition`) existed.
5. A role naming a column that did not exist was silently ignored.

## Design

A TargetSet holds the observed data only. How its rows line up with one
simulation's output is a separate `Match`, given where the two meet, like a join:

- **keys** (`match`) pick the curve: one or more discrete keys (dose, donor, arm).
- **`at`** picks the point on that curve: a position along one ordered axis
  (time, dose, ...). It is not tied to time.
- **`variable`** names the simulated variable each row's observed value is
  compared with.

```julia
targets = TargetSet(target_df; value = :Conc)          # data: what was observed

sim(p) = scan(SimContext(prob) |> with(p), :dose => unique(target_df.dose);
              events = q -> ev(time=0.0, cmt=:Depot, amt=q.dose),
              duration = 24.0)

res = fit(targets; simulate = sim,                     # mapping: how it lines up with `sim`
          match = :dose, at = :TIME => 24.0, variable = :Conc,
          params, keyfile)
```

The same data can be fitted against another model or output shape by changing
only the mapping. With several TargetSets that line up differently, pair each
with its own `Match` (or predict function):

```julia
fit(pk => Match(:dose; at = :TIME, variable = :Conc),
    pd => Match(:dose_mg => :dose; at = :TIME => 48.0, variable = :Effect);
    simulate = sim, params, bounds)
```

### Mapping (`Match` / keywords)

`fit`, `setup`, `objective`, and `score` take `match`, `at`, and `variable`
keywords (one mapping for every TargetSet), `predict` (the alternative), or
`TargetSet => Match(...)` / `TargetSet => predict_fn` pairs.

| Part | Forms | Meaning |
|---|---|---|
| keys (`match`) | `:col`, `:col => :simkey`, or a vector of these | Target column(s) holding discrete keys. `:col => :simkey` matches a target column against a differently named simulation key. |
| `at` | `:col`, `:col => :axis`, `:axis => value` | One ordered axis. `:col` reads each row's position from a target column with the same name as the simulation axis; `:col => :axis` maps a target column to a differently named axis; `:axis => value` places every target at one position. |
| `variable` | `:simvar`, `Dict(measured => :simvar, ...)`, or omitted | The simulated variable. A name applies to every row. When the TargetSet has a `variable` column (long data naming each row's measured variable), a Dict translates those names, and omitting `variable` uses them as simulated names directly. |

Keys and `at` are each optional. The TargetSet columns they name keep their
names, so `where(ts, :dose => 10)` works. Rows without given names are named
after the mapping (`:"dose=10.0,TIME=24.0"`) in reports and errors.

Each TargetSet's rows use that TargetSet's loss; a `loss` keyword overrides them
all, and a per-row `loss` column wins over both.

Unit conversions are done on the target DataFrame before building the
TargetSet; `match` and `at` take column names and constants only.

Series-valued targets (`(t=..., y=...)` cells) cannot be matched; use one row per
point with `at = :TIME`, or a `predict` function.

### Simulation outputs

`simulate` may return:

| Output | Keys come from | `at` means | Variable |
|---|---|---|---|
| A table (DataFrame or any Tables.jl table) | its columns | a column (the axis name) | a column |
| An ODE solution | none | the solution's time (the axis name is not checked) | a state or observed variable |
| A SimKit scan result | the scanned values (`params`) | resolved inside each result | resolved inside each result |
| A SimKit `SimContext` | none | the last phase's solution time (the phase `to_dataframe` reports) | as for a solution |
| An `AbstractDict` | its keys, matched against the one remaining match key | resolved inside each value | resolved inside each value |
| `TargKit.KeyedResults([keys => result, ...])` | each entry's `keys` | resolved inside each result | resolved inside each result |

Resolution is recursive: keys are matched against the labelled results first,
and any match keys not found in the labels are matched against columns of the
selected table. A solution has no keys, so any match key left over when a
solution is reached is an error.

`TargKit.match_source(sim)` converts outputs to one of the forms above; other
components add methods. SimKit's methods live in `TargKit/ext/TargKitSimKitExt.jl`,
included by the QSPKit root after both components, so neither component depends
on the other.

### Matching rules

- Numbers match with `isapprox` (default relative tolerance), so doses that went
  through a unit conversion still match. `Symbol` and `String` values match by
  their text. Anything else matches with `isequal`.
- Every target row must match **exactly one** simulation point.
  - **No match** is an error naming the target and listing the values the output
    has.
  - **More than one match** is an error listing the columns (or keys) in which
    the candidates differ. Differing identifiers mean a missing `match` key.
    Rows that agree on every key and on `at` but differ in values are duplicate
    points, typically the values just before and after a dose.
  - A table group with several rows and no `at` is the same error; the message
    suggests `at`.
- For an ODE solution, `at` is required, must lie within the solved time span,
  and must not fall on a time the solution saved twice. A dose at a saved time
  produces two points there (before and after the dose), and `sol(t)` would
  silently return one of them; the error asks for a time just before or after.
- There is no interpolation along a table axis. The simulation must include
  every target point (e.g. `saveat` or the scanned values).
- A solution with dense output (no `saveat`) is evaluated with the solver's own
  interpolant, which is accurate to solver tolerance. A solution saved with
  `saveat` has no dense output, so `at` must be one of its saved times, the same
  rule as for tables.
- Several target rows may match the same simulation point (replicates).

### Failures

- Errors are `TargKit.MatchError` and propagate. `setup` evaluates the objective
  once at `x0`, so a mismatch stops the fit before optimization starts.
- A solution whose return code is not successful makes the objective return
  `failure_penalty`, as `simulate` returning `nothing` does. `score` raises an
  error for it instead. A table cannot report a failed solve; a simulation that
  can fail should return `nothing` from `simulate`.

### fit / objective / score

- A mapping is required: without `match`/`at`/`variable` or `predict` (or a
  paired `Match`/function), `score`, `objective`, `setup`, and `fit` raise an
  `ArgumentError`. There is no implicit lookup.
- `predict` together with `match`/`at`/`variable` is an `ArgumentError`.
- The columns a `Match` names are checked against each TargetSet when the two
  are paired, so a wrong column fails before any simulation runs.

### Other changes

- A role naming a column that is not in the data is an error, except the
  default optional columns (`:lower`, `:upper`).
- A role that renames a column onto an existing column of the role's name
  (e.g. `value = :obs` while the data also has `:value`) is an error.

### Removed

The `condition` and `timepoint` keywords and the implicit lookup
(`sim[condition][variable]`, `sim[variable]`, `sim[target name]`, and
series-valued targets keyed by condition) are removed. `TargetSet` takes no
mapping keywords (`condition`, `timepoint`, `match`, `at` are unsupported-keyword
`MethodError`s). Targets keyed by name, or series-valued targets, use `predict`.

## Out of scope

- Interpolation along table axes.
- Transforms inside `match`/`at`.
- Per-TargetSet loss for the `df => predict_fn` pair API (it uses one `loss`).
- Matching against a SimKit `PopulationResult` (error; use `to_dataframe`).
- Keyed NamedTuple outputs such as `(pk = sol,)`.

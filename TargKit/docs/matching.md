# TargKit: matching targets to simulation output (`match` / `at`)

Status: accepted, 2026-09-24.

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

A target row is matched to the simulation output the way a join matches rows:

- **`match`** picks the curve: one or more discrete keys (dose, donor, arm).
- **`at`** picks the point on that curve: a position along one ordered axis
  (time, dose, ...). It is not tied to time.
- **`value`** is the observed number. The simulated variable it is compared
  with defaults to the value column's name.

```julia
ts = TargetSet(target_df;
    match = :dose,                 # target column(s) matched against the sim output
    value = :Conc,                 # observed column; also the simulated variable
    at    = :TIME => 24.0,         # every target at TIME = 24
)

sim(p) = scan(SimContext(prob) |> with(p), :dose => unique(target_df.dose);
              events = q -> ev(time=0.0, cmt=:Depot, amt=q.dose),
              duration = 24.0)

res = fit(ts; simulate = sim, params, keyfile)
```

### TargetSet keywords

| Keyword | Forms | Meaning |
|---|---|---|
| `match` | `:col`, `:col => :simkey`, or a vector of these | Target column(s) holding discrete keys. `:col => :simkey` matches a target column against a differently named simulation key. |
| `at` | `:col`, `:col => :axis`, `:axis => value` | One ordered axis. `:col` reads each row's position from a target column with the same name as the simulation axis; `:col => :axis` maps a target column to a differently named axis; `:axis => value` places every target at one position. |
| `value` | existing forms, plus `:obs => :simvar` and `:obs => fn => :simvar` | Observed column. The simulated variable defaults to the observed column's name; `=> :simvar` names it explicitly. |
| `variable` | existing forms | With `match`/`at`: a target column of simulated variable names (long data with several endpoints). Overrides the default. |

`match` and `at` are each optional; either one switches the TargetSet to
matching. Neither can be combined with `condition` or `timepoint`.
`match`/`at` columns keep their names in the TargetSet, so `where(ts, :dose => 10)`
works. Target names are generated from the match and `at` columns, e.g.
`:"dose=10.0,TIME=24.0"`.

Unit conversions are done on the target DataFrame before building the
TargetSet; `match` and `at` take column names and constants only.

Series-valued targets (`(t=..., y=...)` cells) are not supported with
`match`/`at`; use one row per point with `at = :TIME`.

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

- `score(ts; sim)`, `objective(ts; ...)`, `setup(ts; ...)` and `fit(ts; ...)`
  use matching for TargetSets that have `match`/`at`.
- Passing `predict` together with a matching TargetSet is an `ArgumentError`.
- `predict = (sim, row) -> ...` remains the escape hatch for TargetSets without
  `match`/`at`.

### Other changes

- A role naming a column that is not in the data is an error, except the
  default optional columns (`:lower`, `:upper`).
- A role that renames a column onto an existing column of the role's name
  (e.g. `value = :obs` while the data also has `:value`) is an error.

### Deprecations

`condition` and `timepoint` keep working through the existing convention
lookup, which is unchanged, and emit a deprecation warning. Use `match` and
`at` instead.

## Out of scope

- Interpolation along table axes.
- Transforms inside `match`/`at`.
- Matching against a SimKit `PopulationResult` (error; use `to_dataframe`).
- Keyed NamedTuple outputs such as `(pk = sol,)`.

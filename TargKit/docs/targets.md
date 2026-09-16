# Targets Guide

This document covers everything about declaring and working with calibration targets in TargKit.

## @targetset

A `TargetSet` is a named, iterable collection of `Target` objects. Create one with the `@targetset` macro:

```julia
ts = @targetset :baseline begin
    @target Blood_Eos  2.5  range=(1.5, 4.0)
    @target FeNO       40.0 range=(25.0, 60.0)
end
```

### Syntax

```julia
@targetset :name [group_by=:field] begin
    [default_predict(ctx, t) = ...]
    [var = expr]           # let-bindings (shared across targets)
    @target ...
    @target ...
end
```

- **`:name`** (required) -- a Symbol naming this target set.
- **`group_by=:field`** (optional) -- a metadata key to group targets by. See [Grouping](#grouping).
- **`default_predict(ctx, t)`** (optional) -- fallback predict function for targets that don't define their own.
- **Let-bindings** -- any `var = expr` assignment becomes available to all `@target` blocks below it. Useful for sharing a common source.

### TargetSet is iterable

`TargetSet` supports `iterate`, `length`, and `getindex`:

```julia
length(ts)        # number of targets
ts[1]             # first target
for t in ts       # iterate over targets
    println(t.name, " => ", t.value)
end
```

## @target

Declares a single calibration target inside a `@targetset` block.

### Syntax

```julia
@target name [value] [range=(lo, hi)] [loss=:log] [weight=1.0] [key=val...] [begin
    [source = ...]
    [observe(data) = ...]
    [predict(ctx) = ...]       # or predict(ctx, t) = ...
end]
```

### Fields

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `name` | yes | -- | Symbol identifying the target (first positional arg) |
| `value` | yes* | -- | Numeric target value (second positional arg, or from `observe`) |
| `range` | no | `nothing` | `(lo, hi)` tuple for pass/fail range checking |
| `loss` | no | `:log` | Loss type: `:log`, `:squared`, `:range_only`, `:series_mse` |
| `weight` | no | `1.0` | Multiplicative weight on the loss contribution |
| `source` | no | `nothing` | A `Source` object for provenance tracking |
| `error` | no | `nothing` | Error model: `:additive`, `:proportional`, `:lognormal`, `:combined` |
| `sigma` | no | `nothing` | Additive SD (for `:additive` or `:combined`) |
| `cv` | no | `nothing` | Proportional CV (for `:proportional` or `:combined`) |
| `omega` | no | `nothing` | Log-scale SD (for `:lognormal`) |
| any `key=val` | no | -- | Stored in `metadata` dict (e.g., `drug=:mepo`, `species=:Blood_Eos`) |

\*Value is required either as a literal or via `observe(data)`.

### Minimal target

```julia
@target Blood_Eos 2.5
```

Creates a target named `:Blood_Eos` with value `2.5`, no range, `:log` loss, weight `1.0`.

### Target with range and custom loss

```julia
@target FEV1 60.0 range=(50.0, 70.0) loss=:squared weight=2.0
```

### Target with metadata

Any `key=val` pair that isn't a reserved field (`range`, `loss`, `weight`, `source`, `error`, `sigma`, `cv`, `omega`) is stored in the target's metadata dict:

```julia
@target eos_mepo -67.0 range=(-80.0, -50.0) drug=:mepolizumab species=:Blood_Eos
```

Access metadata later:
```julia
t.metadata[:drug]     # :mepolizumab
t.metadata[:species]  # :Blood_Eos
```

### Target with error model

For MLE/WLS objectives, targets need an error model specification:

```julia
@target Blood_Eos 2.5 range=(1.5, 4.0) error=:lognormal omega=0.3
@target FeNO 40.0 range=(25.0, 60.0) error=:proportional cv=0.25
@target FEV1 60.0 range=(50.0, 70.0) error=:additive sigma=5.0
```

See [Error Models](error_models.md) for details.

## The `begin...end` Block

The optional block supports three special declarations:

### `source = ...`

Attach a provenance source:

```julia
@target Blood_Eos 2.5 range=(1.5, 4.0) begin
    source = from_literature(ref="Lou 2021", pmid=33456789, table="Table 2")
end
```

You can also pass `source` as a keyword (for simple cases):

```julia
@target Blood_Eos 2.5 source=from_literature(ref="Lou 2021")
```

### `observe(data) = ...`

Compute the target value (and optionally range) from a data file at load time. Requires the source to be a `DataSource`:

```julia
@target eos_baseline begin
    source = from_data("data/clinical.csv", filter=(cohort="asthma",))
    observe(data) = Observed(mean(data.eos_count); range=(1.5, 4.0))
end
```

The `observe` function receives the loaded (and filtered) data and must return an `Observed` object. The `Observed` constructor accepts:
- `Observed(value)` -- value only
- `Observed(value; range=(lo, hi))` -- value with range
- `Observed((t=..., y=...))` -- series data for `:series_mse` targets

**Resolution rules at load time:**
1. If both a literal value and `observe` provide a value, TargKit raises an error (ambiguous).
2. If both a literal range and `observe` provide a range, TargKit raises an error (ambiguous).
3. A literal range can supplement an observed value (or vice versa).
4. Either a literal value or an observed value is required.

### `predict(ctx) = ...` or `predict(ctx, t) = ...`

Override the `default_predict` for this specific target:

```julia
@target Blood_Eos 2.5 begin
    predict(ctx) = ctx.sol[:Blood_Eos][end]
end
```

If you write `predict(ctx)` (one argument), TargKit wraps it as `(ctx, _t) -> ...` internally. If you need access to the target itself (e.g., its metadata), use the two-argument form:

```julia
@target eos_drug -67.0 drug=:mepo species=:Blood_Eos begin
    predict(ctx, t) = pct_change(
        ctx.drug_sols[t.metadata[:drug]][t.metadata[:species]][end],
        ctx.base_sol[t.metadata[:species]][end]
    )
end
```

## default_predict

The `default_predict(ctx, t)` function defined at the `@targetset` level is used for any target that doesn't define its own `predict` block:

```julia
ts = @targetset :baseline begin
    default_predict(ctx, t) = ctx.sol[t.name][end]

    @target Blood_Eos  2.5  range=(1.5, 4.0)  # uses default_predict
    @target FeNO       40.0 range=(25.0, 60.0) # uses default_predict
    @target FEV1       60.0 begin              # uses custom predict
        predict(ctx) = ctx.sol[:FEV1_pct][end]
    end
end
```

The signature is always `(ctx, t)`:
- `ctx` -- whatever you pass to `score(ts, ctx)`. Typically a NamedTuple or Dict containing simulation results.
- `t` -- the `Target` being evaluated. Access `t.name`, `t.value`, `t.metadata`, etc.

## Source Types

Sources track where target values come from. Three constructors are provided:

### `from_literature(...)`

For values extracted from published papers:

```julia
from_literature(
    ref = "Lou et al. 2021",       # free-text citation (default: "")
    pmid = 33456789,               # PubMed ID (optional)
    doi = "10.1234/example",       # DOI (optional)
    table = "Table 2",             # table reference (optional)
    figure = "Fig 3A",             # figure reference (optional)
    method = :direct,              # :direct, :digitized, :derived, :assumed
    derivation = "mean of cols",   # human-readable derivation (optional)
    notes = "healthy controls",    # free-text notes (optional)
)
```

### `from_data(path; ...)`

For values computed from data files:

```julia
from_data(
    "data/clinical.csv",
    filter = (cohort = "asthma", visit = "baseline"),  # equality filter (optional)
    notes = "Filtered to baseline visits",             # free-text (optional)
)
```

When used with `observe(data)`, TargKit:
1. Loads the CSV file at `path`
2. Applies the `filter` NamedTuple as equality conditions on columns
3. Passes the filtered data to your `observe(data)` function

### `assumed(rationale; ...)`

For values based on assumptions or expert judgment:

```julia
assumed(
    "Typical asthma severity",
    author = "J. Smith",
    date = "2024-06-15",
)
```

## Let-Bindings for Shared Sources

Inside `@targetset`, regular assignments create let-bindings visible to all targets below:

```julia
ts = @targetset :drug_response group_by=:drug begin
    fig4 = from_data("data/gadkar_fig4.csv")

    @target eos_mepo  -67.0  drug=:mepo begin
        source = fig4  # reuse the shared source
    end
    @target eos_lebri  33.0  drug=:lebri begin
        source = fig4  # same source, different target
    end
end
```

## Grouping

Set `group_by=:field` on a `@targetset` to enable grouping by a metadata key:

```julia
ts = @targetset :drug_response group_by=:drug begin
    @target eos_mepo  -67.0  drug=:mepolizumab
    @target fev1_mepo  0.0   drug=:mepolizumab
    @target eos_dupi   23.0  drug=:dupilumab
    @target fev1_dupi  9.5   drug=:dupilumab
end

for (drug, targets) in groups(ts)
    println("$drug: $(length(targets)) targets")
    # drug=:mepolizumab, targets=[eos_mepo, fev1_mepo]
    # drug=:dupilumab,   targets=[eos_dupi, fev1_dupi]
end
```

Every target in the set must have the `group_by` key in its metadata, otherwise `groups()` raises an error.

`groups()` returns an iterator of `(key, Vector{Target})` pairs.

## The Observed Type

`Observed` is the return type of `observe(data)` functions. It holds a value and optional range:

```julia
Observed(2.5)                           # scalar, no range
Observed(2.5; range=(1.5, 4.0))        # scalar with range
Observed((t=[0, 7, 14], y=[1, 2, 3]))  # series data (for :series_mse)
```

The `value` field accepts any type:
- `Float64` for scalar targets
- A NamedTuple with `t` and `y` fields for series/trajectory targets

## Helper: pct_change

```julia
pct_change(new, old) = 100.0 * (new - old) / old
```

Convenience function for computing percent change from baseline. Commonly used in drug response targets:

```julia
default_predict(ctx, t) = pct_change(
    ctx.drug_sol[t.metadata[:species]][end],
    ctx.base_sol[t.metadata[:species]][end]
)
```

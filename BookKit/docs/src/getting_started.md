# Getting Started

## Installation

BookKit is part of the QSPKit monorepo. Add it and its dependency StoreKit via:

```julia
using Pkg
Pkg.develop(path="path/to/QSPKit/StoreKit")
Pkg.develop(path="path/to/QSPKit/BookKit")
```

## Basic Workflow

### 1. Book a result

When you have a result you're satisfied with, call `book!()` to record it:

```julia
using BookKit

result = book!("MU2", :accepted;
    result = fit_result,
    rationale = "Two-compartment model fits IV PK data well",
)
```

The `status` argument is a Symbol --- use `:accepted` or `:rejected`. Any other status throws an error.

### 2. Retrieve a result

In a later session or a downstream script, retrieve the booked result:

```julia
pk = lookup("MU2")
pk.data         # the original result object
pk.status       # :accepted
pk.rationale    # "Two-compartment model fits IV PK data well"
```

`BookedResult` forwards property access to the stored data, so if your result has `fitted_params`, you can access it directly:

```julia
pk.fitted_params  # delegates to fit_result.fitted_params
```

### 3. Verify staleness

Pass `verify=true` to check whether any files that contributed to the result have been modified:

```julia
pk = lookup("MU2"; verify=true)
```

If files have changed, you'll see a warning:

```
Warning: MU2 may be stale - 2 file(s) changed: ["data/pk.csv", "scripts/fit_pk.jl"]
```

### 4. Review history

See all bookings for a given name:

```julia
history("MU2")
```

```
History for 'MU2' (3 entries):
------------------------------------------------------------
  #5  [accepted]  2025-03-15 14:32:01  vcs=abc1234  loss=0.0234
        Two-compartment model fits IV PK data well
  #3  [rejected]  2025-03-14 10:15:22  vcs=def5678
        One-compartment model underpredicts Cmax
  #1  [accepted]  2025-03-12 09:00:05  vcs=789abcd
        Initial fit, exploratory
------------------------------------------------------------
```

### 5. Restore file snapshots

Extract the files that were snapshotted at booking time:

```julia
files = restore("MU2"; to="snapshots/mu2_v3")
```

This writes each attributed file to its original relative path under the target directory. You can then diff against your current files to see what changed.

## Typical Project Workflow

```julia
using BookKit

# --- Phase 1: Fit a PK model ---
# (run your fitting code here)
book!("PK_IV", :accepted;
    result = pk_fit,
    rationale = "CL and V estimates consistent with literature",
    fit_quality = Dict("RMSE" => 0.12, "r2" => 0.97),
    loss = 0.12,
)

# --- Phase 2: Use PK result as input to PD model ---
pk = lookup("PK_IV"; verify=true)
# (build PD model using pk.fitted_params)

book!("PD_Efficacy", :accepted;
    result = pd_fit,
    rationale = "EC50 within expected range, Hill coefficient ~1",
)

# --- Later: revisit with new data ---
book!("PK_IV", :accepted;
    result = pk_fit_v2,
    rationale = "Updated with additional subjects from cohort 2",
)
# The previous booking is still in history() — this one is now the latest
```

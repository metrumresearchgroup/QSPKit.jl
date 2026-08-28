# mrggsave

ShowKit wraps the public [mrggsave](https://github.com/metrumresearchgroup/mrggsave) package for saving ggplot objects with provenance annotation. Every saved figure is automatically stamped with the script name and output filename, making figures self-documenting.

## Basic Usage

```julia
using ShowKit

p = ggplot(df, aes(x=:TIME, y=:DV)) + geom_point() + theme_bw()

# Save a single plot
mrggsave(p, "pk-profile"; dir="deliv/figure")
```

This creates `deliv/figure/pk-profile.pdf` with an annotation footer showing the source script.

## Arguments

```julia
mrggsave(plot, stem;
    dir = ".",              # output directory
    script = nothing,       # source script name; nothing = auto-detect calling .jl
    dev = ["pdf"],          # device(s): "pdf", "png", or both
    width = 5.0,            # width in inches
    height = 4.0,           # height in inches
    # ... additional kwargs passed to mrggsave R function
)
```

### Output Formats

```julia
# PDF only (default)
mrggsave(p, "fig1"; dev="pdf")

# PNG only
mrggsave(p, "fig1"; dev="png")

# Both PDF and PNG
mrggsave(p, "fig1"; dev=["pdf", "png"])
```

### Script Annotation

The `script` argument stamps the figure with the generating script name:

```julia
mrggsave(p, "dv-pred";
    dir="deliv/figure",
    script="analysis/pk-diagnostics.jl",
    dev=["pdf", "png"],
    width=6, height=5,
)
```

The annotation appears as a small footer on the saved figure: `analysis/pk-diagnostics.jl / dv-pred`.

When `script` is omitted, it is auto-detected from the `.jl` file that called `mrggsave`, so figures run from a script are self-documenting without any extra argument. Calling `mrggsave` from the REPL (or another interactive session, where there is no source file) raises an error asking for an explicit `script` — this keeps figures from being stamped with a meaningless source. The same applies to [`mrggsave_list`](@ref).

## Saving Multiple Plots

### Named List

```julia
plots = [
    dv_pred(df) + theme_bw(),
    cwres_time(df) + theme_bw(),
    eta_hist(df; x="ETA1//CL"),
]

mrggsave_list(plots;
    stems=["dv-pred", "cwres-time", "eta-cl"],
    dir="deliv/figure",
    script="analysis/diagnostics.jl",
    dev=["pdf", "png"],
    width=6, height=5,
)
```

This creates six files:
- `deliv/figure/dv-pred.pdf`, `deliv/figure/dv-pred.png`
- `deliv/figure/cwres-time.pdf`, `deliv/figure/cwres-time.png`
- `deliv/figure/eta-cl.pdf`, `deliv/figure/eta-cl.png`

## Complete Workflow Example

```julia
using ShowKit, DataFrames, CSV

# Load data
df = CSV.read("data/derived/pk-data.csv", DataFrame)

# Create all diagnostic plots
plots = [
    dv_pred(df) + ggtitle("DV vs PRED"),
    dv_ipred(df) + ggtitle("DV vs IPRED"),
    cwres_time(df) + ggtitle("CWRES vs TIME"),
    cwres_pred(df) + ggtitle("CWRES vs PRED"),
    npde_time(df) + ggtitle("NPDE vs TIME"),
    npde_pred(df) + ggtitle("NPDE vs PRED"),
]

stems = [
    "dv-pred", "dv-ipred",
    "cwres-time", "cwres-pred",
    "npde-time", "npde-pred",
]

# Save all with provenance
mrggsave_list(plots;
    stems=stems,
    dir="deliv/figure",
    script="script/pk-diagnostics.jl",
    dev=["pdf", "png"],
    width=5.5, height=4.5,
)
```

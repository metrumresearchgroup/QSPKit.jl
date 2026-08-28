# pmtables

ShowKit wraps the public [pmtables](https://metrumresearchgroup.github.io/pmtables/) package for creating pharmacometric summary tables as LaTeX output. Tables are built with a pipeline pattern using `|>`.

## Overview

The pmtables workflow has two stages:

1. **Create** a table object with `pt_*()` functions → returns `PMTable`
2. **Modify and render** with `st_*()` pipeline functions, then `stable()` → returns `LaTeXTable`

## Continuous Summary Tables

### Wide Format

Groups as columns, statistics as rows:

```julia
using ShowKit, DataFrames

tbl = pt_cont_wide(df; cols=[:WT, :AGE, :SCR, :ALB], by="STUDYf") |>
      st_units(WT="kg", AGE="years", SCR="mg/dL", ALB="g/dL") |>
      st_notes(["BLQ values excluded from summary"]) |>
      stable

stable_save(tbl, "deliv/table/cont-summary.tex")
```

### Long Format

Groups as rows, one statistic per row:

```julia
tbl = pt_cont_long(df; cols=[:WT, :AGE], by="SEXf") |>
      st_units(WT="kg", AGE="years") |>
      stable
```

## Categorical Summary Tables

```julia
# Wide format (groups as columns)
tbl = pt_cat_wide(df; cols=[:SEXf, :RACEf], by="STUDYf") |>
      st_caption("Categorical covariate summary") |>
      stable

# Long format
tbl = pt_cat_long(df; cols=[:SEXf, :RACEf]) |>
      stable
```

## Demographics Table

Mixed continuous and categorical in one table:

```julia
tbl = pt_demographics(df; cols="WT,AGE,SCR,SEXf,RACEf", by="STUDYf") |>
      st_units(WT="kg", AGE="years", SCR="mg/dL") |>
      stable
```

## Data Inventory

Subject/observation/BLQ counts:

```julia
tbl = pt_data_inventory(df; by="STUDYf") |>
      st_caption("Data inventory by study") |>
      stable
```

## The Pipeline

All `st_*()` functions have two forms:

```julia
# Direct form: takes PMTable as first argument
tbl2 = st_units(tbl; WT="kg")

# Curried form: returns a function for |> piping
tbl2 = tbl |> st_units(WT="kg")
```

This makes pipelines readable:

```julia
result = pt_cont_wide(df; cols=[:WT, :AGE]) |>
         st_units(WT="kg", AGE="years") |>
         st_caption("Continuous covariate summary") |>
         st_notes(["Values are mean (SD)"; "N = number of subjects"]) |>
         stable
```

### Available Pipeline Functions

| Function | Purpose | Example |
|----------|---------|---------|
| `st_units(; col="unit")` | Add units row under headers | `st_units(WT="kg")` |
| `st_notes(notes)` | Add footnotes | `st_notes(["a", "b"])` |
| `st_caption(text)` | Set caption | `st_caption("Table 1")` |
| `st_files(; output=path)` | Set output path | `st_files(output="t.tex")` |
| `st_span(label; ...)` | Spanning header | `st_span("Treatment"; ...)` |
| `st_rename(; ...)` | Rename columns | `st_rename(WT="Weight")` |
| `st_bold(; ...)` | Bold content | `st_bold()` |
| `st_clear_reps(cols...)` | Blank consecutive repeated values | `st_clear_reps("STUDY")` |
| `st_clear_grouped(cols...)` | Blank repeated values hierarchically | `st_clear_grouped("name", "unit", "description")` |
| `tab_clear_reps(data, cols...; grouped=false)` | Return a DataFrame with repeats blanked immediately | `tab_clear_reps(df, :name)` |
| `st_align(; kwargs...)` | Set default and per-column alignment or widths | `st_align(_default="l", description=col_ragged(6))` |
| `col_fixed(width)` / `col_ragged(width)` | Build fixed-width LaTeX column specifications | `col_ragged(4)` |

### Keyword names

pmtables keyword names are passed to R **literally**, underscores and all:
`lt_cap_label`, `note_config`, `all_name`, and column names such as
`keyfile_value` all arrive unchanged. This differs from the ggplot2 wrappers,
where `axis_text_x` is translated to `axis.text.x`.

The one translation is a **leading** underscore, which becomes a leading dot —
Julia cannot spell pmtables' dot-prefixed arguments directly:

```julia
st_align(_default = "l", keyfile_value = col_ragged(2))   # .default = "l"
```

## Rendering

### To LaTeX String

```julia
latex = stable(tbl)           # standard tabular
latex = stable_long(tbl)      # longtable environment
```

Both take pmtables arguments, and both have curried forms for piping:

```julia
latex = params |>
    st_new |>
    st_align(_default = "l", description = col_ragged(5.25)) |>
    stable_long(lt_cap_text  = "Model parameters.",
                lt_cap_label = "tab-param-table")
```

!!! note "Captions in longtables"
    `st_caption()` and the `lt_cap_*` arguments are mutually exclusive in
    pmtables. If a caption was set with `st_caption()`, `stable_long()` builds
    `\caption{...}` from it and ignores `lt_cap_text`, `lt_cap_short`,
    `lt_cap_label`, and `lt_cap_macro` — so no `\label{}` is emitted. To get a
    label, pass the caption as `lt_cap_text` instead of using `st_caption()`.

### To File

```julia
# Save LaTeXTable to .tex file
stable_save(latex, "deliv/table/summary.tex")

# Or directly from PMTable
stable_save(tbl, "deliv/table/summary.tex")
```

### To PNG

Render the table as an image (useful for previewing):

```julia
st2png(tbl, "preview/table.png")
```

In VS Code and other PNG-capable Julia displays, leaving either a `PMTable`
or the `LaTeXTable` returned by `stable` as the final expression renders the
table automatically in the preview pane.

## Complete Example

```julia
using ShowKit, DataFrames, CSV

# Load NONMEM output
df = CSV.read("run001.csv", DataFrame)

# Demographics table
demog = pt_cont_wide(df;
    cols=[:WT, :AGE, :HT, :BMI, :SCR, :ALB],
    by="STUDYf",
) |>
st_units(WT="kg", AGE="years", HT="cm", BMI="kg/m2", SCR="mg/dL", ALB="g/dL") |>
st_caption("Table 1. Continuous covariate summary by study") |>
st_notes([
    "Values are mean (SD) [min, max]",
    "N = number of subjects with non-missing values",
]) |>
stable

stable_save(demog, "deliv/table/demog-cont.tex")

# Categorical summary
cats = pt_cat_wide(df;
    cols=[:SEXf, :RACEf, :FORMf],
    by="STUDYf",
) |>
st_caption("Table 2. Categorical covariate summary by study") |>
st_notes(["Values are n (%)"; "Denominator is group total"]) |>
stable

stable_save(cats, "deliv/table/demog-cat.tex")
```

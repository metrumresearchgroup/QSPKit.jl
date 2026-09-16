"""
    TargKit

A QSPKit subpackage for declaring and scoring calibration targets.
v4: TargetSet as pure data container with Pair syntax constructors.
    Sim mapping at score/fit time, not construction time.
"""
module TargKit

# Standard library
using SHA
using Statistics: mean
import Base: show

# External dependencies
using DataFrames
using DataFramesMeta
using CSV
using OrderedCollections: OrderedDict
import Tables
import ConfigKit
import QSPKitCore
import SymbolicIndexingInterface

# ============================================================
# Include source files
# ============================================================

# Core types
include("types.jl")
include("source_fp.jl")
include("targets.jl")

# TargetSet system
include("targetspec/types.jl")
include("targetspec/targetset.jl")
include("targetspec/validate.jl")
include("targetspec/helpers.jl")
include("targetspec/filtering.jl")

# Scoring, optimization, display
include("scoring.jl")
include("objective.jl")
include("pipeline_types.jl")
include("fit.jl")         # imports Optimization, OptimizationOptimJL (ParticleSwarm, NelderMead, etc.)
include("pipeline.jl")    # uses solver types from fit.jl
include("display.jl")
include("fingerprint.jl")

# ============================================================
# Public API Exports
# ============================================================

# Core API
export fit, score, objective, targets, Stage
export setup, finish, inspect_fit, score_fit, checkpoint

# Types
export FitResult, ScoreReport, TargetSet
export FitState, StageResult, FitStep, FitPipeline

# Named presets
export PSO_NM, NM_ONLY, LBFGS_ONLY

# Helpers
export fingerprint, reset!, validate, filter_flags, where

# Re-exports: DataFrames
export DataFrame, nrow, eachrow, groupby, innerjoin, leftjoin

# Re-exports: DataFramesMeta
export @chain, @rsubset, @rtransform, @rselect, @select, @transform,
       @subset, @combine, @by, @rename, @orderby, @groupby

# Re-exports: CSV
export CSV

# Re-exports: Optimization solvers (needed for custom Stage pipelines)
export ParticleSwarm, NelderMead, LBFGS

end # module

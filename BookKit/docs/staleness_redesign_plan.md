# BookKit/StoreKit Staleness & Dependency-Capture — Audit & Redesign Plan

*Status: design. Produced 2026-06-24. Backed by a 17-agent adversarial audit of the
live code and a reproducible per-method-fingerprinting feasibility spike. Supersedes the
scope described in `BookKit/docs/src/staleness.md` (which documents only today's
files-only behavior).*

> ## STATUS: IMPLEMENTED (2026-06-24)
> Phases 1–3 are built, tested, and committed on `bayeskit-forwarddiff-reduced`.
> Phase 1 (`602a8c0`, `bbabb70`): writes-as-inputs fix + structured `staleness()`
> over files/upstream/vcs/blob. Phase 2 (`22f4375`…`04aeced`): per-method IR source
> fingerprinting, `book!(...; fingerprints/metrics)`, `book_extract` typed dispatch,
> TargKit/SimKit extractors, `artifact()`. Phase 3 (`b3681fc`, `311ae29`): env capture
> (Manifest + Julia `VERSION`) and RNG-seed-as-dependency (BayesKit). Two adversarial
> review passes (Phase 1b, Phase 2) caught and fixed real bugs incl. a critical
> restore-clobber. Deferred items are in §7. `SimKit/src` was never touched.
>
> ## TL;DR
> Today BookKit's **only** staleness mechanism is `lookup(name; verify=true)` re-hashing
> the latest annotation's *data-file* snapshots. Everything else that can change a QSP
> result is either **never captured** (model, parameters, code, package versions, RNG seed,
> solver config) or **captured-but-never-checked** (upstream `input_hash`, VCS ref, result
> blob). The machinery to do better (an IR source-dependency tracer) was **built but never
> wired in**. This plan fixes the capture gap in three phases, with **zero scientist
> ceremony** (`produced_by` and the `cached() do … end` do-block are both rejected), and
> makes **per-method lowered-IR fingerprinting** a Phase-2 requirement so that shared
> `helper.jl` files don't trigger blanket false-stale.

---

## 1. Verified current reality (the audit)

Every claim below was confirmed by reading the live code; the audit adversarially
re-checked each and corrected two first-pass errors (noted inline).

### 1.1 The one working mechanism
`lookup(name; verify=true)` (`BookKit/src/lookup.jl:22-35`) loads the **latest** annotation's
`file_snapshots`, re-hashes each file with `hash_file` (raw SHA-256, `StoreKit/src/store.jl:76-80`),
and `@warn`s on any content-hash mismatch or deletion. It is **opt-in** (`verify=false`
default), **advisory** (warn-only), and **head-revision only**. Capture side:
`book!` content-hashes attributed files into `file_snapshots` (`book.jl:151-156`) using
`blob_put_file!` whose blob key equals `hash_file` (`store.jl:121-133`), so the stored hash
serves both `restore` and `verify`.

### 1.2 Captured but DEAD (data is in the DB, nothing checks it)
- **Upstream booked-result drift.** `result_inputs.input_hash` pins the upstream
  `result_hash` at read time (`book.jl:159-163`, schema `StoreKit/src/db.jl:49-57`), but it is
  read **only** by `lineage.jl:507` to draw the DAG — and `LineageEdge` (`lineage.jl:66-73`)
  has no hash field, so the pin is structurally discarded. ⇒ **no transitive staleness**.
- **VCS ref + dirty** (`book.jl:121,140-143`, `vcs.jl`): stored, shown in `history`/lineage,
  **never diffed** against the working tree at verify.
- **Result blob integrity:** `result_hash` is stored but the blob is never re-hashed; a
  corrupted/edited blob is returned silently.

### 1.3 Built but UNWIRED
StoreKit ships a real IR/source-dependency tracer — `_discover_closure_source_deps` /
`_trace_fn_deps!` / `_scan_deps_recursive!` (`StoreKit/src/tracing.jl:111-247`), exported
(`StoreKit.jl:26`) and unit-tested — with **zero callers** from `book!`/`lookup` (only its own
recursion + tests). `cached()` is **not implemented** (only referenced in comments,
`lineage.jl:7-10`). TracKit is fully removed. `book!` filters attribution through
`_is_attributable_file` (the *data* predicate, `tracing.jl:74-92`), never `_is_user_file`
(the `.jl` predicate, `tracing.jl:44`).

### 1.4 Never captured at all
MTK model / ODE definition; parameters & config supplied as in-memory values (θ, Ω/Σ, p0,
doses, tspan); package / `Manifest.toml` / Julia version; RNG seed; solver config
(reltol/alg/sensealg/metric); ENV / BLAS threads / FP platform; non-`open` I/O (1-arg
`open(path)` handle, mmap, network/DB).

### 1.5 Correctness bugs (not just gaps)
- **Writes counted as inputs.** The `Base.open(f, path, mode)` override (`file_tracking.jl:36-41`)
  is mode-blind and stores no mode; a file the run *wrote* is snapshotted as a `"data"`
  dependency ⇒ **false-positive** stale when that output is regenerated. (`const FILE_READS`
  and the docs are misleading — it logs writes too.)
- **Silent no-op bookings.** Interactive attribution finds the result's files by `===`
  identity against a `Main` binding (`_find_result_var`, `book.jl:228-243`). An
  anonymous / copied / inline result ⇒ `result_var === nothing` ⇒ **zero snapshots** ⇒
  `verify` is a permanent no-op that always reports "fresh." Most dangerous mode: looks like
  it works.
- **Script-mode over-attribution.** `book!` dumps the entire process-global, never-cleared
  `FILE_READS` (`book.jl:108-113`); the smarter `_script_mode_attribution` (`attribution.jl:60-108`)
  is itself dead code.
- TOCTOU (hash taken at `book!` time, not read time); `expr_id=0` reads dropped;
  `_CURRENT_EXPR_ID` is a process-global `Ref` (not task-local) ⇒ concurrency
  cross-contamination; deleted-before-`book!` files silently skipped.

*Audit corrections worth keeping:* `read(path)` / `read(path, String)` **are** captured
(they route through the do-block `open`); the genuine bypass is the 1-arg handle form
`open(path)` / `open(path, "r")` plus mmap/ccall/network. And `_script_mode_attribution`
is dead — the real script path is the blunter all-of-`FILE_READS` dump.

### 1.6 Honest framing
`BookKit/docs/src/staleness.md` only ever claimed "check the contributing **files**,
best-effort." The implementation matches that narrow claim — it just falls far short of
"capture everything that touches the artifact," which for QSP is model + params + code +
data + versions + seed.

---

## 2. Design principles

1. **Two dependency kinds, two staleness flavors.**
   - *On-disk* deps (data files, `.jl` source, `Manifest.toml`, keyfiles) → **cold-store
     re-hashable** by `verify` (today's file model).
   - *In-memory* deps (params, solver config, model built in code, seed) → there is nothing
     on disk to re-read later, so capturing them buys **diff-at-rebook / explicit-check**
     staleness ("MU3's params differ from when it was accepted"), not passive cold verify.
     This is still hugely valuable — just a different question.

2. **Typed extractors are the delivery vehicle.** A type-agnostic core stores any payload +
   open `metrics` + `kind` + `inputs` + a `fingerprints` map. Package **extensions**
   (weakdeps, like the existing `BookKitMetaGraphsNextExt`) teach `book_extract` to pull
   dependency fingerprints out of the result objects that carry them — so the *caller* never
   hand-copies `loss`/params/model. The objects already hold what we need:
   - `TargKit.FitResult` (`TargKit/src/types.jl:60`): `params`, `loss`, `report`, `converged`, `method`.
   - `SimKit.SimContext` (`SimKit/src/types.jl:24`): `prob`, `sys`, `solver`, `solve_kwargs`,
     `events`, `params`.

3. **Zero scientist ceremony — hard constraint.** Both `produced_by=` and the
   `cached("name") do … end` do-block are **rejected** (the research deep-dive judged the
   do-block "too much ceremony / confusing", and concluded true zero-ceremony for *arbitrary*
   expressions is impossible). The achievable zero-ceremony routes are **library-internal
   self-tracing** (a QSPKit function fingerprints its own closure from the inside) and the
   **REPL/VSCode `ast_transforms` session log** (already implemented for file attribution).

4. **The three code-staleness routes (no-ceremony):**
   - **Route 2 — library-internal IR self-tracing (BACKBONE).** `fit()`/`simulate()` call
     `_discover_closure_source_deps` on their own closure, attach per-method hashes to
     `FitResult`/`SimContext`; the extractor books them. REPL-safe; reachability-scoped so
     *unused* includes are not deps. For IR deps, do **not** apply `_is_attributable_file`
     (dev'd-package source is a real dep).
   - **Route 3 — `hash(equations(sys))` model fingerprint.** The MTK model is a
     `RuntimeGeneratedFunction`, invisible to the IR trace, so fingerprint it structurally
     from `SimContext.sys`.
   - **Route 1 — `.jl` snapshots, DEMOTED.** Only the reachability-filtered files + the
     top-level driver script (non-function glue route 2 can't reach). Raw wholesale `include`
     hashing is *rejected* — see §3.

---

## 3. Per-method lowered-IR fingerprinting (Phase-2 REQUIREMENT)

**Why required, not deferred.** Scientists here heavily share `helper.jl`-style files.
File-granular hashing would flag *every* artifact that touched `helpers.jl` stale the moment
*any* unrelated function in it is edited. Constant false alarms → people ignore the warning →
the system is worse than useless. So Phase 2 must hash at **method** granularity.

**Mechanism — a leaf swap, not a new subsystem.** The reachability walk already exists
(dead) in `_trace_fn_deps!`: it follows `GlobalRef`s out of a closure to discover reachable
functions. We replace its **leaf** — "hash the whole `.jl` file" — with "hash
`Base.uncompressed_ast(m)` normalized per method" (drop `LineNumberNode`s; canonicalize). One
`CodeInfo` per `Method`, type-independent, comment/format-insensitive.

**Validated 2026-06-24** by a feasibility canary now in the suite
(`BookKit/test/method_fingerprint_feasibility.jl`, wired into `runtests.jl`). Results:

| Check | Result |
|---|---|
| (a) determinism across recompute **and** redefinition of identical source | ✅ |
| (b) editing an **unused** sibling fn leaves used fns' hashes unchanged — **THE requirement** | ✅ |
| (c) editing a **used** fn changes its hash | ✅ |
| (d) callee recoverable as `GlobalRef` from caller's lowered IR (transitive walk works) | ✅ |
| (e) works on REPL-defined methods (no on-disk source) | ✅ |

**Bonus simplification:** because `uncompressed_ast` works on REPL-defined methods (check e),
per-method IR hashing **unifies** package / dev'd-package / `include`d / REPL-authored
functions under one path. The separate session-log expression-hash fallback is then only
needed for top-level **non-function** driver glue.

**Known limits (on the record):**
1. **Intra-Julia-version only** — lowered IR layout can shift across Julia versions. Caught
   explicitly because Phase 3 hashes Julia `VERSION` separately (so a version change is a
   visible dep change, not a silent mis-compare).
2. **Static reachability** — a callee reached via a variable / higher-order arg / dynamic
   dispatch (not a literal `GlobalRef`) is invisible ⇒ possible false-*fresh*. Same limit as
   R's `targets`/`codetools`. Mitigated by independent param/data capture; consider a
   conservative fallback flag later.
3. **`@generated` functions** — generator runs per type; hash the generator (edge case).

---

## 4. Phased plan

### Phase 1 — Wire up what's already captured (no new capture)
Highest value-to-effort; independent of the extractor redesign.
- `verify` compares each `result_inputs.input_hash` against the upstream's **current**
  `result_hash`, and **recurses** ⇒ transitive staleness. (Data already pinned.)
- `verify` re-runs `_vcs_describe()` and diffs vs stored `vcs_ref`/`vcs_dirty`.
- `verify`/`lookup` re-hash the result blob vs `result_hash` (integrity).
- Return a structured `StalenessReport` (per-dimension), not just `@warn`; allow checking any
  revision, not only head.
- **Bugfix:** record open mode and drop writes from attribution (kills writes-as-inputs
  false positives).

### Phase 2 — Code + in-memory dependency capture via typed extractors
Depends on the generic-core + `book_extract` + `artifact()` redesign.
- Generic core: type-agnostic payload + `metrics` + `kind` + `inputs` + **`fingerprints`** map.
- **Route 2** per-method IR self-tracing (§3) wired into `TargKit.fit` / `SimKit.simulate`,
  surfaced on `FitResult` / `SimContext`, booked by `book_extract`.
- **Route 3** `hash(equations(sys))` model fingerprint from `SimContext`.
- **Route 1** reachability-filtered `.jl` + driver-script snapshot only.
- In-memory dep fingerprints: params (`FitResult.params` / `prob.p`), solver config
  (`solver` + `solve_kwargs`), doses (`events`).
- `artifact(path)` convention for figures/CSVs/reports (reliable explicit on-disk capture,
  routing around the fragile `Base.open` attribution).
- `verify` checks the new `fingerprints` (diff-at-rebook for in-memory; cold re-hash for
  on-disk `.jl`/model-source).

### Phase 3 — Remaining new capture
- `Manifest.toml` + Julia `VERSION` hash (on-disk ⇒ cold-verifiable; fits the file model).
- **RNG seed as a dependency** (strict reproducibility — every reseed reads as changed, by
  choice). **API requirement:** BayesKit NUTS / SimKit population-sim must *surface* their
  `rng`/seed so the extractor can read it; global-RNG use can't be recovered after the fact.
- Deferred / low priority: ENV / BLAS threads / FP-platform capture; per-method body
  precision upgrade beyond reachability filtering; conservative fallback for non-`GlobalRef`
  call targets.

---

## 5. Capture matrix (gap → where it's addressed)

| Dependency dimension | Today | Addressed by |
|---|---|---|
| Project-local data files (do-block `open`) | ✅ captured + checked | Phase 1 hardening (`artifact()` for reliability) |
| Upstream booked-result drift (`input_hash`) | captured, **dead** | **Phase 1** (compare + recurse) |
| VCS ref/dirty | captured, **dead** | **Phase 1** (diff at verify) |
| Result blob integrity | captured, **dead** | **Phase 1** (re-hash) |
| `.jl` source of producing functions | ❌ | **Phase 2** route 2 (per-method IR) |
| MTK model / ODE definition | ❌ | **Phase 2** route 3 (`equations(sys)`) |
| Parameters / config (in-memory) | ❌ | **Phase 2** extractor fingerprints |
| Solver config / doses | ❌ | **Phase 2** extractor (`solve_kwargs`/`events`) |
| Package/Manifest/Julia version | ❌ | **Phase 3** (Manifest + VERSION hash) |
| RNG seed | ❌ | **Phase 3** (seed-as-dep; needs upstream API) |
| Writes mis-recorded as inputs | ❌ bug | **Phase 1** bugfix |
| Silent no-op bookings (`===` identity) | ❌ bug | **Phase 2** (typed/explicit capture bypasses Main-identity discovery) |
| Non-`open` I/O (mmap/handle/network) | ❌ | partial via `artifact()`; otherwise out of reach |

---

## 6. Locked decisions
- Auto-status from results: **yes, with override** (e.g. `FitResult.converged` →
  `:accepted`/`:rejected`; explicit `status=` always wins).
- Build scope: generic core + `metrics`; `artifact()` convention; TargKit + SimKit extractors.
- Code staleness (B1): **all three routes**, per-method IR as backbone, no `produced_by`/do-block.
- Stochastic artifacts (B5): **capture seed as a dependency** (strict repro).
- Persisted schema is **not** a constraint (in-development; free to redesign).

---

## 7. Open items / risks
- Per-method IR normalization must be hardened + tested against the **real** QSPKit closures
  (`fit`, `solve_subject`, likelihood/objective/transform) — the canary uses toy functions.
- Route-2 must skip `_is_attributable_file` for IR deps (dev'd-package source is a real dep)
  but still avoid hashing Base/stdlib — needs a distinct predicate.
- Seed capture requires BayesKit/SimKit API changes (surface the rng) — cross-package.
- `metrics`/`fingerprints` schema design (queryable vs opaque) — see the kwargs-redesign
  discussion; `loss` should fold into `metrics`, not stay a privileged column.
- **Deferred (low severity, from the Phase-1b adversarial review):** (a) a transitive
  upstream chain deeper than `max_depth` (64) yields a `:depth_exceeded` note and the
  upstream dimension reports `stale=false` — not authoritative for pathologically deep
  DAGs (the `visited` set already guarantees termination, so the cap is only a stack
  backstop). (b) Duplicate `result_inputs` rows for one upstream can yield duplicate
  per-edge findings; deduped at the detail level via `unique`, but a
  `UNIQUE(annotation_id, input_name)` schema constraint would be cleaner.

---

## 8. References
- Audit: 17-agent adversarial workflow, 2026-06-24 (verified findings above).
- Feasibility canary: `BookKit/test/method_fingerprint_feasibility.jl` (in the suite).
- Current behavior doc this supersedes in scope: `BookKit/docs/src/staleness.md`.
- Research context: `docs/research/deep_dive_general_computation_caching.md`,
  `docs/research/PROMPT_general_computation_caching.md` (zero-ceremony conclusion;
  `produced_by`/do-block rejection).
- Kwargs/extractor redesign discussion (generic core, `metrics`, `artifact()`, `book_extract`).

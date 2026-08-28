# ============================================================
# fingerprint — deterministic hash of target DataFrames
# ============================================================

"""
    fingerprint(dfs::AbstractDataFrame...) -> String

Compute a deterministic 16-character hex fingerprint of target DataFrames.
Hashes column names, :name, :value, and :weight (if present) for each row.
Use this to detect when targets change (for example, to invalidate cached work).
"""
function fingerprint(dfs::AbstractDataFrame...)::String
    ctx = SHA.SHA256_CTX()
    for df in dfs
        # Hash column names for structural changes
        for col in sort(string.(names(df)))
            SHA.update!(ctx, Vector{UInt8}(col))
        end
        for row in eachrow(df)
            SHA.update!(ctx, Vector{UInt8}(string(row.name)))
            SHA.update!(ctx, Vector{UInt8}(string(row.value)))
            if hasproperty(row, :weight) && !ismissing(row.weight)
                SHA.update!(ctx, Vector{UInt8}(string(row.weight)))
            end
            if hasproperty(row, :lower) && !ismissing(row.lower)
                SHA.update!(ctx, Vector{UInt8}(string(row.lower)))
            end
            if hasproperty(row, :upper) && !ismissing(row.upper)
                SHA.update!(ctx, Vector{UInt8}(string(row.upper)))
            end
            if hasproperty(row, :loss) && !ismissing(row.loss)
                SHA.update!(ctx, Vector{UInt8}(string(row.loss)))
            end
        end
    end
    return bytes2hex(SHA.digest!(ctx))[1:16]
end

# CondaR

R and R packages are provisioned automatically on first use in a private environment.
The consuming project can follow `pkgr.yml` or select latest packages using
`ShowKit.configure_r!(mode=:latest)`. Settings persist without shell variables.

See `CondaR/README.md` in the QSPKit repository for configuration, isolation,
version tracking, switching, and troubleshooting.

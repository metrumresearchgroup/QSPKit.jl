# Security

## Supported release

Only the latest QSPKit alpha candidate is supported. This repository has not
yet declared a stable compatibility or security-support window.

## Reporting

Do not publish exploit details in a public issue. Contact the repository owner
through the private security-reporting channel configured for the eventual
hosting repository. A concrete address or advisory URL must be added before
public release.

## Trusted-input boundary

ConfigKit keyfiles can contain Julia expression strings that are evaluated
while values and symbolic bindings are resolved. Treat keyfiles as executable
code. Do not load keyfiles supplied by untrusted users, and do not use this
alpha as a sandbox for multi-tenant keyfile evaluation.

Model code, callbacks, and serialized Julia objects are likewise trusted
application inputs. Dependency vulnerabilities should be evaluated against the
resolved manifests produced in CI.

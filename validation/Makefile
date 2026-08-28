JULIA ?= julia
ROOT := $(abspath $(CURDIR)/..)
PROJECT := $(ROOT)/validation
GENERATOR := $(PROJECT)/generate.jl
PACKAGES := BookKit CondaR ConfigKit InjecKit QSPKitCore QSPKitIO QSPReports ShowKit SimKit SpecKit StoreKit TargKit

.PHONY: help
help:
	@echo "QSPKit SDLC evidence"
	@echo
	@echo "  make instantiate       install validation, test, and docs dependencies"
	@echo "  make sanitize          scan release content for identifying material"
	@echo "  make validate          run sanitization and validate all traceability matrices"
	@echo "  make privacy           reject unsafe public evidence before upload"
	@echo "  make pdf-privacy       extract and scan all 13 rendered-card PDFs"
	@echo "  make test-tooling      test score calculations and matrix validation"
	@echo "  make all-packages      test every package and build package + QSPKit cards"
	@echo "  make package PKG=...   test one package and build its card"
	@echo "  make aggregate         rebuild the QSPKit card from existing package cards"
	@echo "  make render            optionally render all 13 cards with mpn.scorecard"
	@echo "  make all               run the complete machine-readable evidence workflow"
	@echo "  make package-dev PKG=...  development-only package evidence"
	@echo "  make all-dev           development-only working-tree evidence"
	@echo "  make aggregate-dev     development-only aggregate evidence"
	@echo "  make clean             remove generated evidence, builds, manifests, coverage, and local package state"

.PHONY: instantiate
instantiate:
	$(JULIA) --startup-file=no --project='$(ROOT)' -e 'using Pkg; Pkg.instantiate()'
	$(JULIA) --startup-file=no --project='$(PROJECT)' -e 'using Pkg; Pkg.instantiate()'
	@for pkg in $(PACKAGES); do \
		for environment in test docs; do \
			$(JULIA) --startup-file=no --project='$(ROOT)/'$$pkg/$$environment -e 'using Pkg; Pkg.instantiate()' || exit $$?; \
		done; \
	done

.PHONY: sanitize
sanitize:
	cd '$(ROOT)' && $(JULIA) --startup-file=no --project='$(PROJECT)' '$(PROJECT)/sanitize.jl'

.PHONY: validate
validate: sanitize
	cd '$(ROOT)' && $(JULIA) --startup-file=no --project='$(PROJECT)' '$(GENERATOR)' validate

.PHONY: privacy
privacy:
	cd '$(ROOT)' && $(JULIA) --startup-file=no --project='$(PROJECT)' '$(GENERATOR)' privacy

.PHONY: pdf-privacy
pdf-privacy:
	cd '$(ROOT)' && $(JULIA) --startup-file=no --project='$(PROJECT)' '$(GENERATOR)' pdf-privacy '$(PROJECT)/cards'

.PHONY: test-tooling
test-tooling:
	cd '$(ROOT)' && $(JULIA) --startup-file=no --project='$(PROJECT)' '$(PROJECT)/test/runtests.jl'

.PHONY: package
package:
	@test -n "$(PKG)" || { echo >&2 "PKG is required (one of: $(PACKAGES))"; exit 2; }
	cd '$(ROOT)' && $(JULIA) --startup-file=no --project='$(PROJECT)' '$(GENERATOR)' package '$(PKG)'

.PHONY: all-packages
all-packages:
	cd '$(ROOT)' && $(JULIA) --startup-file=no --project='$(PROJECT)' '$(GENERATOR)' all

.PHONY: aggregate
aggregate:
	cd '$(ROOT)' && $(JULIA) --startup-file=no --project='$(PROJECT)' '$(GENERATOR)' aggregate

.PHONY: package-dev
package-dev:
	@test -n "$(PKG)" || { echo >&2 "PKG is required (one of: $(PACKAGES))"; exit 2; }
	cd '$(ROOT)' && $(JULIA) --startup-file=no --project='$(PROJECT)' '$(GENERATOR)' package-dev '$(PKG)'

.PHONY: all-dev
all-dev:
	cd '$(ROOT)' && $(JULIA) --startup-file=no --project='$(PROJECT)' '$(GENERATOR)' all-dev

.PHONY: aggregate-dev
aggregate-dev:
	cd '$(ROOT)' && $(JULIA) --startup-file=no --project='$(PROJECT)' '$(GENERATOR)' aggregate-dev

.PHONY: verify
verify:
	cd '$(ROOT)' && $(JULIA) --startup-file=no --project='$(PROJECT)' '$(GENERATOR)' verify

.PHONY: verify-dev
verify-dev:
	cd '$(ROOT)' && $(JULIA) --startup-file=no --project='$(PROJECT)' '$(GENERATOR)' verify-dev

.PHONY: render
render: verify privacy
	cd '$(PROJECT)' && Rscript --vanilla render-scorecards.R output cards
	$(MAKE) pdf-privacy

.PHONY: all
all: instantiate validate test-tooling all-packages privacy

.PHONY: clean
clean:
	cd '$(ROOT)' && $(JULIA) --startup-file=no --project='$(PROJECT)' '$(GENERATOR)' clean

VERSION ?= $(shell git describe --tags --always --long --dirty)

MODULES = lib/header.sh \
          lib/log.sh \
          lib/path.sh \
          lib/json.sh \
          lib/symlink.sh \
          lib/preflight.sh \
          lib/git.sh \
          lib/config_block.sh \
          lib/service.sh \
          lib/backup.sh \
          lib/prompt.sh \
          lib/version.sh \
          lib/klipper.sh

BATS = test/bats-core/bin/bats

.PHONY: kpi.sh
kpi.sh: $(MODULES)
	@echo "#!/bin/bash" > $@
	@echo "# --- kpi.sh $(VERSION) ---" >> $@
	@echo "# Klipper Plugin Installer library" >> $@
	@echo "# https://github.com/mjonuschat/kpi-sh" >> $@
	@for f in $^; do \
	    echo "" >> $@; \
	    echo "# --- $$(basename $$f) ---" >> $@; \
	    grep -v '^#!/bin/bash' "$$f" >> $@; \
	done
	@echo "" >> $@
	@echo "# --- /kpi.sh ---" >> $@
	@chmod +x $@

.PHONY: test
test:
	$(BATS) test/*.bats

.PHONY: test-unit
test-unit:
	$(BATS) $(filter-out test/integration.bats,$(wildcard test/*.bats))

.PHONY: test-integration
test-integration: kpi.sh
	$(BATS) test/integration.bats

.PHONY: shellcheck
shellcheck:
	shellcheck lib/*.sh

.PHONY: checksum
checksum: kpi.sh
	sha256sum kpi.sh > kpi.sh.sha256

.PHONY: clean
clean:
	rm -f kpi.sh kpi.sh.sha256

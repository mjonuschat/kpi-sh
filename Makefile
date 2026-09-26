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
OUT = dist/kpi.sh

.PHONY: kpi.sh
kpi.sh: $(MODULES)
	@mkdir -p $(dir $(OUT))
	@echo "#!/bin/bash" > $(OUT)
	@echo "# --- kpi.sh $(VERSION) ---" >> $(OUT)
	@echo "# Klipper Plugin Installer library" >> $(OUT)
	@echo "# https://github.com/mjonuschat/kpi-sh" >> $(OUT)
	@for f in $^; do \
	    echo "" >> $(OUT); \
	    echo "# --- $$(basename $$f) ---" >> $(OUT); \
	    grep -v '^#!/bin/bash' "$$f" >> $(OUT); \
	done
	@echo "" >> $(OUT)
	@echo "# --- /kpi.sh ---" >> $(OUT)
	@chmod +x $(OUT)

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
	cd $(dir $(OUT)) && sha256sum kpi.sh > kpi.sh.sha256

.PHONY: clean
clean:
	rm -rf $(dir $(OUT))

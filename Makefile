PREFIX      ?= /usr/local
MANDIR      ?= $(PREFIX)/share/man
COMPDIR     ?= /etc/bash_completion.d
# shellcheck binary for `make lint` (CI passes a pinned release)
SHELLCHECK  ?= shellcheck
# nic-report.py needs Python 3.9+ (the one Python script: CLAUDE.md §2)
PYTHON      ?= python3
PY_MIN      := (3, 9)

# Primary script and companions: each ships a man page (section 8) and a completion
SCRIPTS     := nic-xray nic-health nic-sweep nic-report

.PHONY: install-man uninstall-man install-completion uninstall-completion test lint

install-man:
	install -d $(DESTDIR)$(MANDIR)/man8
	for s in $(SCRIPTS); do install -m 644 man/man8/$$s.8 $(DESTDIR)$(MANDIR)/man8/ || exit 1; done

uninstall-man:
	for s in $(SCRIPTS); do rm -f $(DESTDIR)$(MANDIR)/man8/$$s.8; done

install-completion:
	install -d $(DESTDIR)$(COMPDIR)
	for s in $(SCRIPTS); do install -m 644 completions/$$s.bash $(DESTDIR)$(COMPDIR)/$$s || exit 1; done

uninstall-completion:
	for s in $(SCRIPTS); do rm -f $(DESTDIR)$(COMPDIR)/$$s; done

test:
	bash tests/nic-health-test.sh
	bash tests/nic-xray-test.sh
	bash tests/nic-sweep-test.sh
	@if $(PYTHON) -c 'import sys; sys.exit(sys.version_info < $(PY_MIN))' 2>/dev/null; then \
		PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m unittest discover -s tests -p 'test_nic_report.py'; \
	else \
		echo "⏭️  SKIP nic-report tests: Python 3.9+ required ($$($(PYTHON) --version 2>&1))"; \
	fi

# Static analysis of the scripts and the test suite (needs shellcheck)
lint:
	@command -v $(SHELLCHECK) >/dev/null || { echo "lint: $(SHELLCHECK) not found; install shellcheck" >&2; exit 1; }
	$(SHELLCHECK) nic-xray.sh nic-health.sh nic-sweep.sh
	$(SHELLCHECK) -x tests/nic-health-test.sh tests/nic-xray-test.sh tests/nic-sweep-test.sh
	@# nic-report.py: Python 3.9 grammar (no bytecode written; needs Python 3.8+ to check); ruff when installed
	@if $(PYTHON) -c 'import sys; sys.exit(sys.version_info < (3, 8))' 2>/dev/null; then \
		echo "$(PYTHON): nic-report.py grammar check for Python 3.9"; \
		$(PYTHON) -c 'import ast, sys; [ast.parse(open(f, encoding="utf-8").read(), f, feature_version=$(PY_MIN)) for f in sys.argv[1:]]' nic-report.py tests/test_nic_report.py; \
	else \
		echo "⏭️  SKIP nic-report.py grammar check: Python 3.8+ required"; \
	fi
	@if command -v ruff >/dev/null; then ruff check nic-report.py tests/test_nic_report.py; fi

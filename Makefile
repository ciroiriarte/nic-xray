PREFIX      ?= /usr/local
MANDIR      ?= $(PREFIX)/share/man
COMPDIR     ?= /etc/bash_completion.d
# shellcheck binary for `make lint` (CI passes a pinned release)
SHELLCHECK  ?= shellcheck

# Primary script and companions: each ships a man page (section 8) and a completion
SCRIPTS     := nic-xray nic-health nic-sweep

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

# Static analysis of the scripts and the test suite (needs shellcheck)
lint:
	@command -v $(SHELLCHECK) >/dev/null || { echo "lint: $(SHELLCHECK) not found; install shellcheck" >&2; exit 1; }
	$(SHELLCHECK) nic-xray.sh nic-health.sh nic-sweep.sh
	$(SHELLCHECK) -x tests/nic-health-test.sh tests/nic-xray-test.sh tests/nic-sweep-test.sh

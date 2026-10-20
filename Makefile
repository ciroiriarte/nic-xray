PREFIX      ?= /usr/local
MANDIR      ?= $(PREFIX)/share/man
COMPDIR     ?= /etc/bash_completion.d

# Primary script and companions: each ships a man page (section 8) and a completion
SCRIPTS     := nic-xray nic-health

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

# Static analysis of the scripts and the test suite (needs shellcheck)
lint:
	shellcheck nic-xray.sh nic-health.sh
	shellcheck -x tests/nic-health-test.sh

PREFIX      ?= /usr/local
MANDIR      ?= $(PREFIX)/share/man
COMPDIR     ?= /etc/bash_completion.d

.PHONY: install-man uninstall-man install-completion uninstall-completion

install-man:
	install -d $(DESTDIR)$(MANDIR)/man8
	install -m 644 man/man8/nic-xray.8 $(DESTDIR)$(MANDIR)/man8/

uninstall-man:
	rm -f $(DESTDIR)$(MANDIR)/man8/nic-xray.8

install-completion:
	install -d $(DESTDIR)$(COMPDIR)
	install -m 644 completions/nic-xray.bash $(DESTDIR)$(COMPDIR)/nic-xray

uninstall-completion:
	rm -f $(DESTDIR)$(COMPDIR)/nic-xray

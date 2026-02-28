PREFIX  ?= /usr/local
MANDIR  ?= $(PREFIX)/share/man

.PHONY: install-man uninstall-man

install-man:
	install -d $(DESTDIR)$(MANDIR)/man8
	install -m 644 man/man8/nic-xray.8 $(DESTDIR)$(MANDIR)/man8/

uninstall-man:
	rm -f $(DESTDIR)$(MANDIR)/man8/nic-xray.8

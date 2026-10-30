# LinuxArch, the Linux app (Apps/LinuxArch), and its packages. The Mac app is
# built with tests/scripts/build-app.sh and scripts/release.sh.

.PHONY: build run app test install install-user uninstall deb flatpak icons

APP_ID := com.accidentalfish.LinuxArch
VERSION := $(shell sed -n 's/.*static let version = "\(.*\)"/\1/p' Apps/LinuxArch/Sources/LinuxArchApp.swift)
DATA := Apps/LinuxArch/data
ARCLIBRE := Apps/MacArch/Resources/ArcLibre

# Installs into $(DESTDIR)$(PREFIX): the programs in lib/linuxarch, with
# links in bin; ArcLibre (if this tree has it) and the release notes in
# share/linuxarch; and the desktop entry, icons, MIME types and metainfo.
PREFIX ?= /usr/local
DESTDIR ?=
LIBDIR := $(DESTDIR)$(PREFIX)/lib/linuxarch
SHAREDIR := $(DESTDIR)$(PREFIX)/share
PROGRAMS := linuxarch macarch-mcp macarch-cli

build:
	swift build --product linuxarch

run:
	swift run linuxarch

# The programs to install, with the Swift runtime linked in (so they only
# need the system's libraries).
app:
	swift build -c release --static-swift-stdlib --product linuxarch
	swift build -c release --static-swift-stdlib --product macarch-mcp
	swift build -c release --static-swift-stdlib --product macarch-cli

test:
	cd Packages/ArchimedesCore && swift test
	swift test

install: app
	install -d $(LIBDIR) $(DESTDIR)$(PREFIX)/bin
	install -m 755 -s $(addprefix .build/release/,$(PROGRAMS)) $(LIBDIR)/
	for program in $(PROGRAMS); do ln -sf ../lib/linuxarch/$$program $(DESTDIR)$(PREFIX)/bin/$$program; done
	install -Dm 644 $(DATA)/$(APP_ID).desktop $(SHAREDIR)/applications/$(APP_ID).desktop
	install -Dm 644 $(DATA)/$(APP_ID).metainfo.xml $(SHAREDIR)/metainfo/$(APP_ID).metainfo.xml
	install -Dm 644 $(DATA)/$(APP_ID).mime.xml $(SHAREDIR)/mime/packages/$(APP_ID).xml
	install -Dm 644 $(DATA)/icons/hicolor/scalable/apps/$(APP_ID).svg $(SHAREDIR)/icons/hicolor/scalable/apps/$(APP_ID).svg
	install -Dm 644 $(DATA)/icons/hicolor/symbolic/apps/$(APP_ID)-symbolic.svg $(SHAREDIR)/icons/hicolor/symbolic/apps/$(APP_ID)-symbolic.svg
	install -Dm 644 Apps/LinuxArch/WHATSNEW.md $(SHAREDIR)/linuxarch/WHATSNEW.md
	install -d $(SHAREDIR)/linuxarch/Classics $(SHAREDIR)/linuxarch/Covers
	install -m 644 Apps/MacArch/Resources/Classics/classics.json $(SHAREDIR)/linuxarch/Classics/
	install -m 644 Apps/MacArch/Resources/Covers/*.jpg $(SHAREDIR)/linuxarch/Covers/
	@if [ -f Apps/MacArch/Resources/Level4.adf ]; then \
		install -m 644 Apps/MacArch/Resources/Level4.adf $(SHAREDIR)/linuxarch/Level4.adf; \
	else \
		echo "(No Apps/MacArch/Resources/Level4.adf: file servers are set up from a Level 4 disc image chosen in the app.)"; \
	fi
	@if ls $(ARCLIBRE)/*.rom >/dev/null 2>&1; then \
		install -d $(SHAREDIR)/linuxarch/ArcLibre && install -m 644 $(ARCLIBRE)/* $(SHAREDIR)/linuxarch/ArcLibre/; \
	else \
		echo "(No ROM in $(ARCLIBRE): installing without ArcLibre; add RISC OS from the app.)"; \
	fi
	install -d $(SHAREDIR)/linuxarch/DriveSounds
	install -m 644 Apps/MacArch/Resources/DriveSounds/* $(SHAREDIR)/linuxarch/DriveSounds/
	install -Dm 644 LICENSE $(SHAREDIR)/licenses/linuxarch/LICENSE
	@if [ -z "$(DESTDIR)" ]; then \
		update-desktop-database -q $(SHAREDIR)/applications 2>/dev/null || true; \
		update-mime-database $(SHAREDIR)/mime 2>/dev/null || true; \
		gtk4-update-icon-cache -q -t -f $(SHAREDIR)/icons/hicolor 2>/dev/null || gtk-update-icon-cache -q -t -f $(SHAREDIR)/icons/hicolor 2>/dev/null || true; \
	fi

# For you alone, without sudo: in ~/.local (put ~/.local/bin on your PATH).
install-user:
	$(MAKE) install PREFIX=$(HOME)/.local

uninstall:
	rm -rf $(LIBDIR) $(SHAREDIR)/linuxarch $(SHAREDIR)/licenses/linuxarch
	rm -f $(addprefix $(DESTDIR)$(PREFIX)/bin/,$(PROGRAMS))
	rm -f $(SHAREDIR)/applications/$(APP_ID).desktop $(SHAREDIR)/metainfo/$(APP_ID).metainfo.xml
	rm -f $(SHAREDIR)/mime/packages/$(APP_ID).xml
	rm -f $(SHAREDIR)/icons/hicolor/scalable/apps/$(APP_ID).svg $(SHAREDIR)/icons/hicolor/symbolic/apps/$(APP_ID)-symbolic.svg

# A Debian/Ubuntu package, in .build/deb.
deb:
	scripts/make-linux-deb.sh $(VERSION)

# The Flatpak (needs flatpak-builder and Flathub's GNOME SDK).
flatpak:
	flatpak-builder --user --force-clean --install-deps-from=flathub .build/flatpak Apps/LinuxArch/flatpak/$(APP_ID).yml

# Redraws the icons (Tools/icon/draw-svg.py).
icons:
	python3 Tools/icon/draw-svg.py $(DATA)/icons/hicolor

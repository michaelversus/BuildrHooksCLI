# Define variables.
prefix ?= /usr/local
bindir = $(prefix)/bin

# Command building targets.
build:
	swift build -c release --disable-sandbox

install: build
	install -d "$(bindir)"
	install ".build/release/BuildrHooksCLI" "$(bindir)/buildrhooks"
	cp -R ".build/release/BuildrHooksCLI_BuildrHooksCLI.bundle" "$(bindir)/"
	cp -R ".build/release/BuildrHooksCLI_BuildrBridgeContracts.bundle" "$(bindir)/"

uninstall:
	rm -rf "$(bindir)/buildrhooks"
	rm -rf "$(bindir)/BuildrHooksCLI_BuildrHooksCLI.bundle"
	rm -rf "$(bindir)/BuildrHooksCLI_BuildrBridgeContracts.bundle"

clean:
	rm -rf .build

.PHONY: build install uninstall clean

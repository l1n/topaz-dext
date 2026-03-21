SWIFT = /usr/bin/swiftc
SDK = /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
SWIFTFLAGS = -O -sdk $(SDK) -framework Cocoa -framework CoreGraphics

.PHONY: all clean install uninstall app

all: topaz app

topaz: TopazCapture.swift
	env -i HOME="$(HOME)" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
		$(SWIFT) $(SWIFTFLAGS) -o $@ $<

app: topaz
	@mkdir -p Topaz.app/Contents/MacOS
	@cp topaz Topaz.app/Contents/MacOS/Topaz
	@echo "Built Topaz.app (menu bar app, no dock icon)"

install: topaz app
	@mkdir -p $(HOME)/.local/bin $(HOME)/Documents/Topaz\ Signatures
	@cp topaz $(HOME)/.local/bin/topaz
	@cp -R Topaz.app /Applications/Topaz.app 2>/dev/null || cp -R Topaz.app $(HOME)/Applications/Topaz.app
	@echo "Installed:"
	@echo "  CLI:  $(HOME)/.local/bin/topaz"
	@echo "  App:  /Applications/Topaz.app (or ~/Applications/)"
	@echo ""
	@echo "  Double-click Topaz.app or run 'topaz' for menu bar"
	@echo "  Run 'topaz capture' for CLI capture"
	@echo "  Run 'topaz daemon install' for login item"

uninstall:
	@rm -f $(HOME)/.local/bin/topaz
	@rm -rf /Applications/Topaz.app $(HOME)/Applications/Topaz.app
	@./topaz daemon uninstall 2>/dev/null || true
	@echo "Uninstalled"

clean:
	rm -f topaz
	rm -rf Topaz.app/Contents/MacOS/Topaz

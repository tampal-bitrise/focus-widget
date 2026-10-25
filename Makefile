.PHONY: build run test app install uninstall clean

build:
	swift build

run:
	swift run FocusWidget

test:
	swift run FocusCheck

app:
	Scripts/bundle.sh

install: app
	rm -rf /Applications/FocusWidget.app
	cp -R build/FocusWidget.app /Applications/FocusWidget.app
	@echo "Installed /Applications/FocusWidget.app"

uninstall:
	rm -rf /Applications/FocusWidget.app

clean:
	rm -rf .build build

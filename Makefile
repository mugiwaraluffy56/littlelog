PROJECT := littlelog.xcodeproj
SCHEME := littlelog
DERIVED := build/DerivedData
APP := $(DERIVED)/Build/Products/Debug/littlelog.app
XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED)

.PHONY: generate build test run icon clean

## generate: create littlelog.xcodeproj from project.yml (run after adding or moving files)
generate:
	xcodegen generate

$(PROJECT): project.yml
	xcodegen generate

## build: debug build
build: $(PROJECT)
	$(XCODEBUILD) build

## test: run the test suite (ONLY=Suite or ONLY=Suite/test to narrow it)
test: $(PROJECT)
	$(XCODEBUILD) test $(if $(ONLY),-only-testing:littlelogTests/$(ONLY))

## run: build, then relaunch the app
run: build
	-pkill -x littlelog
	open $(APP)

## icon: re-render the app icon PNGs
icon:
	swift scripts/make-icon.swift Resources/Assets.xcassets/AppIcon.appiconset

## clean: remove build output and the generated project
clean:
	rm -rf build $(PROJECT)

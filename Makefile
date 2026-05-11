.PHONY: generate build run clean

# Generate the Xcode project from project.yml
generate:
	xcodegen generate

# Build the app in Release mode.
# The post-build `codesign --force --sign - --deep` call re-applies an ad-hoc
# signature to the whole bundle (including the Widget extension). Without it,
# incremental builds can leave stale CodeResources artifacts that don't match
# the actual bundle contents, causing macOS to refuse to launch the app with
# `_LSOpenURLsWithCompletionHandler() failed with error -600`. This is a
# personal-fork addition; upstream uses GitHub Actions to ship a real signature.
build: generate
	xcodebuild \
		-project ClaudeGod.xcodeproj \
		-scheme ClaudeGod \
		-configuration Release \
		-derivedDataPath build \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=NO
	codesign --force --sign - --deep \
		"build/Build/Products/Release/Claude God.app"

# Open in Xcode
open: generate
	open ClaudeGod.xcodeproj

# Build and run
run: build
	open "build/Build/Products/Release/Claude God.app"

# Create a DMG
dmg: build
	mkdir -p dmg-contents
	cp -R "build/Build/Products/Release/Claude God.app" dmg-contents/
	ln -sf /Applications dmg-contents/Applications
	hdiutil create \
		-volname "Claude God" \
		-srcfolder dmg-contents \
		-ov \
		-format UDZO \
		ClaudeGod.dmg
	rm -rf dmg-contents

# Clean build artifacts
clean:
	rm -rf build ClaudeGod.xcodeproj ClaudeGod.dmg dmg-contents

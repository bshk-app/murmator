# Murmur — build helpers.
#
# Builds are RELEASE: MLX-Swift in Debug sends every MLXArray call through
# unoptimised Swift wrappers and lands well over realtime.
#
# RTF baselines, so nobody hunts a phantom regression:
#   2026-06-23  0.587  hybrid, "clip22" — measured BEFORE TwoTierEngine, the
#                      Silero gate and the 160 ms fast chunk existed. Different
#                      pipeline, different clip. Historical only; do NOT diff
#                      against it.
#   2026-08-13  M1 Max, 15.5 s of dense synthesised Russian speech, `--mode`:
#                      fast 0.139 · accurate 0.647 · hybrid 0.829
#                      First run after a cold Metal shader cache: 1.219.
#                      Dense speech is close to worst case — the Silero gate
#                      skips silent chunks, so real dictation with pauses is
#                      cheaper.
# Hybrid is additive: MLX is not concurrency-safe, so both lanes run on the one
# serial STT queue and their costs sum. Voxtral is ~78 % of it.
#
# Xcode 26 also breaks explicitly-built modules for some SPM deps
# (swift-algorithms → RealModule), so builds disable them; arm64-only keeps the
# heavy MLX build short.

WORKSPACE = Murmur.xcworkspace
SCHEME    = Murmur
XCB = tuist xcodebuild build -workspace $(WORKSPACE) -scheme $(SCHEME) \
	-configuration Release -destination 'generic/platform=macOS' -allowProvisioningUpdates \
	ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SWIFT_ENABLE_EXPLICIT_MODULES=NO

.PHONY: gen build run clean cli run-cli bench test-app

gen:
	tuist generate --no-open

build: gen
	$(XCB)

# App-layer tests. Debug: these are pure decision/declaration checks with no
# MLX in the path, so the Release caveat above does not apply and Debug links
# far quicker.
test-app: gen
	tuist xcodebuild test -workspace $(WORKSPACE) -scheme $(SCHEME) -only-testing:MurmurTests \
		-configuration Debug -destination 'platform=macOS,arch=arm64' \
		-allowProvisioningUpdates ONLY_ACTIVE_ARCH=YES SWIFT_ENABLE_EXPLICIT_MODULES=NO
run: build
	-killall Murmur Murmator 2>/dev/null   # quit a stale background agent, including the old product name
	@sleep 1                             # let it fully die — else `open` races LaunchServices (-600)
	open "$$(find $(HOME)/Library/Developer/Xcode/DerivedData/Murmur-*/Build/Products/Release -maxdepth 1 -name Murmator.app | head -1)"

# murmur-cli — same MurmurKit core as the app, RELEASE. `swift build` is flaky at
# emitting mlx-swift's Cmlx metallib bundle in a fresh checkout, so copy a
# known-good one next to the binary (app DerivedData, else main mlx-audio-swift).
KIT_REL     = MurmurKit/.build/release
CMLX_BUNDLE = mlx-swift_Cmlx.bundle
CMLX_SRC := $(firstword \
	$(wildcard $(HOME)/Library/Developer/Xcode/DerivedData/Murmur-*/Build/Products/Release/$(CMLX_BUNDLE)) \
	$(wildcard /Volumes/DATA/mlx-audio-swift/.build/arm64-apple-macosx/release/$(CMLX_BUNDLE)) \
	$(wildcard /Volumes/DATA/mlx-audio-swift/.build/arm64-apple-macosx/debug/$(CMLX_BUNDLE)))

cli:
	cd MurmurKit && swift build -c release --product murmur-cli
	@if [ ! -e "$(KIT_REL)/$(CMLX_BUNDLE)/Contents/Resources/default.metallib" ]; then \
		if [ -n "$(CMLX_SRC)" ]; then cp -R "$(CMLX_SRC)" "$(KIT_REL)/" && echo "→ copied metallib bundle next to murmur-cli"; \
		else echo "WARN: no metallib bundle found — run 'make build' (the app) once to produce it"; fi; \
	fi

run-cli: cli
	"$(KIT_REL)/murmur-cli"

# Offline timing on a fixed file: make bench WAV=/path/to/clip.wav
WAV ?= /path/to/clip.wav
bench: cli
	"$(KIT_REL)/murmur-cli" --wav "$(WAV)"

clean:
	rm -rf build Murmur.xcodeproj Murmur.xcworkspace Derived MurmurKit/.build

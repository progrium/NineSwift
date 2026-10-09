SWIFTC ?= swiftc
LIB    := NineP/NineP.swift
EXP    := NineExplorer
SHARED := $(LIB) $(EXP)/NineExplorer.swift
PLIST  := $(EXP)/Info.plist

BUNDLE_ID ?= xyz.progrium.NineExplorer
WATCH_ID  := $(BUNDLE_ID).watchkitapp

# Keys in the shared Info.plist that only some platforms use; each bundle
# drops the keys meant for the others.
MAC_ONLY_KEYS   := LSMinimumSystemVersion LSApplicationCategoryType NSPrincipalClass \
                   NSHighResolutionCapable NSSupportsAutomaticGraphicsSwitching
PHONE_ONLY_KEYS := LSRequiresIPhoneOS UILaunchScreen UIApplicationSceneManifest \
                   UIRequiredDeviceCapabilities UISupportedInterfaceOrientations \
                   UISupportedInterfaceOrientations~ipad NSLocalNetworkUsageDescription
MOBILE_KEYS     := MinimumOSVersion UIDeviceFamily
WATCH_ONLY_KEYS := WKApplication WKCompanionAppBundleIdentifier WKRunsIndependentlyOfCompanionApp
ORIENTATION_KEYS := UISupportedInterfaceOrientations UISupportedInterfaceOrientations~ipad

# make-plist <platform> <keys-to-remove> <output>
define make-plist
	sed -e 's/__PLATFORM__/$(1)/' -e "s/__PLATFORM_LOWER__/$$(echo $(1) | tr A-Z a-z)/" \
	    -e 's/__BUNDLE_ID__/$(BUNDLE_ID)/g' $(PLIST) > $(3)
	for k in $(2); do plutil -remove "$$k" $(3); done
	plutil -convert xml1 $(3)
	plutil -lint -s $(3)
endef

# ---- macOS app ------------------------------------------------------------
MAC_TARGET ?= $(shell uname -m)-apple-macos14.0
MAC_APP    := build/macOS/NineExplorer.app

# ---- iOS + watchOS + tvOS apps --------------------------------------------
# IOS_PLATFORM=simulator (default) or device; the watch and tv apps follow it.
# Device builds need a signing identity and provisioning profiles to install:
#   make ios-app IOS_PLATFORM=device IOS_SIGN_ID="Apple Development: ..." \
#        IOS_PROFILE=ios.mobileprovision WATCH_PROFILE=watch.mobileprovision \
#        BUNDLE_ID=com.yourteam.NineExplorer
IOS_PLATFORM ?= simulator
IOS_MIN      ?= 17.0
WATCH_MIN    ?= 10.0
TV_MIN       ?= 17.0
ifeq ($(IOS_PLATFORM),device)
  IOS_SDK          := iphoneos
  IOS_TARGET       := arm64-apple-ios$(IOS_MIN)
  IOS_PLIST_PLAT   := iPhoneOS
  WATCH_SDK        := watchos
  WATCH_ARCHS      := arm64_32 arm64
  WATCH_TRIPLE     := apple-watchos$(WATCH_MIN)
  WATCH_PLIST_PLAT := WatchOS
  TV_SDK           := appletvos
  TV_TARGET        := arm64-apple-tvos$(TV_MIN)
  TV_PLIST_PLAT    := AppleTVOS
else
  IOS_SDK          := iphonesimulator
  IOS_TARGET       := arm64-apple-ios$(IOS_MIN)-simulator
  IOS_PLIST_PLAT   := iPhoneSimulator
  WATCH_SDK        := watchsimulator
  WATCH_ARCHS      := arm64
  WATCH_TRIPLE     := apple-watchos$(WATCH_MIN)-simulator
  WATCH_PLIST_PLAT := WatchSimulator
  TV_SDK           := appletvsimulator
  TV_TARGET        := arm64-apple-tvos$(TV_MIN)-simulator
  TV_PLIST_PLAT    := AppleTVSimulator
endif
IOS_SIGN_ID   ?= -
IOS_PROFILE   ?=
WATCH_PROFILE ?=
TV_PROFILE    ?=
TV_ENTITLEMENTS ?=
IOS_APP       := build/iOS-$(IOS_PLATFORM)/NineExplorer.app
WATCH_APP     := build/watchOS-$(IOS_PLATFORM)/NineExplorerWatch.app
TV_APP        := build/tvOS-$(IOS_PLATFORM)/NineExplorer.app

all: build/NineClient mac-app ios-app tv-app

# ---- CLI ------------------------------------------------------------------
build/NineClient: $(LIB) NineClient/main.swift
	@mkdir -p build
	$(SWIFTC) -O -o $@ $(LIB) NineClient/main.swift

# ---- macOS bundle: NineExplorer.app/Contents/{Info.plist,PkgInfo,MacOS/NineExplorer}
mac-app: $(MAC_APP)

$(MAC_APP): $(SHARED) $(EXP)/MacApp.swift $(PLIST)
	@rm -rf $@ && mkdir -p $@/Contents/MacOS $@/Contents/Resources
	xcrun --sdk macosx $(SWIFTC) -parse-as-library -O -target $(MAC_TARGET) \
		-o $@/Contents/MacOS/NineExplorer $(SHARED) $(EXP)/MacApp.swift
	$(call make-plist,MacOSX,$(PHONE_ONLY_KEYS) $(MOBILE_KEYS) $(WATCH_ONLY_KEYS),$@/Contents/Info.plist)
	printf 'APPL????' > $@/Contents/PkgInfo
	codesign --force --sign - $@
	@echo "built $@"

# ---- watchOS bundle: NineExplorerWatch.app/{Info.plist,PkgInfo,NineExplorerWatch}
# Thin client: shared NineExplorer.swift + WatchApp.swift, no NineP.swift.
watch-app: $(WATCH_APP)

$(WATCH_APP): $(EXP)/NineExplorer.swift $(EXP)/WatchApp.swift $(PLIST)
	@rm -rf $@ && mkdir -p $@
	for a in $(WATCH_ARCHS); do \
		xcrun --sdk $(WATCH_SDK) $(SWIFTC) -parse-as-library -O -target $$a-$(WATCH_TRIPLE) \
			-o $@/NineExplorerWatch.$$a $(EXP)/NineExplorer.swift $(EXP)/WatchApp.swift || exit 1; \
	done
	lipo -create $(foreach a,$(WATCH_ARCHS),$@/NineExplorerWatch.$(a)) -output $@/NineExplorerWatch
	rm -f $(foreach a,$(WATCH_ARCHS),$@/NineExplorerWatch.$(a))
	$(call make-plist,$(WATCH_PLIST_PLAT),$(MAC_ONLY_KEYS) $(PHONE_ONLY_KEYS),$@/Info.plist)
	plutil -replace CFBundleIdentifier -string $(WATCH_ID) $@/Info.plist
	plutil -replace CFBundleExecutable -string NineExplorerWatch $@/Info.plist
	plutil -replace MinimumOSVersion -string $(WATCH_MIN) $@/Info.plist
	plutil -replace UIDeviceFamily -json '[4]' $@/Info.plist
	printf 'APPL????' > $@/PkgInfo
	$(if $(WATCH_PROFILE),cp "$(WATCH_PROFILE)" $@/embedded.mobileprovision)
	codesign --force --sign "$(IOS_SIGN_ID)" --timestamp=none $@
	@echo "built $@"

# ---- iOS bundle: NineExplorer.app/{Info.plist,PkgInfo,NineExplorer,Watch/NineExplorerWatch.app}
ios-app: $(IOS_APP)

$(IOS_APP): $(SHARED) $(EXP)/iOSApp.swift $(PLIST) $(WATCH_APP)
	@rm -rf $@ && mkdir -p $@/Watch
	xcrun --sdk $(IOS_SDK) $(SWIFTC) -parse-as-library -O -target $(IOS_TARGET) \
		-o $@/NineExplorer $(SHARED) $(EXP)/iOSApp.swift
	$(call make-plist,$(IOS_PLIST_PLAT),$(MAC_ONLY_KEYS) $(WATCH_ONLY_KEYS),$@/Info.plist)
	printf 'APPL????' > $@/PkgInfo
	cp -R $(WATCH_APP) $@/Watch/
	$(if $(IOS_PROFILE),cp "$(IOS_PROFILE)" $@/embedded.mobileprovision)
	codesign --force --sign "$(IOS_SIGN_ID)" --timestamp=none $@
	@echo "built $@"

# ---- tvOS bundle: NineExplorer.app/{Info.plist,PkgInfo,NineExplorer}
# Speaks 9P itself: shared NineExplorer.swift + NineP.swift + TVApp.swift.
tv-app: $(TV_APP)

$(TV_APP): $(SHARED) $(EXP)/TVApp.swift $(PLIST) $(TV_ENTITLEMENTS)
	@rm -rf $@ && mkdir -p $@
	xcrun --sdk $(TV_SDK) $(SWIFTC) -parse-as-library -O -target $(TV_TARGET) \
		-o $@/NineExplorer $(SHARED) $(EXP)/TVApp.swift
	$(call make-plist,$(TV_PLIST_PLAT),$(MAC_ONLY_KEYS) $(WATCH_ONLY_KEYS) $(ORIENTATION_KEYS),$@/Info.plist)
	plutil -replace MinimumOSVersion -string $(TV_MIN) $@/Info.plist
	plutil -replace UIDeviceFamily -json '[3]' $@/Info.plist
	printf 'APPL????' > $@/PkgInfo
	$(if $(TV_PROFILE),cp "$(TV_PROFILE)" $@/embedded.mobileprovision)
	codesign --force --sign "$(IOS_SIGN_ID)" --timestamp=none \
		$(if $(TV_ENTITLEMENTS),--entitlements "$(TV_ENTITLEMENTS)") $@
	@echo "built $@"

# ---- Simulators ------------------------------------------------------------
# iphone-sim: build ios-app for the simulator, create (once) an iPhone
#             simulator, boot it, install and launch NineExplorer.
# watch-sim:  everything iphone-sim does, then create (once) a watch
#             simulator, pair it with that iPhone, boot it, install and launch
#             the watch app (WatchConnectivity needs the pair + both apps).
# tv-sim:     build tv-app for the simulator, create (once) an Apple TV
#             simulator, boot it, install and launch NineExplorer.
# Re-running reuses the simulators by name. Override with e.g.
#   make watch-sim PHONE_TYPE="iPhone 15" WATCH_TYPE="Apple Watch Ultra 2 (49mm)"
#   make tv-sim TV_TYPE="Apple TV 4K (3rd generation) (at 1080p)"
SIM_PHONE     ?= NineExplorer iPhone
SIM_WATCH     ?= NineExplorer Watch
SIM_TV        ?= NineExplorer TV
PHONE_TYPE    ?= $(shell xcrun simctl list devicetypes | grep -E '^iPhone' | head -1 | sed -E 's/ .com[.]apple[.].*//')
WATCH_TYPE    ?= $(shell xcrun simctl list devicetypes | grep -E '^Apple Watch' | head -1 | sed -E 's/ .com[.]apple[.].*//')
TV_TYPE       ?= $(shell xcrun simctl list devicetypes | grep -E '^Apple TV' | head -1 | sed -E 's/ .com[.]apple[.].*//')
SIM_IOS_APP   := build/iOS-simulator/NineExplorer.app
SIM_TV_APP    := build/tvOS-simulator/NineExplorer.app
SIM_WATCH_APP := $(SIM_IOS_APP)/Watch/NineExplorerWatch.app
UUID_RE       := [0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}

# sim-udid <name>: shell snippet printing the UDID of the simulator with that name
sim-udid = xcrun simctl list devices | grep -F "    $(1) (" | grep -oE '$(UUID_RE)' | head -1

# sim-ensure <var> <name> <devicetype> <runtime-family>: set $$<var> to the
# UDID, creating the simulator if it does not exist yet
define sim-ensure
xcrun simctl list runtimes | grep -q '^$(4) ' || { \
	echo "no $(4) simulator runtime; install one with: xcodebuild -downloadPlatform $(4)"; exit 1; }; \
$(1)=$$($(call sim-udid,$(2))); \
if [ -z "$$$(1)" ]; then \
	echo "creating simulator '$(2)' ($(3))"; \
	$(1)=$$(xcrun simctl create "$(2)" "$(3)"); \
fi
endef

# sim-boot <udid-var>: boot (if needed) and wait until ready
define sim-boot
xcrun simctl boot $$$(1) 2>/dev/null || true; \
open -a Simulator; \
xcrun simctl bootstatus $$$(1) -b >/dev/null
endef

iphone-sim:
	$(MAKE) ios-app IOS_PLATFORM=simulator
	@set -e; \
	$(call sim-ensure,P,$(SIM_PHONE),$(PHONE_TYPE),iOS); \
	echo "iPhone simulator: $(SIM_PHONE) $$P"; \
	$(call sim-boot,P); \
	echo "installing $(SIM_IOS_APP)"; \
	xcrun simctl install $$P $(SIM_IOS_APP); \
	echo "launching $(BUNDLE_ID)"; \
	xcrun simctl launch --terminate-running-process $$P $(BUNDLE_ID)

watch-sim: iphone-sim
	@set -e; \
	P=$$($(call sim-udid,$(SIM_PHONE))); \
	$(call sim-ensure,W,$(SIM_WATCH),$(WATCH_TYPE),watchOS); \
	echo "watch simulator: $(SIM_WATCH) $$W"; \
	PAIRS=$$(xcrun simctl list pairs); \
	if echo "$$PAIRS" | grep -A1 "$$W" | grep -q "$$P"; then \
		echo "already paired with $(SIM_PHONE)"; \
	else \
		OLD=$$(echo "$$PAIRS" | grep -B1 "$$W" | head -1 | grep -oE '$(UUID_RE)' || true); \
		if [ -n "$$OLD" ]; then echo "unpairing from another iPhone ($$OLD)"; xcrun simctl unpair $$OLD; fi; \
		echo "pairing with $(SIM_PHONE)"; \
		xcrun simctl pair $$W $$P >/dev/null; \
	fi; \
	PAIR=$$(xcrun simctl list pairs | grep -B1 "$$W" | head -1 | grep -oE '$(UUID_RE)'); \
	xcrun simctl pair_activate $$PAIR 2>/dev/null || true; \
	$(call sim-boot,W); \
	echo "installing $(SIM_WATCH_APP)"; \
	xcrun simctl install $$W $(SIM_WATCH_APP); \
	echo "launching $(WATCH_ID)"; \
	xcrun simctl launch --terminate-running-process $$W $(WATCH_ID)

tv-sim:
	$(MAKE) tv-app IOS_PLATFORM=simulator
	@set -e; \
	$(call sim-ensure,T,$(SIM_TV),$(TV_TYPE),tvOS); \
	echo "Apple TV simulator: $(SIM_TV) $$T"; \
	$(call sim-boot,T); \
	echo "installing $(SIM_TV_APP)"; \
	xcrun simctl install $$T $(SIM_TV_APP); \
	echo "launching $(BUNDLE_ID)"; \
	xcrun simctl launch --terminate-running-process $$T $(BUNDLE_ID)

# ---- Apple TV device -------------------------------------------------------
# tv-device: build tv-app for a real Apple TV and install + launch it.
#   make tv-device TV_PROFILE=path/to/tvOS.mobileprovision
# The bundle ID and entitlements come from the profile (BUNDLE_ID is only used
# for wildcard profiles). Optional: TV_DEVICE=<name or identifier from
# `xcrun devicectl list devices`> (default: first available Apple TV) and
# IOS_SIGN_ID (default: first "Apple Development" identity in the keychain).
TV_DEVICE      ?=
TV_DEV_PROFILE := build/tvOS-device.profile.plist
TV_DEV_ENTS    := build/tvOS-device.entitlements

tv-device:
	@set -e; \
	[ -n "$(TV_PROFILE)" ] && [ -f "$(TV_PROFILE)" ] || { \
		echo "set TV_PROFILE=path/to/tvOS.mobileprovision (see README)"; exit 1; }; \
	mkdir -p build; \
	security cms -D -i "$(TV_PROFILE)" > $(TV_DEV_PROFILE) 2>/dev/null; \
	/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' $(TV_DEV_PROFILE) > $(TV_DEV_ENTS); \
	APPID=$$(/usr/libexec/PlistBuddy -c 'Print :application-identifier' $(TV_DEV_ENTS)); \
	TEAM=$${APPID%%.*}; ID=$${APPID#*.}; \
	case "$$ID" in *'*') ID='$(BUNDLE_ID)'; \
		/usr/libexec/PlistBuddy -c "Set :application-identifier $$TEAM.$$ID" $(TV_DEV_ENTS);; esac; \
	SIGN='$(IOS_SIGN_ID)'; \
	if [ "$$SIGN" = "-" ]; then \
		SIGN=$$(security find-identity -v -p codesigning | grep -m1 'Apple Development' | awk '{print $$2}'); \
	fi; \
	[ -n "$$SIGN" ] || { echo "no Apple Development signing identity; set IOS_SIGN_ID (see README)"; exit 1; }; \
	DEV='$(TV_DEVICE)'; \
	if [ -z "$$DEV" ]; then \
		DEV=$$(xcrun devicectl list devices 2>/dev/null | grep 'Apple TV' | grep available | grep -oE '$(UUID_RE)' | head -1); \
	fi; \
	[ -n "$$DEV" ] || { echo "no available Apple TV found; pair one in Xcode or set TV_DEVICE (see README)"; exit 1; }; \
	echo "bundle ID: $$ID  device: $$DEV  identity: $$SIGN"; \
	$(MAKE) tv-app IOS_PLATFORM=device IOS_SIGN_ID="$$SIGN" TV_PROFILE="$(TV_PROFILE)" \
		TV_ENTITLEMENTS=$(TV_DEV_ENTS) BUNDLE_ID="$$ID"; \
	xcrun devicectl device install app --device "$$DEV" build/tvOS-device/NineExplorer.app; \
	xcrun devicectl device process launch --terminate-existing --device "$$DEV" "$$ID"

clean:
	rm -rf build

.PHONY: all mac-app ios-app watch-app tv-app iphone-sim watch-sim tv-sim tv-device clean

# Optional local additions (.local is gitignored).
-include .local/local.mk

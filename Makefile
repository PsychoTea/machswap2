TARGET       = machswap2
PACKAGE      = zone.sparkes.machswap2
VERSION      = 1.0.0
BIN          = bin
SRC          = src
RES          = res
APP          = $(BIN)/Payload/$(TARGET).app
IPA		= $(TARGET).ipa
# PNGS        := $(wildcard $(RES)/*.png)
FILES       := $(TARGET) Info.plist
IGCC        ?= xcrun -sdk iphoneos gcc
ARCH        ?= -arch arm64
IGCC_FLAGS  ?= -Wall -O3 -fmodules -framework IOKit $(CFLAGS)
STRIP       ?= xcrun -sdk iphoneos strip

.PHONY: all ipa clean install

all: $(IPA)

ipa: $(IPA)

$(IPA): $(addprefix $(APP)/, $(FILES))
	cd $(BIN) && zip -x .DS_Store -qr9 ../$@ Payload

$(APP)/$(TARGET): $(SRC)/*.m | $(APP)
	$(IGCC) $(ARCH) -o $@ $(IGCC_FLAGS) $^
	$(STRIP) $@

$(APP)/Info.plist: $(RES)/Info.plist | $(APP)
	sed 's/$$(TARGET)/$(TARGET)/g;s/$$(PACKAGE)/$(PACKAGE)/g;s/$$(VERSION)/$(VERSION)/g' $(RES)/Info.plist > $@

$(APP)/%.png: $(RES)/$(@F) | $(APP)
	cp $(RES)/$(@F) $@

$(APP):
	mkdir -p $@

clean:
	rm -rf $(BIN)
	rm -f *.ipa *.dylib $(TRAMP)

ifndef ID
install:
	@echo 'Environment variable ID not set'
	exit 1
else
install: | $(IPA)
	cp res/*.mobileprovision $(APP)/embedded.mobileprovision
	echo '<?xml version="1.0" encoding="UTF-8"?>' >tmp.plist
	echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' >>tmp.plist
	echo '<plist version="1.0">' >>tmp.plist
	echo '<dict>' >>tmp.plist
	strings res/*.mobileprovision | egrep -A1 'application-identifier' >>tmp.plist
	strings res/*.mobileprovision | egrep -A1 'team-identifier' >>tmp.plist
	echo '</dict>' >>tmp.plist
	echo '</plist>' >>tmp.plist
	codesign -f -s '$(ID)' --entitlements tmp.plist $(APP)
	rm tmp.plist
	cd $(BIN) && zip -x .DS_Store -qr9 ../$(IPA) Payload
	ideviceinstaller -i $(IPA)
endif

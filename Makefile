# Eyes — classic Mac-style pointer watchers (Free Pascal)
#
# macOS:   make
# Linux:   sudo apt install fpc libgtk2.0-dev   &&  make linux
# Windows: from a native FPC install:            make windows

FPC      ?= fpc
SRC      := src
BUILD    := build
APP      := $(BUILD)/Eyes.app
UNITS    := -Fu$(SRC) -FU$(BUILD) -FE$(BUILD)
FLAGS    := -Mobjfpc -Scgi -O2 -Xs

.PHONY: all app run linux windows clean

all: app

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/Eyes: $(BUILD) $(SRC)/*.pas
	$(FPC) $(FLAGS) $(UNITS) -o$(BUILD)/Eyes $(SRC)/eyes.pas

app: $(BUILD)/Eyes
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BUILD)/Eyes $(APP)/Contents/MacOS/Eyes
	cp bundle/Info.plist $(APP)/Contents/Info.plist

run: app
	open $(APP)

linux: $(BUILD)
	$(FPC) $(FLAGS) $(UNITS) -o$(BUILD)/eyes $(SRC)/eyes.pas

windows: $(BUILD)
	$(FPC) $(FLAGS) $(UNITS) -o$(BUILD)/Eyes.exe $(SRC)/eyes.pas

clean:
	rm -rf $(BUILD)

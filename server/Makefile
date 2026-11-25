# Tingfeng Pure-Geisha Backend Makefile (`server/Makefile`)

GEISHA ?= $(shell command -v geisha 2>/dev/null || command -v geisha3 2>/dev/null || ls ../geisha.gsa/build/geisha3 $(HOME)/code/geisha.gsa/build/geisha3 2>/dev/null | head -n 1)
GEISHA_RUNTIME ?= $(shell ls $(dir $(GEISHA))libgeisha_runtime.a ../geisha.gsa/build/libgeisha_runtime.a $(HOME)/code/geisha.gsa/build/libgeisha_runtime.a 2>/dev/null | head -n 1)

ROOT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
BUILD_DIR := $(ROOT_DIR)/server/build
BIN := $(BUILD_DIR)/tingfeng-server
SRCS := $(wildcard $(ROOT_DIR)/server/src/*.gsa)

.PHONY: all build test run clean

all: build

build: $(BIN)

$(BIN): $(SRCS)
	@if [ -z "$(GEISHA)" ] || [ ! -x "$(GEISHA)" ]; then \
		echo "Error: Geisha compiler not found. Set GEISHA=/path/to/geisha3" >&2; \
		exit 1; \
	fi
	@mkdir -p "$(BUILD_DIR)"
	"$(GEISHA)" --src-root "$(ROOT_DIR)/server" $(if $(GEISHA_RUNTIME),--runtime "$(GEISHA_RUNTIME)",) -o "$(BIN)" "$(ROOT_DIR)/server/src/mod.gsa"

test: build
	cd "$(ROOT_DIR)" && "$(BIN)" --test

run: build
	cd "$(ROOT_DIR)" && "$(BIN)"

clean:
	rm -rf "$(BUILD_DIR)"

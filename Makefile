.PHONY: build test run clean dev-test

export TEST_USER ?= tester
export TEST_RESET ?= 1
export OPEN_BROWSER ?= 1
export SKIP_BUILD ?= 0
export SKIP_CLIENT_INSTALL ?= 0
export CLIENT_HOST ?= 127.0.0.1
export CLIENT_PORT ?= 8080

build:
	$(MAKE) -C server build

test:
	$(MAKE) -C server test

run:
	$(MAKE) -C server run

clean:
	$(MAKE) -C server clean

dev-test:
	./scripts/dev-test.sh

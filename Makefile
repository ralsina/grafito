CRYSTAL_SRC_DIR := src
CRYSTAL_MAIN_FILE := $(CRYSTAL_SRC_DIR)/main.cr
ASSETS_DIR := $(CRYSTAL_SRC_DIR)/assets
EXECUTABLE_NAME := grafito

# Default target: build the project
.PHONY: all
all: build

# Install dependencies
.PHONY: shards
shards:
	@echo "Installing Crystal shards..."
	shards install

# Build the project
# Uses `shards build` which respects settings in shard.yml
.PHONY: build
build: shards minify
	@echo "Building $(EXECUTABLE_NAME)..."
	shards build --release --no-debug $(EXECUTABLE_NAME)

# Build for development (faster, with debug symbols)
.PHONY: build-dev
build-dev: shards minify
	@echo "Building $(EXECUTABLE_NAME) (development)..."
	shards build $(EXECUTABLE_NAME)

# Run the project (after building for development)
.PHONY: run
run: build-dev
	@echo "Running $(EXECUTABLE_NAME)..."
	./bin/$(EXECUTABLE_NAME)

# Run the release build
.PHONY: run-release
run-release: build
	@echo "Running $(EXECUTABLE_NAME) (release)..."
	./bin/$(EXECUTABLE_NAME)

# Watch for source changes and automatically rebuild and run (development)
.PHONY: watch
watch: shards
	@echo "Watching for changes in $(CRYSTAL_SRC_DIR)/ and re-running with entr..."
	fd $(CRYSTAL_SRC_DIR)/ --full-path | entr -r make run

# Clean build artifacts
.PHONY: clean
clean:
	@echo "Cleaning build artifacts..."
	rm -f ./bin/$(EXECUTABLE_NAME)
	rm -rf ./libs # If shards install creates this

# Lint Crystal code (which also formats with --fix)
.PHONY: lint
lint:
	@echo "Linting Crystal code (Ameba --fix also formats)..."
	ameba --fix $(CRYSTAL_SRC_DIR)

# --- Frontend assets ---
# CSS and JS are edited as small modules under css/ and js/ and
# concatenated (in filename order — keep the numeric prefixes) into the
# served artifacts, which are then minified. The concatenated and
# minified files are committed so the binary build needs no extra
# tooling beyond `minify`.
CSS_MODULES := $(wildcard $(ASSETS_DIR)/css/*.css)
JS_MODULES  := $(wildcard $(ASSETS_DIR)/js/*.js)
INDEX_HTML_SRC := $(ASSETS_DIR)/index.html
INDEX_HTML_MIN := $(ASSETS_DIR)/index.min.html
STYLE_CSS_SRC := $(ASSETS_DIR)/style.css
STYLE_CSS_MIN := $(ASSETS_DIR)/style.min.css
APP_JS_SRC := $(ASSETS_DIR)/app.js
APP_JS_MIN := $(ASSETS_DIR)/app.min.js

$(STYLE_CSS_SRC): $(CSS_MODULES)
	@echo "Concatenating CSS modules to $@"
	cat $(CSS_MODULES) > $@

$(APP_JS_SRC): $(JS_MODULES)
	@echo "Concatenating JS modules to $@"
	cat $(JS_MODULES) > $@

# Regenerates the concatenated and minified assets, then fails when
# the committed copies are stale. Wired into pre-commit for src/assets
# edits so a source change can never ship without its bundle (#70).
.PHONY: assets-fresh
assets-fresh:
	@cat $(CSS_MODULES) > $(STYLE_CSS_SRC)
	@cat $(JS_MODULES) > $(APP_JS_SRC)
	@$(MAKE) --no-print-directory minify
	@git diff --exit-code -- $(ASSETS_DIR) || { echo 'Stale committed assets were regenerated: git add src/assets and retry.'; exit 1; }

.PHONY: minify
minify: $(INDEX_HTML_MIN) $(STYLE_CSS_MIN) $(APP_JS_MIN)

$(INDEX_HTML_MIN): $(INDEX_HTML_SRC)
	@echo "Minifying $< to $@"
	minify $< -o $@
	@printf '\n' >> $@ # pre-commit's end-of-file-fixer requires a trailing newline

$(STYLE_CSS_MIN): $(STYLE_CSS_SRC)
	@echo "Minifying $< to $@"
	minify $< -o $@
	@printf '\n' >> $@ # pre-commit's end-of-file-fixer requires a trailing newline

$(APP_JS_MIN): $(APP_JS_SRC)
	@echo "Minifying $< to $@"
	minify $< -o $@
	@printf '\n' >> $@ # pre-commit's end-of-file-fixer requires a trailing newline

.PHONY: test
test:
	crystal spec

# The demo/fake-journal surface (compose view, fake data generators) is
# only compiled with this flag; run both suites for full coverage.
test-demo:
	crystal spec -Ddemo_mode

.PHONY: website
website:
	crycco --theme=apathy shard.yml src/*.cr -o site

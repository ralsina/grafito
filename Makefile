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

# --- Minify Specific Assets ---
INDEX_HTML_SRC := $(ASSETS_DIR)/index.html
INDEX_HTML_MIN := $(ASSETS_DIR)/index.min.html
STYLE_CSS_SRC := $(ASSETS_DIR)/style.css
STYLE_CSS_MIN := $(ASSETS_DIR)/style.min.css

.PHONY: minify
minify: $(INDEX_HTML_MIN) $(STYLE_CSS_MIN)

$(INDEX_HTML_MIN): $(INDEX_HTML_SRC)
	@echo "Minifying $< to $@"
	minify $< -o $@

$(STYLE_CSS_MIN): $(STYLE_CSS_SRC)
	@echo "Minifying $< to $@"
	minify $< -o $@

.PHONY: test
test:
	crystal spec

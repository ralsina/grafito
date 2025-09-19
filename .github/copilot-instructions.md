# Grafito - GitHub Copilot Development Instructions

**ALWAYS follow these instructions first.** Only fallback to additional search and context gathering if the information in these instructions is incomplete or found to be in error.

## Project Overview

Grafito is a Crystal-based web application for viewing systemd journal logs through a web interface. It's designed as a single-binary application with embedded assets, making deployment simple and self-contained.

## Prerequisites and Setup

### Required System Dependencies
Install Crystal, shards, and essential tools:

```bash
# Install Crystal >= 1.16.0 (CRITICAL: Ubuntu 24.04 only has 1.11.2 - build will fail)
# Use the official Crystal repository:
curl -fsSL https://packagecloud.io/install/repositories/84codes/crystal/script.deb.sh | sudo bash
sudo apt update && sudo apt install -y crystal shards

# Install build dependencies
sudo apt install -y golang-go minify entr fd-find

# OR install minify via go if npm fails due to SSL issues:
go install github.com/tdewolff/minify/v2/cmd/minify@latest
export PATH=$PATH:~/go/bin

# Verify journalctl and systemctl are available (required for runtime)
which journalctl systemctl
```

### Bootstrap Repository
Always run these commands in this exact order:

```bash
# Clone and setup
git clone https://github.com/ralsina/grafito.git
cd grafito

# Install Crystal dependencies - takes ~2 seconds  
shards install

# Verify setup by running tests - takes ~6 seconds, NEVER CANCEL
crystal spec
```

## Build Commands

### Development Build
```bash
# Build development version - NEVER CANCEL, may take 2-5 minutes
# Set timeout to 10+ minutes to be safe
make build-dev

# Alternative: direct shards build (faster)
shards build grafito
```

### Docker Alternative (If Crystal Version Issues)
If local Crystal version < 1.16.0 prevents building:

```bash
# Static build using Docker (requires docker)
./build_static.sh
# Produces: bin/grafito-static-linux-amd64 and bin/grafito-static-linux-arm64

# Or use individual Docker commands
docker build . -f Dockerfile.static -t grafito-builder
docker run -ti --rm -v "$PWD":/app --user="$UID" grafito-builder /bin/sh -c "cd /app && shards build --static --release"
```

### Production Build
```bash
# Build optimized release - NEVER CANCEL, may take 5-10 minutes  
# Set timeout to 15+ minutes to be safe
make build

# Alternative: release build via shards
shards build --release --no-debug grafito
```

### Asset Minification
The build process requires minified assets:

```bash
# Minify assets (runs automatically with make build/build-dev)
make minify

# Manual minification if needed (very fast: ~1ms per file)
minify src/assets/index.html -o src/assets/index.min.html
minify src/assets/style.css -o src/assets/style.min.css
```

## Testing and Quality

### Run Tests
```bash
# Run all tests (75 specs) - takes ~6 seconds, NEVER CANCEL
# Set timeout to 30+ seconds to be safe
crystal spec

# Alternative make command
make test
```

### Linting
**WARNING: Ameba linter requires Crystal 1.16.0+ and may not work with older versions**

```bash
# Run linter with auto-fix - may fail on Crystal < 1.16.0
make lint

# Alternative direct ameba (if available)
ameba --fix src

# If ameba fails due to Crystal version, note in instructions but continue
```

## Running the Application

### Development Mode
```bash
# Build and run development version
make run

# Alternative: run via shards
shards run grafito

# Default URL: http://localhost:3000
```

### Production Mode
```bash
# Build and run release version
make run-release

# Manual execution
./bin/grafito
```

### Watch Mode (Auto-rebuild)
```bash
# Watch for changes and auto-rebuild - requires entr and fd-find
# VERIFIED: Both tools available via: sudo apt install entr fd-find
make watch

# Uses: fd src/ --full-path | entr -r make run
```

## Architecture and Key Files

### Core Components
- `src/main.cr` - Entry point with docopt CLI parsing and Kemal server setup
- `src/grafito.cr` - HTTP routes and web interface  
- `src/journalctl.cr` - Journal log parsing and filtering logic
- `src/grafito_helpers.cr` - HTML generation helpers
- `src/timeline.cr` - Timeline visualization
- `src/baked_handler.cr` - Serves embedded assets

### Asset Management
- `src/assets/` - Original assets (HTML, CSS, JS, favicon)
- `src/assets/index.min.html` - Minified HTML (generated)
- `src/assets/style.min.css` - Minified CSS (generated)
- Assets are embedded at compile time using `baked_file_system`

### Dependencies (Minimal by Design)
- `kemal` - Web framework
- `docopt` - CLI parsing (maintainer preference)
- `baked_file_system` - Asset embedding for single binary
- `html_builder` - Clean HTML generation
- `kemal-basic-auth` - Optional authentication

## Critical Version Requirements

### Crystal Version
- **CRITICAL**: Requires Crystal >= 1.16.0
- Ubuntu 24.04 ships with Crystal 1.11.2 which causes build failures
- Kemal dependency uses `Process.on_terminate` (requires newer Crystal)
- Use official Crystal repository for newer versions
- **VERIFIED**: System Crystal 1.11.2 fails with "undefined method 'on_terminate'"

### Known Compatibility Issues
- `Process::Status.system_exit_status` → use `.exit_code` (fixed in this codebase)
- Ameba linter requires Crystal 1.16.0+
- Kemal uses newer Process API features

## Validation and Testing

### Manual Validation Scenarios
After making changes, ALWAYS test these scenarios:

1. **Application Starts Successfully**
   ```bash
   ./bin/grafito
   # Should start without errors, listening on port 3000
   # Look for: "Listening on http://0.0.0.0:3000"
   ```

2. **Web Interface Loads Correctly**
   - Navigate to http://localhost:3000
   - **VERIFY**: Page title shows "Grafito Log Viewer"
   - **VERIFY**: Filter sidebar contains:
     - Unit filter (placeholder: "Unit (e.g., docker)")
     - Syslog Tag filter (placeholder: "Syslog Tag (e.g., myapp)")  
     - Hostname filter (placeholder: "Hostname (e.g., server1)")
     - Time range dropdown
     - Priority dropdown
   - **VERIFY**: Main content area with results section displays
   - **VERIFY**: Toggle button for sidebar works
   - **VERIFY**: No JavaScript console errors

3. **CLI Help Functions**
   ```bash
   ./bin/grafito --help
   # Should show docopt-based help with available options
   ```

4. **Log Functionality** (if journalctl available)
   - Test basic log viewing (should show recent journal entries)
   - Test filtering by unit/service (select from dropdown or type)
   - Test time range filtering (last hour, day, week options)
   - Test search functionality
   - **VERIFY**: Timeline visualization appears above log entries
   - **VERIFY**: Log entries show timestamp, hostname, unit, priority, message

### Build Validation
Always run these before considering changes complete:

```bash
# Clean build test
make clean && make build-dev
make test
./bin/grafito --help

# CI validation (matches .github/workflows/crystal.yml)
# The CI uses crystallang/crystal Docker image with correct Crystal version
shards install
crystal spec
```

## Common Tasks Reference

### Repository Structure
```
.
├── src/                    # Crystal source code
│   ├── assets/            # Web assets (HTML, CSS, JS)
│   ├── main.cr           # Application entry point
│   ├── grafito.cr        # Web routes
│   └── journalctl.cr     # Journal integration
├── spec/                  # Test files (75 specs)
├── Makefile              # Build system
├── shard.yml             # Crystal dependencies
└── README.md             # Documentation
```

### Environment Variables
- `GRAFITO_AUTH_USER` - Basic auth username (optional)
- `GRAFITO_AUTH_PASS` - Basic auth password (optional)

### System Requirements
- Linux with systemd (for journalctl/systemctl)
- User must be in `systemd-journal` group to access all logs
- Crystal 1.16.0+ for building
- Go 1.18+ for minify tool

## Timeout Specifications

**NEVER CANCEL these operations - set appropriate timeouts:**

- `shards install`: ~2 seconds (set 60s timeout)
- `crystal spec`: ~6 seconds (set 30s timeout) 
- `make build-dev`: 2-5 minutes (set 10+ minute timeout)
- `make build`: 5-10 minutes (set 15+ minute timeout)
- `make minify`: <1 second (set 30s timeout)
- `make watch`: Continuous (no timeout needed)

## Troubleshooting

### Crystal Version Issues
If you see `undefined method` errors, likely Crystal version < 1.16.0:
- `Process.on_terminate` error: Crystal too old for Kemal
- `Process::Status.system_exit_status` error: Use `.exit_code` instead
- Install from official repository
- Use Docker build as fallback
- Document limitation in changes

### Missing Tools
- `minify not found`: Install via go or npm
- `entr not found`: `sudo apt install entr fd-find`  
- `ameba not found`: Requires Crystal 1.16.0+, may need to skip linting
- `shards not found`: `sudo apt install shards`

### Build Failures
- Clean and rebuild: `make clean && make build-dev`
- Check Crystal version: `crystal --version`
- Verify all dependencies: `shards check`
- Check minified assets exist: `ls src/assets/*.min.*`

### Runtime Requirements
- Ensure journalctl/systemctl available: `which journalctl systemctl`
- Check user permissions for journal access
- Verify port 3000 is available
- **IMPORTANT**: Application needs systemd journal access to function

### Common Error Patterns
```
Error: undefined method 'on_terminate' for Process.class
→ Crystal version too old, need >= 1.16.0

Error: undefined method 'system_exit_status' 
→ Use .exit_code instead (already fixed in codebase)

Shard "baked_file_handler" may be incompatible with Crystal X.X.X
→ Warning only, usually safe to ignore
```

Remember: This is a single-binary application with embedded assets. The goal is always a self-contained executable that can run anywhere with systemd.
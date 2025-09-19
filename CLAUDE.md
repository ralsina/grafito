# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Grafito is a Crystal-based web application for viewing systemd journal logs through a web interface. It's designed as a single-binary application with embedded assets, making deployment simple and self-contained.

## Key Development Commands

### Building and Running
- `make build` - Build optimized release binary (no debug)
- `make build-dev` - Build development binary (faster, with debug symbols)
- `make run` - Build and run development version
- `make run-release` - Build and run release version
- `make watch` - Watch mode: auto-rebuild on changes using entr
- `make clean` - Remove build artifacts

### Testing and Quality
- `make test` - Run all tests (75 specs)
- `make lint` - Run Ameba linter with auto-fix
- `crystal spec` - Alternative way to run tests
- `ameba --fix src` - Alternative way to lint

### Dependencies
- `make shards` - Install/update Crystal dependencies
- `shards install` - Alternative way to install dependencies

## Architecture Notes

### Single Binary Design
- All assets (HTML, CSS, JS, favicon) are embedded using `baked_file_system`
- Assets are minified during build process using the `minify` tool
- The resulting binary is self-contained and can be deployed anywhere

### Core Components
- `src/main.cr` - Entry point with docopt CLI parsing and Kemal server setup
- `src/grafito.cr` - HTTP routes and web interface
- `src/journalctl.cr` - Journal log parsing and filtering logic
- `src/grafito_helpers.cr` - HTML generation helpers
- `src/timeline.cr` - Timeline visualization
- `src/baked_handler.cr` - Serves embedded assets

### Dependencies Philosophy
The project intentionally minimizes dependencies:
- `kemal` - Web framework
- `docopt` - CLI parsing (as preferred by the maintainer)
- `baked_file_system` - Asset embedding
- `html_builder` - Clean HTML generation
- `kemal-basic-auth` - Optional authentication

### Authentication
Basic auth can be enabled via environment variables:
- `GRAFITO_AUTH_USER` - Username
- `GRAFITO_AUTH_PASS` - Password

### Permissions
To access all system logs, the application needs to run as a user in the `systemd-journal` group.

## Development Notes

### Crystal Version Requirements
- Requires Crystal >= 1.16.0

### Code Style
- Uses Ameba linter with auto-fix
- Cyclomatic complexity warnings are disabled for `src/journalctl.cr`
- Block parameter naming restrictions are disabled
- Avoid using `not_nil!` (per maintainer preference)
- Prefer descriptive parameter names over single letters

### Testing
- Test files are in the `spec/` directory
- Uses Crystal's built-in spec framework
- All 75 tests should pass before committing

### Asset Management
- Original assets in `src/assets/`
- Minified versions used in build: `index.min.html`, `style.min.css`
- Assets get embedded at compile time, not served as files

### Multi-host Support
Grafito can display logs from multiple hosts when using systemd's journal centralization features. The hostname filter allows isolating logs from specific machines.

### CLI Interface
Uses docopt for command-line parsing as explicitly preferred by the maintainer.

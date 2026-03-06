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
- `make watch` - Watch mode: auto-rebuild on changes using entr (requires fd tool)
- `make clean` - Remove build artifacts
- `shards build` - Build using shards (respects shard.yml settings)
- `shards build --release` - Release build with optimizations

### Testing and Quality
- `make test` - Run all tests
- `crystal spec` - Run tests using Crystal spec framework
- `crystal spec spec/journalctl_spec.cr` - Run specific test file
- `make lint` - Run Ameba linter with auto-fix
- `ameba --fix src` - Alternative way to lint with auto-fix

### Dependencies
- `make shards` - Install/update Crystal dependencies
- `shards install` - Alternative way to install dependencies
- `shards update` - Update dependencies to latest compatible versions

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
- `src/ai/` - AI provider abstraction layer for log analysis
  - `config.cr` - AI configuration and provider detection
  - `provider.cr` - Abstract base class for AI providers
  - `providers/` - Concrete implementations (Anthropic, OpenAI-compatible)
- `src/fake_journal_data.cr` - Fake data generation for demo mode

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
- Tests cover: journalctl parsing, timeline generation, helper functions, timezone handling
- Run `crystal spec` to execute all tests before committing
- Individual test files can be run: `crystal spec spec/journalctl_spec.cr`

### Asset Management
- Original assets in `src/assets/`
- Minified versions used in build: `index.min.html`, `style.min.css`
- Assets get embedded at compile time, not served as files

### Multi-host Support
Grafito can display logs from multiple hosts when using systemd's journal centralization features. The hostname filter allows isolating logs from specific machines.

### CLI Interface
Uses docopt for command-line parsing as explicitly preferred by the maintainer. Supports configuration via:
- Command-line arguments (highest priority)
- Environment variables with `GRAFITO_` prefix
- Optional config file (via `GRAFITO_CONFIG` environment variable)

### Development Philosophy
- **Minimal dependencies**: Only essential dependencies are used to keep binary size small
- **Single binary deployment**: All assets are embedded, no external files needed
- **Build on existing tools**: Leverages systemd journalctl rather than reinventing log storage
- **Simplicity over features**: Focus on core functionality rather than extensive configuration
- **Literate programming**: Source code includes detailed markdown comments for documentation generation

### Key Configuration Options
- `--bind ADDRESS` / `-b ADDRESS` - Bind address (default: 127.0.0.1)
- `--port PORT` / `-p PORT` - Port number (default: 3000)
- `--units UNITS` / `-U UNITS` - Restrict to specific systemd units (comma-separated)
- `--timezone TIMEZONE` / `-t TIMEZONE` - Timezone for timestamps (default: local)
- `--base-path PATH` - Base path for deployment (default: /)
- `--log-level LEVEL` - Set log level (debug, info, warn, error, fatal)

### AI Features Configuration
AI log analysis is optional and provider-agnostic:
- `ANTHROPIC_API_KEY` - Anthropic/Claude API key
- `Z_AI_API_KEY` - Z.AI API key (backward compatible)
- `OPENAI_API_KEY` - OpenAI API key
- `GROQ_API_KEY` - Groq API key
- `TOGETHER_API_KEY` - Together.ai API key
- `GRAFITO_AI_ENDPOINT` - Custom endpoint URL (for Ollama, etc.)
- `GRAFITO_AI_MODEL` - Override default model
- `GRAFITO_AI_PROVIDER` - Force specific provider (anthropic, openai, z_ai, groq, ollama)

## Deployment and Release

### Static Binary Builds
- `build_static.sh` - Build static binaries for AMD64 and ARM64 using Docker
- Produces fully static binaries that can run on any Linux system
- Uses QEMU multiarch for cross-compilation

### Release Process
- `do_release.sh` - Automated release script that:
  - Updates version in shard.yml and install.sh
  - Builds static binaries
  - Creates git tag and commit
  - Generates GitHub release with changelog
  - Uploads Docker images
  - Updates AUR package

### Docker Deployment
- `Dockerfile` - Standard Docker build
- `Dockerfile.static` - Static binary build
- Images available for AMD64 and ARM64 architectures

### Systemd Service
- `grafito.service` - Production systemd service file
- `grafito-fake.service` - Demo mode with fake data
- Uses DynamicUser for security
- Runs with systemd-journal group for log access

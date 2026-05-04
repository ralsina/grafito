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

### Documentation Generation
- `make website` - Generate HTML documentation from source code comments
- Uses crycco tool to extract markdown comments from Crystal source files
- Output goes to `site/` directory
- Documentation theme: apathy
- Generates browsable documentation for all source files

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
  - `request.cr` - AI request interface
  - `response.cr` - AI response normalization
  - `providers/anthropic.cr` - Anthropic/Claude API integration
  - `providers/openai_compatible.cr` - OpenAI-compatible API wrapper (Z.AI, OpenAI, Groq, Ollama, etc.)
- `src/fake_journal_data.cr` - Fake data generation for demo mode (compile with `--flag=fake_journal`)

### Dependencies Philosophy
The project intentionally minimizes dependencies:
- `kemal` - Web framework
- `docopt` - CLI parsing (as preferred by the maintainer)
- `baked_file_system` - Asset embedding for single-binary deployment
- `html_builder` - Clean HTML generation without string concatenation
- `kemal-basic-auth` - Optional authentication
- `anthropic` - Anthropic/Claude API client for AI features
- `faker` - Fake data generation for development/demo mode

### External Libraries
Code in `lib/` consists of external shards and should not be modified:
- Crystal dependencies installed via shards
- Version-controlled libraries that should be updated via `shards update`
- Modifications to lib/ files will be lost when dependencies are updated

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
- Tests cover: journalctl parsing, timeline generation, helper functions, timezone handling, AI providers
- Run `crystal spec` to execute all tests before committing
- Individual test files can be run: `crystal spec spec/journalctl_spec.cr`
- AI provider tests: `crystal spec spec/ai/`

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
- **Code generation**: `make website` uses crycco to generate documentation from source comments

### Important Development Constraints
- **Never use `not_nil!`**: Explicitly forbidden by maintainer preference
- **Avoid `to_s` as crutch**: Don't use string conversion to work around nilable values
- **No `--release` flag**: Don't use release builds during development (use regular build)
- **Descriptive parameters**: Use descriptive names for block parameters, not single letters
- **Fix linting errors**: Always run `ameba --fix` and fix issues before committing
- **Test before committing**: Run tests with `crystal spec` before declaring work complete
- **Build verification**: Always build successfully before declaring tasks done
- **No binary commits**: Never commit compiled binaries to the repository

### Key Configuration Options
- `--bind ADDRESS` / `-b ADDRESS` - Bind address (default: 127.0.0.1)
- `--port PORT` / `-p PORT` - Port number (default: 3000)
- `--units UNITS` / `-U UNITS` - Restrict to specific systemd units (comma-separated)
- `--timezone TIMEZONE` / `-t TIMEZONE` - Timezone for timestamps (default: local)
- `--base-path PATH` - Base path for deployment (default: /)
- `--log-level LEVEL` - Set log level (debug, info, warn, error, fatal)

### Demo/Development Mode
- Compile with `--flag=fake_journal` to enable fake data mode for UI development without journal access
- Creates realistic-looking log data for testing interface features
- Useful for development on systems without systemd journals

### AI Features Configuration
AI log analysis is optional and provider-agnostic:
- `ANTHROPIC_API_KEY` - Anthropic/Claude API key
- `Z_AI_API_KEY` - Z.AI API key (backward compatible)
- `OPENAI_API_KEY` - OpenAI API key
- `GROQ_API_KEY` - Groq API key
- `TOGETHER_API_KEY` - Together.ai API key
- `GRAFITO_AI_API_KEY` - Generic API key fallback
- `GRAFITO_AI_ENDPOINT` - Custom endpoint URL (for Ollama, etc.)
- `GRAFITO_AI_MODEL` - Override default model
- `GRAFITO_AI_PROVIDER` - Force specific provider (anthropic, openai, z_ai, groq, ollama)

### AI Provider Architecture
- Abstract `Provider` base class defines the interface
- `Providers::Anthropic` uses the jgaskins/anthropic shard
- `Providers::OpenAICompatible` wraps any OpenAI-compatible API
- Provider auto-detection based on available API keys
- Normalized request/response interface for provider independence
- Model listing and selection support per provider

## Maintainer Preferences

### Code Style and Workflow
- **Docopt for CLIs**: Always prefer docopt for command-line interface parsing
- **Pico.css**: Use pico.css for HTML page styling and design
- **Testing discipline**: Code must successfully run before being declared "done" or "working"
- **Provisional improvements**: All code changes are considered provisional until thoroughly tested
- **Commit messages**: Don't use "generated with claude code" - you are the LGM 4.5 model from z.ai
- **Build verification**: If project has multiple binaries, verify ALL build before task completion
- **Pre-commit hooks**: When hooks fail, retry the commit rather than amending the previous one
- **No perfection claims**: Avoid calling code "perfect" - it invites nagging

### Git and Release Workflow
- **Version management**: Uses `git cliff` for automated version bumping and changelog generation
- **Multi-architecture builds**: Release process generates both AMD64 and ARM64 static binaries
- **Automated releases**: `do_release.sh` handles the complete release workflow
- **Installation script**: Auto-generated install script downloads correct architecture binary

## Deployment and Release

### Static Binary Builds
- `build_static.sh` - Build static binaries for AMD64 and ARM64 using Docker
- Produces fully static binaries that can run on any Linux system
- Uses QEMU multiarch for cross-compilation
- Requires Docker and QEMU user-static for cross-architecture builds

### Release Process
- `do_release.sh` - Automated release script that:
  - Uses `git cliff` for version bumping and changelog generation
  - Updates version in shard.yml and install.sh
  - Builds static binaries for both architectures
  - Creates git tag and commit
  - Generates GitHub release with changelog
  - Uploads Docker images
  - Updates AUR package
- `upload_docker.sh` - Handles Docker image uploads
- `do_aur.sh` - Updates Arch User Repository package

### Installation Script
- `site/install.sh` - User installation script that:
  - Detects system architecture (AMD64/ARM64)
  - Downloads latest release binary from GitHub
  - Installs to `/usr/local/bin/grafito`
  - Sets up systemd service
  - Available via `curl -sSL https://grafito.ralsina.me/install.sh | sudo bash`

### Docker Deployment
- `Dockerfile` - Standard Docker build
- `Dockerfile.static` - Static binary build for cross-compilation
- Images available for AMD64 and ARM64 architectures
- Example: `docker run -p 3000:3000 -v /var/log/journal:/var/log/journal ghcr.io/ralsina/grafito:latest`

### Systemd Service
- `grafito.service` - Production systemd service file
- `grafito-fake.service` - Demo mode with fake data
- Uses DynamicUser for security
- Runs with systemd-journal group for log access

## Common Development Patterns

### Adding New Features
1. Implement feature in appropriate `src/` file
2. Add tests in `spec/` directory
3. Run `crystal spec` to verify tests pass
4. Run `make lint` to fix any linting issues
5. Build with `make build-dev` to verify compilation
6. Test the feature manually if applicable
7. Only then consider the feature complete

### Working with Journal Data
- Use `Journalctl::LogEntry` for parsing individual log entries
- Use `Journalctl.build_query_command` for constructing journalctl commands
- Respect timezone configuration via `Grafito.timezone`
- Handle nil values properly without using `not_nil!`
- Test with fake data mode by compiling with `--flag=fake_journal`

### AI Feature Development
- Inherit from `Grafito::AI::Provider` for new providers
- Use `Grafito::AI::Request` for normalized input
- Return `Grafito::AI::Response` for normalized output
- Add provider configuration in `src/ai/config.cr`
- Test with mock APIs in `spec/ai/` directory

### Web Interface Changes
- HTML templates in `src/assets/` (will be minified during build)
- Use `html_builder` for generating HTML programmatically
- Follow pico.css conventions for styling
- Consider base path configuration via `Grafito.base_path`
- Test both with and without authentication enabled
- Supports basic authentication via environment variables

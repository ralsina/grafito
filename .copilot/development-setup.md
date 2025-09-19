# Development Environment Setup

## Prerequisites

### Crystal Language
Install Crystal programming language (≥1.16.0):

#### Ubuntu/Debian
```bash
curl -fsSL https://crystal-lang.org/install.sh | sudo bash
```

#### macOS
```bash
brew install crystal
```

#### Arch Linux
```bash
sudo pacman -S crystal shards
```

### System Dependencies
Grafito requires these system tools to be available:

- `journalctl` - for reading systemd journal logs
- `systemctl` - for discovering service units
- `curl` - for development and testing (optional)

These are typically pre-installed on systemd-based Linux systems.

## Project Setup

### 1. Clone Repository
```bash
git clone https://github.com/ralsina/grafito.git
cd grafito
```

### 2. Install Dependencies
```bash
# Install Crystal dependencies
shards install

# Verify installation
shards check
```

### 3. Build Application
```bash
# Development build (faster compilation, includes debug info)
shards build

# Production build (optimized, static linking)
shards build --release --static
```

### 4. Run Application
```bash
# Run directly with Crystal
crystal run src/main.cr -- --help

# Run compiled binary
./bin/grafito --help

# Run with development settings
./bin/grafito -b 127.0.0.1 -p 3000
```

## Development Workflow

### File Structure
```
grafito/
├── src/                 # Crystal source code
│   ├── main.cr         # Entry point
│   ├── *.cr            # Core modules
│   └── assets/         # Frontend files (HTML, CSS, JS)
├── spec/               # Test files
├── site/               # Marketing website
├── shard.yml          # Dependencies and metadata
└── shard.lock         # Locked dependency versions
```

### Asset Development

#### CSS Development
The application uses both full and minified CSS:

- Edit: `src/assets/style.css` (full version for development)
- Minify: Create `src/assets/style.min.css` for production
- The app loads `style.min.css` in production

#### HTML Development
- Main app: `src/assets/index.html`
- Marketing: `site/index.html`
- Assets are baked into the binary during compilation

### Running Tests
```bash
# Run all tests
crystal spec

# Run specific test file
crystal spec spec/journalctl_spec.cr

# Run with verbose output
crystal spec --verbose
```

### Code Quality

#### Linting with Ameba
```bash
# Install Ameba (Crystal linter)
shards install

# Run linter
./bin/ameba

# Run with specific rules
./bin/ameba --rules Lint/UselessAssign
```

#### Code Formatting
```bash
# Format all Crystal files
crystal tool format

# Check if files need formatting
crystal tool format --check
```

## Development Commands

### Useful Shards Commands
```bash
# Show dependency tree
shards list

# Update dependencies
shards update

# Install missing dependencies
shards install

# Check for outdated dependencies
shards outdated
```

### Building Variations
```bash
# Debug build (default)
shards build

# Release build
shards build --release

# Static build (no dynamic linking)
shards build --static

# Release + static (production)
shards build --release --static
```

### Running with Different Options
```bash
# Bind to all interfaces
./bin/grafito -b 0.0.0.0 -p 1111

# Development with live reload (manual restart needed)
watchexec -r -e cr "crystal run src/main.cr"

# Run with authentication
GRAFITO_AUTH_USER=admin GRAFITO_AUTH_PASS=secret ./bin/grafito
```

## Debugging

### Enable Debug Logging
```bash
# Crystal debug mode
CRYSTAL_LOG_LEVEL=debug ./bin/grafito

# Verbose journalctl output
./bin/grafito --verbose
```

### Common Issues

#### "journalctl not found"
Ensure systemd is installed and journalctl is in PATH.

#### Permission denied for journal access
Add user to systemd-journal group:
```bash
sudo usermod -a -G systemd-journal $USER
# Log out and back in, or restart systemd service
```

#### Port already in use
```bash
# Find process using port 3000
sudo lsof -i :3000

# Use different port
./bin/grafito -p 3001
```

#### Missing dependencies
```bash
# Clean and reinstall
rm -rf lib/ shard.lock
shards install
```

### Performance Testing
```bash
# Test with curl
curl "http://localhost:3000/logs?unit=nginx.service"

# Load testing (if you have wrk installed)
wrk -t4 -c10 -d10s "http://localhost:3000/logs"

# Memory usage monitoring
ps aux | grep grafito
```

## IDE Setup

### VS Code Extensions
Recommended extensions for Crystal development:
- Crystal Language Support
- Crystal Language Server
- Ameba (Crystal linter)

### Configuration
Create `.vscode/settings.json`:
```json
{
  "crystal-lang.server": "scry",
  "crystal-lang.implementations": true,
  "files.associations": {
    "*.cr": "crystal"
  }
}
```

## Deployment Testing

### Local Systemd Service (for testing)
1. Create service file:
```bash
sudo cp grafito.service /etc/systemd/system/
sudo systemctl daemon-reload
```

2. Install binary:
```bash
sudo cp ./bin/grafito /usr/local/bin/
sudo chmod +x /usr/local/bin/grafito
```

3. Start service:
```bash
sudo systemctl start grafito
sudo systemctl status grafito
```

### Docker Development
```bash
# Build development image
docker build -t grafito-dev .

# Run with journal access (Linux only)
docker run -p 3000:3000 -v /var/log/journal:/var/log/journal:ro grafito-dev
```

## Contributing Workflow

1. Fork the repository
2. Create feature branch: `git checkout -b my-feature`
3. Make changes and test: `crystal spec`
4. Run linter: `./bin/ameba`
5. Format code: `crystal tool format`
6. Commit changes: `git commit -am 'Add feature'`
7. Push branch: `git push origin my-feature`
8. Create Pull Request

### Pre-commit Checklist
- [ ] Tests pass (`crystal spec`)
- [ ] Linter clean (`./bin/ameba`)
- [ ] Code formatted (`crystal tool format`)
- [ ] Documentation updated
- [ ] Binary builds successfully (`shards build --release`)

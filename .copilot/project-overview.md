# Grafito - Project Overview

## About
Grafito is a simple, self-contained web-based log viewer for systemd's `journalctl`. It provides an intuitive web interface to browse and filter system logs directly from a browser.

## Architecture & Tech Stack

### Backend (Crystal)
- **Language**: Crystal (≥1.16.0)
- **Web Framework**: Kemal (lightweight Sinatra-like framework)
- **Authentication**: kemal-basic-auth (optional HTTP Basic Auth)
- **Asset Management**: baked-file-system (embeds all assets in binary)
- **Command Line**: docopt (elegant CLI interface)
- **HTML Generation**: html_builder (programmatic HTML generation)

### Frontend
- **JavaScript Library**: HTMX (minimal JavaScript, server-driven UI)
- **CSS Framework**: Pico CSS (lightweight, semantic CSS framework)
- **Fonts**: Chivo & Chivo Mono (Google Fonts)
- **Icons**: Material Design Icons
- **Theme**: Light/Dark mode support with system preference detection

### System Integration
- **Log Source**: systemd journalctl
- **Service Discovery**: systemctl (for unit name autocomplete)
- **Deployment**: Single binary with embedded assets
- **System Service**: Runs as systemd service with DynamicUser

## Key Components

### Core Modules

1. **Main Entry Point** (`src/main.cr`)
   - CLI argument parsing with docopt
   - Asset baking and static file serving
   - Authentication setup
   - Kemal web server initialization

2. **API Layer** (`src/grafito.cr`)
   - RESTful endpoints for log querying
   - JSON API for HTMX frontend
   - Log filtering and pagination

3. **Journal Integration** (`src/journalctl.cr`)
   - Wrapper around journalctl command
   - Log entry parsing and serialization
   - Service unit discovery via systemctl

4. **Helper Functions** (`src/grafito_helpers.cr`)
   - HTML generation utilities
   - Query parameter handling
   - URL state management

5. **Timeline Visualization** (`src/timeline.cr`)
   - Log frequency histogram generation
   - SVG chart rendering for log distribution

6. **Asset Handler** (`src/baked_handler.cr`)
   - Serves embedded static files from binary
   - Custom Kemal handler for asset delivery

### Frontend Structure

1. **Main Application** (`src/assets/index.html`)
   - HTMX-powered single page application
   - Collapsible sidebar with filters
   - Real-time log streaming
   - Responsive design

2. **Styles** (`src/assets/style.css`)
   - Custom CSS extending Pico CSS
   - Dark/light theme variables
   - Responsive grid layouts
   - Animation transitions

3. **Marketing Site** (`site/index.html`)
   - Static landing page with particle effects
   - Feature showcase and installation instructions
   - Testimonial carousel
   - Theme switcher integration

## Key Features

### Log Filtering
- **Text Search**: Full-text search using journalctl -g
- **Unit Filter**: Filter by systemd service units
- **Tag Filter**: Filter by syslog identifier
- **Hostname Filter**: Filter by source hostname (multi-host setups)
- **Time Range**: Predefined ranges (15min, 1h, 1d, 1w, etc.)
- **Priority Levels**: Emergency through Debug (0-7)

### User Interface
- **Live View**: Auto-refresh every 10 seconds
- **Column Visibility**: Toggle timestamp, hostname, unit, priority, message columns
- **Sortable Headers**: Click to sort by any column
- **Detail View**: Expandable log entry details with full JSON
- **Context View**: Show surrounding log entries
- **Export**: Download filtered logs as plain text
- **Shareable URLs**: Bookmark and share filter states

### System Integration
- **Single Binary**: All assets baked into executable
- **Systemd Service**: Runs with DynamicUser and systemd-journal group
- **Authentication**: Optional HTTP Basic Auth
- **Multi-host**: Support for centralized logging via journal-remote

## Development Workflow

### Build Process
```bash
# Install dependencies
shards install

# Development build
shards build

# Production build
shards build --release --static

# Run tests
crystal spec

# Linting
./bin/ameba
```

### Asset Pipeline
- Static assets in `src/assets/` are baked into binary
- CSS minification for production
- Marketing site in separate `site/` directory

### Testing
- Unit tests in `spec/` directory
- Fake data generation for demo mode
- CI/CD via GitHub Actions

## File Organization

```
grafito/
├── src/
│   ├── main.cr              # Entry point & CLI
│   ├── grafito.cr           # Web API endpoints
│   ├── journalctl.cr        # journalctl wrapper
│   ├── grafito_helpers.cr   # Utility functions
│   ├── timeline.cr          # Log visualization
│   ├── baked_handler.cr     # Asset serving
│   └── assets/              # Frontend files
│       ├── index.html       # Main app UI
│       ├── style.css        # Styles
│       ├── style.min.css    # Minified styles
│       └── (other assets)
├── site/                    # Marketing website
│   ├── index.html          # Landing page
│   └── install.sh          # Installation script
├── spec/                   # Test suite
└── shard.yml              # Crystal dependencies
```

## Configuration Options

### Environment Variables
- `GRAFITO_AUTH_USER`: HTTP Basic Auth username
- `GRAFITO_AUTH_PASS`: HTTP Basic Auth password

### Command Line Options
- `-b, --bind`: Bind address (default: 127.0.0.1)
- `-p, --port`: Port number (default: 3000)
- `--help`: Show usage information
- `--version`: Show version

### Systemd Service
- Runs with `DynamicUser=yes`
- Member of `systemd-journal` group for log access
- Configurable bind address and port
- Automatic restart on failure

## Security Considerations

### Log Access
- Requires membership in `systemd-journal` group
- Can access all system logs by default
- Optional authentication for web interface

### Network Security
- Bind to localhost by default
- HTTPS not built-in (use reverse proxy)
- Basic authentication available but not enforced

### Data Privacy
- No log persistence beyond systemd journal
- No external network calls except for fonts/icons
- All processing happens server-side

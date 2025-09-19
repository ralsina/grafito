# Coding Guidelines and Conventions

## Crystal Code Style

### General Principles

- Follow Crystal's official style guide
- Prioritize readability and maintainability
- Use meaningful names for variables, methods, and classes
- Keep methods focused and single-purpose
- Minimize dependencies to maintain lightweight binary

### Naming Conventions

#### Classes and Modules
```crystal
# Use PascalCase for classes and modules
class LogEntry
end

module Grafito
  class JournalCtl
  end
end
```

#### Methods and Variables
```crystal
# Use snake_case for methods and variables
def parse_log_entry(json_string : String)
  log_data = JSON.parse(json_string)
  timestamp = log_data["__REALTIME_TIMESTAMP"]?.try(&.as_s)
end

# Boolean methods should be descriptive
def entry_has_unit?
  !unit.nil?
end
```

#### Constants
```crystal
# Use SCREAMING_SNAKE_CASE for constants
MAX_LOG_ENTRIES = 5000
DEFAULT_BIND_ADDRESS = "127.0.0.1"
SAMPLE_UNIT_NAMES = ["nginx.service", "sshd.service"]
```

### Method Organization

#### Class Method Order
1. Class-level constants
2. Include/extend statements
3. Class variables and properties
4. Constructor methods
5. Public instance methods
6. Private instance methods
7. Class methods

#### Method Signatures
```crystal
# Use type annotations for clarity
def build_query_command(
  lines : Int32 = 5000,
  unit : String? = nil,
  tag : String? = nil,
  priority : String? = nil
) : Array(String)
end

# Return type annotations for complex methods
def parse_log_entries(output : String) : Array(LogEntry)
end
```

### Error Handling

#### Use Explicit Error Types
```crystal
# Prefer specific rescue blocks
begin
  result = risky_operation()
rescue ex : JSON::ParseException
  Log.error { "JSON parsing failed: #{ex.message}" }
  return nil
rescue ex : IO::Error
  Log.error { "IO operation failed: #{ex.message}" }
  return nil
end
```

#### Nil Handling
```crystal
# Use safe navigation and nil coalescing
timestamp = entry["__REALTIME_TIMESTAMP"]?.try(&.as_s) || ""

# Use explicit nil checks when needed
if unit = params["unit"]?
  query_args << "--unit=#{unit}" unless unit.empty?
end
```

### Documentation

#### Module-level Documentation
```crystal
# # The Grafito Module
#
# This module defines the API for the grafito backend.
# It provides RESTful endpoints for log querying and filtering.
module Grafito
end
```

#### Method Documentation
```crystal
# Builds the journalctl command array based on provided filters.
#
# Args:
#   lines: Maximum number of log entries to retrieve
#   unit: Systemd unit to filter by (optional)
#   tag: Syslog identifier to filter by (optional)
#
# Returns:
#   Array of command line arguments for journalctl
def build_query_command(lines : Int32, unit : String? = nil) : Array(String)
end
```

## Frontend Code Style

### HTML Structure

#### Semantic HTML
```html
<!-- Use semantic elements -->
<main>
  <aside id="filters-sidebar">
    <section class="filter-group">
      <h2>Time Filters</h2>
    </section>
  </aside>
  <section id="results">
    <table>
      <thead>
        <tr>
          <th scope="col">Timestamp</th>
        </tr>
      </thead>
    </table>
  </section>
</main>
```

#### HTMX Conventions
```html
<!-- Use descriptive trigger names -->
<input
  hx-get="logs"
  hx-trigger="keyup changed delay:500ms"
  hx-target="#results"
  hx-include=".log-filter"
  class="log-filter"
/>

<!-- Use clear custom events -->
<button hx-trigger="immediateUnitFilterUpdate">
```

### CSS Organization

#### File Structure
- `style.css` - Full development version
- `style.min.css` - Production minified version
- Use CSS custom properties for theming
- Follow mobile-first responsive design

#### Class Naming
```css
/* Use BEM-like conventions for component styles */
.filter-group { }
.filter-group__header { }
.filter-group--collapsed { }

/* Use semantic class names */
.sidebar-actions-area { }
.testimonial-carousel { }
.hero-separator { }
```

#### CSS Variables
```css
/* Define theme variables */
:root {
  --sidebar-width: 18.75rem;
  --transition-duration: 0.3s;
  --particle-opacity: 0.1;
}

/* Use variables consistently */
.sidebar {
  width: var(--sidebar-width);
  transition: width var(--transition-duration) ease;
}
```

### JavaScript Style

#### Event Handling
```javascript
// Use descriptive function names
function updateToggleButtonPosition() {
  // Implementation
}

function buildFilterURLSearchParams() {
  // Implementation
}

// Use const for configuration objects
const SHARED_FILTER_CONFIGS = [
  { id: "search-box", param: "q", type: "value" },
];
```

#### Modern JavaScript
```javascript
// Use arrow functions for short callbacks
SHARED_FILTER_CONFIGS.forEach(config => {
  const element = document.getElementById(config.id);
});

// Use template literals
const shareUrl = `${window.location.origin}${window.location.pathname}?${params}`;

// Use destructuring when appropriate
const { successful, error } = event.detail;
```

## File Organization

### Directory Structure
```
src/
├── main.cr              # Entry point, CLI, asset baking
├── grafito.cr           # Web endpoints and API
├── journalctl.cr        # System integration
├── grafito_helpers.cr   # Utility functions
├── timeline.cr          # Visualization components
├── baked_handler.cr     # Asset serving
├── fake_journal_data.cr # Test data generation
└── assets/              # Frontend files
    ├── index.html       # Main application
    ├── style.css        # Styles (development)
    └── style.min.css    # Styles (production)
```

### Module Responsibilities

#### Core Modules
- `main.cr` - Entry point, CLI parsing, server setup
- `grafito.cr` - HTTP endpoints, request handling
- `journalctl.cr` - System command execution, log parsing
- `grafito_helpers.cr` - Shared utilities, HTML generation

#### Supporting Modules
- `timeline.cr` - SVG generation, log frequency analysis
- `baked_handler.cr` - Static asset serving
- `fake_journal_data.cr` - Development/demo data

### Import Organization
```crystal
# Standard library imports first
require "json"
require "log"
require "time"

# Third-party dependencies
require "kemal"
require "html_builder"

# Internal modules
require "./journalctl"
require "./timeline"
```

## Testing Conventions

### Test File Organization
```
spec/
├── spec_helper.cr                    # Test configuration
├── journalctl_spec.cr               # Unit tests
├── grafito_helpers_spec.cr          # Helper function tests
├── timeline_spec.cr                 # Visualization tests
└── fake_journal_data_spec.cr        # Test data validation
```

### Test Structure
```crystal
describe "Journalctl" do
  describe "#build_query_command" do
    it "generates basic command" do
      result = Journalctl.build_query_command(lines: 100)
      result.should contain("--lines=100")
      result.should contain("--output=json")
    end

    it "includes unit filter when provided" do
      result = Journalctl.build_query_command(unit: "nginx.service")
      result.should contain("--unit=nginx.service")
    end
  end
end
```

### Test Data
- Use `faker` for generating realistic test data
- Create reusable test fixtures
- Mock external system calls (`journalctl`, `systemctl`)

## Performance Guidelines

### Memory Management
- Avoid large object allocations in request handlers
- Use streaming for large log outputs
- Implement pagination for log results

### Asset Optimization
- Minify CSS and JavaScript for production
- Use baked assets to eliminate file system calls
- Optimize SVG graphics in timelines

### Database/System Calls
- Limit journalctl query scope with appropriate filters
- Cache systemctl unit lists when possible
- Use background processes for long-running queries

## Security Considerations

### Input Validation
```crystal
# Sanitize user input for system commands
def sanitize_unit_name(unit : String) : String?
  return nil if unit.empty?
  # Allow only valid systemd unit characters
  return unit if unit.match(/\A[a-zA-Z0-9\-_.@]+\z/)
  nil
end
```

### Authentication
- Use environment variables for credentials
- Implement optional HTTP Basic Auth
- Never log authentication credentials

### System Access
- Run with minimal required permissions
- Use systemd DynamicUser for service isolation
- Restrict journalctl access through group membership

## Configuration Management

### Environment Variables
```crystal
# Use descriptive names and provide defaults
AUTH_USER = ENV["GRAFITO_AUTH_USER"]?
AUTH_PASS = ENV["GRAFITO_AUTH_PASS"]?
BIND_ADDRESS = ENV["GRAFITO_BIND"] || "127.0.0.1"
```

### Command Line Options
```crystal
# Use docopt for clear CLI interface
DOC = <<-DOCOPT
Grafito - A simple log viewer.

Usage:
  grafito [--bind=<address>] [--port=<port>]
  grafito --help
  grafito --version

Options:
  -b, --bind=<address>  Bind address [default: 127.0.0.1]
  -p, --port=<port>     Port number [default: 3000]
  --help                Show this help
  --version             Show version
DOCOPT
```

## Git Workflow

### Commit Messages
```
feat: add timeline visualization for log frequency
fix: resolve sidebar toggle button positioning
docs: update API documentation for log endpoints
style: improve CSS organization and naming
refactor: extract common HTML generation methods
test: add unit tests for journalctl command building
```

### Branch Naming
- `feat/feature-name` - New features
- `fix/issue-description` - Bug fixes
- `docs/update-topic` - Documentation updates
- `refactor/component-name` - Code refactoring

### Pull Request Process
1. Create feature branch from main
2. Write tests for new functionality
3. Ensure all tests pass
4. Run linter and fix issues
5. Update documentation
6. Submit PR with clear description
7. Address review feedback

## Code Review Checklist

### Functionality
- [ ] Code works as intended
- [ ] Edge cases are handled
- [ ] Error conditions are managed properly
- [ ] Performance is acceptable

### Style and Standards
- [ ] Follows Crystal style guide
- [ ] Uses consistent naming conventions
- [ ] Includes appropriate documentation
- [ ] Has adequate test coverage

### Security
- [ ] Input is properly validated
- [ ] No hardcoded secrets
- [ ] System calls are secure
- [ ] Authentication is handled correctly

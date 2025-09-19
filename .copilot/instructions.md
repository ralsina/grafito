# GitHub Copilot Agent Configuration for Grafito

## Project Context
Grafito is a self-contained web-based systemd journal log viewer built with Crystal and HTMX. This configuration helps GitHub Copilot understand the project's architecture, conventions, and development practices.

## Agent Instructions

### Core Technologies
- **Backend**: Crystal programming language with Kemal web framework
- **Frontend**: HTMX for dynamic interactions, Pico CSS for styling
- **System Integration**: journalctl and systemctl for systemd interaction
- **Assets**: Baked into binary using baked-file-system
- **Authentication**: Optional HTTP Basic Auth via kemal-basic-auth

### Key Principles
1. **Simplicity**: Minimal dependencies, single binary deployment
2. **Performance**: Lightweight, efficient log processing
3. **Security**: Safe system command execution, input validation
4. **Usability**: Intuitive web interface, real-time updates

### Architecture Patterns

#### Backend Structure
- **Main Entry** (`src/main.cr`): CLI parsing, asset baking, server initialization
- **API Layer** (`src/grafito.cr`): RESTful endpoints for log operations
- **System Layer** (`src/journalctl.cr`): journalctl wrapper and log parsing
- **Helpers** (`src/grafito_helpers.cr`): HTML generation, query utilities
- **Visualization** (`src/timeline.cr`): SVG chart generation for log frequency

#### Frontend Patterns
- **HTMX-driven**: Server-side HTML generation with client-side updates
- **Progressive Enhancement**: Works without JavaScript, enhanced with it
- **State Management**: URL parameters for filter persistence
- **Responsive Design**: Mobile-first approach with Pico CSS

### Code Conventions

#### Crystal Style
- Use Crystal's standard formatting (`crystal tool format`)
- Type annotations for public method parameters and return values
- Explicit error handling with specific rescue blocks
- Meaningful variable and method names in snake_case
- Constants in SCREAMING_SNAKE_CASE

#### HTML/CSS Style
- Semantic HTML5 elements
- BEM-like CSS class naming
- CSS custom properties for theming
- HTMX attributes with descriptive trigger names
- Accessible form controls with proper labels

### Common Tasks

#### Adding New Log Filters
1. Add input element to sidebar in `src/assets/index.html`
2. Include in `SHARED_FILTER_CONFIGS` JavaScript array
3. Handle parameter in `journalctl.cr` build_query_command method
4. Update URL state management in frontend JavaScript

#### Adding API Endpoints
1. Define route in `src/grafito.cr` with appropriate HTTP method
2. Extract query parameters using `optional_query_param` helper
3. Call appropriate journalctl method with validated parameters
4. Return JSON or HTML response based on Accept header

#### System Command Integration
1. Always validate input parameters before shell execution
2. Use Array(String) for command building to prevent injection
3. Handle process errors with specific rescue blocks
4. Log command execution for debugging when needed

### Security Guidelines
- Sanitize all user input before system command execution
- Use parameterized command arrays, never string interpolation
- Validate systemd unit names against allowed character patterns
- Implement rate limiting for expensive operations
- Never log authentication credentials

### Performance Considerations
- Limit journalctl query scope with appropriate time ranges
- Implement pagination for large result sets
- Use streaming responses for real-time log tailing
- Cache expensive operations like service unit discovery
- Minimize memory allocations in request handlers

### Testing Approach
- Unit tests for core logic in Crystal
- Mock system commands to avoid dependencies
- Test HTTP endpoints with various parameter combinations
- Validate HTML generation and HTMX interactions
- Use faker for realistic test data generation

### Common Patterns to Follow

#### Error Handling Pattern
```crystal
begin
  result = system_operation()
rescue ex : SpecificException
  Log.error { "Operation failed: #{ex.message}" }
  return nil
end
```

#### Query Parameter Handling Pattern
```crystal
unit = optional_query_param(env, "unit")
if unit && !unit.empty?
  command_args << "--unit=#{unit}"
end
```

#### HTMX Response Pattern
```html
<div
  hx-get="/api/endpoint"
  hx-trigger="event delay:500ms"
  hx-target="#target-element"
  hx-include=".form-elements"
>
```

#### CSS Component Pattern
```css
.component-name {
  /* Base styles */
}

.component-name--modifier {
  /* Variant styles */
}

.component-name__element {
  /* Child element styles */
}
```

### File Modification Guidelines
- When editing `src/assets/style.css`, remember to minify to `style.min.css`
- Asset changes require rebuilding the binary to take effect
- Test all HTMX interactions after modifying frontend code
- Run `crystal spec` and `./bin/ameba` before committing changes

### Development Workflow
1. Make changes to source files
2. Run tests: `crystal spec`
3. Check linting: `./bin/ameba`
4. Format code: `crystal tool format`
5. Build and test: `shards build && ./bin/grafito`
6. Update documentation if needed

### Deployment Considerations
- Single binary contains all assets
- Requires systemd-journal group membership for log access
- Can run with DynamicUser for security
- Supports environment variables for authentication
- Bind to 0.0.0.0 for network access, 127.0.0.1 for local only

This configuration should help GitHub Copilot provide more accurate and contextually appropriate suggestions for the Grafito project.

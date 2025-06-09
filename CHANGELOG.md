# Changelog

All notable changes to this project will be documented in this file.

## [0.10.0] - 2025-06-09

### 🚀 Features

- Allow for generic queries like _RUNTIME_SCOPE=system

### 📚 Documentation

- Commenting in literate style (part 3)

## [0.9.2] - 2025-06-07

### 🚜 Refactor

- Implemented generic BakedFileHandler
- Nicer method check
- Reorg code a bit
- Use standalone baked_file_handler

### 📚 Documentation

- Add AUR mention
- Start publishing crycco output
- Commenting in literate style (part 1)
- Commenting in literate style (part 2)
- More literate output
- Commit site to repo
- More installation instructions
- Add curl|bash mechanism to install
- More literate output

## [0.9.1] - 2025-06-02

### 🐛 Bug Fixes

- Make fake server support hostname filtering

### 💼 Other

- Release v0.9.1

### 📚 Documentation

- Example service file

### 🎨 Styling

- Fix theme switch
- Start with filters open

## [0.9.0] - 2025-06-02

### 🚀 Features

- Filter by unit when clicking on a unit name in a log entry.
- Support multi-host logs concentrated via journald
- Control column visibility
- Auto-filtering when clicking on a hostname

### 🐛 Bug Fixes

- Use minified files
- Use -m flag when calling journalctl

### 💼 Other

- Added Makefile
- Better watch target respecting minify
- Release v0.9.0

### 🚜 Refactor

- Removed dead HTML and CSS
- Moved assets into separate folder

### 📚 Documentation

- Add test badge
- Update README.md

### 🎨 Styling

- New favicon
- Use grouped buttons
- Make 'advanced' filters section collapsable
- Fix word wrapping in message cells
- Fix word wrapping in unit cells

### 🧪 Testing

- Fix tests

## [0.8.2] - 2025-06-01

### 🐛 Bug Fixes

- Use actual icons instead of emoji
- Show sorting indicator more consistently

### 💼 Other

- Release v0.8.2

### 🎨 Styling

- No more emoji class/font
- More compact rows in log table
- Error messages are now a dialog for better ux
- Integrate message counter in table heading

## [0.8.1] - 2025-06-01

### 🐛 Bug Fixes

- Embed all functional dependencies (htmx/pico.css)
- Use chivo fonts
- Avoid a redirect
- Avoid chrome complaint

### 💼 Other

- Release v0.8.1

### 🎨 Styling

- Footer tweaks

## [0.8.0] - 2025-05-30

### 🚀 Features

- Basic auth support

### 🐛 Bug Fixes

- Make link useful in unsafe connections
- Update the URL whenever a filter changes so it matches the set filters

### 💼 Other

- Release v0.8.0

## [0.7.0] - 2025-05-30

### 🚀 Features

- Highlight central line in context view
- Client-side network error handling

### 🐛 Bug Fixes

- Some table headers were double-quoted

### 💼 Other

- Slightly faster
- Release v0.7.0

### 🚜 Refactor

- Remove unused unit_filter_active parameter
- Simpler code

### 🧪 Testing

- Unit tests for fake data generator

## [0.6.0] - 2025-05-29

### 🚀 Features

- Implemented fake mode

### 🐛 Bug Fixes

- Don't escape things twice
- Support grep in the demo server

### 💼 Other

- Build demo server for ... demo purposes
- Release v0.6.0

### 🚜 Refactor

- Use html_build for table generation
- Use html_build for service completion
- Use html_build for details endpoint

### 📚 Documentation

- Link to demo site

### 🎨 Styling

- Only show actions on row hover

## [0.5.0] - 2025-05-29

### 🚀 Features

- Download logs
- Website
- Show container name in log entries when available
- Detail view
- Context view

### 🐛 Bug Fixes

- Pretty json for detail view

### 💼 Other

- Release v0.4.0
- Release v0.4.0
- Update static build to alpine edge
- Release v0.5.0

### 🚜 Refactor

- Keep all data in LogEntry.@data
- Move helpers to separate file
- Helpers cleanup
- Minor fix
- Simplify common code
- Removed useless comments

### 📚 Documentation

- Added systemd help
- Updated README.md
- Update README.md

### 🎨 Styling

- Use mono emoji
- Use mono emoji
- Consistent spacing in sidebar

### 🧪 Testing

- Unit tests for timeline
- Unit tests for LogEntry
- Unit tests for build_query_command
- Unit tests for journalctl
- Unit tests for plain text logs

## [0.3.0] - 2025-05-27

### 🚀 Features

- Highlight search term
- Clear filters button
- Light/dark theme switcher

### 🐛 Bug Fixes

- Command to run from source was wrong
- More robust static files

### 💼 Other

- Release v0.3.0

### 🚜 Refactor

- Optional param helper
- Simpler HTML/CSS/JS
- Simpler SVG chart generation
- Inline CSS into a class

### 🎨 Styling

- Handle collapsing better
- Alignment and borders
- Collapse button margin
- Tweak priority colors

## [0.2.0] - 2025-05-27

### 🚀 Features

- Nicer chart, more informative
- Nicer styling
- More functional layout

### 🐛 Bug Fixes

- Disable copy URL button in insecure contexts
- Simpler code
- Refactor CSS
- Better links

### 🚜 Refactor

- Simpler code
- Use stdlib's mime

### 🎨 Styling

- Brighter priority colors, removed some comments
- Padding tweaks

## [0.1.1] - 2025-05-26

### 🚀 Features

- Multiple units, positive and negative tags

### 💼 Other

- Pre-commit hooks
- Preparing cliff config
- Release v0.1.0
- Release v0.1.0
- Release v0.1.0
- Release v0.1.1

<!-- generated by git-cliff -->

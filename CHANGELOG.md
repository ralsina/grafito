# Changelog

All notable changes to this project will be documented in this file.

## [1.2.0] - 2026-09-16

### 🚀 Features

- *(dashboard)* Server dashboard with metrics history, unit actions and gotify alerts
- *(dashboard)* Sortable unit table columns
- *(ui)* Dashboard button first in topbar, unit column rightmost
- *(ui)* Hide log chrome while the dashboard is shown
- *(dashboard)* Service filter and configurable time window
- *(ui)* Time selector on the timeline, filter in the services title
- *(ui)* Dashboard service filter moves to the topbar omnibox
- *(dashboard)* Service filter matches all displayed columns
- *(ui)* Services count joins the stats strip
- *(dashboard)* State/sub pills and left state stripes like the log view
- *(dashboard)* Service detail panel in the sidebar
- *(dashboard)* Services minimap in the minimap rail
- *(dashboard)* Full unit actions with contextual panel buttons
- *(ui)* Icon-only panel actions matching the table's action cells
- *(actions)* Require authentication before unit actions can be enabled
- *(dashboard)* Contextual unit actions in the table
- *(dashboard)* Hide actions systemd says cannot start (CanStart)
- *(dashboard)* AI "Explain this unit" in the service panel
- *(dashboard)* Feed systemctl status output to the unit AI explanation
- *(dashboard)* Overlay error frequency on the history chart
- *(logs)* Overlay memory and load on the frequency timeline
- *(dashboard)* Combined severity + resource usage chart
- *(demo)* Living metrics for the fake dashboard
- *(logs)* Use the combined severity + resource chart in the log view
- *(compose)* Add a Docker Compose view as a third mode
- Add htop-style process monitor view (merge branch 'process-monitor')
- *(processes)* Htop-style process monitor view
- *(processes)* Detail panel with signals, logs and AI integration
- *(ui)* Loading overlay while a view's fragment is on its way
- *(processes)* Combo chart and square per-core load cells
- *(processes)* Show the machine total as a 2x2 leading cell
- *(ui)* Minimap viewport window
- *(compose)* Two-column stack layout on wide viewports
- *(homepage)* Self-hosted app launcher view with weather widget
- *(security)* Warn on non-loopback actions bind; docs housekeeping
- *(assets)* Self-host marked and the Material Icons font
- *(security)* Reject cross-site state-changing POSTs (CSRF)
- *(logs)* SSE live tail for the log stream
- *(ai)* Built-in ChatJimmy provider (flag-gated)
- *(compose)* Runtipi-compatible app store
- Merge Runtipi-compatible app store (branch feat/app-store)
- *(web)* Serve an llms.txt from the baked assets
- *(demo)* Simulate every action so the demo is fully interactive

### 🐛 Bug Fixes

- *(ui)* Dashboard toggle shows the view it switches to
- *(ui)* Reload restores the dashboard view
- *(ui)* Hide Context/AI tabs while the sidebar shows a service
- *(ui)* Close the sidebar when jumping to logs from the service panel
- *(ui)* Monochrome icon style for dashboard action buttons
- *(dashboard)* Clip long unit names and descriptions with ellipsis
- *(dashboard)* Emit hyphenated htmx attributes on the explain button
- *(ui)* Use the pencil logo as the brand mark
- *(dashboard)* Render the error overlay as bars, not an area
- *(ui)* Brighten the log timeline bars
- *(dashboard)* Readable time axis labels on the combined chart
- *(ui)* Keep the URL in sync when leaving the dashboard
- *(ci)* Dashboard specs and unit status without systemctl
- *(processes)* Resolve user names from the correct passwd field
- *(processes)* Keep command cells to one truncated line
- *(processes)* Style the process filter box like the other omniboxes
- *(ui)* Keep the view switcher at content width
- *(ui)* Restore the dashboard and process filter boxes
- *(processes)* Don't count the aggregate cpu line as a core
- *(processes)* Make the total square an actual 2x2
- *(processes)* Give the count line room on the left
- *(ui)* Hide the minimap rail on views without one
- *(processes)* Stop stretching the combo chart
- *(ui)* Wrap empty-state cells in table rows
- *(docker)* Clean apt cache after install, in the same layer
- *(gotify)* Bound the notification request with timeouts
- *(security)* Sanitize AI markdown before rendering
- *(processes)* Don't hold the chart cache lock across journalctl I/O
- *(compose)* Never evict a running job while finished ones exist
- *(a11y)* Resolve Lighthouse accessibility findings; trim to two webfonts
- *(demo)* Fake live tail, coherent cursor lookups, demo disclaimer

### 🚜 Refactor

- *(actions)* Drop the --units action whitelist, trust systemd
- *(timeline)* Shared combined chart, log-view metrics overlay
- *(processes)* Compact per-core CPU meters
- *(ui)* Compact 4-way view switch in the topbar
- *(ui)* Icon-only view switcher
- *(ui)* Fold the brand into the view switcher cartouche
- Each view owns its routes and frontend wiring
- *(ui)* Keep only the Mission Control look
- *(ui)* Split the frontend monolith into modules
- *(ai)* Single priority bucket, alternating roles, spec coverage

### 📚 Documentation

- Refresh CLAUDE.md and regenerate the generated site
- *(cli)* --data-dir is also the app store root now
- Reflect current capabilities across all docs

### ⚡ Performance

- *(processes)* Read /etc/passwd once per snapshot, not per process
- *(processes)* Cap rows, poll slower, morph instead of rebuild
- *(logs)* Stream-parse journalctl output line by line

### 🎨 Styling

- *(dashboard)* Dashed stroke for the disk usage line
- *(dashboard)* Left margin for the chart legend

### 🧪 Testing

- Run the fake-journal suite in automation

## [1.1.1] - 2026-09-12

### 🚀 Features

- *(ui)* Tags column with sortable header and click-to-filter

### 💼 Other

- Release v1.1.1

## [1.1.0] - 2026-09-12

### 🚀 Features

- *(ui)* Active filter chips for unit, tag and hostname filters
- *(ui)* Filter chips as tokens inside the search omnibox
- *(ui)* Interpret key:value tokens typed in the search box
- *(deploy)* Containerized real grafito stack with jimmy AI proxy
- *(ui)* Copy log entries and detail data to the clipboard

### 🐛 Bug Fixes

- *(deploy)* Add AI provider name label to demo compose
- *(ui)* Live toggle polls with full filters and refreshes immediately
- *(ui)* Refetch immediately when removing a filter chip

### 💼 Other

- Release v1.1.0

## [1.0.1] - 2026-09-11

### 🚀 Features

- *(ui)* Command dialog with copy button, htmx minified

### 🐛 Bug Fixes

- *(deploy)* Share the network namespace between demo and jimmy
- *(deploy)* Reference the grafito service (not container name) in network_mode
- *(ui)* Fire the first log load after htmx initializes
- *(demo)* Generate unique cursors for fake context entries
- *(demo)* Pin the context target cursor after fake regeneration

### 💼 Other

- Release v1.0.1

### 📚 Documentation

- Update README for the redesigned UI and AI features

### ⚡ Performance

- *(ui)* Gzip responses, minified htmx, deferred scripts, less CLS, a11y

## [1.0.0] - 2026-09-11

### 🚀 Features

- Add --user flag for user systemd mode support
- Show HTTP errors from htmx requests instead of failing silently
- Redo marketing site with retrofuturistic CRT cockpit look
- *(timeline)* Adaptive severity-stacked chart with clickable buckets
- *(ai)* Iterative refinement with conversation history
- *(ui)* Three-mode redesign with inspector side panel
- *(server)* Cache headers, root redirect, sorted details, AI routing
- *(ai)* Allow labeling endpoint-only providers

### 🐛 Bug Fixes

- Respect --log-level and validate the port argument
- Escape entry cursor in AI explanation button onclick
- Resolve conflicts with socket activation PR and satisfy linter
- *(ui)* Keep statusbar and AI reply box inside the mobile viewport
- *(deploy)* Recreate the whole demo stack to keep container DNS intact

### 💼 Other

- Release v0.17.0
- Append trailing newline when minifying assets
- *(deploy)* Run the demo site as a compose stack with jimmy-proxy
- *(deps)* Update kemal to 1.13 and use its handler API
- Release v1.0.0

### 🚜 Refactor

- Deduplicate user-mode flags and simplify unit filtering
- *(ui)* Readable stylesheet, dead-rule cleanup, robust details fetch
- *(ai)* Use Time.instant instead of deprecated Time.monotonic

### 📚 Documentation

- Enhance CLAUDE.md and fix install.sh to use latest release

### 🧪 Testing

- Add route-level and HTML output specs

## [0.16.3] - 2025-12-30

### 🐛 Bug Fixes

- Use build_url helper in HTML to avoid double slashes
- Use buildUrl helper in JavaScript to avoid protocol-relative URLs

### 💼 Other

- Release v0.16.3

## [0.16.2] - 2025-12-28

### 🐛 Bug Fixes

- Handle base path "/" correctly to avoid double slashes

### 💼 Other

- Release v0.16.2

## [0.16.1] - 2025-12-28

### 🐛 Bug Fixes

- Use correct mount_path parameter for BakedFileHandler

### 💼 Other

- Release v0.16.1

## [0.16.0] - 2025-12-28

### 🚀 Features

- Add configurable base path for flexible deployment

### 💼 Other

- Release v0.16.0

## [0.15.0] - 2025-12-28

### 🚀 Features

- Add multi-provider AI log analysis with dynamic prompts
- Add model switching with dropdown UI and curated model lists per provider
- Migrate to docopt-config for enhanced configuration

### 🐛 Bug Fixes

- Remove dead code for unused ai-current-provider element
- Add error handling for malformed ai API responses
- Remove redundant empty body check in /ask-ai endpoint
- Prevent XSS in AI response error handling
- Use to_s instead of as(String) for type flexibility
- Handle timezone edge cases (/UTC, Etc/UTC) in Docker
- Properly configure timezone in Docker image

### 💼 Other

- Release v0.15.0

### 🚜 Refactor

- *(ai)* Fix lint issues, reduce complexity, add constants for DRY, improve test coverage
- Replace internal BakedFileHandler with external library

### 📚 Documentation

- Update README.md [skip ci]
- Create .all-contributorsrc [skip ci]

### 🎨 Styling

- Fix ameba lint issues in AI module

### 🧪 Testing

- Add provider specs with webmock

## [0.14.1] - 2025-12-17

### 🚀 Features

- Add configurable timezone support

### 🐛 Bug Fixes

- Crash on startup because of timezone

### 💼 Other

- Release v0.14.1

### 📚 Documentation

- Fix doc build

## [0.13.0] - 2025-11-05

### 🚀 Features

- AI-powered log analysis

### 💼 Other

- Release v0.13.0

## [0.12.1] - 2025-10-27

### 📚 Documentation

- Site

## [0.12.0] - 2025-09-19

### 🚀 Features

- Configurable log level

### 💼 Other

- Release v0.12.0

## [0.11.0] - 2025-09-19

### 🚀 Features

- Add command line option to restrict access to specific systemd units

## [0.10.2] - 2025-07-07

### 💼 Other

- Release v0.10.2

### 📚 Documentation

- Updated website
- Updated site

### 🎨 Styling

- UI fix

## [0.10.1] - 2025-07-02

### 💼 Other

- Release v0.10.1

### 📚 Documentation

- Updated website

## [0.10.0] - 2025-07-02

### 🚀 Features

- Allow for generic queries like _RUNTIME_SCOPE=system

### 💼 Other

- Add docker labels
- Release v0.10.0

### 📚 Documentation

- Commenting in literate style (part 3)
- Docker support

### 🧪 Testing

- Fix off-by-one in unit test

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

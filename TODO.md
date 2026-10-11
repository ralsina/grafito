# Things To Do

* Point-a-script-at-a-server bootstrap via krikri (docker + compose +
  vector + stacks). POC playbook ran green in `--check` against rocky.
  Gotchas: rocky is Debian 12 on arm64 (controller needs the arm64
  `plugins/` dir from the arm64 krikri tarball), Arch targets are not
  supported (no pacman module)
* Formalize API
* Write MCP
* ✅ Maybe add z.ai integration (the `z_ai` provider)
* ✅ Handle configurable URLs
* ✅ Authentication
* ✅ Better error handling (client side!)
* ✅ Docs
* ✅ Tests
* ✅ Site
* ✅ Select a nice color scheme using the nicolino base16-picocss theme generator
* ✅ Add CLI options to set the port and host etc.
* ✅ Implement "context": link an entry to unfiltered nearby entries.
* ✅ Implement "detail": show all the fields in a table for a specific entry
* ✅ Use <https://github.com/crystal-lang/html_builder> to build HTML
* ✅ Make it literate, push through crycco, produce nice site (`make website`)
* ✅ Replace emoji icons with actual icons (see <https://fonts.google.com/icons>)
* ✅ Use minified assets automatically
* ✅ Package for arch (with systemd service)
* ✅ Create install script
* ✅ Docker image (makes no sense to run this in a container, but why not)

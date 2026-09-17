require "baked_file_handler"
require "baked_file_system"

# ## The Assets class
#
# Bake all files from the src/assets directory into the binary.
# The keys in the baked FS will be like "/index.html" for "assets/index.html", etc.
#
# This is important because it's what allows distributing Grafito as a single binary
# without the need to ship a bunch of files alongside it.
#
# All the things that are needed to function are baked-in:
#
# * pico.css
# * htmx
# * index.html
# * style.css
# * robots.txt
# * llms.txt
#
# Fonts and the material icons font are baked too, so the app works
# fully offline.
class Assets
  extend BakedFileSystem
  bake_folder "./assets"
end

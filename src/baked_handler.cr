# # baked_handler.cr

require "baked_file_system"
require "kemal"

module Grafito
  # # BakedFileHandler
  #
  # `BakedFileHandler` is a specialized `HTTP::Handler` designed to serve
  # files embedded within the application binary using a `BakedFileSystem`
  # compatible class.
  #
  # It replaces standard filesystem lookups with lookups in the provided
  # baked assets class. This allows serving static content (HTML, CSS, JS,
  # images, etc.) directly from memory, making the application distributable
  # as a single binary without loose asset files.
  #
  # ## Features:
  # - Serves files from a `BakedFileSystem` class.
  # - Handles GET and HEAD requests.
  # - Optionally serves `index.html` for directory-like paths (e.g., `/admin/` serves `/admin/index.html`).
  # - Sets `Content-Type` based on file extension.
  # - Allows configuring `Cache-Control` headers.
  # - Fallthrough to the next handler if a file is not found or the method is not supported.
  #
  # ## Usage:
  #
  # ```
  # require "kemal"
  # require "baked_file_system"
  #
  # # Example BakedFileSystem class
  # class MyAssets
  #   extend BakedFileSystem
  #   bake_folder "./public_assets"
  # end
  #
  # # In your Kemal app:
  # baked_asset_handler = BakedFileHandler.new(
  #   MyAssets)
  # add_handler baked_asset_handler
  #
  # Kemal.run
  # ```
  #
  # When a request like `GET /css/style.css` is received, `BakedFileHandler`
  # will attempt to retrieve and serve the file associated with the key
  # `"/css/style.css"` from the `MyAssets` class.
  #
  # ## Caveats:
  # - Directory listing is not supported.
  # - File modification times and ETag based on `mtime` are not used for caching,
  #   as baked assets are immutable at runtime. Caching relies on `Cache-Control`.
  # - Range requests are not explicitly supported by this handler;
  #   the entire file content is served.

  class BakedFileHandler < Kemal::StaticFileHandler
    Log = ::Log.for(self)

    @baked_fs_class : BakedFileSystem
    @serve_index_html : Bool = true
    @cache_control : String? = "max-age=604800" # Default 1 week

    # Creates a new `BakedFileHandler`.
    #
    # Arguments:
    #   - `baked_fs_class`: The class object (e.g., `MyAssets`) that extends `BakedFileSystem`
    #     and contains the baked files.
    #   - `fallthrough`: If `true` (default), calls the next handler if a file is not found
    #     or if the request method is not GET or HEAD. (Passed to `super`)
    #   - `serve_index_html`: If `true` (default), attempts to serve `index.html` for
    #     requests to directory-like paths (e.g., `/admin/` serves `/admin/index.html`).
    #   - `cache_control`: Sets the `Cache-Control` header for successful responses.
    #     Defaults to "max-age=604800" (1 week). Set to `nil` to omit this header.
    def initialize(
      @baked_fs_class : BakedFileSystem,
      fallthrough = true,
      @serve_index_html = true,
      @cache_control = "max-age=604800",
    )
      # Call super with a dummy public_dir, as we override `call` and don't use parent's fs logic.
      # Parent's directory_listing is also made false as we don't support it.
      super("/", fallthrough, directory_listing: false)
    end

    # Overrides the main request handling method from `HTTP::StaticFileHandler`.
    # This implementation bypasses filesystem checks and serves directly from
    # the `BakedFileSystem`.
    def call(context : HTTP::Server::Context)
      request_path = context.request.path

      unless ["GET", "HEAD"].includes? context.request.method
        # Method not allowed
        if @fallthrough
          return call_next(context)
        else
          context.response.status = HTTP::Status::METHOD_NOT_ALLOWED # 405
          context.response.headers["Allow"] = "GET, HEAD"
          return
        end
      end
      baked_key = Path.posix(URI.decode(request_path)).relative_to("/").to_s

      # Attempt to serve the direct path
      if serve_baked_key(context, baked_key)
        return
      end

      # If direct path failed, and it's a "directory" path (ends with / or is "." for root),
      # and @serve_index_html is true, try serving an index.html file from that path.
      if @serve_index_html && (request_path.ends_with?('/') || request_path == ".")
        index_key = (baked_key == ".") ? "index.html" : Path.posix(baked_key).join("index.html").normalize.to_s
        if serve_baked_key(context, index_key)
          return
        end
      end

      # If nothing worked, fall through to the next handler.
      call_next(context)
    end

    # Helper to serve a file from BakedFileSystem using its key.
    private def serve_baked_key(context : HTTP::Server::Context, baked_key : String)
      Log.debug { "Attempting to serve baked key: '#{baked_key}' from #{@baked_fs_class}" }

      # Check for file existence in the BakedFileSystem first.
      unless @baked_fs_class.get?(baked_key)
        Log.debug { "Baked key not found: '#{baked_key}' in #{@baked_fs_class}" }
        return false # Not served, allow fallthrough
      end

      begin
        # Now that we know it exists, get it.
        io = @baked_fs_class.get(baked_key)
        extension = Path.new(baked_key).extension.to_s # .to_s handles nil if no extension
        context.response.content_type = MIME.from_extension(extension) || "application/octet-stream"
        @cache_control.try { |cc|
          context.response.headers["Cache-Control"] = cc
        }
        context.response.content_length = io.size
        # For GET requests, we copy the IO content to the response.
        if context.request.method == "GET"
          IO.copy(io, context.response)
        end
        # Served
        Log.debug { "Successfully served baked key: '#{baked_key}'" }
        true
      rescue ex
        # Catch errors during the actual serving process and
        # ensure a response is sent if not already closed, to prevent hanging
        Log.error(exception: ex) { "Error serving (already confirmed) baked key: '#{baked_key}'" }
        unless context.response.closed?
          begin
            context.response.status = :internal_server_error
            context.response.print "Error serving file."
          rescue error : IO::Error
            Log.warn(exception: error) { "Could not send full 500 error response for '#{baked_key}' (e.g., headers already sent or stream closed)." }
          end
        end
        # Consider this handled with an error, do not fallthrough
        true
      ensure
        # Ensure the IO is closed if it was opened (probably not needed)
        io.try &.close
      end
    end
  end
end

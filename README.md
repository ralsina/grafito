# grafito

Grafito is a simple, self-contained web-based log viewer for `journalctl`.
It provides an intuitive interface to browse and filter system logs directly from your web browser.

Key features include:

* Real-time log viewing (with an optional auto-refresh).
* Filtering by unit, tag, time range, and a general search query.
* A dynamic user interface powered by HTMX for a smooth experience.
* Embedded assets (HTML, favicon) for easy deployment as a single binary.
* Built with the Crystal programming language and the Kemal web framework.

![image](https://github.com/user-attachments/assets/be14d4c7-89f8-43f5-bbf1-4fd271275ff0)



## Installation

To install from prebuilt binaries, download the latest release from the [releases page](github.com/ralsina/grafito/releases). The binaries are available for linux, both x86_64 and arm64 architectures.

To install from source:

1. **Clone the repository:**

    ```bash
    git clone https://github.com/ralsina/grafito.git
    cd grafito
    ```

2. **Install Crystal dependencies:**

    ```bash
    shards install
    ```

3. **Build the application:**

    ```bash
    shards build --release
    ```

    This will create a single executable file named `bin/grafito`

## Usage

Simply run the compiled binary:

```bash
./bin/grafito
```

Then open your web browser and navigate to `http://localhost:3000` (or the port specified if configured differently).

The application requires `journalctl` and `systemctl` to be available on the system where it's run.

## Development

1. **Prerequisites:**
    * Ensure you have Crystal installed.
    * Ensure `journalctl` and `systemctl` are available on your development machine.

2. **Clone and Setup:**
    Follow the "Install from source" instructions above to clone the repository and install dependencies using `shards install`.

3. **Run for Development:**
    To run the application locally with automatic recompilation on changes, you can use a tool like Sentry.cr or simply recompile and run manually:

    ```bash
    crystal run src/grafito.cr
    ```

    The application will typically be available at `http://localhost:3000`.

4. **Linting:**
    This project uses Ameba for static code analysis. To run the linter:

    ```bash
    ./bin/ameba
    ```

## Contributing

1. Fork it (<https://github.com/ralsina/grafito/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Roberto Alsina](https://github.com/ralsina) - creator and maintainer

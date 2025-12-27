[![Crystal CI](https://github.com/ralsina/grafito/actions/workflows/crystal.yml/badge.svg)](https://github.com/ralsina/grafito/actions/workflows/crystal.yml)
<!-- ALL-CONTRIBUTORS-BADGE:START - Do not remove or modify this section -->
[![All Contributors](https://img.shields.io/badge/all_contributors-1-orange.svg?style=flat-square)](#contributors-)
<!-- ALL-CONTRIBUTORS-BADGE:END -->

# grafito

Grafito is a simple, self-contained web-based log viewer for `journalctl`.
It provides an intuitive interface to browse and filter system logs
directly from your web browser.

Key features include:

* Real-time log viewing (with an optional auto-refresh).
* Filtering by unit, tag, time range, and a general search query.
* **Configurable timezone support** - Display timestamps in your local timezone or any timezone you prefer.
* **AI-powered log explanations** - Get intelligent analysis of log errors using LLMs (requires API key).
* A dynamic user interface powered by HTMX for a smooth experience.
* Embedded assets (HTML, favicon) for easy deployment as a single binary.
* Built with the Crystal programming language and the Kemal web framework.

### AI Log Analysis

Grafito includes an optional AI feature that provides intelligent explanations for log entries. When configured, you'll see a psychology icon (🧠) next to each log entry that allows you to get AI-powered analysis.

**To enable AI features:**

1. **Get an API key** from [z.ai](https://z.ai) - they offer affordable LLM access with low costs.
2. **Set the environment variable** before running Grafito:
   ```bash
   export Z_AI_API_KEY="your_api_key_here"
   ./bin/grafito
   ```
3. **Or add it to your systemd service**:
   ```ini
   Environment="Z_AI_API_KEY=your_api_key_here"
   ```

The AI feature sends ±5 lines of log context around the selected entry to analyze patterns, suggest solutions, and explain complex errors. The feature is completely optional - Grafito works perfectly without it, and the AI button only appears when the API key is configured.

### Timezone Configuration

Grafito displays timestamps in your local timezone by default, but you can configure it to use any timezone you prefer. This solves the issue of having to mentally convert UTC timestamps to your local time.

**To configure timezone:**

1. **Command line option**:
   ```bash
   ./bin/grafito --timezone America/New_York
   ./bin/grafito --timezone Europe/London
   ./bin/grafito --timezone GMT+5
   ./bin/grafito --timezone local  # Default behavior
   ```

2. **Environment variable**:
   ```bash
   export GRAFITO_TIMEZONE="America/New_York"
   ./bin/grafito
   ```

3. **In systemd service**:
   ```ini
   Environment="GRAFITO_TIMEZONE=America/New_York"
   ```

**Supported timezone formats:**
- **IANA timezone names**: `America/New_York`, `Europe/London`, `Asia/Tokyo`, etc.
- **GMT offsets**: `GMT+5`, `GMT-3`, `GMT+5:30` (supports hours and minutes)
- **Special values**: `local` (system timezone), `utc` (UTC timezone)

By default, Grafito uses your system's local timezone, so most users won't need to configure anything unless they want to use a different timezone.

![image](https://github.com/user-attachments/assets/1042269f-3c34-46d3-ad45-c9a0ee250c82)

## Installation

If you are using Arch Linux grafito is [available in AUR](https://aur.archlinux.org/packages/grafito)

### Using the Install Script (Linux with systemd)

For a quick installation on Linux systems with systemd, you can use the provided installation script. This script will:

1. Download the correct Grafito binary for your system's architecture (amd64 or arm64) for the latest version tagged in the script.
2. Install it to `/usr/local/bin/grafito`.
3. Set up and enable a systemd service for Grafito.

To use the script, run the following command:

```bash
curl -sSL https://grafito.ralsina.me/install.sh | sudo bash
```

After installation, Grafito should be running and accessible at `http://<your_server_ip>:1111` (or the port configured in the service). You can check its status with `systemctl status grafito.service`.

### Prebuilt Binaries

To install from prebuilt binaries, download the latest release from the
[releases page](github.com/ralsina/grafito/releases). The binaries are
available for linux, both x86_64 and arm64 architectures. You can get an example
`grafito.service` [from the repository.](https://github.com/ralsina/grafito/blob/main/grafito.service)


### Install from source:

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

### Run using Docker

It doesn't make much sense to run Grafito in a container, but if you want to:

```bash
docker run -p 3000:3000 -v/var/log/journal:/var/log/journal ghcr.io/ralsina/grafito:latest
```

Or if you are using ARM:

```bash
docker run -p 3000:3000 -v/var/log/journal:/var/log/journal ghcr.io/ralsina/grafito-arm64:latest
```

## Usage

Simply run the compiled binary:

```bash
./bin/grafito
```

Then open your web browser and navigate to `http://localhost:3000`
(or the port specified if configured differently).

The application requires `journalctl` and `systemctl` to be
available on the system where it's run.

## Running with systemd

To run Grafito as a systemd service, you can create a service file.

1. **Create the service file:**

    Create a file named `grafito.service` in `/etc/systemd/system/` (or `~/.config/systemd/user/` for a user service) with the following content. Adjust paths and user/group as necessary.

    ```ini
    [Unit]
    Description=Grafito Log Viewer
    After=network.target

    [Service]
    Type=simple
    DynamicUser=yes
    # If set to "systemd-journal" it can access all logs in the system
    # Change if that is not what you want.
    Group=systemd-journal

    # --- Authentication Configuration ---
    # Set these environment variables to enable Basic Authentication.
    # If GRAFITO_AUTH_USER and GRAFITO_AUTH_PASS are not set, Grafito will run without authentication.
    Environment="GRAFITO_AUTH_USER=your_grafito_username"
    Environment="GRAFITO_AUTH_PASS=your_strong_grafito_password"

    # Replace with the actual path to your Grafito directory
    WorkingDirectory=/usr/local/bin/
    # Replace with the actual path and options to the Grafito binary
    ExecStart=/usr/local/bin/grafito -b 0.0.0.0 -p 1111
    Restart=on-failure

    [Install]
    WantedBy=multi-user.target
    ```

2. **Reload systemd daemon:**

   ```bash
   sudo systemctl daemon-reload
    ```

3. **Enable the service (to start on boot):**

   ```bash
   sudo systemctl enable grafito.service
   ```

4. **Start the service:**

   ```bash
   sudo systemctl start grafito.service
   ```

5. **Check the status:**

   ```bash
   sudo systemctl status grafito.service
   ```

## Journald Permissions

By default, `journalctl` (and therefore Grafito) can only access the logs of the user running the command. To allow Grafito to access all system logs, the user running the Grafito process needs to be part of a group that has permissions to read system-wide journal logs.

Typically, this is the `systemd-journal` group (the name might vary slightly depending on your Linux distribution).

1. **Add the user to the `systemd-journal` group:**
   Replace `your_user` with the actual username that will run the Grafito process.

   ```bash
   sudo usermod -a -G systemd-journal your_user
   ```

2. **Apply group changes:**
   The user will need to log out and log back in for the new group membership to take effect.
   If Grafito is already running as a service under this user, you might need to restart the
   service:

   ```bash
   sudo systemctl restart grafito.service
   ```

Alternatively, if you are running Grafito directly (not as a service) and want to grant
it temporary access for a session, you might run it with `sudo`, but this is generally
not recommended for web applications for security reasons. Configuring the user with
appropriate group membership is the preferred method.

**Security Note:** Granting access to all system logs means that any user who can access
Grafito will be able to see these logs. Ensure that Grafito itself is appropriately secured
if it's exposed to untrusted networks.

## Logs from multiple hosts

Systemd Journald offers mechanisms to centralize logs from multiple hosts onto a single machine. This is particularly useful for managing logs in a distributed environment. Two common tools for this are `systemd-journal-remote` and `systemd-journal-upload`.

* **`systemd-journal-upload`**: This service runs on client machines and uploads their local journal entries to a remote `systemd-journal-remote` instance. It can be configured to send logs securely over HTTPS.
* **`systemd-journal-remote`**: This service runs on a central log server and listens for incoming journal data (typically via HTTP/HTTPS) from `systemd-journal-upload` instances. It then stores these logs in the local journal on the central server.

When logs from multiple hosts are consolidated onto the server where Grafito is running, each log entry will typically retain its original `_HOSTNAME` field. This is where Grafito's **Hostname filter** becomes very useful.

By using the "Hostname" filter in the Grafito UI, you can easily isolate and view logs originating from a specific client machine, even though all logs are stored and queried on the central Grafito server. For example, if you have logs from `server1`, `server2`, and `web-node-alpha` all being sent to your Grafito host, you can simply type `server1` into the Hostname filter to see only its logs.

### Configuration Sketch

1. **On the Central Log Server (where Grafito runs):**
   * Install and configure `systemd-journal-remote` to listen for incoming logs. You'll typically configure it to use HTTPS for security.
   * Ensure the journal on this server has enough storage space.

2. **On Each Client Host:**
   * Install and configure `systemd-journal-upload`.
   * Point it to the address and port of your central `systemd-journal-remote` instance.
   * Configure necessary authentication (e.g., client certificates) if HTTPS is used.

Once set up, logs from all client hosts will appear in Grafito on the central server, and you can use the Hostname filter to distinguish between them. Refer to the official systemd documentation for detailed instructions on configuring `systemd-journal-remote` and `systemd-journal-upload`.

## Development

1. **Prerequisites:**
   * Ensure you have Crystal installed.
   * Ensure `journalctl` and `systemctl` are available on your development machine.

2. **Clone and Setup:**
   Follow the "Install from source" instructions above to clone the repository and
   install dependencies using `shards install`.

3. **Run for Development:**
   To run the application locally with automatic recompilation on changes, you can
   use a tool like Sentry.cr or simply recompile and run manually:

   ```bash
   shards run grafito
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

* [Roberto Alsina](https://github.com/ralsina) - creator and maintainer
<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->
<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="14.28%"><a href="http://omaralani.dev"><img src="https://avatars.githubusercontent.com/u/84993125?v=4?s=100" width="100px;" alt="Omar Alani"/><br /><sub><b>Omar Alani</b></sub></a><br /><a href="https://github.com/ralsina/grafito/commits?author=omarluq" title="Code">💻</a></td>
    </tr>
  </tbody>
</table>

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->

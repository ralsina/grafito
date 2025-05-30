# grafito

Grafito is a simple, self-contained web-based log viewer for `journalctl`.
It provides an intuitive interface to browse and filter system logs
directly from your web browser.

Key features include:

* Real-time log viewing (with an optional auto-refresh).
* Filtering by unit, tag, time range, and a general search query.
* A dynamic user interface powered by HTMX for a smooth experience.
* Embedded assets (HTML, favicon) for easy deployment as a single binary.
* Built with the Crystal programming language and the Kemal web framework.

![image](https://github.com/user-attachments/assets/c02eb73a-0928-4428-9662-4080d9b43d02)


## Installation

To install from prebuilt binaries, download the latest release from the
[releases page](github.com/ralsina/grafito/releases). The binaries are
available for linux, both x86_64 and arm64 architectures.

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

Then open your web browser and navigate to `http://localhost:3000`
(or the port specified if configured differently).

The application requires `journalctl` and `systemctl` to be
available on the system where it's run.

## Running with systemd

To run Grafito as a systemd service, you can create a service file.

1.  **Create the service file:**

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

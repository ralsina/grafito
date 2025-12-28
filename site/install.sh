#!/bin/bash
set -euo pipefail

# --- Configuration ---
REPO="ralsina/grafito"
INSTALL_DIR="/usr/local/bin"
SERVICE_DIR="/etc/systemd/system"
SERVICE_NAME="grafito.service"
BINARY_NAME="grafito"
VERSION="0.16.0" # Hardcoded version
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "${TEMP_DIR}"' EXIT ERR INT TERM # Ensure cleanup

# --- Helper Functions ---

# Check if required commands are available
check_dependencies() {
    local deps=("curl" "tar" "systemctl") # Removed jq
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo "Error: Required dependency '$dep' is not installed." >&2
            echo "Please install it (e.g., sudo apt-get install $dep or sudo yum install $dep) and run the script again." >&2
            exit 1
        fi
    done
}

# Determine system architecture and map to Grafito asset name
get_architecture() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)
            echo "amd64"
            ;;
        aarch64)
            echo "arm64"
            ;;
        *)
            echo "Error: Unsupported architecture '$arch'." >&2
            echo "This script currently supports x86_64 (amd64) and aarch64 (arm64)." >&2
            exit 1
            ;;
    esac
}

# --- Main Installation Logic ---

echo "Starting Grafito installation..."

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root." >&2
   exit 1
fi

# Check for required tools
check_dependencies

# Get system architecture
ARCH=$(get_architecture)
echo "Detected architecture: ${ARCH}"

# Construct download URL for the hardcoded version
echo "Using Grafito version: ${VERSION}"
ASSET_NAME="${BINARY_NAME}-static-linux-${ARCH}" # Asset name based on architecture
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/v${VERSION}/${ASSET_NAME}"

echo "Target asset name: ${ASSET_NAME}"
echo "Constructed download URL: ${DOWNLOAD_URL}"

# Download the asset
echo "Downloading Grafito binary..."
DOWNLOAD_PATH="${TEMP_DIR}/${ASSET_NAME}"
if ! curl -L -o "${DOWNLOAD_PATH}" "${DOWNLOAD_URL}"; then
    echo "Error: Failed to download the asset from ${DOWNLOAD_URL}." >&2
    echo "Please ensure version ${VERSION} and asset ${ASSET_NAME} exist at ${REPO} releases." >&2
    exit 1
fi

echo "Binary downloaded."

# Install the binary to the target directory
echo "Installing binary to ${INSTALL_DIR}/${BINARY_NAME}..."
if ! mv "${DOWNLOAD_PATH}" "${INSTALL_DIR}/${BINARY_NAME}"; then
    echo "Error: Failed to move the binary to the installation directory." >&2
    exit 1
fi
if ! chmod +x "${INSTALL_DIR}/${BINARY_NAME}"; then
    echo "Error: Failed to make the binary executable." >&2
    exit 1
fi

echo "Grafito binary installed successfully."

# Install the systemd service file
echo "Installing systemd service file to ${SERVICE_DIR}/${SERVICE_NAME}..."

# Create the service file using a heredoc, embedding the content from the template
cat <<EOF > "${SERVICE_DIR}/${SERVICE_NAME}"
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
# Environment="GRAFITO_AUTH_USER=your_grafito_username"
# Environment="GRAFITO_AUTH_PASS=your_strong_grafito_password"

# Replace with the actual path to your Grafito directory
WorkingDirectory=${INSTALL_DIR}/
# Replace with the actual path and options to the Grafito binary
ExecStart=${INSTALL_DIR}/${BINARY_NAME} -b 0.0.0.0 -p 1111
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Verify service file creation
if [[ ! -f "${SERVICE_DIR}/${SERVICE_NAME}" ]]; then
    echo "Error: Failed to create the service file." >&2
    exit 1
fi

echo "Systemd service file created."

# Reload systemd daemon, enable and start the service
echo "Reloading systemd daemon..."
if ! systemctl daemon-reload; then
    echo "Error: Failed to reload systemd daemon." >&2
    exit 1
fi

echo "Enabling Grafito service to start on boot..."
if ! systemctl enable "${SERVICE_NAME}"; then
    echo "Error: Failed to enable Grafito service." >&2
    exit 1
fi

echo "Starting Grafito service..."
if ! systemctl start "${SERVICE_NAME}"; then
    echo "Error: Failed to start Grafito service." >&2
    exit 1
fi

echo ""
echo "--- Grafito Installation Complete ---"
echo "Grafito binary installed to: ${INSTALL_DIR}/${BINARY_NAME}"
echo "Systemd service file created at: ${SERVICE_DIR}/${SERVICE_NAME}"
echo ""
echo "--- Next Steps ---"
echo "1. Check the service status: systemctl status grafito.service"
echo "2. Configure authentication (optional but recommended):"
echo "   Edit the service file: sudo nano ${SERVICE_DIR}/${SERVICE_NAME}"
echo "   Uncomment and set GRAFITO_AUTH_USER and GRAFITO_AUTH_PASS."
echo "   After editing, run: sudo systemctl daemon-reload && sudo systemctl restart grafito.service"
echo "3. Access Grafito at http://<your_server_ip>:1111"

# Clean up temporary directory
# Cleanup is now handled by the trap
echo "Temporary files will be cleaned up automatically."

exit 0

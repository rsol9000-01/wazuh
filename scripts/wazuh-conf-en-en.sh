#!/bin/sh
# ---------------------------------------------------------------------------
# Prepare the Wazuh agent configuration after installation
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Stop execution on errors or undefined variables
# ---------------------------------------------------------------------------
set -eu

# ---------------------------------------------------------------------------
# Set the permissions on the authentication file if it is mounted
# ---------------------------------------------------------------------------
if [ -f /var/ossec/etc/authd.pass ]; then
    chown root:wazuh /var/ossec/etc/authd.pass
    chmod 640 /var/ossec/etc/authd.pass
    echo "🔐 authd.pass permissions updated."
fi

# ---------------------------------------------------------------------------
# Install docker-listener dependencies only when needed
# ---------------------------------------------------------------------------
#if ! python3 -c "import docker" >/dev/null 2>&1; then
#    echo "📦 Installing Python dependencies for docker-listener..."
#    dnf install -y python3-pip
#    pip3 install docker==7.1.0 urllib3==1.26.20 requests==2.32.2
#    echo "✅ docker-listener dependencies installed."
#else
#    echo "✅ docker-listener dependencies are already present; skipping installation."
#fi

# ---------------------------------------------------------------------------
# Hand control over to the agent image's original entry point
# ---------------------------------------------------------------------------
exec /init "$@"
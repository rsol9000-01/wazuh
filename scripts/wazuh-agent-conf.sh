#!/bin/sh
# ---------------------------------------------------------------------------
# Configure the Wazuh agent after the container starts
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Stop execution on errors or undefined variables
# ---------------------------------------------------------------------------
set -eu

# ---------------------------------------------------------------------------
# Install the version-controlled declarative configuration from the repository
# ---------------------------------------------------------------------------
cp /opt/ossec.conf.tpl /var/ossec/etc/ossec.conf
chown root:wazuh /var/ossec/etc/ossec.conf
chmod 640 /var/ossec/etc/ossec.conf

# ---------------------------------------------------------------------------
# Set up the enrollment password only if the agent has not enrolled yet
# ---------------------------------------------------------------------------
if [ ! -s /var/ossec/etc/client.keys ]; then
    echo "🔑 client.keys not found: starting agent enrollment."
    cp /opt/authd.pass /var/ossec/etc/authd.pass
    chown root:wazuh /var/ossec/etc/authd.pass
    chmod 640 /var/ossec/etc/authd.pass
    echo "🔐 authd.pass permissions updated."
else
    echo "✅ client.keys found: skipping enrollment."
    rm -f /var/ossec/etc/authd.pass
fi

# ---------------------------------------------------------------------------
# Get the manager address from an argument or the environment
# ---------------------------------------------------------------------------
if [ -n "${1:-}" ]; then
    MANAGER="$1"
    shift
else
    MANAGER="${WAZUH_MANAGER_SERVER:-}"
fi

if [ -n "$MANAGER" ]; then
    echo "Wazuh manager server: ${MANAGER}"
    sed -i "/<server>/,/<\/server>/ s|<address>.*</address>|<address>${MANAGER}</address>|" \
        /var/ossec/etc/ossec.conf
fi

# ---------------------------------------------------------------------------
# Configure the enrollment group when one is defined
# ---------------------------------------------------------------------------
if [ -n "${WAZUH_AGENT_GROUP:-}" ]; then
    echo "Enrollment group: ${WAZUH_AGENT_GROUP}"
    sed -i "/<enrollment>/,/<\/enrollment>/ s|<groups>.*</groups>|<groups>${WAZUH_AGENT_GROUP}</groups>|" \
        /var/ossec/etc/ossec.conf
fi

# ---------------------------------------------------------------------------
# Configure the agent name during enrollment
# With network_mode: host, set it explicitly in <enrollment> because
# Compose cannot assign the container's host name.
# ---------------------------------------------------------------------------
if [ -n "${WAZUH_AGENT_NAME:-}" ]; then
    echo "Agent name: ${WAZUH_AGENT_NAME}"
    sed -i "/<enrollment>/,/<\/enrollment>/ s|<enabled>yes</enabled>|&\n      <agent_name>${WAZUH_AGENT_NAME}</agent_name>|" \
        /var/ossec/etc/ossec.conf
fi

# ---------------------------------------------------------------------------
# Build the SCA (CIS) policies for the host
# The official policies would evaluate this container. sca_host.py rewrites
# the one of the host operating system (from /host/etc/os-release) to read
# /host and to run its commands in the host namespaces. If anything fails,
# SCA is turned off so no misleading report is sent.
# ---------------------------------------------------------------------------
SCA_DIR=/var/ossec/etc/sca-host
rm -rf "$SCA_DIR"
if [ -d /host/etc ] && [ -d /opt/sca-src ] && python3 /opt/sca_host.py /opt/sca-src "$SCA_DIR"; then
    POLICIES=""
    for f in "$SCA_DIR"/*_host.yml; do
        POLICIES="${POLICIES}<policy>etc/sca-host/$(basename "$f")</policy>"
    done
    for f in /var/ossec/ruleset/sca/*.yml; do
        [ -e "$f" ] && POLICIES="${POLICIES}<policy enabled=\"no\">ruleset/sca/$(basename "$f")</policy>"
    done
    chown -R root:wazuh "$SCA_DIR"
    chmod 750 "$SCA_DIR"
    chmod 640 "$SCA_DIR"/*.yml
    sed -i "s|<!-- SCA_HOST_POLICIES -->|${POLICIES}|" /var/ossec/etc/ossec.conf
    echo "SCA: host policies enabled."
else
    sed -i "/<sca>/,/<\/sca>/ s|<enabled>yes</enabled>|<enabled>no</enabled>|" /var/ossec/etc/ossec.conf
    echo "SCA: host view not available (/host or /opt/sca-src missing). SCA disabled."
fi

# ---------------------------------------------------------------------------
# Hand control over to the image's original entry point
# ---------------------------------------------------------------------------
exec /init "$@"
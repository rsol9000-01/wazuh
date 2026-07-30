#!/bin/sh
##########################################################################################
###### Script post-install for wazuh, executed by the wazuh-agents           #############
##########################################################################################

#──── Exit on error, e=exit on error, u=exit on undefined var ──────────
set -eu

# Set permissions for the mounted authd.pass file
if [ -f /var/ossec/etc/authd.pass ]; then
    chown root:wazuh /var/ossec/etc/authd.pass
    chmod 640 /var/ossec/etc/authd.pass
    echo "🔐 Permisos de authd.pass ajustados."
fi

# Install docker-listener dependencies only if missing (avoids reinstalling on each restart)
#if ! python3 -c "import docker" >/dev/null 2>&1; then
#    echo "📦 Installing Python dependencies for docker-listener..."
#    dnf install -y python3-pip
#    pip3 install docker==7.1.0 urllib3==1.26.20 requests==2.32.2
#    echo "✅ Docker-listener dependencies installed."
#else
#    echo "✅ Docker-listener dependencies already present, skipping installation."
#fi

if [ -n "$1" ]; then
    echo "Wazuh manager server: $1"
    cp /var/ossec/etc/ossec.conf /tmp/ossec.conf
    sed -i "/<server>/,/<\/server>/ s|<address>.*</address>|<address>${1}</address>|" \
    /tmp/ossec.conf
    cat /tmp/ossec.conf > /var/ossec/etc/ossec.conf
    rm /tmp/ossec.conf
    shift
fi
# Execute the original entrypoint of the agent image
exec /init "$@"

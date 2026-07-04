#!/usr/bin/env bash
########################################################################################################################
###### Script post-install for wazuh, executed by the wazuh-init service, defined in docker-compose.yml #############
########################################################################################################################


#──── Exit on error, e=exit on error, u=exit on undefined var ──────────
set -eu
#──── Flag to determine if a new user should be created with API_WEB_USER and API_WEB_PASS from .env *** DO NOT CHANGE THE VALUE *** ─────
flag_new_user=FALSE


#----- PSK file inside the container, used to read the PSK value and configure API autoregistration settings
#PSK_VALUE=$(cat /zabbix_agentd.psk)


#############################################################################################################
#######################################    0. IS API AVAILABLE?   ###########################################
#############################################################################################################
#API_URL
COUNT=0
MAX_RETRIES=5

echo "⏳ Waiting for Wazuh API to be available..."

until curl -k -s -o /dev/null \
  -w "%{http_code}" \
  -X POST "${API_URL}/security/user/authenticate?raw=true" \
  | grep -qE '200|401'; do

  COUNT=$((COUNT + 1))

  if [ "$COUNT" -ge "$MAX_RETRIES" ]; then
    echo "❌ Wazuh API not available after $MAX_RETRIES attempts, exiting..."
    exit 1
  fi

  echo "⏳ Attempt $COUNT/$MAX_RETRIES — retrying in 5 seconds..."
  sleep 5
done

echo "✅ Wazuh API available"

#############################################################################################################
##########################################    1. AUTHENTICATE   #############################################
#############################################################################################################

# ── 1.1. Authenticating as default ─────────────────────────────────
echo "🔒 Authenticating with default user..."
TOKEN=$(curl -k -s -u "${API_USERNAME}:${API_PASSWORD}" \
  -X POST "${API_URL}/security/user/authenticate?raw=true")

# ── 1.2. Authenticating as '$API_WEB_USER' ─────────────────────────────────
if [ -z "$TOKEN" ]; then
  echo "⚠️ Authentication failed with default user, trying with user '$API_NEW_USER'..."

  TOKEN=$(curl -k -s -u "${API_NEW_USER}:${API_NEW_PASS}" \
    -X POST "${API_URL}/security/user/authenticate?raw=true")

  if [ -z "$TOKEN" ]; then
    echo "❌ Could not authenticate with any user, exiting..."
    exit 1
  fi
  echo "   - 🔑 Authenticated with .env user: $API_NEW_USER"
else
  echo "   - 🔑 Authenticated with default user: $API_USERNAME"
  flag_new_user=TRUE
fi

echo "   - 🔑 Token obtained successfully"








#!/usr/bin/env bash
# Wazuh-dev.sh - development helper for Wazuh docker-compose (server or agent)
# Styled to match zabbix-dev.sh (colors, icons, menu) — English version

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# -------------- Script usage instructions
usage() {

  echo ""
  echo -e "⚠️  ${YELLOW}Usage:${NC} $0 [server|agent] [action]"
  echo ""
  echo -e "    ${BLUE}server${NC} ---> Run full Wazuh stack using docker-compose.yml"
  echo -e "    ${BLUE}agent${NC}  ---> Run Wazuh agent using docker-compose-agent.yml"
  echo ""
  echo -e "    ${BLUE}action${NC}  ---> up (default), down, logs, ps, restart"
  echo ""

}

# ---------------------------------------------------------------------------
# Print a consistently formatted section title with a chosen color
# ---------------------------------------------------------------------------

print_section() {
  local color="$1"
  local title="$2"
  echo ""
  echo -e "${color}-----------------------------------------------------${NC}"
  echo -e "${color}  ${title}${NC}"
  echo -e "${color}-----------------------------------------------------${NC}"
}

validate_password() {
  local password="$1"
  local var_name="${2:-Password}"  # just for error message
  local len=${#password}

  # Longitud entre 8 y 64
  if (( len < 8 || len > 64 )); then
    echo "❌  Error: ${var_name} must be between 8 and 64 characters long (current: ${len})."
    return 1
  fi

  # Al menos una mayúscula
  if [[ ! "$password" =~ [A-Z] ]]; then
    echo "❌  Error: ${var_name} must contain at least one uppercase letter."
    return 1
  fi

  # Al menos una minúscula
  if [[ ! "$password" =~ [a-z] ]]; then
    echo "❌  Error: ${var_name} must contain at least one lowercase letter."
    return 1
  fi

  # Al menos un número
  if [[ ! "$password" =~ [0-9] ]]; then
    echo "❌  Error: ${var_name} must contain at least one digit."
    return 1
  fi

  # Al menos uno de los símbolos permitidos: . * + ? -
  if [[ ! "$password" =~ [.*+?\-] ]]; then
    echo "❌  Error: ${var_name} must contain at least one of the following symbols: . * + ? -"
    return 1
  fi

  # Characters not allowed: $ | & \
  if [[ "$password" == *['$|&\']* ]]; then
    echo "❌  Error: Character (\$, |, &, \\) it is not allowed on ${var_name}."
    exit 1
  fi

  return 0
}

clear
print_section "$GREEN" "Wazuh infrastructure stack installation script"
#--------------  Error control
set -euo pipefail

#-------------  Always run from the repo root, regardless of where the script is invoked from

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FLAG_SERVER=false

# ---------- parse args
CHOICE="${1:-}"
ACTION="${2:-up}"

# ---------- Only one or two argument are allowed.
if [[ $# -ne 1 && $# -ne 2 ]]; then
  usage
  exit 1
fi

# ---------- Check the first argument to determine the installation type

if [ "$1" = "agent" ]; then
  echo "🛰️   Deploying Wazuh agent..."
elif [ "$1" = "server" ]; then
  echo "🖥️   Deploying full Wazuh server infrastructure..."
  FLAG_SERVER=true
else
  usage
  exit 1
fi

#---------- Check the second argument for a custom seed value (optional)

#if [[ -z "$CHOICE" ]]; then
#  echo "Select deployment type:"
#  select opt in "server" "agent" "exit"; do
#    case $opt in
#      server) CHOICE=server; break ;;
#      agent) CHOICE=agent; break ;;
#      exit) printf "Exiting.\n"; exit 0 ;;
#      *) echo "Invalid option" ;;
#    esac
#  done
#fi


#print_section "$CYAN" "Selected: $CHOICE | Action: $ACTION"

AGENT_AUTH_PASSWORD_FILE=$REPO_ROOT/config/wazuh_cluster/authd.pass

# ---------- Compose file to deploy 
CERTS_FILE="generate-indexer-certs.yml"
COMPOSE_FILE="docker-compose.yml"
if [ "$FLAG_SERVER" = "false" ]; then
  COMPOSE_FILE="agent/docker-compose-agent.yml"
fi

INTERNAL_USERS_FILE="$REPO_ROOT/config/wazuh_indexer/internal_users.yml"

#############################################################################################################
############################    Establecer vm.max_map_count  ################################################
#############################################################################################################

CURRENT=$(cat /proc/sys/vm/max_map_count)
REQUIRED=262144

echo -e "💾  Current vm.max_map_count: ${GREEN}$CURRENT${NC}"

if [ "$CURRENT" -lt "$REQUIRED" ]; then
    echo "   - 🔧 Setting vm.max_map_count to $REQUIRED..."
    sysctl -w vm.max_map_count=$REQUIRED
    echo 'vm.max_map_count=262144' >> /etc/sysctl.conf
    sysctl -p
else
    echo "    - ✅ vm.max_map_count already satisfies the requirement."
fi

#######################################################################################################
####################################    Check dependencies  #################################################
#############################################################################################################


#--------------- Docker ---------------
if ! command -v docker >/dev/null 2>&1; then
    echo "❌  Error: docker is not installed or not in PATH."
    exit 1
fi
echo "✅  Docker ready: ${GREEN}$(docker --version | cut -d' ' -f1-3)${NC}"

# ------------- Get the Docker group ID
DOCKER_GID=$(getent group docker | cut -d: -f3 || true)
if [ -z "$DOCKER_GID" ]; then
    echo "❌  Docker group not found."
    exit 1
fi

#export DOCKER_GID
echo -e "🐳  Docker GID: ${GREEN}$DOCKER_GID${NC}"

#--------------- curl -------------------
if ! command -v curl &> /dev/null; then
  echo "🔧  Installing curl..."
  command -v apt-get &> /dev/null && apt-get update -qq && apt-get install -y -qq curl
fi
command -v curl &> /dev/null || { echo "❌  Error: curl is not installed or not in PATH."; exit 1; }
echo "✅  curl ready: ${GREEN}$(curl -V | head -n1 | cut -d' ' -f1-2)${NC}"

#--------------- apache utilities for htpasswd -------------------
#if ! command -v htpasswd &> /dev/null; then
#  echo "🔧  Installing apache2-utils..."
#  command -v apt-get &> /dev/null && apt-get update -qq && apt-get install -y -qq apache2-utils
#fi
#command -v htpasswd &> /dev/null || { echo "❌  Error: htpasswd is not installed or not in PATH."; exit 1; }
#echo "✅  htpasswd ready."


###################################################################################################
###################################    Check required files  ######################################
###################################################################################################


#--------------- .env  -------------------
if [ ! -f ".env" ]; then
    echo "🚨  Warning: .env file not found."
    if [ -f ".env.example" ]; then
        echo "ℹ️  Copying .env.example -> .env ..."
        cp .env.example .env
        echo "⚠️  Edit .env with your values before continuing."
    fi
    exit 1
fi
echo "✅  The environment variables will be loaded from the .env file."


#--------------- Docker compose file ------------------
if [ ! -f "$COMPOSE_FILE" ]; then
    echo "❌  Error: $COMPOSE_FILE not found."
    exit 1
fi
echo -e "✅  Docker Compose file found: ${GREEN}$COMPOSE_FILE${NC}"

#--------------- Internal users file ------------------
if [ ! -f "$INTERNAL_USERS_FILE" ]; then
    echo "❌  Error: $INTERNAL_USERS_FILE not found."
    exit 1
fi
echo -e "✅  Internal users file found: ${GREEN}$INTERNAL_USERS_FILE${NC}"
#------------ generate-indexer-certs - server only ------------------

if [ "$FLAG_SERVER" = "true" ]; then
  if [ ! -f "$CERTS_FILE" ]; then
    echo "❌  Error: $CERTS_FILE not found."
    exit 1
  fi
  echo -e "✅  Certs file found: ${GREEN}$CERTS_FILE${NC}"
fi
#------------ post-install script  ------------------
if [ "$FLAG_SERVER" = "true" ]; then
 
  SCRIPT_POST_INSTALL=$(grep '^SCRIPT_POST_INSTALL[[:space:]]*=' .env | sed 's/^[^=]*=[[:space:]]*//' || true)


  if [ -z "$SCRIPT_POST_INSTALL" ]; then
      echo "❌ Error: SCRIPT_POST_INSTALL is not set in .env"
      exit 1
  fi
   
  if [ ! -f "$SCRIPT_POST_INSTALL" ]; then
    echo "❌  Error: $SCRIPT_POST_INSTALL not found."
    exit 1
  fi
  echo -e "✅  Post-install script found: ${GREEN}$REPO_ROOT/$SCRIPT_POST_INSTALL${NC}"
  chmod +x $SCRIPT_POST_INSTALL
fi

# ------- API data file for Wazuh dashboard ------------------------------
API_DATA="$REPO_ROOT/config/wazuh_dashboard/wazuh.yml"
if [ ! -f "$API_DATA" ]; then
    echo "❌  Error: $API_DATA not found."
    exit 1
fi
  echo -e "✅  API data file found: ${GREEN}$API_DATA${NC}"

#------------- Agent authentication password file ------------------------------
if [ ! -f "$AGENT_AUTH_PASSWORD_FILE" ]; then
  echo "❌  Error: $AGENT_AUTH_PASSWORD_FILE not found."
  exit 1
fi
  echo -e "✅  Auth password file found."


############################################################################################################
############################   get hostname for agent name  ################################################
############################################################################################################

LOCAL_AGENT_HOSTNAME=$(grep '^LOCAL_AGENT_HOSTNAME[[:space:]]*=' .env | sed 's/^[^=]*=[[:space:]]*//' || true)

if [ -z "$LOCAL_AGENT_HOSTNAME" ]; then
    echo "❌ Error: LOCAL_AGENT_HOSTNAME is not set in .env"
    exit 1
fi

if [[ "$LOCAL_AGENT_HOSTNAME" == "localhost" ]]; then
    #---------- change to actual hostname ----------------
    LOCAL_AGENT_HOSTNAME=$(hostname -f || true)
fi

echo -e "📝  Agent hostname to use: ${YELLOW}$LOCAL_AGENT_HOSTNAME${NC}"
export LOCAL_AGENT_HOSTNAME

#--------------- Setting up API users and passwords   -------------------


API_NEW_PASSWORD=$(grep '^API_PASSWORD[[:space:]]*=' .env | sed 's/^[^=]*=[[:space:]]*//' || true)
if [ -z "$API_NEW_PASSWORD" ]; then
    echo "❌ Error: API_PASSWORD is not set in .env"
    exit 1
fi

# ----- Password validation
if ! validate_password "$API_NEW_PASSWORD" "API_PASSWORD"; then
    exit 1
fi

sed -i "s|^\([[:space:]]*password:[[:space:]]*\).*|\1$API_NEW_PASSWORD|" "$API_DATA"

echo -e "✅  API data file updated with credentials defined on .env file"

#--------------- NEW USER DEFINED BY MY_USERNAME AND MY_PASSWORD  -------------------

MY_USERNAME=$(grep '^MY_USERNAME[[:space:]]*=' .env | sed 's/^[^=]*=[[:space:]]*//' || true)
if [ -z "$MY_USERNAME" ]; then
    echo "❌ Error: MY_USERNAME is not set in .env"
    exit 1
fi
MY_PASSWORD=$(grep '^MY_PASSWORD[[:space:]]*=' .env | sed 's/^[^=]*=[[:space:]]*//' || true)
if [ -z "$MY_PASSWORD" ]; then
    echo "❌ Error: MY_PASSWORD is not set in .env"
    exit 1
fi
if [[ "$MY_PASSWORD" == *['$|&\']* ]]; then
    echo "❌  Error: Character (\$, |, &, \\) it is not allowed on MY_PASSWORD."
    exit 1
fi

MY_HASH=$(docker run --rm wazuh/wazuh-indexer:4.14.5 /usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh -p "$MY_PASSWORD")

if grep -q "^[[:space:]]*${MY_USERNAME}:" "$INTERNAL_USERS_FILE"; then
    #sed -i "/^[[:space:]]*${MY_USERNAME}:/,/^[[:space:]]*[^[:space:]]/ s/^[[:space:]]*hash:.*/  hash: \"${MY_HASH}\"/" "$INTERNAL_USERS_FILE"
    sed -i "/^[[:space:]]*${MY_USERNAME}:/,/^[[:space:]]*[^[:space:]]/ s#^[[:space:]]*hash:.*#  hash: \"${MY_HASH}\"#" "$INTERNAL_USERS_FILE"
    
    echo -e "✅  Password updated for user ${YELLOW}$MY_USERNAME${NC}"
else
    cat >> "$INTERNAL_USERS_FILE" <<EOF

${MY_USERNAME}:
  hash: "${MY_HASH}"
  reserved: false
  backend_roles:
    - "admin"
  description: "Usuario administrador nuevo"
EOF
echo "✅  New user created with credentials defined on .env: $MY_USERNAME:MY_PASSWORD"
fi

# Copy GID
sed -i "s|^\([[:space:]]*DOCKER_GID=[[:space:]]*\).*|\1$DOCKER_GID|" .env

# -------Set new password for kibanauser  

KIBANA_PASSWORD=$(grep '^DASHBOARD_PASSWORD[[:space:]]*=' .env | sed 's/^[^=]*=[[:space:]]*//' || true)
if [ -z "$KIBANA_PASSWORD" ]; then
    echo "❌ Error: DASHBOARD_PASSWORD is not set in .env"
    exit 1
fi

if [[ "$KIBANA_PASSWORD" != kibanaserver ]]; then
  # ------ Password validation
  if ! validate_password "$KIBANA_PASSWORD" "DASHBOARD_PASSWORD"; then
    exit 1
  fi
  KIBANA_HASH=$(docker run --rm wazuh/wazuh-indexer:4.14.5 /usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh -p "$KIBANA_PASSWORD")
  if grep -q "^[[:space:]]*kibanaserver:" "$INTERNAL_USERS_FILE"; then
    sed -i "/^[[:space:]]*kibanaserver:/,/^[[:space:]]*[^[:space:]]/ s#^[[:space:]]*hash:.*#  hash: \"${KIBANA_HASH}\"#" "$INTERNAL_USERS_FILE"
    echo -e "✅  Password updated for user ${YELLOW}kibanaserver${NC}"
  else
    echo -e "❌ ERROR: Kibanaserver user not found."
    exit 1
  fi
else
  echo -e "⚠️  Warning: the Kibana/dashboard password is still the default '${YELLOW}kibanaserver${NC}'. Please change it in .env."
fi

#exit 1
#########################################################################################################
#####################    COPY AGENT AUTH PASS TO RESPECTIVE FILE  #######################################
#########################################################################################################
AGENT_AUTH_PASSWORD=$(grep '^AGENT_AUTH_PASSWORD[[:space:]]*=' .env | sed 's/^[^=]*=[[:space:]]*//' || true)
if [ -z "$AGENT_AUTH_PASSWORD" ]; then
    echo "❌ Error: AGENT_AUTH_PASSWORD is not set in .env"
    exit 1
fi
# ------- Password validation 
if ! validate_password "$AGENT_AUTH_PASSWORD" "AGENT_AUTH_PASSWORD"; then
    exit 1
fi

echo -n "$AGENT_AUTH_PASSWORD" > $AGENT_AUTH_PASSWORD_FILE

# ------ Create Wazuh group and set permissions for the agent authentication password file
#groupadd -r wazuh 2>/dev/null || true
#chmod 640 $AGENT_AUTH_PASSWORD_FILE
#chown root:wazuh $AGENT_AUTH_PASSWORD_FILE
echo -e "✅  Agent authentication password saved to: ${GREEN}$AGENT_AUTH_PASSWORD_FILE${NC}"

# ------ Generate self-signed certificates  

if [ "$FLAG_SERVER" = "true" ]; then
  echo "🔐  Generating self-signed certificates..."
  docker compose -f generate-indexer-certs.yml run --rm generator
  echo "✅  Certificates generated at ./config/wazuh_indexer_ssl_certs."
fi

#---------- Run the compose file ----------------
echo -e "🚀  ${GREEN}Starting Docker Compose deployment...${NC}"
docker compose -f "$COMPOSE_FILE" --env-file "$REPO_ROOT/.env" up -d
#docker compose logs -f wazuh-init

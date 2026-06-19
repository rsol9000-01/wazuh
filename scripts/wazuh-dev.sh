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

# ---------- Compose file to deploy 
CERTS_FILE="generate-indexer-certs.yml"
COMPOSE_FILE="docker-compose.yml"
if [ "$FLAG_SERVER" = "false" ]; then
  COMPOSE_FILE="agent/docker-compose-agent.yml"
fi

## Resolve compose file: prefer repo root, fallback to sibling wazuh-docker
#COMPOSE_FILE="$REPO_ROOT/docker-compose.yml"
#if [[ "$CHOICE" == "agent" ]]; then
#  COMPOSE_FILE="$REPO_ROOT/docker-compose-agent.yml"
#fi

#############################################################################################################
####################################    Check dependencies  #################################################
#############################################################################################################


#--------------- Docker ---------------
if ! command -v docker >/dev/null 2>&1; then
    echo "❌  Error: docker is not installed or not in PATH."
    exit 1
fi
echo "✅  Docker ready: $(docker --version | cut -d' ' -f1-3)"

#--------------- curl -------------------
if ! command -v curl &> /dev/null; then
  echo "🔧  Installing curl..."
  command -v apt-get &> /dev/null && apt-get update -qq && apt-get install -y -qq curl
fi
command -v curl &> /dev/null || { echo "❌  Error: curl is not installed or not in PATH."; exit 1; }
echo "✅  curl ready: $(curl -V | head -n1 | cut -d' ' -f1-2)"

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
echo "✅  Docker Compose file found: $COMPOSE_FILE"

#------------ generate-indexer-certs - server only ------------------

if [ ! -f "$CERTS_FILE" ]; then
    echo "❌  Error: $CERTS_FILE not found."
    exit 1
fi
echo "✅  Certs file found: $CERTS_FILE"

#########################################################################################################
#####################    Generate self-signed certificates  #############################################
#########################################################################################################
if [ "$FLAG_SERVER" = "true" ]; then
  echo "🔐 Generating self-signed certificates..."
  docker compose -f generate-indexer-certs.yml run --rm generator
  echo "   - ✅ Certificates generated at /config/wazuh_indexer_ssl_certs."
fi

#---------- Run the compose file ----------------
echo -e "🚀  ${GREEN}Starting Docker Compose deployment...${NC}"
docker compose -f "$COMPOSE_FILE" --env-file "$REPO_ROOT/.env" up -d





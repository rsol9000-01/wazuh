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
COMPOSE_FILE="docker-compose.yml"
if [ "$FLAG_SERVER" = "false" ]; then
  COMPOSE_FILE="docker-compose-agent.yml"
fi

## Resolve compose file: prefer repo root, fallback to sibling wazuh-docker
#COMPOSE_FILE="$REPO_ROOT/docker-compose.yml"
#if [[ "$CHOICE" == "agent" ]]; then
#  COMPOSE_FILE="$REPO_ROOT/docker-compose-agent.yml"
#fi

if [[ ! -f "$COMPOSE_FILE" ]]; then
  # try sibling wazuh-docker
  ALT="$REPO_ROOT/../wazuh-docker/$(basename "$COMPOSE_FILE")"
  if [[ -f "$ALT" ]]; then
    COMPOSE_FILE="$ALT"
    echo -e "${YELLOW}Note:${NC} using compose file from ../wazuh-docker: $COMPOSE_FILE"
  else
    echo -e "${RED}Error:${NC} Compose file not found: $COMPOSE_FILE" >&2
    exit 1
  fi
fi

echo -e "✅  Compose file: ${GREEN}$COMPOSE_FILE${NC}"

# Check docker available
if ! command -v docker >/dev/null 2>&1; then
  echo -e "${RED}Error:${NC} docker is not installed or not in PATH." >&2
  exit 1
fi
echo -e "🔧  Docker: $(docker --version | head -n1)"

# Prepare docker compose command array
case "$ACTION" in
  up)
    CMD=(docker compose -f "$COMPOSE_FILE" --env-file "$REPO_ROOT/.env" up -d)
    ;;
  down)
    CMD=(docker compose -f "$COMPOSE_FILE" down)
    ;;
  logs)
    CMD=(docker compose -f "$COMPOSE_FILE" logs -f)
    ;;
  ps)
    CMD=(docker compose -f "$COMPOSE_FILE" ps)
    ;;
  restart)
    CMD=(docker compose -f "$COMPOSE_FILE" restart)
    ;;
  *)
    echo -e "${RED}Unknown action:${NC} $ACTION" >&2
    usage
    exit 2
    ;;
esac

# Run command
echo -e "\n${BLUE}Running:${NC} ${CMD[*]}\n"
"${CMD[@]}"

# If action was up and server selected, tail main init logs briefly
if [[ "$ACTION" == "up" ]]; then
  if [[ "$CHOICE" == "server" ]]; then
    echo -e "\n${GREEN}Tailing wazuh manager logs (ctrl+c to stop)...${NC}\n"
    docker compose -f "$COMPOSE_FILE" logs -f wazuh.manager || true
  else
    echo -e "\n${GREEN}Tailing wazuh agent logs (ctrl+c to stop)...${NC}\n"
    docker compose -f "$COMPOSE_FILE" logs -f wazuh.agent || true
  fi
fi

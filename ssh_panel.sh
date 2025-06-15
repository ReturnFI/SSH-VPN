#!/bin/bash
# SSH VPN - Simple Management

# Set color variables
RED='\e[91m'
GREEN='\e[92m'
YELLOW='\e[93m'
BLUE='\e[94m'
CYAN='\e[96m'
RESET='\e[0m'

SHELL_NOLOGIN="/usr/sbin/nologin"
SHELL_FALSE="/bin/false"

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}❌ This script must be run as root${RESET}"
  exit 1
fi

if [[ ! -f $SHELL_NOLOGIN ]]; then
  echo -e "${YELLOW}⚠️ Warning: $SHELL_NOLOGIN not found. Falling back to $SHELL_FALSE${RESET}"
  SHELL_NOLOGIN=$SHELL_FALSE
fi

function menu() {
  echo
  echo -e "${CYAN}======== SSH VPN ========${RESET}"
  echo -e "${GREEN}1) ➕ Add VPN User${RESET}"
  echo -e "${RED}2) 🗑️  Remove VPN User${RESET}"
  echo -e "${YELLOW}3) 📄 List VPN Users${RESET}"
  echo -e "${BLUE}4) 🔁 Change SSH Port${RESET}"
  echo -e "${RED}5) ❌ Exit${RESET}"
  echo -e "${CYAN}===============================${RESET}"
  read -rp "Choose an option [1-5]: " opt

  case "$opt" in
    1) add_user ;;
    2) remove_user ;;
    3) list_users ;;
    4) change_ssh_port ;;
    5) exit 0 ;;
    *) echo -e "${RED}❌ Invalid option${RESET}"; menu ;;
  esac
}

function add_user() {
  read -rp "👤 Enter new username: " username
  if id "$username" &>/dev/null; then
    echo -e "${RED}❌ User $username already exists${RESET}"
    return
  fi

  read -rsp "🔑 Enter password: " password
  echo

  useradd -M -s "$SHELL_NOLOGIN" "$username"
  echo "$username:$password" | chpasswd

  echo -e "${GREEN}✅ User $username created with VPN-only access${RESET}"
}

function remove_user() {
  read -rp "👤 Enter username to remove: " username
  if ! id "$username" &>/dev/null; then
    echo -e "${RED}❌ User $username does not exist${RESET}"
    return
  fi

  userdel -r "$username" 2>/dev/null
  echo -e "${GREEN}🗑️ User $username removed${RESET}"
}

function list_users() {
  echo -e "${YELLOW}📄 VPN-only Users (UID ≥ 1000 & nologin):${RESET}"
  awk -F: -v shell="$SHELL_NOLOGIN" '($7 == shell && $3 >= 1000) { print "🔹 " $1 }' /etc/passwd
}

function change_ssh_port() {
  read -rp "🔁 Enter new SSH port (1–65535): " new_port

  if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
    echo -e "${RED}❌ Invalid port number${RESET}"
    return
  fi

  SSH_CONFIG="/etc/ssh/sshd_config"
  cp "$SSH_CONFIG" "${SSH_CONFIG}.bak"
  sed -i '/^#\?Port /d' "$SSH_CONFIG"
  echo "Port $new_port" >> "$SSH_CONFIG"

  sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' "$SSH_CONFIG"

  echo -e "${BLUE}🔄 Restarting SSH service...${RESET}"
  systemctl restart ssh || systemctl restart sshd

  if ss -tuln | grep -q ":$new_port"; then
    echo -e "${GREEN}✅ SSH is now listening on port $new_port${RESET}"
  else
    echo -e "${RED}⚠️ SSH may not have restarted correctly. Check the service manually!${RESET}"
  fi
}

while true; do
  menu
done

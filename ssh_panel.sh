#!/bin/bash
# SSH VPN - Simple Management

RED='\e[91m'
GREEN='\e[92m'
YELLOW='\e[93m'
BLUE='\e[94m'
CYAN='\e[96m'
RESET='\e[0m'

SHELL_NOLOGIN="/usr/sbin/nologin"
SHELL_FALSE="/bin/false"
USER_DB="/opt/ssh_vpn_users.json"

detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
    VER=$VERSION_ID
  elif type lsb_release >/dev/null 2>&1; then
    OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
    VER=$(lsb_release -sr)
  elif [[ -f /etc/redhat-release ]]; then
    OS="centos"
    VER=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1)
  else
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    VER=""
  fi
}

install_jq() {
  detect_os
  
  echo -e "${BLUE}🔍 Checking for jq installation...${RESET}"
  
  if command -v jq >/dev/null 2>&1; then
    echo -e "${GREEN}✅ jq is already installed${RESET}"
    return 0
  fi
  
  echo -e "${YELLOW}📦 Installing jq...${RESET}"
  
  case "$OS" in
    ubuntu|debian)
      apt-get update && apt-get install -y jq
      ;;
    centos|rhel|rocky|almalinux)
      if command -v dnf >/dev/null 2>&1; then
        dnf install -y jq
      elif command -v yum >/dev/null 2>&1; then
        if ! rpm -qa | grep -q epel-release; then
          if [[ "$VER" =~ ^7 ]]; then
            yum install -y epel-release
          elif [[ "$VER" =~ ^8 ]]; then
            dnf install -y epel-release
          fi
        fi
        yum install -y jq
      else
        echo -e "${RED}❌ No suitable package manager found for $OS${RESET}"
        return 1
      fi
      ;;
    fedora)
      dnf install -y jq
      ;;
    opensuse|suse)
      zypper install -y jq
      ;;
    arch|manjaro)
      pacman -S --noconfirm jq
      ;;
    alpine)
      apk add --no-cache jq
      ;;
    *)
      echo -e "${RED}❌ Unsupported OS: $OS${RESET}"
      echo -e "${YELLOW}Please install jq manually for your system${RESET}"
      return 1
      ;;
  esac
  
  if command -v jq >/dev/null 2>&1; then
    echo -e "${GREEN}✅ jq installed successfully${RESET}"
    return 0
  else
    echo -e "${RED}❌ Failed to install jq${RESET}"
    return 1
  fi
}

validate_alphanumeric() {
  local input="$1"
  local field_name="$2"
  
  if [[ ! "$input" =~ ^[a-zA-Z0-9]+$ ]]; then
    echo -e "${RED}❌ $field_name must contain only alphanumeric characters (a-z, A-Z, 0-9)${RESET}"
    return 1
  fi
  return 0
}

check_prerequisites() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}❌ This script must be run as root${RESET}"
    exit 1
  fi

  if ! install_jq; then
    echo -e "${RED}❌ jq installation failed. This script requires jq to manage user database.${RESET}"
    exit 1
  fi

  if [[ ! -f $SHELL_NOLOGIN ]]; then
    echo -e "${YELLOW}⚠️ Warning: $SHELL_NOLOGIN not found. Falling back to $SHELL_FALSE${RESET}"
    SHELL_NOLOGIN=$SHELL_FALSE
  fi
}

function init_user_db() {
  if [[ ! -f "$USER_DB" ]]; then
    echo '{"users": []}' > "$USER_DB"
    chmod 600 "$USER_DB"
  fi
}

function user_exists_in_db() {
  local username="$1"
  if [[ -f "$USER_DB" ]]; then
    jq -e ".users[] | select(.username == \"$username\")" "$USER_DB" >/dev/null 2>&1
  else
    return 1
  fi
}

function add_user_to_db() {
  local username="$1"
  local password="$2"
  local created_date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  init_user_db
  
  local temp_file=$(mktemp)
  jq ".users += [{\"username\": \"$username\", \"password\": \"$password\", \"created\": \"$created_date\", \"last_password_change\": \"$created_date\"}]" "$USER_DB" > "$temp_file"
  mv "$temp_file" "$USER_DB"
  chmod 600 "$USER_DB"
}

function remove_user_from_db() {
  local username="$1"
  if [[ -f "$USER_DB" ]]; then
    local temp_file=$(mktemp)
    jq ".users = [.users[] | select(.username != \"$username\")]" "$USER_DB" > "$temp_file"
    mv "$temp_file" "$USER_DB"
    chmod 600 "$USER_DB"
  fi
}

function update_user_password_in_db() {
  local username="$1"
  local new_password="$2"
  local change_date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  if [[ -f "$USER_DB" ]]; then
    local temp_file=$(mktemp)
    jq "(.users[] | select(.username == \"$username\") | .password) = \"$new_password\" | (.users[] | select(.username == \"$username\") | .last_password_change) = \"$change_date\"" "$USER_DB" > "$temp_file"
    mv "$temp_file" "$USER_DB"
    chmod 600 "$USER_DB"
  fi
}

function menu() {
  echo
  echo -e "${CYAN}========== SSH VPN ===========${RESET}"
  echo -e "${GREEN}1) ➕ Add VPN User${RESET}"
  echo -e "${RED}2) 🗑️  Remove VPN User${RESET}"
  echo -e "${YELLOW}3) 📄 List VPN Users${RESET}"
  echo -e "${BLUE}4) 🔑 Change User Password${RESET}"
  echo -e "${CYAN}5) 🔄 Change SSH Port${RESET}"
  echo -e "${RED}6) ❌ Exit${RESET}"
  echo -e "${CYAN}=================================${RESET}"
  read -rp "Choose an option [1-6]: " opt

  case "$opt" in
    1) add_user ;;
    2) remove_user ;;
    3) list_users ;;
    4) change_user_password ;;
    5) change_ssh_port ;;
    6) exit 0 ;;
    *) echo -e "${RED}❌ Invalid option${RESET}"; menu ;;
  esac
}

function add_user() {
  while true; do
    read -rp "👤 Enter new username (alphanumeric only): " username
    
    if [[ -z "$username" ]]; then
      echo -e "${RED}❌ Username cannot be empty${RESET}"
      continue
    fi
    
    if ! validate_alphanumeric "$username" "Username"; then
      continue
    fi
    
    if id "$username" &>/dev/null; then
      echo -e "${RED}❌ User $username already exists in the system${RESET}"
      read -rp "🔄 Would you like to try another username? (y/n): " retry
      if [[ "$retry" =~ ^[Yy]$ ]]; then
        continue
      else
        return
      fi
    fi
    
    if user_exists_in_db "$username"; then
      echo -e "${RED}❌ User $username already exists in VPN database${RESET}"
      read -rp "🔄 Would you like to try another username? (y/n): " retry
      if [[ "$retry" =~ ^[Yy]$ ]]; then
        continue
      else
        return
      fi
    fi
    
    break
  done

  while true; do
    read -rp "🔑 Enter password (alphanumeric only): " password
    echo
    if [[ -z "$password" ]]; then
      echo -e "${RED}❌ Password cannot be empty${RESET}"
      continue
    fi
    
    if ! validate_alphanumeric "$password" "Password"; then
      continue
    fi
    
    break
  done

  useradd -M -s "$SHELL_NOLOGIN" "$username"
  echo "$username:$password" | chpasswd

  add_user_to_db "$username" "$password"

  echo -e "${GREEN}✅ User $username created successfully with VPN-only access${RESET}"
}

function remove_user() {
  read -rp "👤 Enter username to remove: " username
  
  if [[ -z "$username" ]]; then
    echo -e "${RED}❌ Username cannot be empty${RESET}"
    return
  fi
  
  if ! id "$username" &>/dev/null; then
    echo -e "${RED}❌ User $username does not exist in the system${RESET}"
    return
  fi

  if ! user_exists_in_db "$username"; then
    echo -e "${YELLOW}⚠️ User $username not found in VPN database, but exists in system${RESET}"
  fi

  read -rp "🗑️ Are you sure you want to remove user $username? (y/N): " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}❌ Operation cancelled${RESET}"
    return
  fi

  userdel -r "$username" 2>/dev/null
  
  remove_user_from_db "$username"

  echo -e "${GREEN}🗑️ User $username removed successfully${RESET}"
}

function list_users() {
  echo -e "${YELLOW}📄 VPN Users Database:${RESET}"
  echo -e "${CYAN}========================${RESET}"
  
  if [[ ! -f "$USER_DB" ]] || ! jq -e '.users | length > 0' "$USER_DB" >/dev/null 2>&1; then
    echo -e "${YELLOW}📝 No VPN users found in database${RESET}"
    echo
    echo -e "${BLUE}🔍 System users with nologin shell (UID ≥ 1000):${RESET}"
    awk -F: -v shell="$SHELL_NOLOGIN" '($7 == shell && $3 >= 1000) { print "  🔹 " $1 " (UID: " $3 ")" }' /etc/passwd
    return
  fi

  jq -r '.users[] | "🔹 Username: \(.username) | Password: \(.password) | Created: \(.created)"' "$USER_DB" 2>/dev/null || {
    echo -e "${RED}❌ Error reading user database${RESET}"
    return
  }
  
  echo -e "${CYAN}========================${RESET}"
  local user_count=$(jq '.users | length' "$USER_DB" 2>/dev/null || echo "0")
  echo -e "${GREEN}📊 Total VPN users: $user_count${RESET}"
}

function change_user_password() {
  read -rp "👤 Enter username: " username
  
  if [[ -z "$username" ]]; then
    echo -e "${RED}❌ Username cannot be empty${RESET}"
    return
  fi
  
  if ! id "$username" &>/dev/null; then
    echo -e "${RED}❌ User $username does not exist in the system${RESET}"
    return
  fi

  if ! user_exists_in_db "$username"; then
    echo -e "${RED}❌ User $username not found in VPN database${RESET}"
    return
  fi

  while true; do
    read -rp "🔑 Enter new password (alphanumeric only): " new_password
    echo
    if [[ -z "$new_password" ]]; then
      echo -e "${RED}❌ Password cannot be empty${RESET}"
      continue
    fi
    
    if ! validate_alphanumeric "$new_password" "Password"; then
      continue
    fi
    
    break
  done

  echo "$username:$new_password" | chpasswd

  update_user_password_in_db "$username" "$new_password"

  echo -e "${GREEN}✅ Password for user $username updated successfully${RESET}"
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

  echo -e "${BLUE}🔄 Restarting SSH service...${RESET}"
  
  detect_os
  case "$OS" in
    ubuntu|debian)
      systemctl restart ssh
      ;;
    centos|rhel|rocky|almalinux|fedora)
      systemctl restart sshd
      ;;
    *)
      systemctl restart sshd || systemctl restart ssh
      ;;
  esac

  if ss -tuln 2>/dev/null | grep -q ":$new_port" || netstat -tuln 2>/dev/null | grep -q ":$new_port"; then
    echo -e "${GREEN}✅ SSH is now listening on port $new_port${RESET}"
  else
    echo -e "${RED}⚠️ SSH may not have restarted correctly. Check the service manually!${RESET}"
  fi
}

echo -e "${BLUE}🚀 SSH VPN Manager - Enhanced Version${RESET}"
echo -e "${CYAN}Checking prerequisites...${RESET}"

check_prerequisites
init_user_db

while true; do
  menu
done

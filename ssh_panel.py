#!/usr/bin/env python3
import json
import os
import sys
import re
import subprocess
import pwd
import datetime
import tempfile
import shutil
from pathlib import Path

class Colors:
    RED = '\033[91m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    CYAN = '\033[96m'
    RESET = '\033[0m'

class SSHVPNManager:
    def __init__(self):
        self.shell_nologin = "/usr/sbin/nologin"
        self.shell_false = "/bin/false"
        self.user_db = "/opt/ssh_vpn_users.json"
        self.ssh_config = "/etc/ssh/sshd_config"
        self.os_info = {}
        
    def detect_os(self):
        try:
            with open('/etc/os-release') as f:
                for line in f:
                    if '=' in line:
                        key, value = line.strip().split('=', 1)
                        self.os_info[key] = value.strip('"')
        except FileNotFoundError:
            try:
                result = subprocess.run(['lsb_release', '-si'], capture_output=True, text=True, check=True)
                self.os_info['ID'] = result.stdout.strip().lower()
                result = subprocess.run(['lsb_release', '-sr'], capture_output=True, text=True, check=True)
                self.os_info['VERSION_ID'] = result.stdout.strip()
            except (subprocess.CalledProcessError, FileNotFoundError):
                self.os_info['ID'] = 'unknown'
                
    def check_prerequisites(self):
        if os.geteuid() != 0:
            print(f"{Colors.RED}❌ This script must be run as root{Colors.RESET}")
            sys.exit(1)
            
        if not os.path.exists(self.shell_nologin):
            print(f"{Colors.YELLOW}⚠️ Warning: {self.shell_nologin} not found. Falling back to {self.shell_false}{Colors.RESET}")
            self.shell_nologin = self.shell_false
            
    def init_user_db(self):
        if not os.path.exists(self.user_db):
            with open(self.user_db, 'w') as f:
                json.dump({"users": []}, f)
            os.chmod(self.user_db, 0o600)
            
    def validate_alphanumeric(self, input_str, field_name):
        if not re.match(r'^[a-zA-Z0-9]+$', input_str):
            print(f"{Colors.RED}❌ {field_name} must contain only alphanumeric characters (a-z, A-Z, 0-9){Colors.RESET}")
            return False
        return True
        
    def user_exists_in_system(self, username):
        try:
            pwd.getpwnam(username)
            return True
        except KeyError:
            return False
            
    def user_exists_in_db(self, username):
        if not os.path.exists(self.user_db):
            return False
        try:
            with open(self.user_db, 'r') as f:
                data = json.load(f)
            return any(user['username'] == username for user in data['users'])
        except (json.JSONDecodeError, KeyError):
            return False
            
    def add_user_to_db(self, username, password):
        self.init_user_db()
        created_date = datetime.datetime.utcnow().isoformat() + 'Z'
        
        try:
            with open(self.user_db, 'r') as f:
                data = json.load(f)
        except (json.JSONDecodeError, FileNotFoundError):
            data = {"users": []}
            
        data['users'].append({
            "username": username,
            "password": password,
            "created": created_date,
            "last_password_change": created_date
        })
        
        with tempfile.NamedTemporaryFile(mode='w', delete=False) as temp_f:
            json.dump(data, temp_f)
            temp_path = temp_f.name
            
        shutil.move(temp_path, self.user_db)
        os.chmod(self.user_db, 0o600)
        
    def remove_user_from_db(self, username):
        if not os.path.exists(self.user_db):
            return
            
        try:
            with open(self.user_db, 'r') as f:
                data = json.load(f)
        except (json.JSONDecodeError, KeyError):
            return
            
        data['users'] = [user for user in data['users'] if user['username'] != username]
        
        with tempfile.NamedTemporaryFile(mode='w', delete=False) as temp_f:
            json.dump(data, temp_f)
            temp_path = temp_f.name
            
        shutil.move(temp_path, self.user_db)
        os.chmod(self.user_db, 0o600)
        
    def update_user_password_in_db(self, username, new_password):
        if not os.path.exists(self.user_db):
            return
            
        try:
            with open(self.user_db, 'r') as f:
                data = json.load(f)
        except (json.JSONDecodeError, KeyError):
            return
            
        change_date = datetime.datetime.utcnow().isoformat() + 'Z'
        
        for user in data['users']:
            if user['username'] == username:
                user['password'] = new_password
                user['last_password_change'] = change_date
                break
                
        with tempfile.NamedTemporaryFile(mode='w', delete=False) as temp_f:
            json.dump(data, temp_f)
            temp_path = temp_f.name
            
        shutil.move(temp_path, self.user_db)
        os.chmod(self.user_db, 0o600)
        
    def menu(self):
        while True:
            print()
            print(f"{Colors.CYAN}========== SSH VPN ==========={Colors.RESET}")
            print(f"{Colors.GREEN}1) ➕ Add VPN User{Colors.RESET}")
            print(f"{Colors.RED}2) 🗑️  Remove VPN User{Colors.RESET}")
            print(f"{Colors.YELLOW}3) 📄 List VPN Users{Colors.RESET}")
            print(f"{Colors.BLUE}4) 🔑 Change User Password{Colors.RESET}")
            print(f"{Colors.CYAN}5) 🔄 Change SSH Port{Colors.RESET}")
            print(f"{Colors.RED}6) ❌ Exit{Colors.RESET}")
            print(f"{Colors.CYAN}================================={Colors.RESET}")
            
            try:
                opt = input("Choose an option [1-6]: ").strip()
            except (KeyboardInterrupt, EOFError):
                print(f"\n{Colors.YELLOW}👋 Goodbye!{Colors.RESET}")
                sys.exit(0)
                
            if opt == '1':
                self.add_user()
            elif opt == '2':
                self.remove_user()
            elif opt == '3':
                self.list_users()
            elif opt == '4':
                self.change_user_password()
            elif opt == '5':
                self.change_ssh_port()
            elif opt == '6':
                sys.exit(0)
            else:
                print(f"{Colors.RED}❌ Invalid option{Colors.RESET}")
                
    def add_user(self):
        while True:
            try:
                username = input("👤 Enter new username (alphanumeric only): ").strip()
            except (KeyboardInterrupt, EOFError):
                return
                
            if not username:
                print(f"{Colors.RED}❌ Username cannot be empty{Colors.RESET}")
                continue
                
            if not self.validate_alphanumeric(username, "Username"):
                continue
                
            if self.user_exists_in_system(username):
                print(f"{Colors.RED}❌ User {username} already exists in the system{Colors.RESET}")
                try:
                    retry = input("🔄 Would you like to try another username? (y/n): ").strip().lower()
                    if retry.startswith('y'):
                        continue
                    else:
                        return
                except (KeyboardInterrupt, EOFError):
                    return
                    
            if self.user_exists_in_db(username):
                print(f"{Colors.RED}❌ User {username} already exists in VPN database{Colors.RESET}")
                try:
                    retry = input("🔄 Would you like to try another username? (y/n): ").strip().lower()
                    if retry.startswith('y'):
                        continue
                    else:
                        return
                except (KeyboardInterrupt, EOFError):
                    return
                    
            break
            
        while True:
            try:
                password = input("🔑 Enter password (alphanumeric only): ").strip()
            except (KeyboardInterrupt, EOFError):
                return
                
            if not password:
                print(f"{Colors.RED}❌ Password cannot be empty{Colors.RESET}")
                continue
                
            if not self.validate_alphanumeric(password, "Password"):
                continue
                
            break
            
        try:
            subprocess.run(['useradd', '-M', '-s', self.shell_nologin, username], check=True)
            subprocess.run(['chpasswd'], input=f"{username}:{password}", text=True, check=True)
            
            self.add_user_to_db(username, password)
            print(f"{Colors.GREEN}✅ User {username} created successfully with VPN-only access{Colors.RESET}")
        except subprocess.CalledProcessError as e:
            print(f"{Colors.RED}❌ Failed to create user: {e}{Colors.RESET}")
            
    def remove_user(self):
        try:
            username = input("👤 Enter username to remove: ").strip()
        except (KeyboardInterrupt, EOFError):
            return
            
        if not username:
            print(f"{Colors.RED}❌ Username cannot be empty{Colors.RESET}")
            return
            
        if not self.user_exists_in_system(username):
            print(f"{Colors.RED}❌ User {username} does not exist in the system{Colors.RESET}")
            return
            
        if not self.user_exists_in_db(username):
            print(f"{Colors.YELLOW}⚠️ User {username} not found in VPN database, but exists in system{Colors.RESET}")
            
        try:
            confirm = input(f"🗑️ Are you sure you want to remove user {username}? (y/N): ").strip().lower()
            if not confirm.startswith('y'):
                print(f"{Colors.YELLOW}❌ Operation cancelled{Colors.RESET}")
                return
        except (KeyboardInterrupt, EOFError):
            return
            
        try:
            subprocess.run(['userdel', '-r', username], check=True, stderr=subprocess.DEVNULL)
        except subprocess.CalledProcessError:
            pass
            
        self.remove_user_from_db(username)
        print(f"{Colors.GREEN}🗑️ User {username} removed successfully{Colors.RESET}")
        
    def list_users(self):
        print(f"{Colors.YELLOW}📄 VPN Users Database:{Colors.RESET}")
        print(f"{Colors.CYAN}========================{Colors.RESET}")
        
        if not os.path.exists(self.user_db):
            print(f"{Colors.YELLOW}📝 No VPN users found in database{Colors.RESET}")
            self._show_system_users()
            return
            
        try:
            with open(self.user_db, 'r') as f:
                data = json.load(f)
                
            if not data.get('users'):
                print(f"{Colors.YELLOW}📝 No VPN users found in database{Colors.RESET}")
                self._show_system_users()
                return
                
            for user in data['users']:
                print(f"🔹 Username: {user['username']} | Password: {user['password']} | Created: {user['created']}")
                
            print(f"{Colors.CYAN}========================{Colors.RESET}")
            print(f"{Colors.GREEN}📊 Total VPN users: {len(data['users'])}{Colors.RESET}")
            
        except (json.JSONDecodeError, KeyError):
            print(f"{Colors.RED}❌ Error reading user database{Colors.RESET}")
            
    def _show_system_users(self):
        print()
        print(f"{Colors.BLUE}🔍 System users with nologin shell (UID ≥ 1000):{Colors.RESET}")
        try:
            for user in pwd.getpwall():
                if user.pw_shell == self.shell_nologin and user.pw_uid >= 1000:
                    print(f"  🔹 {user.pw_name} (UID: {user.pw_uid})")
        except Exception:
            pass
            
    def change_user_password(self):
        try:
            username = input("👤 Enter username: ").strip()
        except (KeyboardInterrupt, EOFError):
            return
            
        if not username:
            print(f"{Colors.RED}❌ Username cannot be empty{Colors.RESET}")
            return
            
        if not self.user_exists_in_system(username):
            print(f"{Colors.RED}❌ User {username} does not exist in the system{Colors.RESET}")
            return
            
        if not self.user_exists_in_db(username):
            print(f"{Colors.RED}❌ User {username} not found in VPN database{Colors.RESET}")
            return
            
        while True:
            try:
                new_password = input("🔑 Enter new password (alphanumeric only): ").strip()
            except (KeyboardInterrupt, EOFError):
                return
                
            if not new_password:
                print(f"{Colors.RED}❌ Password cannot be empty{Colors.RESET}")
                continue
                
            if not self.validate_alphanumeric(new_password, "Password"):
                continue
                
            break
            
        try:
            subprocess.run(['chpasswd'], input=f"{username}:{new_password}", text=True, check=True)
            self.update_user_password_in_db(username, new_password)
            print(f"{Colors.GREEN}✅ Password for user {username} updated successfully{Colors.RESET}")
        except subprocess.CalledProcessError as e:
            print(f"{Colors.RED}❌ Failed to update password: {e}{Colors.RESET}")
            
    def change_ssh_port(self):
        try:
            new_port = input("🔁 Enter new SSH port (1–65535): ").strip()
        except (KeyboardInterrupt, EOFError):
            return
            
        if not re.match(r'^\d+$', new_port) or not (1 <= int(new_port) <= 65535):
            print(f"{Colors.RED}❌ Invalid port number{Colors.RESET}")
            return
            
        try:
            shutil.copy2(self.ssh_config, f"{self.ssh_config}.bak")
            
            with open(self.ssh_config, 'r') as f:
                lines = f.readlines()
                
            filtered_lines = [line for line in lines if not re.match(r'^\s*#?\s*Port\s+', line)]
            filtered_lines.append(f"Port {new_port}\n")
            
            with open(self.ssh_config, 'w') as f:
                f.writelines(filtered_lines)
                
            print(f"{Colors.BLUE}🔄 Restarting SSH service...{Colors.RESET}")
            
            self.detect_os()
            os_id = self.os_info.get('ID', 'unknown').lower()
            
            if os_id in ['ubuntu', 'debian']:
                service_name = 'ssh'
            else:
                service_name = 'sshd'
                
            try:
                subprocess.run(['systemctl', 'restart', service_name], check=True)
            except subprocess.CalledProcessError:
                try:
                    alt_service = 'sshd' if service_name == 'ssh' else 'ssh'
                    subprocess.run(['systemctl', 'restart', alt_service], check=True)
                except subprocess.CalledProcessError:
                    print(f"{Colors.RED}❌ Failed to restart SSH service{Colors.RESET}")
                    return
                    
            try:
                result = subprocess.run(['ss', '-tuln'], capture_output=True, text=True)
                if f":{new_port}" in result.stdout:
                    print(f"{Colors.GREEN}✅ SSH is now listening on port {new_port}{Colors.RESET}")
                else:
                    raise subprocess.CalledProcessError(1, 'ss')
            except subprocess.CalledProcessError:
                try:
                    result = subprocess.run(['netstat', '-tuln'], capture_output=True, text=True)
                    if f":{new_port}" in result.stdout:
                        print(f"{Colors.GREEN}✅ SSH is now listening on port {new_port}{Colors.RESET}")
                    else:
                        print(f"{Colors.RED}⚠️ SSH may not have restarted correctly. Check the service manually!{Colors.RESET}")
                except subprocess.CalledProcessError:
                    print(f"{Colors.RED}⚠️ Could not verify SSH port. Check the service manually!{Colors.RESET}")
                    
        except Exception as e:
            print(f"{Colors.RED}❌ Failed to change SSH port: {e}{Colors.RESET}")
            
    def run(self):
        print(f"{Colors.BLUE}🚀 SSH VPN Manager - Python Version{Colors.RESET}")
        print(f"{Colors.CYAN}Checking prerequisites...{Colors.RESET}")
        
        self.check_prerequisites()
        self.init_user_db()
        
        self.menu()

if __name__ == "__main__":
    manager = SSHVPNManager()
    manager.run()

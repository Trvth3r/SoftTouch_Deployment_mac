#!/bin/bash
# ----------------------------------------
# Title: Enforce Single-User SSH Access
# Description: Restricts SSH (Remote Login) to one specific user by 
#              rebuilding the com.apple.access_ssh ACL group cleanly.
#              Detects and reports if the Administrators group previously
#              had SSH access and removes it safely.
# Author: Ish Morgan
# ----------------------------------------

USER="admin"
PLIST="/var/db/dslocal/nodes/Default/groups/com.apple.access_ssh.plist"
ADMIN_GUID="ABCDEFAB-CDEF-ABCD-EFAB-CDEF00000050"   # universal admin group GUID

# Check user existence
user_exists() {
  dscl . -read "/Users/$USER" &>/dev/null
}

# Detect and only print admin SSH access when present
check_admin_group() {
  local nested
  nested=$(dscl . -read /Groups/com.apple.access_ssh nestedgroups 2>/dev/null | awk '{$1=""; print $0}' | xargs)

  if [[ "$nested" == *"$ADMIN_GUID"* ]]; then
    echo "---- Admin Group SSH Access ----"
    echo "Administrators group SSH access: ALLOWED"
    echo "----------------------------------------"
  fi
}

# Pre-enforcement check
precheck() {
  echo "----------------------------------------"
  echo "---- Current SSH Status ----"
  systemsetup -getremotelogin
  echo "----------------------------------------"

  echo "---- Current SSH Access Group ----"
  if dscl . -read /Groups/com.apple.access_ssh &>/dev/null; then
    local current_users
    current_users=$(dscl . -read /Groups/com.apple.access_ssh GroupMembership 2>/dev/null \
      | awk '{$1=""; print $0}' | xargs)
    echo "Current allowed SSH users: ${current_users:-None}"
  else
    echo "No existing com.apple.access_ssh group"
  fi
  echo "----------------------------------------"

  check_admin_group

  echo "---- Proceeding with enforcement ----"
  echo "----------------------------------------"
}

backup_plist() {
  [[ -f "$PLIST" ]] && cp "$PLIST" "/var/tmp/com.apple.access_ssh.plist.bak"
}

create_ssh_group() {
  dscl . -delete /Groups/com.apple.access_ssh 2>/dev/null
  dscl . -create /Groups/com.apple.access_ssh
  dscl . -create /Groups/com.apple.access_ssh RecordName com.apple.access_ssh
  dscl . -create /Groups/com.apple.access_ssh RealName "Remote Login Access"
  dscl . -create /Groups/com.apple.access_ssh GroupMembership ""
  dscl . -create /Groups/com.apple.access_ssh GroupMembers ""
}

append_user_to_ssh_group() {
  dscl . -append /Groups/com.apple.access_ssh GroupMembership "$USER"
  local uid
  uid=$(dscl . -read /Users/"$USER" GeneratedUID | awk '{print $2}')
  dscl . -append /Groups/com.apple.access_ssh GroupMembers "$uid"
}

verify() {
  echo "----------------------------------------"
  echo "---- Group (After Enforcement) ----"
  dscl . -read /Groups/com.apple.access_ssh | grep -E 'RecordName|GroupMembership|GroupMembers'
  echo "----------------------------------------"

  echo "---- SSH Status (After Enforcement) ----"
  systemsetup -getremotelogin
  echo "----------------------------------------"

  check_admin_group

  echo "✔ SSH restricted to: $USER"
  echo "----------------------------------------"
}

main() {
  precheck
  systemsetup -setremotelogin on

  backup_plist

  if ! user_exists; then
    echo "✗ User '$USER' not found."
    exit 1
  fi

  create_ssh_group
  append_user_to_ssh_group
  verify

  launchctl kickstart -k system/com.openssh.sshd 2>/dev/null
}

main

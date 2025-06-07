#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

USERS_YAML_FILE="../users.yaml"   # adjust path if needed

PROTECTED_USERS=("root" "harishannavisamy")
GROUP_KEYS=("users" "authors" "mods" "admins")

# Check if user is protected
is_protected_user() {
  local u=$1
  for p in "${PROTECTED_USERS[@]}"; do
    if [[ "$u" == "$p" ]]; then
      return 0
    fi
  done
  return 1
}

# Check if user exists on system
user_exists() {
  id "$1" &>/dev/null
}

# Lock and delete user safely
lock_and_delete_user() {
  local user=$1
  if is_protected_user "$user"; then
    echo "Skipping protected user: $user"
    return
  fi

  if ! user_exists "$user"; then
    echo "User $user does not exist on system, skipping."
    return
  fi

  echo "Locking user: $user"
  usermod -e 1 "$user" || echo "Warning: failed to lock $user"

  local homedir
  homedir=$(eval echo "~$user")
  if [[ -d "$homedir" ]]; then
    echo "Removing home directory of $user: $homedir"
    rm -rf "$homedir"
  else
    echo "Home directory for $user not found, skipping removal"
  fi

  echo "Deleting user: $user"
  userdel "$user" || echo "Warning: failed to delete $user"
}

# Extract usernames from YAML category using yq
get_users_from_yaml() {
  local category=$1
  # This extracts all usernames under a given category, e.g. .users[].username
  yq e ".${category}[]?.username" "$USERS_YAML_FILE" 2>/dev/null || echo ""
}

main() {
  for category in "${GROUP_KEYS[@]}"; do
    echo "Processing category: $category"
    mapfile -t yaml_users < <(get_users_from_yaml "$category")

    for user in "${yaml_users[@]}"; do
      lock_and_delete_user "$user"
    done
  done
  echo "deleteusers.sh completed."
}

main

#!/usr/bin/env bash
# initusers.sh - user/group creation script without associative arrays

set -euo pipefail
IFS=$'\n\t'

USERS_YAML_FILE="../users.yaml"

# Use indexed arrays instead of associative arrays
GROUP_KEYS=("users" "authors" "mods" "admins")
GROUP_NAMES=("g_user" "g_author" "g_mod" "g_admin")
BASEDIRS=("/home/users" "/home/authors" "/home/mods" "/home/admin")

# Helper: get group name by category
get_group() {
  local cat=$1
  for i in "${!GROUP_KEYS[@]}"; do
    if [[ "${GROUP_KEYS[$i]}" == "$cat" ]]; then
      echo "${GROUP_NAMES[$i]}"
      return
    fi
  done
  echo ""
}

# Helper: get base dir by category
get_basedir() {
  local cat=$1
  for i in "${!GROUP_KEYS[@]}"; do
    if [[ "${GROUP_KEYS[$i]}" == "$cat" ]]; then
      echo "${BASEDIRS[$i]}"
      return
    fi
  done
  echo ""
}

# Create groups if missing
for grp in "${GROUP_NAMES[@]}"; do
  if ! getent group "$grp" >/dev/null 2>&1; then
    groupadd "$grp"
  fi
done

create_user() {
  local category=$1
  local username=$2
  local fullname=$3
  local group
  local homedir

  group=$(get_group "$category")
  homedir="$(get_basedir "$category")/$username"

  if id "$username" &>/dev/null; then
    # Unlock if locked
    usermod -e -1 "$username" || true
  else
    useradd -m -d "$homedir" -c "$fullname" -G "$group" "$username"
  fi
}

setup_home_dir() {
  local category=$1
  local username=$2
  local homedir
  homedir="$(get_basedir "$category")/$username"
  mkdir -p "$homedir"
  chown "$username:$username" "$homedir"

  case "$category" in
    users|authors)
      chmod 700 "$homedir"
      ;;
    mods)
      chmod 750 "$homedir"
      ;;
    admins)
      chmod 700 "$homedir"
      ;;
  esac
}

setup_authors_dirs() {
  local username=$1
  local homedir
  homedir="$(get_basedir "authors")/$username"
  mkdir -p "$homedir/blogs" "$homedir/public"
  chown -R "$username:$username" "$homedir/blogs" "$homedir/public"
  chmod 700 "$homedir/blogs"
  chmod 755 "$homedir/public"
}

lock_user() {
  local username=$1
  # Avoid locking root or harishannavisamy
  if [[ "$username" == "root" || "$username" == "harishannavisamy" ]]; then
    echo "Skipping lock for $username"
    return
  fi
  usermod -e 1 "$username" || true
  echo "Locked user $username"
}

grant_admin_access() {
  local admin_user=$1

  # Add admin user to all groups to grant access
  for grp in "${GROUP_NAMES[@]}"; do
    usermod -aG "$grp" "$admin_user" || true
  done

  # Set ACLs so admin_user has full access to all home directories
  for path in /home/users /home/authors /home/mods /home/admin; do
    setfacl -R -m u:"$admin_user":rwx "$path" || true
  done
}

clear_symlinks() {
  local dir=$1
  find "$dir" -maxdepth 1 -type l -exec rm -f {} +
}

update_mod_symlinks() {
  local mod_user=$1
  shift
  local authors=("$@")
  local mod_dir
  mod_dir="$(get_basedir "mods")/$mod_user"
  mkdir -p "$mod_dir"
  chown "$mod_user:$mod_user" "$mod_dir"

  clear_symlinks "$mod_dir"

  for author in "${authors[@]}"; do
    local target
    target="$(get_basedir "authors")/$author/public"
    if [[ -d "$target" ]]; then
      ln -s "$target" "$mod_dir/$author"
      setfacl -m g:g_mod:rwx "$target"
      setfacl -d -m g:g_mod:rwx "$target"
    fi
  done
  chown -R "$mod_user:$mod_user" "$mod_dir"
}

setup_users_all_blogs() {
  local user=$1
  local user_dir
  user_dir="$(get_basedir "users")/$user"
  local all_blogs="${user_dir}/all_blogs"
  mkdir -p "$all_blogs"
  chown "$user:$user" "$all_blogs"
  clear_symlinks "$all_blogs"

  for author_dir in "$(get_basedir "authors")"/*; do
    author=$(basename "$author_dir")
    public_dir="$author_dir/public"
    if [[ -d "$public_dir" ]]; then
      ln -s "$public_dir" "$all_blogs/$author"
      setfacl -m u:"$user":r-x "$public_dir"
      setfacl -d -m u:"$user":r-x "$public_dir"
    fi
  done

  chown -R "$user:$user" "$all_blogs"
}

get_usernames() {
  local category=$1
  yq e ".${category}[] | .username" "$USERS_YAML_FILE" 2>/dev/null || echo ""
}

get_moderator_authors() {
  local moduser=$1
  yq e ".moderators[] | select(.username == \"$moduser\") | .authors[]" "$USERS_YAML_FILE" 2>/dev/null || echo ""
}

# Read existing users under home dirs
existing_users_users=()
existing_users_authors=()
existing_users_mods=()
existing_users_admins=()

read_existing_users() {
  local category=$1
  local basedir
  basedir="$(get_basedir "$category")"
  local arrname=$2

  local users=()
  if [[ -d "$basedir" ]]; then
    while IFS= read -r user; do
      users+=("$user")
    done < <(find "$basedir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' || true)
  fi

  # Set global array by name
  eval "$arrname=(\"\${users[@]}\")"
}

read_existing_users "users" existing_users_users
read_existing_users "authors" existing_users_authors
read_existing_users "mods" existing_users_mods
read_existing_users "admins" existing_users_admins

# Read YAML users into arrays
read_yaml_users() {
  local category=$1
  local arrname=$2
  local users=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    users+=("$line")
  done < <(get_usernames "$category")
  eval "$arrname=(\"\${users[@]}\")"
}

read_yaml_users "users" yaml_users_users
read_yaml_users "authors" yaml_users_authors
read_yaml_users "mods" yaml_users_mods
read_yaml_users "admins" yaml_users_admins

in_array() {
  local needle=$1
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

# Lock removed users/authors, skipping root and harishannavisamy
for cat in users authors; do
  existing_arr="existing_users_${cat}[@]"
  yaml_arr="yaml_users_${cat}[@]"
  for existing_user in "${!existing_arr}"; do
    if ! in_array "$existing_user" "${!yaml_arr}"; then
      lock_user "$existing_user"
    fi
  done
done

# Create/update users
for cat in users authors mods admins; do
  yaml_arr="yaml_users_${cat}[@]"
  for u in "${!yaml_arr}"; do
    [[ -z "$u" ]] && continue
    fullname=$(yq e ".${cat}[] | select(.username==\"$u\") | .name" "$USERS_YAML_FILE")
    create_user "$cat" "$u" "$fullname"
    setup_home_dir "$cat" "$u"
    if [[ "$cat" == "authors" ]]; then
      setup_authors_dirs "$u"
    fi
  done
done

# Setup mod symlinks
for mod_user in "${yaml_users_mods[@]}"; do
  mapfile -t assigned_authors < <(get_moderator_authors "$mod_user")
  update_mod_symlinks "$mod_user" "${assigned_authors[@]}"
done

# Setup users all_blogs
for user in "${yaml_users_users[@]}"; do
  setup_users_all_blogs "$user"
done

# Grant admin access
for admin in "${yaml_users_admins[@]}"; do
  grant_admin_access "$admin"
done

echo "initusers: completed successfully."
exit 0

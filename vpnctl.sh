#!/bin/bash

INTERFACE="wg0"

is_interface_enabled() {
  ip link show "$INTERFACE" >/dev/null 2>&1
}

is_kill_switch_enabled() {
  iptables -L OUTPUT -n | grep -q "Chain OUTPUT (policy DROP)"
}

enable_interface() {
  wg-quick up "$INTERFACE" >/dev/null 2>&1 || {
    echo "Error: Failed to enable VPN interface $INTERFACE" >&2
    return 1
  }
}

disable_interface() {
  wg-quick down "$INTERFACE" >/dev/null 2>&1 || {
    echo "Error: Failed to disable VPN interface $INTERFACE" >&2
    return 1
  }
}

enable_kill_switch() {
  iptables -F OUTPUT || return 1
  iptables -P OUTPUT DROP || return 1
  iptables -A OUTPUT -o lo -j ACCEPT || return 1
  iptables -A OUTPUT -o "$INTERFACE" -j ACCEPT || return 1
  iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || return 1
  iptables -A OUTPUT -o docker0 -j ACCEPT || return 1
  iptables -A OUTPUT -d 172.17.0.0/16 -j ACCEPT || return 1
}

disable_kill_switch() {
  iptables -F OUTPUT
  iptables -P OUTPUT ACCEPT
}

enable() {
  is_interface_enabled && disable_interface
  disable_kill_switch
  enable_interface || return 1
  sleep 2
  enable_kill_switch
}

disable() {
  is_interface_enabled && disable_interface
  disable_kill_switch
}

toggle() {
  if is_interface_enabled; then
    disable
  else
    enable
  fi
}

status() {
  if is_interface_enabled && is_kill_switch_enabled; then
    echo "enabled"
    return 0
  else
    echo "disabled"
    return 1
  fi
}

waybar() {
  if status >/dev/null; then
    echo "{\"text\": \" \", \"class\": \"active\", \"tooltip\": \"VPN Connected: $INTERFACE\"}"
  else
    echo "{\"text\": \" \", \"class\": \"inactive\", \"tooltip\": \"VPN Disconnected\"}"
  fi
}

install() {
  if [[ $EUID -ne 0 ]]; then
    echo "Error: The 'install' command must be run with sudo" >&2
    return 1
  fi

  local user
  user=$(logname 2>/dev/null || whoami) || {
    echo "Error: Could not determine current user" >&2
    return 1
  }

  local script_path="/usr/local/bin/vpnctl"
  cp "$0" "$script_path" || {
    echo "Error: Failed to copy script to $script_path" >&2
    return 1
  }
  chown root:root "$script_path" || {
    echo "Error: Failed to set ownership for $script_path" >&2
    return 1
  }
  chmod 755 "$script_path" || {
    echo "Error: Failed to set permissions for $script_path" >&2
    return 1
  }

  local sudoers_file="/etc/sudoers.d/vpnctl-$user"
  local tmp_file
  tmp_file=$(mktemp) || {
    echo "Error: Failed to create temporary file for sudoers" >&2
    return 1
  }

  echo "$user ALL=(ALL) NOPASSWD: $script_path" > "$tmp_file" || {
    echo "Error: Failed to write to temporary sudoers file" >&2
    rm -f "$tmp_file"
    return 1
  }

  if ! visudo -c -f "$tmp_file" >/dev/null 2>&1; then
    echo "Error: Invalid sudoers entry" >&2
    rm -f "$tmp_file"
    return 1
  fi

  mv "$tmp_file" "$sudoers_file" || {
    echo "Error: Failed to install sudoers file to $sudoers_file" >&2
    rm -f "$tmp_file"
    return 1
  }
  chmod 440 "$sudoers_file" || {
    echo "Error: Failed to set permissions for $sudoers_file" >&2
    return 1
  }

  echo "Installation successful: $script_path installed and sudoers configured for $user"
}

main() {
  case "$1" in
    enable|disable|toggle|status|waybar|install)
      "$1"
      ;;
    *)
      echo "Usage: $0 [enable|disable|toggle|status|waybar|install]" >&2
      return 1
      ;;
  esac
}

main "$@"

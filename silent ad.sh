#!/bin/bash
# ----------------------------------------
# Title: AD_JoinLitev5
# Description: Minimal AD bind with dynamic OU
# Author: Ish Morgan
# ----------------------------------------
set -euo pipefail

BAR="––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––"

ts() { /bin/date "+%Y-%m-%d %H:%M:%S"; }

log() {
  echo "[$(ts)] $*"
}

hdr() {
  echo "$BAR"
  echo "$*"
  echo "$BAR"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# ----------------------------
# Root check
# ----------------------------
if [[ "${EUID:-$(/usr/bin/id -u)}" -ne 0 ]]; then
  echo "Must be run as root (sudo)."
  exit 1
fi

# ----------------------------
# SETTINGS
# ----------------------------
DOMAIN="office.globalrelay.local"

# ----------------------------
# Computer name + location
# ----------------------------
RAWNAME=$(scutil --get ComputerName 2>/dev/null || hostname)

# Expecting names like: LMny-xxxx / LMva-xxxx / LMlo-xxxx
CODE=$(echo "$RAWNAME" | sed -E 's/^.*([a-z]{2})-.*/\1/')

case "$CODE" in
  ny) LOC="New York-Branch" ;;
  va) LOC="Vancouver-Branch" ;;
  lo) LOC="London-Branch" ;;
  *)  LOC="" ;; # Unknown → default Computers container
esac

# ----------------------------
# Build DC=... from DOMAIN
# ----------------------------
DC_STRING=""
IFS='.' read -r -a PARTS <<< "$DOMAIN"
for part in "${PARTS[@]}"; do
  [[ -z "$part" ]] && continue
  if [[ -n "$DC_STRING" ]]; then
    DC_STRING+=","
  fi
  DC_STRING+="DC=$part"
done

# ----------------------------
# Build OU DN (branch OU or default Computers)
# ----------------------------
if [[ -n "$LOC" ]]; then
  OU_PATH="/GR Computers/Workstations-New/Laptop/${LOC}/Non-Windows/Mac"
  STRIPPED=$(echo "$OU_PATH" | sed 's#^/##')
  OU_DN_BASE=$(echo "$STRIPPED" | awk -F'/' ' { for (i = NF; i >= 1; i--) { printf "OU=%s", $i; if (i > 1) printf "," } }')
  OU_DN="${OU_DN_BASE},${DC_STRING}"
  TARGET_DESC="Location OU"
else
  OU_PATH="(Default Computers container)"
  OU_DN="CN=Computers,${DC_STRING}"
  TARGET_DESC="Default Computers"
fi

# ----------------------------
# Print effective settings + environment (max debugging)
# ----------------------------
echo "$BAR"
echo " Simple AD Join – Preview"
echo "$BAR"
echo "Computer Name : $RAWNAME"
echo "Location Code : $CODE"
echo "Location      : ${LOC:-Unknown}"
echo "Target        : $TARGET_DESC"
echo "OU Path       : $OU_PATH"
echo "OU DN         : $OU_DN"
echo "Domain        : $DOMAIN"
echo "$BAR"

hdr "Debug: Runtime context"
log "User/UID     : $(/usr/bin/id -un) / $(/usr/bin/id -u)"
log "macOS        : $(/usr/bin/sw_vers -productName) $(/usr/bin/sw_vers -productVersion) ($( /usr/bin/sw_vers -buildVersion ))"
log "HostName     : $(/usr/sbin/scutil --get HostName 2>/dev/null || echo unset)"
log "LocalHostName: $(/usr/sbin/scutil --get LocalHostName 2>/dev/null || echo unset)"
log "ComputerName : $RAWNAME"
log "Time         : $(/bin/date)"
if have_cmd systemsetup; then
  log "NTP enabled  : $(/usr/sbin/systemsetup -getusingnetworktime 2>/dev/null | sed 's/^[[:space:]]*//')"
  log "NTP server   : $(/usr/sbin/systemsetup -getnetworktimeserver 2>/dev/null | sed 's/^[[:space:]]*//')"
fi

hdr "Debug: Current AD bind state (before)"
if /usr/sbin/dsconfigad -show >/dev/null 2>&1; then
  /usr/sbin/dsconfigad -show 2>&1 | sed 's/^/[dsconfigad -show] /'
else
  echo "[dsconfigad -show] (failed to run)"
fi

hdr "Debug: Network/DNS quick checks"
# Default route + active interface + IP
ACTIVE_IF=$(/sbin/route get default 2>/dev/null | awk '/interface:/ {print $2}' || true)
if [[ -n "${ACTIVE_IF:-}" ]]; then
  log "Default IF   : $ACTIVE_IF"
  IP_ADDR=$(/usr/sbin/ipconfig getifaddr "$ACTIVE_IF" 2>/dev/null || true)
  log "IP address   : ${IP_ADDR:-none}"
else
  log "Default IF   : (none)"
fi

# Domain SRV lookup (best indicator DNS is correct for AD binding)
if have_cmd host; then
  echo "[dns] host -t SRV _ldap._tcp.dc._msdcs.${DOMAIN}"
  host -t SRV "_ldap._tcp.dc._msdcs.${DOMAIN}" 2>&1 | sed 's/^/[dns] /' || true
  echo "[dns] host ${DOMAIN}"
  host "${DOMAIN}" 2>&1 | sed 's/^/[dns] /' || true
elif have_cmd dig; then
  echo "[dns] dig +short SRV _ldap._tcp.dc._msdcs.${DOMAIN}"
  dig +short SRV "_ldap._tcp.dc._msdcs.${DOMAIN}" 2>&1 | sed 's/^/[dns] /' || true
else
  log "DNS tools    : host/dig not found"
fi

# ----------------------------
# Credentials + Simple AD join (3 attempts)
# ----------------------------
hdr "Debug: Credentials source (WS1 variables)"
BIND_USER="${BIND_USER:-}"
BIND_PASS="${BIND_PASS:-}"

log "BIND_USER set: $([[ -n "${BIND_USER:-}" ]] && echo yes || echo no)"
log "BIND_PASS set: $([[ -n "${BIND_PASS:-}" ]] && echo yes || echo no)"
if [[ -n "${BIND_PASS:-}" ]]; then
  log "BIND_PASS len: ${#BIND_PASS}"
fi

if [[ -z "$BIND_USER" || -z "$BIND_PASS" ]]; then
  echo "Final Result: ⛔ Missing AD bind credentials"
  exit 1
fi

diagnose_bind_failure() {
  local msg="$1"

  echo "$BAR"
  echo " Debug: Likely failure reasons (pattern match)"
  echo "$BAR"

  if echo "$msg" | /usr/bin/grep -Eqi "Invalid credentials|invalid.*credential|authentication failed"; then
    echo "- Credentials rejected OR bind account lacks rights to join/move in target OU"
  fi
  if echo "$msg" | /usr/bin/grep -Eqi "No route to host|Network is down|cannot connect|Connection refused|timed out|timeout"; then
    echo "- Network path to AD/DCs failing (routing/firewall/VPN/DNS/port 389/636/88)"
  fi
  if echo "$msg" | /usr/bin/grep -Eqi "Node name wasn't found|Server not found|Unknown host|can't find|not available"; then
    echo "- DNS is wrong/missing for the AD domain (SRV records), or domain name mismatch"
  fi
  if echo "$msg" | /usr/bin/grep -Eqi "Clock skew|KDC|Kerberos|kinit|time"; then
    echo "- Time sync issue (Kerberos-related failures often show up as clock skew)"
  fi
  if echo "$msg" | /usr/bin/grep -Eqi "Computer account already exists|Bind to Existing"; then
    echo "- Existing computer object conflict; -force should auto-accept, but verify rights on the existing object"
  fi
  if echo "$msg" | /usr/bin/grep -Eqi "OU|ou=|invalid.*ou|No such object"; then
    echo "- OU DN invalid OR bind account lacks rights to create/move into that OU"
  fi
  echo "- Check: DNS SRV lookup output above (_ldap._tcp.dc._msdcs.${DOMAIN})"
  echo "- Check: AD object exists + permissions + replication state"
  echo "$BAR"
}

MAX_TRIES=3
attempt=1
JOIN_RC=1

hdr "Debug: AD bind attempts"
while (( attempt <= MAX_TRIES )); do
  log "Attempt $attempt/$MAX_TRIES"

  set +e
  DSOUT=$(
    /usr/sbin/dsconfigad -add "$DOMAIN" \
      -computer "$RAWNAME" \
      -username "$BIND_USER" \
      -password "$BIND_PASS" \
      -ou "$OU_DN" \
      -force 2>&1
  )
  JOIN_RC=$?
  set -e

  echo "$DSOUT" | sed 's/^/[dsconfigad] /'
  log "dsconfigad rc : $JOIN_RC"

  if [[ $JOIN_RC -eq 0 ]]; then
    log "Bind command returned success"
    break
  fi

  diagnose_bind_failure "$DSOUT"
  ((attempt++))
done

# ----------------------------
# Disable network users at login window
# ----------------------------
hdr "Debug: Disable network users at login window"
set +e
/usr/bin/defaults write /Library/Preferences/com.apple.loginwindow EnableExternalAccounts -bool false 2>&1 | sed 's/^/[defaults] /'
DEF_RC=$?
set -e
log "defaults rc   : $DEF_RC"

# ----------------------------
# Final Result (verify bind + show readable OU path)
# ----------------------------
hdr "Debug: Post-bind state"
POST_SHOW=$(/usr/sbin/dsconfigad -show 2>&1 || true)
echo "$POST_SHOW" | sed 's/^/[dsconfigad -show] /'

if echo "$POST_SHOW" | /usr/bin/grep -qi "Active Directory Domain"; then
  # Convert DN -> readable path (OU=... reversed, DC=... => domain)
  READABLE_PATH=$(
    echo "$OU_DN" | /usr/bin/awk -F',' '
      {
        for (i=1; i<=NF; i++) {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
          if ($i ~ /^OU=/) { ou[++n_ou]=substr($i,4) }
          else if ($i ~ /^DC=/) { dc[++n_dc]=substr($i,4) }
        }
        # Print /OU1/OU2/... (reverse OU order) + (domain)
        printf "/"
        for (i=n_ou; i>=1; i--) {
          printf "%s", ou[i]
          if (i>1) printf "/"
        }
        printf "  ("
        for (i=1; i<=n_dc; i++) {
          printf "%s", dc[i]
          if (i<n_dc) printf "."
        }
        printf ")"
      }'
  )
  echo "Final Result: ✅ Device is AD Joined - $READABLE_PATH"
else
  echo "Final Result: ⛔ Device couldn't be AD Joined"
fi

echo "$BAR"
echo "AD join successful:"
echo "  Computer : $RAWNAME"
echo "  Domain   : $DOMAIN"
echo "  OU DN    : $OU_DN"
echo "$BAR"

exit 0
```0
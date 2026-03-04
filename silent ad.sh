#!/bin/bash
# ----------------------------------------
# Title: AD_JoinLitev5
# Description: Minimal AD bind with dynamic OU
# Author: Ish Morgan
# ----------------------------------------
set -euo pipefail

BAR="––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––"

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
# Print effective settings
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

# ----------------------------
# Credentials + Simple AD join (3 attempts)
# ----------------------------
BIND_USER="${BIND_USER:-}"
BIND_PASS="${BIND_PASS:-}"

if [[ -z "$BIND_USER" || -z "$BIND_PASS" ]]; then
  echo "Final Result: ⛔ Missing AD bind credentials"
  exit 1
fi

MAX_TRIES=3
attempt=1
JOIN_RC=1

while (( attempt <= MAX_TRIES )); do
  set +e
  printf 'y\n' | /usr/sbin/dsconfigad -add "$DOMAIN" \
    -computer "$RAWNAME" \
    -username "$BIND_USER" \
    -password "$BIND_PASS" \
    -ou "$OU_DN"
  JOIN_RC=$?
  set -e

  [[ $JOIN_RC -eq 0 ]] && break
  ((attempt++))
done

# ----------------------------
# Disable network users at login window
# ----------------------------
/usr/bin/defaults write /Library/Preferences/com.apple.loginwindow EnableExternalAccounts -bool false

# ----------------------------
# Final Result (verify bind + show readable OU path)
# ----------------------------
if /usr/sbin/dsconfigad -show 2>/dev/null | /usr/bin/grep -qi "Active Directory Domain"; then
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
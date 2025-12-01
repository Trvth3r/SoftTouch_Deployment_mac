#!/bin/bash
# -------------------------------------------------------------------
# Script Title  : Disable Apple Intelligence (arm64) + Siri (Intel & arm64)
# Description   : Pre-MDM. On Intel, disable Siri via user prefs.
#                 On Apple Silicon, also slam Apple Intelligence keys
#                 in com.apple.applicationaccess.
# Author        : ish morgan
# -------------------------------------------------------------------

arch=$(uname -m)
echo "Detected architecture: ${arch}"

ai_domain="com.apple.applicationaccess"
assistant_domain="com.apple.assistant.support"
siri_domain="com.apple.Siri"

# Siri-related keys (user prefs)
siri_keys=(
  "Assistant Enabled:${assistant_domain}"
  "StatusMenuVisible:${siri_domain}"
  "UserHasDeclinedEnable:${siri_domain}"
)

########################################
# SECTION: Siri disable (Intel & arm64)
########################################

echo "=== Siri BEFORE → AFTER (current user) ==="

for entry in "${siri_keys[@]}"; do
  key="${entry%%:*}"
  domain="${entry##*:}"

  before=$(defaults read "${domain}" "${key}" 2>/dev/null || echo "not set")

  case "${key}" in
    "Assistant Enabled")
      defaults write "${domain}" "${key}" -bool false
      ;;
    "StatusMenuVisible")
      defaults write "${domain}" "${key}" -bool false
      ;;
    "UserHasDeclinedEnable")
      defaults write "${domain}" "${key}" -bool true
      ;;
  esac
done

# Kill cfprefsd for current user so Siri sees the changes
killall -u "$(whoami)" cfprefsd 2>/dev/null || true
sleep 2

for entry in "${siri_keys[@]}"; do
  key="${entry%%:*}"
  domain="${entry##*:}"

  after=$(defaults read "${domain}" "${key}" 2>/dev/null || echo "not set")
  echo "${domain}.${key}: ${before} -> ${after}"
done

# Also mark Siri setup as already seen to suppress first-run prompt
defaults write com.apple.SetupAssistant DidSeeSiriSetup -bool TRUE

########################################
# SECTION: Apple Intelligence (arm64 only)
########################################

if [[ "${arch}" != "arm64" ]]; then
  echo "Non-Apple Silicon detected – Apple Intelligence keys not present. Siri disabled for this user."
  echo "Done. (author – ish morgan)"
  exit 0
fi

echo "Apple Silicon detected – applying Apple Intelligence restrictions."

ai_keys=(
  "allowGenmoji"
  "allowImagePlayground"
  "allowWritingTools"
  "allowMailSummary"
  "allowExternalIntelligenceIntegrations"
  "allowExternalIntelligenceIntegrationsSignIn"
  "allowedExternalIntelligenceWorkspaceIDs"
  "allowSafariSummary"
  "allowNotesTranscriptionSummary"
  "allowMailSmartReplies"
  "allowAppleIntelligenceReport"
  "allowNotesTranscription"
  "allowAssistant"
)

echo "=== Apple Intelligence BEFORE → AFTER (com.apple.applicationaccess as root) ==="

for key in "${ai_keys[@]}"; do
  before=$(defaults read "${ai_domain}" "${key}" 2>/dev/null || echo "not set")

  case "${key}" in
    "allowedExternalIntelligenceWorkspaceIDs")
      sudo defaults write "${ai_domain}" "${key}" -array
      ;;
    *)
      sudo defaults write "${ai_domain}" "${key}" -bool false
      ;;
  esac

  sudo killall -u "$(whoami)" cfprefsd 2>/dev/null || true
  sleep 1

  after=$(defaults read "${ai_domain}" "${key}" 2>/dev/null || echo "not set")
  echo "${ai_domain}.${key}: ${before} -> ${after}"
done

echo "Done."

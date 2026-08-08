#!/usr/bin/env bash

# Shared signing selection for local builds. WidgetKit extensions need a real
# team identity to be discoverable in the macOS widget picker; ad-hoc signing
# is kept as an explicit fallback for machines without a development cert.

codexmeter_select_signing() {
  CODEX_SIGNING_MODE="${SIGNING_MODE:-auto}"
  CODEX_SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:-}"
  CODEX_DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
  local identity_line=""
  local certificate_name=""

  if [[ "$CODEX_SIGNING_MODE" == "adhoc" ]]; then
    CODEX_SIGNING_IDENTITY=""
    CODEX_DEVELOPMENT_TEAM=""
  elif [[ -z "$CODEX_SIGNING_IDENTITY" ]]; then
    identity_line="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development:/ { print; exit }')"
    if [[ -n "$identity_line" ]]; then
      CODEX_SIGNING_IDENTITY="$(printf '%s\n' "$identity_line" | sed -n 's/.* \([A-Fa-f0-9]\{40\}\) ".*/\1/p')"
    fi
  fi

  if [[ -z "$CODEX_DEVELOPMENT_TEAM" && -n "$CODEX_SIGNING_IDENTITY" ]]; then
    if [[ -z "$identity_line" ]]; then
      identity_line="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -v identity="$CODEX_SIGNING_IDENTITY" '$2 == identity || index($0, "\"" identity "\"") { print; exit }')"
    fi
    certificate_name="$(printf '%s\n' "$identity_line" | sed -n 's/.*"\(.*\)"/\1/p')"
    if [[ -n "$certificate_name" ]]; then
      CODEX_DEVELOPMENT_TEAM="$(security find-certificate -a -c "$certificate_name" -p 2>/dev/null \
        | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null \
        | sed -n 's/.*OU=\([^,]*\).*/\1/p')"
    fi
  fi

  if [[ -n "$CODEX_SIGNING_IDENTITY" && -n "$CODEX_DEVELOPMENT_TEAM" ]]; then
    CODEX_SIGNING_MODE="development"
    CODEX_XCODE_SIGNING_ARGS=(
      CODE_SIGNING_ALLOWED=YES
      CODE_SIGNING_REQUIRED=YES
      CODE_SIGN_STYLE=Manual
      CODE_SIGN_IDENTITY="$CODEX_SIGNING_IDENTITY"
      DEVELOPMENT_TEAM="$CODEX_DEVELOPMENT_TEAM"
    )
    echo "Using Apple Development signing for team $CODEX_DEVELOPMENT_TEAM."
  else
    CODEX_SIGNING_MODE="adhoc"
    CODEX_XCODE_SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO)
    echo "No Apple Development certificate found; using ad-hoc signing. WidgetKit may not appear in the macOS picker." >&2
  fi
}

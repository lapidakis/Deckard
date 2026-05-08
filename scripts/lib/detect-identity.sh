#!/usr/bin/env bash
# Resolves a codesigning identity for use by scripts/codesign.sh and
# scripts/build-ui-app.sh.
#
# Resolution order:
#   1. $ICB_SIGN_IDENTITY (explicit override — used as-is, no validation)
#   2. The first "Developer ID Application:" identity in the user's
#      keychain. Lets a contributor with their own Developer ID build
#      without setting any env var, while keeping the original maintainer's
#      cert from being baked into the repo.
#   3. "-" (adhoc). Build still produces a runnable binary; TCC grants
#      will need to be re-approved on every rebuild because adhoc has no
#      stable signing identity. A loud warning goes to stderr.
#
# Source this file from another script:
#   . "$(dirname "$0")/lib/detect-identity.sh"
#   detect_identity                 # populates $ICB_RESOLVED_IDENTITY
#                                   # and $ICB_RESOLVED_IDENTITY_KIND
#                                   #   ∈ {explicit, detected, adhoc}

detect_identity() {
    if [ -n "${ICB_SIGN_IDENTITY:-}" ]; then
        ICB_RESOLVED_IDENTITY="$ICB_SIGN_IDENTITY"
        ICB_RESOLVED_IDENTITY_KIND="explicit"
        return 0
    fi

    # `security find-identity -v -p codesigning` lists valid codesigning
    # identities; grep for Developer ID Application; awk-strip the
    # quoted CN. -p filters by purpose so we don't accidentally pick
    # an installer cert.
    local detected
    detected=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Developer ID Application:" \
        | head -n 1 \
        | sed -E 's/.*"(Developer ID Application:[^"]*)".*/\1/')

    if [ -n "$detected" ]; then
        ICB_RESOLVED_IDENTITY="$detected"
        ICB_RESOLVED_IDENTITY_KIND="detected"
        return 0
    fi

    ICB_RESOLVED_IDENTITY="-"
    ICB_RESOLVED_IDENTITY_KIND="adhoc"
    return 0
}

# Print a short banner about which identity is being used. Callers
# invoke this after `detect_identity` so the build log makes the
# resolution explicit.
print_identity_banner() {
    case "${ICB_RESOLVED_IDENTITY_KIND:-}" in
        explicit)
            echo "codesign: using explicit ICB_SIGN_IDENTITY: $ICB_RESOLVED_IDENTITY"
            ;;
        detected)
            echo "codesign: using detected Developer ID identity: $ICB_RESOLVED_IDENTITY"
            ;;
        adhoc)
            echo "codesign: WARNING — no Developer ID Application identity available; adhoc-signing." >&2
            echo "codesign:   This produces a runnable binary, but TCC grants (Mail / Calendar / Reminders / Automation)" >&2
            echo "codesign:   will need to be re-approved on every rebuild because adhoc has no stable identity." >&2
            echo "codesign:   To fix: install a Developer ID Application certificate, OR set ICB_SIGN_IDENTITY=<name>" >&2
            ;;
    esac
}

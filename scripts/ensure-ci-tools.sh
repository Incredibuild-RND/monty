#!/usr/bin/env bash
# Bootstrap baseline tools on lean self-hosted runners (e.g. Incredibuild
# Hosted Build Runner) where ubuntu-latest preinstalled tooling like
# `sudo`, `wget`, `curl` may be missing. No-op when tools are already
# present, so safe to call from GitHub-hosted runners too.

set -euo pipefail

is_root() { [ "$(id -u)" = "0" ]; }

apt_install() {
    if is_root; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
    else
        sudo apt-get update -qq
        DEBIAN_FRONTEND=noninteractive sudo apt-get install -y --no-install-recommends "$@"
    fi
}

# Provide a no-op `sudo` shim when running as root and sudo is missing,
# so existing `sudo X` calls in scripts/workflows just exec X.
if is_root && ! command -v sudo >/dev/null 2>&1; then
    cat > /usr/local/bin/sudo <<'EOF'
#!/bin/sh
exec "$@"
EOF
    chmod +x /usr/local/bin/sudo
    echo "ensure-ci-tools: installed no-op sudo shim"
fi

missing=()
for tool in wget curl unzip; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing+=("$tool")
    fi
done
# Always ensure ca-certificates if we're going to install anything else
if [ "${#missing[@]}" -gt 0 ]; then
    missing+=(ca-certificates)
    apt_install "${missing[@]}"
    echo "ensure-ci-tools: installed ${missing[*]}"
else
    echo "ensure-ci-tools: nothing to install"
fi

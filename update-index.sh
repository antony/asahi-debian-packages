#!/bin/sh
# Regenerate the apt index (Packages, Packages.gz, Release) from the
# .deb files in repo/. Run this after adding, updating or removing a
# .deb. Needs dpkg-scanpackages (from the dpkg-dev package).
set -eu

cd "$(dirname "$0")/repo"

dpkg-scanpackages --multiversion . > Packages
gzip -9nc Packages > Packages.gz

checksums() {
    # $1 = Release field name, $2 = checksum command
    echo "$1:"
    for f in Packages Packages.gz; do
        printf ' %s %s %s\n' \
            "$($2 "$f" | cut -d' ' -f1)" \
            "$(wc -c < "$f" | tr -d ' ')" \
            "$f"
    done
}

{
    cat <<EOF
Origin: asahi-debian-packages
Label: asahi-debian-packages
Suite: local
Codename: local
Architectures: all arm64 amd64
Date: $(date -Ru)
Description: Locally built Debian packages
EOF
    checksums MD5Sum md5sum
    checksums SHA1 sha1sum
    checksums SHA256 sha256sum
} > Release

echo "Indexed $(grep -c '^Package:' Packages) package(s):"
grep -E '^(Package|Version):' Packages | paste - - | sed 's/^/  /'

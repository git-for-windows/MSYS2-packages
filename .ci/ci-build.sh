#!/bin/bash

set -e

# GitHub workflow for Git for Windows' Continuous Integration
# Author: Renato Silva <br.renatosilva@gmail.com>
# Author: Qian Hong <fracting@gmail.com>
# Author: Johannes Schindelin <johannes.schindelin@gmx.de>

DIR="$( cd "$( dirname "$0" )" && pwd )"

# Configure
source "$DIR/ci-library.sh"
mkdir artifacts
git_config user.email 'ci@github'
git_config user.name  'Git for Windows Continuous Integration'
git remote add upstream 'https://github.com/git-for-windows/MSYS2-packages'
git fetch --quiet upstream
# reduce time required to install packages by disabling pacman's disk space checking
sed -i 's/^CheckSpace/#CheckSpace/g' /etc/pacman.conf

pacman --noconfirm -Fy

# Detect
list_commits  || failure 'Could not detect added commits'
list_packages || failure 'Could not detect changed files'
message 'Processing changes' "${commits[@]}"
test -z "${packages}" && success 'No changes in package recipes'
define_build_order || failure 'Could not determine build order'

# Build
message 'Building packages' "${packages[@]}"
execute 'Approving recipe quality' check_recipe_quality

message 'Building packages'
for package in "${packages[@]}"; do
    test msys2-runtime-3.3 != "${package}" || {
        echo "Skipping ${package}: we only need to build this for i686" >&2
        continue
    }

    echo "::group::[build] ${package}"
    execute 'Fetch keys' "$DIR/fetch-validpgpkeys.sh"
    execute 'Building binary' makepkg --noconfirm --noprogressbar --check --syncdeps --rmdeps --cleanbuild
    execute 'Building source' makepkg --noconfirm --noprogressbar --allsource
    echo "::endgroup::"

    echo "::group::[install] ${package}"
    grep -qFx "${package}" "$(dirname "$0")/ci-dont-install-list.txt" || execute 'Installing' yes:pacman --noprogressbar --upgrade '*.pkg.tar.*'
    echo "::endgroup::"

    echo "::group::[diff] ${package}"
    cd "$package"
    for pkg in *.pkg.tar.*; do
        message "File listing diff for ${pkg}"
        pkgname="$(echo "$pkg" | rev | cut -d- -f4- | rev)"
        diff -Nur <(pacman -Fl "$pkgname" | sed -e 's|^[^ ]* |/|' | sort) <(pacman -Ql "$pkgname" | sed -e 's|^[^/]*||' | sort) || true
    done
    cd - > /dev/null
    echo "::endgroup::"

    echo "::group::[dll check] ${package}"
    execute 'Checking dll depencencies' list_dll_deps ./pkg
    execute 'Checking dll bases' list_dll_bases ./pkg
    echo "::endgroup::"

    mv "${package}"/*.pkg.tar.* artifacts
    mv "${package}"/*.src.tar.* artifacts
    unset package
done
success 'All packages built successfully'

cd artifacts
execute 'SHA-256 checksums' sha256sum *

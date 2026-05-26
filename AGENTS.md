# Agent Instructions for MSYS2-packages (Git for Windows fork)

This is Git for Windows' fork of the MSYS2 package recipes
(upstream: https://github.com/msys2/MSYS2-packages). Most packages
are consumed directly from upstream MSYS2. Git for Windows
maintains its own builds of only the packages listed below,
publishing them to the `git-for-windows/pacman-repo` repository
where they shadow MSYS2's upstream versions.

MSYS2 has two classes of packages: MSYS packages (which depend on
the MSYS2 runtime, `msys-2.0.dll`, a Cygwin fork) and MINGW
packages (which produce native Win32/Win64 binaries with no MSYS2
runtime dependency). This repository contains MSYS packages. The
build tool is `makepkg` (not `makepkg-mingw`, which is used for
MINGW packages).

When contributing changes, keep in mind that the MSYS2 project has
its own conventions and review process. Changes to packages that
are not specific to Git for Windows should ideally be contributed
upstream to `msys2/MSYS2-packages` first.

## Building packages

MSYS builds need the MSYS toolchain on PATH, with `MSYSTEM` set to
`MSYS`. In PowerShell:

    $env:MSYSTEM = "MSYS"
    $env:PATH = "<MSYS-root>\usr\bin;$env:PATH"
    $env:HOME = $env:USERPROFILE
    bash -c "cd /path/to/package && makepkg -s 2>&1"

Do not use `bash -l` or `bash --login`; login shells may hang in
Git for Windows SDK environments.

Use `makepkg -s` to install missing dependencies automatically.
Use `--nocheck` to skip the test suite, `--cleanbuild` to force a
clean rebuild, and `--skippgpcheck` to skip GPG signature
verification. Use `makepkg -o` (extract and prepare only) to
validate that patches apply cleanly without waiting for a full
compile.

When a package uses git sources, `updpkgsums` must be run with
`core.autoCRLF=false` in the Git configuration. Otherwise the
generated `.tar` archive is checksummed with CRLF line endings
and CI (which uses LF) will fail the validity check. Since
`updpkgsums` is not a Git command, `git -c core.autoCRLF=false`
cannot be used. Instead, set the environment variable in
PowerShell before invoking bash:

    $env:GIT_CONFIG_PARAMETERS = "'core.autoCRLF=false'"
    bash -c "cd /path/to/package && updpkgsums"

## Git for Windows package landscape

The full list of MSYS packages that Git for Windows currently
shadows can be inspected at
https://github.com/git-for-windows/pacman-repo/tree/x86_64/ (and
the `i686` branch for 32-bit). As of April 2026, these MSYS
packages (grouped with their sub-packages) are built from this
fork:

- `bash` (+ `bash-devel`)
- `curl` (+ `libcurl`, `libcurl-devel`)
- `gnutls` (+ `libgnutls`, `libgnutls-devel`)
- `heimdal` (+ `heimdal-devel`, `heimdal-libs`)
- `libcbor` (+ `libcbor-devel`)
- `libfido2` (+ `libfido2-devel`, `libfido2-docs`, `fido2-tools`)
- `mintty`
- `msys2-runtime` (+ `msys2-runtime-devel`, `msys2-runtime-3.3`)
- `openssh`
- `openssl` (+ `libopenssl`, `openssl-devel`, `openssl-docs`)
- `pcre2` (+ `libpcre2_8`, `libpcre2_16`, `libpcre2_32`,
  `libpcre2posix`, `pcre2-devel`)
- `pkgconf`

In addition, two Git for Windows-specific packages (`git-extra`,
`git-for-windows-keyring`) and several `mingw-w64-*` packages
(built from the separate `MINGW-packages` repository) are
published there.

### Packages that have been unshadowed

An ongoing effort tracked in
https://github.com/git-for-windows/git/issues/5395 is reducing
the number of packages that Git for Windows builds from this fork.
The following have already been unshadowed (i.e. Git for Windows
now uses MSYS2's upstream versions):

- `perl`, `subversion`, and all `perl-*` packages (March 2026;
  `git svn` was confirmed to work with vanilla MSYS2's
  Perl/Subversion)
- `gawk` (August 2025; verified not to regress
  git-for-windows/git#1524)
- `gnupg`, `libgcrypt`, `libgpg-error` (and their `-devel`
  sub-packages)
- `mingw-w64-pcre2`, `mingw-w64-connect`, `mingw-w64-nodejs`
- `mingw-w64-asciidoctor-extensions`
- `p7zip` (replaced by `mingw-w64-7zip`)
- `tig`, `git-flow`

Some of the remaining shadowed packages are candidates for
removal too; see the issue for current status.

### The 32-bit (i686) build

Git for Windows still provides a 32-bit MinGit package, which is
required by Visual Studio's built-in Git support until at least
2029. The 32-bit build covers only the MinGit subset, which is
far smaller than the full Git for Windows installer package set.
The i686 packages live in the `i686` branch of `pacman-repo`.

## Perl $^O on Git for Windows

Git for Windows recently stopped building its own Perl and now uses
the MSYS2 version. Because MSYS2's runtime is a Cygwin fork,
`/usr/bin/perl` reports `$^O` as `cygwin`, not `msys`. Any test
skip guard that checks for `msys` (e.g. `skip if $^O =~ /msys/`)
must also check for `cygwin`, or it will stop firing and the test
will run unexpectedly.

This is particularly dangerous for tests that open listening sockets
(OCSP responders, HTTP servers, TFO listeners), because Windows
Firewall will prompt for permission. On interactive machines this
causes a modal dialog; on CI agents there is nobody to click
"Allow", so the test hangs until the job times out.

## The playground repository

When upgrading a package to a new version, patches often fail to
apply because the upstream context has changed. Rather than hand-
editing hunks, create a standalone Git repository at `src/playground`
inside the package directory and use it to rebase the patches:

1. Import the old upstream tarball with Git's
   `contrib/fast-import/import-tars.perl` (run via
   `<MSYS-root>\usr\bin\perl`; the script can be downloaded from
   https://github.com/git/git/blob/HEAD/contrib/fast-import/import-tars.perl).
2. Apply the existing `.patch` files as individual commits using
   `git am`. For patch files that lack a `git am`-format header,
   start `git am` with a properly formatted copy to capture
   authorship and subject, then when it fails (because the diff
   content is stale), apply the correct patch via `patch -p1`,
   `git add -A`, and `git am --continue`. Check for stray `.orig`
   files and remove them before or as part of the amend.
   (`--committer-date-is-author-date` is not needed; step 5 forces
   committer=author via fast-export/fast-import regardless, and
   that pipeline is unavoidable because `import-tars.perl` already
   produces mismatched committer/author metadata.)
3. Import the new upstream tarball into the same repo.
4. `git rebase --onto <new-tag> <old-tag> <branch>` to replay the
   patches onto the new version. Resolve conflicts.
5. Before exporting, verify that committer matches author in every
   commit (see "Stable commit OIDs" below for why this matters):

       git log --format='%aN <%aE> %ai%n%cN <%cE> %ci' HEAD | uniq -u

   If this produces any output, there is a mismatch. Fix with:

       git fast-export --no-data HEAD | \
         awk '/^author /{a=$0} /^committer /{$0="committer " substr(a,8)} 1' | \
         git fast-import --force --quiet

   Use `HEAD` (not a range like `<base-tag>..HEAD`) to avoid
   disconnecting the first commit from its parent.
6. `git format-patch --no-signature -o ../.. <base-tag>` to export
   back to the PKGBUILD directory.
7. Verify the round-trip: re-export `format-patch` from the
   playground and `git diff -I'^@@'` against the originals. Only
   commit OIDs, index lines, and `@@` offsets should differ.

`patch -p1` supports fuzz matching that `git apply` does not. When
`git am` or `git apply` fails on context lines, fall back to
`patch -p1` and stage the result.

Keep the playground around for the duration of the upgrade work. New
fixes and patch adjustments are committed here, then re-exported with
`git format-patch --no-signature -o ../.. <base-tag>`. Deleting and
recreating it means re-importing tarballs, re-applying all patches,
and re-resolving any conflicts from scratch.

When an existing patch needs updating (e.g. a patch that introduces
MSYS-specific handling needs to cover a new platform variant), amend
the original commit in the playground rather than layering a new
patch on top. Use `amend!` commits and
`git rebase -i --autosquash` to fold the fix into the right commit,
then re-export all patches. This keeps the patch series clean and
makes the intent of each patch self-contained.

### Stable commit OIDs for reproducible patches

The `.patch` files shipped in the PKGBUILD are `git format-patch`
output. Each file's first line is `From <commit-OID> ...`, and
`updpkgsums` hashes the entire file, so the OID is baked into the
`sha256sums` array. If a different person re-exports the same logical
patches but produces different OIDs, the checksums will not match and
the build will fail.

A Git commit OID is a hash over the tree, parent, author (name,
email, timestamp), committer (name, email, timestamp), and message.
The tree and parent are fixed by the content and import order. The
author identity and date come from the patch itself (preserved by
`git am --committer-date-is-author-date`). But the committer identity
defaults to whoever runs the command, and the committer date defaults
to "now". This means that without intervention, every person who
re-exports the patches gets different OIDs.

The fix is to force the committer to match the author in every
playground commit. The `fast-export | awk | fast-import` pipeline
from step 5 handles this in one pass (both name/email and
timestamps). This pipeline is not optional: `import-tars.perl`
already produces commits where committer and author metadata
differ, so the fixup is needed regardless of what flags are passed
to `git am` or `git rebase`. After any operation that creates
commits (import, rebase, amend, cherry-pick), re-run the mismatch
check and pipeline. Once committer=author holds for every commit,
the OIDs are deterministic: anyone who imports the same tarball,
applies the same patches, and enforces this invariant will arrive
at identical OIDs and therefore identical `sha256sums`.

## General workflow

Use `git worktree add` with sparse checkout for testing dependent
packages. Commit fixes in the worktree and `git cherry-pick` them
into the main branch rather than copying files manually.

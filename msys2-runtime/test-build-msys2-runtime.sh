#!/usr/bin/env bash

set -euo pipefail

usage () {
	cat <<-EOF
	usage: $0 [--source-dir <dir>] [--build-dir <dir>] [--full]
	          [--reconfigure] [-j <jobs>]

	Configure and test-build the MSYS2 runtime without deleting any existing
	build tree.  The default source is src/msys2-runtime next to this script.
	The default target is new-msys-2.0.dll.  --full continues with the
	complete build after the runtime DLL succeeds.  --reconfigure forces
	autogen and configure even when the cached configuration matches.
	EOF
}

summarize_output () {
	sed -n \
		-e '/warning:/p' \
		-e '/error:/p' \
		-e '/\*\*\* \[/p' \
		-e '/new-msys-2\.0\.dll/p'
}

jobs=${JOBS:-$(nproc)}
source_dir=
build_dir=
full_build=
reconfigure=

while test $# -gt 0
do
	case "$1" in
	--source-dir)
		test $# -ge 2 || {
			echo "error: --source-dir requires a value" >&2
			exit 2
		}
		source_dir=$2
		shift 2
		;;
	--build-dir)
		test $# -ge 2 || {
			echo "error: --build-dir requires a value" >&2
			exit 2
		}
		build_dir=$2
		shift 2
		;;
	--full)
		full_build=t
		shift
		;;
	--reconfigure)
		reconfigure=t
		shift
		;;
	-j|--jobs)
		test $# -ge 2 || {
			echo "error: $1 requires a value" >&2
			exit 2
		}
		jobs=$2
		shift 2
		;;
	-j[0-9]*)
		jobs=${1#-j}
		shift
		;;
	-h|--help)
		usage
		exit 0
		;;
	*)
		echo "error: unknown option: $1" >&2
		usage >&2
		exit 2
		;;
	esac
done

case "$jobs" in
''|*[!0-9]*|0)
	echo "error: job count must be a positive integer: $jobs" >&2
	exit 2
	;;
esac

package_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
if test -z "$source_dir"
then
	source_dir=$package_dir/src/msys2-runtime
fi
test -d "$source_dir/winsup" || {
	echo "error: MSYS2 runtime source not found at $source_dir" >&2
	exit 1
}
source_dir=$(cd "$source_dir" && pwd -P)

# PowerShell may have inherited a MINGW64 environment.  Reset all related
# variables together; changing MSYSTEM alone leaves stale tool paths behind.
export MSYSTEM=MSYS
. /etc/msystem
export ACLOCAL_PATH=/usr/share/aclocal
export PATH=/usr/bin:/mingw64/bin:/mingw32/bin:$PATH

gcc=$(command -v gcc)
gcc_target=$(gcc -dumpmachine)
test "$gcc" = /usr/bin/gcc || {
	echo "error: expected /usr/bin/gcc, found $gcc" >&2
	exit 1
}
test "$gcc_target" = "$MSYSTEM_CHOST" || {
	echo "error: gcc targets $gcc_target, expected $MSYSTEM_CHOST" >&2
	exit 1
}

if test -z "$build_dir"
then
	build_dir="$(dirname "$source_dir")/build-test-$MSYSTEM_CHOST"
fi
mkdir -p "$build_dir/logs"
build_dir=$(cd "$build_dir" && pwd -P)

pkgver=$(sed -n 's/^pkgver=//p' "$package_dir/PKGBUILD")
test -n "$pkgver" || {
	echo "error: could not read pkgver from $package_dir/PKGBUILD" >&2
	exit 1
}

runtime_commit=$(git -C "$source_dir" rev-parse HEAD)
export CFLAGS="-O2 -pipe -ggdb -DCYGPORT_RELEASE_INFO=$pkgver"
export CXXFLAGS="-O2 -pipe -ggdb"

config_stamp=$build_dir/.test-build-config
config_key="$MSYSTEM_CHOST|$runtime_commit|$CFLAGS|$CXXFLAGS"
configure_needed=$reconfigure
autogen_needed=$reconfigure

if ! test -f "$build_dir/Makefile" || ! test -f "$config_stamp"
then
	configure_needed=t
	test -f "$build_dir/Makefile" || autogen_needed=t
else
	test "$(cat "$config_stamp")" = "$config_key" ||
		configure_needed=t

	build_system_change=$(find "$source_dir/winsup" -type f \
		\( -name configure.ac -o -name Makefile.am -o -name '*.m4' \) \
		-newer "$config_stamp" -print -quit)
	if test -n "$build_system_change"
	then
		autogen_needed=t
		configure_needed=t
	fi
	test "$source_dir/configure" -nt "$build_dir/Makefile" &&
		configure_needed=t
fi

timestamp=$(date +%Y%m%d-%H%M%S)
log=$build_dir/logs/build-$timestamp.log

echo "MSYSTEM=$MSYSTEM"
echo "MSYSTEM_CHOST=$MSYSTEM_CHOST"
echo "gcc=$gcc ($gcc_target)"
echo "source=$source_dir"
echo "build=$build_dir"
echo "log=$log"
if test -n "$configure_needed"
then
	echo "configuration=refresh"
else
	echo "configuration=reuse"
fi

{
	if test -n "$autogen_needed"
	then
		(
			cd "$source_dir/winsup"
			./autogen.sh
		)
	fi

	if test -n "$configure_needed"
	then
		(
			cd "$build_dir"
			"$source_dir/configure" \
				--with-msys2-runtime-commit="$runtime_commit" \
				--prefix=/usr \
				--build="$MSYSTEM_CHOST" \
				--sysconfdir=/etc
			printf '%s\n' "$config_key" >"$config_stamp"
		)
	fi

	(
		cd "$build_dir"
		LC_ALL=C make -j"$jobs" all-target-newlib
		LC_ALL=C make configure-target-winsup
	)

	LC_ALL=C make \
		-C "$build_dir/$MSYSTEM_CHOST/winsup/cygwin" \
		-j"$jobs" \
		child_info_magic.h \
		shared_info_magic.h \
		globals.h \
		localtime.patched.c

	LC_ALL=C make \
		-C "$build_dir/$MSYSTEM_CHOST/winsup/cygwin" \
		-j"$jobs" \
		new-msys-2.0.dll
} 2>&1 | tee "$log" | summarize_output

dll=$build_dir/$MSYSTEM_CHOST/winsup/cygwin/new-msys-2.0.dll
test -f "$dll" || {
	echo "error: runtime build did not produce $dll" >&2
	exit 1
}

newer_source=$(find "$source_dir/winsup/cygwin" -type f \
	\( -name '*.c' -o -name '*.cc' -o -name '*.h' -o -name '*.S' \) \
	-newer "$dll" -print -quit)
test -z "$newer_source" || {
	echo "error: runtime DLL is older than $newer_source" >&2
	exit 1
}

echo "runtime DLL built successfully: $dll" | tee -a "$log"

if test -n "$full_build"
then
	if ! LC_ALL=C make -C "$build_dir" -j"$jobs" 2>&1 |
		tee -a "$log" |
		summarize_output
	then
		echo "error: runtime DLL succeeded, but the full build failed" >&2
		if grep -q 'undefined reference to `ZSTD_' "$log"
		then
			echo "hint: PKGBUILD lists libzstd-devel as a build dependency" >&2
		fi
		exit 1
	fi
fi

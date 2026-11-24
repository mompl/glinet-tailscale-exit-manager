#!/bin/sh
# Build the TSEM release package. Reproducible, offline, changes nothing outside --out.
#
#   sh tools/build-release.sh --version VERSION [--out DIR]
#
# Produces in DIR (default ./dist):
#   tsem-VERSION.tar.gz       router package + Mac acceptance tools + docs + tests (extract on the Mac, run from there)
#   tsem-ha-VERSION.tar.gz    Home Assistant integration only (custom_components/tsem) + README
#   SHA256SUMS                checksums of both archives
# The build refuses to run if a file that looks like a credential would be packed.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
VERSION="" OUT=$ROOT/dist
while [ $# -gt 0 ]; do
	case $1 in
	--version) VERSION=${2:-}; shift 2 ;;
	--out) OUT=${2:-}; shift 2 ;;
	-h | --help) sed -n '2,10p' "$0"; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done
case $VERSION in
'' | *[!A-Za-z0-9._-]*) echo "--version is required (letters, digits, . _ - only)" >&2; exit 2 ;;
esac
for t in tar gzip sha256sum find sort; do command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t" >&2; exit 1; }; done
tar --help 2>&1 | grep -q -- --sort || { echo "GNU tar with --sort is required (macOS: brew install gnu-tar, use gtar)" >&2; exit 1; }

W=$(mktemp -d) || exit 1
trap 'rm -rf "$W"' EXIT
PK=$W/tsem-$VERSION
mkdir -p "$PK" "$OUT" || exit 1

# the shipped set; development leftovers (mut, mut2, old_discovery.sh, test-discovery.sh at top level) are not part of it
for d in src contrib native tools tests docs homeassistant; do
	[ -d "$ROOT/$d" ] && cp -R "$ROOT/$d" "$PK/$d"
done
for f in setup.sh install.sh uninstall.sh README.md LICENSE; do
	[ -f "$ROOT/$f" ] && cp "$ROOT/$f" "$PK/$f"
done
rm -rf "$PK/homeassistant/tests/__pycache__" "$PK/homeassistant/custom_components/tsem/__pycache__"
find "$PK" -name '*.pyc' -delete -o -name '.DS_Store' -delete 2>/dev/null

# credential guard: names that must never ship, and obvious secret assignments
bad=$(find "$PK" \( -iname '*.pem' -o -iname '*.key' -o -iname '.env' -o -iname '*token*' -o -iname 'id_rsa*' -o -iname '*.p12' \) -type f | sed "s|$PK/||")
[ -z "$bad" ] || { echo "REFUSED: files that look like credentials: $bad" >&2; exit 1; }
# content scan: product files only (tests/ and tools/ hold redaction code and fake fixtures that contain such patterns on purpose).
# Fail-closed: a scan that cannot run (grep error, e.g. unsupported option on busybox) refuses the build instead of passing silently.
find "$PK" -type f ! -path "$PK/tests/*" ! -path "$PK/tools/*" >"$W/scanlist" || { echo "REFUSED: cannot list files for the secret scan" >&2; exit 1; }
leak=""
while IFS= read -r f; do
	grep -qE '(tskey-[A-Za-z0-9]{8,}|BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16})' "$f" 2>/dev/null
	case $? in
	0) leak="$leak ${f#"$PK"/}" ;;
	1) ;;
	*) echo "REFUSED: the secret scan failed on ${f#"$PK"/}" >&2; exit 1 ;;
	esac
done <"$W/scanlist"
[ -z "$leak" ] || { echo "REFUSED: secret-like content in:$leak" >&2; exit 1; }

# every shell script must at least parse
for f in "$PK/setup.sh" "$PK/install.sh" "$PK/uninstall.sh" "$PK"/tools/*.sh "$PK"/src/usr/sbin/tsem "$PK"/src/usr/lib/tsem/*.sh; do
	[ -f "$f" ] || continue
	sh -n "$f" || { echo "REFUSED: syntax error in ${f#"$PK"/}" >&2; exit 1; }
done

(cd "$PK" && find . -type f ! -name MANIFEST.sha256 | sort | while IFS= read -r f; do printf '%s  %s\n' "$(sha256sum <"$f" | cut -d' ' -f1)" "$f"; done) >"$PK/MANIFEST.sha256"
printf '%s\n' "$VERSION" >"$PK/VERSION"

pack() { # dir name -> archive
	tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner -C "$W" -cf - "$1" | gzip -n -9 >"$OUT/$2"
}
pack "tsem-$VERSION" "tsem-$VERSION.tar.gz" || exit 1

HA=$W/tsem-ha-$VERSION
mkdir -p "$HA" && cp -R "$ROOT/homeassistant/custom_components" "$HA/custom_components" && cp -R "$ROOT/homeassistant/blueprints" "$HA/blueprints" && cp "$ROOT/homeassistant/README.md" "$ROOT/docs/home-assistant-install.md" "$HA/"
find "$HA" -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null
pack "tsem-ha-$VERSION" "tsem-ha-$VERSION.tar.gz" || exit 1

(cd "$OUT" && sha256sum "tsem-$VERSION.tar.gz" "tsem-ha-$VERSION.tar.gz" >SHA256SUMS) || exit 1
echo "built in $OUT:"
(cd "$OUT" && ls -l "tsem-$VERSION.tar.gz" "tsem-ha-$VERSION.tar.gz" SHA256SUMS && cat SHA256SUMS)

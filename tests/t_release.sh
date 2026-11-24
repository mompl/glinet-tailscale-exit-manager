# shellcheck shell=sh
# tools/build-release.sh: reproducible package, checksums, no credentials, installable from the extracted archive.

_need_tar() { tar --help 2>&1 | grep -q -- --sort || need_skip "GNU tar with --sort is required"; }

test_release_builds_verifies_and_is_reproducible() {
	_need_tar
	"$SH" "$ROOT/tools/build-release.sh" --version t1 --out "$T/o1" >"$T/b1.out" 2>&1 || fail "build failed: $(cat "$T/b1.out")"
	"$SH" "$ROOT/tools/build-release.sh" --version t1 --out "$T/o2" >"$T/b2.out" 2>&1 || fail "second build failed"
	(cd "$T/o1" && sha256sum -c SHA256SUMS >/dev/null) || fail "checksums do not verify"
	assert_eq reproducible "$(cat "$T/o1/SHA256SUMS")" "$(cat "$T/o2/SHA256SUMS")"
	_l=$(tar -tzf "$T/o1/tsem-t1.tar.gz")
	for f in install.sh uninstall.sh src/usr/sbin/tsem tools/run-rc3-active-mac.sh tools/tsem-rc3-recover.sh docs/emergency-recovery.md homeassistant/custom_components/tsem/manifest.json MANIFEST.sha256 VERSION; do
		case $_l in *"tsem-t1/$f"*) ;; *) fail "release lacks $f" ;; esac
	done
	case $_l in *tsem-t1/mut/* | *old_discovery.sh*) fail "development leftovers are in the release" ;; esac
	tar -tzf "$T/o1/tsem-ha-t1.tar.gz" | grep -q 'custom_components/tsem/switch.py' || fail "HA package lacks the integration"
	case $(tar -tzf "$T/o1/tsem-ha-t1.tar.gz") in *install.sh*) fail "HA package contains router installer" ;; esac
}

test_release_extracted_package_dry_run_installs_nothing() {
	_need_tar
	"$SH" "$ROOT/tools/build-release.sh" --version t2 --out "$T/o" >/dev/null 2>&1 || fail "build failed"
	mkdir -p "$T/x" "$T/rt/etc/config" && tar -xzf "$T/o/tsem-t2.tar.gz" -C "$T/x"
	(cd "$T/x/tsem-t2" && sha256sum -c MANIFEST.sha256 >/dev/null 2>&1) || fail "MANIFEST does not verify after extraction"
	PATH=$ROOT/tests/netns/bin:$PATH "$SH" "$T/x/tsem-t2/install.sh" --root "$T/rt" >"$T/i.out" 2>&1 || fail "dry run from the package failed: $(cat "$T/i.out")"
	assert_contains dry "dry run only" "$(cat "$T/i.out")"
	assert_eq nothing "0" "$(find "$T/rt" -type f | wc -l | tr -d ' ')"
}

test_release_refuses_credentials_and_bad_version() {
	_need_tar
	"$SH" "$ROOT/tools/build-release.sh" --out "$T/o" >/dev/null 2>&1 && fail "built without --version"
	"$SH" "$ROOT/tools/build-release.sh" --version 'a b' --out "$T/o" >/dev/null 2>&1 && fail "accepted a bad version"
	# copy of the tree with a planted key: the guard must refuse
	mkdir -p "$T/cp" && cp -R "$ROOT/tools" "$ROOT/src" "$ROOT/docs" "$T/cp/" && cp "$ROOT/install.sh" "$ROOT/uninstall.sh" "$T/cp/"
	printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nx\n' >"$T/cp/docs/leak.txt"
	if "$SH" "$T/cp/tools/build-release.sh" --version t3 --out "$T/o3" >"$T/g.out" 2>&1; then fail "planted private key was packed"; fi
	assert_contains refused "REFUSED" "$(cat "$T/g.out")"
}

#!/usr/bin/env bash
# Initialize the system-only factory baseline from one running QPi device.

set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ADB=${ADB:-adb}
KBT="$ROOT/kernel/prebuilts/kernel-build-tools/linux-x86/bin"
IMG2SIMG="$KBT/img2simg"
SIMG2IMG="$KBT/simg2img"
META="$ROOT/prebuilds/device-baseline.meta"
readonly E2FSCK_NORMALIZE_OPTS=-fp

die() { echo "ERROR: $*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }
meta_get() { sed -n "s/^$2=//p" "$1" | head -1; }

MODE=init
EXPECTED_PLATFORM=""
OFFLINE_RAW=""
OFFLINE_CONFIG=""
OFFLINE_OUT=""

while [ $# -gt 0 ]; do
	case "$1" in
	--detect-only) MODE=detect ;;
	--print-platform) MODE=print-platform ;;
	--check-installed) MODE=check ;;
	--self-test) MODE=self-test ;;
	--platform) EXPECTED_PLATFORM=${2:?--platform requires a value}; shift ;;
	--offline-test)
		MODE=offline
		OFFLINE_RAW=${2:?--offline-test requires RAW CONFIG PLATFORM KREL OUTDIR}
		OFFLINE_CONFIG=${3:?--offline-test requires RAW CONFIG PLATFORM KREL OUTDIR}
		EXPECTED_PLATFORM=${4:?--offline-test requires RAW CONFIG PLATFORM KREL OUTDIR}
		KERNEL_RELEASE=${5:?--offline-test requires RAW CONFIG PLATFORM KREL OUTDIR}
		OFFLINE_OUT=${6:?--offline-test requires RAW CONFIG PLATFORM KREL OUTDIR}
		shift 5
		;;
	-h|--help)
		cat <<'EOF'
Usage:
  init-baseline-from-device.sh
  init-baseline-from-device.sh --detect-only
  init-baseline-from-device.sh --print-platform
  init-baseline-from-device.sh --check-installed --platform PLATFORM
  init-baseline-from-device.sh --self-test
  init-baseline-from-device.sh --offline-test RAW CONFIG PLATFORM KREL OUTDIR
EOF
		exit 0
		;;
	*) die "unknown argument: $1" ;;
	esac
	shift
done

validate_platform_name() {
	case "$1" in
	200u-debian|200u-debian-perf|200u-linux|200u-linux-perf|200e-debian|200e-debian-perf|200e-linux|200e-linux-perf) ;;
	*) die "invalid platform: $1" ;;
	esac
}

validate_config() {
	local config=$1 profile=$2 localversion
	[ -s "$config" ] || die "Kernel config is empty: $config"
	grep -qx 'CONFIG_ARM64=y' "$config" || die "Kernel config lacks CONFIG_ARM64=y"
	grep -qx 'CONFIG_IKCONFIG=y' "$config" || die "Kernel config lacks CONFIG_IKCONFIG=y"
	localversion=$(sed -n 's/^CONFIG_LOCALVERSION=//p' "$config" | head -1)
	case "$profile:$localversion" in
	normal:'"-gki-consolidate"'|perf:'""') ;;
	*) die "Kernel config/profile mismatch: profile=$profile CONFIG_LOCALVERSION=${localversion:-<missing>}" ;;
	esac
}

profile_from_platform() {
	case "$1" in *-perf) echo perf ;; *) echo normal ;; esac
}

config_path_for_profile() {
	case "$1" in normal) echo "$ROOT/config/kernel.config" ;; perf) echo "$ROOT/config/kernel.perf.config" ;; esac
}

release_path_for_profile() {
	case "$1" in normal) echo "$ROOT/prebuilds/kernel.release" ;; perf) echo "$ROOT/prebuilds/kernel.perf.release" ;; esac
}

device_platform_from_ids() {
	local compatible=$1 soc_id=$2
	if printf '%s\n' "$compatible" | grep -qx 'qcom,bengal' && [ "$soc_id" = 444 ]; then
		echo 200u
		return 0
	fi
	if printf '%s\n' "$compatible" | grep -qx 'qcom,scuba-iot' && [ "$soc_id" = 473 ]; then
		echo 200e
		return 0
	fi
	return 1
}

rootfs_from_os_id() {
	case "$1" in
	debian) echo debian ;;
	qti-distro-fullstack-debug|qti-distro-fullstack-perf) echo linux ;;
	*) return 1 ;;
	esac
}

rootfs_kind_from_image() {
	local image=$1 id
	id=$(debugfs -R 'cat /usr/lib/os-release' "$image" 2>/dev/null |
		sed -n 's/^ID=//p' | head -1 | tr -d '\r"') || return 1
	[ -n "$id" ] || return 1
	rootfs_from_os_id "$id"
}

profile_from_release_config() {
	case "$1:$2" in
	*-gki-consolidate:'"-gki-consolidate"') echo normal ;;
	5.15.180:'""') echo perf ;;
	*) return 1 ;;
	esac
}

active_slot_from_devices() {
	case "$1" in
	"$2") printf '_a\n' ;;
	"$3") printf '_b\n' ;;
	*) return 1 ;;
	esac
}

root_mount_from_sources() {
	local have_findmnt=$1 findmnt_line=$2 proc_mounts=$3 mount_line
	case "$have_findmnt" in
	yes)
		mount_line=$(printf '%s\n' "$findmnt_line" | awk 'NF {print $1, $2, $3; exit}')
		;;
	no)
		mount_line=$(printf '%s\n' "$proc_mounts" | awk '$2 == "/" {print $1, $3, $4; exit}')
		;;
	*) return 1 ;;
	esac
	[ "$(printf '%s\n' "$mount_line" | awk '{print NF}')" = 3 ] || return 1
	printf '%s\n' "$mount_line"
}

root_mount_is_ext4() {
	[ "$(printf '%s\n' "$1" | awk '{print $2}')" = ext4 ]
}

slot_from_cmdline() {
	local slots
	slots=$(printf '%s\n' "$1" |
		grep -oE 'systemd\.setenv="?SLOT_SUFFIX=_[ab]"?|androidboot\.slot_suffix=_[ab]|(^|[[:space:]])SLOT_SUFFIX=_[ab]' |
		sed -n 's/.*=\(_[ab]\)"*$/\1/p' | sort -u || true)
	case "$slots" in
	"") return 1 ;;
	_a|_b) printf '%s\n' "$slots" ;;
	*) return 2 ;;
	esac
}

ext4_has_needs_recovery() {
	case " $1 " in *' needs_recovery '*) return 0 ;; *) return 1 ;; esac
}

ext4_precheck_action() {
	local rc=$1 features=$2
	case "$rc" in
	0)
		if ext4_has_needs_recovery "$features"; then echo normalize; else echo clean; fi
		;;
	4) echo normalize ;;
	*) return 1 ;;
	esac
}

ext4_normalization_rc_is_safe() {
	local rc=$1 dangerous_mask=$((4 | 8 | 16 | 32 | 128))
	case "$rc" in ''|*[!0-9]*) return 1 ;; esac
	[ $((rc & dangerous_mask)) -eq 0 ] && [ $((rc & ~3)) -eq 0 ]
}

ext4_strict_postcheck_is_clean() {
	local rc=$1 features=$2
	[ "$rc" -eq 0 ] && ! ext4_has_needs_recovery "$features"
}

self_test() {
	local d c m findmnt_line proc_mounts rc
	[ "$E2FSCK_NORMALIZE_OPTS" = -fp ] || die "self-test: Host-copy normalization must force a full preen check"
	d=$(mktemp -d /tmp/qpi-device-baseline-selftest.XXXXXX)
	trap 'rm -rf "$d"' EXIT HUP INT TERM
	c=$d/kernel.config
	cat > "$c" <<'EOF'
CONFIG_ARM64=y
CONFIG_IKCONFIG=y
CONFIG_LOCALVERSION="-gki-consolidate"
EOF
	validate_config "$c" normal
	if (validate_config "$c" perf >/dev/null 2>&1); then die "self-test: invalid profile was accepted"; fi
	[ "$(device_platform_from_ids $'qcom,bengal-idp\nqcom,bengal' 444)" = 200u ]
	[ "$(device_platform_from_ids $'qcom,scuba-idp\nqcom,scuba-iot\nqcom,idp' 473)" = 200e ]
	if device_platform_from_ids 'qcom,scuba-iot' 444 >/dev/null; then die "self-test: L1 compatible with M1 soc_id was accepted"; fi
	if device_platform_from_ids 'qcom,bengal' 473 >/dev/null; then die "self-test: M1 compatible with L1 soc_id was accepted"; fi
	if device_platform_from_ids $'qcom,scuba-idp\nqcom,idp' 473 >/dev/null; then die "self-test: L1 without exact qcom,scuba-iot compatible was accepted"; fi
	if device_platform_from_ids 'qcom,unknown' 999 >/dev/null; then die "self-test: unknown SoC was accepted"; fi
	[ "$(rootfs_from_os_id debian)" = debian ]
	[ "$(rootfs_from_os_id qti-distro-fullstack-debug)" = linux ]
	[ "$(rootfs_from_os_id qti-distro-fullstack-perf)" = linux ]
	if rootfs_from_os_id qti-distro-fullstack >/dev/null; then die "self-test: partial QTI rootfs ID was accepted"; fi
	if rootfs_from_os_id qti-distro-fullstack-unknown >/dev/null; then die "self-test: unknown QTI rootfs variant was accepted"; fi
	if rootfs_from_os_id qti-distro >/dev/null; then die "self-test: partial QTI distro ID was accepted"; fi
	if rootfs_from_os_id fullstack-perf >/dev/null; then die "self-test: partial perf rootfs ID was accepted"; fi
	if rootfs_from_os_id unknown >/dev/null; then die "self-test: unknown rootfs was accepted"; fi
	[ "$(profile_from_release_config 5.15.180-gki-consolidate '"-gki-consolidate"')" = normal ]
	[ "$(profile_from_release_config 5.15.180 '""')" = perf ]
	if profile_from_release_config 5.15.180 '"-gki-consolidate"' >/dev/null; then die "self-test: conflicting profile was accepted"; fi
	[ "$(active_slot_from_devices /dev/p77 /dev/p77 /dev/p78)" = _a ]
	[ "$(active_slot_from_devices /dev/p78 /dev/p77 /dev/p78)" = _b ]
	if active_slot_from_devices /dev/mapper/root /dev/p77 /dev/p78 >/dev/null; then die "self-test: unknown root device was accepted"; fi
	findmnt_line='/dev/mmcblk0p77 ext4 ro,relatime'
	proc_mounts='/dev/mmcblk0p77 / ext4 ro,relatime 0 0'
	[ "$(root_mount_from_sources yes "$findmnt_line" '')" = '/dev/mmcblk0p77 ext4 ro,relatime' ]
	[ "$(root_mount_from_sources no '' "$proc_mounts")" = '/dev/mmcblk0p77 ext4 ro,relatime' ]
	root_mount_is_ext4 "$(root_mount_from_sources no '' "$proc_mounts")"
	if root_mount_is_ext4 "$(root_mount_from_sources no '' '/dev/mmcblk0p77 / xfs ro 0 0')"; then
		die "self-test: non-ext4 root was accepted"
	fi
	[ "$(slot_from_cmdline 'root=/dev/mmcblk0p77 systemd.setenv="SLOT_SUFFIX=_a" rootwait ro')" = _a ]
	[ "$(slot_from_cmdline 'androidboot.slot_suffix=_b root=/dev/mmcblk0p78')" = _b ]
	if slot_from_cmdline 'root=/dev/mmcblk0p77' >/dev/null; then die "self-test: missing cmdline slot was accepted"; fi
	[ "$(ext4_precheck_action 0 'has_journal extent')" = clean ]
	[ "$(ext4_precheck_action 0 'has_journal needs_recovery extent')" = normalize ]
	[ "$(ext4_precheck_action 4 'has_journal extent')" = normalize ]
	for rc in 8 16 32 128; do
		if ext4_precheck_action "$rc" 'has_journal extent' >/dev/null; then
			die "self-test: unsafe precheck rc=$rc was accepted"
		fi
	done
	for rc in 0 1 2 3; do
		ext4_normalization_rc_is_safe "$rc" || die "self-test: safe normalization rc=$rc was rejected"
	done
	for rc in 4 5 8 9 12 16 32 64 128; do
		if ext4_normalization_rc_is_safe "$rc"; then die "self-test: unsafe normalization rc=$rc was accepted"; fi
	done
	ext4_normalization_rc_is_safe 1 && ext4_strict_postcheck_is_clean 0 'has_journal extent' ||
		die "self-test: repaired host copy with clean postcheck was rejected"
	if ext4_normalization_rc_is_safe 4; then die "self-test: normalization rc=4 was accepted"; fi
	if ext4_strict_postcheck_is_clean 4 'has_journal extent'; then die "self-test: postcheck rc=4 was accepted"; fi
	if ext4_strict_postcheck_is_clean 0 'has_journal needs_recovery extent'; then
		die "self-test: postcheck with needs_recovery was accepted"
	fi
	if ext4_strict_postcheck_is_clean 1 'has_journal extent'; then die "self-test: nonzero round-trip rc was accepted"; fi
	m=$d/meta
	printf 'BASELINE_SOURCE=device\nPLATFORM=200u-debian\n' > "$m"
	[ "$(meta_get "$m" BASELINE_SOURCE)" = device ]
	[ "$(meta_get "$m" PLATFORM)" = 200u-debian ]
	rm -rf "$d"
	trap - EXIT HUP INT TERM
	echo "self-test PASS"
}

if [ "$MODE" = self-test ]; then
	self_test
	exit 0
fi

check_installed() {
	[ -s "$META" ] || die "device baseline metadata is missing: $META"
	[ "$(meta_get "$META" BASELINE_SOURCE)" = device ] || die "invalid device baseline metadata source"
	local platform profile config config_meta release device_platform rootfs_kind
	local sparse_sha system_size
	platform=$(meta_get "$META" PLATFORM)
	profile=$(meta_get "$META" PROFILE)
	[ -n "$platform" ] && [ -n "$profile" ] || die "incomplete device baseline metadata"
	validate_platform_name "$platform"
	if [ -n "$EXPECTED_PLATFORM" ] && [ "$platform" != "$EXPECTED_PLATFORM" ]; then
		die "device baseline platform mismatch: metadata=$platform current=$EXPECTED_PLATFORM"
	fi
	config=$(config_path_for_profile "$profile")
	config_meta=${config}.meta
	release=$(release_path_for_profile "$profile")
	[ -s "$config" ] && [ -s "$config_meta" ] || die "device Kernel config/config metadata is incomplete"
	cmp -s "$META" "$config_meta" || die "device baseline metadata and Kernel config metadata differ"
	[ "$(meta_get "$config_meta" BASELINE_SOURCE)" = device ] || die "Kernel config is not device-derived"
	[ "$(meta_get "$config_meta" PLATFORM)" = "$platform" ] || die "Kernel config platform metadata mismatch"
	device_platform=$(meta_get "$META" DEVICE_PLATFORM)
	rootfs_kind=$(meta_get "$META" ROOTFS_KIND)
	[ "$device_platform" = "${platform%%-*}" ] || die "device platform metadata mismatch"
	case "$platform:$rootfs_kind" in
		*-debian*:debian|*-linux*:linux) ;;
		*) die "device rootfs metadata mismatch" ;;
	esac
	[ "$(profile_from_platform "$platform")" = "$profile" ] || die "device profile metadata mismatch"
	validate_config "$config" "$profile"
	[ -n "$(meta_get "$META" CONFIG_SHA256)" ] || die "device config SHA256 metadata is missing"
	[ -s "$release" ] || die "device kernel release is missing: $release"
	[ "$(tr -d '\r\n' < "$release")" = "$(meta_get "$META" KERNEL_RELEASE)" ] || die "device kernel release metadata mismatch"
	[ -s "$ROOT/prebuilds/system.img" ] || die "device system baseline is missing"
	sparse_sha=$(meta_get "$META" SYSTEM_SPARSE_SHA256)
	[ -n "$sparse_sha" ] || die "device sparse system SHA256 metadata is missing"
	[ "$(sha256sum "$ROOT/prebuilds/system.img" | awk '{print $1}')" = "$sparse_sha" ] || die "device sparse system SHA256 mismatch"
	system_size=$(meta_get "$META" SYSTEM_SIZE)
	case "$system_size" in ''|*[!0-9]*) die "invalid device system size metadata" ;; esac
	[ "$(sed -n 's/^system=//p' "$ROOT/prebuilds/baseline.platform" 2>/dev/null | head -1)" = "$platform" ] ||
		die "system baseline platform marker mismatch"
	note "device baseline ready: $platform ($profile), kernel $(cat "$release")"
}

if [ "$MODE" = check ]; then
	check_installed
	exit 0
fi

SERIAL=""
adb_one_device() {
	local line state
	local -a good=() bad=()
	while IFS=$'\t' read -r line state; do
		[ -n "$line" ] || continue
		case "$state" in device*) good+=("$line") ;; unauthorized*|offline*) bad+=("$line:$state") ;; esac
	done < <("$ADB" devices | awk 'NR>1 && NF {print $1 "\t" $2}')
	[ "${#bad[@]}" -eq 0 ] || die "ADB has unauthorized/offline device(s); fix the connection first"
	[ "${#good[@]}" -eq 1 ] || die "exactly one ADB device is required (found ${#good[@]})"
	SERIAL=${good[0]}
}

adbs() { "$ADB" -s "$SERIAL" shell "$1"; }
adbx() { "$ADB" -s "$SERIAL" exec-out "$1"; }

detect_device() {
	adb_one_device
	local uid compatible soc_id os_id localversion mount_line root_source
	local findmnt_line proc_mounts cmdline cmdline_slot slot_rc
	local system_a system_b release_dir sample vermagic
	uid=$(adbs 'id -u' | tr -d '\r')
	[ "$uid" = 0 ] || die "device block extraction requires the existing ADB shell to be root; do not run adb root automatically"

	compatible=$(adbs 'tr "\0" "\n" </proc/device-tree/compatible 2>/dev/null' | tr -d '\r')
	soc_id=$(adbs 'cat /sys/devices/soc0/soc_id 2>/dev/null' | tr -d '\r\n')
	DEVICE_PLATFORM=$(device_platform_from_ids "$compatible" "$soc_id") ||
		die "unsupported or unvalidated device compatible/soc_id mapping"

	os_id=$(adbs 'sed -n '\''s/^ID=//p'\'' /etc/os-release 2>/dev/null | head -1' | tr -d '\r"')
	ROOTFS_KIND=$(rootfs_from_os_id "$os_id") || die "unknown or unvalidated rootfs ID='$os_id'"

	KERNEL_RELEASE=$(adbs 'uname -r' | tr -d '\r\n')
	[ -n "$KERNEL_RELEASE" ] || die "uname -r returned empty"
	adbs 'test -r /proc/config.gz' >/dev/null 2>&1 ||
		die 'device does not expose /proc/config.gz; boot-partition fallback is not implemented yet'
	CONFIG_GZ="$WORK/device-config.gz"
	CONFIG_TMP="$WORK/kernel.config"
	adbx 'cat /proc/config.gz' > "$CONFIG_GZ"
	gzip -t "$CONFIG_GZ" || die "device /proc/config.gz failed gzip validation"
	gzip -dc "$CONFIG_GZ" > "$CONFIG_TMP"
	localversion=$(sed -n 's/^CONFIG_LOCALVERSION=//p' "$CONFIG_TMP" | head -1)
	PROFILE=$(profile_from_release_config "$KERNEL_RELEASE" "$localversion") ||
		die "uname/config profile mismatch: uname=$KERNEL_RELEASE CONFIG_LOCALVERSION=${localversion:-<missing>}"
	validate_config "$CONFIG_TMP" "$PROFILE"
	PLATFORM="$DEVICE_PLATFORM-$ROOTFS_KIND"
	[ "$PROFILE" = perf ] && PLATFORM="$PLATFORM-perf"
	case "$PLATFORM" in
	200u-debian|200u-linux|200e-debian|200e-linux|200u-debian-perf|200u-linux-perf|200e-debian-perf|200e-linux-perf) ;;
	*)
		die "profile detected as $PLATFORM but device-baseline support has not been validated"
		;;
	esac

	if adbs 'command -v findmnt >/dev/null 2>&1'; then
		findmnt_line=$(adbs 'findmnt -no SOURCE,FSTYPE,OPTIONS /' | tr -d '\r')
		mount_line=$(root_mount_from_sources yes "$findmnt_line" '') ||
			die "cannot parse root mount from findmnt: $findmnt_line"
	else
		proc_mounts=$(adbs 'cat /proc/mounts 2>/dev/null' | tr -d '\r')
		mount_line=$(root_mount_from_sources no '' "$proc_mounts") ||
			die "cannot identify root mount from /proc/mounts"
	fi
	root_source=$(printf '%s\n' "$mount_line" | awk '{print $1}')
	root_mount_is_ext4 "$mount_line" || die "active root filesystem is not ext4: $mount_line"
	system_a=$(adbs 'readlink -f /dev/block/bootdevice/by-name/system_a 2>/dev/null' | tr -d '\r\n')
	system_b=$(adbs 'readlink -f /dev/block/bootdevice/by-name/system_b 2>/dev/null' | tr -d '\r\n')
	ACTIVE_SLOT=$(active_slot_from_devices "$root_source" "$system_a" "$system_b") ||
		die "root source cannot be mapped to system_a/system_b: root=$root_source a=$system_a b=$system_b"
	cmdline=$(adbs 'cat /proc/cmdline 2>/dev/null' | tr -d '\r\n')
	cmdline_slot=""
	if cmdline_slot=$(slot_from_cmdline "$cmdline"); then slot_rc=0; else slot_rc=$?; fi
	case "$slot_rc" in
	0) [ "$cmdline_slot" = "$ACTIVE_SLOT" ] ||
		die "cmdline slot disagrees with active root device: cmdline=$cmdline_slot root=$ACTIVE_SLOT" ;;
	1) note "cmdline has no SLOT_SUFFIX; active slot verified from root device and system_a/system_b" ;;
	*) die "cmdline contains conflicting SLOT_SUFFIX values" ;;
	esac
	case "$ACTIVE_SLOT" in _a) ACTIVE_SYSTEM_DEVICE=$system_a ;; _b) ACTIVE_SYSTEM_DEVICE=$system_b ;; esac
	case "$ACTIVE_SYSTEM_DEVICE" in /dev/*) ;; *) die "unsafe active system device path: $ACTIVE_SYSTEM_DEVICE" ;; esac
	EXPECTED_SYSTEM_SIZE=$(adbs "blockdev --getsize64 '$ACTIVE_SYSTEM_DEVICE'" | tr -d '\r\n')
	case "$EXPECTED_SYSTEM_SIZE" in ''|*[!0-9]*) die "invalid active system size: $EXPECTED_SYSTEM_SIZE" ;; esac
	[ "$EXPECTED_SYSTEM_SIZE" -gt 0 ] || die "active system size is zero"

	release_dir=$(adbs "test -d '/lib/modules/$KERNEL_RELEASE' && echo yes" | tr -d '\r\n')
	[ "$release_dir" = yes ] || die "device lacks /lib/modules/$KERNEL_RELEASE"
	sample=$(adbs "find '/lib/modules/$KERNEL_RELEASE' -type f -name '*.ko' 2>/dev/null | head -1" | tr -d '\r\n')
	if [ -n "$sample" ] && adbs 'command -v modinfo >/dev/null 2>&1'; then
		vermagic=$(adbs "modinfo '$sample' 2>/dev/null | sed -n 's/^vermagic:[[:space:]]*//p'" | tr -d '\r' | head -1)
		case "$vermagic" in "$KERNEL_RELEASE "*|"$KERNEL_RELEASE") ;; *) die "sample module vermagic mismatch: ${vermagic:-<missing>}" ;; esac
	fi
	DEVICE_COMPATIBLE=$(printf '%s' "$compatible" | paste -sd, -)
	SOC_ID=$soc_id
}

WORK=""
if [ "$MODE" != offline ]; then
	mkdir -p "$ROOT/.tmp"
	WORK=$(mktemp -d "$ROOT/.tmp/device-baseline.XXXXXX")
	trap 'rm -rf "$WORK"' EXIT HUP INT TERM
	detect_device
	if [ "$MODE" = print-platform ]; then echo "$PLATFORM"; exit 0; fi
	if [ "$MODE" = detect ]; then
		echo "device platform: $PLATFORM"
		echo "kernel release: $KERNEL_RELEASE"
		echo "active slot: $ACTIVE_SLOT"
		echo "active system: $ACTIVE_SYSTEM_DEVICE ($EXPECTED_SYSTEM_SIZE bytes)"
		exit 0
	fi
else
	validate_platform_name "$EXPECTED_PLATFORM"
	case "$OFFLINE_OUT" in /tmp/?*) ;; *) die "offline test output must be a dedicated directory below /tmp" ;; esac
	PLATFORM=$EXPECTED_PLATFORM
	PROFILE=$(profile_from_platform "$PLATFORM")
	DEVICE_PLATFORM=${PLATFORM%%-*}
	case "$PLATFORM" in *-debian*) ROOTFS_KIND=debian ;; *-linux*) ROOTFS_KIND=linux ;; esac
	WORK=$OFFLINE_OUT
	rm -rf "$WORK"
	mkdir -p "$WORK"
	cp -f "$OFFLINE_CONFIG" "$WORK/kernel.config"
	CONFIG_TMP="$WORK/kernel.config"
	validate_config "$CONFIG_TMP" "$PROFILE"
	ACTIVE_SLOT=_offline
	ACTIVE_SYSTEM_DEVICE=offline
	EXPECTED_SYSTEM_SIZE=$(stat -c%s "$OFFLINE_RAW")
	DEVICE_COMPATIBLE=offline-test
	SOC_ID=offline-test
fi

[ -x "$IMG2SIMG" ] && [ -x "$SIMG2IMG" ] || die "managed sparse tools are missing; run buildenv dependency preparation first"
command -v e2fsck >/dev/null 2>&1 || die "missing e2fsck"
command -v dumpe2fs >/dev/null 2>&1 || die "missing dumpe2fs"
command -v debugfs >/dev/null 2>&1 || die "missing debugfs"

if [ "$MODE" = init ]; then
	CONFIG_TARGET=$(config_path_for_profile "$PROFILE")
	CONFIG_META_TARGET=${CONFIG_TARGET}.meta
	RELEASE_TARGET=$(release_path_for_profile "$PROFILE")
	for existing in "$ROOT/config/kernel.config" "$ROOT/config/kernel.config.meta" \
		"$ROOT/config/kernel.perf.config" "$ROOT/config/kernel.perf.config.meta"; do
		[ ! -e "$existing" ] && [ ! -L "$existing" ] ||
			die "Kernel work config/meta already exists; run buildclean before device initialization: $existing"
	done
fi

RAW="$WORK/system.raw"
if [ "$MODE" = offline ]; then
	cp --reflink=auto "$OFFLINE_RAW" "$RAW"
else
	echo "Extracting active $ACTIVE_SLOT system ($EXPECTED_SYSTEM_SIZE bytes) read-only..."
	adbx "cat '$ACTIVE_SYSTEM_DEVICE'" > "$RAW"
fi
[ "$(stat -c%s "$RAW")" = "$EXPECTED_SYSTEM_SIZE" ] || die "system extraction size mismatch"
SYSTEM_RAW_SHA256=$(sha256sum "$RAW" | awk '{print $1}')

set +e
e2fsck -fn "$RAW" > "$WORK/e2fsck-pre.log" 2>&1
pre_rc=$?
set -e
features=$(dumpe2fs -h "$RAW" 2>/dev/null | sed -n 's/^Filesystem features:[[:space:]]*//p')
if ! pre_action=$(ext4_precheck_action "$pre_rc" "$features"); then
	cat "$WORK/e2fsck-pre.log" >&2
	die "system raw failed the strict read-only ext4 precheck (rc=$pre_rc)"
fi
if [ "$pre_action" = normalize ]; then
	set +e
	e2fsck "$E2FSCK_NORMALIZE_OPTS" "$RAW" > "$WORK/e2fsck-normalize.log" 2>&1
	norm_rc=$?
	set -e
	if ! ext4_normalization_rc_is_safe "$norm_rc"; then
		cat "$WORK/e2fsck-normalize.log" >&2
		die "safe Host-copy ext4 normalization failed (rc=$norm_rc)"
	fi
fi
set +e
e2fsck -fn "$RAW" > "$WORK/e2fsck-post.log" 2>&1
post_rc=$?
set -e
features=$(dumpe2fs -h "$RAW" 2>/dev/null | sed -n 's/^Filesystem features:[[:space:]]*//p')
if ! ext4_strict_postcheck_is_clean "$post_rc" "$features"; then
	cat "$WORK/e2fsck-post.log" >&2
	die "normalized system raw failed strict ext4 validation (rc=$post_rc needs_recovery=$(ext4_has_needs_recovery "$features" && echo yes || echo no))"
fi

IMAGE_ROOTFS_KIND=$(rootfs_kind_from_image "$RAW") ||
	die "system image has an unsupported rootfs identity"
[ "$IMAGE_ROOTFS_KIND" = "$ROOTFS_KIND" ] ||
	die "system image rootfs identity does not match $ROOTFS_KIND"
debugfs -R "stat /lib/modules/$KERNEL_RELEASE" "$RAW" 2>/dev/null |
	grep -q 'Type: directory' || die "system image lacks /lib/modules/$KERNEL_RELEASE"

NORMALIZED_RAW_SHA256=$(sha256sum "$RAW" | awk '{print $1}')
SPARSE="$WORK/system.img"
ROUNDTRIP="$WORK/system-roundtrip.raw"
"$IMG2SIMG" "$RAW" "$SPARSE" 4096
"$SIMG2IMG" "$SPARSE" "$ROUNDTRIP"
[ "$(stat -c%s "$ROUNDTRIP")" = "$EXPECTED_SYSTEM_SIZE" ] || die "sparse round-trip size mismatch"
[ "$(sha256sum "$ROUNDTRIP" | awk '{print $1}')" = "$NORMALIZED_RAW_SHA256" ] || die "sparse round-trip is not byte-for-byte identical"
set +e
e2fsck -fn "$ROUNDTRIP" > "$WORK/e2fsck-roundtrip.log" 2>&1
round_rc=$?
set -e
round_features=$(dumpe2fs -h "$ROUNDTRIP" 2>/dev/null | sed -n 's/^Filesystem features:[[:space:]]*//p')
if ! ext4_strict_postcheck_is_clean "$round_rc" "$round_features"; then
	cat "$WORK/e2fsck-roundtrip.log" >&2
	die "sparse round-trip ext4 validation failed (rc=$round_rc)"
fi
ROUNDTRIP_ROOTFS_KIND=$(rootfs_kind_from_image "$ROUNDTRIP") || die "round-trip OS identity mismatch"
[ "$ROUNDTRIP_ROOTFS_KIND" = "$ROOTFS_KIND" ] || die "round-trip OS identity mismatch"
debugfs -R "stat /lib/modules/$KERNEL_RELEASE" "$ROUNDTRIP" 2>/dev/null |
	grep -q 'Type: directory' || die "round-trip module release path is missing"

CONFIG_SHA256=$(sha256sum "$CONFIG_TMP" | awk '{print $1}')
SYSTEM_SPARSE_SHA256=$(sha256sum "$SPARSE" | awk '{print $1}')
cat > "$WORK/device-baseline.meta" <<EOF
SCHEMA_VERSION=1
BASELINE_SOURCE=device
PLATFORM=$PLATFORM
DEVICE_PLATFORM=$DEVICE_PLATFORM
ROOTFS_KIND=$ROOTFS_KIND
PROFILE=$PROFILE
KERNEL_RELEASE=$KERNEL_RELEASE
CONFIG_SHA256=$CONFIG_SHA256
ACTIVE_SLOT=$ACTIVE_SLOT
SYSTEM_SIZE=$EXPECTED_SYSTEM_SIZE
SYSTEM_RAW_SHA256=$SYSTEM_RAW_SHA256
SYSTEM_NORMALIZED_RAW_SHA256=$NORMALIZED_RAW_SHA256
SYSTEM_SPARSE_SHA256=$SYSTEM_SPARSE_SHA256
DEVICE_COMPATIBLE=$DEVICE_COMPATIBLE
SOC_ID=$SOC_ID
EOF
printf '%s\n' "$KERNEL_RELEASE" > "$WORK/kernel.release"
printf 'system=%s\n' "$PLATFORM" > "$WORK/baseline.platform"

if [ "$MODE" = offline ]; then
	note "offline staging validation PASS: $WORK"
	exit 0
fi

mkdir -p "$ROOT/config" "$ROOT/prebuilds" "$ROOT/.tmp"
BACKUP="$WORK/backup"
mkdir -p "$BACKUP"
targets=("$CONFIG_TARGET" "$CONFIG_META_TARGET" "$RELEASE_TARGET" "$ROOT/prebuilds/system.img" "$ROOT/prebuilds/baseline.platform" "$META" "$ROOT/.tmp/platform")
for i in "${!targets[@]}"; do
	t=${targets[$i]}
	if [ -e "$t" ] || [ -L "$t" ]; then
		printf '1\n' > "$BACKUP/$i.exists"
		ln "$t" "$BACKUP/$i.data" 2>/dev/null || cp -a "$t" "$BACKUP/$i.data"
	else
		printf '0\n' > "$BACKUP/$i.exists"
	fi
done

COMMITTED=0
rollback() {
	[ "$COMMITTED" = 1 ] && return 0
	local i t
	for i in "${!targets[@]}"; do
		t=${targets[$i]}
		if [ "$(cat "$BACKUP/$i.exists")" = 1 ]; then
			mv -f "$BACKUP/$i.data" "$t"
		else
			rm -f "$t"
		fi
	done
}
trap 'rc=$?; rollback; rm -rf "$WORK"; exit $rc' EXIT HUP INT TERM

install_one() {
	local src=$1 dst=$2 tmp=${2}.new.$$
	cp -a "$src" "$tmp"
	mv -f "$tmp" "$dst"
}
install_one "$CONFIG_TMP" "$CONFIG_TARGET"
install_one "$WORK/device-baseline.meta" "$CONFIG_META_TARGET"
install_one "$WORK/kernel.release" "$RELEASE_TARGET"
install_one "$SPARSE" "$ROOT/prebuilds/system.img"
install_one "$WORK/baseline.platform" "$ROOT/prebuilds/baseline.platform"
install_one "$WORK/device-baseline.meta" "$META"
printf '%s\n' "$PLATFORM" > "$ROOT/.tmp/platform.new.$$"
mv -f "$ROOT/.tmp/platform.new.$$" "$ROOT/.tmp/platform"
COMMITTED=1
trap - EXIT HUP INT TERM
rm -rf "$WORK"

echo "device system-only baseline initialized: $PLATFORM"
echo "kernel release: $KERNEL_RELEASE"
echo "system size: $EXPECTED_SYSTEM_SIZE"
echo "system raw SHA256: $SYSTEM_RAW_SHA256"
echo "system sparse SHA256: $SYSTEM_SPARSE_SHA256"

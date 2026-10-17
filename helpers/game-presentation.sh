#!/bin/sh
# Resolve Steam game presentation metadata and an optional original game icon.
# Output is a bounded, line-oriented interface: name=... and, when available,
# icon=/absolute/path/to/game.icns. Values are data; callers must not eval them.
set -eu

fail() {
	printf '%s\n' "game-presentation: $1" >&2
	exit 1
}

has_linebreak() {
	case "$1" in *'
'*|*'\r'*) return 0 ;; esac
	linebreak_cr=$(printf '\r')
	case "$1" in *"$linebreak_cr"*) return 0 ;; esac
	return 1
}

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || fail 'usage: game-presentation.sh <steam-root> <appid> [original-art-fallback]'
steam_root=$1
appid=$2
original_art=${3-}
has_linebreak "$steam_root" && fail 'Steam root contains a line break'
has_linebreak "$appid" && fail 'appid contains a line break'
has_linebreak "$original_art" && fail 'fallback path contains a line break'
case "$steam_root" in /*) ;; *) fail 'Steam root must be absolute' ;; esac
case "$appid" in ''|*[!0-9]*) fail 'appid must be a decimal UInt32' ;; esac

# Normalize leading zeroes before comparing, avoiding shell octal parsing.
normalized=$appid
while [ "${normalized#0}" != "$normalized" ]; do normalized=${normalized#0}; done
[ -n "$normalized" ] || fail 'appid must be nonzero'
[ "${#normalized}" -le 10 ] || fail 'appid exceeds UInt32'
if [ "${#normalized}" -eq 10 ] && [ "$normalized" -gt 4294967295 ]; then
	fail 'appid exceeds UInt32'
fi
appid=$normalized

appcache="$steam_root/appcache"
appinfo_vdf="$appcache/appinfo.vdf"
[ -d "$appcache" ] && [ -r "$appinfo_vdf" ] || fail 'Steam appcache/appinfo.vdf is unavailable'

support="$HOME/Library/Application Support/notproton"
has_linebreak "$HOME" && fail 'HOME contains a line break'
case "$HOME" in /*) ;; *) fail 'HOME must be absolute' ;; esac
appinfo="$support/appinfo"
iconmaker="$support/iconmaker"
[ -x "$appinfo" ] || fail 'installed appinfo helper is unavailable'

metadata_file=$(mktemp "${TMPDIR:-/tmp}/np-appinfo.XXXXXX") || fail 'cannot create appinfo scratch file'
trap 'rm -f "$metadata_file"' EXIT HUP INT TERM
if ! "$appinfo" "$appinfo_vdf" "$appid" > "$metadata_file"; then
	fail 'appinfo could not resolve this appid'
fi
metadata_size=$(wc -c < "$metadata_file" | tr -d ' ')
[ "$metadata_size" -le 8192 ] || fail 'appinfo output exceeds 8192 bytes'
meta_name=
meta_icon=
meta_clienticon=
while IFS= read -r line || [ -n "$line" ]; do
	case "$line" in
		name=*) meta_name=${line#name=} ;;
		icon=*) meta_icon=${line#icon=} ;;
		clienticon=*) meta_clienticon=${line#clienticon=} ;;
	esac
done < "$metadata_file"
has_linebreak "$meta_name" && fail 'metadata name contains a line break'
if printf '%s' "$meta_name" | LC_ALL=C grep -q '[[:cntrl:]]'; then
	fail 'metadata name contains a control character'
fi
case "$meta_icon" in ''|*[!0-9a-fA-F]*) meta_icon= ;; esac
case "$meta_clienticon" in ''|*[!0-9a-fA-F]*) meta_clienticon= ;; esac
[ -n "$meta_name" ] || fail 'appinfo metadata has no name'

# Preserve Steam's title punctuation; this is data, never shell code.
flat_name=$(printf '%s' "$meta_name" | sed 's/^ *//; s/ *$//')
[ -n "$flat_name" ] || fail 'appinfo returned an unusable name'
[ "${#flat_name}" -le 512 ] || fail 'metadata name exceeds 512 characters'

cache="$HOME/Library/Application Support/notproton/launchers/$appid"
mkdir -p "$cache" || fail 'cannot create presentation cache'
art_dir="$appcache/librarycache/$appid"
art=
ico=
# Explicit native artwork wins before any network attempt.
case "$original_art" in
    *.icns|*.ICNS)
        if [ -f "$original_art" ] && [ -r "$original_art" ]; then
            art=$original_art
            meta_clienticon=
            meta_icon=
        fi ;;
esac
# Use local original art first; fetching is only needed when Steam has none cached.
if [ -n "$meta_clienticon" ]; then
	ico="$cache/clienticon-$meta_clienticon.ico"
	if [ -s "$ico" ] && [ "$(od -An -tx1 -N4 "$ico" 2>/dev/null | tr -d ' \n')" = 00000100 ]; then
		art=$ico
	fi
fi
if [ -z "$art" ] && [ -n "$meta_icon" ] && [ -f "$art_dir/$meta_icon.jpg" ]; then
	art="$art_dir/$meta_icon.jpg"
fi
if [ -z "$art" ] && [ -n "$ico" ]; then
	tmp="$ico.new.$$"
	url="https://shared.fastly.steamstatic.com/community_assets/images/apps/$appid/$meta_clienticon.ico"
	if curl -fsL --connect-timeout 2 --max-time 5 -o "$tmp" "$url" 2>/dev/null &&
	   [ "$(od -An -tx1 -N4 "$tmp" 2>/dev/null | tr -d ' \n')" = 00000100 ]; then
		mv -f "$tmp" "$ico"
		art=$ico
	fi
	rm -f "$tmp"
fi
if [ -z "$art" ] && [ -n "$original_art" ] && [ -f "$original_art" ] && [ -r "$original_art" ]; then
	original_ext=$(printf '%s' "$original_art" | tr '[:upper:]' '[:lower:]')
	case "$original_ext" in
		*.exe|*.png|*.jpg|*.jpeg|*.gif|*.bmp|*.tif|*.tiff|*.heic|*.icns|*.ico) art=$original_art ;;
		*) fail 'fallback must be an executable or image file' ;;
	esac
fi

printf 'name=%s\n' "$flat_name"
# An explicitly supplied native ICNS takes precedence over Steam cache artwork.
# Copy its bytes unchanged; never run generated or original ICNS through iconmaker.
case "$original_art" in
    *.icns|*.ICNS) [ ! -f "$original_art" ] || art=$original_art ;;
esac
if [ -n "$art" ]; then
	icon_cache="$cache/game.icns"
	identity_file="$cache/notproton-icon.source"
	version=5
	mtime=$(stat -f %m "$art" 2>/dev/null || stat -c %Y "$art" 2>/dev/null || printf 0)
	identity="$art $mtime format=$version"
	valid_icns() {
		[ -f "$1" ] && [ -r "$1" ] || return 1
        size=$(wc -c < "$1" | tr -d ' ')
        [ "$size" -ge 8 ] && [ "$size" -le 33554432 ] || return 1
        [ "$(od -An -tc -N4 "$1" 2>/dev/null | tr -d ' \n')" = icns ] || return 1
        declared=$(od -An -tu1 -j4 -N4 "$1" | awk 'NF == 4 {print $1*16777216+$2*65536+$3*256+$4}')
        [ "$declared" = "$size" ]
	}
	if [ -f "$identity_file" ] && [ "$(cat "$identity_file")" = "$identity" ] && valid_icns "$icon_cache"; then
		:
	else
		tmp_icon="$icon_cache.new.$$.icns"
		rm -f "$tmp_icon"
		case "$art" in
            *.icns|*.ICNS)
                if valid_icns "$art"; then cp "$art" "$tmp_icon"; fi ;;
            *)
                if [ -x "$iconmaker" ]; then "$iconmaker" "$art" "$tmp_icon" >/dev/null 2>&1 || :; fi ;;
        esac
        if valid_icns "$tmp_icon"; then
			mv -f "$tmp_icon" "$icon_cache"
			printf '%s\n' "$identity" > "$identity_file"
		else
			rm -f "$tmp_icon"
		fi
	fi
	if [ -f "$identity_file" ] && [ "$(cat "$identity_file")" = "$identity" ] && valid_icns "$icon_cache"; then
		printf 'icon=%s\n' "$icon_cache"
	fi
fi

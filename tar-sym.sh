#!/usr/bin/env sh
#
# Copyright (c) 2017 Christian Lamparter <chunkeey@googlemail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, version 2.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.
#
# Aus der schnappsideen Kiste: Limited TarBall symlink searcher
#
# This utility tries to follows symlinks in a tarball.
# The current implementation handles simple redirects and recursive lookups
# just fine. It can deal with file-symlinks and directory symlinks.
# However, It doesn't support anything else than the "ustar  " format and
# it can only operate on single volume tar files.
# It does not have support for hardlinks, longnames or any other extensions.
# Never tested the limits of the implementation, the main idea was that it
# was simple and robust... And frankly, if you need anything more complicated
# then you should ask, if the "tar-balls" is really the best method.
#
# Syntax:
# ./tar-sym.sh find|extract|length file.tar path/to/possibly/symlinked/file
#
#
# How it works:
#
# First, the tool will open the file and generate a table ("array*") of all files,
# directories and symlinks listed in the tarball (see mapper()).
#
# If the import was successful, the tool will then use the table to follow through
# the given "path/to/possibl..." path (see follow_link()). It does this by splitting
# up the path-string into the individual /path/ tokens. And then walks recursively
# through the directories and symlinks until it reaches the requested "file".
# If the file isn't found it will bail.
#
# At the end, the code will perform the requested operation:
#   "extract" : this will dump the file's content to stdout: (--to-stdout | -O)
#   "find" : returns the real file behind "path/to/possibly/symlinked/file"
#   "length"  : returns the length of the stored file
#
# Note:
#
# All tools and techniques are limited to what the most basic OpenWRT/LEDE
# installation has on board. One of those limitation is that busybox's sh does
# not support arrays. Hence, this implementation incorporates dynamic
# metaprogramming to generate a indexed key value store. Don't be fooled
# be the convoluted code, this is much simpler to do, if the programming
# language has a hashmap.

# This bash scripts needs the following external programs
# echo, dd, printf, wc

# _POSIX_SYMLOOP_MAX is only 7. But we have a
# recursive loop test, so no problem  Do not traverse more than 7 levels into a redirection hell
MAX_INDIRECTIONS=${MAX_INDIRECTIONS:-40}
${INIT_TRACE:+set -x}

tar_file=
die() {
	>&2 echo "$@"
	exit 1
}

help() {
	die "Syntax: $0 find|extract|length tarfile.tar path/to/possibly/symlinked/file"
}

dbg() {
	[ -z $DEBUG ] || (>&2 echo "$@")
}

get_tar() {
	( dd if="$tar_file" skip="$1" bs=1 count="$2" 2>/dev/null | strings -n 1 | head -1 )
}

offset=0
name=
type=
size=

# TAR header parser - Assume that TAR Blocksize is 512.
get_tar_header() {
	# Surprisingly easy to implement. The full format can be found on:
	# <https://www.gnu.org/software/tar/manual/html_node/Standard.html>
	# This code only cares for "magic/version", "name", "type", "link"
	# and "size". And it only understands the "ustar  " format.
	#  With a bit of elbow grease however, this could be extended to
	# handle longnames (and longsyms), other formats and possibly
	# BIG archieves.

	# End of .tar reached. Stop
	[[ "$offset" -ge "$tar_size" ]] && return 1

	# First: Check if the MAGIC matches
	local magic_off=$(($offset+257))

	[[ "$(get_tar $magic_off 7)" == "ustar  " ]] && {
		# Everything has a fixed position in the header
		# Strings are null-terminated.
		local name_off=$(($offset+0))
	        local type_off=$(($offset+156))
        	local link_off=$(($offset+157))
		local size_off=$(($offset+124))

		type="$(get_tar $type_off 1)"
		size="$(get_tar $size_off 12)"

		# Convert size from the stored octal to decimal
		# size="$((8#$size))" # Not supported by busybox
		size=$(printf '%d' $size)

		# Pointer to the next entry. 512-Byte aligned.
		offset=$(( $offset + ( ($size + 511) / 512 + 1) * 512 ))

		# If this was a SymLink, grab the link
		[ "$type" == "2" ] && link="$(get_tar $link_off 100)"

                name="$(get_tar $name_off 100)"
		tar_finished=0
	} || {
		# TAR archieves end on at least two consecutive zero-filled blocks.
		# So if we fail to read any values. we can stop
		tar_finished=1
	}
}

# the key-value store

arrayindex=0		# current array index
nextarrayindex=0	# next array index

addarray() {
	arrayindex=$nextarrayindex
	eval arrayname_$arrayindex="$1"
	eval arraytype_$arrayindex="$2"
	eval arrayoffset_$arrayindex="$3"
	eval arraysize_$arrayindex="$4"
	eval arraylink_$arrayindex="$5"
	nextarrayindex=$(($nextarrayindex+1))
}

lookup_array() {
	local tmp
	local i
	for i in $(seq 0 $arrayindex); do
		eval tmp="\$arrayname_$i"
		[ "$tmp" == "$1" ] && {
			echo -n $i
			break
		}
	done
}

adddir() {
	[ -z $(lookup_array "$1") ] && addarray "$1" 1 "$2" 0 0 ""
}

dumparray() {
	local i
	for i in $(seq 0 $ain); do
		eval name="\$arrayname_$i"
		eval type="\$arraytype_$i"

		dbg ARRAY: i:$i n:$name t:$type
		case "$type" in
		0)
			eval filename="\$arrayname_$i"
			eval fileoffset="\$arrayoffset_$i"
			eval filesize="\$arraysize_$i"
			dbg "   FILE: $i name: $filename, offset_in_tar:$fileoffset, size_in_tar:$filesize"
			;;
		1)
			eval dirname="\$arrayname_$i"
			dbg "    DIR: $i dirname: $dirname"

			;;
		2)
			eval linkname="\$arrayname_$i"
			eval linklink="\$arraylink_$i"
			dbg "  LINK: $i linkname: $linkname, linklink:$linklink"
			;;
		esac

	done
}

mapper() {
	local dirstack=
	local cleanname=
	local saved_offset=

	offset=0
	tar_finished=0

	get_tar_header

	[ "$tar_finished" -eq "1" ] && \
		die "Unable to read anything. Probably not a compatible tar."

	while [ "$tar_finished" -eq "0" ]; do

		cleanname=$name
		cleanname="${cleanname%/}"
		cleanname="${cleanname#/}"
		cleanname="${cleanname#./}"

		dbg "Found entry '$name' of type '$type'"

		case "$type" in
		""|\
		"0")	# File
			addarray "$cleanname" 0 "$saved_offset" "$size" ""
			;;
		"5")	# Directory
			dirstack=""
			OLDIFS=$IFS;IFS="/";for subdir in $cleanname; do
				IFS=$OLDIFS
				[ -z "$dirstack" ] && adddir "$subdir"
				[ -z "$dirstack" ] || adddir "$dirstack$subdir"
				dirstack="$dirstack$subdir/"
			done
			;;
		"2")	# Softlink
			link=${link%/}

			addarray "$cleanname" 2 0 0 "$link"
			;;
		"*")
			die "Found unhandled $type"
			;;
		esac

		saved_offset=$offset
		get_tar_header
	done
}

dirlevel=0
follow_link() {
	local look="$1"
	local level="$2"
	local stack=

        [ "$level" -ge "$MAX_INDIRECTIONS" ] && {
                die "Too many redirections. Giving up."
        }

	dbg "Entered level:$level looking for:$look with base:$stack"

	OLDIFS="$IFS";IFS="/";for pele in $look; do
		IFS="$OLDIFS"

		eval stack="\$stack_$dirlevel"
		dbg "Look for '$pele' in path: '$stack'"

		case "$pele" in
		"..")
#			Could be used instead
#			[ "$dirlevel" -gt 0 ] && dirlevel=$(( $dirlevel - 1 ))
			[ "$dirlevel" -eq 0 ] && die "Aborting because link '$look' leaves the archive."
			dirlevel=$(( $dirlevel - 1 ))
			;;
		".")
			;;
		*)
			aid=$(lookup_array "$stack$pele")
			[ -z "$aid" ] && die "'$orig_dest' was not found in archive."

			eval type="\$arraytype_$aid"

			case "$type" in
			"0") # File
				eval filename="\$arrayname_$aid"
				echo "$filename"
				return
				;;
			"1") # Directory
				dirlevel=$(( $dirlevel + 1 ))
				eval stack_$dirlevel="$stack$pele/"
				;;
			"2") # Link
				eval [ -z \$arrayvisited_$aid ] || die "Aborting due to recursive link loop."
				eval arrayvisited_$aid=1
				eval linklink="\$arraylink_$aid"
				follow_link "$linklink" $(( $level + 1 )) "$dirlevel"
				;;
			*)
				die "Internal error"
				;;
			esac
		esac
	done
}

[ "$#" -eq "3" ] || help

[ -r "$2" ] || {
	die "file: $2 not accessible"
}

orig_dest="$3"
clean_dest="${3%/}"
clean_dest="${clean_dest#./}"
tar_file="$2"
tar_size=$(cat "$tar_file" | wc -c)

mapper

[ -z $DEBUG ] || dumparray

case "$1" in
"find")
	follow_link "$clean_dest" "0"
	;;

"length")
	link=$(follow_link "$clean_dest" "0")
	[ -z "$link" ] && exit 1

	aid=$(lookup_array "$link")
	eval echo "\$arraysize_$aid"
	;;

"extract")
	link=$(follow_link "$clean_dest" "0")
	[ -z "$link" ] && exit 1

	aid=$(lookup_array "$link")
	eval offset="\$arrayoffset_$aid"
	eval size="\$arraysize_$aid"
	dd if="$tar_file" bs=1 count="$size" skip="$(( $offset + 512 ))" status=none
	;;

*)
	help
	;;
esac

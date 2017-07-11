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
# This utility tries to follows symlinks in a tar ball.
# The current implementation handles simple redirects and recursive lookups
# just fine. It can deal with file-symlinks and directory symlinks.
# However, It doesn't support anything else than the "ustar  " format. It
# does not have support for hardlinks, longnames or any other extensions.
# Never tested the limit of the implementation, the main idea was that it
# was simple and robust... And frankly, if you need anything more complicated
# then you should ask, if the "tar-balls" is really the best method.
#
# Syntax:
# ./tar-sym.sh find|extract file.tar path/to/possibly/symlinked/file
#
#
# How it works:
#
# First, the tool will open the file and generate a "indextable" of all files,
# directories and symlinks of the tar ball (see mapper()).
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
#
# Note:
#
# All tools and techniques are limited to what the most basic OpenWRT/LEDE
# installation has on board. One of those limitation is that busybox's sh does
# not support arrays. Hence, this implementation incorporates dynamic
# metaprogramming to generate a indexed key value store. Don't be fooled
# be the convoluted code, this is much simpler to do, if the programming
# language has a hashmap.

MAX_INDIRECTIONS=${MAX_INDIRECTIONS:-7} # Do not traverse more than 7 levels into a redirection hell
DEBUG=${DEBUG:-}
${INIT_TRACE:+set -x}

tar_file=
die() {
	>&2 echo "$@"
	exit 1
}

help() {
	die "Syntax: $0 find|extract tarfile.tar path/to/possibly/symlinked/file"
}

dbg() {
	[ -z $DEBUG ] || (>&2 echo "$@")
}

get_tar() {
	( /bin/dd if="$tar_file" skip="$1" bs=1 count="$2" 2>/dev/null | strings -n 1 | head -1 )
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
		size=$(/usr/bin/printf '%d' $size)

		# Pointer to the next entry. 512-Byte aligned.
		offset=$(( $offset + ( ($size + 511) / 512 + 1) * 512 ))

		# If this was a SymLink, grab the link
		[ "$type" == "2" ] && link="$(get_tar $link_off 100)"

                name="$(get_tar $name_off 100)"
		tar_finished=0
	} || {
		# TAR archieves end on a empty block. So if we fail
		# to read any values. we can stop
		tar_finished=1
	}
}

# key-value store

ain=0	# current array index
nai=0	# next array index
fin=0	# current file index
nfi=0	# next file index
din=0	# directory index
ndi=0	# next directory index
lin=0	# link index
nli=0	# next link index

addarray() {
	ain=$nai
	eval arrayname_$ain="$1"
	eval arraytype_$ain="$2"
	eval arrayindex_$ain="$3"
	nai=$(($nai+1))
}

addfile() {
	fin=$nfi
	eval filename_$fin="$1"
	eval fileoffset_$fin="$2"
	eval filesize_$fin="$3"
	addarray "$1" 0 "$fin"
	nfi=$(($nfi+1))
}

lookup_array() {
	for i in $(seq 0 $ain); do
		eval tmp="\$arrayname_$i"
		[ "$tmp" == "$1" ] && {
			echo -n $i
			break
		}
	done
}

lookup_dir() {
	for i in $(seq 0 $din); do
		eval tmp="\$dirname_$i"
		[ "$tmp" == "$1" ] && {
			echo -n $i
			break
		}
	done
}

adddir() {
	local edi=
	[ $din -gt 0 ] && edi=$(lookup_dir "$1")
	[ -z $edi ] && {
		din=$ndi
		eval dirname_$din="$1"
		ndi=$(($ndi+1))
		addarray "$1" 1 "$din"
	}
}

addlink() {
	lin=$nli
	eval linkname_$lin="$1"
	eval linklink_$lin="$2"
	addarray "$1" 2 "$lin"
	nli=$(($nli+1))
}

dumparray() {
	local i
	for i in $(seq 0 $ain); do
		eval name="\$arrayname_$i"
		eval type="\$arraytype_$i"
		eval index="\$arrayindex_$i"

		dbg ARRAY: i:$i n:$name t:$type ii:$index
		case "$type" in
		0)
			eval filename="\$filename_$index"
			eval fileoffset="\$fileoffset_$index"
			eval filesize="\$filesize_$index"
			dbg "   FILE: $index name: $filename, offset_in_tar:$fileoffset, size_in_tar:$filesize"
			;;
		1)
			eval dirname="\$dirname_$index"
			dbg "    DIR: $index dirname: $dirname"

			;;
		2)
			eval linkname="\$linkname_$index"
			eval linklink="\$linklink_$index"
			dbg "  LINK: $index linkname: $linkname, linklink:$linklink"
			;;
		esac

	done
}

stack=
mapper() {
	local stack=
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

		dbg "Found $name of type $type"

		case "$type" in
		""|\
		"0")	# File
			addfile "$cleanname" "$saved_offset" "$size"
			;;
		"5")	# Directory
			stack=""
			OLDIFS=$IFS;IFS="/";for subdir in $cleanname; do
				IFS=$OLDIFS
				[ -z "$stack" ] && adddir "$subdir"
				[ -z "$stack" ] || adddir "$stack$subdir"
				stack="$stack$subdir/"
			done
			;;
		"2")	# Softlink
			link=${link%/}

			addlink "$cleanname" "$link"
			;;
		"*")
			die "Found unhandled $type"
			;;
		esac

		saved_offset=$offset
		get_tar_header
	done
}

oldstack=
follow_link() {
	local le="$2"
	local li="$1"
	stack="$3"
	oldstack="$4"

        [ "$le" -ge "$MAX_INDIRECTIONS" ] && {
                die "Too many redirections. Giving up."
        }

	dbg "Entered level:$le looking for:$li with base:$stack"

	OLDIFS="$IFS";IFS="/";for pele in $li; do
		IFS="$OLDIFS"

		dbg "Look for '$pele' in path: '$stack'"

		case "$pele" in
		"..")
			stack=$oldstack
			;;
		".")
			;;
		*)
			aid=$(lookup_array "$stack$pele")
			[ -z "$aid" ] && die "'$orig_dest' not found or not a file."

			eval type="\$arraytype_$aid"

			case "$type" in
			"0") # File
				eval filename="\$arrayname_$aid"
				echo "$filename"
				return
				;;
			"1") # Directory
				oldstack="$stack"
				stack="$stack$pele/"
				;;
			"2") # Link
				eval lid="\$arrayindex_$aid"
				eval linklink="\$linklink_$lid"

				follow_link "$linklink" $((le + 1)) "$stack" "$oldstack"
				;;
			*)
				die "Internal error"
				;;
			esac
		esac
	done
}

[ "$#" -eq "3" ] || help

[ -r $2 ] || {
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

"extract")
	link=$(follow_link "$clean_dest" "0")
	aid=$(lookup_array $link)

	eval fid="\$arrayindex_$aid"
	eval offset="\$fileoffset_$fid"
	eval size="\$filesize_$fid"

	/bin/dd if="$tar_file" bs=1 count="$size" skip="$(( $offset + 512 ))" status=none
	;;
*)
	help
	;;
esac

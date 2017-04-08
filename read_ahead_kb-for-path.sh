#!/bin/bash

# debugging made useful/easy
PS4='Line ${LINENO}: '
# set -ex

myname="$(basename $0)"
user_id=$(id -u)

function usage () {
  cat << EOF
Sets read_ahead_kb for all block devices used behind path.

Usage: $myname [-s SIZE|-r] -p PATH
   or: $myname -f SETTINGS-FILE

Options:
  -s  - size to set for device via read_ahead_kb

  -r  - report the current read_ahead_kb setting and blockdev
        setting for each block device behind PATH

  -p  - path to search for block devices behind
        REQUIRED

  -f  - specify setting file
        if set, -s and -p options ignored as they're in the file
        File format:
          [directory] [read_ahead_kb]
        Lines that start with # are ignored, all whitespace treated
        equaly.

Example:
  $myName -s 16384 -p /mnt/iscsi/10_vod_db_main

Notes:
  Without -s SIZE or -r, this will default to -r.

Requires:
  blockdev command, root privs.
EOF
  echo
  exit
}

# set default
report=0

function is_integer () {
  case ${1#[-+]} in
    ''|*[!0-9]* ) return 1 ;;
    *           ) return 0 ;;
  esac
}

function echo_err      () { echo -e "$myname: $@" 1>&2 ; }
function echo_err_exit () { echo_err "$@" ; exit 1 ; }

# this IDs all block devices behind path - multipath and lvm make for fun
function get_block_devs_for_dir () {
  whichDir="$1"
  mainDev=$(readlink -f $(df -P $whichDir|tail -n1| cut -d\  -f1) | sed 's,^.*/,,g')
  realDevs=$(lsblk -i | \
    grep -e '^[a-zA-Z]' -e "$mainDev " -e "($mainDev)" | \
    grep -B1            -e "$mainDev " -e "($mainDev)" | \
    grep -e '^[a-zA-Z]' | \
    cut -d\  -f1)
  echo $mainDev $realDevs | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/\ \+$//g'
}

# get read_ahead_kb file contents/setting
function get_ra_kb_val () {
  local dev="$1"
  if [ "x$dev" = 'x' ] ; then
    echo_err "$FUNCNAME - required block device argument missing"
    return 1
  fi
  if [ ! -e /sys/block/$dev ] ; then
    echo_err "$FUNCNAME - block device '/sys/block/$dev' does not exist"
    return 1
  fi
  cat /sys/block/$dev/queue/read_ahead_kb
}

# get blockdev read_ahead value
function get_ra_block_val () {
  local dev="$1"
  if [ "x$dev" = 'x' ] ; then
    echo_err "$FUNCNAME - required device argument missing"
    return 1
  fi
  if [ ! -e /dev/$dev ] ; then
    echo_err "$FUNCNAME - device '/dev/$dev' does not exist"
    return 1
  fi
  blockdev --getra /dev/$dev
}

function show_ra_kb_blocks () {
  local dev="$1"
  local dir="$2"
  if [ "x$dev" = 'x' ] ; then
    echo_err "$FUNCNAME - required device argument missing"
    return 1
  fi
  read_ahead_kb=$(get_ra_kb_val $dev)
  err=$?
  [ $err -ne 0 ] && \
    echo_err "$FUNCNAME call to function 'get_ra_kb_val' returned error '$err', with the message (if any):\n$read_ahead_kb"
  if [ $user_id -eq 0 ] ; then
    read_ahead_block=$(get_ra_block_val $dev)
    err=$?
    [ $err -ne 0 ] && \
      echo_err "$FUNCNAME call to function 'get_ra_block_val' returned error '$err', with the message (if any):\n$read_ahead_kb"
  else
    read_ahead_block='(non-root:n/a)'
  fi
  if [ "x$dir" != 'x' ] ; then
    echo "$dir $dev $read_ahead_kb $read_ahead_block"
  else
    echo "$dev read_ahead_kb:$read_ahead_kb block_ra:$read_ahead_block"
  fi
}

function show_all_read_ahead_kb_block () {
  local show_all_dir="$1"

  [ "x$show_all_dir" != 'x' ] && \
    echo 'dir dev read_ahead_kb blockdev_getra'
  for show_all_device in ${block_devices[@]}; do
    show_ra_kb_blocks "$show_all_device" "$show_all_dir"
  done
}

# identify block to kb ratio
#  blockdev accepts blocks as arguments, file is managed and read in kb
#  note: this does NO input validation, that should be handled before this
function get_block_kb_ratio () {
  local get_block_kb_ratio_dev="$1"
  local read_ahead_kb=$(get_ra_kb_val $get_block_kb_ratio_dev)
  err=$?
  [ $err -ne 0 ] && \
    echo_err "$FUNCNAME call to function 'get_ra_kb_val' returned error '$err', with the message (if any):\n$read_ahead_kb"
  read_ahead_block=$(get_ra_block_val $get_block_kb_ratio_dev)
  err=$?
  [ $err -ne 0 ] && \
    echo_err "$FUNCNAME call to function 'get_ra_block_val' returned error '$err', with the message (if any):\n$read_ahead_kb"

  echo "$read_ahead_block/$read_ahead_kb"|bc
}

# sets read_ahead_kb intelligently using blockdev, which uses blocks, not kb
function set_read_ahead_kb_val () {
  local set_read_ahead_kb_val_dev="$1"
  local set_read_ahead_kb_val_size="$2"

  [ "x$set_read_ahead_kb_val_dev" = 'x' ] && \
    echo_err "$FUNCNAME usage: $FUNCNAME [dev] [size]" && return 1
  [ "x$set_read_ahead_kb_val_size" = 'x' ] && \
    echo_err "$FUNCNAME usage: $FUNCNAME [dev] [size]" && return 1

  [ ! -e /sys/block/$set_read_ahead_kb_val_dev ] && \
    echo_err "$FUNCNAME: block device $set_read_ahead_kb_val_dev does not exist" && return 1
  ! is_integer $set_read_ahead_kb_val_size && \
    echo_err "$FUNCNAME: size '$set_read_ahead_kb_val_size' is not an integer" && return 1

  local block_kb_ratio=$(get_block_kb_ratio $set_read_ahead_kb_val_dev)
  local set_new_read_ahead_block="$(echo "$block_kb_ratio*$set_read_ahead_kb_val_size"|bc)"

  blockdev --setra $set_new_read_ahead_block /dev/$set_read_ahead_kb_val_dev
}

function parse_validate_settings_file () {
  # this is only used when SETTING params, so if not root, go away
  [ $user_id -ne 0 ] &&
    echo_err_exit "non-root: this functionality requires root"

  # set an array off of what's found in the file
  tmp_path_array=( $(
    grep -v -e '^#' -e '^$' $settings_file | \
    sed \
      -e 's/[\t ]\+/ /g' \
      -e 's/^\ //g' \
      -e 's/\ $//g' \
      -e 's/\ /:/g' | \
      cut -d: -f1-2
  ) )
  [ ${#tmp_path_array[@]} -eq 0 ] && \
    echo_err_exit "no data found in '$settings_file"

  # now validate each path:size pair found and build real array
  for path_size_val in ${tmp_path_array[@]} ; do
    [ ! -d ${path_size_val/:*} ] && \
      echo_err "specified path '${path_size_val/:*}' does not exist" && \
      continue
    ! is_integer ${path_size_val/*:} && \
      echo_err "read_ahead_kb size is not an int: '${path_size_val/*:}'" && \
      continue
    path_array[${#path_array[@]}]=$path_size_val
  done

  [ ${#path_array[@]} -eq 0 ] && \
    echo_err_exit "no valid paths:sizes in '$settings_file'"
}

#
# process arguments
#
while [ $# -gt 0 ] ; do
  ARG="$1" ; shift
  case $ARG in
    -p     ) mount_path="$1" ; shift
             [ ! -d $mount_path ] && \
               echo_err_exit "specified path '$mount_path' does not exist"
           ;;
    -s     ) ra_kb_size="$1" ; shift
             is_integer $ra_kb_size || \
               echo_err_exit "read_ahead_kb size is not an int: '$ra_kb_size'"
           ;;
    -r     ) report=1 ;;
    -f     ) settings_file="$1" ; shift
             [ ! -r $settings_file ] && \
               echo_err_exit "settings file '$settings_file' does not exist or is not readable"
           ;;
    '-?'   ) usage ;;
    -h     ) usage ;;
    --help ) usage ;;
    *      ) echo_err_exit "unkown arg: $ARG" ;;
  esac
done

#
# Usage is very different when called with a settings file, parse input sanely
#
if [ "x$settings_file" != 'x' ] ; then
  parse_validate_settings_file
else
  # regular input validation here

  # if not root, explain limited functionality
  [ $user_id -ne 0 ] && \
    echo '(non-root:blockdev binary unavailable, output/options limited)' 1>&2

  # ensure valid params provided
  [ "x$mount_path" = 'x' ] && echo_err_exit "-p [path] required"
  [ "x$ra_kb_size" = 'x' ] && report=1

  # mount_path and size validation done in argument parsing
  path_array=( $mount_path:$ra_kb_size )
fi

#
# main work loop
#
for path_size_val in ${path_array[@]} ; do
  # get devices, do sanity check
  block_devices=( $(get_block_devs_for_dir ${path_size_val/:*}) )
  [ ${#block_devices[@]} -eq 0 ] && \
    echo_err "failed to identify block devices used by $mount_path." && \
    continue

  # report requested? 'ere ya go!
  [ $report -eq 1 ] && show_all_read_ahead_kb_block ${path_size_val/:*} | column -t

  # this would only happen if NOT using settings file and size not set
  [ "x${path_size_val/*:}" = 'x' ] && exit

  # if not root, quit now
  [ $user_id -ne 0 ] && echo_err_exit 'non-root: blockdev requires root'

  for main_loop_dev in ${block_devices[@]} ; do
    set_read_ahead_kb_val $main_loop_dev ${path_size_val/*:}
  done

  # report requested? 'ere ya go again!
  [ $report -eq 1 ] && show_all_read_ahead_kb_block ${path_size_val/:*}
done

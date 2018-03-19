#!/bin/bash

# defaults
noop=0
debug=0
dowhat=''
devlist=( )
wwids=( )

debug () {
  [ $debug -eq 1 ] && echo -e "DEBUG: $@" 1>&2
}

debug_func () {
  [ $debug -eq 1 ] && echo -e "( DEBUG_FUNC: '${FUNCNAME[1]}' args: $@ )" 1>&2
}

# allow for sourced script to run safely
exit_safe () {
  debug_func $@
  code="$1" ; shift
  echo "$@"
  [[ "${BASH_SOURCE[0]}" != "${0}" ]] && return $code
  exit $code
}

usage () {
  cat <<EOF
  usage forms:
    $0 cleanall|all
    $0 wwid:[WWID] [wwid:[WWID]] ...
    $0 dev1 [dev2] ...
  * these may not be mixed.

  ACTIONS (pick only 1)

  cleanll|all
    Will attempt to remove all block devices used by WWIDs that ONLY include
    'failed' or 'faulty' paths. WWIDs that are only partially failed will be
    noted.
    This will rerun up to 4 more times if any are cleaned.

  wwid:[wwid] [wwid:[wwid]] ...
    Will attempt to forcibly remove devices used by WWID(s), and if successfull,
    the WWID iteself. Runs regardless of the current status of the WWID and
    it's devices.

  dev1 [dev2] ...
    Will attempt to forcibly remove all listed devices. Runs regardless of the
    current status of the devices.

  OPTIONS

  noop
    Announce what this would have done.

  debug
    Dumps hopefully useful debug output while running, and all functions
    announce their arguments (chatty!)

  example usage:
    $0 cleanall
    $0 wwid:3600a098038303771345d49656b304d6b noop
    $0 sdc sdl
    $0 sdc sdl sdd sde

  For all [dev] devices this script will, if the device exists:
    Flush it:  /sbin/blockdev --flushbugs /dev/[dev]
    Delete it: echo 1 > /sys/block/[dev]/device/delete
  then, if acting on a WWID, flush it (if empty, should be removed)
  finally, finish up with a list of all block devices via blkid, which
    reportedly makes the system take a 'fresh look' at what is going on.

EOF
  exit_safe 0
}

noop () {
  debug_func $@
  if [ $noop -eq 1 ] ; then
    echo "NOOP: $@"
    return 0
  else
    eval $@ 2>&1
  fi
}

# this is necessary as blkid may hang
safe_blkid () {
  debug_func $@
  blkid_output="$( timeout 5 /sbin/blkid $@ 2>&1 )"
  local blkid_err=$?
  [ $blkid_err -eq 124 ] && echo 'blkid call timed out'
  return $blkid_err
}

delete_block_dev () {
  debug_func $@
  dev=$1
  # verif we got an arg
  [ -z "$dev" ] && \
    echo "called without arg, got: '$@'" && \
    return 1

  echo -n "flushing '$dev'... "
  noop "/sbin/blockdev --flushbufs /dev/$dev"
  flusherr=$?

  if [ $flusherr -eq 0 ] ; then
    echo -n "deleteing '$dev'... "
    noop "echo 1 > /sys/block/$dev/device/delete"
    return $?
  else
    return $flusherr
  fi
}

# deletes list of provided devs - returns on first error
remove_dev_list () {
  debug_func $@
  indevs="$@"
  if [ -z "$indevs" ] ; then
    echo 'clean_dev_list called without device list'
    return 1
  else
    for dev in $indevs ; do
      delete_block_dev $dev
      err=$?
      [ $err -ne 0 ] && echo "failed to delete block dev '$dev'" && return 1
    done
  fi
  return 0
}

# create global var 'multipath_cleaned'
get_clean_multipath_output () {
  debug_func $@

  # mulipath output includes unnecessary information and
  #  is formatted slightly different depending on OS. yes, really.

  # example C6 multipath -ll output...:
  # :: 3600a098038303771345d49656b305745 dm-3 NETAPP,LUN C-Mode
  # :: size=200G features='4 queue_if_no_path pg_init_retries 50 retain_attached_hw_handle' hwhandler='1 alua' wp=rw
  # :: |-+- policy='round-robin 0' prio=0 status=enabled
  # :: | `- 9:0:0:10  sdi 8:128  failed faulty running
  # :: `-+- policy='round-robin 0' prio=0 status=enabled
  # ::   `- 4:0:0:10  sdb 8:16   failed faulty running
  # :: 3600a0980383034674b2b46584173756e dm-9 NETAPP,LUN C-Mode
  # :: size=10T features='4 queue_if_no_path pg_init_retries 50 retain_attached_hw_handle' hwhandler='1 alua' wp=rw
  # :: |-+- policy='round-robin 0' prio=50 status=active
  # :: | `- 3:0:0:90  sdv 65:80  active ready running
  # :: `-+- policy='round-robin 0' prio=10 status=enabled
  # ::   `- 5:0:0:90  sdx 65:112 active ready running
  # ...is transformed into:
  # :: 3600a098038303771345d49656b305745
  # :: _sdi 8:128 failed faulty running
  # :: _sdb 8:16 failed faulty running
  # :: 3600a0980383034674b2b46584173756e
  # :: _sdv 65:80 active ready running
  # :: _sdx 65:112 active ready running

  # below results in a clean list of multipath followed by device paths
  # : strip lines that include size
  # : remove various symbols, cleanup spaces
  # : grab only lines that start with WWIDs and the device paths
  # : and finally remove unneeded info at beginning of device path lines

  multipath_cleaned="$( /sbin/multipath -ll | \
    grep -v size | \
    sed -e 's/[\\_\`+|-]//g' -e 's/\ \+/ /g'  | \
    grep -o -e '^[0-9a-z]*' -e '^ [0-9]\+:.*' | \
    sed -e 's/^\ [0-9]\+:[^\ ]*\ / /g' -e 's/^\ \+/_/g'
  )"
  debug "multipath_cleaned:\n$multipath_cleaned"
}

# get paths for a WWID, listed one per line
get_paths_for_wwid() {
  debug_func $@

  # output format: dev:status
  # example output (depending on OS):
  #  sdc:failed
  #  sdc:[failed][faulty][running]

  wwid="$1"
  found=0
  # loop through $multipath_cleaned until wwid found, then capture devices
  #  once new wwid found, stop.
  while read line ; do
    # we're done, but the pipe HEREDOC will keep open
    [ $found -eq 3 ] && continue

    # not found yet, maybe this time?
    if [ $found -eq 0 ] ; then
      # found it, go to read next $line
      if [[ $line = $wwid ]] ; then
        found=1
        continue
      fi
      # not found yet, try next $line
      continue
    fi

    ### we've found it if you're here

    # if line does NOT start with an underscore, then we're done
    [[ $line != _* ]] && found=3 && continue

    # this must be a device. output device:status
    dev_stat="$(echo "$line" | cut -d' ' -f1,3- | sed 's/^_//g')"
    echo "$dev_stat"
    debug "found dev line for wwid: $line"
    debug "converted to dev:status: $dev_stat"

  done <<< "$(echo -e "$multipath_cleaned")"
}

# remove a single wwid whether ok or not
remove_wwid () {
  debug_func $@

  local wwid="${1#*:}"

  # did we get wwid
  [ -z "$wwid" ] && exit_safe 1 'WWID not provided.'
  # is wwid a dev
  [ ! -e "/dev/mapper/$wwid" ] &&  exit_safe 1 "WWID '$wwid' not present"
  # does it point at/is it a real dev
  [ ! -b $(readlink -f /dev/mapper/$wwid) ] && \
    exit_safe 1 "provided WWID does not point at a block dev; see /dev/mapper/$wwid"

  # if multipath_cleaned var isn't set, get it
  [ -z "$multipath_cleaned" ] && get_clean_multipath_output

  wwid_devs="$(get_paths_for_wwid $wwid | sed -e 's/:.*//g' -e 's/ .*//g')"

  if [ -n "$wwid_devs" ] ; then
    echo "cleaning devices for WWID $wwid"
    remove_dev_list $wwid_devs
    devremerr=$?
    if [ $devremerr -ne 0 ] ; then
      echo "failed to remove some devices. skipping WWID '$wwid' flush"
      return $devremerr
    fi
  fi

  # sometimes above is all it takes for the WWID to be released. Refresh...
  get_clean_multipath_output
  wwid_devs="$(get_paths_for_wwid $wwid | sed -e 's/:.*//g' -e 's/ .*//g')"
  if [ -n "$wwid_devs" ] ; then
    echo "all devs removed, WWID already released"
    return
  fi
  echo "all devices for WWID removed, or non present. flushing WWID '$wwid'"
  noop "/sbin/multipath -f $wwid"
  flusherr=$?
  [ $flusherr -ne 0 ] && echo "flush attempt returned: $flusherr"
  return $flusherr
}

# no checking if WWID is ok or not, just remove.
remove_wwids () {
  debug_func $@
  [ ${#wwids[@]} -eq 0 ] && exit_safe 1 'WWID not provided'
  for wwid in ${wwids[@]} ; do remove_wwid $wwid ; done
}

# attempt cleanup of all WWIDs with only failed or faulty paths
clean_all () {
  debug_func $@

  # this can be reran 4 more times, once this hits 5 runs, give up
  # unless running noop mode
  for ((runcount=1 ; runcount<6 ; runcount++)) ; do
    echo -e "\n----- BEGIN CLEAN ALL RUN $runcount (max 5) -----"
    get_clean_multipath_output
    wwidList=( $(echo "$multipath_cleaned" | grep '^[0-9a-z]') )

    [ -z "$wwidList" ] && echo "No WWIDs identified" && return 1
    wwidStatus=( )
    needswork=0

    for wwid in ${wwidList[@]} ; do
      wwidPaths="$(get_paths_for_wwid $wwid)"
      # wwidPathsCount is used to compare against failedcount later
      wwidPathsCount=$(echo "$wwidPaths" | grep -c ^)
      if [ -z "$wwidPaths" ] ; then
        echo "no paths found for WWID '$wwid' or it doesn't exist."
        echo 'attempting delete anyway'
      else
        failedCount=$( echo "$wwidPaths"| grep -e fail -e faulty | grep -c ^ )
        failedComp=$(( 100*($wwidPathsCount-$failedCount)/$wwidPathsCount ))
        # wwidPathOut is only for displaying output
        wwidPathOut="$(echo "$wwidPaths"|tr '\n' '|' | sed 's/|$//g')"
        if [ $failedComp -eq 100 ] ; then
          # echo "OK:        $wwid : $wwidPathOut"
          continue
        fi
        if [ $failedComp -ne 0 ] ; then
          echo "UNCERTAIN: $wwid : $wwidPathOut - SKIPPING"
         continue
        fi
        echo   "FAILED:    $wwid : $wwidPathOut - attempting to clean"
      fi
      needswork=1
      remove_wwid $wwid
    done
    if [ $needswork -eq 0 ] ; then
      echo 'No WWIDs now contain only failed paths'
      return 0
    fi
    echo "----- END CLEAN ALL RUN $runcount (max 5) -----"
    if [ $noop -eq 1 ] ; then
      echo -e "NOOP: ending at first run\n"
      break
    else
      echo
    fi
  done

  echo "After $runcount runs some WWIDs still contain only failed or faulty paths."
  echo 'Giving up to prevent an endless script. You may attempt this again.'
  return 1
}

dowhat () {
  debug_func $@
  [[ -n "$dowhat" && "$dowhat" != "$1" ]] && \
    exit_safe 1 "only one action allowed. already doing '$dowhat'; '$1' not allowed."
  dowhat="$1"
}

while [ $# -gt 0 ] ; do
  ARG="$1" ; shift
  case "$ARG" in
    -h|--help|'-?' ) usage ;;
    noop           ) noop=1 ;;
    debug          ) debug=1 ;;
    cleanall|all   ) dowhat clean_all ;;
    wwid:*         ) dowhat remove_wwid     ; wwids[${#devlist[@]}]="${ARG##:*}" ;;
    *              ) dowhat remove_dev_list ; devlist[${#devlist[@]}]="$ARG" ;;
  esac
done

[ -z "$dowhat" ] && \
  exit_safe 1 'action not identified. see usage.'

[ -x "$(which multipath 2> /dev/null)" ] || \
  exit_safe 1 'failed to locate multipath command'

# now handle the dowhat, verifiying we have the args necessary
case "$dowhat" in
  clean_all       ) clean_all ;;
  remove_wwid     ) remove_wwids ;;
  remove_dev_list ) remove_dev_list ${devlist[@]} ;;
  *               ) exit_safe 1 "unexpected action: '$dowhat'" ;;
esac
runerr=$?
if [ $runerr -ne 0 ] ; then
  exit_safe 1 "failed to perform '$dowhat' (got error: $runerr)"
fi

echo -e "\nlisting/refreshing list of block devices (blkid)."
safe_blkid
blkid_err=$?
if [ $blkid_err -eq 0 ]
  then debug "$blkid_output"
  else echo "blkid called failed. Error #: $blkid_err"
fi
exit_safe $blkd_err

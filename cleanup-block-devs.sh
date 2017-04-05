#!/bin/bash

usage () {
  cat <<EOF
  usage forms:
    $0 cleanall|all
    $0 wwid:[WWID]
    $0 [dev1] [dev2] ...

  cleanll|all       : Will attempt to remove all block devices used by WWIDs
                        that ONLY include 'failed' paths.
                    : WWIDs that are only partially failed will be noted.
                    : This will rerun up to 4 more times if any are cleaned.
                    : ANY FOLLOWING ARGS ARE IGNORED

  wwid:[wwid]       : Will attempt to remove devices used by WWID [wwid]
                    : ANY FOLLOWING ARGS WILL BE IGNORED

  [dev1] [dev2] ... : Will attempt to remove all listed devices

  example usage:
    $0 cleanall
    $0 wwid:3600a098038303771345d49656b304d6b
    $0 sdc sdl
    $0 sdc sdl sdd sde

  For all [dev] devices this script will, if the device exists:
    Flush it:  /sbin/blockdev --flushbugs /dev/[dev]
    Delete it: echo 1 > /sys/block/[dev]/device/delete
  and then finish up with a list of all block devices via blkid, which
    reportedly makes the system take a 'fresh look' at what is going on.

  DEBUGGING
  If the word 'debug' is the FIRST argument:
    * multipath -ll will not be used instead; it's output will be faked by the
      contents of 'fake-multipath-output'
    * device(s) will not be verified to exist
    * device flush(es) will be skipped
    * device deletes will be skipped
    * the debug argument is discarded and the rest of the args treated as above.
  Example:
    $0 debug cleanall
EOF
  exit
}

safe_blkid () {
# this is necessary as blkid may hang
  blkid_output="$( timeout 5 /sbin/blkid $@ 2>&1 )"
  blkid_err=$?
  [ $blkid_err -eq 124 ] && echo 'blkid call timed out'
  return $blkid_err
}

delete_block_dev () {
  dev=$1
  # verif we got an arg
  [ "x$dev" = 'x' ] && \
    echo 'called without arg' && \
    return 1
  # verif block device exists
  if [ ! -e /sys/block/$dev -a "x$debug" = 'x' ] ; then
    echo "block dev $dev not present - SKIPPING"
    return 1
  fi

  echo -n "flushing $dev... "
  if [ "x$debug" = 'x1' ]
    then echo -n '(debug,skipping) '
    else /sbin/blockdev --flushbufs /dev/$dev
  fi

  echo -n "deleteing $dev... "
  if [ "x$debug" = 'x1' ]
    then echo '(debug:skipping)'
    else echo 1 > /sys/block/$dev/device/delete
  fi
}

clean_dev_list () {
  indevs="$@"
  if [ "x$indevs" = 'x' ] ; then
    echo 'clean_dev_list called without device list'
  else
    for dev in $indevs ; do
      delete_block_dev $dev
    done
  fi
}

get_clean_multipath_output () {
# mulipath output includes unnecessary information and
#  is formatted slightly different depending on OS. yes, really.

  # below results in a clean list of multipath followed by device paths
  # : strip lines that include size
  # : remove various symbols, cleanup spaces
  # : grab only lines that start with WWIDs and the device paths
  # : and finally remove unneeded info at beginning of device path lines

  if [ "x$debug" = 'x1' ] ; then
    MULTIPATH='cat fake-multipath-output'
  else
    MULTIPATH='/sbin/multipath -ll'
  fi
  multipathUseful="$( $MULTIPATH | grep -v size | \
    sed -e 's/[\\_\`+|-]//g' -e 's/\ \+/ /g'  | \
    grep -o -e '^[0-9a-z]*' -e '^ [0-9]\+:.*' | \
    sed -e 's/^\ [0-9]:[^\ ]*\ / /g' -e 's/^\ \+/_/g'
  )"
}

get_paths_for_wwid() {
# get paths for a WWID, listed one per line
# output format: dev:status
# example output (depending on OS):
#  sdc:failed
#  sdc:[failed][faulty][running]

  wwid="$1"
  found=0
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
    echo "$line" | awk '{print $1":"$3}' | sed 's/^_//g'
  done <<< "$(echo -e "$multipathUseful")"
}

clean_wwid () {
# cleanup a single wwid. Similar to cleanALL, but act only on a single
# command line declared wwid

  local wwid="${1#*:}"

  # if multipathUseful var isn't set, get it
  [ "x$multipathUseful" = 'x' ] && get_clean_multipath_output

  wwid_devs="$(get_paths_for_wwid $wwid | sed 's/:.*//g')"

  if [ "x$wwid_devs" = 'x' ] ; then
    echo "unable to identify devices for WWID $wwid"
    return 1
  else
    echo "cleaning devices for WWID $wwid"
    clean_dev_list $wwid_devs
  fi
}

cleanAll () {
# remove all block devices used by WWIDs that ONLY include 'failed' paths.

  # this can be reran 4 more times, once this hits 5 runs, give up
  runcount=0

  while [ $runcount -lt 5 ] ; do
    ((runcount++))
    echo -e "\n----- BEGIN CLEAN ALL RUN $runcount (max 5) -----"
    get_clean_multipath_output
    wwidList=( $(echo "$multipathUseful" | grep '^[0-9a-z]') )

    [ "x$wwidList" = 'x' ] && echo "No WWIDs identified" && return 1
    wwidStatus=( )
    needswork=0

    for wwid in ${wwidList[@]} ; do
      wwidPaths="$(get_paths_for_wwid $wwid)"
      # wwidPathsCount is used to compare against failedcount later
      wwidPathsCount=$(echo "$wwidPaths" | grep -c ^)
      [ "x$wwidPaths" = 'x' ] && \
        echo "no paths found for $wwid or it doesn't exist." && \
        continue
      failedCount=$( echo "$wwidPaths"| grep fail | tr ' ' '\n' | grep -c ^ )
      failedComp=$(( 100*($wwidPathsCount-$failedCount)/$wwidPathsCount ))
      # wwidPathOut is only for displaying output
      wwidPathOut="$(echo "$wwidPaths"|tr '\n' '|' | sed 's/|$//g')"
      if [ $failedComp -eq 100 ] ; then
        # echo "OK:        $wwid : $wwidPathOut"
        continue
      fi
      if [ $failedComp -ne 0 ] ; then
        echo "UNCERTAIN: $wwid : $wwidPathOut - SKIPPING"
      fi
      echo   "FAILED:    $wwid : $wwidPathOut - attempting to clean"
      needswork=1
      clean_wwid $wwid
    done
    if [ $needswork -eq 0 ] ; then
      echo 'No WWIDs now contain only failed paths'
      return 0
    fi
    echo -e "----- END CLEAN ALL RUN $runcount (max 5) -----\n"
  done
  echo 'After 5 runs some WWIDs yet contain only failed paths.'
  echo 'Giving up to prevent an endless script. You may attempt this again.'
  return 1
}

# no args , 'help' type args, debug arg handling
[ $# -eq 0        ] && usage
[ "$1" = '-h'     ] && usage
[ "$1" = '--help' ] && usage
[ "$1" = '-?'     ] && usage
[ "$1" = "debug"  ] && debug=1 && shift

case ${1%%:*} in
  omg|cleanall|all ) cleanAll          ;;
  wwid             ) clean_wwid $@     ;;
  *                ) clean_dev_list $@ ;;
esac

echo -e "\nlisting/refreshing list of block devices (blkid):"
safe_blkid
blkid_err=$?
if [ $blkid_err -eq 0 ]
  then echo "$blkid_output"
  else echo "blkid called failed. Error #: $blkid_err"
fi
exit $blkd_err

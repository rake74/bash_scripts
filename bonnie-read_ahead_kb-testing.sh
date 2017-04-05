#!/bin/bash
#set -ex
myname="$(basename $0)"

usage () {
  cat << EOF
Runs bonnie++ tests on block device(s) 

Usage: $myname [options]

Options:
  -l  - specify logFile
        default: /root/bonnie-testing

  -d  - specify test dir (on disk you want tested)
        note: actual test dir is at (location)/test
        default: /root

  -y  - delete testDir/test if it exists
        default: query user

  -r  - skip performing test and just regenerate output
        default: unset

  -s  - specify read_ahead_kb sizes you wish to test
        default '256 512 1024 2048 4096 8192 16384 32768'

Output modifiers options:
  -q  - hide bonnie++ output while running
        default: unset

  -qq - hide all output except results
        default: unset

  -h  - skip header in results tabulation
        default: unset

  -c  - print output in CSV format
        default: unset

Example:
  $myName -l /root/bonnie-tests-results -d /mnt/iscsi/10_db_storage

Notes:
  if test_dir/test exists it will be removed first.
  if logFile exists it will be removed first.

ToDo:
  Saving test results must be done manually. This is a little more obnoxious
  as usually the testDir and your logFile will be at separate locations

Requires:
  blockdev command, bonnie++ package, root privs.
EOF
  echo
  [ $# -gt 0 ] && echo -e "$@\n" && exit 1
  exit
}

# set defaults
testDir='/root'
logFile='/root/bonnie-testing'
rmtestDir=0
testOutput='tee'
loopOutput='tee'
noHeader=0
csvOutput=0
justRegenOutput=0
sizes=(256 512 1024 2048 4096 8192 16384 32768 )

# process arguments
while [ $# -gt 0 ] ; do
  ARG="$1" ; shift
  case $ARG in
    -l     ) logFile="$1" ; shift  ;;
    -d     ) testDir="$1" ; shift  ;;
    -y     ) rmtestDir=1           ;;
    -q     ) testOutput='cat >'    ;;
    -qq    ) testOutput='cat >' ;
             loopOutput='cat >'    ;;
    -h     ) noHeader=1            ;;
    -c     ) csvOutput=1           ;;
    -r     ) justRegenOutput=1     ;;
    -s     ) sizes=( $1 ) ; shift  ;;
    '-?'   ) usage                 ;;
    -h     ) usage                 ;;
    --help ) usage                 ;;
    *      ) usage "unk arg: $ARG" ;;
  esac
done

# ensure directories for test and logFile exist
[ ! -d $testDir ]            && usage "$testDir is not a dir or doesn't exist."
[ ! -d $(dirname $logFile) ] && usage "dir for '$logFile' doesn't exist."

# we ACTUALLY do tests in $testDir/test
targetDir="$testDir/test"

# this identifies all block devices behind the path - multipath makes fun
getBlockDevsForDir () {
  whichDir="$1"
  mainDev=$(readlink -f $(df -P $whichDir|tail -n1| cut -d\  -f1) | sed 's,^.*/,,g')
  realDevs=$(lsblk -i | \
    grep -e '^[a-zA-Z]' -e "$mainDev " -e "($mainDev)" | \
    grep -B1            -e "$mainDev " -e "($mainDev)" | \
    grep -e '^[a-zA-Z]' | \
    cut -d\  -f1)
  echo $mainDev $realDevs | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/\ \+$//g'
}

do_bonnie_test () {
  DIR="$targetDir/$size"
  mkdir -p $DIR
  rm -rf $DIR/*
  echo running: bonnie++ -d $DIR -r $mem -u root
  bonnie++ -d $DIR -r $mem -u root 2>&1 | eval $testOutput $DIR/results
  echo 'finished bonnie++ test'
}

is_integer () {
  case ${1#[-+]} in
    ''|*[!0-9]* ) return 1 ;;
    *           ) return 0 ;;
  esac
}

doTests () {
  # get devices for path (yay multipath, lvm, etc)
  devsToActOn="$(getBlockDevsForDir $testDir)"
  [ "$devsToActOn-" = '-' ] && usage "unable to determine blocks devices for $testDir"
  for dev in $devsToActOn ; do
    [ ! -e /dev/$dev       ] && usage "unable to locate '/dev/$dev'"
    [ ! -e /sys/block/$dev ] && usage "unable to locate '/sys/block/$dev'"
  done
  
  [ "$(which bonnie++ 2>/dev/null)-" = '-' ] && usage 'unable to locate bonnie++'
  
  # if previous tests, or other contents, exists at location
  # shall we delete it or quit?
  if [ -e $targetDir ] ; then
    if [ $rmtestDir -eq 1 ] ; then
      rm -rf $targetDir
    else
      echo -n "$targetDir exists, shall I delete it? "
      read -n1 ANS ; echo
      [ "x$ANS-" != 'xy-' ] && echo 'ok, quitting.' && exit
      rm -rf $targetDir
    fi
  fi
  
  # clear logFile
  [ ! -e $logFile ] && rm -f $logFile
  
  mem=$(free -mo | grep ^Mem: | awk '{print $2}')
  
  echo "$(date +"%F %T") | acting on devs: $devsToActOn" | eval $loopOutput $logFile

  # get sizes to start with so we can put them back when we're done
  startSizes=( $(for dev in $devsToActOn ; do
    echo -n $dev:
    blockdev --getra /dev/$dev
  done) )

  # loop through sizes (static list for now) and performe tests
  for size in ${sizes[@]} ; do
    ! is_integer $size && \
      echo "size '$size' is not an integer, skipping" && continue
    for blockDev in $devsToActOn ; do
      echo -n "dev $blockDev setting $size "
      echo -n "blockdev:$(blockdev --setra $size /dev/$blockDev ; blockdev --getra /dev/$blockDev) "
      grep -H ^ /sys/block/$blockDev/queue/read_ahead_kb
    done
    do_bonnie_test $size
  done 2>&1 | while read line ; do echo -e "$(date +"%F %T") | $line" ; done | eval $loopOutput $logFile

  # return devices to their original size pre-testing
  for devSize in ${startSizes[@]} ; do
    Dev="${devSize/:*}"
    Siz="${devSize/*:}"
    blockdev --setra $Siz /dev/$Dev
  done
  blockdev --setra $startSize /dev/$blockDev
}

[ $justRegenOutput -eq 0 ] && doTests

output="$(
[ $noHeader -eq 0 ] && echo 'blockSize : KBSize =>  DataSize WriteSpd ReWriteSpd ReadSpd'
for file in $(find $targetDir/*/results | sort -V) ; do
  setting="$(echo $file | grep -o '[0-9]*/results' | cut -d/ -f1)"
  kbBlock="$(grep "setting $setting " $logFile | tail -n1 | sed 's/^.*://g')"
  echo -n "$setting : $kbBlock => "
  grep $HOSTNAME $file | sort -V | cut -d, -f6,10,12,16 | tr ',' ' '
done
)"

if [ $csvOutput -eq 0 ]
  then echo -e "$output" | column -t
  else echo -e "$output" | \
    sed \
      -e 's/ : / /g'   \
      -e 's/ => / /g'  \
      -e 's/\ \+/ / g' | \
    tr ' ' ','
fi | tee -a $logFile

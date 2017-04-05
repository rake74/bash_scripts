#!/bin/bash

usage () {
  myName="$(basename $BASH_SOURCE)"
  cat << EOF
  $myName - list OpenVPN sessions information

  Arguments:
    -h | --nohead  Skip printing the header

    -f | --files   Status file selection. Default: /etc/openvpn/*status*

    -r | --raw     Print out raw data
                   Note: fields separated by spaces,
                         underscores used to denote spaces WITHIN field

    -c [arg]       Column selection
                   Note: columns selected as raw above.  Usage as used by cut -f"[arg]"

    -s [arg]       Sort arguments
                   Note: sorted after COLUMNS selection. Usage as used by sort.

    Notes:
      When spaces are included in an [arg], surrouned it with quotes.
      Username is identied by client connection. When a session is found to not be
        fully setup, and a username is identified (perhaps previous connection), then
        username will be surrouned by ? marks, indicating it's a guess: ?jdoe?

    Default columns with column #:
      1 - SERVER
      2 - AD-USER
      3 - EXT-IP
      4 - INT-IP
      5 - START
      6 - LAST-REF
      7 - DAYS-TIME
      8 - BYTES-IN
      9 - BYTES-OUT

    Sort column selection is based on columns left after column selection.

  Example:
    Print just username, session length, sorted by length connected at top, w/o header:
      $myName -c 2,7 -s -rk2
    Print just username, internal IP, Bytes Out, sorted by internal IP:
      $myName -c 2,4,9 -s -Vk2
    Print just status fro 1194 or 1194-tcp servers, sorted by username:
      $myName -f /etc/openvpn/openvpn-status-1194* -s -k2
EOF
  exit
}

noheader=0
raw=0
colsel="1-"
statfiles='/etc/openvpn/*stat*'

while [[ $# > 0 ]] ; do
  arg="$1"
  shift
  case "$arg" in
    "-h"        ) noheader=1             ;;
    "--nohead"  ) noheader=1             ;;
    "-r"        ) raw=1                  ;;
    "--raw"     ) raw=1                  ;;
    "-s"        ) sortOpts="$1"  ; shift ;;
    "-c"        ) colsel="$1"    ; shift ;;
    "--columns" ) colsel="$1"    ; shift ;;
    "-f"        ) statfiles="$1" ; shift ;;
    "--files"   ) statfiles="$1" ; shift ;;
    *           ) usage                  ;;
  esac
  unset arg
done

if [ $raw -eq 1 ] ; then
  colcat='cat'
  trrep=' '
else
  colcat='column'
  trrep='_'
fi

SessionList="$( grep ^UNDEF $statfiles | cut -d, -f2 )"
{
  if [ $noheader -eq 0 -a $raw -eq 0 ] ; then
    echo "SERVER AD-USER EXT-IP INT-IP START LAST-REF DAYS-TIME BYTES-IN BYTES-OUT"
    echo "------ ------- ------ ------ ----- -------- --------- -------- ---------"
  fi | cut -d\  -f$colsel
  {
    for Client in $SessionList ; do
      unset ClientRaw Server BytesI BytesO StartRaw LastRaw IntIP StartSec LastSec LengthRaw Length Start Last UserName
      ClientRaw="$( grep "${Client}" /etc/openvpn/*status* | sed 's/\.log//g')"
      Server="$(   echo "${ClientRaw}" | cut -d: -f1 | sed 's,^/etc/openvpn/openvpn-status-,,g' | sort -u)"
      BytesI="$(   echo "${ClientRaw}" | grep    ':UNDEF,' | cut -d, -f3)"
      BytesO="$(   echo "${ClientRaw}" | grep    ':UNDEF,' | cut -d, -f4)"
      StartRaw="$( echo "${ClientRaw}" | grep    ':UNDEF,' | cut -d, -f5)"
      LastRaw="$(  echo "${ClientRaw}" | grep -v ':UNDEF,' | cut -d, -f4)"
      IntIP="$(    echo "${ClientRaw}" | grep -v ':UNDEF,' | cut -d, -f1 | cut -d: -f2)"
    
      StartSec="$( date -d "${StartRaw}" +%s)"
      LastSec="$(  date -d "${LastRaw}"  +%s)"
      LengthRaw=$((LastSec-StartSec))
      Length="$( printf '%02d_d_%02d:%02d:%02d\n' $(($LengthRaw/86400)) $(($LengthRaw%86400/3600)) $(($LengthRaw%3600/60)) $(($LengthRaw%60)) )"
      Start="$( date -d "${StartRaw}" +'%F_%T')"
      Last="$(  date -d "${LastRaw}"  +'%F_%T')"
    
      UserName="$( grep $Client /var/log/messages | grep 'authentication succeeded for username' | tail -n1 | cut -d\' -f2)"
    
      if [ "x$LastRaw-" = "x-" ] ; then
       Length=""
       Last=""
       [ "x$UserName-" != 'x-' ] && UserName="?${UserName}?"
      fi
    
      echo "${Server:-n/a} ${UserName:-n/a} ${Client:-n/a} ${IntIP:-n/a} ${Start:-n/a} ${Last:-n/a} ${Length:-n/a} ${BytesI:-n/a} ${BytesO:-n/a}"
    done
  } | cut -d\  -f$colsel | sort $sortOpts
} | $colcat -t | tr "$trrep" ' '

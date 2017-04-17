#!/bin/bash

# these are what nagios expects.
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3
STATE_DEPENDENT=4

# functions to collect and output messages, etc.
add_crit_msg () { crit_msg="$crit_msg / $@" ; }
add_warn_msg () { warn_msg="$warn_msg / $@" ; }
add_unkn_msg () { unkn_msg="$unkn_msg / $@" ; }
msg_check () {
  if [ "x$crit_msg-" != 'x-' ] ; then
    echo -e "${crit_msg# / }"
    exit $STATE_CRITICAL
  fi
  if [ "x$warn_msg-" != 'x-' ] ; then
    echo -e "${warn_msg# / }"
    exit $STATE_WARNING
  fi
  if [ "x$unkn_msg-" != 'x-' ] ; then
    echo -e "${unkn_msg# / }"
    exit $STATE_UNKNOWN
  fi
  # nothing found, return to continue
  return 0
}

# some mathy functions
math () { echo "$@" | bc ; }
is_integer () {
  case ${1#[-+]} in
    ''|*[!0-9]* ) return 1 ;;
    *           ) return 0 ;;
  esac
}

# test if param apears to be an IPv4 address
is_ipv4 () {
  echo "$1" | { IFS=. read a b c d e;
    test "$a" -ge 0 && test "$a" -le 255 && \
    test "$b" -ge 0 && test "$b" -le 255 && \
    test "$c" -ge 0 && test "$c" -le 255 && \
    test "$d" -ge 0 && test "$d" -le 255 && \
    test -z "$e"
  } &> /dev/null
}

# test ability to connect to $1:$2
# CentOS7 netcat/nc does not support -z test option
testConn () {
  timeout $TimeOut bash -c "</dev/tcp/$1/$2"
  err=$1
  [ $err -ne 0 ] && TimeOutErr $err "verifying connectivity to $HostPort"
  return $err
}

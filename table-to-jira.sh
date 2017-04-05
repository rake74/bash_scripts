#!/bin/bash

myName="$(basename $0)"

usage () {
  cat << EOF
Paste or pipe excel data to $myName and Jira formatted table will be printed.
(This assume the excel data will be tab separated.)

When pasting data, indicate input complete via 'Ctrl-D' on a new/blank line.

Options:
 -H   first line is a header.
 -p   pretty print so table is still readable (at least for mono fonts)
      if you have a command 'mycolumn' available, this script will use that,
      otherwise it will use 'column -t'
 -d   change delimiter from 'tab' to whatever you specify (e.g.: -d ',')

EOF
  exit $1
}

hasHeader=0
pretty=0
delim="$(echo -e "\t")"

while [ $# -gt 0 ] ; do
  arg="$1" ; shift
  case $arg in
    -H )             hasHeader=1        ;;
    -p )             pretty=1           ;;
    -d )             delim="$1" ; shift ;;
    -h|--help|'-?' ) usage ; exit       ;;
    * ) echo -e "unknown arg: $1 (Try $myName -?)" 1>&2 ; exit 1 ;;
  esac
done

formatIt () {
  bar='|'
  [ $hasHeader -eq 1 ] && bar='||'
  echo "$@" | sed \
      -e 's/^\ \+//g'  \
      -e 's/\ \+$//g'  \
      -e "s/\ /~/g"    \
      -e "s/^/$bar /g" \
      -e "s/$/ $bar/g" \
      -e "s/$delim/ $bar /g"
  hasHeader=0
}

basework="$( while read line ; do formatIt "$line" ; done )"

case $pretty in
  '0' ) outM='cat' ;;
  '1' )
    if [ $(which mycolumn &> /dev/null ; echo $?) -eq 0 ]
      then outM='mycolumn'
      else outM='column -t'
    fi
    ;;
esac


echo "$basework" | $outM | sed 's/~/ /g'

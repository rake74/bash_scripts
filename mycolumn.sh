#!/bin/bash

myName="$(basename $0)"
usage () {
  cat << EOF
This take input from a pipe or STDIN and prints it in columnar format.

Options:
-c  Draw column separators
-C  specify column separators - can be any arbitrary string (assumes -c)
EOF
  exit $1
}

while [ $# -gt 0 ] ; do
  ARG=$1 ; shift
  case $ARG in
    -c ) colDiv=1 ;;
    -C ) colDiv=1 ; colSep="$1" ; shift ;;
    '-?'|-h|--help ) usage ;;
    *  ) echo "unknown arg: $ARG" ; exit 1 ;;
  esac
done

# get input
input="$(while read X ; do echo "$X" ; done)"

# calculate each column's max width saved in colsW array
#  by parsing the entire data set line by line, word by word
while read X ; do
  XArr=( $X )
  for (( x=0 ; x<${#XArr[@]} ; x++ )) ; do
    [ ${colsW[$x]:-0} -lt ${#XArr[$x]} ] && colsW[$x]=${#XArr[$x]}
  done
done <<< "$(echo -e "$input")"

# now print the data padding with spaces as needed
while read X ; do
  XArr=( $X )
  for (( x=0 ; x<${#XArr[@]} ; x++ )) ; do
    [ ${colDiv:-0} -eq 1 ] && echo -n "${colSep:-|} "
    printf "%-${colsW[$x]}s" "${XArr[$x]}"
    [ $x -lt ${#XArr[@]} ] && echo -n ' '
  done
  [ ${colDiv:-0} -eq 1 ] && echo -n "${colSep:-|}"
  echo
  pastFirst=1
done <<< "$(echo -e "$input")"

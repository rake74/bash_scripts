#!/bin/bash

usage () {
  cat << EOF

  $0 -f [file] [openssl x509 options]

      -f [cert file]
  --file [cert file]
  --file=[cert file]  file from which to read certs

  Without a file argument, the script will process STDIN,
  which can be either from a pipe or 'pasted'.

  All other options are treated as openssl x509 options.
  Some commone ones:
    -noout
    -subject
    -issuer
    -startdate
    -enddate
    -dates
    -modulus
  see openxxl 509 -? for more.

  Note: options not understood by openssl x509 will generate openssl errors.

  Examples:
    cat chainfile | $0 -noout -subject -issuer
    $0 -f chainfile -noout -subject -dates

EOF
}

FILE='-'

while [ $# -gt 0 ] ; do
  ARG="$1" ; shift
  case "$ARG" in
    -f|--file ) FILE="$1" ; shift;;
    --file=*  ) FILE="${ARG/*=}" ;;
    -h|--help|-? ) usage ;;
    *         ) openssl_opts="$openssl_opts $ARG" ;;
  esac
done

cat $FILE | \
while read line ; do
  if [ "${line//END}" != "$line" ]; then
    txt="$txt$line\n"
    printf -- "$txt" | openssl x509 ${openssl_opts}
    echo
    txt=""
  else
    txt="$txt$line\n"
  fi
done

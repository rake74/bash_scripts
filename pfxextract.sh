#!/bin/bash

errecho () { echo -e "$@" 1>&2 ; }

while [ $# -gt 0 ] ; do
  ARG="$1" ; shift
  case "$ARG" in
    -f|--file ) CertFile="$1" ; shift ;;
    -p|--pass ) PassWord="$1" ; shift ;;
    --file=*  ) CertFile="${ARG#*=}" ;;
    --pass=*  ) PassWord="${ARG#*=}" ;;
    * ) errecho "Unknown arg '$ARG'; ignoring." ;;
  esac
done

getarg () {
  Var="$1"
  Desc="$2"
  Secret="$3"
  if [ -z "$Var" ] ; then
    echo 'Arg 1 (Var) not set, script error'
    exit 1
  fi
  if [ "$Secret" == '1' -o "$Secret" == 's' ]
    then read -s -p "$Desc: " ; echo
    else read -p "$Desc: "
  fi
  export "$Var"="$REPLY"
}

[ -z "$CertFile" ] && getarg CertFile "PFX/pkcs12 filepath"
[ -z "$PassWord" ] && getarg PassWord "PFX/pkcs12 password" s

if [ ! -e "$CertFile" ] ; then
  errecho "File Not found: '$CertFile'"
  exit 1
fi

FileRaw="${CertFile##*/}"
OutDir="$(dirname $CertFile)"

if [[ "$FileRaw" =~ \.pfx$ || "$FileRaw" =~ \.pkcs12$ ]]
  then OutFile="${FileRaw%.*}"
  else OutFile="$FileRaw"
fi

do_openssl () {
  passOpts="-passout pass: -passin pass:$PassWord"
  case "$1" in
    crt   ) echo -n 'Extracting cert... '  ; Opts='-clcerts' ;;
    chain ) echo -n 'Extracting chain... ' ; Opts='-cacerts' ;;
    key   ) echo -n 'Extracting key... '   ; Opts='-nocerts -nodes' ;;
    *     ) errecho "Ignored arg '$1'" ; return 1 ;;
  esac
#  openssl pkcs12 $Opts -in "$CertFile" -passout pass: -passin pass:$PassWord -out "$OutDir/$OutFile.$1"
  openssl pkcs12 -in "$CertFile" $passOpts $Opts -out "$OutDir/$OutFile.$1"
}

do_openssl crt
do_openssl chain
do_openssl key

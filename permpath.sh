#!/bin/bash

function permpath () {

  function permpath_clearvars () {
    unset -f permpath_usage permpath_walkdir permpath_printrow
    unset noheader noreadlink luser lgroup lperms lpath outarr
  }
  permpath_clearvars

  MyName=$FUNCNAME

  noheader=0
  noreadlink=0
  dirs=( )

  function permpath_usage () {
    echo "

    $MyName [space separated path list] [-H|-R|-h]
    Walks a path and identify the user, group, and permissions at each step.

    May be called with as many paths as desired.

    Options:
    -H     Skip printing header
    -r     Use readlink to get real/full path
    -R     Show output from both w/ and w/o readlink for path

    -h, --help, -?, --? print this message and exit (no work)

    Example:
    $MyName /var/lib/ /var/log -R -H"
    [ "x$@-" != "x-" ] && echo
    echo "$@"
    return
  }

  # read in all args and create array of paths, and looking for -h noheader flag
  # if not argument or valid path, skip it
  while [[ $# > 0 ]] ; do
    arg="$1"
    case "$arg" in
      "-H"                     ) noheader=1                        ;;
      "-r"                     ) noreadlink=1                      ;;
      "-R"                     ) noreadlink=2                      ;;
      "-h"|"--help"|"-?"|"--?" ) permpath_usage ; return                    ;;
      *                        ) [ -e "$arg" ] && dirs+=( "$arg" ) ;;
    esac
    shift
    unset arg
  done

  # set column header default widths
  if [ $noheader -eq 1 ] ; then
    luser=0 ; lgroup=0 ; lperms=0 ; lpath=0
  else
    luser=4 ; lgroup=5 ; lperms=5 ; lpath=4
  fi

  function permpath_walkdir () {
    dir="$1"
    [ ! -e "$dir" ] && echo "$dir doesn't seem to exist." 1>&2  && return

    # split path into array using / as separator
    # then postfix every element with /
    # e.g.: /home/bob becomes [0]="/" [1]="home/" [2]="bob/"
    # this allows for easily rebuilding path as we walk it
    OIFS=$IFS
    IFS="/" read -r -a dirpath <<< "$dir"
    dirpath=( "${dirpath[@]/%//}" )

    dirwalk=''
    for (( x=0 ; x<${#dirpath[@]} ; x++ )); do
      dirwalk="${dirwalk}${dirpath[x]}"
      # this next line is kind hacky
      # we already know the path exists
      # if dirwalk suddenly doesn't, then this is a /file/
      # so remove the last slash added above.
      [ ! -e "${dirwalk}" ] && dirwalk="$( echo "$dirwalk" | sed 's/\/$//g')"
      read auser agroup aperms <<<  $( echo "$(stat "$dirwalk" -c "%U %G %A")" )
      [ $luser  -lt ${#auser}   ] && export luser=${#auser}
      [ $lgroup -lt ${#agroup}  ] && export lgroup=${#agroup}
      [ $lperms -lt ${#aperms}  ] && export lperms=${#aperms}
      [ $lpath  -lt ${#dirwalk} ] && export lpath=${#dirwalk}
      outarr[${#outarr[@]}]="$auser $agroup $aperms $dirwalk"
    done
    unset dirpath OIFS dirwalk
  }

  # build outarr from each identified path arg
  for (( d=0 ; d<${#dirs[@]} ; d++ )) ; do
    case $noreadlink in
      0 ) permpath_walkdir "${dirs[$d]}"                    ;;
      1 ) permpath_walkdir "$( readlink -f "${dirs[$d]}" )" ;;
      2 ) permpath_walkdir "${dirs[$d]}"
          permpath_walkdir "$( readlink -f "${dirs[$d]}" )" ;;
    esac
  done

  # used later to print outarr
  function permpath_printrow () {
    auser="$1" ; shift
    agroup="$1" ; shift
    aperms="$1" ; shift
    apath="$@"
    printf "%-${luser}s %-${lgroup}s %-${lperms}s %-${lpath}s\n" \
             "${auser}"  "${agroup}"  "${aperms}"  "${apath}"
    unset auser agroup aperms apath
  }

  # print header unless told not to
  if [ $noheader -eq 0 ] ; then
    permpath_printrow user group perms path
    permpath_printrow $(printf '%*s' $luser|tr ' ' -)   \
             $(printf '%*s' $lgroup|tr ' ' -)  \
             $(printf '%*s' $lperms|tr ' ' -)  \
             $(printf '%*s' $lpath | tr ' ' -)
  fi

  # print results
  for (( x=0 ; x<${#outarr[@]} ; x++ )) ; do
    permpath_printrow ${outarr[$x]}
  done

  permpath_clearvars
  unset -f permpath_clearvars

}

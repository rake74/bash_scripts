#!/bin/bash

file="$1"

[ "x$file-" = "x-" ] && echo "Accepts one arg: filename" && exit
[ ! -e "$file" ] && echo "Accepts one arg: filename" && exit

echo -n "$file : "
puppet parser validate $file && echo "validated" && \
echo -n "$file : " &&  puppet-lint --fix --no-80chars-check $file && echo "linted"

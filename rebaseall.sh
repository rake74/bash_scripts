#!/bin/bash

mainline='production'
me="$(who am i | cut -d\  -f1)"
myBranches=( $(git branch --color=never | grep $me) )
startBranch=$(git symbolic-ref HEAD 2>/dev/null | sed 's/^.*\///g')

if [ $startBranch != "$mainline" ] ; then
  echo "Switching from $startBranch to $mainline"
  git checkout -q $mainline
fi

echo "updating $mainline branch"
git pull -q

echo pruning branches
git fetch --prune

prefix_it () { while read line ; do echo -e "$prefix $line" ; done }

count=${#myBranches[@]}
counter=0
for myBranch in ${myBranches[@]} ; do
  ((counter++))
  prefix="( $counter/$count ) $myBranch"

  (
    echo 'starting...'
    git checkout -q $myBranch 2>&1

    PreCommitID=$(git log --pretty=oneline -1 --no-color | cut -d\  -f1)
    git pull -q --rebase -u origin $mainline 2>&1
    PostCommitID=$(git log --pretty=oneline -1 --no-color | cut -d\  -f1)

    [ $PreCommitID = $PostCommitID ] && echo "already based off $mainline head" && continue
    echo "rebased off of $mainline head, pushing and watching"
    gitmco.sh 2>&1
  ) | prefix_it
done

echo "switching back to $startBranch"
git checkout -q $startBranch

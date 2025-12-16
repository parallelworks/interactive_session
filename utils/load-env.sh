#!/usr/bin/env bash
# These lines should not really be necessary but they are needed on some platforms for some reason
source /etc/profile.d/parallelworks.sh
source /etc/profile.d/parallelworks-env.sh

echod() {
    echo $(date): $@
}


displayErrorMessage() {
    echo $(date): $1
    # Jobs use this file to determine if another job has failed
    touch ERROR
    exit 1
}

failIfError(){
  if [ -f ERROR ]; then
    echo "One of the jobs failed. Exiting workflow..."
    exit 1
  fi
}

# export the users env file (for some reason not all systems are getting these upon execution)
while read LINE; do export "$LINE"; done < ~/.env

# load kerberos if it exists
if [ -d /pw/kerberos ];then
  echo "LOADING KERBEROS SSH PACKAGES"
  source /pw/kerberos/source.env
  which ssh kinit
fi

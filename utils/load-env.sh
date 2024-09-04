
# These lines should not really be necessary but they are needed on some platforms for some reason
source /etc/profile.d/parallelworks.sh
source /etc/profile.d/parallelworks-env.sh
source /pw/.miniconda3/etc/profile.d/conda.sh
conda activate

# export the users env file (for some reason not all systems are getting these upon execution)
while read LINE; do export "$LINE"; done < ~/.env

# load kerberos if it exists
if [ -d /pw/kerberos ];then
  echo "LOADING KERBEROS SSH PACKAGES"
  source /pw/kerberos/source.env
  which ssh kinit
fi


source lib.sh
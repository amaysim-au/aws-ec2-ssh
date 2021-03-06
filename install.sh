#!/bin/bash -e

show_help() {
cat << EOF
Usage: ${0##*/} [-hv] [-a ARN] [-i GROUP,GROUP,...] [-l GROUP,GROUP,...] [-s GROUP] [-p PROGRAM] [-u "ARGUMENTS"]
Install import_users.sh and authorized_key_commands.

    -h                 display this help and exit
    -v                 verbose mode.

    -a arn             Assume a role before contacting AWS IAM to get users and keys.
                       This can be used if you define your users in one AWS account, while the EC2
                       instance you use this script runs in another.
    -i group,group     Which IAM groups have access to this instance
                       Comma seperated list of IAM groups. Leave empty for all available IAM users
    -l group,group     Give the users these local UNIX groups
                       Comma seperated list
    -s group,group     Specify IAM group(s) for users who should be given sudo privileges, or leave
                       empty to not change sudo access, or give it the value '##ALL##' to have all
                       users be given sudo rights.
                       Comma seperated list
    -p program         Specify your useradd program to use.
                       Defaults to '/usr/sbin/useradd'
    -u "useradd args"  Specify arguments to use with useradd.
                       Defaults to '--create-home --shell /bin/bash'
    -d user            Which user the SSHD should run the authorized_keys_command as.
                       Default 'nobody'


EOF
}

SSHD_CONFIG_FILE="/etc/ssh/sshd_config"
AUTHORIZED_KEYS_COMMAND_FILE="/usr/local/bin/authorized_keys_command.sh"
IMPORT_USERS_SCRIPT_FILE="/usr/local/bin/import_users.sh"
MAIN_CONFIG_FILE="/etc/aws-ec2-ssh.conf"

IAM_GROUPS=""
SUDO_GROUPS=""
LOCAL_GROUPS=""
ASSUME_ROLE=""
USERADD_PROGRAM=""
USERADD_ARGS=""
RUNAS_USER="nobody"

while getopts :hva:i:l:s:d: opt
do
    case $opt in
        h)
            show_help
            exit 0
            ;;
        i)
            IAM_GROUPS="$OPTARG"
            ;;
        s)
            SUDO_GROUPS="$OPTARG"
            ;;
        l)
            LOCAL_GROUPS="$OPTARG"
            ;;
        v)
            set -x
            ;;
        a)
            ASSUME_ROLE="$OPTARG"
            ;;
        p)
            USERADD_PROGRAM="$OPTARG"
            ;;
        u)
            USERADD_ARGS="$OPTARG"
            ;;
        d)
            RUNAS_USER="$OPTARG"
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            show_help
            exit 1
            ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2
            show_help
            exit 1
    esac
done

wget -q "https://raw.githubusercontent.com/amaysim-au/aws-ec2-ssh/master/authorized_keys_command.sh" -O $AUTHORIZED_KEYS_COMMAND_FILE
chmod +x $AUTHORIZED_KEYS_COMMAND_FILE

wget -q "https://raw.githubusercontent.com/amaysim-au/aws-ec2-ssh/master/import_users.sh" -O $IMPORT_USERS_SCRIPT_FILE
chmod +x $IMPORT_USERS_SCRIPT_FILE

if [ "${ASSUME_ROLE}" != "" ]; then
    echo "ASSUMEROLE=\"${ASSUME_ROLE}\"" > $MAIN_CONFIG_FILE
else
    echo "ASSUMEROLE=\"\"" > $MAIN_CONFIG_FILE
fi

if grep -q '#AuthorizedKeysCommand none' $SSHD_CONFIG_FILE; then
    sed -i "s:#AuthorizedKeysCommand none:AuthorizedKeysCommand ${AUTHORIZED_KEYS_COMMAND_FILE}:g" $SSHD_CONFIG_FILE
else
    if ! grep -q "AuthorizedKeysCommand ${AUTHORIZED_KEYS_COMMAND_FILE}" $SSHD_CONFIG_FILE; then
        echo "AuthorizedKeysCommand ${AUTHORIZED_KEYS_COMMAND_FILE}" >> $SSHD_CONFIG_FILE
    fi
fi

if grep -q '#AuthorizedKeysCommandUser' $SSHD_CONFIG_FILE; then
    sed -i "s:#AuthorizedKeysCommandUser .*$:AuthorizedKeysCommandUser $RUNAS_USER:g" $SSHD_CONFIG_FILE
else
    if ! grep -q "AuthorizedKeysCommandUser $RUNAS_USER" $SSHD_CONFIG_FILE; then
        echo "AuthorizedKeysCommandUser $RUNAS_USER" >> $SSHD_CONFIG_FILE
    fi
fi

cat > /etc/cron.d/import_users_${IAM_GROUPS} << EOF
IAM_AUTHORIZED_GROUPS="${IAM_GROUPS}"
SUDOERS_GROUPS="${SUDO_GROUPS}"
LOCAL_GROUPS="${LOCAL_GROUPS}"
LOCAL_MARKER_GROUP="iam-synced-users"
ASSUMEROLE="${ASSUME_ROLE}"
USERADD_PROGRAM="${USERADD_PROGRAM}"
USERADD_ARGS="${USERADD_ARGS}"
SHELL=/bin/bash
PATH=/usr/local/bin:/bin:/usr/bin:/usr/local/sbin:/usr/sbin:/sbin:/opt/aws/bin
MAILTO=root
*/10 * * * * root $IMPORT_USERS_SCRIPT_FILE
EOF
chmod 0644 /etc/cron.d/import_users_${IAM_GROUPS}

IAM_AUTHORIZED_GROUPS="${IAM_GROUPS}" SUDOERS_GROUPS="${SUDO_GROUPS}" LOCAL_GROUPS="${LOCAL_GROUPS}" LOCAL_MARKER_GROUP="iam-synced-users" ASSUMEROLE="${ASSUME_ROLE}" USERADD_PROGRAM="${USERADD_PROGRAM}" USERADD_ARGS="${USERADD_ARGS}" $IMPORT_USERS_SCRIPT_FILE

# In order to support SELinux in Enforcing mode, we need to tell SELinux that it
# should have the nis_enabled boolean turned on (so it should expect login services
# like PAM and sshd to make calls to get public keys from a remote server)
#
# This is observed on CentOS 7 and RHEL 7

# Capture the return code and use that to determine if we have the command available
retval=0
which getenforce > /dev/null 2>&1 || retval=$?

if [[ "$retval" -eq "0" ]]; then
  retval=0
  selinuxenabled || retval=$?
  if [[ "$retval" -eq "0" ]]; then
    setsebool -P nis_enabled on
  fi
fi


# Restart sshd using an appropriate method based on the currently running init daemon
# Note that systemd can return "running" or "degraded" (If a systemd unit has failed)
# This was observed on the RHEL 7.3 AMI, so it's added for completeness
# systemd is also not standardized in the name of the ssh service, nor in the places
# where the unit files are stored.

# Capture the return code and use that to determine if we have the command available
retval=0
which systemctl > /dev/null 2>&1 || retval=$?

if [[ "$retval" -eq "0" ]]; then
  if [[ (`systemctl is-system-running` =~ running) || (`systemctl is-system-running` =~ degraded) ]]; then
    if [ -f "/usr/lib/systemd/system/sshd.service" ] || [ -f "/lib/systemd/system/sshd.service" ]; then
      systemctl restart sshd.service
    else
      systemctl restart ssh.service
    fi
  fi
elif [[ `/sbin/init --version` =~ upstart ]]; then
    if [ -f "/etc/init.d/sshd" ]; then
      service sshd restart
    else
      service ssh restart
    fi
else
  if [ -f "/etc/init.d/sshd" ]; then
    /etc/init.d/sshd restart
  else
    /etc/init.d/ssh restart
  fi
fi

#!/bin/bash
# Bootstrapping script to start and run Kitsune.

SELF=$0
GITSRC="https://github.com/mozilla/kitsune.git"
L10NSRC="https://svn.mozilla.org/projects/sumo/locales"

_prompt() {
    local _prompt=$1
    local _out=$2
    local _default=$3
    local _val=''
    if [ $_default ]; then
        _prompt="${_prompt} [${_default}]"
    fi
    read -p "$_prompt " _val
    if [ $_val ]; then
        eval $_out="'$_val'"
    else
        eval $_out="'$_default'"
    fi
}

_yn() {
    local _prompt=$1
    local _default=$2
    local _defret=-1
    local _in=''
    local _extra=''
    case "$_default" in
        y|Y)
            _extra='Yn'
            _defret=0
            ;;
        n|N)
            _extra='yN'
            _defret=1
            ;;
        *)
            _extra='yn'
    esac
    while [ 1 ]; do
        read -p "$_prompt [$_extra] " _in
        case "$_in" in
            y|Y|yes)
                return 0
                ;;
            n|N|no)
                return 1
                ;;
            '')
                if [ $_default ]; then
                    return $_defret
                fi
                ;;
            *)
                echo "Please enter Y or N."
        esac
    done
}

_prompt "Where do you want to install Kitsune?" TARGET ~/kitsune

echo "We need a couple bits of information to set up Kitsune..."

_prompt "What's your name?" NAME "$USER"
_prompt "What's your email address?" EMAIL

echo "Installing into ${TARGET}..."

STARTDIR=$PWD
LOGFILE="${STARTDIR}/kitsune-install.log"
VENV=$TARGET/.venv
echo -e "Logging activity into $LOGFILE\n"

# Start the log file.
echo -n "Starting Kitsune install into ${TARGET} on " > $LOGFILE
date >> $LOGFILE

# Write to stdout and logfile.
_print() {
    echo -e $1 | tee -a $LOGFILE
}

# No newline.
_printn() {
    echo -ne $1 | tee -a $LOGFILE
}

_fail() {
    _print "FAILED"
}

_ok() {
    _print "OK"
}

# Helpers to check for dependencies.
_is_installed() {
    which --skip-alias "$1" &>/dev/null
    return $?
}

_which() {
    which --skip-alias "$1" 2>/dev/null
}

_require_installed() {
    _printn "Checking for $1 (required)... "
    _is_installed "$1"
    local RET=$?
    if [ 0 -eq $RET ]; then
        _print $(_which "$1")
    else
        _print "MISSING"
        _print  "Missing requirement: \"$1\", please install and re-run $SELF"
        exit $RET
    fi
    return $RET
}

_check_installed() {
    _printn "Checking for $1... "
    _is_installed "$1"
    local RET=$?
    if [ 0 -eq $RET ]; then
        _print $(_which "$1")
    else
        _print "MISSING"
        _print "\"$1\" is missing. $2 may not be available."
    fi
    return $RET
}

_check_ret() {
    if [ 0 -ne $1 ]; then
        _print "An error occurred. Check ${LOGFILE}"
        exit 100
    fi
}

# Check for dependencies.
_print "\nChecking for dependencies...\n"

_require_installed python
_require_installed virtualenv
_require_installed pip
_require_installed git
_require_installed mysql

_check_installed searchd "Search"
HAS_SPHINX=$?
_check_installed elasticsearch "Search"
HAS_ES=$?
_check_installed memcached "Some cache features"
HAS_MC=$?
_check_installed redis-server "Redis-backed features"
HAS_REDIS=$?
_check_installed svn "Localizations"
HAS_SVN=$?
_check_installed msgfmt "Localizations"
HAS_GETTEXT=$?
_check_installed rabbitmq-server "Offline tasks"
HAS_RABBIT=$?

# Get the source code.
_printn "\nCloning the repository... "
git clone $GITSRC $TARGET &>> $LOGFILE
_check_ret $?
_ok
cd $TARGET

# Clone and update all the submodules.
_printn "\nCloning submodules (this may take a while)... "
git submodule update --init --recursive &>> $LOGFILE
_check_ret $?
_ok

# Create the virtual environment.
_printn "\nCreating virtual environment... "
virtualenv $VENV &>> $LOGFILE
_check_ret $?
_ok

# Activate the virtualenv.
_printn "Activating virtual environment... "
. $VENV/bin/activate &>> $LOGFILE
_check_ret $?
_ok

# Install compiled/dev dependencies.
_printn "Installing compiled dependencies into virtualenv (this may take a while)... "
pip install -r $TARGET/requirements/compiled.txt &>> $LOGFILE
_check_ret $?
_ok

_print "Now we'll gather some data about your environment."

# Try to create the databases.
_print "Creating the database. Make sure the MySQL server is running."
_prompt "What DB user can create the database?" DBADMIN "root"
_prompt "What should we name the Kitsune DB?" DBNAME "kitsune"
_prompt "What should we name the Kitsune DB user?" DBUSER "kitsune"
_prompt "Enter a password for the user ${DBUSER}:" DBPASS "kpass"

_print "Attempting to create database, you may need to enter the password twice..."
DBCMD1="CREATE DATABASE ${DBNAME}; GRANT ALL ON ${DBNAME}.* TO ${DBUSER}@localhost IDENTIFIED BY '${DBPASS}';"
DBCMD2="CREATE DATABASE test_${DBNAME}; GRANT ALL ON test_${DBNAME}.* TO ${DBUSER}@localhost;"
mysql -u$DBADMIN -p -e "$DBCMD1"
DBCREATED1=$?
mysql -u$DBADMIN -p -e "$DBCMD2"
DBCREATED2=$?

if [ 0 -ne $DBCREATED1 ] && [0 -ne $DBCREATED2 ]; then
    _print "There was an issue creating the database. You should be able to create it with these commands:"
    _print "${DBCMD1}"
    _print "${DBCMD2}"
fi

# Write settings_local.py.
# Generate a secret.
SECRET=`python $TARGET/scripts/gen-secret.py`
#TODO
#_check_ret $?

# Figure out cache settings.
if [ 0 -eq $HAS_MC ]; then
    _prompt "What is your memcached server port?" MC_PORT 11211
    MC_BACKEND='caching.backends.memcached.CacheClass'
    MC_LOCATION='localhost:${MC_PORT}'
    _prompt "Select a cache key prefix (to avoid collisions):" MC_PREFIX "kitsune:"
else
    MC_BACKEND='django.core.cache.backends.locmem.LocMemCache'
    MC_LOCATION=''
    MC_PREFIX=''
fi

_yn "Do you want to send email to yourself (and possibly others)?" "N"
if [ 0 -eq $? ]; then
    EMAIL_BACKEND='django.core.mail.backends.console.EmailBackend'
else
    EMAIL_BACKEND='django.core.mail.backends.smtp.EmailBackend'
fi

cat > settings_local.py <<ENDSETTINGS
from settings import *

DEBUG = True
TEMPLATE_DEBUG = DEBUG
STAGE = True

ADMINS = (
    ('${NAME}', '${EMAIL}'),
)

DATABASES['default']['NAME'] = '${DBNAME}'
DATABASES['default']['USER'] = '${DBUSER}'
DATABASES['default']['PASSWORD'] = '${DBPASS}'

CACHES = {
    'default': {
        'BACKEND': '${MC_BACKEND}',
        'LOCATION': ['${MC_LOCATION}'],
        'PREFIX': '${MC_PREFIX}',
    },
}

SECRET_KEY = '${SECRET}'
ROOT_URLCONF = '%s.urls' % ROOT_PACKAGE
EMAIL_BACKEND = '${EMAIL_BACKEND}'

ENDSETTINGS

# Decide whether to use Redis.
USE_REDIS=1
if [ 0 -eq $HAS_REDIS ]; then
    _yn "Do you want to set up Redis?" "Y"
    USE_REDIS=$?
fi

#TODO

# Get the localizations if all the infrastructure is there.
_is_installed svn
SVN=$?
_is_installed msgfmt
#TODO
GETTEXT=1
if [[ 0 -eq $SVN ]] && [[ 0 -eq $GETTEXT ]]; then
    _print "\nLocalizations available!"
    _printn "Checking out localizations... "
    svn checkout $L10NSRC $TARGET/locale &>> $LOGFILE
    _check_ret $?
    _ok

    _printn "Compiling localizations... "
    $TARGET/locale/compile-mo.sh $TARGET/locale &>> $LOGFILE
    _check_ret $?
    _ok
else
    _print "\nLocalizations not available."
fi

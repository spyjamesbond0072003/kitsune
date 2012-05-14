#!/bin/bash


SELF=$0
GITSRC="https://github.com/mozilla/kitsune.git"
L10NSRC="https://svn.mozilla.org/projects/sumo/locales"

TARGET=~/kitsune
read -p "Where do you want to install Kitsune? [${TARGET}] "
if [ $REPLY ]; then
    TARGET=$REPLY
fi
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
        _print ""
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
    if [ $1 -ne 0 ]; then
        _print "An error occurred. Check ${LOGFILE}"
        exit 100
    fi
}

# Check for dependencies.
_print "\nChecking for dependencies...\n"

_require_installed yum
_require_installed python
_require_installed virtualenv
_require_installed pip
_require_installed git
_require_installed mysql

_check_installed searchd "Search"
_check_installed elasticsearch "Search"
_check_installed memcached "Some cache features"
_check_installed redis-server "Redis-backed features"
_check_installed svn "Localizations"
_check_installed msgfmt "Localizations"

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

# Write settings_local.py.
SECRET=`python $TARGET/scripts/gen-secret.py`
_check_ret $?
# TODO: Create a settings_local.py

# TODO: Create the databases.

# Get the localizations if all the infrastructure is there.
_is_installed svn
SVN=$?
_is_installed msgfmt
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

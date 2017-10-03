#!/bin/sh

pip_url="https://bootstrap.pypa.io/get-pip.py"
agent_url="https://github.com/nginxinc/nginx-amplify-agent"
agent_conf_path="/etc/amplify-agent"
agent_conf_file="${agent_conf_path}/agent.conf"
nginx_conf_file="/etc/nginx/nginx.conf"

set -e

install_warn1 () {
    echo "The script will install git, python, python-dev, wget and possibly some other"
    echo "additional packages unless already found on this system."
    echo ""
    printf "Continue (y/n)? "
    read line
    test "${line}" = "y" -o "${line}" = "Y" || \
        exit 1
    echo ""
}

check_packages () {
    printf 'Checking if python 2.6 or 2.7 exists ... '
    for version in '2.7' '2.6'
    do
        # checks for python2.7, python2, python, etc
        major=`echo $version | sed 's/\(.\).*/\1/'`
        for py_command in "python${version}" "python${major}" 'python'
        do
            # checks if it's a valid command
            if ! command -V "${py_command}" >/dev/null 2>&1; then
                py_command=''
            # checks what python version it runs
            elif [ "$(${py_command} -c 'import sys; print(".".join(map(str, sys.version_info[:2])))' 2>&1)" != "${version}" ]; then
                py_command=''
            else
                break 2
            fi
        done
    done

    if [ -n "${py_command}" ]; then
        found_python='yes'
        echo 'yes'
    else
        found_python='no'
        echo 'no'
    fi

    for i in git wget curl gcc
    do
        printf "Checking if ${i} exists ... "
        if command -V ${i} >/dev/null 2>&1; then
            eval "found_${i}='yes'"
            echo 'yes'
        else
            eval "found_${i}='no'"
            echo 'no'
        fi
    done

    printf 'Checking if python-dev exists ... '
    if [ "${found_python}" = 'no' ]; then
        found_python_dev='no'
        echo 'no'
    elif [ ! -e "$(${py_command} -c 'from distutils import sysconfig as s; print(s.get_config_vars()["INCLUDEPY"])' 2>&1)" ]; then
        found_python_dev='no'
        echo 'no'
    else
        found_python_dev='yes'
        echo 'yes'
    fi

    echo
}

# Detect the user for the agent to use
detect_amplify_user() {
    if [ -f "${agent_conf_file}" ]; then
        amplify_user=`grep -v '#' ${agent_conf_file} | \
                      grep -A 5 -i '\[.*nginx.*\]' | \
                      grep -i 'user.*=' | \
                      awk -F= '{print $2}' | \
                      sed 's/ //g' | \
                      head -1`

        nginx_conf_file=`grep -A 5 -i '\[.*nginx.*\]' ${agent_conf_file} | \
                         grep -i 'configfile.*=' | \
                         awk -F= '{print $2}' | \
                         sed 's/ //g' | \
                         head -1`
    fi

    if [ -f "${nginx_conf_file}" ]; then
        nginx_user=`grep 'user[[:space:]]' ${nginx_conf_file} | \
                    grep -v '[#].*user.*;' | \
                    grep -v '_user' | \
                    sed -n -e 's/.*\(user[[:space:]][[:space:]]*[^;]*\);.*/\1/p' | \
                    awk '{ print $2 }' | head -1`
    fi

    if [ -z "${amplify_user}" ]; then
        test -n "${nginx_user}" && \
        amplify_user=${nginx_user} || \
        amplify_user="nginx"
    fi
}

printf "\n --- This script will install the NGINX Amplify Agent from source ---\n\n"

# Detect root
if [ "`id -u`" = "0" ]; then
    sudo_cmd=""
else
    if command -V sudo >/dev/null 2>&1; then
        sudo_cmd="sudo "
        echo "HEADS UP - will use sudo, you need to be in sudoers(5)"
        echo ""
    else
        echo "Started as non-root, sudo not found, exiting."
        exit 1
    fi
fi

if uname -m | grep "_64" >/dev/null 2>&1; then
    arch64="yes"
else
    arch64="no"
fi

os="alpine33"
check_packages

test "${found_python}" = "no" && ${sudo_cmd} apk add --no-cache python
test "${found_python_dev}" = "no" && ${sudo_cmd} apk add --no-cache python-dev
test "${found_python}" = "no" && ${sudo_cmd} apk add --no-cache py-configobj
test "${found_git}" = "no" && ${sudo_cmd} apk add --no-cache git
${sudo} apk add --no-cache util-linux procps
test "${found_wget}" = "no" -a "${found_curl}" = "no" &&  ${sudo_cmd} dnf -y install wget
test "${found_gcc}" = "no" && ${sudo_cmd} apk add --no-cache gcc musl-dev linux-headers

if command -V curl >/dev/null 2>&1; then
    downloader="curl -fs -O"
else
    if command -V wget >/dev/null 2>&1; then
        downloader="wget -q --no-check-certificate"
    else
        echo "no curl or wget found, exiting."
        exit 1
    fi
fi

# Set up Python stuff
${downloader} ${pip_url}
${py_command} get-pip.py --ignore-installed --user
~/.local/bin/pip install setuptools --upgrade --user

# Clone the Amplify Agent repo
${sudo_cmd} rm -rf nginx-amplify-agent
git clone ${agent_url}

# Install the Amplify Agent
cd nginx-amplify-agent

if [ "${os}" = "fedora" -a "${arch64}" = "yes" ]; then
    echo '[install]' > setup.cfg
    echo 'install-purelib=$base/lib64/python' >> setup.cfg
fi

if [ "${os}" = "freebsd" ]; then
    rel=`uname -r | sed 's/^\(.[^.]*\)\..*/\1/'`
    test "${rel}" = "11" && \
	opt='-std=c99'

    grep -v gevent packages/requirements > packages/req-nogevent
    grep gevent packages/requirements > packages/req-gevent

    ~/.local/bin/pip install --upgrade --target=amplify --no-compile -r packages/req-nogevent
    CFLAGS=${opt} ~/.local/bin/pip install --upgrade --target=amplify --no-compile -r packages/req-gevent
else
    ~/.local/bin/pip install --upgrade --target=amplify --no-compile -r packages/requirements
fi

if [ "${os}" = "fedora" -a "${arch64}" = "yes" ]; then
    rm setup.cfg
    export PYTHONPATH=/usr/lib64/python/
fi

${sudo_cmd} ${py_command} setup.py install
${sudo_cmd} cp nginx-amplify-agent.py /usr/bin
${sudo_cmd} chown root /usr/bin/nginx-amplify-agent.py

# Generate new config file for the agent
${sudo_cmd} rm -f ${agent_conf_file}
${sudo_cmd} sh -c "sed -e 's/api_key.*$/api_key = $api_key/' ${agent_conf_file}.default > ${agent_conf_file}"
${sudo_cmd} chmod 644 ${agent_conf_file}


${sudo_cmd} chown ${UID}:${GID} ${agent_conf_path} >/dev/null 2>&1
${sudo_cmd} chown ${UID}:${GID} ${agent_conf_file} >/dev/null 2>&1

# Create directories for the agent in /var/log and /var/run
${sudo_cmd} mkdir -p /var/log/amplify-agent
${sudo_cmd} chmod 755 /var/log/amplify-agent
${sudo_cmd} chown ${UID}:${GID} /var/log/amplify-agent

${sudo_cmd} mkdir -p /var/run/amplify-agent
${sudo_cmd} chmod 755 /var/run/amplify-agent
${sudo_cmd} chown ${UID}:${GID} /var/run/amplify-agent

echo ""
echo " --- Finished successfully! --- "
echo ""
echo " To start the Amplify Agent use:"
echo ""
echo " # sudo -u ${amplify_user} ${py_command} /usr/bin/nginx-amplify-agent.py start \ "
echo "                   --config=/etc/amplify-agent/agent.conf \ "
echo "                   --pid=/var/run/amplify-agent/amplify-agent.pid"
echo ""
echo " To stop the Amplify Agent use:"
echo ""
echo " # sudo -u ${amplify_user} ${py_command} /usr/bin/nginx-amplify-agent.py stop \ "
echo "                   --config=/etc/amplify-agent/agent.conf \ "
echo "                   --pid=/var/run/amplify-agent/amplify-agent.pid"
echo ""

exit 0

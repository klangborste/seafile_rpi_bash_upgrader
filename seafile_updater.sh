#!/usr/bin/env bash

############################################################################
#### description: semi automatic seafile rpi server version updater
#### ~build from reference: https://manual.seafile.com/deploy/upgrade.html
#### written by Max Roessler - mailmax@web.de on 07.07.2018
#### Version: 0.9.2
############################################################################

######## variable setup ########
set -o errexit
set -o nounset

grn=$'\e[1;32m'
red=$'\e[1;31m'
end=$'\e[0m'

### include configuration file with user assigned variables ###
. seafile_updater.conf || { echo "-- Configuration file 'seafile_updater.conf' not found. See file 'seafile_updater.conf.template'"; exit 1; }

################################

### Before starting the script it must be checked manually if other necessary dependencies like new packages are needed to be installed, like on some releases already before. Please look at release notes: https://github.com/haiwen/seafile-rpi/releases/latest

### logging must me build in ####
#log() {
#       /bin/echo "$(date --iso-8601=seconds) : ${1}" >> ${log_path}/${log_file}
#       # create missing  log directory
#       [[ ! -d "${log_path}" ]] && /bin/mkdir -p "${log_path}"
#}
###

if [ "${https}" = 'true' ]; then
	ssl_switch=https
else
	ssl_switch=http
fi

### get the latest release installed on the server ###
serv_ver=$(/usr/bin/curl -s "${ssl_switch}://${domain}/api2/server-info/")
serv_ver=${serv_ver#*\"version\": \"}  # throw away beginning of string including `"version": "`
serv_ver=${serv_ver%%\"*}              # throw away end of string starting with `"`
if [ -z "${serv_ver}" ]; then
        echo "${red}error on validate server version!${end}"
        exit 1
fi

### get the latest release available on GitHub ###
git_ver=$(/usr/bin/curl -s "https://api.github.com/repos/haiwen/seafile-rpi/releases/latest")
git_ver=${git_ver#*\"tag_name\": \"v}  # throw away beginning of string including `"tag_name": "v`
git_ver=${git_ver%%\"*}                # throw away end of string starting with `"`
if [ -z "${git_ver}" ]; then
        echo "${red}error on validate available git version!${end}"
        exit 1
fi

if [ "${serv_ver}" == "${git_ver}" ]; then
        echo "${grn}the newest seafile rpi server version is already installed!${end}"
        exit 1
else
        ### do all the parsing of the versions
        old_ifs="${IFS}"
        IFS='.'

        init_git_ver=($git_ver)
        init_serv_ver=($serv_ver)

        git_major=${init_git_ver[0]}
        git_minor=${init_git_ver[1]}
        git_maint=${init_git_ver[2]}

        serv_major=${init_serv_ver[0]}
        serv_minor=${init_serv_ver[1]}
        serv_maint=${init_serv_ver[2]}

        ### set again back to the original internal field separator
        IFS="${old_ifs}"

        ### check if parsing was successfullfy
        only_num='^[0-9]$'
        for var in $serv_major $serv_minor $serv_maint $git_major $git_minor $git_maint ; do
                if ! [[ $var =~ $only_num ]] ; then
                        echo "${red}variable not a single number - aborted!${end}"
                        exit 1
                fi
        done

        ### if seafile tar-file not already exists
        if [ ! -f "${tmp_dir}seafile-server_${git_ver}_stable_pi.tar.gz" ]; then
                 ### get the latest version as tar.gz file from GitHub
                /usr/bin/wget "https://github.com/haiwen/seafile-rpi/releases/download/v${git_ver}/seafile-server_${git_ver}_stable_pi.tar.gz" -P "${tmp_dir}" || { /bin/echo "${red}download latest server software package failed${end}"; exit 1; }
        else
                /bin/echo "${red}seafile latest tar.gz already exists in tmp-dir${end}"
                exit 1
        fi
        ### if seafile directory not already exists
        if [ ! -d "${sea_dir}seafile-server-${git_ver}/" ]; then
                ### untar the archive
                /bin/tar xzf "${tmp_dir}seafile-server_${git_ver}_stable_pi.tar.gz" -C "${tmp_dir}" || { /bin/echo "${red}untar server package failed${end}"; exit 1; }
                ### move file to seafile working directory
                /bin/mv "${tmp_dir}seafile-server-${git_ver}/" "${sea_dir}" || { /bin/echo "${red}move new untar-ed server software package to sea_dir failed${end}"; exit 1; }
        else
                /bin/echo "${red}seafile directory already exists${end}"
                exit 1
        fi
        ### setting right folder and file permissions on new folder structure
	/bin/chown -R "${sea_user}":"${sea_grp}" "${sea_dir}seafile-server-${git_ver}"/ || { /bin/echo "${red}chown the new server sea_dir failed${end}"; exit 1; }
        ### stop all services from seafile before update started
        /bin/systemctl stop seafile.service seahub.service || { /bin/echo "${red}stop the seafile and/or seahub service failed${end}"; exit 1; }
        ### compare versions if there is a major or minor version upgrade needed
        if [ "${git_major}" -gt "${serv_major}" ] || [ "${git_minor}" -gt "${serv_minor}" ] ; then
                ### execute all needed incremental update scripts
                for path in $(/bin/ls "${sea_dir}seafile-server-${git_ver}"/upgrade/upgrade_*.sh); do
                        script=$(basename "$path")
                        old_ifs="${IFS}"
                        IFS='._'
                        init_script=($script)
                        script_major=${init_script[1]}
                        script_minor=${init_script[2]}
                        IFS="${old_ifs}"
                        ### search for necessary update scripts
                        if [ "${script_major}" -gt "${serv_major}" ] || [ "${script_major}" -eq "${serv_major}" ] && [ "${script_minor}" -ge "${serv_minor}" ]; then
	                	/bin/su - "${sea_user}" -s /bin/bash -c "cd ${sea_dir}seafile-server-${git_ver}/ && upgrade/${script}" || { /bin/echo "${red}update script failed!${end}"; exit 1; }
                        fi
                done
        ### compare versions if there is a maint version upgrade needed
        elif [ "${git_maint}" -gt "${serv_maint}" ] ; then
                ### exexute the upgrade script itself
                /bin/su - "${sea_user}" -s /bin/bash -c "cd ${sea_dir}seafile-server-${git_ver} && upgrade/minor-upgrade.sh" || { /bin/echo "${red}update script failed!${end}"; exit 1; }
        fi
        ### seafile services start again
        /bin/systemctl start seafile.service seahub.service || { /bin/echo "${red}start the seafile and/or seahub service failed${end}"; exit 1; }
        ### verfiy if correct version of seafile server software is installed
        try=0
        until [ $try -ge 5 ]; do
                verify_ver=$(/usr/bin/curl -s --connect-timeout 30 "${ssl_switch}://${domain}/api2/server-info/")
                [ -n "${verify_ver}" ] && break
                try=$((try+1))
                sleep 10
        done
        verify_ver=${verify_ver#*\"version\": \"}  # throw away beginning of string including `"version": "`
        verify_ver=${verify_ver%%\"*}              # throw away end of string starting with first `"`
        ver_num='^[0-9].[0-9].[0-9]$'
        if ! [[ $verify_ver =~ $ver_num ]] ; then
                echo "${red}error on validate server version!${end}"
                exit 1
        fi
        if [ "${git_ver}" == "${verify_ver}" ]; then
                ### move old seafile version to installed dir as an archive for a possible rollback scenario
		/bin/mv "${sea_dir}seafile-server-${serv_ver}" "${sea_dir}installed/" || { /bin/echo "${red}move to archive dir failed${end}"; exit 1; }
                ### delete old temporary files and archives
                /bin/rm -rf "${tmp_dir}"* || { /bin/echo "${red}remove temporary files and directories failed${end}"; exit 1; }
        else
                echo "${red}a bigger problem is occured, no new version was installed!${end}"
        fi
fi

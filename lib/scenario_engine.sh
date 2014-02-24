#!/bin/bash

# Copyright (c) 2013 David Vossel <dvossel@redhat.com>
#                    All Rights Reserved.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of version 2 of the GNU General Public License as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it would be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
#
# Further, this software is distributed without any warranty that it is
# free of the rightful claim of any third person regarding infringement
# or the like.  Any license provided herein, whether implied or
# otherwise, applies only to this software file.  Patent licenses, if
# any, provided herein do not apply to combinations of this program with
# other software, or any other product whatsoever.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write the Free Software Foundation,
# Inc., 59 Temple Place - Suite 330, Boston MA 02111-1307, USA.
#

. ${PHDCONST_ROOT}/lib/phd_utils_api.sh
. ${PHDCONST_ROOT}/lib/pacemaker.sh
. ${PHDCONST_ROOT}/lib/shared_storage.sh
. ${PHDCONST_ROOT}/lib/package.sh

SENV_PREFIX="PHD_SENV"
SREQ_PREFIX="PHD_SREQ"
SCRIPT_PREFIX="PHD_SCPT"

SEC_REQ="REQUIREMENTS"
SEC_LOCAL="LOCAL_VARIABLES"
SEC_SCRIPTS="SCRIPTS"
SEC_TESTS="TESTS"

TEST_INDEX=0

scenario_clean()
{
	rm -rf ${PHD_TMP_DIR}
	mkdir -p "$PHD_TMP_DIR/lib"
	phd_clear_vars "$SENV_PREFIX"
}

scenario_clean_nodes()
{
	local nodes=$(definition_nodes)
	phd_cmd_exec "rm -rf $PHD_TMP_DIR" "$nodes"
	phd_cmd_exec "mkdir -p $PHD_TMP_DIR/lib" "$nodes"
}

scenario_script_add_env()
{
	local script=$1
	local api_files=$(ls ${PHDCONST_ROOT}/lib/*api*)
	local tmp
	local file

	echo "export PHDCONST_ROOT=\"${PHD_TMP_DIR}\"" >> $script
	for file in $(echo $api_files); do
		file=$(basename $file)
		echo ". ${PHD_TMP_DIR}/lib/${file}" >> $script
	done

	while read tmp; do
		local key=$(echo $tmp | awk -F= '{print $1}')
		local value=$(echo $tmp | awk -F= '{print $2}')
		echo "export $key=\"${value}\"" >> $script
	done < <(print_definition)
}

scenario_install_nodes()
{
	local nodes=$(definition_nodes)
	local install_local=$(eval echo "\$${SREQ_PREFIX}_install_local")

	if [ "$install_local" = "1" ]; then
		echo "$nodes $HOSTNAME" | sed 's/\s/\n/g' | sort | uniq -u | tr '\n' ' '
	else 
		echo "$nodes"
	fi
}

scenario_unpack()
{
	local section=""
	local cleaned=""
	local cur_script=""
	local script_num=1
	local writing_script=0

	scenario_clean

	local old_IFS=$IFS
	IFS=$'\n'

	for line in $(cat $1 | grep -v -e "[[:space:]]#" -e "^#")
	do
		cleaned=$(echo "$line" | tr -d ' ')
		if [ "${cleaned:0:1}" = "=" ]; then
			cleaned=$(echo "$cleaned" | tr -d '=')
		fi

		case $cleaned in
		$SEC_REQ|$SEC_LOCAL|$SEC_SCRIPTS|$SEC_TESTS)
			section=$cleaned
			continue ;;
		*) : ;;
		esac

		case $section in
		$SEC_REQ)
			export "${SREQ_PREFIX}_$line"
			continue ;;
		$SEC_LOCAL)
			export "${SENV_PREFIX}_$cleaned"
			continue ;;
		$SEC_TESTS)
			# this is the script index that separates
			# the deployment from the tests
			TEST_INDEX=$script_num
		;;
		$SEC_SCRIPTS) : ;;
		*) : ;;
		esac

		# determine if we are writing to a script
		if [ "$cleaned" = "...." ]; then
			if [ "$writing_script" -eq 0 ]; then
				writing_script=1
				cur_script=${PHD_TMP_DIR}/${SCRIPT_PREFIX}${script_num}
				export "${SCRIPT_PREFIX}_${script_num}=${cur_script}"
				echo "#!/bin/bash" > ${cur_script}


				
				IFS=$old_IFS
				scenario_script_add_env "$cur_script"
				IFS=$'\n'
				chmod 755 ${cur_script}
			else
				writing_script=0
				script_num=$(($script_num + 1))
			fi 
			continue
		fi

		# If writing, append to latest script file
		if [ "$writing_script" -eq 1 ]; then
			echo "$line" >> ${cur_script}
		else
			if [ -z "$cleaned" ]; then
				continue
			fi

			local key=$(echo $cleaned | awk -F= '{print $1}')
			local value=$(echo $cleaned | awk -F= '{print $2}')

			local cleaned_value=$(phd_get_value $value)
			if [ -z "$cleaned_value" ]; then
				phd_log LOG_ERR "no value found for \"$line\" for script number $script_num in scenario file"
				continue
			fi
			export "${SENV_PREFIX}_${key}${script_num}=${cleaned_value}"
		fi
	done

	IFS=$old_IFS
}

print_scenario()
{
	printenv | grep -e "$SENV_PREFIX" -e "$SREQ_PREFIX" -e "$SCRIPT_PREFIX"
	return 0
}

scenario_package_install()
{
	local nodes=$(scenario_install_nodes)
	local custom_package_dir=$(definition_package_dir)
	local packages=$(eval echo "\$${SREQ_PREFIX}_packages")

	# install custom packages from a directory
	package_install_custom "$custom_package_dir"  "$nodes"

	# install required scenario packages
	package_install "$packages" "$nodes"

}

scenario_storage_destroy()
{
	local cluster_init=$(eval echo "\$${SREQ_PREFIX}_cluster_init")
	local wipe=$(eval echo "\$${SREQ_PREFIX}_clean_shared_storage")
	local shared_dev=$(definition_shared_dev)

	if [ -z "$wipe" ]; then
		phd_log LOG_NOTICE "Success: Skipping."
		return
	fi

	if [ "$wipe" -ne 1 ]; then
		phd_log LOG_NOTICE "Success: Skipping."
		return
	fi

	if [ -z "$shared_dev" ]; then
		phd_exit_failure "Could not clear shared storage, cluster definition contains no shared storage."
	fi
	
	# since wiping storage involves the dlm and clvmd, we need to init
	# corosync to perform this operation
	if [ "$cluster_init" -eq "1" ]; then
		pacemaker_cluster_init
	fi

	shared_storage_destroy
	phd_log LOG_NOTICE "Success: Shared storage wiped"
}

scenario_cluster_destroy()
{
	local cluster_destroy=$(eval echo "\$${SREQ_PREFIX}_cluster_destroy")
	local cluster_init=$(eval echo "\$${SREQ_PREFIX}_cluster_init")
	local destroy=1

	if [ -n "$cluster_destroy" ]; then
		destroy=1
	fi
	if [ -n "$cluster_init" ]; then
		destroy=1
	fi

	if [ "$destroy" -eq "1" ]; then
		pacemaker_cluster_stop
		pacemaker_cluster_clean
		phd_log LOG_NOTICE "Success: Cluster destroyed"
	else 
		phd_log LOG_NOTICE "Success: Skipping cluster destroy"
	fi
}

scenario_cluster_init()
{
	local cluster_init=$(eval echo "\$${SREQ_PREFIX}_cluster_init")

	if [ -z "$cluster_init" ]; then
		return
	fi

	if [ "$cluster_init" -eq "1" ]; then
		pacemaker_cluster_init
		pacemaker_cluster_start
		pacemaker_fence_init
		phd_log LOG_NOTICE "Success: Cluster started"
	else 
		phd_log LOG_NOTICE "Success: Skipping cluster start"

	fi
}

scenario_distribute_api()
{
	local api_files=$(ls ${PHDCONST_ROOT}/lib/*)
	local nodes=$(definition_nodes)
	local file

	for file in $(echo $api_files); do
		file=$(basename $file)
		# copy it remotely
		phd_node_cp "${PHDCONST_ROOT}/lib/${file}" "${PHD_TMP_DIR}/lib/${file}" "$nodes" "755"
		if [ $? -ne 0 ]; then
			phd_exit_failure "Failed to distribute phd API to nodes. Exiting."
		fi

		# also copy it locally
		cp "${PHDCONST_ROOT}/lib/${file}" "${PHD_TMP_DIR}/lib/${file}"
	done
	phd_log LOG_NOTICE "Success: API distributed to nodes ($nodes)"
}

scenario_environment_defaults()
{
	local nodes=$(definition_nodes)

	# install configs and other environment constants that we
	# need to be consistent for all scenarios.
	phd_node_cp "${PHDCONST_ROOT}/environment/lvm.conf.phd_default" "/etc/lvm/lvm.conf" "$nodes" "644"
	if [ $? -ne 0 ]; then
		phd_exit_failure "Failed to distribute default configuration files."
	fi
	phd_log LOG_NOTICE "Success: Default configs distributed"
}

scenario_script_exec()
{
	local execute_tests=$1
	local script_num=1
	local script=""
	local nodes=""
	local node=""
	local rc=0
	local expected_rc=0

	if [ $execute_tests -eq 1 ]; then
		script_num=$TEST_INDEX
		if [ $script_num -eq 0 ]; then
			return 0
		fi
	fi

	while true; do
		script=$(eval echo "\$${SCRIPT_PREFIX}_${script_num}")
		if [ -z "$script" ]; then
			break
		fi

		expected_rc=$(eval echo "\$${SENV_PREFIX}_require_exitcode${script_num}")
		if [ -z "$expected_rc" ]; then
			expected_rc=0
		fi

		nodes=$(eval echo "\$${SENV_PREFIX}_target${script_num}")
		if [ -z "$nodes" ]; then
			nodes=$(definition_nodes)
		fi
		if [ "$nodes" = "all" ]; then
			nodes=$(definition_nodes)
		fi

		if [ "$nodes" = "local" ]; then
			phd_log LOG_NOTICE "executing $script locally"
			eval $script
			rc=$?
			if [ "$expected_rc" -ne "$rc" ]; then
				phd_exit_failure "Script $script_num exit code is $rc, expected $expected_rc Exiting."
			fi
		else
			phd_log LOG_NOTICE "executing $script on nodes \"$nodes\""
			for node in $(echo $nodes); do
				phd_script_exec $script "$node"
				rc=$?
				if [ "$expected_rc" -ne "$rc" ]; then
					phd_exit_failure "Script $script_num exit code is $rc, expected $expected_rc Exiting."
				fi
			done
		fi
		script_num=$(($script_num + 1))

		if [ $execute_tests -eq 0 ]; then
			if [ $script_num -eq $TEST_INDEX ]; then
				break
			fi
		fi
	done

	return 0
}

scenario_verify()
{
	local res=0
	while read line; do
		local key=$(echo $line | awk -F= '{print $1}' | sed "s/${SREQ_PREFIX}_//g")
		local value=$(echo $line | awk -F= '{print $2}')

		case $key in
		cluster_init|cluster_destroy|packages|install_local|clean_shared_storage)
			continue ;;
		*) : ;;
		esac

		definition_meets_requirement $key $value
		if [ $? -ne 0 ]; then
			res=1
		fi
	done < <(printenv | grep "$SREQ_PREFIX")

	if [ $res -ne 0 ]; then
		phd_exit_failure "Cluster defintion does not meet all of the scenarios requirements"
	fi
	phd_log LOG_NOTICE "Success: cluster definition passes scenario validation"
}

scenario_exec()
{
	phd_log LOG_NOTICE "=======================================================" 
	phd_log LOG_NOTICE "==== Verifying Scenario against Cluster Definition ====" 
	phd_log LOG_NOTICE "=======================================================" 
	scenario_verify

	phd_log LOG_NOTICE "========================================="
	phd_log LOG_NOTICE "==== Verifying Cluster Communication ===="
	phd_log LOG_NOTICE "========================================="
	phd_verify_connection "$(definition_nodes)"
	scenario_clean_nodes
	phd_log LOG_NOTICE "Success: all nodes are accessible"

	phd_log LOG_NOTICE "====================================" 
	phd_log LOG_NOTICE "====  Checking Cluster Shutdown ====" 
	phd_log LOG_NOTICE "====================================" 
	scenario_cluster_destroy

	phd_log LOG_NOTICE "==================================" 
	phd_log LOG_NOTICE "====  Checking Shared Storage ====" 
	phd_log LOG_NOTICE "==================================" 
	scenario_storage_destroy

	phd_log LOG_NOTICE "=========================" 
	phd_log LOG_NOTICE "==== Package Install ====" 
	phd_log LOG_NOTICE "=========================" 
	scenario_package_install

	phd_log LOG_NOTICE "============================" 
	phd_log LOG_NOTICE "==== Distribute PHD API ====" 
	phd_log LOG_NOTICE "============================" 
	scenario_distribute_api

	phd_log LOG_NOTICE "===================================="
	phd_log LOG_NOTICE "==== Distribute Default Configs ====" 
	phd_log LOG_NOTICE "====================================" 
	scenario_environment_defaults

	phd_log LOG_NOTICE "==================================" 
	phd_log LOG_NOTICE "==== Checking Cluster Startup ====" 
	phd_log LOG_NOTICE "==================================" 
	scenario_cluster_init

	phd_log LOG_NOTICE "======================================" 
	phd_log LOG_NOTICE "==== Executing Deployment Scripts ====" 
	phd_log LOG_NOTICE "======================================" 
	scenario_script_exec 0
	phd_log LOG_NOTICE "Success: Deployment Complete" 
}

scenario_exec_tests()
{
	phd_log LOG_NOTICE "=================================" 
	phd_log LOG_NOTICE "==== Executing Test Scripts  ====" 
	phd_log LOG_NOTICE "=================================" 

	if [ $TEST_INDEX -eq 0 ]; then
		phd_log LOG_NOTICE "No tests exist for this scenario"
	else
		scenario_script_exec 1
		phd_log LOG_NOTICE "Success: All tests Passed"
	fi
}

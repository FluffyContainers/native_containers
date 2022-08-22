#!/bin/bash

# Copyright 2022 FluffyContainers
# GitHub: https://github.com/FluffyContainers

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

#     http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# shellcheck disable=SC2155,SC1091,SC2015

LIB_VERSION="0.0.0"
PATH=${PATH}:/usr/bin
__DEBUG=0

__dir(){
  local __source="${BASH_SOURCE[0]}"
  while [[ -h "${__source}" ]]; do
    local __dir=$(cd -P "$( dirname "${__source}" )" 1>/dev/null 2>&1 && pwd)
    local __source="$(readlink "${__source}")"
    [[ ${__source} != /* ]] && local __source="${__dir}/${__source}"
  done
  echo -n "$(cd -P "$( dirname "${__source}" )" 1>/dev/null 2>&1 && pwd)"
}
DIR=$(__dir)
APP_NAME=${BASH_SOURCE[1]}; APP_NAME=${APP_NAME##*/}; APP_NAME=${APP_NAME%.*}

# Include configuration files
. "${DIR}/.shared.lib.sh"
[[ -f "${DIR}/.secrets" ]] && { . "${DIR}/.secrets"; __echo "Including secrets..."; }
. "${DIR}/.config"


APPLICATION=${APPLICATION:-}
VER=${VER:-}
VOLUMES=${VOLUMES:-}           
ENVIRONMENT=${ENVIRONMENT:-}   
CMD=${CMD:-}                   
IP=${IP:-}
ATTACH_NVIDIA=${ATTACH_NVIDIA:-0}
ATTACH_SYSTEMD=${ATTACH_SYSTEMD:-0}
CONTAINER_CAPS=${CONTAINER_CAPS:-}
CAPS_PRIVILEGED=${CAPS_PRIVILEGED:0}
BUILD_ARGS=${BUILD_ARGS:-}
DEVICES=${DEVICES:-}

NS_USER=${NS_USER:-containers}
declare -A LIMITS=${LIMITS:([CPU]="0.0" [MEMORY]=0)}
declare -A CUSTOM_COMMANDS=${CUSTOM_COMMANDS:()}; unset "CUSTOM_COMMANDS[0]"
declare -A CUSTOM_FLAGS=${CUSTOM_FLAGS:()}; unset "CUSTOM_FLAGS[0]"


IS_LXCFS_ENABLED=$([[ -d "/var/lib/lxcfs" ]] && echo "1" || echo "0")
# options required if LXCFS is installed
LXC_FS_OPTS=(
  "-v" "/var/lib/lxcfs/proc/cpuinfo:/proc/cpuinfo:rw"
  "-v" "/var/lib/lxcfs/proc/diskstats:/proc/diskstats:rw"
  "-v" "/var/lib/lxcfs/proc/meminfo:/proc/meminfo:rw"
  "-v" "/var/lib/lxcfs/proc/stat:/proc/stat:rw"
  "-v" "/var/lib/lxcfs/proc/swaps:/proc/swaps:rw"
  "-v" "/var/lib/lxcfs/proc/uptime:/proc/uptime:rw"
)

CONTAINER_BIN="podman"


verify_requested_resources(){
  local system_cpu_cores=$(nproc)
  local total_system_memory=$(grep MemTotal /proc/meminfo|awk '{print $2}')
  local total_system_memory=$((total_system_memory / 1024 / 1024))
  local is_error=0

  if [[ "${LIMITS[MEMORY]%.*}" -gt "${total_system_memory%.*}" ]]; then
    local is_error=1
    __echo error "Available system memory: ${total_system_memory%.*} GB, but requested ${LIMITS[MEMORY]%.*} GB"
  fi

  if [[ "${LIMITS[CPU]%.*}" -gt "${system_cpu_cores%.*}" ]]; then 
    local is_error=1
    __echo error "Available system cpu cores: ${system_cpu_cores}, but requested ${LIMITS[CPU]}"
  fi

  [[ ${is_error} -eq 1 ]] && exit 1
}

do_start() {
  local -n flags=$1
  local ver=${FLAGS[VER]}
  local clean=${FLAGS[CLEAN]}
  local attach=${FLAGS[ATTACH]}
  local interactive=${FLAGS[INTERACTIVE]}
  local volumes=""
  local devices=""
  local envi=""
  local lxcfs_mounts=""
  local limits_mem=""
  local limits_cpu=""
  local nvidia_args=""
  local bin_options=""
  local custom_container_command=""
  local caps=""

  [[ ${clean} -eq 1 ]] && [[ ${attach} -eq 1 ]] && { echo "[E] -c and -a options cannot be used together!"; return; }

  [[ ATTACH_NVIDIA -eq 1 ]] && { __command "[i] Initializing CUDA" 1 _nvidia_cuda_init; local nvidia_args=$(_add_nvidia_mounts); echo "[i] Attaching NVIDIA stuff to container..."; } || echo -n

  verify_requested_resources
  if [[ ${LIMITS[CPU]%.*} -ne 0 ]]; then 
    local total_cores=$(($(nproc) - 1))
    local min_core=$((total_cores - LIMITS[CPU] - 1))
    local limits_cpu="--cpuset-cpus=${min_core}-${total_cores}"; echo -e "CPU cores set:\n- ${min_core}-${total_cores}"
  fi

  if [[ ${LIMITS[CPU]%.*} -ne 0 ]]; then 
    echo -e "MEMORY limits:\n- ${LIMITS[MEMORY]}"
    local limits_mem="--memory=${LIMITS[MEMORY]}G"
  fi

  echo "LXS-FS extension is installed: "
  [[ "${IS_LXCFS_ENABLED}" -eq 1 ]] && { local lxcfs_mounts=${LXC_FS_OPTS[*]}; echo "- YES"; } || { echo "- NO"; }

  echo "SystemD enabled container:"
  if [[ ${ATTACH_SYSTEMD} -eq 1 ]]; then 
    echo "- yes"
    CONTAINER_CAPS+=("SYS_ADMIN")
    VOLUMES+=("/sys/fs/cgroup:/sys/fs/cgroup:rw")
    # ToDo: Add this only for ubuntu/debian
    #VOLUMES+=("$(mktemp -d):/run")
    ENVIRONMENT+=("container=docker")
    local bin_options="${bin_options}--cgroupns=host --entrypoint= "
    local custom_container_command="/usr/sbin/init"
  else  
    echo "- no"
  fi

  echo "Container volumes:"
  for v in "${VOLUMES[@]}"; do
    # shellcheck disable=SC2206
    local share=(${v//:/ })
    [[ "${share[0]}" == "" ]] && { echo " - no volumes"; continue; }
    [[ "${share[0]:0:1}" == "/" ]] && { local _src_dir=${share[0]}; } || { local _src_dir="${DIR}/storage/${share[0]}"; }

    [[ ! -d "${_src_dir}" ]] && mkdir -p "${_src_dir}" 1>/dev/null 2>&1

    local volumes="${volumes}-v ${_src_dir}:${share[1]} "; echo " - ${_src_dir} => ${share[1]}"
  done
  
  echo "Container devices:"
  for v in "${DEVICES[@]}"; do
    # shellcheck disable=SC2206
    [[ "${v}" == "" ]] && { echo " - no devices"; continue; }
    local devices="${devices}--device ${v} "; echo " - ${v}"
  done

  echo "Environment variables:"
  for v in "${ENVIRONMENT[@]}"; do
    # shellcheck disable=SC2206
    local _env=(${v//=/ })
    [[ "${_env[0]}" == "" ]] && { echo " - no variables"; continue; }
    local envi="${envi}-e ${_env[0]}=${_env[1]} "; echo " - ${_env[0]} = ${_env[1]}"
  done

  echo "Container CAPS:"
  if [[ ${CAPS_PRIVILEGED} -eq 0 ]]; then
    for v in "${CONTAINER_CAPS[@]}"; do
      [[ "${v}" == "" ]] && { echo " - no CAPS"; continue; }
      local caps="${caps}--cap-add ${v} "; echo " - ${v}"
    done
  else 
    local caps="--privileged";  echo " - privileged mode"
  fi

  # network 
  [[ "${IP}" == "host" ]] && { local _net_argument="--net=host"; } || { local _net_argument="--ip=${IP}"; }

  # NS Isolation
  echo -n "NS_USER mapping: "
  if [[ "${NS_USER}" == "keep-id" ]]; then
    local __ns_arguments="";  echo "none"
  elif [[ "${NS_USER:0:1}" == "@" ]]; then 
    local __ns_arguments="--user=${NS_USER:1}";  echo "run as user"
  else
    local __ns_arguments="--subuidname=${NS_USER} --subgidname=${NS_USER}"; echo "uid and gid mapping"
  fi

  echo -e "Container IP:\n - ${IP}"

  local action="start"

  if ${CONTAINER_BIN} container exists "${APPLICATION}" 1>/dev/null 2>&1; then
    __command "Stopping container" 1 ${CONTAINER_BIN} stop -i -t 5 "${APPLICATION}"
    [[ ${clean} -eq 1 ]] && { __command "[!] Removing already existing container..." 1 ${CONTAINER_BIN} rm -fiv "${APPLICATION}"; local action="run"; }
  else
    local action="run"
  fi

  if [[ "${action}" == "start" ]]; then  
    [[ ${attach} -eq 1 ]] && local _option="-a"  || local _option=""
    [[ ${attach} == 0 ]] && local _silent=1 || local _silent=0 # flip attach value and store to _silent
    __command "[!] Starting container..." ${_silent} ${CONTAINER_BIN} start "${_option}" "${APPLICATION}"
    return $?
  fi 

  [[ ${interactive} -eq 1 ]] && { local action="run"; local it_options="-it --entrypoint=bash"; echo "[i] Interactive run..."; } || { local action="run"; local it_options="-d"; }
  [[ ${attach} -eq 1 ]] && { local action="create"; local it_options=""; }

  # shellcheck disable=SC2086
  __command "[!] Creating and starting container..." 0 \
  ${CONTAINER_BIN} ${action} ${limits_cpu} ${limits_mem}\
  ${__ns_arguments}\
  --name ${APPLICATION}\
  --hostname ${APPLICATION}\
  ${caps}\
  ${devices}\
  ${it_options}\
  ${bin_options}\
  ${_net_argument}\
  ${lxcfs_mounts}\
  ${envi}\
  ${volumes}\
  ${nvidia_args}\
  localhost/${APPLICATION}:${ver} "${custom_container_command}"


  [[ ${attach} -eq 1 ]] && ${CONTAINER_BIN} start -a "${APPLICATION}"
}

do_stop() {
  local -n flags=$1
  local clean=${flags[CLEAN]}
  __command "[I] Stopping container ..." 1 ${CONTAINER_BIN} stop -t 10 "${APPLICATION}"
  [[ ${clean} -eq 1 ]] && __command "[!] Removing container..." 1 ${CONTAINER_BIN} rm "${APPLICATION}"
}

do_logs() {
  local -n flags=$1
  local _options=""

  [[ ${flags[FOLLOW]} -eq 1 ]] && local _options="-f"

  ${CONTAINER_BIN} logs ${_options} "${APPLICATION}"
}

do_ssh() {
  ${CONTAINER_BIN} exec -it "${APPLICATION}" bash 2>/dev/null

  if [[ $? -eq 127 ]]; then # e.g. command not found
    ${CONTAINER_BIN} exec -it "${APPLICATION}" sh 
  fi
}

do_top() {
  ${CONTAINER_BIN} stats "${APPLICATION}"
}

do_build() {
  local -n flags=$1
  local ver=${flags[VER]}
  local _clean_flag=${flags[CLEAN]}
  local _build_args=""

  if [[ ${_clean_flag} -eq 1 ]]; then
    local _build_args+="--rm --force-rm --no-cache --pull-always"
    if ${CONTAINER_BIN} image exists "localhost/${APPLICATION}:${ver}"; then
      __command "Removing already existing \"localhost/${APPLICATION}:${ver}\" ..." 1 ${CONTAINER_BIN} rmi -if "localhost/${APPLICATION}:${ver}"
    fi
  fi

  echo "Build args:"
  for v in "${BUILD_ARGS[@]}"; do
    # shellcheck disable=SC2206
    local _args=(${v//=/ })
    if [[ "${_args[0]}" == "" ]]; then
      echo " - no build args"
      continue
    fi
    local _build_args="${_build_args}--build-arg ${_args[0]}=${_args[1]} "
    echo " - ${_args[0]} = ${_args[1]}"
  done
  
  # shellcheck disable=SC2086
  ${CONTAINER_BIN} build --build-arg APP_VER="${VER}" ${_build_args} -t "localhost/${APPLICATION}:${ver}" container
}

do_init(){
  local dirs=("container" "storage")
  local docker_mkdir=""
  local docker_volumes=""
  local volumes=""
  for v in "${VOLUMES[@]}"; do
    [[ "${v}" == "" ]] && continue
    # shellcheck disable=SC2206
    local share=(${v//:/ })

    local docker_mkdir="${docker_mkdir}RUN mkdir -p ${share[1]}\n"
    local docker_volumes="${docker_volumes}VOLUME ${share[1]}\n"
    [[ "${share[0]:0:1}" != "/" ]] && local volumes+=("${share[0]}")
  done

  echo "Initializing folders structures..."
  for d in "${dirs[@]}"; do
      [[ ! -d "${DIR}/${d}" ]] && echo " - Creating ../${d}" || echo " - Skipping ../${d}"
  done

  if [[ -f "${DIR}/container/Dockerfile" ]]; then
    echo "Skipping ../container/Dockerfile creation..."
  else
    echo "Creating blank ../container/Dockerfile..."
    [[ ! -d "${DIR}/container" ]] && mkdir -p "${DIR}/container" || echo
  
    cat > "${DIR}/container/Dockerfile" <<EOF
FROM fedora:latest

ARG APP_VER
ENV APP_VER=\${APP_VER:-}

STOPSIGNAL SIGRTMIN+3

RUN dnf install -y curl &&\\
#    ....packages to install here.......
    dnf clean all
EOF

  echo -e "${docker_mkdir}" >> "${DIR}/container/Dockerfile"
  echo -e "${docker_volumes}" >> "${DIR}/container/Dockerfile" 

  if [[ ${ATTACH_NVIDIA} -eq 1 ]]; then
    # shellcheck disable=SC2028
    echo "RUN echo -e \"\\n\\n#Required for NVidia integration\\nldconfig\\n\" >> /root/.bashrc" >> "${DIR}/container/Dockerfile"
  fi

  echo "CMD [${CMD}]" >> "${DIR}/container/Dockerfile"
  fi
  
  echo "Create volumes..."
  local _change_owner=0
  if [[ "${NS_USER}" != "keep-id" ]] && [[ "${NS_USER:0:1}" != "@" ]]; then
    local _change_owner=1 
    local _uid=$(grep "${NS_USER}" /etc/subuid|cut -d ':' -f 2)
    local _gid=$(grep "${NS_USER}" /etc/subgid|cut -d ':' -f 2)
  fi

  # shellcheck disable=SC2048
  for v in ${volumes[*]}; do
    [[ "${v}" == "" ]] && continue
    local _dir="storage/${v}"

    echo -n " - mkdir ${_dir} ..."
    if [[ -d "${DIR}/${_dir}" ]]; then
      echo "exist"
    else 
    mkdir -p "${DIR}/${_dir}" 1>/dev/null 2>&1 && echo "created" || echo "failed"
    fi

    if [[ ${_change_owner} -eq 1 ]]; then
      echo " - permissions ${_dir} => ${_uid}:${_gid}, mode 700..."
      chown "${_uid}":"${_gid}" "${DIR}/${_dir}"
      chmod 700 "${DIR}/${_dir}"
    fi
  done

  echo -n "Creating systemd service file..."
  local service_name=$(basename "$0")
  # shellcheck disable=SC2206
  local service_name=(${service_name//./ })
  # shellcheck disable=SC2178
  local service_name=${service_name[0]}
  
  # shellcheck disable=SC2128
  
  if [[ ! -f "${DIR}/${service_name}.service" ]]; then
    cat > "${DIR}/${service_name}.service" <<EOF
[Unit]
Description=Podman ${service_name}.service
Wants=network.target
After=network-online.target

[Service]
Type=simple
Environment=PODMAN_SYSTEMD_UNIT=%n
Restart=on-failure
TimeoutStopSec=70
ExecStart=${DIR}/${service_name}.sh start -a
ExecStop=${DIR}/${service_name}.sh stop


[Install]
WantedBy=multi-user.target default.target
EOF
    echo "ok"
  else
    echo "skipped"
  fi
}

show_help(){
  local -n commands=$1
  local -n flags=$2

  echo -e "\n${APPLICATION} v${VER} [wrapper v${LIB_VERSION}] help"
  echo -e "===============================================\n"

  echo "Available commands:"
  for c in ${!commands[*]}; do
    [[ "${c##*,}" == "F" ]] && continue
    echo "  - ${c%,*}"
  done

  echo -e "\nAvailable arguments:"
  for c in ${!flags[*]}; do
    [[ "${c:0:1}" == "-" ]] && continue
    echo "  - ${c}"
  done

}

#=============================================
declare -A COMMANDS=(
  [INIT,S]=0   [INIT,F]="do_init"    
  [BUILD,S]=0  [BUILD,F]="do_build"          
  [START,S]=0  [START,F]="do_start"          
  [STOP,S]=0   [STOP,F]="do_stop"
  [TOP,S]=0    [TOP,F]="do_top"
  [LOGS,S]=0   [LOGS,F]="do_logs"
  [SSH,S]=0    [SSH,F]="do_ssh"
  [UPDATE,S]=0 [UPDATE,F]="__do_lib_upgrade"
)

declare -A FLAGS=(
  [CLEAN]=0       [-C]=CLEAN         [--CLEAN]=CLEAN
  [ATTACH]=0      [-A]=ATTACH        [--ATTACH]=ATTACH
  [INTERACTIVE]=0 [-IT]=INTERACTIVE  [--INTERACTIVE]=INTERACTIVE
  [FOLLOW]=0      [-F]=FOLLOW        [--FOLLOW]=FOLLOW
  [VER]=${VER} 
)

# Disallow internal commands override
for key in ${!CUSTOM_COMMANDS[*]}; do
  [[ ! ${COMMANDS[${key},F]+_} ]] && { COMMANDS[${key},S]=0; COMMANDS[${key},F]=${CUSTOM_COMMANDS[${key}]}; }
done

for key in ${!CUSTOM_FLAGS[*]}; do
  [[ ! ${FLAGS[${key^^}]+_} ]] && FLAGS[${key^^}]=${CUSTOM_FLAGS[${key^^}]}
done

for i in "${@}"; do
  if [[ ${COMMANDS[${i^^},S]+_} ]]; then
    COMMANDS[${i^^},S]=1
  elif [[ ${FLAGS[${i^^}]+_} ]]; then 
    FLAGS[${FLAGS[${i^^}]}]=1
  else case ${i,,} in
  -v=*|--ver=*)
    FLAGS[VER]="${i#*=}";;
  help|-h|--help)
    show_help COMMANDS FLAGS
    exit 0;;
  esac fi
  shift
done

for i in ${!COMMANDS[*]}; do 
  [[ "${i##*,}" == "F" ]] && continue
  [[ ${COMMANDS[${i%,*},S]} -eq 1 ]] && { ${COMMANDS[${i%,*},F]} FLAGS; exit $?; }
done

show_help COMMANDS FLAGS
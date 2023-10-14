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
__ALLOW_CMD_HOOKS=0

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
[[ -f "${DIR}/.secrets" ]] && { . "${DIR}/.secrets"; }
. "${DIR}/.config"


APPLICATION=${APPLICATION:-}
VER=${VER:-}
VOLUMES=${VOLUMES:-}           
ENVIRONMENT=${ENVIRONMENT:-}   
CMD=${CMD:-}                   
IP=${IP:-}
APP_HOSTNAME=${APP_HOSTNAME:-${APPLICATION}}
APP_INTERACTIVE_SHELL=${APP_INTERACTIVE_SHELL:-bash}
ATTACH_NVIDIA=${ATTACH_NVIDIA:-0}
ATTACH_SYSTEMD=${ATTACH_SYSTEMD:-0}
CONTAINER_CAPS=${CONTAINER_CAPS:-}
CAPS_PRIVILEGED=${CAPS_PRIVILEGED:0}
BUILD_ARGS=${BUILD_ARGS:-}
BUILD_VOLUMES=${BUILD_VOLUMES:-}
DEVICES=${DEVICES:-}
SHM_SIZE=${SHM_SIZE:-}
__ALLOW_CMD_HOOKS=${__ALLOW_COMMAND_HOOKS:-0}

NS_USER=${NS_USER:-containers}
declare -A LIMITS=${LIMITS:([CPU]="0.0" [MEMORY]=0)}
declare -A CUSTOM_COMMANDS=${CUSTOM_COMMANDS:()}; unset "CUSTOM_COMMANDS[0]"
declare -A CUSTOM_FLAGS=${CUSTOM_FLAGS:()}; unset "CUSTOM_FLAGS[0]"


IS_LXCFS_ENABLED=$([[ -d "/var/lib/lxcfs" ]] && echo "1" || echo "0")
if ! systemctl status lxcfs 1>/dev/null 2>&1; then 
  __echo "ERROR" "LXC FS is installed but service \"lxcfs\" is not running!"
  IS_LXCFS_ENABLED=0
fi
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
${CONTAINER_BIN} 1>/dev/null 2>&1
[[ $? -eq 127 ]] && { CONTAINER_BIN="docker"; __echo "WARN" "No podman installation found, using docker "; }


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

# shellcheck disable=SC2206
do_start() {
  local -n flags=$1
  local ver=${FLAGS[VER]} clean=${FLAGS[CLEAN]} attach=${FLAGS[ATTACH]} interactive=${FLAGS[INTERACTIVE]}

  local __args=()
  local bin_options="" custom_container_command="" it_options=""

  [[ ${clean} -eq 1 ]] && [[ ${attach} -eq 1 ]] && { __echo "ERROR" "-c and -a options cannot be used together!"; return; }

  [[ ${ATTACH_NVIDIA} -eq 1 ]] && { __run -t "Initializing CUDA" _nvidia_cuda_init; __args+=($(_add_nvidia_mounts)); } || echo -n

  verify_requested_resources
  if [[ ${LIMITS[CPU]%.*} -ne 0 ]]; then 
    local total_cores=$(($(nproc) - 1))
    local min_core=$((total_cores - (LIMITS[CPU] - 1)))
    __args+=("--cpuset-cpus=${min_core}-${total_cores}"); echo -e "CPU cores set:\n- ${min_core}-${total_cores} (${LIMITS[CPU]} cores)"
  fi

  if [[ ${LIMITS[CPU]%.*} -ne 0 ]]; then 
    echo -e "MEMORY limits:\n- ${LIMITS[MEMORY]}"
    __args+=("--memory=${LIMITS[MEMORY]}G")
  fi

  echo "LXC-FS extension is installed: "
  [[ "${IS_LXCFS_ENABLED}" -eq 1 ]] && { __args+=(${LXC_FS_OPTS[*]}); echo "- YES"; } || { echo "- NO"; }

  echo "SystemD enabled container:"
  if [[ ${ATTACH_SYSTEMD} -eq 1 ]]; then 
    echo "- yes"
    CONTAINER_CAPS+=("SYS_ADMIN")
    VOLUMES+=("/sys/fs/cgroup:/sys/fs/cgroup:rw")
    # ToDo: Add this only for ubuntu/debian
    #VOLUMES+=("$(mktemp -d):/run")
    ENVIRONMENT+=("container=docker")
    local bin_options="${bin_options}--cgroupns=host "
    local it_options="${it_options}--entrypoint= "
    local custom_container_command="/usr/sbin/init"
  else  
    echo "- no"
  fi

  echo "Container hostname: ${APP_HOSTNAME}"

  echo "Container volumes:"
  for v in "${VOLUMES[@]}"; do
    # shellcheck disable=SC2206
    local share=(${v//:/ })
    local _opts=""
    local _opts_text=""
    [[ "${share[0]}" == "" ]] && { echo " - no volumes"; continue; }
    [[ "${share[0]:0:1}" == "/" ]] && { local _src_dir=${share[0]}; } || { local _src_dir="${DIR}/storage/${share[0]}"; }

    [[ ! -d "${_src_dir}" ]] && mkdir -p "${_src_dir}" 1>/dev/null 2>&1
    [[ -n ${share[2]} ]] && [[ "${share[2]}" == "ro" ]] && { local _opts=":ro"; local _opts_text="[read-only]"; }

    __args+=("-v ${_src_dir}:${share[1]}${_opts}"); echo " - ${_src_dir} => ${share[1]} ${_opts_text}"
  done
  
  echo "Container devices:"
  for v in "${DEVICES[@]}"; do
    # shellcheck disable=SC2206
    [[ "${v}" == "" ]] && { echo " - no devices"; continue; }
    __args+=("--device ${v}"); echo " - ${v}"
  done

  echo "Environment variables:"
  for v in "${ENVIRONMENT[@]}"; do
    # shellcheck disable=SC2206
    local _env=("${v%%=*}" "${v#*=}")
    [[ "${_env[0]}" == "" ]] && { echo " - no variables"; continue; }
    __args+=("-e ${_env[0]}='${_env[1]}'"); echo " - ${_env[0]} = '${_env[1]}'"
  done

  echo "Container CAPS:"
  if [[ ${CAPS_PRIVILEGED} -eq 0 ]]; then
    for v in "${CONTAINER_CAPS[@]}"; do
      [[ "${v}" == "" ]] && { echo " - no CAPS"; continue; }
      __args+=("--cap-add ${v}"); echo " - ${v}"
    done
  else 
    __args+=("--privileged");  echo " - privileged mode"
  fi

  # network 
  [[ "${IP}" == "host" ]] && __args+=("--net=host") || __args+=("--ip=${IP}")

  # NS Isolation
  echo -n "NS_USER mapping: "
  if [[ "${NS_USER}" == "keep-id" ]]; then
    echo "none"
  elif [[ "${NS_USER:0:1}" == "@" ]]; then 
    __args+=("--user=${NS_USER:1}");  echo "run as user"
  else
    __args+=("--subuidname=${NS_USER}" "--subgidname=${NS_USER}"); echo "uid and gid mapping"
  fi

  echo -e "Container IP:\n - ${IP}"

  local action="start"

  if ${CONTAINER_BIN} container exists "${APPLICATION}" 1>/dev/null 2>&1; then
    __run -s -t "Stopping container" ${CONTAINER_BIN} stop -i -t 5 "${APPLICATION}"
    [[ ${clean} -eq 1 ]] && { __run -s -t "Removing already existing container" ${CONTAINER_BIN} rm -fiv "${APPLICATION}"; local action="run"; }
  else
    local action="run"
  fi

  if [[ "${action}" == "start" ]]; then  
    [[ ${attach} -eq 1 ]] && local _option="-a"  || local _option=""
    [[ ${attach} == 0 ]] && local _silent="-s" || local _silent="" # flip attach value and store to _silent
    __run -a -s -o -t "Starting container" ${CONTAINER_BIN} start "${_option}" "${APPLICATION}"
    return $?
  fi 

  [[ ${interactive} -eq 1 ]] && { local action="run"; local _run_option="-a"; local it_options="-it --entrypoint=bash"; unset custom_container_command; echo "Interactive run..."; } || { local action="run"; local it_options="-d"; }
  [[ ${attach} -eq 1 ]] && { local action="create"; local it_options=""; local _run_option=""; }

  # shellcheck disable=SC2206
  local _args=(
  "${CONTAINER_BIN}" "${action}"\
    --name "${APPLICATION}"\
    --hostname "${APP_HOSTNAME}"\
    ${it_options}\
    ${bin_options}
  )

  _args+=(${__args[*]})

  if [[ -n "${custom_container_command}" ]]; then
    # shellcheck disable=SC2206
    _args+=(${custom_container_command})
  fi

  _args+=("localhost/${APPLICATION}:${ver}")

  # shellcheck disable=SC2086,SC2068
  __run ${_run_option} -s -o -t "Creating and starting container" ${_args[@]}
}

do_stop() {
  local -n flags=$1
  local clean=${flags[CLEAN]}

  if ! ${CONTAINER_BIN} container exists "${APPLICATION}"; then
    __echo "ERROR" "Application \"${APPLICATION}\" not exists"
    return 1
  fi

  __run -s -t "Stopping container" ${CONTAINER_BIN} stop -t 10 "${APPLICATION}"
  [[ ${clean} -eq 1 ]] && __run -s -t "Removing container" ${CONTAINER_BIN} rm "${APPLICATION}"
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

  BUILD_ARGS+=("APP_VER=${ver}")

  local __args=(
    "${CONTAINER_BIN}" "build"
  )

  [[ -f container/Dockerfile ]] &&  __args+=("--format" "docker")

  if [[ ${_clean_flag} -eq 1 ]]; then
    __args+=("--rm" "--force-rm" "--no-cache" "--pull-always")
    if ${CONTAINER_BIN} image exists "localhost/${APPLICATION}:${ver}"; then
      __run -s -t "Removing already existing \"localhost/${APPLICATION}:${ver}\" ..." ${CONTAINER_BIN} rmi -if "localhost/${APPLICATION}:${ver}"
    fi
  fi

  echo "Build args:"
  for v in "${BUILD_ARGS[@]}"; do
    # shellcheck disable=SC2206
    local _args=(${v//=/ })
    [[ "${_args[0]}" == "" ]] && { continue; }
    __args+=("--build-arg" "${_args[0]}=${_args[1]}")
    echo " - ${_args[0]} = ${_args[1]}"
  done

  echo "Build volumes:"
  for v in "${BUILD_VOLUMES[@]}"; do
    # shellcheck disable=SC2206
    local share=(${v//:/ })
    local _opts=""
    local _opts_text=""
    [[ "${share[0]}" == "" ]] && { echo " - no volumes"; continue; }
    [[ "${share[0]:0:1}" == "/" ]] && { local _src_dir=${share[0]}; } || { local _src_dir="${DIR}/storage/${share[0]}"; }

    [[ ! -d "${_src_dir}" ]] && mkdir -p "${_src_dir}" 1>/dev/null 2>&1
    [[ -n ${share[2]} ]] && [[ "${share[2]}" == "ro" ]] && { local _opts=":ro"; local _opts_text="[read-only]"; }

    __args+=("-v" "${_src_dir}:${share[1]}${_opts}"); echo " - ${_src_dir} => ${share[1]} ${_opts_text}"
  done
  
  __args+=("-t" "localhost/${APPLICATION}:${ver}" "container")
  # shellcheck disable=SC2086
  local _start_time=$(date +%s.%N)
  echo
  echo -e "${_COLOR[INFO]}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${_COLOR[GRAY]}"
  __run -t "Building image" -s -o --stream "${__args[@]}"
  local _stop_time=$(date +%s.%N)

  dt=$(echo "${_stop_time} - ${_start_time}" | bc)
  dd=$(echo "$dt/86400" | bc)
  dt2=$(echo "$dt-86400*$dd" | bc)
  dh=$(echo "$dt2/3600" | bc)
  dt3=$(echo "$dt2-3600*$dh" | bc)
  dm=$(echo "$dt3/60" | bc)
  ds=$(echo "$dt3-60*$dm" | bc)
  echo -e "${_COLOR[INFO]}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo -ne "${_COLOR[DARKPINK]}[>>>>]${_COLOR[INFO]} Done, build time: ${_COLOR[RED]}"
  LC_NUMERIC=C printf "%d:%02d:%02d:%02.4f\n" "${dd}" "${dh}" "${dm}" "${ds}"
  echo -ne "${_COLOR[RESET]}"
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
  [[ ! ${COMMANDS[${key},F]+_} ]] && [[ "${key}" != *"_HOOK" ]] && { COMMANDS[${key},S]=0; COMMANDS[${key},F]=${CUSTOM_COMMANDS[${key}]}; }
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
  [[ ${COMMANDS[${i%,*},S]} -eq 1 ]] && {
    [[ ${__ALLOW_CMD_HOOKS} -eq 1 ]] && [[ ${CUSTOM_COMMANDS[${i%,*},PRE_HOOK]+_} ]] && ${CUSTOM_COMMANDS[${i%,*},PRE_HOOK]} FLAGS
    ${COMMANDS[${i%,*},F]} FLAGS; r=$?
    [[ ${r} -eq 0 ]] && [[ ${__ALLOW_CMD_HOOKS} -eq 1 ]] && [[ ${CUSTOM_COMMANDS[${i%,*},POST_HOOK]+_} ]] && ${CUSTOM_COMMANDS[${i%,*},POST_HOOK]} FLAGS
    exit ${r}
  }
done

show_help COMMANDS FLAGS
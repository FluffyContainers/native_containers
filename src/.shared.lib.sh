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


# [template] !!! DO NOT MODIFY CODE INSIDE. INSTEAD USE apply-teplate.sh script to update template !!!
# [module: core.sh]


# shellcheck disable=SC2155,SC2015

# =====================
#  Terminal functions
# =====================

declare -A _COLOR=(
    [INFO]="\033[38;05;39m"
    [ERROR]="\033[38;05;161m"
    [WARN]="\033[38;05;178m"
    [OK]="\033[38;05;40m"
    [GRAY]="\033[38;05;245m"
    [DARKPINK]="\033[38;05;127m"
    [RESET]="\033[m"
)

# deprecated, should be overseeded by __run with porting functionality and letting it be simple as __run
__command(){
  local title="$1"
  local status="$2"  # 0 or 1
  shift;shift

  [[ "${__DEBUG}" -eq 1 ]] && echo "${_COLOR[INFO]}[CMD-DBG] ${_COLOR[GRAY]} $* ${_COLOR[RESET]}"

  if [[ ${status} -eq 1 ]]; then
    echo -n "${title}..."
    "$@" 1>/dev/null 2>&1
    local n=$?
    [[ $n -eq 0 ]] && echo -e "${_COLOR[OK]}ok${_COLOR[RESET]}" || echo -e "${_COLOR[ERROR]}fail[#${n}]${_COLOR[RESET]}"
    return ${n}
  else
    echo "${title}..."
    "$@"
    return $?
  fi
}

# __run [-t "command caption" [-s] [-f "echo_func_name"]] command
# -t "command caption" - instead of command itself, show the specified text
# -s - if provided, command itself would be hidden from the output
# -f - if provided, output of function would be displayed in title
# Samples:
# _test(){
#  echo "lol" 
#}
# __run -s -t "Updating" -f "_test" update_dirs
__run(){
  local _default=1 _f="" _silent=0 _show_output=0 _custom_title="" _func="" _attach=0

  # scan for arguments
  while true; do
    [[ "${1^^}" == "-S" ]] && { _silent=1; shift; }
    [[ "${1^^}" == "-T" ]] && { _custom_title="${2}"; shift; shift; _default=0; }
    [[ "${1^^}" == "-F" ]] && { _func="${2}"; shift; shift; }
    [[ "${1^^}" == "-O" ]] && { _show_output=1; shift; }
    [[ "${1^^}" == "-A" ]] && { _attach=1; shift; }

    [[ "${1:0:1}" != "-" ]] && break
  done

  # [[ "${DEBUG}" == "1" ]] &&  echo -e "${_COLOR[GRAY]}[DEBUG] $*${_COLOR[RESET]}"

  [[ "${_custom_title}" != "" ]] && {
    echo -ne "${_custom_title} "
    [[ ${_silent} -eq 0 ]] && echo -ne "${_COLOR[GRAY]} | $*"
  }

  [[ ${_attach} -eq 1 ]] && {
    echo
    echo -e "${_COLOR[GRAY]}--------Attaching${_COLOR[RESET]}"
    "$@" 
    local n=$?
    echo -e "${_COLOR[GRAY]}----------Summary"
    echo -e "${_COLOR[DARKPINK]}[>>>>]${_COLOR[GRAY]} Exit code: ${n} ${_COLOR[RESET]}"
    return ${n}
  }
  
  local _out; _out=$("$@" 2>&1)
  local n=$?


  [[ -n ${_func} ]] && echo -ne " | $(${_f})"
  [[ ${_default} -eq 0 ]] &&  echo -ne "${_COLOR[GRAY]} ... [" || echo -ne "${_COLOR[INFO]}[EXEC] ${_COLOR[GRAY]}$* -> ["
  
  [[ $n -eq 0 ]] && echo -e "${_COLOR[OK]}ok${_COLOR[GRAY]}]${_COLOR[RESET]}" || echo -e "${_COLOR[ERROR]}fail[#${n}]${_COLOR[GRAY]}]${_COLOR[RESET]}"
  [[ $n -ne 0 ]] && [[ ${_silent} -eq 0 ]] || [[ ${_show_output} -eq 1 ]] && {
    local _accent_color="DARKPINK"
    [[ ${n} -ne 0 ]] && _accent_color="ERROR"
    IFS=$'\n' mapfile -t out_lines <<< "${_out}"
    echo -e "${_COLOR[${_accent_color}]}[>>>>]${_COLOR[GRAY]} ${out_lines[0]}"
    
    for line in "${out_lines[@]:1}"; do
        echo -e "${_COLOR[${_accent_color}]}     | ${_COLOR[GRAY]}${line}"
    done
    echo -e "${_COLOR[RESET]}"
  }
  return ${n}
  }

  __echo() {
  local _lvl="INFO"
  local _new_line=""

  [[ "${1^^}" == "-N" ]] && { local _new_line="n"; shift; }
  [[ "${1^^}" == "INFO" ]] || [[ "${1^^}" == "ERROR" ]] || [[ "${1^^}" == "WARN" ]] && { local _lvl=${1^^}; shift; }
  
  echo -${_new_line}e "${_COLOR[${_lvl}]}[${_lvl}]${_COLOR[RESET]} $*"
}

__ask() {
    local _title="${1}"
    read -rep "${1} (y/N): " answer < /dev/tty
    if [[ "${answer}" != "y" ]]; then
      __echo "error" "Action cancelled by the user"
      return 1
    fi
    return 0
}

cuu1(){
  echo -e "\E[A"
}

# https://stackoverflow.com/questions/4023830/how-to-compare-two-strings-in-dot-separated-version-format-in-bash
# Results: 
#          0 => =
#          1 => >
#          2 => <
# shellcheck disable=SC2206
__vercomp () {
    [[ "$1" == "$2" ]] && return 0 ; local IFS=. ; local i ver1=($1) ver2=($2)
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++));  do ver1[i]=0;  done
    for ((i=0; i<${#ver1[@]}; i++)); do
        [[ -z ${ver2[i]} ]] && ver2[i]=0
        ((10#${ver1[i]} > 10#${ver2[i]})) &&  return 1
        ((10#${ver1[i]} < 10#${ver2[i]})) &&  return 2
    done
    return 0
}

__urldecode() { : "${*//+/ }"; echo -e "${_//%/\\x}"; }

__download() {
  [[ "${1^^}" == "-L" ]] && { local _follow_link="-L"; shift; } || local _follow_link=""
  local _url="$1"
  local _file=$(__urldecode "${_url##*/}")
  [[ -z $2 ]] && local _destination="./" || local _destination="$2"
  [[ "${_destination:0-1}" == "/" ]] && local _dest_path="${_destination}/${_file}" || local _dest_path="${_destination}"

  __echo "Downloading file ${_file}: "
  # shellcheck disable=SC2086
  curl -f ${_follow_link} --progress-bar "${_url}" -o "${_dest_path}" 2>&1
  local _ret=$?

  [[ ${_ret} -eq 0 ]] && {
    echo -ne "\E[A"; echo -ne "\033[0K\r"; echo -ne "\E[A"
    __echo "Downloading file ${_file}: [${_COLOR[OK]}ok${_COLOR[RESET]}]"
  } || {
    echo -ne "\E[A"; echo -ne "\033[0K\r"; echo -ne "\E[A";echo -ne "\033[0K\r"; echo -ne "\E[A";
    __echo "Downloading file ${_file}: [${_COLOR[ERROR]}fail ${_ret}${_COLOR[RESET]}]"
  }
  return ${_ret} 
}


# [template] [end] !!! DO NOT REMOVE ANYTHING INSIDE, INCLUDING CURRENT LINE !!!

# =====================
# 
#  Upgrade functions
#
# =====================


handle_file(){
  IFS=" "
  local _name=${1}
  local _diff_line=${2}
  local _command=${_diff_line:0:1}
  local _file=${_diff_line:2}; local _file=${_file//..};local _file=${_file//\/}  # to avoid paths like ../../.something
  local _lib_download_uri="https://raw.githubusercontent.com/FluffyContainers/native_containers/master"
  local _lib_source_loc="src"

  case ${_command} in 
  -)
    [[ ! -f "${DIR}/${_file}" ]] &&  __echo "INFO" "Skipping ${_file} removal as file doesn't exists"  || __run rm -f "${DIR}/${_file}";;
  +)
    local _http_code=$(curl -s "${_lib_download_uri}/${_lib_source_loc}/${_file}" -o "${DIR}/${_file}" --write-out "%{http_code}")
    if [[ ${_http_code} -lt 200 ]] || [[ ${_http_code} -gt 299 ]]; then 
      __echo "error" "Failed to download file \"${_file}\": HTTP ${_http_code}"
    else 
      __echo "info" "Downloaded \"${_file}\" ... OK"
    fi
    ;;
  ?)
    if [[ -f "${DIR}/${_file}" ]]; then
      __echo "info" "Skipping download of optional \"${_file}\", as file already exists"
      return
    elif [[ "${_file}" == "example.sh" ]] && [[ -f "${DIR}/${_name}.sh" ]]; then
      __echo "info" "Skipping download of optional \"${_name}.sh\", as file already exists"
      return
    else  
      local _http_code=$(curl -s "${_lib_download_uri}/${_lib_source_loc}/${_file}" -o "${DIR}/${_file}" --write-out "%{http_code}")
      [[ ${_http_code} -lt 200 ]] || [[ ${_http_code} -gt 299 ]] && __echo "error" "Failed to download file \"${_file}\": HTTP ${_http_code}" || {
          [[ "${_file}" == "example.sh" ]] && {
          __run mv "${DIR}/${_file}" "${DIR}/${_name}.sh"
          __run chmod +x "${DIR}/${_name}.sh" 
          }
        __echo "info" "Downloaded \"${_file}\" ... OK"
      }
    fi
    ;;
  *)
    __echo "ERROR" "Unknown instruction \"${_command}\"";;
  esac
}

__do_lib_upgrade() {
    local _lib_download_uri="https://raw.githubusercontent.com/FluffyContainers/native_containers/master"
    local _lib_source_loc="src"
    local _remote_ver=""
    
    echo -en "You're about to use remote lib source \"${_COLOR[ERROR]}${_lib_download_uri}${_COLOR[RESET]}\". "
    ! __ask "Agree to continue" && return 1

    local _remote_ver=$(curl "${_lib_download_uri}/version" 2>/dev/null)
    [[ -z ${_remote_ver} ]] && { __echo "error" "Can't retrieve remote version"; exit 1; }
    if ! __vercomp "${LIB_VERSION}" "${_remote_ver}"; then
        echo "Current version ${LIB_VERSION} are installed, while ${_remote_ver} are available ..."
        ! curl --output /dev/null --silent --head --fail "${_lib_download_uri}/download.diff" && { __echo "error" "Lib update list is not available at \"${_lib_download_uri}/download.diff\""; exit 1; }        

        local oldIFS="${IFS}"
        IFS=$'\n'; for line in $(curl -s ${_lib_download_uri}/download.diff); do 
            [[ "${line:0:1}" == "#" ]] && continue
            handle_file "${APP_NAME}" "${line}"
        done
        IFS=${oldIFS}
        if [[ -f "${DIR}/.container.lib.sh" ]]; then
            sed -i "s/LIB_VERSION=\"0.0.0\"/LIB_VERSION=\"${_remote_ver}\"/" "${DIR}/.container.lib.sh"
        fi

        __echo "Upgrade done, please referer to ${_lib_download_uri}/src/.config for new available conf options"
    else 
        __echo "Lib is already up to date"
    fi
}


# ========================= NVIDIA Integration
_add_nvidia_mounts(){
  if [[ ! -f /usr/bin/nvidia-container-cli ]]; then 
    echo "Please install libnvidia-container tools: "
    echo "   - https://github.com/NVIDIA/libnvidia-container"
    echo "   - https://nvidia.github.io/libnvidia-container/"
    exit 1
  fi
  local _args="--cap-add=ALL" # required 
  local _driver_version=$(nvidia-container-cli info|grep "NVRM"|awk -F ':' '{print $2}'|tr -d ' ')

  for _dev in /dev/nvidia*; do 
    local _args="${_args} --device ${_dev}"
  done 
  
  for item in $(nvidia-container-cli list|grep -v "dev"); do 
    if [[ ${item} == *".so"* ]]; then
      local _path_nover=${item%".${_driver_version}"}
      local _args="${_args} -v ${item}:${item}:ro -v ${item}:${_path_nover}:ro -v ${item}:${_path_nover}.1:ro"
    else 
      local _args="${_args} -v ${item}:${item}:ro"
    fi
  done

  [[ -d /dev/dri ]] &&  local _args="${_args} -v /dev/dri:/dev/dri" || true

  echo -n "${_args}"
}

_nvidia_cuda_init(){
  # https://askubuntu.com/questions/590319/how-do-i-enable-automatically-nvidia-uvm
  # https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html#runfile-verifications

  if /sbin/modprobe nvidia; then
    # Count the number of NVIDIA controllers found.
    NVDEVS=$(lspci | grep -i NVIDIA)
    N3D=$(echo "$NVDEVS" | grep -c "3D controller")
    NVGA=$(echo "$NVDEVS" | grep -c "VGA compatible controller")

    N=$((N3D + NVGA - 1))
    for i in $(seq 0 $N); do
      mknod -m 666 "/dev/nvidia$i" c 195 "$i" 1>/dev/null 2>&1
    done

    mknod -m 666 /dev/nvidiactl c 195 255 1>/dev/null 2>&1
  else
    return 1
  fi

  if /sbin/modprobe nvidia-uvm; then
    # Find out the major device number used by the nvidia-uvm driver
    D=$(grep nvidia-uvm /proc/devices | awk '{print $1}')

    mknod -m 666 /dev/nvidia-uvm c "${D}" 0 1>/dev/null 2>&1
  else
    return 1
  fi
  return 0
}
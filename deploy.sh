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

# shellcheck disable=SC2155,SC2015

DIR=${PWD:-$(pwd)}

# =====================
# 
#  Terminal functions
#
# =====================
declare -A _COLOR=(
  [INFO]="\033[38;05;39m"
  [ERROR]="\033[38;05;161m"
  [WARN]="\033[38;05;178m"
  [OK]="\033[38;05;40m"
  [GRAY]="\033[38;05;245m"
  [RESET]="\033[m"
)


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

__run(){
 echo -ne "${_COLOR[INFO]}[EXEC] ${_COLOR[GRAY]}$* -> ["
 "$@" 1>/dev/null 2>/dev/null
 local n=$?
 [[ $n -eq 0 ]] && echo -e "${_COLOR[OK]}ok${_COLOR[GRAY]}]${_COLOR[RESET]}" || echo -e "${_COLOR[ERROR]}fail[#${n}]${_COLOR[GRAY]}]${_COLOR[RESET]}"
 return ${n}
}

__echo() {
 local _lvl="INFO"
 [[ "${1^^}" == "INFO" ]] || [[ "${1^^}" == "ERROR" ]] || [[ "${1^^}" == "WARN" ]] && { local _lvl=${1^^}; shift; }
 
 echo -e "${_COLOR[${_lvl}]}[${_lvl}]${_COLOR[RESET]} $*"
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


LIB_DOWNLOAD_URI="https://raw.githubusercontent.com/FluffyContainers/native_containers/master"
LIB_SOURCE_LOC="src"

handle_file(){
  IFS=" "
  local _name=${1}
  local _diff_line=${2}
  local _command=${_diff_line:0:1}
  local _file=${_diff_line:2}; local _file=${_file//..};local _file=${_file//\/}  # to avoid paths like ../../.something

  case ${_command} in 
  -)
   [[ ! -f "${DIR}/${_file}" ]] &&  __echo "INFO" "Skipping ${_file} removal as file doesn't exists"  || __run rm -f "${DIR}/${_file}";;
  +)
    local _http_code=$(curl -s "${LIB_DOWNLOAD_URI}/${LIB_SOURCE_LOC}/${_file}" -o "${DIR}/${_file}" --write-out "%{http_code}")
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
      local _http_code=$(curl -s "${LIB_DOWNLOAD_URI}/${LIB_SOURCE_LOC}/${_file}" -o "${DIR}/${_file}" --write-out "%{http_code}")
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

install_script(){
  local _name=${1}

  __echo "INFO" "Installation dir: ${DIR}..."
  echo -en "You're about to use remote lib source \"${_COLOR[ERROR]}${LIB_DOWNLOAD_URI}${_COLOR[RESET]}\". "
  ! __ask "Agree to continue" && return 1

  
  local _remote_ver=$(curl -s ${LIB_DOWNLOAD_URI}/version)
  local oldIFS=${IFS}

  [[ -z ${_remote_ver} ]] && { __echo "error" "Can't retrieve remote version"; exit 1; }

  ! curl --output /dev/null --silent --head --fail "${LIB_DOWNLOAD_URI}/download.diff" && { __echo "error" "Lib update list is not available at \"${LIB_DOWNLOAD_URI}/download.diff\""; exit 1; }

  IFS=$'\n'; for line in $(curl -s ${LIB_DOWNLOAD_URI}/download.diff); do 
    [[ "${line:0:1}" == "#" ]] && continue
    handle_file "${_name}" "${line}"
  done
  IFS=${oldIFS}

  if [[ -f "${DIR}/.container.lib.sh" ]]; then
    sed -i "s/LIB_VERSION=\"0.0.0\"/LIB_VERSION=\"${_remote_ver}\"/" "${DIR}/.container.lib.sh"
  fi
  __echo "info" "Deployment done."
}

__MY_SCRIPT_NAME="${1}"; [[ -z "${__MY_SCRIPT_NAME}" ]] && { __echo "error" "No input script name provided"; exit 1; }
install_script "${__MY_SCRIPT_NAME}"
#!/bin/bash

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

. "${DIR}/.container.lib.sh"
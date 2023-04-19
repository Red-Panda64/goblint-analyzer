#!/usr/bin/env bash
# usage: transform.sh [--stdout] [--stderr] transform1 transform2 ... -- [goblint args] file.c
# runs goblint with the given transformations active and outputs the transformed file to stdout

set -eu -o pipefail

function main() {
  local -a trans_args=()
  local stdout=0 stderr=0

  while [ $# -gt 0 ]; local arg="$1"; shift; do
    case $arg in
      --) break ;;
      --stdout) stdout=1 ;;
      --stderr) stderr=1 ;;
      *) trans_args+=( "--set" "trans.activated[+]" "$arg" ) ;;
    esac
  done

  # save stdout to fd 3
  exec 3>&1
  [ $stdout -eq 1 ] || exec 1>/dev/null
  [ $stderr -eq 1 ] || exec 2>/dev/null

  # run goblint, then output the transformed file with the
  # 'Generated by CIL v. X.X.X' header and #line annotations removed
  goblint \
    "${trans_args[@]}" \
    --set trans.output >(awk '!/^#line / && NR > 3' 1>&3) \
    "$@"
}

main "$@"

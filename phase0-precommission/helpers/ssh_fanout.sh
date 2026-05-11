#!/usr/bin/env bash
# Parallel SSH fan-out without external dependencies (no pdsh/parallel-ssh required).
# Usage:
#   ssh_fanout <node_list_file> <fanout> <remote-command-string>
# The remote command runs as "ssh <user>@<node> <P0_SSH_OPTS> <cmd>". The host
# is appended to stdout as the first whitespace-separated field.
#
# Caller is responsible for sourcing env.sh first.

set -u

ssh_fanout() {
    local node_list="$1"
    local fanout="$2"
    local cmd="$3"

    if [[ ! -s "${node_list}" ]]; then
        echo "ssh_fanout: node list ${node_list} missing/empty" >&2
        return 1
    fi

    # xargs gives us a portable parallel runner. We force one node per child
    # via -n1 -P<fanout>. The child runs ssh, captures host on each line.
    # shellcheck disable=SC2016
    xargs -n1 -P"${fanout}" -I{} bash -c '
        host="$1"
        cmd="$2"
        out=$(ssh '"${P0_SSH_OPTS}"' '"${P0_SSH_USER}"'@"${host}" "${cmd}" 2>&1)
        rc=$?
        # Prefix every line with the host so the caller can demux.
        printf "%s\t%d\t%s\n" "${host}" "${rc}" "$(echo "${out}" | base64 -w0)"
    ' _ {} "${cmd}" < "${node_list}"
}

# Decode the base64 payload from a ssh_fanout line.
ssh_fanout_decode() {
    base64 -d <<< "$1"
}

#!/bin/bash -x

# Copyright 2019 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail

fix_mount() {
  echo 'INFO: ensuring we can execute mount/umount even with userns-remap'
  # necessary only when userns-remap is enabled on the host, but harmless
  # The binary /bin/mount should be owned by root and have the setuid bit
  chown root:root "$(which mount)" "$(which umount)"
  chmod -s "$(which mount)" "$(which umount)"

  # This is a workaround to an AUFS bug that might cause `Text file
  # busy` on `mount` command below. See more details in
  # https://github.com/moby/moby/issues/9547
  if [[ "$(stat -f -c %T /bin/mount)" == 'aufs' ]]; then
    echo 'INFO: detected aufs, calling sync' >&2
    sync
  fi

  echo 'INFO: remounting /sys read-only'
  # systemd-in-a-container should have read only /sys
  # https://systemd.io/CONTAINER_INTERFACE/
  # however, we need other things from `docker run --privileged` ...
  # and this flag also happens to make /sys rw, amongst other things
  # mount -o remount,ro /sys

  echo 'INFO: making mounts shared' >&2
  # for mount propagation
  # mount --make-rshared /
}

fix_cgroup() {
  echo 'INFO: fix cgroup mounts for all subsystems'
  # For each cgroup subsystem, Docker does a bind mount from the current
  # cgroup to the root of the cgroup subsystem. For instance:
  #   /sys/fs/cgroup/memory/docker/<cid> -> /sys/fs/cgroup/memory
  #
  # This will confuse Kubelet and cadvisor and will dump the following error
  # messages in kubelet log:
  #   `summary_sys_containers.go:47] Failed to get system container stats for ".../kubelet.service"`
  #
  # This is because `/proc/<pid>/cgroup` is not affected by the bind mount.
  # The following is a workaround to recreate the original cgroup
  # environment by doing another bind mount for each subsystem.
  local docker_cgroup_mounts
  docker_cgroup_mounts=$(grep /sys/fs/cgroup /proc/self/mountinfo | grep docker || true)
  if [[ -n "${docker_cgroup_mounts}" ]]; then
    local docker_cgroup cgroup_subsystems subsystem
    docker_cgroup=$(echo "${docker_cgroup_mounts}" | head -n 1 | cut -d' ' -f 4)
    cgroup_subsystems=$(echo "${docker_cgroup_mounts}" | cut -d' ' -f 5)
    echo "${cgroup_subsystems}" |
    while IFS= read -r subsystem; do
      mkdir -p "${subsystem}${docker_cgroup}"
      mount --bind "${subsystem}" "${subsystem}${docker_cgroup}"
    done
  fi
  local podman_cgroup_mounts
  podman_cgroup_mounts=$(grep /sys/fs/cgroup /proc/self/mountinfo | grep libpod_parent || true)
  if [[ -n "${podman_cgroup_mounts}" ]]; then
    local podman_cgroup cgroup_subsystems subsystem
    podman_cgroup=$(echo "${podman_cgroup_mounts}" | head -n 1 | cut -d' ' -f 4)
    cgroup_subsystems=$(echo "${podman_cgroup_mounts}" | cut -d' ' -f 5)
    echo "${cgroup_subsystems}" |
    while IFS= read -r subsystem; do
      mkdir -p "${subsystem}${podman_cgroup}"
      mount --bind "${subsystem}" "${subsystem}${podman_cgroup}"
    done
  fi
}

fix_machine_id() {
  # Deletes the machine-id embedded in the node image and generates a new one.
  # This is necessary because both kubelet and other components like weave net
  # use machine-id internally to distinguish nodes.
  echo 'INFO: clearing and regenerating /etc/machine-id' >&2
  rm -f /etc/machine-id
  systemd-machine-id-setup
}

fix_product_name() {
    # this is a small fix to hide the underlying hardware and fix issue #426
  # https://github.com/kubernetes-sigs/kind/issues/426
  if [[ -f /sys/class/dmi/id/product_name ]]; then
    echo 'INFO: faking /sys/class/dmi/id/product_name to be "kind"' >&2
    echo 'kind' > /kind/product_name
    mount -o ro,bind /kind/product_name /sys/class/dmi/id/product_name
  fi
}

fix_product_uuid() {
  # The system UUID is usually read from DMI via sysfs, the problem is that
  # in the kind case this means that all (container) nodes share the same
  # system/product uuid, as they share the same DMI.
  # Note: The UUID is read from DMI, this tool is overwriting the sysfs files
  # which should fix the attached issue, but this workaround does not address
  # the issue if a tool is reading directly from DMI.
  # https://github.com/kubernetes-sigs/kind/issues/1027
  [[ ! -f /kind/product_uuid ]] && cat /proc/sys/kernel/random/uuid > /kind/product_uuid
  if [[ -f /sys/class/dmi/id/product_uuid ]]; then
    echo 'INFO: faking /sys/class/dmi/id/product_uuid to be random' >&2
    mount -o ro,bind /kind/product_uuid /sys/class/dmi/id/product_uuid
  fi
  if [[ -f /sys/devices/virtual/dmi/id/product_uuid ]]; then
    echo 'INFO: faking /sys/devices/virtual/dmi/id/product_uuid as well' >&2
    mount -o ro,bind /kind/product_uuid /sys/devices/virtual/dmi/id/product_uuid
  fi
}

fix_kmsg() {
  # In environments where /dev/kmsg is not available, the kubelet (1.15+) won't
  # start because it cannot open /dev/kmsg when starting the kmsgparser in the
  # OOM parser.
  # To support those environments, we link /dev/kmsg to /dev/console.
  # https://github.com/kubernetes-sigs/kind/issues/662
  if [[ ! -e /dev/kmsg ]]; then
    if [[ -e /dev/console ]]; then
      echo 'WARN: /dev/kmsg does not exist, symlinking /dev/console' >&2
      ln -s /dev/console /dev/kmsg
    else
      echo 'WARN: /dev/kmsg does not exist, nor does /dev/console!' >&2
    fi
  fi
}

configure_proxy() {
  # ensure all processes receive the proxy settings by default
  # https://www.freedesktop.org/software/systemd/man/systemd-system.conf.html
  mkdir -p /etc/systemd/system.conf.d/
  cat <<EOF >/etc/systemd/system.conf.d/proxy-default-environment.conf
[Manager]
DefaultEnvironment="HTTP_PROXY=${HTTP_PROXY:-}" "HTTPS_PROXY=${HTTPS_PROXY:-}" "NO_PROXY=${NO_PROXY:-}"
EOF
}

select_iptables() {
  # based on: https://github.com/kubernetes/kubernetes/blob/ffe93b3979486feb41a0f85191bdd189cbd56ccc/build/debian-iptables/iptables-wrapper
  local mode=nft
  num_legacy_lines=$( (iptables-legacy-save || true; ip6tables-legacy-save || true) 2>/dev/null | grep '^-' | wc -l || true)
  if [ "${num_legacy_lines}" -ge 10 ]; then
    mode=legacy
  else
    num_nft_lines=$( (timeout 5 sh -c "iptables-nft-save; ip6tables-nft-save" || true) 2>/dev/null | grep '^-' | wc -l || true)
    if [ "${num_legacy_lines}" -ge "${num_nft_lines}" ]; then
      mode=legacy
    fi
  fi

  echo "INFO: setting iptables to detected mode: ${mode}" >&2
  update-alternatives --set iptables "/usr/sbin/iptables-${mode}" > /dev/null
  update-alternatives --set ip6tables "/usr/sbin/ip6tables-${mode}" > /dev/null
}

enable_network_magic(){
  # well-known docker embedded DNS is at 127.0.0.11:53
  local docker_embedded_dns_ip='127.0.0.11'

  # first we need to detect an IP to use for reaching the docker host
  local docker_host_ip
  docker_host_ip="$( (getent ahostsv4 'host.docker.internal' | head -n1 | cut -d' ' -f1) || true)"
  if [[ -z "${docker_host_ip}" ]]; then
    docker_host_ip=$(ip -4 route show default | cut -d' ' -f3)
  fi

  # patch docker's iptables rules to switch out the DNS IP
  iptables-save \
    | sed \
      `# switch docker DNS DNAT rules to our chosen IP` \
      -e "s/-d ${docker_embedded_dns_ip}/-d ${docker_host_ip}/g" \
      `# we need to also apply these rules to non-local traffic (from pods)` \
      -e 's/-A OUTPUT \(.*\) -j DOCKER_OUTPUT/\0\n-A PREROUTING \1 -j DOCKER_OUTPUT/' \
      `# switch docker DNS SNAT rules rules to our chosen IP` \
      -e "s/--to-source :53/--to-source ${docker_host_ip}:53/g"\
    | iptables-restore

  # now we can ensure that DNS is configured to use our IP
  cp /etc/resolv.conf /etc/resolv.conf.original
  sed -e "s/${docker_embedded_dns_ip}/${docker_host_ip}/g" /etc/resolv.conf.original >/etc/resolv.conf

  # fixup IPs in manifests ...
  curr_ipv4="$( (getent ahostsv4 "$(hostname)" | head -n1 | cut -d' ' -f1) || true)"
  echo "INFO: Detected IPv4 address: ${curr_ipv4}" >&2
  if [ -f /kind/old-ipv4 ]; then
      old_ipv4=$(cat /kind/old-ipv4)
      echo "INFO: Detected old IPv4 address: ${old_ipv4}" >&2
      # sanity check that we have a current address
      if [[ -z $curr_ipv4 ]]; then
        echo "ERROR: Have an old IPv4 address but no current IPv4 address (!)" >&2
        exit 1
      fi
      # kubernetes manifests are only present on control-plane nodes
      sed -i "s#${old_ipv4}#${curr_ipv4}#" /etc/kubernetes/manifests/*.yaml || true
      # this is no longer required with autodiscovery
      sed -i "s#${old_ipv4}#${curr_ipv4}#" /var/lib/kubelet/kubeadm-flags.env || true
  fi
  if [[ -n $curr_ipv4 ]]; then
    echo -n "${curr_ipv4}" >/kind/old-ipv4
  fi

  # do IPv6
    curr_ipv6="$( (getent ahostsv6 "$(hostname)" | head -n1 | cut -d' ' -f1) || true)"
  echo "INFO: Detected IPv6 address: ${curr_ipv6}" >&2
  if [ -f /kind/old-ipv6 ]; then
      old_ipv6=$(cat /kind/old-ipv6)
      echo "INFO: Detected old IPv6 address: ${old_ipv6}" >&2
      # sanity check that we have a current address
      if [[ -z $curr_ipv6 ]]; then
        echo "ERROR: Have an old IPv6 address but no current IPv6 address (!)" >&2
      fi
      # kubernetes manifests are only present on control-plane nodes
      sed -i "s#${old_ipv6}#${curr_ipv6}#" /etc/kubernetes/manifests/*.yaml || true
      # this is no longer required with autodiscovery
      sed -i "s#${old_ipv6}#${curr_ipv6}#" /var/lib/kubelet/kubeadm-flags.env || true
  fi
  if [[ -n $curr_ipv6 ]]; then
    echo -n "${curr_ipv6}" >/kind/old-ipv6
  fi
}

# run pre-init fixups
fix_kmsg
fix_mount
fix_cgroup
fix_machine_id
fix_product_name
fix_product_uuid
configure_proxy
select_iptables
enable_network_magic

# we want the command (expected to be systemd) to be PID1, so exec to it
exec "$@"

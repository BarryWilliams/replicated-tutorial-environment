#!/bin/sh

# override systemctl when using the restart command

command=$1

if [ "$command" == "restart" ]; then

  # do stuff if restarting kubelet
  if [ "$2" == "kubelet" ]; then
    echo "restart kubelet"
    pkill -f kubelet

    source /var/lib/kubelet/kubeadm-flags.env
    KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf
    KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml

    # TODO - log files
    /usr/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS </dev/null &>/dev/null &
  fi

  # do nothing on other restarts
  echo "restart something -- the Pope says nope!!"
  exit 0
fi

# non-restart commands
exec echo "run this: /usr/local/bin/systemctl_docker_replacement $@" #/usr/local/bin/systemctl_docker_replacement $@

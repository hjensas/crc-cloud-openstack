#!/bin/bash

#CONST
export KUBECONFIG="/opt/kubeconfig"
DNSMASQ_CONF="/etc/dnsmasq.d/crc-dnsmasq.conf"
CLUSTER_HEALTH_SLEEP=8
CLUSTER_HEALTH_RETRIES=500
STEPS_SLEEP_TIME=10
MAXIMUM_LOGIN_RETRY=500
CORE_HOME="/var/home/core"
PASSWORDS_FILE="${CORE_HOME}/crc_passwords"


# LOGGING FUNCS
pr_info() {
    echo "[INF] $1"
}

pr_error() {
    >&2 echo "[ERR] $1"
}

pr_end() {
    echo "[END] $1"
}

# Load Afterburn metadata
if ! [ -f /run/metadata/afterburn ]; then
    pr_error  "Afterburn metadata not available"
    exit 1
fi
source /run/metadata/afterburn

# Load the Passwords file - or generate passwords
if ! [ -f "${PASSWORDS_FILE}" ]; then
    touch ${PASSWORDS_FILE}
fi
if ! grep -q PASS_DEVELOPER ${PASSWORDS_FILE}; then
    echo PASS_DEVELOPER=$(uuidgen) >> ${PASSWORDS_FILE}
fi
if ! grep -q PASS_KUBEADMIN ${PASSWORDS_FILE}; then
    echo PASS_KUBEADMIN=$(uuidgen) >> ${PASSWORDS_FILE}
fi
if ! grep -q PASS_REDHAT ${PASSWORDS_FILE}; then
    echo PASS_REDHAT=$(uuidgen) >> ${PASSWORDS_FILE}
fi
source ${PASSWORDS_FILE}

#REPLACED VARS
IIP=${IIP:-$AFTERBURN_OPENSTACK_IPV4_LOCAL}
EIP=${EIP:-$AFTERBURN_OPENSTACK_IPV4_PUBLIC}
PULL_SECRET=${PULL_SECRET:-$(cat /var/home/core/pull-secret.txt | base64 | tr -d "\n")}
SUDO_PREFIX=${SUDO_PREFIX:-""}


save_the_keys() {
    cat /var/home/core/.ssh/authorized_keys.d/afterburn | tee -a /var/home/core/.ssh/authorized_keys > /dev/null
    # clustersetup expects the public key to be in /var/home/core/id_rsa.pub
    tail --lines=1 /var/home/core/.ssh/authorized_keys.d/afterburn | tee /var/home/core/id_rsa.pub > /dev/null
}

stop_if_failed(){
	local exit_code=$1
	local message=$2

	if [[ $exit_code != 0 ]]; then
		pr_error "$message" 
		exit $exit_code
	fi
}

replace_default_ca() {
    local user="system:admin"
    local group="system:masters"
    local user_subj="/O=${group}/CN=${user}"
    local name="custom"
    local ca_subj="/OU=openshift/CN=admin-kubeconfig-signer-custom"
    local validity=3650

    pr_info "replacing the default cluster CA and invalidating default kubeconfig"
    openssl genrsa -out $name-ca.key 4096 > /dev/null 2>&1
    stop_if_failed $? "failed to generate CA private key"

    openssl req -x509 -new -nodes -key $name-ca.key -sha256 -days $validity -out $name-ca.crt -subj "$ca_subj" > /dev/null 2>&1
    stop_if_failed $? "failed to generate CA certificate"

    openssl req -nodes -newkey rsa:2048 -keyout $user.key -subj "$user_subj" -out $user.csr > /dev/null 2>&1
    stop_if_failed $? "failed to issue the CSR"

    openssl x509 -extfile <(printf "extendedKeyUsage = clientAuth") -req -in $user.csr \
       -CA $name-ca.crt -CAkey $name-ca.key -CAcreateserial -out $user.crt -days $validity -sha256 > /dev/null 2>&1
    stop_if_failed $? "failed to generate new admin certificate"

    oc create configmap client-ca-custom -n openshift-config --from-file=ca-bundle.crt=$name-ca.crt
    stop_if_failed $? "failed to create user certficate ConfigMap"

    oc patch apiserver cluster --type=merge -p '{"spec": {"clientCA": {"name": "client-ca-custom"}}}'
    stop_if_failed $? "failed to patch API server with newly created certificate"

    oc create configmap admin-kubeconfig-client-ca -n openshift-config --from-file=ca-bundle.crt=$name-ca.crt \
        --dry-run=client -o yaml | oc replace -f -
    stop_if_failed $? "failed to replace OpenShift CA"
}

login () {
    local counter=0
    pr_info "logging in again to update $KUBECONFIG"

    until oc login --insecure-skip-tls-verify=true -u kubeadmin -p "$PASS_KUBEADMIN" https://api.crc.testing:6443 > /dev/null 2>&1; do
        [[ "$counter" -eq "$MAXIMUM_LOGIN_RETRY" ]] && stop_if_failed 1 "impossible to login on OpenShift, installation failed."
        pr_info "logging into OpenShift with updated credentials try $counter, hang on...."
        sleep 5
        ((counter++))
    done
}

wait_for_resource() {
    local resource=$1
    local retry=0
    local max_retry=20

    until oc get ${resource} > /dev/null 2>&1
    do
        [[ "${retry}" -eq "$max_retry" ]] && stop_if_failed 1 "impossible to get resource ${resource}"
        pr_info "waiting for ${resource} to become available try ${retry}, hang on...."
        sleep 5
        ((retry++))
    done
}

#Replaces the default pubkey with the new one just generated to avoid the mysterious service to replace it later on :-\
replace_default_pubkey() {
    pr_info "Updating the public key resource for machine config operator"
    local pub_key=$(tr -d '\n\r' < /home/core/id_rsa.pub)
    wait_for_resource machineconfig
    oc patch machineconfig 99-master-ssh -p "{\"spec\": {\"config\": {\"passwd\": {\"users\": [{\"name\": \"core\", \"sshAuthorizedKeys\": [\"${pub_key}\"]}]}}}}" --type merge
    stop_if_failed $? "failed to update public key to machine config operator"
}

setup_dsnmasq(){
    local hostName=$(hostname)

    pr_info "writing Dnsmasq conf on $DNSMASQ_CONF"
         cat << EOF | ${SUDO_PREFIX} tee /etc/dnsmasq.d/crc-dnsmasq.conf
listen-address=$IIP
expand-hosts
log-queries
local=/crc.testing/
domain=crc.testing
address=/apps-crc.testing/$IIP
address=/api.crc.testing/$IIP
address=/api-int.crc.testing/$IIP
address=/$hostName.crc.testing/192.168.126.11
EOF

    stop_if_failed  $? "failed to write Dnsmasq configuration in $DNSMASQ_CONF"
    pr_info  "adding Dnsmasq as primary DNS"
    sleep 2
    ${SUDO_PREFIX} nmcli connection modify Wired\ connection\ 1 ipv4.dns "$IIP,169.254.169.254"
    stop_if_failed  $? "failed to modify NetworkManager settings"
    pr_info  "restarting NetworkManager"
    sleep 2
    ${SUDO_PREFIX} systemctl restart NetworkManager
    stop_if_failed $? "failed to restart NetworkManager"
    pr_info  "enabling & starting Dnsmasq service"
    ${SUDO_PREFIX} systemctl enable dnsmasq.service
    ${SUDO_PREFIX} systemctl start dnsmasq.service
    sleep 2
    stop_if_failed $? "failed to start Dnsmasq service"
}

enable_and_start_kubelet() {
    pr_info  "enabling & starting Kubelet service"
    ${SUDO_PREFIX} systemctl enable kubelet
    ${SUDO_PREFIX} systemctl start kubelet
    stop_if_failed $? "failed to start Kubelet service"
}

check_cluster_healthy() {
    local cluster_services=$1
    local counter=0
    local wait="authentication console etcd ingress openshift-apiserver"

    [ ! -z "${cluster_services}" ] && wait="${cluster_services}"

    until oc get co > /dev/null 2>&1; do
        [ "$counter" -eq "$CLUSTER_HEALTH_RETRIES" ] && return 1
        pr_info "waiting Openshift API to become healthy, hang on...."
        sleep $CLUSTER_HEALTH_SLEEP
        ((counter++))
    done

    [[ "$(oc get co "$wait" | awk '{ print $3 }')" =~ "False" ]] && return 1 || return 0
}

wait_cluster_become_healthy () {
    local cluster_services=$1
    local counter=0

    [ ! -z "${cluster_services}" ] && W="[${cluster_services}]" || W="[ALL]"
    until check_cluster_healthy "${cluster_services}"; do
        [ "$counter" -eq "$CLUSTER_HEALTH_RETRIES" ] && return 1
        pr_info "checking for the $counter time if the OpenShift Cluster has become healthy, hang on....$W"
        sleep $CLUSTER_HEALTH_SLEEP
	    ((counter++))
    done
    pr_info "cluster has become ready in $(expr $counter \* $CLUSTER_HEALTH_SLEEP) seconds"
    return 0
}


patch_pull_secret() {
    pr_info  "patching OpenShift pull secret"
    oc patch secret pull-secret -p "{\"data\":{\".dockerconfigjson\":\"$PULL_SECRET\"}}" -n openshift-config --type merge
    stop_if_failed $? "failed patch OpenShift pull secret"
    sleep $STEPS_SLEEP_TIME
}

create_certificate_and_patch_secret() {
    pr_info  "creating OpenShift secrets"
    openssl req -newkey rsa:2048 -new -nodes -x509 -days 3650 -keyout nip.key -out nip.crt -subj "/CN=$EIP.nip.io" -addext "subjectAltName=DNS:apps.$EIP.nip.io,DNS:*.apps.$EIP.nip.io,DNS:api.$EIP.nip.io" > /dev/null 2>&1
    oc create secret tls nip-secret --cert=nip.crt --key=nip.key -n openshift-config
    stop_if_failed $? "failed patch OpenShift pull secret"
    sleep $STEPS_SLEEP_TIME
}

patch_ingress_config() {
    pr_info  "patching Cluster Ingress config"
    cat <<EOF > ingress-patch.yaml
spec:
  appsDomain: apps.$EIP.nip.io
  componentRoutes:
  - hostname: console-openshift-console.apps.$EIP.nip.io
    name: console
    namespace: openshift-console
    servingCertKeyPairSecret:
      name: nip-secret
  - hostname: oauth-openshift.apps.$EIP.nip.io
    name: oauth-openshift
    namespace: openshift-authentication
    servingCertKeyPairSecret:
      name: nip-secret
EOF
    oc patch ingresses.config.openshift.io cluster --type=merge --patch-file=ingress-patch.yaml
    stop_if_failed $? "failed patch Cluster Ingress config"
    #sleep $STEPS_SLEEP_TIME
}

patch_api_server() {
    pr_info  "patching API server"
    oc patch apiserver cluster --type=merge -p '{"spec":{"servingCerts": {"namedCertificates":[{"names":["api.'$EIP'.nip.io"],"servingCertificate": {"name": "nip-secret"}}]}}}'
    stop_if_failed $? "failed patch API server"
    #sleep $STEPS_SLEEP_TIME
}

patch_default_route() {
    pr_info  "patching default route"
    oc patch -p '{"spec": {"host": "default-route-openshift-image-registry.'$EIP'.nip.io"}}' route default-route -n openshift-image-registry --type=merge
    stop_if_failed $? "failed patch default route"
    #sleep $STEPS_SLEEP_TIME
}

set_credentials() {
    pr_info  "setting cluster credentials"
    podman run --rm -ti xmartlabs/htpasswd developer $PASS_DEVELOPER > htpasswd.developer
    stop_if_failed $? "failed to set developer password"
    podman run --rm -ti xmartlabs/htpasswd kubeadmin $PASS_KUBEADMIN > htpasswd.kubeadmin
    stop_if_failed $? "failed to set kubeadmin password"
    podman run --rm -ti xmartlabs/htpasswd redhat $PASS_REDHAT > htpasswd.redhat
    stop_if_failed $? "failed to set redhat password"

    cat htpasswd.developer > htpasswd.txt
    cat htpasswd.kubeadmin >> htpasswd.txt
    cat htpasswd.redhat >> htpasswd.txt
    sed -i '/^\s*$/d' htpasswd.txt

    oc create secret generic htpass-secret  --from-file=htpasswd=htpasswd.txt -n openshift-config --dry-run=client -o yaml > /tmp/htpass-secret.yaml
    stop_if_failed $? "failed to create Cluster secret"
    oc replace -f /tmp/htpass-secret.yaml
    stop_if_failed $? "failed to replace Cluster secret"
}

# Create a tarball with kubeconfig, certs, passwords.
create_config_tarball() {
    local console=$1
    mkdir -p ${CORE_HOME}/crc_config
    cp ${PASSWORDS_FILE} ${CORE_HOME}/crc_config/passwords
    oc cluster-info | head -n 1 > ${CORE_HOME}/crc_config/cluster-info
    echo "Console is running at: ${console}" >> ${CORE_HOME}/crc_config/cluster-info
    sed -i "s/https:\/\/api.crc.testing:6443/https:\/\/api.${EIP}.nip.io:6443/g" ${CORE_HOME}/crc_config/cluster-info
    cp $KUBECONFIG ${CORE_HOME}/crc_config/kubeconfig
    sed -i "s/https:\/\/api.crc.testing:6443/https:\/\/api.${EIP}.nip.io:6443/g" ${CORE_HOME}/crc_config/kubeconfig
    tar -czf ${CORE_HOME}/crc_config.tar.gz -C ${CORE_HOME} crc_config
}

save_the_keys
setup_dsnmasq

enable_and_start_kubelet
replace_default_pubkey
set_credentials
replace_default_ca
login
stop_if_failed $? "failed to recover Cluster after $(expr $CLUSTER_HEALTH_RETRIES \* $CLUSTER_HEALTH_SLEEP) seconds"

patch_pull_secret
create_certificate_and_patch_secret
wait_cluster_become_healthy "etcd openshift-apiserver"
stop_if_failed $? "failed to recover Cluster after $(expr $CLUSTER_HEALTH_RETRIES \* $CLUSTER_HEALTH_SLEEP) seconds"

patch_ingress_config
patch_api_server
patch_default_route

wait_cluster_become_healthy "authentication console etcd ingress openshift-apiserver"

until `oc get route console-custom -n openshift-console > /dev/null 2>&1` 
do
    pr_info "waiting for console route to become ready, hang on...."
    sleep 2
done 

CONSOLE_ROUTE=$(oc get route console-custom -n openshift-console -o json | jq -r '.spec.host')

create_config_tarball ${CONSOLE_ROUTE}

pr_end "Cluster-Info and Config archived in: ${CORE_HOME}/crc_config.tar.gz"
pr_end $CONSOLE_ROUTE
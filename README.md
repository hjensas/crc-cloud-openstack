# crc-cloud-openstack
CRC Cloud Openstack - insipired by https://github.com/crc-org/crc-cloud

A script to modify a CRC bundle qcow2 image so that it can be used in openstack clouds.

* Changes ignition.platfrom.id to openstack
* Enable service `afterburn-sshkeys@core.service` - to ensure SSH keys
  from openstack metadata is added to the `core` user.
* Install `clustersetup.sh` script from: https://github.com/crc-org/crc-cloud
* Set up systemd `clustersetup.path` unit monitoring for: `/var/home/core/pull-secret.txt`
* Set up systemd `clustersetup.service` (triggered by `clustersetup.path`)

The clustersetup.service run's the clustersetup.sh script - once complete it creates a file `/var/home/core/.clustersetup_ran` conditionally disable itself.

## Usage

Clone the reposotory, and run the `crc-cloud-openstack` command.

Configuration via environment variables.

- `BUNDLE_VERSION` - Bundle version to download *(defaults to: `4.14.12`)*
- `BUNDLE_URL` - *(defaults to: `https://mirror.openshift.com/pub/openshift-v4/clients/crc/bundles/openshift/${BUNDLE_VERSION}/crc_libvirt_${BUNDLE_VERSION}_amd64.crcbundle`)*
- `BASE_IMAGE_NAME` - Name of the disk image file in the bundle archive *(defaults to `crc.qcow2`)*
- `WORKSPACE` - Path to working directory *(defaults to: `workspace` relative to the script file)*
- `GUEST_MOUNT_POINT` - Path for image mounting *(defaults to: `$WORKSPACE/mnt`)*
- `FILES_DIR` - Path to files that will be install in the image *(defaults to `${SCRIPTPATH}/files`)*
- `LIBGUESTFS_BACKEND` - *(defaults to: `direct`)*

### Createing the image

   Run command:
   ```bash
   BUNDLE_VERSION=4.14.12 ./crc-cloud-openstack
   ```
   
   Example output:
   ```console
   [INF] Downloading bundle
   ########################################################### 100.0%
   [INF] Extracting bundle
   ......................................................
   [INF] Creating a copy of the base image
   [INF] Getting clustersetup.sh
   ########################################################### 100.0%
   [INF] Modifying clustersetup.sh
   [INF] Mounting image
   [INF] Set ignition platform id in boot loader entries
   [INF] Installing clustersetup.sh
   [INF] Make clustersetup.sh executable
   [INF] Adding systemd service: clustersetup.path
   [INF] Adding systemd service: clustersetup.service
   [INF] Enable systemd services in chroot
   bash-5.1# systemctl enable afterburn-sshkeys@core.service > /dev/null 2>&1
   bash-5.1# systemctl disable clustersetup.service > /dev/null 2>&1
   bash-5.1# systemctl enable clustersetup.path > /dev/null 2>&1
   bash-5.1# systemctl disable qemu-guest-agent.service > /dev/null 2>&1
   bash-5.1# exit
   [INF] Sync and unmount image
   [END] Image crc-openstack-4.14.12.qcow2 created.
   ```

### Upload image to openstack
   ```bash
   openstack image create --disk-format qcow2 --file workspace/crc-openstack-4.14.12.qcow2 openshift-local-4.14.12
   ```

### (Optional) Create a security group

To enable access create a security group allowing traffic on ports and icmp: 
* 80 (HTTP)
* 443 (HTTPs)
* 6443 (APIPort)
* 22 (SSH)

```bash
openstack security group create sg_crc_openstack --description "Security group for CRC (openshift local)"
openstack security group rule create --protocol icmp sg_crc_openstack

openstack security group rule create sg_crc_openstack --protocol tcp --dst-port 22:22 --remote-ip 0.0.0.0/0
openstack security group rule create sg_crc_openstack --protocol tcp --dst-port 80:80 --remote-ip 0.0.0.0/0
openstack security group rule create sg_crc_openstack --protocol tcp --dst-port 443:443 --remote-ip 0.0.0.0/0
openstack security group rule create sg_crc_openstack --protocol tcp --dst-port 6443:6443 --remote-ip 0.0.0.0/0
```

### Creating a CRC Openstack instance

1. Create an instance:
   ```bash
   openstack server create --image openshift-local-4.14.12 --flavor m1.xlarge --network private --key-name default --security-group sg_crc_openstack crc-cloud
2. Add floating IP address:
   ```bash
   openstack server add floating ip crc-cloud 192.168.254.169
   ```
3. (Optional): Create a password file with pre-defined passwords:
   ```bash
   cat << EOF > crc_passwords
   PASS_DEVELOPER=12345678
   PASS_KUBEADMIN=12345678
   PASS_REDHAT=12345678
   EOF
   scp crc_passwords core@192.168.254.169:
   ```
4. Copy pull secret to the instance to trigger the clustersetup service:
   ```bash
   scp ~/pull-secret.txt core@192.168.254.169:pull-secret.txt
   ```
5. The progress of clustersetup can be monitored via the systemd journal, for example:
   ```bash
   ssh core@192.168.254.169 journalctl -f -u clustersetup.service
   ```
6. Get the kubeconfig file:
   ```bash
   scp core@192.168.254.169:/opt/kubeconfig crc_kubeconfig
   ```
7. Get the passwords file:
   ```bash
   scp core@192.168.254.169:crc_passwords crc_passwords
   ```

Kata Containers is a VM-based container runtime. Each container runs inside its own virtual machine, so containers do not share the host kernel.

Asterinas now supports Kata Containers and can serve as the guest kernel in common Kata-based scenarios.

## For End Users
For end users, we provide the `asterinas/kata` container image, which already includes the dependencies and scripts required by Kata.

You can try it with the following command:

```bash
ASTERINAS_IMAGE_TAG=0.17.2-20260407
docker run --rm -it \
    --cgroupns host \
    --privileged \
    --device /dev/kvm \
    --device /dev/vhost-net \
    --device /dev/vhost-vsock \
    --tmpfs /tmp:exec,mode=1777,size=8g \
    --tmpfs /var/lib/containerd:exec,mode=755,size=8g \
    asterinas/kata:${ASTERINAS_IMAGE_TAG}
```

After entering the container, start the background services required by Kata. At the moment, these services are `containerd` and `syslogd`:

```bash
tools/kata/kata_services.sh start
```

You can check their status with the following command to make sure they started successfully:

```bash
tools/kata/kata_services.sh status
```

Then you can use `nerdctl` with Kata to start an Alpine container:

```bash
nerdctl run \
    --cgroup-manager cgroupfs \
    --net none \
    --runtime io.containerd.kata.v2 \
    --name foo \
    -it \
    docker.io/alpine:latest
```

If Docker Hub is temporarily unreachable during local validation, you can use
`docker.1ms.run/alpine:latest` instead. CI should keep using
`docker.io/alpine:latest`.

Once the container starts, you will be inside Alpine. You can run the following commands to verify that you are no longer in the host environment:

```bash
cat /proc/version
cat /etc/alpine-release
```

After you exit the container, remove it with:

```bash
nerdctl rm foo
```

## For Kernel Developers
Kernel developers typically use the `asterinas/asterinas` container image. When starting the container, you also need to pass the additional arguments required by Kata:

```bash
ASTERINAS_IMAGE_TAG=0.17.2-20260407
ASTERINAS_SRC=$HOME/asterinas
KATA_SRC=$(git rev-parse --show-toplevel)
docker run --rm -it \
    --cgroupns host \
    --privileged \
    --device /dev/kvm \
    --device /dev/vhost-net \
    --device /dev/vhost-vsock \
    --tmpfs /tmp:exec,mode=1777,size=8g \
    --tmpfs /var/lib/containerd:exec,mode=755,size=8g \
    -v "${ASTERINAS_SRC}:/root/asterinas" \
    -v "${KATA_SRC}:/root/kata-containers" \
    -w /root/kata-containers \
    asterinas/asterinas:${ASTERINAS_IMAGE_TAG}
```

After entering the container, you will already be in `/root/kata-containers`.
The examples below assume the current kata-containers checkout is mounted there,
and that the local Asterinas tree is mounted at `/root/asterinas`.

```bash
pwd
```

This script installs the files, scripts, and configuration needed to run Kata. After that, you can test Kata in the same way as an end user:

```bash
# Install all dependencies
tools/kata/kata_env.sh install

# Start background services
tools/kata/kata_services.sh start

nerdctl run \
    --cgroup-manager cgroupfs \
    --net none \
    --runtime io.containerd.kata.v2 \
    --name foo \
    -it \
    docker.io/alpine:latest
```

If Docker Hub is temporarily unreachable during local validation, you can use
`docker.1ms.run/alpine:latest` here as well. CI should keep using
`docker.io/alpine:latest`.

If `/dev/vsock` also exists on your host, it is fine to pass it through too,
but the documented minimum setup only requires `/dev/kvm`, `/dev/vhost-net`,
and `/dev/vhost-vsock`.

You can also point Kata to a locally built guest kernel. Edit
`/etc/kata-containers/configuration.toml` and set `kernel` to the path of your
local kernel image:

```toml
[hypervisor.qemu]
kernel = "/root/asterinas/target/osdk/aster-kernel-osdk-bin.qemu_elf"
```

Build the kernel with:

```bash
cd /root/asterinas && make kernel BOOT_METHOD=qemu-direct
```

Then start the container with `nerdctl` again, and Kata will boot using your local kernel.

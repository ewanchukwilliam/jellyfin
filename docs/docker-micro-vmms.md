https://www.docker.com/blog/why-microvms-the-architecture-behind-docker-sandboxes/

# Docker MicroVMs
MicroVMs are a new architecture for Docker that allows containers to run in a virtual machine.

- important tradeoffs. not as fast to build full separated kernel. 
- strong VM level KVM isolation. 
- only works for a single container


``` bash

docker run --microvm qbittorrent
```

## important takeaway 
You can have the compose stack run inside and hare the microvms kernel not the host kernel. so trivial exploit dont work anymore. 
docker networking exists. so this is likely the next best thing for kernel isolation of untrusted containers. 
wrap the whole thing in a microvm image. compose the stack against that daemon. 

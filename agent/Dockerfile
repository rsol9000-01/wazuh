FROM wazuh/wazuh-agent:4.14.5
ARG WAZUH_VERSION=4.14.5
RUN dnf install -y python3-pip iptables-nft util-linux tar gzip && \
    pip3 install docker==7.1.0 urllib3==1.26.20 requests==2.32.2 PyYAML==6.0.2 && \
    dnf clean all
# Official SCA (CIS) policies of the same Wazuh version. sca_host.py turns
# them into "host" policies at startup (see agent/sca_host.py).
RUN mkdir -p /opt/sca-src && \
    curl -fsSL "https://codeload.github.com/wazuh/wazuh/tar.gz/refs/tags/v${WAZUH_VERSION}" \
    | tar -xz -C /opt/sca-src --strip-components=3 --wildcards "wazuh-${WAZUH_VERSION}/ruleset/sca/*"
COPY sca_host.py /opt/sca_host.py
# The agent runs with pid: host (see sca_host.py). On stop, s6-overlay sends
# TERM and KILL to every process it can see (s6-nuke); with pid: host those
# are all the processes of the server (SSH, Docker, the application).
# Remove those two steps and stop the build if any is left.
RUN sed -i '/s6-nuke/d' /etc/s6/init/init-stage3 && \
    ! grep -q s6-nuke /etc/s6/init/init-stage3
# Package inventory (syscollector, used by vulnerability detection) must list
# the packages of the server, not of this image. The host dpkg database is
# mounted at /var/lib/dpkg (see the compose files). Remove the rpm database
# and the Python package metadata of the image so they are not reported as
# packages of the server. Keep this step last: dnf cannot run after it.
# The imports check that the agent scripts still work.
RUN rm -rf /var/lib/rpm /usr/lib/sysimage/rpm && \
    find $(ls -d /usr/lib /usr/lib64 /usr/local/lib /usr/local/lib64 2>/dev/null) \
         -path '*python3*' \( -name '*.dist-info' -o -name '*.egg-info' \) -prune \
         -exec rm -rf {} + && \
    python3 -c "import docker, yaml, requests, urllib3"

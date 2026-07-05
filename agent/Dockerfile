FROM wazuh/wazuh-agent:4.14.5
RUN dnf install -y python3-pip && \
    pip3 install docker==7.1.0 urllib3==1.26.20 requests==2.32.2 && \
    dnf clean all
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest AS builder

RUN microdnf -y update && \
  microdnf -y install tar gzip

WORKDIR /work

RUN (curl -sL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz | tar -C . -xvzf - oc kubectl) && \
  install -m 0755 oc /usr/local/bin/oc && \
  install -m 0755 kubectl /usr/local/bin/kubectl

FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

COPY webhook-server.py requirements.txt scripts/daemonset.sh scripts/logger.sh .

COPY --from=builder /usr/local/bin/oc /usr/local/bin/oc
COPY --from=builder /usr/local/bin/kubectl /usr/local/bin/kubectl

RUN microdnf -y update && \
  microdnf -y install python3.11 python3.11-pip vim-enhanced iproute jq && \
  microdnf clean all && \
  pip3.11 install --no-cache-dir -U pip && \
  pip3.11 install --no-cache-dir -U -r requirements.txt

EXPOSE 8443

CMD ["python3.11", "webhook-server.py"]

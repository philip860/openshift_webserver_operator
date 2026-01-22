# -----------------------------------------------------------------------------
# WebServer Operator (Ansible Operator) - Path B (Rebased UBI9 image)
#
# Fixes:
# - ENTRYPOINT uses /usr/local/bin/ansible-operator (no /usr/local/bin/entrypoint)
# - Use UBI python + ansible-core for ansible-galaxy
# - Install ansible-runner (required at runtime by ansible-operator)
# -----------------------------------------------------------------------------

ARG OSE_ANSIBLE_DIGEST=sha256:81fe42f5070bdfadddd92318d00eed63bf2ad95e2f7e8a317f973aa8ab9c3a88

FROM registry.redhat.io/openshift4/ose-ansible-rhel9-operator@${OSE_ANSIBLE_DIGEST} AS operator-src
FROM registry.access.redhat.com/ubi9/ubi:latest AS final

USER 0
ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# Repo hygiene: keep UBI repos only
RUN set -eux; \
    rm -f /etc/yum.repos.d/redhat.repo || true; \
    rm -f /etc/yum.repos.d/redhat.repo.rpmsave /etc/yum.repos.d/redhat.repo.rpmnew || true

# Enable UBI repos + install tooling
# IMPORTANT: install ansible-runner (required by ansible-operator at runtime)
# NOTE: Do NOT install curl (curl-minimal already present and conflicts)
RUN set -eux; \
    dnf -y install dnf-plugins-core ca-certificates yum \
      python3 python3-setuptools \
      ansible-core ansible-runner; \
    dnf config-manager --set-enabled ubi-9-baseos-rpms || true; \
    dnf config-manager --set-enabled ubi-9-appstream-rpms || true; \
    dnf config-manager --set-enabled ubi-9-codeready-builder-rpms || true; \
    /usr/bin/python3 --version; \
    ansible-galaxy --version; \
    ansible-runner --version; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# Patch UBI first
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y update --security --refresh; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# Create expected dirs
RUN set -eux; \
    mkdir -p /opt/ansible /opt/ansible/.ansible /licenses /opt/ansible-operator /usr/local/bin

# Copy operator runtime bits from official base:
# - /opt runtime bits
# - ansible-operator binary only
COPY --from=operator-src /opt/ /opt/
COPY --from=operator-src /usr/local/bin/ansible-operator /usr/local/bin/ansible-operator

# Quick verify
RUN set -eux; \
    test -x /usr/local/bin/ansible-operator; \
    /usr/local/bin/ansible-operator version; \
    command -v ansible-runner; \
    ansible-runner --version

# Certification labels
LABEL name="webserver-operator-dev" \
      vendor="Duncan Networks" \
      maintainer="Phil Duncan <philipduncan860@gmail.com>" \
      version="1.0.34" \
      release="1" \
      summary="Kubernetes operator to deploy and manage web workloads" \
      description="An Ansible-based operator that manages web workload deployments on OpenShift/Kubernetes."

# Licensing
RUN set -eux; \
    mkdir -p /licenses; \
    printf "See project repository for license and terms.\n" > /licenses/NOTICE

# Make Ansible output visible in OpenShift pod logs (stdout/stderr)
ENV ANSIBLE_STDOUT_CALLBACK=default \
    ANSIBLE_LOAD_CALLBACK_PLUGINS=1 \
    ANSIBLE_FORCE_COLOR=0 \
    PYTHONUNBUFFERED=1 \
    ANSIBLE_DEPRECATION_WARNINGS=False

# Install required Ansible collections
COPY requirements.yml /tmp/requirements.yml
RUN set -eux; \
    ansible-galaxy collection install -r /tmp/requirements.yml \
      --collections-path /opt/ansible/.ansible/collections; \
    chmod -R g+rwX /opt/ansible/.ansible; \
    rm -f /tmp/requirements.yml

# Copy operator content
COPY watches.yaml ./watches.yaml
COPY playbooks/ ./playbooks/
COPY roles/ ./roles/

# OpenShift-friendly permissions (arbitrary UID)
RUN set -eux; \
    chgrp -R 0 ${ANSIBLE_OPERATOR_DIR} /opt/ansible /opt/ansible/.ansible /licenses /usr/local/bin; \
    chmod -R g=u ${ANSIBLE_OPERATOR_DIR} /opt/ansible /opt/ansible/.ansible /licenses /usr/local/bin

USER 1001
ENV ANSIBLE_USER_ID=1001

ENTRYPOINT ["/usr/local/bin/ansible-operator"]
CMD ["run", "--watches-file=/opt/ansible-operator/watches.yaml"]

# -----------------------------------------------------------------------------
# WebServer Operator (Ansible Operator) - UBI rebase but preserve official runner events
# -----------------------------------------------------------------------------

ARG OSE_ANSIBLE_DIGEST=sha256:81fe42f5070bdfadddd92318d00eed63bf2ad95e2f7e8a317f973aa8ab9c3a88

# Stage 0: Official operator image as source of truth for ansible + runner + plugins
FROM registry.redhat.io/openshift4/ose-ansible-rhel9-operator@${OSE_ANSIBLE_DIGEST} AS operator-src

# Stage 1: Final rebased filesystem (UBI 9)
FROM registry.access.redhat.com/ubi9/ubi:latest AS final

USER 0

ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# 1) UBI repos only + install minimal runtime deps
#    (NO ansible-core here; we transplant the exact ansible stack from operator-src)
RUN set -eux; \
    rm -f /etc/yum.repos.d/redhat.repo || true; \
    rm -f /etc/yum.repos.d/redhat.repo.rpmsave /etc/yum.repos.d/redhat.repo.rpmnew || true; \
    dnf -y install dnf-plugins-core ca-certificates; \
    dnf config-manager --set-enabled ubi-9-baseos-rpms || true; \
    dnf config-manager --set-enabled ubi-9-appstream-rpms || true; \
    dnf config-manager --set-enabled ubi-9-codeready-builder-rpms || true; \
    dnf -y repolist; \
    # Python runtime and common libs runner/ansible often need
    dnf -y install \
      python3 \
      python3-pyyaml \
      python3-jinja2 \
      python3-cryptography \
      python3-requests \
      python3-six \
      python3-setuptools \
      python3-pip \
      # runner interaction deps
      python3-pexpect \
      # misc helpers sometimes required by runner/ansible
      shadow-utils \
      findutils \
      tar \
      gzip \
      which; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# 2) Patch UBI packages with security errata (this is your CVE reduction lever)
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y update --security --refresh || dnf -y update --refresh; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# 3) Create OpenShift-friendly dirs
ENV HOME=/opt/ansible \
    ANSIBLE_LOCAL_TEMP=/opt/ansible/.ansible/tmp \
    ANSIBLE_REMOTE_TEMP=/opt/ansible/.ansible/tmp \
    ANSIBLE_COLLECTIONS_PATHS=/opt/ansible/.ansible/collections:/usr/share/ansible/collections \
    ANSIBLE_ROLES_PATH=/opt/ansible/.ansible/roles:/etc/ansible/roles:/usr/share/ansible/roles \
    ANSIBLE_NOCOLOR=1 \
    ANSIBLE_FORCE_COLOR=0 \
    TERM=dumb \
    PYTHONUNBUFFERED=1

RUN set -eux; \
    mkdir -p \
      /opt/ansible/.ansible/tmp \
      /opt/ansible/.ansible/collections \
      /opt/ansible/.ansible/roles \
      /etc/ansible \
      /licenses \
      ${ANSIBLE_OPERATOR_DIR}; \
    chgrp -R 0 /opt/ansible /licenses ${ANSIBLE_OPERATOR_DIR} /etc/ansible; \
    chmod -R g+rwX /opt/ansible /licenses ${ANSIBLE_OPERATOR_DIR} /etc/ansible

# 4) Copy operator runtime bits from official image (keeps operator expectations)
COPY --from=operator-src /opt/ /opt/

# 5) Copy ansible-operator binary (as you already do)
COPY --from=operator-src /usr/local/bin/ansible-operator /usr/local/bin/ansible-operator

# 6) TRANSPLANT the exact Ansible + Runner stack from operator-src
#    This is the important part: match the working official image behavior.
#
#    Copy ansible + ansible_runner python modules and their metadata.
COPY --from=operator-src /usr/lib/python3.9/site-packages/ansible/ /usr/lib/python3.9/site-packages/ansible/
COPY --from=operator-src /usr/lib/python3.9/site-packages/ansible-*.dist-info/ /usr/lib/python3.9/site-packages/
COPY --from=operator-src /usr/lib/python3.9/site-packages/ansible_runner/ /usr/lib/python3.9/site-packages/ansible_runner/
COPY --from=operator-src /usr/lib/python3.9/site-packages/ansible_runner-*.dist-info/ /usr/lib/python3.9/site-packages/

# Copy ansible CLI entrypoints (ansible-playbook etc.) from operator-src
COPY --from=operator-src /usr/bin/ansible /usr/bin/ansible
COPY --from=operator-src /usr/bin/ansible-playbook /usr/bin/ansible-playbook
COPY --from=operator-src /usr/bin/ansible-galaxy /usr/bin/ansible-galaxy
COPY --from=operator-src /usr/bin/ansible-doc /usr/bin/ansible-doc

# 7) Sanity check: confirm we're using the transplanted stack (no callback forcing)
RUN set -eux; \
    /usr/local/bin/ansible-operator version; \
    ansible-playbook --version; \
    python3 -c "import ansible_runner; print('ansible_runner from:', ansible_runner.__file__)"

# 8) Required certification labels + NOTICE
LABEL name="webserver-operator" \
      vendor="Duncan Networks" \
      maintainer="Phil Duncan <philipduncan860@gmail.com>" \
      version="1.0.35" \
      release="1" \
      summary="Kubernetes operator to deploy and manage web workloads" \
      description="An Ansible-based operator that manages web workload deployments on OpenShift/Kubernetes."

RUN set -eux; \
    mkdir -p /licenses; \
    printf "See project repository for license and terms.\n" > /licenses/NOTICE; \
    chgrp -R 0 /licenses; \
    chmod -R g+rwX /licenses

# 9) Operator content + collections
COPY requirements.yml /tmp/requirements.yml
RUN set -eux; \
    if [ -s /tmp/requirements.yml ]; then \
      ansible-galaxy collection install -r /tmp/requirements.yml \
        --collections-path /opt/ansible/.ansible/collections; \
    fi; \
    rm -f /tmp/requirements.yml; \
    chgrp -R 0 /opt/ansible; \
    chmod -R g+rwX /opt/ansible

COPY watches.yaml ${ANSIBLE_OPERATOR_DIR}/watches.yaml
COPY playbooks/ ${ANSIBLE_OPERATOR_DIR}/playbooks/
COPY roles/ ${ANSIBLE_OPERATOR_DIR}/roles/

RUN set -eux; \
    chgrp -R 0 ${ANSIBLE_OPERATOR_DIR} /opt/ansible /licenses; \
    chmod -R g=u ${ANSIBLE_OPERATOR_DIR} /opt/ansible /licenses

# 10) Entrypoint shim
RUN set -eux; \
  printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    'exec /usr/local/bin/ansible-operator run --watches-file=/opt/ansible-operator/watches.yaml' \
  > /usr/local/bin/entrypoint; \
  chmod 0755 /usr/local/bin/entrypoint

USER 1001
ENV ANSIBLE_USER_ID=1001

ENTRYPOINT ["/usr/local/bin/entrypoint"]

# -----------------------------------------------------------------------------
# WebServer Operator - Keep OCP operator base (runner events OK) + pull UBI errata
# -----------------------------------------------------------------------------

ARG OSE_ANSIBLE_DIGEST=sha256:81fe42f5070bdfadddd92318d00eed63bf2ad95e2f7e8a317f973aa8ab9c3a88
FROM registry.redhat.io/openshift4/ose-ansible-rhel9-operator@${OSE_ANSIBLE_DIGEST}

USER 0
ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# -----------------------------------------------------------------------------
# 1) Add PUBLIC UBI repos (cdn-ubi.redhat.com) so you can get fixes not present
#    in the OCP operator image repos.
# -----------------------------------------------------------------------------
RUN set -eux; \
  cat > /etc/yum.repos.d/ubi.repo <<'EOF'
[ubi-9-baseos-rpms]
name=Red Hat Universal Base Image 9 (RPMs) - BaseOS
baseurl=https://cdn-ubi.redhat.com/content/public/ubi/dist/ubi9/9/$basearch/baseos/os
enabled=1
gpgcheck=0

[ubi-9-appstream-rpms]
name=Red Hat Universal Base Image 9 (RPMs) - AppStream
baseurl=https://cdn-ubi.redhat.com/content/public/ubi/dist/ubi9/9/$basearch/appstream/os
enabled=1
gpgcheck=0

[ubi-9-codeready-builder-rpms]
name=Red Hat Universal Base Image 9 (RPMs) - CodeReady Builder
baseurl=https://cdn-ubi.redhat.com/content/public/ubi/dist/ubi9/9/$basearch/codeready-builder/os
enabled=1
gpgcheck=0
EOF

# -----------------------------------------------------------------------------
# 2) Pull security updates (from ANY enabled repos, including UBI)
#    IMPORTANT: Do NOT replace ansible/ansible-runner via pip/dnf.
# -----------------------------------------------------------------------------
RUN set -eux; \
  dnf -y makecache --refresh; \
  dnf -y update --security --refresh || dnf -y update --refresh; \
  dnf -y clean all; \
  rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# -----------------------------------------------------------------------------
# 3) Certification labels + NOTICE
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# 4) Operator content + collections
# -----------------------------------------------------------------------------
COPY requirements.yml /tmp/requirements.yml
RUN set -eux; \
  if [ -s /tmp/requirements.yml ]; then \
    ansible-galaxy collection install -r /tmp/requirements.yml; \
  fi; \
  rm -f /tmp/requirements.yml

COPY watches.yaml ${ANSIBLE_OPERATOR_DIR}/watches.yaml
COPY playbooks/ ${ANSIBLE_OPERATOR_DIR}/playbooks/
COPY roles/ ${ANSIBLE_OPERATOR_DIR}/roles/

# -----------------------------------------------------------------------------
# 5) OpenShift permissions (random UID, group 0)
# -----------------------------------------------------------------------------
RUN set -eux; \
  chgrp -R 0 ${ANSIBLE_OPERATOR_DIR} /licenses /opt/ansible /etc/ansible || true; \
  chmod -R g=u ${ANSIBLE_OPERATOR_DIR} /licenses /opt/ansible /etc/ansible || true

# -----------------------------------------------------------------------------
# 6) Entrypoint
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# WebServer Operator (Ansible Operator) - Rebased UBI runtime
#
# Fixes:
# - Keep operator runtime working (entrypoint + ansible-operator)
# - Avoid broken copied ansible-galaxy wrapper (/usr/local/bin/python3)
# - Install python deps for kubernetes.core via pip fallback
# -----------------------------------------------------------------------------

ARG OSE_ANSIBLE_DIGEST=sha256:81fe42f5070bdfadddd92318d00eed63bf2ad95e2f7e8a317f973aa8ab9c3a88

# Stage 0: certified operator image (source of operator runtime + /opt content)
FROM registry.redhat.io/openshift4/ose-ansible-rhel9-operator@${OSE_ANSIBLE_DIGEST} AS operator-src

# Final: publish UBI
FROM registry.access.redhat.com/ubi9/ubi:latest AS final

USER 0

ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# -----------------------------------------------------------------------------
# Repo hygiene: keep UBI repos only
# -----------------------------------------------------------------------------
RUN set -eux; \
    rm -f /etc/yum.repos.d/redhat.repo || true; \
    rm -f /etc/yum.repos.d/redhat.repo.rpmsave /etc/yum.repos.d/redhat.repo.rpmnew || true

# -----------------------------------------------------------------------------
# Install required tooling from UBI (THIS provides /usr/bin/ansible-galaxy)
# NOTE: Do NOT install curl (curl-minimal is present and conflicts)
# -----------------------------------------------------------------------------
RUN set -eux; \
    dnf -y install dnf-plugins-core ca-certificates yum \
      python3 python3-setuptools python3-pip \
      ansible-core; \
    dnf config-manager --set-enabled ubi-9-baseos-rpms || true; \
    dnf config-manager --set-enabled ubi-9-appstream-rpms || true; \
    dnf config-manager --set-enabled ubi-9-codeready-builder-rpms || true; \
    python3 --version; \
    /usr/bin/ansible-galaxy --version; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# -----------------------------------------------------------------------------
# Patch UBI first (security errata)
# -----------------------------------------------------------------------------
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y update --security --refresh; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# -----------------------------------------------------------------------------
# OpenShift-friendly env + directories (arbitrary UID)
# -----------------------------------------------------------------------------
ENV HOME=/opt/ansible \
    ANSIBLE_LOCAL_TEMP=/opt/ansible/.ansible/tmp \
    ANSIBLE_REMOTE_TEMP=/opt/ansible/.ansible/tmp \
    ANSIBLE_COLLECTIONS_PATHS=/opt/ansible/.ansible/collections:/usr/share/ansible/collections \
    ANSIBLE_ROLES_PATH=/opt/ansible/.ansible/roles:/etc/ansible/roles:/usr/share/ansible/roles \
    ANSIBLE_STDOUT_CALLBACK=default \
    ANSIBLE_LOAD_CALLBACK_PLUGINS=1 \
    ANSIBLE_FORCE_COLOR=0 \
    PYTHONUNBUFFERED=1

RUN set -eux; \
    mkdir -p /opt/ansible/.ansible/tmp /opt/ansible/.ansible/collections /opt/ansible/.ansible/roles \
             /licenses ${ANSIBLE_OPERATOR_DIR}

# -----------------------------------------------------------------------------
# Copy only the pieces we actually need from operator-src
#
# - /opt contains the operator project skeleton bits used by the ansible-operator plugin
# - /usr/local/bin/entrypoint and /usr/local/bin/ansible-operator are needed to RUN
# - Do NOT copy /usr/local/bin/ansible-* wrappers (they can have wrong shebang)
# -----------------------------------------------------------------------------
COPY --from=operator-src /opt/ /opt/

# Copy ONLY runtime executables (not the ansible wrappers)
COPY --from=operator-src /usr/local/bin/entrypoint /usr/local/bin/entrypoint
COPY --from=operator-src /usr/local/bin/ansible-operator /usr/local/bin/ansible-operator

# -----------------------------------------------------------------------------
# Python deps needed by kubernetes.core modules (pip fallback is expected on UBI)
# -----------------------------------------------------------------------------
RUN set -eux; \
    python3 -m pip install --no-cache-dir \
      "kubernetes>=24.2.0" \
      "openshift>=0.13.2" \
      "requests>=2.25" \
      "pyyaml>=5.4"

# -----------------------------------------------------------------------------
# Certification labels + NOTICE
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
    printf "See project repository for license and terms.\n" > /licenses/NOTICE

# -----------------------------------------------------------------------------
# Install required collections using the *UBI* ansible-galaxy (NOT /usr/local/bin)
# -----------------------------------------------------------------------------
COPY requirements.yml /tmp/requirements.yml
RUN set -eux; \
    if [ -s /tmp/requirements.yml ]; then \
      /usr/bin/ansible-galaxy collection install -r /tmp/requirements.yml \
        --collections-path /opt/ansible/.ansible/collections; \
    fi; \
    rm -f /tmp/requirements.yml

# -----------------------------------------------------------------------------
# Copy operator content
# -----------------------------------------------------------------------------
COPY watches.yaml ${ANSIBLE_OPERATOR_DIR}/watches.yaml
COPY playbooks/   ${ANSIBLE_OPERATOR_DIR}/playbooks/
COPY roles/       ${ANSIBLE_OPERATOR_DIR}/roles/

# -----------------------------------------------------------------------------
# Permissions for arbitrary UID
# -----------------------------------------------------------------------------
RUN set -eux; \
    chgrp -R 0 ${ANSIBLE_OPERATOR_DIR} /opt/ansible /licenses /usr/local/bin; \
    chmod -R g=u ${ANSIBLE_OPERATOR_DIR} /opt/ansible /licenses /usr/local/bin

USER 1001
ENV ANSIBLE_USER_ID=1001

# -----------------------------------------------------------------------------
# Make rebased image actually start the operator
# -----------------------------------------------------------------------------
ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["ansible-operator", "run", "--watches-file=/opt/ansible-operator/watches.yaml"]

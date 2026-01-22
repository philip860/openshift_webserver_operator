# -----------------------------------------------------------------------------
# WebServer Operator (Ansible Operator) - Path B (Publish REBASED UBI image)
#
# Fixes:
# - Preserve operator runtime (entrypoint + ansible-operator)
# - Do NOT use copied ansible-galaxy wrapper (it points to /usr/local/bin/python3)
# - Use UBI's ansible-core (ansible-galaxy uses /usr/bin/python3)
# - Avoid curl vs curl-minimal conflict (do NOT install curl)
# - Remove redhat.repo to avoid repo mixing
# -----------------------------------------------------------------------------

ARG OSE_ANSIBLE_DIGEST=sha256:81fe42f5070bdfadddd92318d00eed63bf2ad95e2f7e8a317f973aa8ab9c3a88

# Stage 0: official operator base (source of runtime bits)
FROM registry.redhat.io/openshift4/ose-ansible-rhel9-operator@${OSE_ANSIBLE_DIGEST} AS operator-src

# Final: rebased UBI filesystem we publish
FROM registry.access.redhat.com/ubi9/ubi:latest AS final

USER 0
ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# Repo hygiene: keep UBI repos only
RUN set -eux; \
    rm -f /etc/yum.repos.d/redhat.repo || true; \
    rm -f /etc/yum.repos.d/redhat.repo.rpmsave /etc/yum.repos.d/redhat.repo.rpmnew || true

# Install python + ansible-core from UBI (this provides a working ansible-galaxy)
# NOTE: Do NOT install curl (curl-minimal already present and conflicts)
RUN set -eux; \
    dnf -y install dnf-plugins-core ca-certificates yum python3 python3-setuptools ansible-core; \
    dnf config-manager --set-enabled ubi-9-baseos-rpms || true; \
    dnf config-manager --set-enabled ubi-9-appstream-rpms || true; \
    dnf config-manager --set-enabled ubi-9-codeready-builder-rpms || true; \
    dnf -y repolist; \
    /usr/bin/python3 --version; \
    ansible-galaxy --version; \
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
    mkdir -p /opt/ansible /opt/ansible/.ansible /licenses /opt/ansible-operator

# Copy operator runtime bits from official base
COPY --from=operator-src /opt/ /opt/
COPY --from=operator-src /usr/local/bin/ /usr/local/bin/

# IMPORTANT: remove copied ansible wrappers that reference /usr/local/bin/python3
# We want to use UBI's ansible-core ones in /usr/bin instead.
RUN set -eux; \
    rm -f /usr/local/bin/ansible /usr/local/bin/ansible-playbook /usr/local/bin/ansible-galaxy /usr/local/bin/ansible-config || true; \
    command -v ansible-galaxy; \
    head -n1 "$(command -v ansible-galaxy)" || true

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

# Install required Ansible collections using UBI's ansible-galaxy
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

# Force operator entrypoint so container doesn't exit immediately
ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["/usr/local/bin/ansible-operator", "run", "--watches-file=/opt/ansible-operator/watches.yaml"]

USER 1001
ENV ANSIBLE_USER_ID=1001

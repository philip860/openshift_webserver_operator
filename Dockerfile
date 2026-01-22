# -----------------------------------------------------------------------------
# WebServer Operator (Ansible Operator) - UBI9 Rebase (Path B)
#
# Highlights:
# - Copy /opt runtime bits and /usr/local/bin/ansible-operator from the Red Hat base
# - Use UBI python + ansible-core for ansible-galaxy
# - Install ansible-runner via pip --prefix /opt/pip
# - Make /opt/pip site-packages visible to system python via .pth
# - Provide /usr/local/bin/ansible-runner wrapper (no heredocs -> parser safe)
# - OpenShift-friendly permissions (arbitrary UID)
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

# Base tooling (UBI)
RUN set -eux; \
    dnf -y install dnf-plugins-core ca-certificates yum; \
    dnf config-manager --set-enabled ubi-9-baseos-rpms || true; \
    dnf config-manager --set-enabled ubi-9-appstream-rpms || true; \
    dnf config-manager --set-enabled ubi-9-codeready-builder-rpms || true; \
    dnf -y install python3 python3-setuptools python3-pip ansible-core; \
    /usr/bin/python3 --version; \
    ansible-galaxy --version; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# Patch UBI security errata
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y update --security --refresh; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# Expected dirs
RUN set -eux; \
    mkdir -p \
      /opt/ansible \
      /opt/ansible/.ansible \
      /opt/pip \
      /licenses \
      /usr/local/bin \
      /opt/ansible-operator

# Copy operator runtime bits from official base:
# - /opt runtime bits
# - ansible-operator binary only
COPY --from=operator-src /opt/ /opt/
COPY --from=operator-src /usr/local/bin/ansible-operator /usr/local/bin/ansible-operator

# Verify ansible-operator
RUN set -eux; \
    test -x /usr/local/bin/ansible-operator; \
    /usr/local/bin/ansible-operator version

# Install ansible-runner via pip (prefix) + make it importable + wrapper on PATH
RUN set -eux; \
    /usr/bin/pip3 install --no-cache-dir --prefix /opt/pip "ansible-runner>=2.4,<3"; \
    pyver="$(/usr/bin/python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"; \
    sitepk="/opt/pip/lib/python${pyver}/site-packages"; \
    test -d "${sitepk}"; \
    echo "${sitepk}" > "/usr/lib/python${pyver}/site-packages/zz_opt_pip_sitepackages.pth"; \
    printf '%s\n' '#!/bin/sh' 'exec /usr/bin/python3 -m ansible_runner "$@"' > /usr/local/bin/ansible-runner; \
    chmod +x /usr/local/bin/ansible-runner; \
    /usr/local/bin/ansible-runner --version
    
# Certification labels
LABEL name="webserver-operator-dev" \
      vendor="Duncan Networks" \
      maintainer="Phil Duncan <philipduncan860@gmail.com>" \
      version="1.0.34" \
      release="1" \
      summary="Kubernetes operator to deploy and manage web workloads" \
      description="An Ansible-based operator that manages web workload deployments on OpenShift/Kubernetes."

# Licensing placeholder
RUN set -eux; \
    printf "See project repository for license and terms.\n" > /licenses/NOTICE

# Make Ansible output visible in OpenShift logs
ENV ANSIBLE_STDOUT_CALLBACK=default \
    ANSIBLE_LOAD_CALLBACK_PLUGINS=1 \
    ANSIBLE_FORCE_COLOR=0 \
    PYTHONUNBUFFERED=1 \
    ANSIBLE_DEPRECATION_WARNINGS=False \
    PATH="/opt/pip/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Install required Ansible collections
COPY requirements.yml /tmp/requirements.yml
RUN set -eux; \
    ansible-galaxy collection install -r /tmp/requirements.yml \
      --collections-path /opt/ansible/.ansible/collections; \
    chmod -R g+rwX /opt/ansible/.ansible; \
    rm -f /tmp/requirements.yml

# Operator content
COPY watches.yaml ./watches.yaml
COPY playbooks/ ./playbooks/
COPY roles/ ./roles/

# OpenShift-friendly permissions
RUN set -eux; \
    chgrp -R 0 ${ANSIBLE_OPERATOR_DIR} /opt/ansible /opt/ansible/.ansible /licenses /usr/local/bin /opt/pip; \
    chmod -R g=u ${ANSIBLE_OPERATOR_DIR} /opt/ansible /opt/ansible/.ansible /licenses /usr/local/bin /opt/pip

USER 1001
ENV ANSIBLE_USER_ID=1001

ENTRYPOINT ["/usr/local/bin/ansible-operator"]
CMD ["run", "--watches-file=/opt/ansible-operator/watches.yaml"]

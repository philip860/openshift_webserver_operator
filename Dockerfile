# -----------------------------------------------------------------------------
# WebServer Operator - Rebased UBI9 + Preserve official runner/ansible behavior
#
# Goals:
# - Pass Red Hat scan (UBI base + errata)
# - Provide ansible-operator + ansible-runner CLI + ansible-playbook
# - Ensure runner events work (playbook_on_stats) by forcing stdout_callback=ansible_runner
# - Ensure localhost k8s modules work (kubernetes/openshift installed for /usr/bin/python3)
# - Avoid pip dependency conflicts (pin resolvelib for ansible-core 2.14.x)
# - Install ansible-runner-http
# - Install/refresh operator_sdk.util collection
# -----------------------------------------------------------------------------

ARG OSE_ANSIBLE_DIGEST=sha256:81fe42f5070bdfadddd92318d00eed63bf2ad95e2f7e8a317f973aa8ab9c3a88

# Stage 0: official operator image (source of ansible-operator binary + base runtime bits)
FROM registry.redhat.io/openshift4/ose-ansible-rhel9-operator@${OSE_ANSIBLE_DIGEST} AS operator-src

# Stage 1: rebased UBI image we publish
FROM registry.access.redhat.com/ubi9/ubi:latest AS final

USER 0
ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# -----------------------------------------------------------------------------
# 1) Repo hygiene: remove redhat.repo; use only UBI content
# -----------------------------------------------------------------------------
RUN set -eux; \
    rm -f /etc/yum.repos.d/redhat.repo || true; \
    rm -f /etc/yum.repos.d/redhat.repo.rpmsave /etc/yum.repos.d/redhat.repo.rpmnew || true

# -----------------------------------------------------------------------------
# 2) Enable UBI repos + install REQUIRED runtime:
#    - python3 + pip (this is /usr/bin/python3, which ansible-core uses)
#    - ansible-core (provides /usr/bin/ansible-playbook)
# -----------------------------------------------------------------------------
RUN set -eux; \
    dnf -y install dnf-plugins-core ca-certificates yum findutils which tar gzip shadow-utils; \
    dnf config-manager --set-enabled ubi-9-baseos-rpms || true; \
    dnf config-manager --set-enabled ubi-9-appstream-rpms || true; \
    dnf config-manager --set-enabled ubi-9-codeready-builder-rpms || true; \
    dnf -y makecache --refresh; \
    \
    dnf -y install python3 python3-pip python3-setuptools python3-wheel; \
    /usr/bin/python3 -V; \
    /usr/bin/python3 -m pip --version; \
    \
    dnf -y install ansible-core; \
    command -v ansible-playbook; \
    ansible-playbook --version; \
    \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

ENV PIP_ROOT_USER_ACTION=ignore
ENV PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

# -----------------------------------------------------------------------------
# 3) Patch UBI packages (security errata)
# -----------------------------------------------------------------------------
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y update --security --refresh || dnf -y update --refresh; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# -----------------------------------------------------------------------------
# 4) Create OpenShift-friendly dirs
# -----------------------------------------------------------------------------
RUN set -eux; \
    mkdir -p \
      /opt/ansible/.ansible/tmp \
      /opt/ansible/.ansible/collections \
      /opt/ansible/.ansible/roles \
      /etc/ansible \
      /licenses \
      ${ANSIBLE_OPERATOR_DIR} \
      /usr/local/bin \
      /usr/share/ansible/plugins/callback

# -----------------------------------------------------------------------------
# 5) Copy operator runtime bits and ansible config from official base
# -----------------------------------------------------------------------------
COPY --from=operator-src /opt/ /opt/
COPY --from=operator-src /etc/ansible/ /etc/ansible/

# Stage0 bins into temp
COPY --from=operator-src /usr/local/bin/ /tmp/operator-src/usr-local-bin/
COPY --from=operator-src /usr/bin/ /tmp/operator-src/usr-bin/

# -----------------------------------------------------------------------------
# 6) Install ansible-operator binary from operator-src (robust)
# -----------------------------------------------------------------------------
RUN set -eux; \
    if [ -x /tmp/operator-src/usr-local-bin/ansible-operator ]; then \
      install -m 0755 /tmp/operator-src/usr-local-bin/ansible-operator /usr/local/bin/ansible-operator; \
    elif [ -x /tmp/operator-src/usr-bin/ansible-operator ]; then \
      install -m 0755 /tmp/operator-src/usr-bin/ansible-operator /usr/local/bin/ansible-operator; \
    else \
      echo "ERROR: ansible-operator not found in operator-src"; \
      ls -la /tmp/operator-src/usr-local-bin || true; \
      ls -la /tmp/operator-src/usr-bin || true; \
      exit 1; \
    fi; \
    /usr/local/bin/ansible-operator version

# -----------------------------------------------------------------------------
# 7) Install ansible-runner CLI from operator-src so the operator can exec it
# -----------------------------------------------------------------------------
RUN set -eux; \
    if [ -x /tmp/operator-src/usr-local-bin/ansible-runner ]; then \
      install -m 0755 /tmp/operator-src/usr-local-bin/ansible-runner /usr/local/bin/ansible-runner; \
    elif [ -x /tmp/operator-src/usr-bin/ansible-runner ]; then \
      install -m 0755 /tmp/operator-src/usr-bin/ansible-runner /usr/local/bin/ansible-runner; \
    else \
      echo "ERROR: ansible-runner CLI not found in operator-src"; \
      ls -la /tmp/operator-src/usr-local-bin || true; \
      ls -la /tmp/operator-src/usr-bin || true; \
      exit 1; \
    fi; \
    chmod 0755 /usr/local/bin/ansible-runner

# -----------------------------------------------------------------------------
# 8) Pip constraints to keep RPM-installed ansible-core happy
#    ansible-core 2.14.x requires resolvelib < 0.9.0
# -----------------------------------------------------------------------------
RUN set -eux; \
    printf '%s\n' \
      'resolvelib>=0.5.3,<0.9.0' \
    > /etc/pip-constraints.txt

# -----------------------------------------------------------------------------
# 9) Install python deps for *system python* (/usr/bin/python3)
#    - ansible-runner module (needed by /usr/local/bin/ansible-runner)
#    - kubernetes/openshift (needed by kubernetes.core modules on localhost)
#    - ansible-runner-http
# -----------------------------------------------------------------------------
RUN set -eux; \
    /usr/bin/python3 -m pip install --no-cache-dir --upgrade -c /etc/pip-constraints.txt \
      pip setuptools wheel; \
    /usr/bin/python3 -m pip install --no-cache-dir -c /etc/pip-constraints.txt \
      "ansible-runner==2.4.1" \
      "ansible-runner-http" \
      "kubernetes>=24.2.0" \
      "openshift>=0.13.2" \
      "pexpect>=4.8.0" \
      "ptyprocess>=0.7.0" \
      "PyYAML>=6.0" \
      "python-daemon>=3.0.1" \
      "lockfile>=0.12.2" \
      "jinja2>=3.1" \
      "packaging" \
      "cryptography"; \
    \
    /usr/bin/python3 -m pip check; \
    /usr/bin/python3 -c "import kubernetes, openshift; print('OK: k8s libs')"; \
    /usr/bin/python3 -c "import ansible_runner; print('OK: ansible_runner import:', ansible_runner.__file__)"; \
    /usr/bin/python3 -c "import ansible_runner_http; print('OK: ansible_runner_http import:', ansible_runner_http.__file__)"; \
    /usr/local/bin/ansible-runner --version

# -----------------------------------------------------------------------------
# 10) Install/refresh operator_sdk.util collection (requested)
# -----------------------------------------------------------------------------
RUN set -eux; \
    mkdir -p /opt/ansible/.ansible/collections; \
    chgrp -R 0 /opt/ansible; \
    chmod -R g+rwX /opt/ansible; \
    ansible-galaxy collection install operator_sdk.util \
      --collections-path /opt/ansible/.ansible/collections; \
    ansible-galaxy collection list \
      --collections-path /opt/ansible/.ansible/collections \
      | grep -E '^operator_sdk\.util\b'


# -----------------------------------------------------------------------------
# 11) CRITICAL: ensure playbook_on_stats event is emitted
#     Force stdout_callback=ansible_runner and ensure callback plugin is discoverable.
# -----------------------------------------------------------------------------
# Make sure callback destination exists
RUN set -eux; \
    mkdir -p /usr/share/ansible/plugins/callback /etc/ansible

# Copy the helper into the image and run it using the image python
COPY build_helper/install_runner_callback.py /usr/local/bin/install_runner_callback.py

RUN set -eux; \
    chmod 0755 /usr/local/bin/install_runner_callback.py; \
    /usr/bin/python3 /usr/local/bin/install_runner_callback.py; \
    ansible-doc -t callback ansible_runner >/dev/null 2>&1 || \
      (echo "ERROR: ansible_runner callback not discoverable" && exit 1)

# -----------------------------------------------------------------------------
# 12) Verify runtime commands exist
# -----------------------------------------------------------------------------
RUN set -eux; \
    command -v ansible-playbook; \
    command -v ansible-runner; \
    ansible-playbook --version; \
    /usr/local/bin/ansible-runner --version

# -----------------------------------------------------------------------------
# 13) Clean temp copies
# -----------------------------------------------------------------------------
RUN set -eux; \
    rm -rf /tmp/operator-src

# -----------------------------------------------------------------------------
# 14) Environment
# -----------------------------------------------------------------------------
ENV HOME=/opt/ansible \
    ANSIBLE_LOCAL_TEMP=/opt/ansible/.ansible/tmp \
    ANSIBLE_REMOTE_TEMP=/opt/ansible/.ansible/tmp \
    ANSIBLE_COLLECTIONS_PATHS=/opt/ansible/.ansible/collections:/usr/share/ansible/collections \
    ANSIBLE_ROLES_PATH=/opt/ansible/.ansible/roles:/etc/ansible/roles:/usr/share/ansible/roles \
    ANSIBLE_LOAD_CALLBACK_PLUGINS=1 \
    ANSIBLE_PYTHON_INTERPRETER=/usr/bin/python3 \
    PYTHONUNBUFFERED=1

# -----------------------------------------------------------------------------
# 15) Required certification labels + NOTICE
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
# 16) Operator content + collections (your project content)
# -----------------------------------------------------------------------------
COPY requirements.yml /tmp/requirements.yml
RUN set -eux; \
    if [ -s /tmp/requirements.yml ]; then \
      ansible-galaxy collection install -r /tmp/requirements.yml \
        --collections-path /opt/ansible/.ansible/collections; \
    fi; \
    rm -f /tmp/requirements.yml; \
    chgrp -R 0 /opt/ansible /licenses ${ANSIBLE_OPERATOR_DIR} /etc/ansible || true; \
    chmod -R g+rwX /opt/ansible /licenses ${ANSIBLE_OPERATOR_DIR} /etc/ansible || true

COPY watches.yaml ${ANSIBLE_OPERATOR_DIR}/watches.yaml
COPY playbooks/ ${ANSIBLE_OPERATOR_DIR}/playbooks/
COPY roles/ ${ANSIBLE_OPERATOR_DIR}/roles/

RUN set -eux; \
    chgrp -R 0 ${ANSIBLE_OPERATOR_DIR} /opt/ansible /licenses /etc/ansible || true; \
    chmod -R g=u ${ANSIBLE_OPERATOR_DIR} /opt/ansible /licenses /etc/ansible || true

# -----------------------------------------------------------------------------
# 17) Entrypoint
# -----------------------------------------------------------------------------
RUN set -eux; \
  printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    'exec /usr/local/bin/ansible-operator run --watches-file=/opt/ansible-operator/watches.yaml' \
  > /usr/local/bin/entrypoint; \
  chmod 0755 /usr/local/bin/entrypoint

# -----------------------------------------------------------------------------
# 18) Run as OpenShift arbitrary UID (non-root)
# -----------------------------------------------------------------------------
USER 1001
ENV ANSIBLE_USER_ID=1001

ENTRYPOINT ["/usr/local/bin/entrypoint"]

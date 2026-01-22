# -----------------------------------------------------------------------------
# WebServer Operator (Ansible Operator) - Path B (Rebased UBI, Red Hat scan-friendly)
# -----------------------------------------------------------------------------

ARG OSE_ANSIBLE_DIGEST=sha256:81fe42f5070bdfadddd92318d00eed63bf2ad95e2f7e8a317f973aa8ab9c3a88

# Stage 0: grab operator runtime bits from official OCP base
FROM registry.redhat.io/openshift4/ose-ansible-rhel9-operator@${OSE_ANSIBLE_DIGEST} AS operator-src

# Stage 1: final image on UBI 9
FROM registry.access.redhat.com/ubi9/ubi:latest AS final

USER 0

ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# 1) Repo hygiene
RUN set -eux; \
    rm -f /etc/yum.repos.d/redhat.repo || true; \
    rm -f /etc/yum.repos.d/redhat.repo.rpmsave /etc/yum.repos.d/redhat.repo.rpmnew || true

# 2) Base tooling
# NOTE: no python3-virtualenv package (not in these repos)
RUN set -eux; \
    dnf -y install dnf-plugins-core ca-certificates yum \
      python3 python3-setuptools python3-pip \
      ansible-core; \
    dnf -y repolist; \
    python3 --version; \
    ansible --version; \
    ansible-galaxy --version; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# 3) Patch UBI packages (security errata)
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y update --security --refresh; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# 4) Install python deps REQUIRED BY YOUR PLAYBOOKS into SYSTEM PYTHON.
# This is the key fix because your logs show Ansible is using /usr/bin/python3.
RUN set -eux; \
    python3 -m pip install --no-cache-dir --upgrade pip setuptools wheel; \
    python3 -m pip install --no-cache-dir \
      "ansible-runner>=2.3.6" \
      "kubernetes>=24.2.0" \
      "openshift>=0.13.2"; \
    python3 -c "import kubernetes, openshift; print('system python deps OK')" ; \
    ansible-runner --version

# 5) OpenShift-friendly HOME/Ansible dirs
ENV HOME=/opt/ansible \
    ANSIBLE_LOCAL_TEMP=/opt/ansible/.ansible/tmp \
    ANSIBLE_REMOTE_TEMP=/opt/ansible/.ansible/tmp \
    ANSIBLE_COLLECTIONS_PATHS=/opt/ansible/.ansible/collections:/usr/share/ansible/collections \
    ANSIBLE_ROLES_PATH=/opt/ansible/.ansible/roles:/etc/ansible/roles:/usr/share/ansible/roles \
    ANSIBLE_FORCE_COLOR=0 \
    PYTHONUNBUFFERED=1

RUN set -eux; \
    mkdir -p \
      /opt/ansible/.ansible/tmp \
      /opt/ansible/.ansible/collections \
      /opt/ansible/.ansible/roles \
      /licenses \
      ${ANSIBLE_OPERATOR_DIR}; \
    chgrp -R 0 /opt/ansible /licenses ${ANSIBLE_OPERATOR_DIR}; \
    chmod -R g+rwX /opt/ansible /licenses ${ANSIBLE_OPERATOR_DIR}

# 6) Ansible config (don’t set empty callbacks; keep it simple)
RUN set -eux; \
    mkdir -p /etc/ansible; \
    cat > /etc/ansible/ansible.cfg <<'EOF'
[defaults]
stdout_callback = default
host_key_checking = False
retry_files_enabled = False
EOF

# 7) Copy runtime bits from official OpenShift operator base
COPY --from=operator-src /opt/ /opt/

# 8) Copy ansible-operator binary robustly
COPY --from=operator-src /usr/local/bin/ /tmp/operator-src/usr-local-bin/
COPY --from=operator-src /usr/bin/ /tmp/operator-src/usr-bin/

RUN set -eux; \
    if [ -x /tmp/operator-src/usr-local-bin/ansible-operator ]; then \
      install -m 0755 /tmp/operator-src/usr-local-bin/ansible-operator /usr/local/bin/ansible-operator; \
    elif [ -x /tmp/operator-src/usr-bin/ansible-operator ]; then \
      install -m 0755 /tmp/operator-src/usr-bin/ansible-operator /usr/local/bin/ansible-operator; \
    else \
      echo "ERROR: ansible-operator not found in operator-src image"; \
      ls -la /tmp/operator-src/usr-local-bin || true; \
      ls -la /tmp/operator-src/usr-bin || true; \
      exit 1; \
    fi; \
    rm -rf /tmp/operator-src; \
    /usr/local/bin/ansible-operator version

# 9) Labels + NOTICE
LABEL name="webserver-operator" \
      vendor="Duncan Networks" \
      maintainer="Phil Duncan <philipduncan860@gmail.com>" \
      version="1.0.34-dev" \
      release="1" \
      summary="Kubernetes operator to deploy and manage web workloads" \
      description="An Ansible-based operator that manages web workload deployments on OpenShift/Kubernetes."

RUN set -eux; \
    mkdir -p /licenses; \
    printf "See project repository for license and terms.\n" > /licenses/NOTICE

# 10) Operator content + collections
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

# 11) Entrypoint shim
RUN set -eux; \
    cat > /usr/local/bin/entrypoint <<'EOF'
#!/bin/sh
set -eu
exec /usr/local/bin/ansible-operator run --watches-file=/opt/ansible-operator/watches.yaml
EOF
RUN chmod +x /usr/local/bin/entrypoint

# 12) Drop to non-root
USER 1001
ENV ANSIBLE_USER_ID=1001

ENTRYPOINT ["/usr/local/bin/entrypoint"]

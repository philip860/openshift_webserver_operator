# -----------------------------------------------------------------------------
# WebServer Operator - safest approach:
#   * Inherit quay.io/operator-framework/ansible-operator:latest
#   * DO NOT override ENTRYPOINT/CMD (this is what makes your image "do nothing")
#   * Copy operator project into the directory the base image watches
#   * Install python deps needed by kubernetes.core modules
# -----------------------------------------------------------------------------
FROM quay.io/operator-framework/ansible-operator:latest

# Base image is already wired to start the operator correctly.
# We only add dependencies + our operator content.
USER 0

# ---------------------------------------------------------------------
# 1) Make OpenShift random UID happy:
#    - writable HOME
#    - writable ansible cache dirs
#    - group 0 permissions
# ---------------------------------------------------------------------
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
    mkdir -p /opt/ansible/.ansible/tmp /opt/ansible/.ansible/collections /opt/ansible/.ansible/roles; \
    chgrp -R 0 /opt/ansible; \
    chmod -R g+rwX /opt/ansible

# ---------------------------------------------------------------------
# 2) Install python libraries required by kubernetes.core modules:
#    - This fixes: "Failed to import the required Python library (kubernetes)"
#    - Use pip because RPM names may not exist in the base repos for this image.
# ---------------------------------------------------------------------
RUN set -eux; \
    python3 -m pip install --no-cache-dir \
      "kubernetes>=24.2.0" \
      "openshift>=0.13.2" \
      "pyyaml>=5.4" \
      "requests>=2.25"

# ---------------------------------------------------------------------
# 3) Copy your operator project into the directory the base image expects.
#    The base image uses ANSIBLE_OPERATOR_DIR=/opt/ansible-operator.
# ---------------------------------------------------------------------
ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# Copy the key operator runtime bits
COPY watches.yaml ${ANSIBLE_OPERATOR_DIR}/watches.yaml
COPY playbooks/ ${ANSIBLE_OPERATOR_DIR}/playbooks/
COPY roles/ ${ANSIBLE_OPERATOR_DIR}/roles/

# If you use collections via requirements.yml, install them
# (Keep collections under /opt/ansible/.ansible/collections which we made writable)
COPY requirements.yml /tmp/requirements.yml
RUN set -eux; \
    if [ -s /tmp/requirements.yml ]; then \
      ansible-galaxy collection install -r /tmp/requirements.yml \
        --collections-path /opt/ansible/.ansible/collections; \
    fi; \
    rm -f /tmp/requirements.yml; \
    chgrp -R 0 /opt/ansible; \
    chmod -R g+rwX /opt/ansible

# Ensure operator dir is readable under random UID
RUN set -eux; \
    chgrp -R 0 ${ANSIBLE_OPERATOR_DIR}; \
    chmod -R g+rwX ${ANSIBLE_OPERATOR_DIR}

# Drop back to the base image’s non-root user (often 1001)
USER 1001

# IMPORTANT:
# Do NOT set ENTRYPOINT or CMD here.
# We want the base image’s ENTRYPOINT/CMD to remain intact so it auto-runs
# ansible-operator with watches.yaml and CSV env vars (WATCH_NAMESPACE, etc.).

FROM quay.io/operator-framework/ansible-operator:v1.34.1

USER 0

# This is the directory ansible-operator expects to run from
ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# Install required Ansible collections (kubernetes.core, etc.)
# Make sure requirements.yml is in the same directory as this Dockerfile.
COPY requirements.yml /tmp/requirements.yml
RUN ansible-galaxy collection install -r /tmp/requirements.yml \
      --collections-path /opt/ansible/.ansible/collections \
 && chmod -R g+rwX /opt/ansible/.ansible \
 && rm -f /tmp/requirements.yml

# Copy the operator configuration into the image
# These paths MUST exist in your build context:
#   ./watches.yaml
#   ./playbooks/
#   ./roles/
COPY watches.yaml ./watches.yaml
COPY playbooks/ ./playbooks/
COPY roles/ ./roles/

USER ${ANSIBLE_USER_ID}

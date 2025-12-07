FROM quay.io/operator-framework/ansible-operator:v1.34.1

USER 0

# Copy operator definition
COPY watches.yaml ${ANSIBLE_OPERATOR_DIR}/watches.yaml
COPY playbooks/ ${ANSIBLE_OPERATOR_DIR}/playbooks/
COPY roles/ ${ANSIBLE_OPERATOR_DIR}/roles/

USER ${ANSIBLE_USER_ID}

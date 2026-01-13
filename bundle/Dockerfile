FROM scratch

LABEL operators.operatorframework.io.bundle.mediatype.v1=registry+v1
LABEL operators.operatorframework.io.bundle.manifests.v1=manifests/
LABEL operators.operatorframework.io.bundle.metadata.v1=metadata/
LABEL operators.operatorframework.io.bundle.package.v1=webserver-operator
LABEL operators.operatorframework.io.bundle.channels.v1=stable
LABEL operators.operatorframework.io.bundle.channel.default.v1=stable
LABEL com.redhat.openshift.versions="v4.18-v4.20"

# Cert-safe required-ish metadata (avoid RH trademarks in vendor/name)
LABEL name="webserver-operator-bundle" \
      vendor="Duncan Networks" \
      maintainer="Phil Duncan <philipduncan860@gmail.com>" \
      summary="Operator bundle for webserver-operator" \
      description="OLM bundle containing manifests and metadata for the webserver operator."

# License path expected by HasLicense checks
COPY LICENSE /licenses/LICENSE

COPY manifests/ /manifests/
COPY metadata/ /metadata/

# Non-root metadata
USER 1001

